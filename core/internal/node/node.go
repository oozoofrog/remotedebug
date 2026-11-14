package node

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/tailscale/wireguard-go/tun"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/logtail"
	"tailscale.com/tsnet"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/direct"
	"remotedebug/core/internal/events"
	"remotedebug/core/internal/host"
	"remotedebug/core/internal/ids"
	"remotedebug/core/internal/memstat"
	"remotedebug/core/internal/proxy"
	"remotedebug/core/internal/tunnel"
)

func init() {
	// Never upload logs to log.tailscale.com from the embedded node.
	logtail.Disable()
}

// Options are in-process settings that cannot come through the C API.
type Options struct {
	Now    func() time.Time // nil means time.Now
	Limits host.Limits
	// Tun replaces the utunFd device in tunnel mode (in-memory TUN for tests).
	Tun tun.Device
	// Direct changes where the same-network listener binds and whom it
	// accepts (tests use loopback).
	Direct direct.Options
}

// Timings of the background work; variables so tests can shorten them.
const (
	listenFailLimit   = 3                // consecutive host listener failures before "Error"
	loginKickInterval = 30 * time.Second // NeedsLogin without authURL: StartLoginInteractive at most this often
	certRetryMin      = 30 * time.Second
	certRetryMax      = 10 * time.Minute
	listenTLSTimeout  = 30 * time.Second
	logMaxBytes       = 5 << 20 // logPath rotates once to <path>.1 at this size
)

// listenTLSFunc is the TLS host listener; tests replace it.
var listenTLSFunc = listenTailnetTLS

// Status is the rd_status payload (protocol §9, docs/protocol-addenda.md).
type Status struct {
	BackendState    string        `json:"backendState"`
	ErrorMessage    string        `json:"errorMessage,omitempty"` // only with backendState "Error"
	AuthURL         string        `json:"authURL"`
	Hostname        string        `json:"hostname"`
	FQDN            string        `json:"fqdn"`
	TailscaleIPs    []string      `json:"tailscaleIPs"`
	CertDomains     []string      `json:"certDomains"`
	TLSReady        bool          `json:"tlsReady"`
	Listening       bool          `json:"listening"`
	PublishedBuilds int           `json:"publishedBuilds"`
	PairedDevices   int           `json:"pairedDevices"`
	RSSMiB          float64       `json:"rssMiB"`
	Tunnel          *TunnelStatus `json:"tunnel,omitempty"` // tunnel mode only
	// PeerPath is the tunnel node's path to the peer set with SetPathPeer
	// (docs/protocol-addenda.md N). Absent when no peer is set, the peer is
	// unknown or it has no recent traffic.
	PeerPath *PeerPath `json:"peerPath,omitempty"`
	// PeerPaths is the host node's path to each paired device, keyed by
	// nodeStableId. Devices without recent traffic are left out.
	PeerPaths map[string]PeerPath `json:"peerPaths,omitempty"`
	// Direct is the same-network listener (docs/protocol-addenda.md O). Host
	// mode only; absent until it was turned on once in this run.
	Direct *DirectStatus `json:"direct,omitempty"`
}

// DirectStatus is status.direct. The host app advertises ID on Port over
// Bonjour while Listening.
type DirectStatus struct {
	Listening bool   `json:"listening"`
	Port      int    `json:"port"`
	ID        string `json:"id"`
}

// PeerPath says how packets reach one peer: directly (UDP to Addr) or through
// the relay (DERP region code).
type PeerPath struct {
	Direct bool   `json:"direct"`
	Addr   string `json:"addr,omitempty"`  // direct only: the peer's UDP endpoint
	Relay  string `json:"relay,omitempty"` // the peer's relay region code
}

// pathOf maps a peer's status to its path. A peer with a current UDP address
// is direct. Without one, a peer with recent traffic is relayed; an idle peer
// has no known path (nil).
func pathOf(ps *ipnstate.PeerStatus) *PeerPath {
	if ps == nil {
		return nil
	}
	if ps.CurAddr != "" {
		return &PeerPath{Direct: true, Addr: ps.CurAddr, Relay: ps.Relay}
	}
	if ps.Active {
		return &PeerPath{Relay: ps.Relay}
	}
	return nil
}

