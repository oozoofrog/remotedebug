package tunnel

import (
	"net/netip"
	"slices"
	"sync"
	"time"

	"tailscale.com/feature/buildfeatures"
	"tailscale.com/net/dns"
	"tailscale.com/net/tsaddr"
	"tailscale.com/types/dnstype"
	"tailscale.com/util/dnsname"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/router"
	"tailscale.com/wgengine/wgcfg"
)

// Settings is what the Network Extension applies with
// setTunnelNetworkSettings (docs/tunnel.md "network-settings").
type Settings struct {
	Addresses       []string `json:"addresses"`
	Routes          []string `json:"routes"`
	DNSServers      []string `json:"dnsServers"`
	DNSMatchDomains []string `json:"dnsMatchDomains"`
	MTU             int      `json:"mtu"`
}

// Equal reports whether a and b are the same settings.
func (a Settings) Equal(b Settings) bool {
	return slices.Equal(a.Addresses, b.Addresses) && slices.Equal(a.Routes, b.Routes) &&
		slices.Equal(a.DNSServers, b.DNSServers) && slices.Equal(a.DNSMatchDomains, b.DNSMatchDomains) &&
		a.MTU == b.MTU
}

// Clone returns a deep copy of s.
func (s Settings) Clone() Settings {
	s.Addresses = slices.Clone(s.Addresses)
	s.Routes = slices.Clone(s.Routes)
	s.DNSServers = slices.Clone(s.DNSServers)
	s.DNSMatchDomains = slices.Clone(s.DNSMatchDomains)
	return s
}

// buildSettings turns the engine's router and DNS configuration into
// Settings. Routes are the engine's routes as they are (on iOS one prefix per
// peer, already consolidated by the engine); nothing is widened to
// 100.64.0.0/10 here. Routes and DNS servers of an address family the node
// has no local address in are dropped. Every slice is non-nil.
func buildSettings(r *router.Config, o dns.OSConfig, mtu int) Settings {
	s := Settings{MTU: mtu, Addresses: []string{}, Routes: []string{}, DNSServers: []string{}, DNSMatchDomains: []string{}}
	var has4, has6 bool
	for _, p := range r.LocalAddrs {
		has4 = has4 || p.Addr().Is4()
		has6 = has6 || p.Addr().Is6()
		s.Addresses = append(s.Addresses, p.String())
	}
	family := func(a netip.Addr) bool { return (a.Is4() && has4) || (a.Is6() && has6) }
	for _, p := range r.Routes {
		if !family(p.Addr()) {
			continue
		}
		if str := p.String(); !slices.Contains(s.Routes, str) {
			s.Routes = append(s.Routes, str)
		}
	}
	var v4, v6 []string
	for _, a := range o.Nameservers {
		switch {
		case !family(a):
		case a.Is4():
			v4 = append(v4, a.String())
		default:
			v6 = append(v6, a.String())
		}
	}
	s.DNSServers = append(append(s.DNSServers, v4...), v6...) // IPv4 service IP first
	for _, d := range o.MatchDomains {
		s.DNSMatchDomains = append(s.DNSMatchDomains, d.WithoutTrailingDot())
	}
	return s
}

// fallbackFlushDelay: if dns.Set fails, ReconfigureVPN never runs; the
// router config is flushed on its own after this delay.
var fallbackFlushDelay = 250 * time.Millisecond

// sink is the engine's router.Router and dns.OSConfigurator. It never
// touches the OS: it collects the configuration and emits it as Settings.
// The engine calls router.Set, then dns.Set, then ReconfigureVPN (only if
// dns.Set succeeded); ReconfigureVPN is the flush point.
type sink struct {
	mtu  int
	emit func(Settings) // called with s.mu held, under engine locks: must not block

	mu     sync.Mutex
	rcfg   *router.Config
	ocfg   dns.OSConfig   // always scoped (see scopeDNS)
	local  []dnsname.FQDN // suffixes quad-100 answers itself, from the last engine Reconfig
	last   *Settings
	timer  *time.Timer
	closed bool
}

func (s *sink) router() router.Router              { return (*sinkRouter)(s) }
func (s *sink) osConfigurator() dns.OSConfigurator { return (*sinkDNS)(s) }

func (s *sink) reconfigureVPN() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.flushLocked()
	return nil
}

// settings returns the last emitted settings.
func (s *sink) settings() (Settings, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.last == nil {
		return Settings{}, false
	}
	return s.last.Clone(), true
}

