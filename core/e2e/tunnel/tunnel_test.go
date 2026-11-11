package tunnel_test

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"tailscale.com/ipn/store/mem"
	"tailscale.com/net/netns"
	"tailscale.com/net/packet"
	"tailscale.com/tsnet"
	"tailscale.com/tstest"
	"tailscale.com/types/ipproto"

	"remotedebug/core/internal/api"
	"remotedebug/core/internal/faketailnet"
	"remotedebug/core/internal/faketun"
	"remotedebug/core/internal/node"
)

// tunnelStatus mirrors node.Status for the fields these tests read.
type tunnelStatus struct {
	BackendState string   `json:"backendState"`
	ErrorMessage string   `json:"errorMessage"`
	TailscaleIPs []string `json:"tailscaleIPs"`
	Tunnel       *struct {
		settings
		PeerCount int `json:"peerCount"`
	} `json:"tunnel"`
}

type settings struct {
	Type            string   `json:"type"`
	Addresses       []string `json:"addresses"`
	Routes          []string `json:"routes"`
	DNSServers      []string `json:"dnsServers"`
	DNSMatchDomains []string `json:"dnsMatchDomains"`
	MTU             int      `json:"mtu"`
}

func status(t *testing.T, h int64) tunnelStatus {
	t.Helper()
	var st tunnelStatus
	if err := json.Unmarshal([]byte(api.Status(h)), &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func startTunnel(t *testing.T, controlURL string, ft *faketun.Device) int64 {
	t.Helper()
	return startTunnelIn(t, filepath.Join(t.TempDir(), "state"), controlURL, ft)
}

func startTunnelIn(t *testing.T, stateDir, controlURL string, ft *faketun.Device) int64 {
	t.Helper()
	cfg, _ := json.Marshal(map[string]any{
		"mode": "tunnel", "stateDir": stateDir, "hostname": "rd-phone-tun00001",
		"controlURL": controlURL, "mtu": 1280, "listenTLS": false,
	})
	out := api.StartWithOptions(string(cfg), node.Options{Tun: ft})
	var started struct{ Handle int64 }
	json.Unmarshal([]byte(out), &started)
	if started.Handle == 0 {
		t.Fatalf("start: %s", out)
	}
	t.Cleanup(func() { api.Stop(started.Handle) })
	return started.Handle
}

// covers reports whether one of the CIDRs contains ip.
func covers(cidrs []string, ip netip.Addr) bool {
	for _, c := range cidrs {
		if p, err := netip.ParsePrefix(c); err == nil && p.Contains(ip) {
			return true
		}
	}
	return false
}

// exchange injects pkt every second until a packet matching want comes out
// of the TUN; the first packets can race the peer path setup.
func exchange(t *testing.T, ft *faketun.Device, what string, pkt []byte, want func(*packet.Parsed) bool) *packet.Parsed {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		ft.FromOS <- pkt
		wait := time.After(time.Second)
	read:
		for {
			select {
			case b, ok := <-ft.ToOS:
				if !ok {
					t.Fatalf("%s: TUN closed", what)
				}
				p := new(packet.Parsed)
				p.Decode(b)
				if want(p) {
					return p
				}
			case <-wait:
				break read
			}
		}
	}
	t.Fatalf("%s: no reply", what)
	return nil
}

func udp4(src, dst netip.AddrPort, payload []byte) []byte {
	return packet.Generate(packet.UDP4Header{
		IP4Header: packet.IP4Header{Src: src.Addr(), Dst: dst.Addr(), IPID: 1},
		SrcPort:   src.Port(), DstPort: dst.Port(),
	}, payload)
}

func csum(b []byte, sum uint32) uint16 {
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(b[i:]))
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}