// normalName lowercases a DNS name and drops the trailing dot.
func normalName(s string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(s), "."))
}

// pathToName returns the path to the peer whose MagicDNS name is fqdn.
func pathToName(st *ipnstate.Status, fqdn string) *PeerPath {
	if st == nil || fqdn == "" {
		return nil
	}
	for _, ps := range st.Peer {
		if ps != nil && normalName(ps.DNSName) == fqdn {
			return pathOf(ps)
		}
	}
	return nil
}

// pathsToDevices returns the paths to the peers whose stable ID is in ids.
func pathsToDevices(st *ipnstate.Status, ids []string) map[string]PeerPath {
	if st == nil || len(ids) == 0 {
		return nil
	}
	want := make(map[string]bool, len(ids))
	for _, id := range ids {
		want[id] = true
	}
	var out map[string]PeerPath
	for _, ps := range st.Peer {
		if ps == nil || !want[string(ps.ID)] {
			continue
		}
		if p := pathOf(ps); p != nil {
			if out == nil {
				out = map[string]PeerPath{}
			}
			out[string(ps.ID)] = *p
		}
	}
	return out
}

// TunnelStatus is status.tunnel (docs/tunnel.md): the last network settings
// plus the peer count.
type TunnelStatus struct {
	Addresses       []string `json:"addresses"`
	Routes          []string `json:"routes"`
	DNSServers      []string `json:"dnsServers"`
	DNSMatchDomains []string `json:"dnsMatchDomains"`
	MTU             int      `json:"mtu"`
	PeerCount       int      `json:"peerCount"`
}

// tunDeadMessage is errorMessage when the engine stopped by itself.
const tunDeadMessage = "TUN 장치가 닫혔습니다."

// One tunnel node per process: it marks the utun in process-global netmon
// state and two engines on one utun would split its packets.
var (
	tunnelMu   sync.Mutex
	tunnelLive bool
)

// claimTunnel checks the tunnel-only settings and reserves the process's
// tunnel node. It runs before any side effect of Start.
func claimTunnel(cfg *Config, opt Options) error {
	if opt.Tun == nil {
		if cfg.UtunFd <= 0 {
			return apierr.InvalidConfig("utunFd가 필요합니다.")
		}
		if err := tunnel.CheckUTUN(cfg.UtunFd); err != nil {
			return apierr.InvalidConfig("utunFd가 utun 소켓이 아닙니다.")
		}
	}
	tunnelMu.Lock()
	defer tunnelMu.Unlock()
	if tunnelLive {
		return apierr.InvalidConfig("tunnel_in_use")
	}
	tunnelLive = true
	return nil
}

func releaseTunnel() {
	tunnelMu.Lock()
	tunnelLive = false
	tunnelMu.Unlock()
}

// Node is one running core instance.
type Node struct {
	cfg       *Config
	srv       *tsnet.Server // nil in tunnel mode
	tun       *tunnel.Node  // tunnel mode only
	events    *events.Queue
	host      *host.Host // nil in proxy mode
	logger    *log.Logger
	lockDiag  sync.Once // tailnet lock diagnostic, once per start
	logOut    io.Closer
	ctx       context.Context
	cancel    context.CancelFunc
	done      chan struct{}
	watchDone chan struct{} // closed when watchBackend returns

	certFn       func(ctx context.Context, fqdn string) error
	certRetryMin time.Duration
	certRetryMax time.Duration

	mu          sync.Mutex
	closed      bool
	backend     string // raw ipn state; see publicState
	backendErr  string // last ErrMessage from the backend, cleared when Running
	listenFails int
	listenErr   string // set after listenFailLimit consecutive listener failures
	loginKick   time.Time
	authURL     string
	fqdn        string
	selfID      string
	ips         []string
	certs       []string
	listening   bool
	tlsReady    bool
	httpSrv     *http.Server
	prx         *proxy.Proxy
	proxyAddr   string
	lastErr     string
	lastEmit    Status
	peerCount   int    // tunnel: cached once per refresh
	pathPeer    string // tunnel: MagicDNS name whose path is reported (SetPathPeer)
	peerPath    *PeerPath
	peerPaths   map[string]PeerPath // host: paired devices by stable ID
	tunErr      string              // tunnel: set when the engine stopped by itself

	directOpt direct.Options
	directID  *direct.Identity // host: loaded when the direct listener is first turned on
	directSrv *http.Server     // host: non-nil while the direct listener runs
}

