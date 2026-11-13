// Package tunnel assembles a Tailscale node whose TUN is the iOS Network
// Extension's utun (docs/tunnel.md): ipnlocal.LocalBackend + the userspace
// WireGuard engine + netstack (MagicDNS at 100.100.100.100 only).
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"

	"github.com/tailscale/wireguard-go/tun"

	"tailscale.com/control/controlclient"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/ipn/store"
	"tailscale.com/net/netmon"
	"tailscale.com/net/tsdial"
	"tailscale.com/tsd"
	"tailscale.com/types/logger"
	"tailscale.com/types/logid"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/netstack"
)

// Config configures Start.
type Config struct {
	StateDir   string
	Hostname   string
	ControlURL string
	AuthKey    string // secret: never log
	Ephemeral  bool
	MTU        int

	// Tun is the device. Start owns it from the call on: it is closed on any
	// error and, after a successful Start, by the engine on Close.
	Tun tun.Device
	// MarkUTUN marks Tun's interface as the Tailscale interface for netmon
	// (process-global). Only for a real utun, never for an in-memory device.
	MarkUTUN bool

	Logf logger.Logf // nil means discard
	// OnSettings receives every changed Settings. It runs under engine and
	// LocalBackend locks: it must not block or call back into the node.
	OnSettings func(Settings)
}

// Node is a running tunnel-mode Tailscale node.
type Node struct {
	sys    *tsd.System
	netMon *netmon.Monitor
	dialer *tsdial.Dialer
	ns     *netstack.Impl
	lb     *ipnlocal.LocalBackend
	eng    wgengine.Engine
	sink   *sink

	ifMu      sync.Mutex
	defaultIf string // last name given to SetDefaultInterface

	closeOnce sync.Once
}

// Start assembles and starts the node. The backend logs in in the background.
func Start(ctx context.Context, cfg Config) (_ *Node, err error) {
	if cfg.Tun == nil {
		return nil, errors.New("tunnel: no TUN device")
	}
	logf := cfg.Logf
	if logf == nil {
		logf = logger.Discard
	}
	n := &Node{sink: &sink{mtu: cfg.MTU, emit: cfg.OnSettings}}
	n.sys = tsd.NewSystem()
	defer func() {
		if err != nil {
			n.Close()
			cfg.Tun.Close() // idempotent; the engine may already have closed it
		}
	}()

	if cfg.MarkUTUN {
		// Must precede netmon.New: on GOOS=ios netmon does not recognize a
		// utun as the Tailscale interface by itself.
		if name, err := cfg.Tun.Name(); err == nil {
			netmon.SetTailscaleInterfaceProps(name, 0)
		}
	}
	n.netMon, err = netmon.New(n.sys.Bus.Get(), logf)
	if err != nil {
		return nil, fmt.Errorf("netmon: %w", err)
	}
	n.dialer = &tsdial.Dialer{Logf: logf}
	n.dialer.SetBus(n.sys.Bus.Get())

	eng, err := wgengine.NewUserspaceEngine(logf, wgengine.Config{
		Tun:            cfg.Tun,
		Router:         n.sink.router(),
		DNS:            n.sink.osConfigurator(),
		ReconfigureVPN: n.sink.reconfigureVPN,
		EventBus:       n.sys.Bus.Get(),
		NetMon:         n.netMon,
		Dialer:         n.dialer,
		SetSubsystem:   n.sys.Set,
		ControlKnobs:   n.sys.ControlKnobs(),
		HealthTracker:  n.sys.HealthTracker.Get(),
		Metrics:        n.sys.UserMetricsRegistry(),
	})
	if err != nil {
		return nil, fmt.Errorf("engine: %w", err)
	}
	n.eng = eng
	n.sys.Set(&dnsTap{Engine: eng, sink: n.sink}) // LocalBackend reconfigures through the tap
	n.sys.HealthTracker.Get().SetMetricsRegistry(n.sys.UserMetricsRegistry())
	if m, ok := n.sys.DNSManager.GetOK(); ok {
		if err := registerNoUpstream(m); err != nil {
			return nil, fmt.Errorf("dns: %w", err)
		}
	}

	// netstack only answers quad-100 (MagicDNS); every other packet goes
	// through the TUN.
	n.ns, err = netstack.Create(logf, n.sys.Tun.Get(), eng, n.sys.MagicSock.Get(), n.dialer, n.sys.DNSManager.Get(), n.sys.ProxyMapper())
	if err != nil {
		return nil, fmt.Errorf("netstack: %w", err)
	}
	n.ns.ProcessLocalIPs = false
	n.ns.ProcessSubnets = false
	n.sys.Set(n.ns)

	// File store: node key, IPs and StableID survive extension restarts.
	st, err := store.New(logf, filepath.Join(cfg.StateDir, "tailscaled.state"))
	if err != nil {
		return nil, fmt.Errorf("state store: %w", err)
	}
	n.sys.Set(st)
	n.sys.Tun.Get().Start()

	flags := controlclient.LoginDefault
	if cfg.Ephemeral {
		flags = controlclient.LoginEphemeral
	}
	n.lb, err = ipnlocal.NewLocalBackend(logf, logid.PublicID{}, n.sys, flags|controlclient.LocalBackendStartKeyOSNeutral)
	if err != nil {
		return nil, fmt.Errorf("backend: %w", err)
	}
	n.lb.SetVarRoot(cfg.StateDir)
	if err := n.ns.Start(n.lb); err != nil {
		return nil, fmt.Errorf("netstack start: %w", err)
	}

	p := ipn.NewPrefs()
	p.Hostname = cfg.Hostname
	p.ControlURL = cfg.ControlURL
	p.WantRunning = true
	p.CorpDNS = true
	p.RouteAll = false // no subnet routes or exit nodes; defaults to true on iOS
	if err := n.lb.Start(ipn.Options{UpdatePrefs: p, AuthKey: cfg.AuthKey}); err != nil {
		return nil, fmt.Errorf("backend start: %w", err)
	}
	if n.lb.State() == ipn.NeedsLogin {
		if err := n.Login(ctx); err != nil {
			return nil, err
		}
	}
	return n, nil
}

