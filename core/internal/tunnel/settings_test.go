package tunnel

import (
	"context"
	"net/netip"
	"slices"
	"sync"
	"testing"
	"time"

	"tailscale.com/net/dns"
	"tailscale.com/util/dnsname"
	"tailscale.com/wgengine/router"
)

func prefixes(ss ...string) []netip.Prefix {
	var out []netip.Prefix
	for _, s := range ss {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}

func addrs(ss ...string) []netip.Addr {
	var out []netip.Addr
	for _, s := range ss {
		out = append(out, netip.MustParseAddr(s))
	}
	return out
}

// Routes are the engine's, filtered to the families the node has; DNS
// servers likewise, IPv4 first; match domains lose the trailing dot.
func TestTunnelSettingsBuild(t *testing.T) {
	v4, v6 := "100.64.0.11/32", "fd7a:115c:a1e0::b/128"
	engineRoutes := prefixes("100.64.0.1/32", "100.64.0.5/32", "100.100.100.100/32", "fd7a:115c:a1e0::1/128", "fd7a:115c:a1e0::53/128", "100.64.0.1/32")
	servers := addrs("fd7a:115c:a1e0::53", "100.100.100.100")
	domains := []dnsname.FQDN{"rd-test.ts.net.", "64.100.in-addr.arpa."}
	cases := []struct {
		name       string
		local      []string
		servers    []netip.Addr
		wantRoutes []string
		wantDNS    []string
	}{
		{"ipv4 only", []string{v4}, servers,
			[]string{"100.64.0.1/32", "100.64.0.5/32", "100.100.100.100/32"},
			[]string{"100.100.100.100"}},
		{"ipv6 only", []string{v6}, servers,
			[]string{"fd7a:115c:a1e0::1/128", "fd7a:115c:a1e0::53/128"},
			[]string{"fd7a:115c:a1e0::53"}},
		{"both", []string{v4, v6}, servers,
			[]string{"100.64.0.1/32", "100.64.0.5/32", "100.100.100.100/32", "fd7a:115c:a1e0::1/128", "fd7a:115c:a1e0::53/128"},
			[]string{"100.100.100.100", "fd7a:115c:a1e0::53"}},
		{"dns empty", []string{v4, v6}, nil,
			[]string{"100.64.0.1/32", "100.64.0.5/32", "100.100.100.100/32", "fd7a:115c:a1e0::1/128", "fd7a:115c:a1e0::53/128"},
			[]string{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			o := dns.OSConfig{Nameservers: c.servers}
			if c.servers != nil {
				o.MatchDomains = domains
			}
			s := buildSettings(&router.Config{LocalAddrs: prefixes(c.local...), Routes: engineRoutes}, o, 1300)
			if !slices.Equal(s.Addresses, c.local) || !slices.Equal(s.Routes, c.wantRoutes) || !slices.Equal(s.DNSServers, c.wantDNS) || s.MTU != 1300 {
				t.Fatalf("got %+v", s)
			}
			if c.servers != nil && !slices.Equal(s.DNSMatchDomains, []string{"rd-test.ts.net", "64.100.in-addr.arpa"}) {
				t.Fatalf("match domains %v", s.DNSMatchDomains)
			}
			if s.DNSMatchDomains == nil || s.DNSServers == nil || s.Routes == nil {
				t.Fatal("nil slice (JSON null)")
			}
		})
	}
	// The engine's own consolidation (one CGNAT route) passes through as is.
	s := buildSettings(&router.Config{LocalAddrs: prefixes(v4), Routes: prefixes("100.64.0.0/10")}, dns.OSConfig{}, 1280)
	if !slices.Equal(s.Routes, []string{"100.64.0.0/10"}) {
		t.Fatalf("routes %v", s.Routes)
	}
}

type recorder struct {
	mu  sync.Mutex
	got []Settings
}

func (r *recorder) emit(s Settings) {
	r.mu.Lock()
	r.got = append(r.got, s)
	r.mu.Unlock()
}

func (r *recorder) last() Settings {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.got) == 0 {
		return Settings{}
	}
	return r.got[len(r.got)-1]
}

func (r *recorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.got)
}