// Start validates cfg, starts the node and returns immediately; the node
// comes up in the background and reports progress as "state" events.
func Start(cfg *Config, opt Options) (_ *Node, err error) {
	if cfg.Mode == "tunnel" {
		if err := claimTunnel(cfg, opt); err != nil {
			return nil, err
		}
		defer func() {
			if err != nil {
				releaseTunnel()
			}
		}()
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		return nil, apierr.InvalidConfig("stateDir를 만들 수 없습니다.")
	}
	memstat.ApplyLimit(cfg.GoMemLimitMiB)

	n := &Node{
		cfg:          cfg,
		events:       events.New(events.DefaultCapacity),
		backend:      "Starting",
		done:         make(chan struct{}),
		watchDone:    make(chan struct{}),
		certRetryMin: certRetryMin,
		certRetryMax: certRetryMax,
		loginKick:    time.Now(),
	}
	n.ctx, n.cancel = context.WithCancel(context.Background())
	n.certFn = func(ctx context.Context, fqdn string) error { return warmTailnetCert(ctx, n.srv, fqdn) }

	n.logger = log.New(io.Discard, "", log.LstdFlags|log.LUTC)
	if cfg.LogPath != "" {
		f, err := openRotatingFile(cfg.LogPath, logMaxBytes)
		if err != nil {
			return nil, apierr.InvalidConfig("logPath를 열 수 없습니다.")
		}
		n.logger.SetOutput(f)
		n.logOut = f
	}

	if cfg.Mode == "tunnel" {
		if err := n.startTunnel(opt); err != nil {
			n.cancel()
			n.closeLog()
			return nil, err
		}
		go n.monitor()
		go n.watchBackend()
		return n, nil
	}

	if cfg.Mode == "host" {
		h, err := host.New(host.Options{
			WhoIs:      n.whois,
			Now:        opt.Now,
			Events:     n.events,
			PublishDir: cfg.PublishDir,
			Info:       n.info,
			BaseURL:    n.baseURL,
			Limits:     opt.Limits,
			Direct:     n.directInfo,
		})
		if err != nil {
			n.closeLog()
			return nil, err
		}
		n.host = h
		n.directOpt = opt.Direct
		if cfg.DirectListen {
			// Independent of the tailnet: a failure here never stops the node.
			if err := n.SetDirect(true); err != nil {
				n.logf("warn", "직접 연결 리스너를 열지 못했습니다: %v", err)
			}
		}
	}

	n.srv = &tsnet.Server{
		Dir:        cfg.StateDir,
		Hostname:   cfg.Hostname,
		AuthKey:    cfg.AuthKey,
		ControlURL: cfg.ControlURL,
		Ephemeral:  cfg.Ephemeral,
		UserLogf:   n.tsLogf,
	}
	if cfg.LogPath != "" {
		n.srv.Logf = n.tsLogf
	}
	if err := n.srv.Start(); err != nil {
		if n.host != nil {
			n.SetDirect(false)
			n.host.Close()
		}
		n.closeLog()
		return nil, apierr.Internal("tsnet 시작 실패: " + err.Error())
	}
	go n.monitor()
	go n.watchBackend()
	return n, nil
}

