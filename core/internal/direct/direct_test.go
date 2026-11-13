package direct

import (
	"crypto/tls"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestIsLANAddr(t *testing.T) {
	for addr, want := range map[string]bool{
		"10.0.0.5":            true,
		"172.16.0.1":          true,
		"172.31.255.254":      true,
		"192.168.0.10":        true,
		"169.254.10.20":       true,
		"::ffff:192.168.0.10": true,
		"fe80::1":             true,
		"fd12:3456:789a::1":   true,
		"172.32.0.1":          false,
		"100.64.0.1":          false, // CGNAT: Tailscale addresses
		"100.101.102.103":     false,
		"fd7a:115c:a1e0::1":   false, // Tailscale IPv6
		"203.0.113.7":         false,
		"8.8.8.8":             false,
		"2001:db8::1":         false,
		"127.0.0.1":           false,
		"::1":                 false,
		"0.0.0.0":             false,
		"::ffff:203.0.113.7":  false,
	} {
		if got := IsLANAddr(netip.MustParseAddr(addr)); got != want {
			t.Errorf("IsLANAddr(%s) = %v, want %v", addr, got, want)
		}
	}
	if AllowLAN(&net.TCPAddr{IP: net.ParseIP("203.0.113.7"), Port: 1}) || !AllowLAN(&net.TCPAddr{IP: net.ParseIP("192.168.0.10"), Port: 1}) {
		t.Error("AllowLAN disagrees with IsLANAddr")
	}
}

func TestIdentityFilesArePrivateAndStable(t *testing.T) {
	dir := t.TempDir()
	id, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(id.ID()) != 16 || id.SPKI() == "" || id.Port() != 0 {
		t.Fatalf("identity %q %q %d", id.ID(), id.SPKI(), id.Port())
	}
	for _, name := range []string{stateFile, keyFile, certFile} {
		fi, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v", name, fi.Mode().Perm())
		}
	}
	id.SetHostID("h_4be0c7a1")
	again, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID() != id.ID() || again.SPKI() != id.SPKI() || again.HostID() != "h_4be0c7a1" {
		t.Fatal("identity changed across loads")
	}
}

// A peer outside the allowed ranges (here: loopback, which is not a LAN
// address) is dropped before the TLS handshake.
func TestListenerClosesPeersOutsideTheLAN(t *testing.T) {
	id, err := Load(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ln, err := id.Listen(Options{Host: "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	accepted := make(chan struct{}, 1)
	go func() {
		if c, err := ln.Accept(); err == nil {
			accepted <- struct{}{}
			c.Close()
		}
	}()
	d := &net.Dialer{Timeout: 2 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", ln.Addr().String(), &tls.Config{InsecureSkipVerify: true})
	if err == nil {
		conn.Close()
		t.Fatal("handshake succeeded from a non-LAN address")
	}
	select {
	case <-accepted:
		t.Fatal("connection reached the server")
	case <-time.After(100 * time.Millisecond):
	}
}

func TestListenKeepsThePortAndReplacesABusyOne(t *testing.T) {
	dir := t.TempDir()
	id, _ := Load(dir)
	allow := func(net.Addr) bool { return true }
	ln, err := id.Listen(Options{Host: "127.0.0.1", Allow: allow})
	if err != nil {
		t.Fatal(err)
	}
	port := id.Port()
	if port == 0 || ln.Addr().(*net.TCPAddr).Port != port {
		t.Fatalf("port %d, listener %v", port, ln.Addr())
	}
	ln.Close()
	again, _ := Load(dir)
	ln2, err := again.Listen(Options{Host: "127.0.0.1", Allow: allow})
	if err != nil {
		t.Fatal(err)
	}
	defer ln2.Close()
	if again.Port() != port {
		t.Fatalf("port changed %d -> %d", port, again.Port())
	}
	// While the port is taken, another identity pointed at it moves on.
	third, _ := Load(dir)
	ln3, err := third.Listen(Options{Host: "127.0.0.1", Allow: allow})
	if err != nil {
		t.Fatal(err)
	}
	defer ln3.Close()
	if third.Port() == port || third.Port() == 0 {
		t.Fatalf("busy port was not replaced: %d", third.Port())
	}
}