// tcp4SYN builds an IPv4 TCP SYN without options (net/packet has no TCP
// builder).
func tcp4SYN(src, dst netip.AddrPort, seq uint32) []byte {
	b := make([]byte, 40)
	b[0] = 0x45
	binary.BigEndian.PutUint16(b[2:], 40)
	binary.BigEndian.PutUint16(b[4:], 2)
	b[8], b[9] = 64, 6
	s4, d4 := src.Addr().As4(), dst.Addr().As4()
	copy(b[12:16], s4[:])
	copy(b[16:20], d4[:])
	binary.BigEndian.PutUint16(b[10:], csum(b[:20], 0))
	tcp := b[20:]
	binary.BigEndian.PutUint16(tcp[0:], src.Port())
	binary.BigEndian.PutUint16(tcp[2:], dst.Port())
	binary.BigEndian.PutUint32(tcp[4:], seq)
	tcp[12] = 5 << 4
	tcp[13] = 0x02 // SYN
	binary.BigEndian.PutUint16(tcp[14:], 64240)
	var pseudo uint32
	pseudo += uint32(binary.BigEndian.Uint16(s4[0:])) + uint32(binary.BigEndian.Uint16(s4[2:]))
	pseudo += uint32(binary.BigEndian.Uint16(d4[0:])) + uint32(binary.BigEndian.Uint16(d4[2:]))
	pseudo += 6 + 20
	binary.BigEndian.PutUint16(tcp[16:], csum(tcp, pseudo))
	return b
}

func dnsQueryA(name string) []byte {
	msg := dnsmessage.Message{
		Header:    dnsmessage.Header{ID: 0x1234, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}},
	}
	b, err := msg.Pack()
	if err != nil {
		panic(err)
	}
	return b
}

// startPeer starts a tsnet peer with a UDP echo on :7000 and a TCP accept on
// :7001. It returns the peer's IPv4 address and MagicDNS name.
func startPeer(t *testing.T, ctx context.Context, controlURL string) (netip.Addr, string) {
	t.Helper()
	discard := func(string, ...any) {}
	srv := &tsnet.Server{Dir: t.TempDir(), Hostname: "rd-peer", ControlURL: controlURL, Ephemeral: true,
		Store: new(mem.Store), UserLogf: discard, Logf: discard}
	t.Cleanup(func() { srv.Close() })
	st, err := srv.Up(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ip := st.TailscaleIPs[0]
	pc, err := srv.ListenPacket("udp", netip.AddrPortFrom(ip, 7000).String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			pc.WriteTo(append([]byte("echo:"), buf[:n]...), from)
		}
	}()
	ln, err := srv.Listen("tcp", ":7001")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return ip, st.Self.DNSName
}