// startTunnel opens the utun (or the injected device) and starts the
// tunnel engine.
func (n *Node) startTunnel(opt Options) error {
	dev := opt.Tun
	if dev == nil {
		d, err := tunnel.OpenUTUN(n.cfg.UtunFd)
		if err != nil {
			return apierr.Internal("utun 열기 실패: " + err.Error())
		}
		dev = d
	}
	var logf func(string, ...any)
	if n.cfg.LogPath != "" {
		logf = n.tsLogf
	}
	t, err := tunnel.Start(n.ctx, tunnel.Config{
		StateDir:   n.cfg.StateDir,
		Hostname:   n.cfg.Hostname,
		ControlURL: n.cfg.ControlURL,
		AuthKey:    n.cfg.AuthKey,
		Ephemeral:  n.cfg.Ephemeral,
		MTU:        n.cfg.MTU,
		Tun:        dev,
		MarkUTUN:   opt.Tun == nil,
		Logf:       logf,
		OnSettings: n.onSettings,
	})
	if err != nil {
		return apierr.Internal("터널 시작 실패: " + err.Error())
	}
	n.tun = t
	return nil
}

// onSettings runs under engine locks: it only queues the event. A newer
// network-settings event replaces one still waiting in the queue.
func (n *Node) onSettings(s tunnel.Settings) {
	n.events.Replace(events.Event{
		"type":            "network-settings",
		"addresses":       s.Addresses,
		"routes":          s.Routes,
		"dnsServers":      s.DNSServers,
		"dnsMatchDomains": s.DNSMatchDomains,
		"mtu":             s.MTU,
	})
}

// watchBackend records backend error messages (bad auth key, control
// errors) from the IPN bus so rd_status can report "Error". It re-attaches
// when the backend closes the watch.
func (n *Node) watchBackend() {
	defer close(n.watchDone)
	for n.ctx.Err() == nil {
		if n.tun != nil {
			n.tun.Watch(n.ctx, func(msg *ipn.Notify) bool {
				n.noteBackend(msg)
				return n.ctx.Err() == nil
			})
		} else {
			lc, err := n.srv.LocalClient()
			if err != nil {
				return
			}
			if w, err := lc.WatchIPNBus(n.ctx, 0); err == nil {
				for {
					msg, err := w.Next()
					if err != nil {
						break
					}
					n.noteBackend(&msg)
				}
				w.Close()
			}
		}
		select {
		case <-n.ctx.Done():
		case <-time.After(time.Second):
		}
	}
}

// ipnBusFellBehind is the ErrMessage the backend sends before closing a
// watcher that fell behind; it is not a backend error.
const ipnBusFellBehind = "IPN bus consumer fell behind; closing watch"

func (n *Node) noteBackend(msg *ipn.Notify) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if msg.ErrMessage != nil && *msg.ErrMessage != n.backendErr && *msg.ErrMessage != ipnBusFellBehind {
		n.backendErr = *msg.ErrMessage
		n.logger.Printf("warn: backend: %s", n.backendErr)
		n.events.Log("warn", "backend: %s", n.backendErr)
	}
	if msg.State != nil && *msg.State == ipn.Running {
		n.backendErr = ""
	}
}

// publicState maps the raw ipn state to the protocol's backendState
// (Stopped, Starting, NeedsLogin, NeedsMachineAuth, Running, Error) and the
// errorMessage that goes with "Error".
func publicState(raw, backendErr, listenErr string) (string, string) {
	switch {
	case backendErr != "" && raw != "Running":
		return "Error", backendErr
	case raw == "InUseOtherUser":
		return "Error", "다른 사용자가 이 노드를 쓰고 있습니다."
	case raw == "Running" && listenErr != "":
		return "Error", listenErr
	}
	switch raw {
	case "Stopped", "Starting", "NeedsLogin", "NeedsMachineAuth", "Running":
		return raw, ""
	}
	return "Starting", "" // NoState and anything unknown
}

// needLoginKick reports whether to call StartLoginInteractive: the backend
// wants a login, has no URL to show (e.g. the node key expired), no auth key
// can log in by itself, and the last kick was long enough ago.
func needLoginKick(raw, authURL string, hasAuthKey bool, last, now time.Time) bool {
	return raw == "NeedsLogin" && authURL == "" && !hasAuthKey && now.Sub(last) >= loginKickInterval
}

