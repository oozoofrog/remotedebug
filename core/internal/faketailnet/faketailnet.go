// Package faketailnet runs a local, in-process tailnet for tests: a DERP relay
// on 127.0.0.1 plus tailscale.com/tstest/integration/testcontrol as the
// control server. It never contacts the real Tailscale control plane.
// It is used only by tests and cmd/rdtestenv, never by the shipped core.
package faketailnet

import (
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"

	"tailscale.com/derp/derpserver"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// MagicDNSDomain is the tailnet DNS suffix used by the fake control server.
const MagicDNSDomain = "rd-test.ts.net"

// Env is a running fake tailnet.
type Env struct {
	ControlURL string
	Control    *testcontrol.Server
	closers    []func()
}

// Start starts DERP and the control server on loopback. logf may be nil.
func Start(logf logger.Logf) (*Env, error) {
	if logf == nil {
		logf = logger.Discard
	}
	env := &Env{}

	d := derpserver.New(key.NewNode(), logf)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	derpSrv := httptest.NewUnstartedServer(derpserver.Handler(d))
	derpSrv.Listener.Close()
	derpSrv.Listener = ln
	derpSrv.Config.ErrorLog = logger.StdLogger(logf)
	derpSrv.Config.TLSNextProto = map[string]func(*http.Server, *tls.Conn, http.Handler){}
	derpSrv.StartTLS()
	env.closers = append(env.closers, func() {
		derpSrv.CloseClientConnections()
		derpSrv.Close()
		d.Close()
	})

	derpMap := &tailcfg.DERPMap{
		Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
			1: {
				RegionID:   1,
				RegionCode: "test",
				Nodes: []*tailcfg.DERPNode{{
					Name:             "t1",
					RegionID:         1,
					HostName:         "127.0.0.1",
					IPv4:             "127.0.0.1",
					IPv6:             "none",
					STUNPort:         -1, // no STUN; peers talk via DERP or direct loopback
					DERPPort:         ln.Addr().(*net.TCPAddr).Port,
					InsecureForTests: true,
				}},
			},
		},
	}

	env.Control = &testcontrol.Server{
		DERPMap:        derpMap,
		DNSConfig:      &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain: MagicDNSDomain,
		Logf:           logf,
	}
	env.Control.HTTPTestServer = httptest.NewUnstartedServer(env.Control)
	env.Control.HTTPTestServer.Start()
	env.closers = append(env.closers, env.Control.HTTPTestServer.Close)
	env.ControlURL = env.Control.HTTPTestServer.URL
	return env, nil
}

// Close stops the control server and DERP.
func (e *Env) Close() {
	for i := len(e.closers) - 1; i >= 0; i-- {
		e.closers[i]()
	}
}