func (s *sink) flushLocked() {
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	// No addresses: engine start, NeedsLogin or Stopped. Nothing to apply.
	if s.closed || s.rcfg == nil || len(s.rcfg.LocalAddrs) == 0 {
		return
	}
	ns := buildSettings(s.rcfg, s.ocfg, s.mtu)
	if s.last != nil && ns.Equal(*s.last) {
		return // also breaks apply → link change → reconfig → apply loops
	}
	s.last = &ns
	if s.emit != nil {
		s.emit(ns.Clone())
	}
}

type sinkRouter sink

func (r *sinkRouter) Up() error { return nil }

func (r *sinkRouter) Set(cfg *router.Config) error {
	s := (*sink)(r)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rcfg = cfg.Clone()
	if !buildfeatures.HasDNS {
		s.flushLocked()
		return nil
	}
	if s.timer == nil && !s.closed {
		s.timer = time.AfterFunc(fallbackFlushDelay, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			s.flushLocked()
		})
	}
	return nil
}

func (r *sinkRouter) Close() error {
	s := (*sink)(r)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	return nil
}

// noteDNSConfig records the tailnet suffixes quad-100 answers by itself: the
// routes without upstream resolvers (MagicDNS suffix, 100.64.0.0/10 and
// fd7a:115c:a1e0::/48 reverse zones, uncovered ExtraRecord names, empty
// control routes). Called before the engine applies cfg.
func (s *sink) noteDNSConfig(cfg *dns.Config) {
	var local []dnsname.FQDN
	if cfg != nil {
		for suffix, resolvers := range cfg.Routes {
			if len(resolvers) == 0 {
				local = append(local, suffix)
			}
		}
	}
	slices.Sort(local)
	s.mu.Lock()
	s.local = local
	s.mu.Unlock()
}

// scopeDNS keeps the tunnel's DNS scoped to tailnet names: the extension
// never becomes the device's general resolver (docs/tunnel.md). A config
// without match domains (the engine made quad-100, or a tailnet default
// resolver, the primary resolver: Apple "Mode B", "override local DNS")
// becomes quad-100 for local's suffixes only, or no DNS when local is empty.
// A config that already has match domains is kept as is.
func scopeDNS(o dns.OSConfig, local []dnsname.FQDN) dns.OSConfig {
	if len(o.Nameservers) == 0 || len(o.MatchDomains) > 0 {
		return o
	}
	if len(local) == 0 {
		return dns.OSConfig{}
	}
	return dns.OSConfig{
		Nameservers:  []netip.Addr{tsaddr.TailscaleServiceIP(), tsaddr.TailscaleServiceIPv6()},
		MatchDomains: slices.Clone(local),
	}
}

type sinkDNS sink

func (d *sinkDNS) SetDNS(cfg dns.OSConfig) error {
	s := (*sink)(d)
	s.mu.Lock()
	s.ocfg = scopeDNS(cfg, s.local)
	s.mu.Unlock()
	return nil
}

func (d *sinkDNS) SupportsSplitDNS() bool { return true }

// noUpstreamScheme names the only upstream the sink reports: a resolver
// that registerNoUpstream turns into "no resolver", so quad-100 answers
// SERVFAIL for names outside the tailnet instead of forwarding them.
const noUpstreamScheme = "rd-no-upstream"

// GetBaseConfig never fails. On GOOS=ios dns.Manager reads it for every
// config that cannot use Apple's scoped mode (custom split DNS routes,
// ExtraRecords outside the reverse zones, the
// DisableSplitDNSWhenNoCustomResolvers knob); an error or an empty base
// would leave the tunnel with no DNS at all. The device's resolvers are
// never needed: scopeDNS sends only tailnet names to quad-100.
func (d *sinkDNS) GetBaseConfig() (dns.OSConfig, error) {
	return dns.OSConfig{Resolvers: []*dnstype.Resolver{{Addr: noUpstreamScheme + ":"}}}, nil
}

// registerNoUpstream makes noUpstreamScheme resolve to no resolver in m's
// forwarder (a route left with no resolver answers SERVFAIL).
func registerNoUpstream(m *dns.Manager) error {
	if m == nil || m.Resolver() == nil {
		return nil
	}
	return m.Resolver().RegisterCustomScheme(noUpstreamScheme, func(string) (string, error) { return "", nil })
}

func (d *sinkDNS) Close() error { return nil }

// dnsTap is the engine as LocalBackend sees it: it tells the sink which
// suffixes quad-100 answers before the engine applies a DNS config.
type dnsTap struct {
	wgengine.Engine
	sink *sink
}

func (e *dnsTap) Reconfig(cfg *wgcfg.Config, routerCfg *router.Config, dnsCfg *dns.Config) error {
	e.sink.noteDNSConfig(dnsCfg)
	return e.Engine.Reconfig(cfg, routerCfg, dnsCfg)
}