// tsLogf receives tsnet logs; they go to logPath only.
func (n *Node) tsLogf(format string, args ...any) {
	n.logger.Printf("tsnet: "+format, args...)
}

// logf writes our own diagnostic messages to logPath and the event queue.
// logLockStatus writes the tailnet lock state once per start, as booleans and counts only
// (no keys, hashes or names). It is a diagnostic for comparing with other tailnet clients.
func (n *Node) logLockStatus(lc *local.Client) {
	ctx, cancel := context.WithTimeout(n.ctx, 3*time.Second)
	defer cancel()
	ls, err := lc.NetworkLockStatus(ctx)
	if err != nil {
		n.logf("info", "tailnet lock: status unavailable: %v", err)
		return
	}
	n.logf("info", "tailnet lock: enabled=%t headEmpty=%t nodeKeySigned=%t trustedKeys=%d filteredPeers=%d",
		ls.Enabled, ls.Head == nil, ls.NodeKeySigned, len(ls.TrustedKeys), len(ls.FilteredPeers))
}

func (n *Node) logf(level, format string, args ...any) {
	n.logger.Printf(level+": "+format, args...)
	n.events.Log(level, format, args...)
}

func (n *Node) closeLog() {
	if n.logOut != nil {
		n.logOut.Close()
	}
}

// Events returns the node's event queue.
func (n *Node) Events() *events.Queue { return n.events }

// Host returns the host state, or nil in proxy mode.
func (n *Node) Host() *host.Host { return n.host }

// Config returns the validated configuration.
func (n *Node) Config() *Config { return n.cfg }

func (n *Node) whois(ctx context.Context, remoteAddr string) (host.Peer, error) {
	lc, err := n.srv.LocalClient()
	if err != nil {
		return host.Peer{}, err
	}
	who, err := lc.WhoIs(ctx, remoteAddr)
	if err != nil {
		return host.Peer{}, err
	}
	if who.Node == nil || who.Node.StableID == "" {
		return host.Peer{}, errors.New("whois: no node")
	}
	p := host.Peer{StableID: string(who.Node.StableID), NodeName: shortName(who.Node.Name)}
	if p.NodeName == "" {
		p.NodeName = who.Node.ComputedName
	}
	if who.UserProfile != nil {
		p.LoginName = who.UserProfile.LoginName
	}
	return p, nil
}

func shortName(fqdn string) string {
	name, _, _ := strings.Cut(strings.TrimSuffix(fqdn, "."), ".")
	return name
}

func (n *Node) info() host.Info {
	n.mu.Lock()
	defer n.mu.Unlock()
	hostID := ids.HostID(n.selfID)
	if n.selfID == "" && n.directID != nil && n.directID.HostID() != "" {
		// The direct listener answers before the tailnet node is up.
		hostID = n.directID.HostID()
	}
	return host.Info{
		HostID:     hostID,
		HostName:   n.cfg.HostDisplayName,
		FQDN:       n.fqdn,
		AppVersion: n.cfg.AppVersion,
	}
}

func (n *Node) baseURL() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return host.BaseURL(n.cfg.TLS(), n.fqdn, n.cfg.Port)
}

// monitor polls the backend, starts the host listener once Running, sweeps
// expired host state and emits "state" events on change.
func (n *Node) monitor() {
	defer close(n.done)
	t := time.NewTimer(0)
	defer t.Stop()
	var dead <-chan struct{}
	if n.tun != nil {
		dead = n.tun.Dead()
	}
	for {
		select {
		case <-n.ctx.Done():
			return
		case <-t.C:
		case <-dead:
			// The engine closed by itself (TUN read error). The extension
			// cancels the tunnel; the container app reconnects it
			// (docs/tunnel.md). Handled once: dead is nil from here on.
			dead = nil
			n.mu.Lock()
			n.tunErr = tunDeadMessage
			n.mu.Unlock()
			n.logf("error", "%s", tunDeadMessage)
		}
		n.refresh()
		n.kickLogin()
		if n.host != nil {
			n.host.Sweep()
			n.mu.Lock()
			need := n.backend == "Running" && !n.listening
			n.mu.Unlock()
			if need {
				n.startHostListener()
			}
		}
		st := n.Status()
		st.RSSMiB = 0
		n.mu.Lock()
		changed := !reflect.DeepEqual(st, n.lastEmit)
		n.lastEmit = st
		running := n.backend == "Running"
		n.mu.Unlock()
		if changed {
			n.events.Push(events.Event{"type": "state", "status": n.Status()})
		}
		interval := 250 * time.Millisecond // fast until Running
		if running {
			interval = 2 * time.Second
		}
		t.Reset(interval)
	}
}

