//go:build darwin

package tunnel

import (
	"testing"
	"time"

	"tailscale.com/net/netmon"
	"tailscale.com/util/eventbus"
)

// SetDefaultInterface reaches netmon's state and makes it re-evaluate at
// once (no route-socket event needed), so the engine sees
// DefaultInterfaceChanged and rebinds. lo0 stands in for the new interface:
// it is up and has an address, which is all netmon's darwin check needs.
func TestTunnelSetDefaultInterfaceReevaluates(t *testing.T) {
	orig, err := netmon.DefaultRouteInterface()
	if err != nil || orig == "" || orig == "lo0" {
		t.Skipf("no usable default route interface (%q, %v)", orig, err)
	}
	bus := eventbus.New()
	t.Cleanup(bus.Close)
	m, err := netmon.New(bus, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { m.Close() })
	deltas := make(chan *netmon.ChangeDelta, 16)
	m.RegisterChangeCallback(func(d *netmon.ChangeDelta) { deltas <- d })
	m.Start()
	n := &Node{netMon: m}
	// Process-global: put the real default interface back.
	t.Cleanup(func() { setLastKnownDefaultInterface(orig) })

	wait := func(want string) {
		t.Helper()
		deadline := time.After(10 * time.Second)
		for {
			select {
			case d := <-deltas:
				if d.DefaultRouteInterface == want {
					if !d.DefaultInterfaceChanged {
						t.Fatalf("%s: DefaultInterfaceChanged false", want)
					}
					if got := m.InterfaceState().DefaultRouteInterface; got != want {
						t.Fatalf("state %q, want %q", got, want)
					}
					return
				}
			case <-deadline:
				t.Fatalf("netmon never re-evaluated to %q (state %q)", want, m.InterfaceState().DefaultRouteInterface)
			}
		}
	}
	n.SetDefaultInterface("lo0")
	wait("lo0")
	n.SetDefaultInterface("") // ignored
	if got, _ := netmon.OSDefaultRoute(); got.InterfaceName != "lo0" {
		t.Fatalf("empty name changed the interface to %q", got.InterfaceName)
	}
	n.SetDefaultInterface(orig)
	wait(orig)
}