// TestTunnelDataPath is docs/tunnel.md's test contract 1-6 on one fake
// tailnet: settings event, UDP, TCP, MagicDNS, stop and cleanup.
func TestTunnelDataPath(t *testing.T) {
	tstest.ResourceCheck(t) // goroutines are back to the start count after all cleanups
	netns.SetEnabled(false) // as tsnet's tests: no binding to the Mac's default interface
	t.Cleanup(func() { netns.SetEnabled(true) })
	env, err := faketailnet.Start(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(env.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	peerIP, peerFQDN := startPeer(t, ctx, env.ControlURL)
	ft := faketun.New()
	h := startTunnel(t, env.ControlURL, ft)

	var ev settings
	var selfIP netip.Addr
	t.Run("network-settings", func(t *testing.T) {
		deadline := time.Now().Add(60 * time.Second)
		for time.Now().Before(deadline) {
			var out struct {
				Event json.RawMessage `json:"event"`
			}
			json.Unmarshal([]byte(api.NextEvent(h, 500)), &out)
			var e settings
			if json.Unmarshal(out.Event, &e) == nil && e.Type == "network-settings" {
				ev = e
			}
			st := status(t, h)
			if st.BackendState != "Running" || len(st.TailscaleIPs) == 0 || ev.Type == "" || !covers(ev.Routes, peerIP) {
				continue
			}
			selfIP = netip.MustParseAddr(st.TailscaleIPs[0])
			break
		}
		if !selfIP.IsValid() {
			t.Fatalf("no Running node with settings covering the peer; last %+v", ev)
		}
		t.Logf("settings: addresses %v routes %v dns %v", ev.Addresses, ev.Routes, ev.DNSServers)
		if !slices.Contains(ev.Addresses, selfIP.String()+"/32") || ev.MTU != 1280 {
			t.Fatalf("settings %+v", ev)
		}
		if len(ev.DNSServers) == 0 || ev.DNSServers[0] != "100.100.100.100" || !slices.Contains(ev.DNSMatchDomains, faketailnet.MagicDNSDomain) {
			t.Fatalf("dns settings %+v", ev)
		}
		for _, d := range ev.DNSMatchDomains {
			if strings.HasSuffix(d, ".") {
				t.Fatalf("match domain with trailing dot: %q", d)
			}
		}
		// status.tunnel mirrors the last settings and counts the peer.
		deadline = time.Now().Add(20 * time.Second)
		for {
			st := status(t, h)
			if st.Tunnel != nil && st.Tunnel.PeerCount >= 1 && slices.Equal(st.Tunnel.Addresses, ev.Addresses) &&
				slices.Equal(st.Tunnel.DNSServers, ev.DNSServers) && covers(st.Tunnel.Routes, peerIP) && st.Tunnel.MTU == 1280 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("status.tunnel %+v", st.Tunnel)
			}
			time.Sleep(100 * time.Millisecond)
		}
	})
	if t.Failed() {
		return
	}

	t.Run("udp", func(t *testing.T) {
		src, dst := netip.AddrPortFrom(selfIP, 40000), netip.AddrPortFrom(peerIP, 7000)
		p := exchange(t, ft, "udp echo", udp4(src, dst, []byte("hello")), func(p *packet.Parsed) bool {
			return p.IPProto == ipproto.UDP && p.Src == dst && p.Dst == src
		})
		if got := string(p.Payload()); got != "echo:hello" {
			t.Fatalf("payload %q", got)
		}
	})

	t.Run("tcp", func(t *testing.T) {
		src, dst := netip.AddrPortFrom(selfIP, 40001), netip.AddrPortFrom(peerIP, 7001)
		exchange(t, ft, "SYN-ACK", tcp4SYN(src, dst, 1000), func(p *packet.Parsed) bool {
			return p.IPProto == ipproto.TCP && p.Src == dst && p.Dst == src && p.TCPFlags&packet.TCPSynAck == packet.TCPSynAck
		})
	})

	t.Run("magicdns", func(t *testing.T) {
		src, q100 := netip.AddrPortFrom(selfIP, 40002), netip.MustParseAddrPort("100.100.100.100:53")
		p := exchange(t, ft, "dns answer", udp4(src, q100, dnsQueryA(peerFQDN)), func(p *packet.Parsed) bool {
			return p.IPProto == ipproto.UDP && p.Src == q100 && p.Dst == src
		})
		var m dnsmessage.Message
		if err := m.Unpack(p.Payload()); err != nil {
			t.Fatal(err)
		}
		if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) == 0 {
			t.Fatalf("rcode %v, %d answers", m.RCode, len(m.Answers))
		}
		a, ok := m.Answers[0].Body.(*dnsmessage.AResource)
		if !ok || netip.AddrFrom4(a.A) != peerIP {
			t.Fatalf("answer %v, want %v", m.Answers[0].Body, peerIP)
		}
	})

	t.Run("stop", func(t *testing.T) {
		if out := api.Stop(h); out != `{"ok":true}` {
			t.Fatalf("stop: %s", out)
		}
		select {
		case <-ft.Closed(): // the engine closed the device (Go's utun duplicate)
		case <-time.After(5 * time.Second):
			t.Fatal("TUN not closed")
		}
		if out := api.NextEvent(h, 0); !strings.Contains(out, "unknown_handle") {
			t.Fatalf("after stop: %s", out)
		}
	})
}

// deadControl is a loopback control URL where nothing listens.
const deadControl = "http://127.0.0.1:1"