func TestTunnelSinkFlush(t *testing.T) {
	old := fallbackFlushDelay
	fallbackFlushDelay = 20 * time.Millisecond
	t.Cleanup(func() { fallbackFlushDelay = old })

	rec := &recorder{}
	s := &sink{mtu: 1280, emit: rec.emit}
	rt, osc := s.router(), s.osConfigurator()
	running := &router.Config{LocalAddrs: prefixes("100.64.0.11/32"), Routes: prefixes("100.64.0.1/32")}

	rt.Set(nil) // engine start
	rt.Set(&router.Config{})
	s.reconfigureVPN()
	if rec.count() != 0 {
		t.Fatal("emitted without addresses")
	}

	quad100 := dns.OSConfig{Nameservers: addrs("100.100.100.100"), MatchDomains: []dnsname.FQDN{"rd-test.ts.net."}}
	rt.Set(running)
	osc.SetDNS(quad100)
	s.reconfigureVPN()
	if rec.count() != 1 {
		t.Fatalf("emits %d, want 1", rec.count())
	}
	rt.Set(running.Clone()) // identical: no event (apply → link change → reconfig loop guard)
	osc.SetDNS(quad100)
	s.reconfigureVPN()
	time.Sleep(3 * fallbackFlushDelay)
	if rec.count() != 1 {
		t.Fatalf("identical settings emitted again: %d", rec.count())
	}
	if got, ok := s.settings(); !ok || got.DNSServers[0] != "100.100.100.100" {
		t.Fatalf("settings %+v %v", got, ok)
	}

	// DNS-only changes (same routes) are changes: a new match domain, then
	// a new server list.
	rt.Set(running.Clone())
	osc.SetDNS(dns.OSConfig{Nameservers: quad100.Nameservers, MatchDomains: []dnsname.FQDN{"rd-test.ts.net.", "corp.example.com."}})
	s.reconfigureVPN()
	if rec.count() != 2 || !slices.Contains(rec.last().DNSMatchDomains, "corp.example.com") {
		t.Fatalf("match-domain change: %d emits, last %+v", rec.count(), rec.last())
	}
	osc.SetDNS(dns.OSConfig{Nameservers: addrs("100.100.100.100", "fd7a:115c:a1e0::53"), MatchDomains: []dnsname.FQDN{"rd-test.ts.net.", "corp.example.com."}})
	rt.Set(&router.Config{LocalAddrs: prefixes("100.64.0.11/32", "fd7a:115c:a1e0::b/128"), Routes: running.Routes})
	s.reconfigureVPN()
	osc.SetDNS(dns.OSConfig{Nameservers: addrs("100.100.100.100"), MatchDomains: []dnsname.FQDN{"rd-test.ts.net.", "corp.example.com."}})
	s.reconfigureVPN()
	if rec.count() != 4 || !slices.Equal(rec.last().DNSServers, []string{"100.100.100.100"}) {
		t.Fatalf("server change: %d emits, last %+v", rec.count(), rec.last())
	}
	rt.Set(running.Clone())
	s.reconfigureVPN()
	if rec.count() != 5 {
		t.Fatalf("emits %d, want 5", rec.count())
	}

	// dns.Set failed, so no ReconfigureVPN: the fallback timer flushes.
	rt.Set(&router.Config{LocalAddrs: running.LocalAddrs, Routes: prefixes("100.64.0.1/32", "100.64.0.2/32")})
	waitCount := func(want int) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for rec.count() != want && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
		}
		if rec.count() != want {
			t.Fatalf("emits %d, want %d", rec.count(), want)
		}
	}
	waitCount(6)
	// A later successful dns.Set + ReconfigureVPN after that fallback flush
	// emits the DNS change.
	osc.SetDNS(quad100)
	s.reconfigureVPN()
	waitCount(7)
	if !slices.Equal(rec.last().DNSMatchDomains, []string{"rd-test.ts.net"}) {
		t.Fatalf("after fallback: %+v", rec.last())
	}

	rt.Close()
	rt.Set(&router.Config{LocalAddrs: running.LocalAddrs, Routes: prefixes("100.64.0.9/32")})
	s.reconfigureVPN()
	time.Sleep(3 * fallbackFlushDelay)
	if rec.count() != 7 {
		t.Fatal("emitted after Close")
	}
}

// Settings that differ only in DNS fields are not Equal.
func TestTunnelSettingsEqual(t *testing.T) {
	base := Settings{Addresses: []string{"100.64.0.11/32"}, Routes: []string{"100.64.0.1/32"}, DNSServers: []string{"100.100.100.100"}, DNSMatchDomains: []string{"rd-test.ts.net"}, MTU: 1280}
	if !base.Equal(base.Clone()) {
		t.Fatal("clone not equal")
	}
	servers := base.Clone()
	servers.DNSServers = []string{"100.100.100.100", "fd7a:115c:a1e0::53"}
	domains := base.Clone()
	domains.DNSMatchDomains = []string{"rd-test.ts.net", "64.100.in-addr.arpa"}
	noDNS := base.Clone()
	noDNS.DNSServers, noDNS.DNSMatchDomains = []string{}, []string{}
	for name, o := range map[string]Settings{"servers": servers, "match domains": domains, "no dns": noDNS} {
		if base.Equal(o) || o.Equal(base) {
			t.Errorf("%s: equal", name)
		}
	}
}

// StartLoginInteractive panics when the backend has no control client; Login
// must turn any such panic into an error.
func TestTunnelLoginRecovers(t *testing.T) {
	n := &Node{} // no backend at all: the call panics inside
	if err := n.Login(context.Background()); err == nil {
		t.Fatal("no error from a panicking login")
	}
}
