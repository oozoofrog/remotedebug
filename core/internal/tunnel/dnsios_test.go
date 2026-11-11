package tunnel

import (
	"fmt"
	"net/netip"
	"slices"
	"testing"

	"tailscale.com/control/controlknobs"
	"tailscale.com/health"
	"tailscale.com/net/dns"
	"tailscale.com/net/netmon"
	"tailscale.com/net/tsdial"
	"tailscale.com/types/dnstype"
	"tailscale.com/util/dnsname"
	"tailscale.com/util/eventbus"
	"tailscale.com/wgengine/router"
)

// magicDNSConfig is what LocalBackend gives the engine for a tailnet with
// MagicDNS on (ipnlocal.dnsConfigForNetmap + magicDNSRootDomains): the
// suffix and the reverse zones, all answered by quad-100 itself.
func magicDNSConfig() *dns.Config {
	c := &dns.Config{
		AcceptDNS: true,
		Routes: map[dnsname.FQDN][]*dnstype.Resolver{
			"rd-test.ts.net.":                   nil,
			"0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa.": nil,
		},
		Hosts: map[dnsname.FQDN][]netip.Addr{},
	}
	for i := 64; i <= 127; i++ {
		c.Routes[dnsname.FQDN(fmt.Sprintf("%d.100.in-addr.arpa.", i))] = nil
	}
	return c
}

// TestTunnelIOSDNS runs Tailscale's DNS manager with goos "ios" against the
// sink, the way the engine does on the device, and checks that every config
// yields scoped DNS for the tailnet: quad-100 first, the tailnet suffix in
// the match domains, never a match-all (empty) list.
func TestTunnelIOSDNS(t *testing.T) {
	cases := []struct {
		name  string
		cfg   func() *dns.Config
		knob  bool
		extra []string // more match domains expected
		never []string // match domains that must not appear
		// tailnetUpstream: control's default resolvers serve direct queries
		// to quad-100 (the device's own queries never reach it).
		tailnetUpstream bool
	}{
		{name: "magicdns only", cfg: magicDNSConfig},
		{name: "custom split route", cfg: func() *dns.Config {
			c := magicDNSConfig()
			c.Routes["corp.example.com."] = []*dnstype.Resolver{{Addr: "10.0.0.53"}}
			return c
		}, never: []string{"corp.example.com"}},
		{name: "extra record", cfg: func() *dns.Config {
			c := magicDNSConfig()
			c.Hosts["nas.rd-test.ts.net."] = []netip.Addr{netip.MustParseAddr("10.1.2.3")}
			return c
		}},
		{name: "extra record outside the tailnet suffix", cfg: func() *dns.Config {
			c := magicDNSConfig()
			c.Hosts["nas.example.org."] = []netip.Addr{netip.MustParseAddr("10.1.2.4")}
			c.Routes["nas.example.org."] = nil // ipnlocal's coverExtraRecords
			return c
		}, extra: []string{"nas.example.org"}},
		{name: "DisableSplitDNSWhenNoCustomResolvers", cfg: magicDNSConfig, knob: true},
		{name: "override local DNS", cfg: func() *dns.Config {
			c := magicDNSConfig()
			c.DefaultResolvers = []*dnstype.Resolver{{Addr: "1.1.1.1"}}
			return c
		}, tailnetUpstream: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			bus := eventbus.New()
			t.Cleanup(bus.Close)
			dialer := &tsdial.Dialer{Logf: t.Logf}
			dialer.SetNetMon(netmon.NewStatic())
			t.Cleanup(func() { dialer.Close() })
			knobs := new(controlknobs.Knobs)
			knobs.DisableSplitDNSWhenNoCustomResolvers.Store(c.knob)

			rec := &recorder{}
			s := &sink{mtu: 1280, emit: rec.emit}
			m := dns.NewManager(t.Logf, s.osConfigurator(), health.NewTracker(bus), dialer, nil, knobs, "ios", bus)
			t.Cleanup(func() { m.Down() })
			if err := registerNoUpstream(m); err != nil {
				t.Fatal(err)
			}

			// The engine's order: router.Set, dns.Set, ReconfigureVPN.
			cfg := c.cfg()
			s.noteDNSConfig(cfg) // dnsTap.Reconfig
			s.router().Set(&router.Config{LocalAddrs: prefixes("100.64.0.11/32", "fd7a:115c:a1e0::b/128"), Routes: prefixes("100.64.0.1/32", "100.100.100.100/32")})
			if err := m.Set(*cfg); err != nil {
				t.Fatalf("dns.Set: %v", err)
			}
			s.reconfigureVPN()
			got, ok := s.settings()
			if !ok {
				t.Fatal("no settings")
			}
			if len(got.DNSServers) == 0 || got.DNSServers[0] != "100.100.100.100" {
				t.Fatalf("dnsServers %v", got.DNSServers)
			}
			if len(got.DNSMatchDomains) == 0 || slices.Contains(got.DNSMatchDomains, "") {
				t.Fatalf("match-all DNS: %v", got.DNSMatchDomains)
			}
			for _, d := range append([]string{"rd-test.ts.net", "64.100.in-addr.arpa", "0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa"}, c.extra...) {
				if !slices.Contains(got.DNSMatchDomains, d) {
					t.Fatalf("match domains %v lack %q", got.DNSMatchDomains, d)
				}
			}
			for _, d := range c.never {
				if slices.Contains(got.DNSMatchDomains, d) {
					t.Fatalf("match domains %v contain %q", got.DNSMatchDomains, d)
				}
			}
			// quad-100 answers tailnet names itself and, unless control set
			// default resolvers, has no upstream for anything else.
			if up := m.Resolver().GetUpstreamResolvers("example.com."); len(up) != 0 && !c.tailnetUpstream {
				t.Fatalf("upstream for example.com: %v", up)
			}
		})
	}
}

// scopeDNS never produces DNS without match domains.
func TestTunnelScopeDNS(t *testing.T) {
	local := []dnsname.FQDN{"64.100.in-addr.arpa.", "rd-test.ts.net."}
	primary := dns.OSConfig{Nameservers: addrs("100.100.100.100")}
	if o := scopeDNS(primary, nil); len(o.Nameservers) != 0 || len(o.MatchDomains) != 0 {
		t.Fatalf("no tailnet suffixes: %+v", o)
	}
	o := scopeDNS(primary, local)
	if !slices.Equal(o.MatchDomains, local) || o.Nameservers[0] != netip.MustParseAddr("100.100.100.100") {
		t.Fatalf("primary: %+v", o)
	}
	// A tailnet default resolver (override local DNS) is replaced by quad-100.
	o = scopeDNS(dns.OSConfig{Nameservers: addrs("1.1.1.1")}, local)
	if slices.Contains(o.Nameservers, netip.MustParseAddr("1.1.1.1")) || len(o.MatchDomains) != 2 {
		t.Fatalf("default resolver: %+v", o)
	}
	scoped := dns.OSConfig{Nameservers: addrs("100.100.100.100"), MatchDomains: []dnsname.FQDN{"rd-test.ts.net."}}
	if o := scopeDNS(scoped, local); !slices.Equal(o.MatchDomains, scoped.MatchDomains) {
		t.Fatalf("scoped: %+v", o)
	}
	if o := scopeDNS(dns.OSConfig{}, local); len(o.Nameservers) != 0 {
		t.Fatalf("empty: %+v", o)
	}
}