// TestTunnelEngineDeath: when the TUN read fails, wireguard-go closes the
// device and the engine; status turns Error and a state event says so.
func TestTunnelEngineDeath(t *testing.T) {
	tstest.ResourceCheck(t)
	ft := faketun.New()
	h := startTunnel(t, deadControl, ft)
	if st := status(t, h); st.BackendState == "Error" {
		t.Fatalf("Error before the TUN failed: %+v", st)
	}
	ft.FailRead(errors.New("boom"))
	deadline := time.Now().Add(20 * time.Second)
	for {
		var out struct {
			Event *struct {
				Type   string       `json:"type"`
				Status tunnelStatus `json:"status"`
			} `json:"event"`
		}
		json.Unmarshal([]byte(api.NextEvent(h, 500)), &out)
		if e := out.Event; e != nil && e.Type == "state" && e.Status.BackendState == "Error" {
			if e.Status.ErrorMessage != "TUN 장치가 닫혔습니다." {
				t.Fatalf("errorMessage %q", e.Status.ErrorMessage)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no Error state; status %+v", status(t, h))
		}
	}
	select {
	case <-ft.Closed():
	case <-time.After(5 * time.Second):
		t.Fatal("engine did not close the TUN")
	}
	// The monitor handles the engine's death once: no further "error" logs,
	// no queue overflow and only a few events while the status loop keeps
	// running (fast 250 ms ticks: the backend is not Running).
	var events, errorLogs int
	until := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(until) {
		var out struct {
			Event *struct {
				Type    string `json:"type"`
				Level   string `json:"level"`
				Message string `json:"message"`
			} `json:"event"`
		}
		json.Unmarshal([]byte(api.NextEvent(h, 100)), &out)
		e := out.Event
		if e == nil {
			continue
		}
		events++
		if e.Type == "log" && e.Level == "error" {
			errorLogs++
		}
		if strings.Contains(e.Message, "event queue full") {
			t.Fatalf("queue overflowed after the engine died: %s", e.Message)
		}
	}
	if errorLogs != 0 || events > 5 {
		t.Fatalf("after the Error event: %d events, %d error logs", events, errorLogs)
	}
	if st := status(t, h); st.BackendState != "Error" || st.ErrorMessage != "TUN 장치가 닫혔습니다." {
		t.Fatalf("status not sticky: %+v", st)
	}
	if out := api.Stop(h); out != `{"ok":true}` {
		t.Fatalf("stop: %s", out)
	}
}

// TestTunnelRestartKeepsNode: the file state store keeps the node key, so a
// restarted extension comes back as the same node (same IP, no login).
func TestTunnelRestartKeepsNode(t *testing.T) {
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	env, err := faketailnet.Start(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(env.Close)
	dir := filepath.Join(t.TempDir(), "state")
	waitRunning := func(h int64, allowLogin bool) string {
		deadline := time.Now().Add(60 * time.Second)
		for time.Now().Before(deadline) {
			st := status(t, h)
			if st.BackendState == "NeedsLogin" && !allowLogin {
				t.Fatal("restarted node needs a login")
			}
			if st.BackendState == "Running" && len(st.TailscaleIPs) > 0 {
				return st.TailscaleIPs[0]
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatal("not Running")
		return ""
	}
	stop := func(h int64) {
		t.Helper()
		if out := api.Stop(h); out != `{"ok":true}` {
			t.Fatalf("stop: %s", out)
		}
	}
	h := startTunnelIn(t, dir, env.ControlURL, faketun.New())
	ip := waitRunning(h, true)
	stop(h)
	// The identity lives in stateDir/tailscaled.state, nowhere else.
	if fi, err := os.Stat(filepath.Join(dir, "tailscaled.state")); err != nil || fi.Size() == 0 {
		t.Fatalf("state file: %v", err)
	}
	h = startTunnelIn(t, dir, env.ControlURL, faketun.New())
	if again := waitRunning(h, false); again != ip {
		t.Fatalf("IP %s after restart, was %s", again, ip)
	}
	stop(h)
	// Another stateDir is another node: a state file kept anywhere outside
	// stateDir (cwd, temp dir, a fixed path) would bring back the first one.
	other := filepath.Join(t.TempDir(), "state")
	h = startTunnelIn(t, other, env.ControlURL, faketun.New())
	if ip2 := waitRunning(h, true); ip2 == ip {
		t.Fatalf("a fresh stateDir came back as the same node (%s)", ip2)
	}
	stop(h)
	// Moving the directory moves the identity with it.
	moved := filepath.Join(t.TempDir(), "moved")
	if err := os.Rename(dir, moved); err != nil {
		t.Fatal(err)
	}
	h = startTunnelIn(t, moved, env.ControlURL, faketun.New())
	if again := waitRunning(h, false); again != ip {
		t.Fatalf("IP %s from the moved stateDir, was %s", again, ip)
	}
}