// Login starts an interactive login (fills AuthURL). StartLoginInteractive
// panics when the backend has no control client; that panic is returned as
// an error instead of killing the extension.
func (n *Node) Login(ctx context.Context) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("login: %v", r)
		}
	}()
	return n.lb.StartLoginInteractive(ctx)
}

// LocalStatus returns the backend status without peers.
func (n *Node) LocalStatus() *ipnstate.Status { return n.lb.StatusWithoutPeers() }

// FullStatus returns the backend status with peers (their current address
// and relay). It is heavier than LocalStatus: call it only when a peer's path
// is wanted.
func (n *Node) FullStatus() *ipnstate.Status { return n.lb.Status() }

// PeerCount returns the number of peers in the current netmap. It copies the
// netmap: call it at most once per status poll.
func (n *Node) PeerCount() int {
	nm := n.lb.NetMapWithPeers()
	if nm == nil {
		return 0
	}
	return len(nm.Peers)
}

// Settings returns the last emitted settings.
func (n *Node) Settings() (Settings, bool) { return n.sink.settings() }

// Watch calls fn for each backend notification until ctx ends, fn returns
// false or the backend closes the watch. fn must not block.
func (n *Node) Watch(ctx context.Context, fn func(*ipn.Notify) bool) {
	n.lb.WatchNotifications(ctx, 0, nil, fn)
}

// SetDefaultInterface tells netmon which interface now carries the device's
// default route (NWPathMonitor; the Network Extension never updates its
// delegate interface after the tunnel is created). "" is ignored. When the
// name changes, netmon re-evaluates the network at once, so a changed
// default interface rebinds magicsock's sockets and reconnects DERP and
// control instead of waiting for an unrelated route event.
func (n *Node) SetDefaultInterface(name string) {
	if name == "" {
		return
	}
	n.ifMu.Lock()
	changed := name != n.defaultIf
	n.defaultIf = name
	n.ifMu.Unlock()
	setLastKnownDefaultInterface(name)
	if changed && n.netMon != nil {
		n.netMon.InjectEvent()
	}
}

// Dead is closed when the engine has stopped, including on its own after a
// TUN read error (wireguard-go closes the device; LocalBackend still says
// Running).
func (n *Node) Dead() <-chan struct{} { return n.eng.Done() }

// Close stops the node (tsnet's order). The engine closes the TUN device.
// It is idempotent.
func (n *Node) Close() {
	n.closeOnce.Do(func() {
		if n.ns != nil {
			n.ns.Close()
		}
		if n.lb != nil {
			n.lb.Shutdown() // closes the engine and the TUN
		} else if n.eng != nil {
			n.eng.Close()
		}
		if n.netMon != nil {
			n.netMon.Close()
		}
		if n.dialer != nil {
			n.dialer.Close()
		}
		if bus, ok := n.sys.Bus.GetOK(); ok && bus != nil {
			bus.Close()
		}
	})
}