func (n *Node) refresh() {
	var (
		st    *ipnstate.Status
		peers int
	)
	var (
		path  *PeerPath
		paths map[string]PeerPath
	)
	if n.tun != nil {
		n.mu.Lock()
		target := n.pathPeer
		n.mu.Unlock()
		if target != "" {
			// One status with peers replaces the netmap copy of PeerCount.
			st = n.tun.FullStatus()
			peers = len(st.Peer)
			path = pathToName(st, target)
		} else {
			st = n.tun.LocalStatus()
			peers = n.tun.PeerCount() // the only netmap copy per tick
		}
	} else {
		lc, err := n.srv.LocalClient()
		if err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(n.ctx, 2*time.Second)
		defer cancel()
		var ids []string
		if n.host != nil {
			ids = n.host.DeviceStableIDs()
		}
		if len(ids) > 0 {
			st, err = lc.Status(ctx)
		} else {
			st, err = lc.StatusWithoutPeers(ctx)
		}
		if err != nil {
			return
		}
		paths = pathsToDevices(st, ids)
		if st.BackendState == "Running" {
			n.lockDiag.Do(func() { n.logLockStatus(lc) })
		}
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	n.peerCount = peers
	n.peerPath = path
	n.peerPaths = paths
	n.backend = st.BackendState
	n.authURL = st.AuthURL
	n.ips = n.ips[:0]
	for _, ip := range st.TailscaleIPs {
		n.ips = append(n.ips, ip.String())
	}
	n.certs = append(n.certs[:0], st.CertDomains...)
	if st.Self != nil {
		n.fqdn = strings.TrimSuffix(st.Self.DNSName, ".")
		n.selfID = string(st.Self.ID)
	}
	if n.directID != nil && n.selfID != "" {
		n.directID.SetHostID(ids.HostID(n.selfID))
	}
}

// SetDirect turns the same-network listener on or off (host mode,
// docs/protocol-addenda.md O). It does not depend on the tailnet state.
func (n *Node) SetDirect(on bool) error {
	if n.host == nil {
		return apierr.InvalidConfig("host 모드가 아닙니다.")
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if !on {
		if n.directSrv != nil {
			n.directSrv.Close()
			n.directSrv = nil
		}
		return nil
	}
	if n.closed {
		return apierr.NotRunning("노드가 종료되었습니다.")
	}
	if n.directSrv != nil {
		return nil
	}
	if n.directID == nil {
		id, err := direct.Load(n.cfg.StateDir)
		if err != nil {
			return apierr.Internal("직접 연결 키를 준비하지 못했습니다: " + err.Error())
		}
		n.directID = id
		if n.selfID != "" {
			id.SetHostID(ids.HostID(n.selfID))
		}
	}
	ln, err := n.directID.Listen(n.directOpt)
	if err != nil {
		return apierr.Internal("직접 연결 포트를 열지 못했습니다: " + err.Error())
	}
	n.directSrv = &http.Server{
		Handler:           n.host.DirectHandler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          log.New(io.Discard, "", 0),
	}
	go n.directSrv.Serve(ln)
	return nil
}

// directInfo tells the host what an enrolling device needs to reach the
// direct listener; false while it is off.
func (n *Node) directInfo() (host.DirectInfo, bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.directSrv == nil || n.directID == nil {
		return host.DirectInfo{}, false
	}
	return host.DirectInfo{ID: n.directID.ID(), Port: n.directID.Port(), SPKI: n.directID.SPKI()}, true
}

func (n *Node) kickLogin() {
	n.mu.Lock()
	now := time.Now()
	kick := needLoginKick(n.backend, n.authURL, n.cfg.AuthKey != "", n.loginKick, now)
	if kick {
		n.loginKick = now
	}
	n.mu.Unlock()
	if !kick {
		return
	}
	ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
	defer cancel()
	var err error
	if n.tun != nil {
		err = n.tun.Login(ctx) // recovers StartLoginInteractive's panic
	} else {
		var lc *local.Client
		if lc, err = n.srv.LocalClient(); err != nil {
			return
		}
		err = lc.StartLoginInteractive(ctx)
	}
	if err != nil {
		n.logf("warn", "로그인을 시작하지 못했습니다: %v", err)
	}
}

func (n *Node) startHostListener() {
	var (
		ln  net.Listener
		err error
	)
	if n.cfg.TLS() {
		ctx, cancel := context.WithTimeout(n.ctx, listenTLSTimeout)
		ln, err = listenTLSFunc(ctx, n.srv, n.cfg.Port)
		cancel()
	} else {
		ln, err = n.srv.Listen("tcp", fmt.Sprintf(":%d", n.cfg.Port))
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if err != nil {
		n.listenFails++
		msg := "host listener: " + err.Error()
		if n.listenFails >= listenFailLimit {
			n.listenErr = msg
		}
		if msg != n.lastErr {
			n.lastErr = msg
			n.logger.Printf("warn: %s", msg)
			n.events.Log("warn", "%s", msg)
		}
		return
	}
	n.listenFails, n.listenErr = 0, ""
	if n.closed {
		ln.Close()
		return
	}
	n.httpSrv = &http.Server{
		Handler:           n.host.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          log.New(io.Discard, "", 0),
	}
	go n.httpSrv.Serve(ln)
	n.listening = true
	if n.cfg.TLS() {
		go n.certLoop()
	}
}

// certLoop fetches the MagicDNS certificate so tlsReady reflects reality. It
// retries with backoff (certRetryMin doubling up to certRetryMax) while the
// node is Running, until it succeeds or the node stops.
func (n *Node) certLoop() {
	delay := n.certRetryMin
	for {
		n.mu.Lock()
		fqdn, running := n.fqdn, n.backend == "Running"
		n.mu.Unlock()
		wait := n.certRetryMin
		if running {
			ctx, cancel := context.WithTimeout(n.ctx, 2*time.Minute)
			err := n.certFn(ctx, fqdn)
			cancel()
			if err == nil {
				n.mu.Lock()
				n.tlsReady = true
				n.mu.Unlock()
				return
			}
			if n.ctx.Err() != nil {
				return
			}
			n.logf("warn", "TLS 인증서를 받지 못했습니다(%s 뒤 다시 시도): %v", delay, err)
			wait, delay = delay, min(delay*2, n.certRetryMax)
		}
		t := time.NewTimer(wait)
		select {
		case <-n.ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

// Status returns the current status snapshot.
func (n *Node) Status() Status {
	n.mu.Lock()
	state, errMsg := publicState(n.backend, n.backendErr, n.listenErr)
	st := Status{
		BackendState: state,
		ErrorMessage: errMsg,
		AuthURL:      n.authURL,
		Hostname:     n.cfg.Hostname,
		FQDN:         n.fqdn,
		TailscaleIPs: append([]string{}, n.ips...),
		CertDomains:  append([]string{}, n.certs...),
		TLSReady:     n.tlsReady,
		Listening:    n.listening || n.proxyAddr != "",
	}
	if n.tunErr != "" {
		st.BackendState, st.ErrorMessage = "Error", n.tunErr
	}
	if n.closed {
		st.BackendState, st.ErrorMessage = "Stopped", ""
	}
	if n.directID != nil {
		st.Direct = &DirectStatus{Listening: n.directSrv != nil && !n.closed, Port: n.directID.Port(), ID: n.directID.ID()}
	}
	peers := n.peerCount
	if n.peerPath != nil && st.BackendState == "Running" {
		p := *n.peerPath
		st.PeerPath = &p
	}
	if len(n.peerPaths) > 0 && st.BackendState == "Running" {
		st.PeerPaths = make(map[string]PeerPath, len(n.peerPaths))
		for id, p := range n.peerPaths {
			st.PeerPaths[id] = p
		}
	}
	n.mu.Unlock()
	if n.tun != nil {
		ts := &TunnelStatus{Addresses: []string{}, Routes: []string{}, DNSServers: []string{}, DNSMatchDomains: []string{}, MTU: n.cfg.MTU, PeerCount: peers}
		if s, ok := n.tun.Settings(); ok {
			ts.Addresses, ts.Routes, ts.DNSServers, ts.DNSMatchDomains, ts.MTU = s.Addresses, s.Routes, s.DNSServers, s.DNSMatchDomains, s.MTU
		}
		st.Tunnel = ts
	}
	if st.BackendState != "NeedsLogin" {
		st.AuthURL = ""
	}
	if n.host != nil {
		st.PublishedBuilds, st.PairedDevices = n.host.Counts()
	}
	st.RSSMiB = memstat.RSSMiB()
	return st
}

// SetPathPeer sets the MagicDNS name of the peer whose path the tunnel node
// reports as status.peerPath ("" stops reporting). The path appears after the
// next status refresh.
func (n *Node) SetPathPeer(fqdn string) {
	name := normalName(fqdn)
	n.mu.Lock()
	if n.pathPeer != name {
		n.pathPeer = name
		n.peerPath = nil
	}
	n.mu.Unlock()
}

// SetDefaultInterface passes the device's default interface to the tunnel
// engine (tunnel mode; ignored otherwise and after Close).
func (n *Node) SetDefaultInterface(name string) {
	if n.tun != nil {
		n.tun.SetDefaultInterface(name)
	}
}

// StartProxy starts the loopback CONNECT proxy (proxy mode only).
func (n *Node) StartProxy(listenAddr string) (string, error) {
	if n.cfg.Mode != "proxy" {
		return "", apierr.InvalidConfig("rd_proxy_start는 proxy 모드에서만 쓸 수 있습니다.")
	}
	h, _, err := net.SplitHostPort(listenAddr)
	if err != nil || !IsLoopbackHost(h) {
		return "", apierr.InvalidConfig("프록시는 루프백 주소에서만 열 수 있습니다.")
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.closed {
		return "", apierr.NotRunning("노드가 종료되었습니다.")
	}
	if n.prx != nil {
		return n.proxyAddr, nil
	}
	p := proxy.New(n.srv.Dial, n.cfg.AllowedTargets, n.magicSuffix, func(f string, a ...any) { n.logger.Printf("proxy: "+f, a...) })
	addr, err := p.Serve(listenAddr)
	if err != nil {
		return "", apierr.InvalidConfig("프록시를 열 수 없습니다: " + err.Error())
	}
	n.prx, n.proxyAddr = p, addr
	return addr, nil
}

// magicSuffix returns the node's MagicDNS suffix ("" before it is known).
func (n *Node) magicSuffix() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	_, suffix, _ := strings.Cut(n.fqdn, ".")
	return suffix
}

// Close stops listeners and the node. It never waits on the backend: every
// backend call made by the monitor is bounded by n.ctx. In tunnel mode the
// engine closes the TUN device (only Go's duplicate of utunFd).
func (n *Node) Close() error {
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return nil
	}
	n.closed = true
	hs, prx := n.httpSrv, n.prx
	ds := n.directSrv
	n.directSrv = nil
	n.mu.Unlock()

	n.cancel()
	<-n.done
	if n.host != nil {
		n.host.Close() // fails open sessions, aborts transfers, removes snapshots
	}
	if hs != nil {
		hs.Close()
	}
	if ds != nil {
		ds.Close()
	}
	if prx != nil {
		prx.Close()
	}
	var err error
	if n.tun != nil {
		<-n.watchDone // bounded by n.ctx
		n.tun.Close()
		releaseTunnel()
	} else {
		err = n.srv.Close()
	}
	n.events.Close()
	n.closeLog()
	return err
}
