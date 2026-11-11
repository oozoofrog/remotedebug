package api

import (
	"encoding/json"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"testing"

	"golang.org/x/sys/unix"

	"tailscale.com/net/netmon"

	"remotedebug/core/internal/faketun"
	"remotedebug/core/internal/node"
)

func tunnelConfig(stateDir, extra string) string {
	c := `{"mode":"tunnel","stateDir":"` + stateDir + `","hostname":"rd-phone-t1","controlURL":"` + deadControl + `","goMemLimitMiB":28`
	if extra != "" {
		c += "," + extra
	}
	return c + "}"
}

// startTunnelDead starts a tunnel node on an in-memory TUN against the dead
// loopback control server.
func startTunnelDead(t *testing.T) int64 {
	t.Helper()
	out := StartWithOptions(tunnelConfig(filepath.Join(t.TempDir(), "state"), ""), node.Options{Tun: faketun.New()})
	var started struct{ Handle int64 }
	json.Unmarshal([]byte(out), &started)
	if started.Handle == 0 {
		t.Fatalf("start: %s", out)
	}
	t.Cleanup(func() { Stop(started.Handle) })
	return started.Handle
}

const mtuMessage = "mtu는 1280 이상 1420 이하여야 합니다."

// errorMessage returns the error message of a C API result.
func errorMessage(t *testing.T, out string) string {
	t.Helper()
	var v struct {
		Error struct{ Message string } `json:"error"`
	}
	json.Unmarshal([]byte(out), &v)
	return v.Error.Message
}

// Invalid tunnel settings fail with invalid_config before Start touches any
// process-global state (memory limit, GC percent).
func TestTunnelInvalidConfig(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])

	limit := debug.SetMemoryLimit(-1)
	gc := debug.SetGCPercent(-1)
	debug.SetGCPercent(gc)

	dir := t.TempDir()
	for name, c := range map[string]struct{ extra, message string }{
		"no utunFd":       {``, "utunFd가 필요합니다."},
		"negative utunFd": {`"utunFd":-3`, "utunFd가 필요합니다."},
		"not a utun":      {`"utunFd":` + strconv.Itoa(fds[0]), "utunFd가 utun 소켓이 아닙니다."},
	} {
		out := Start(tunnelConfig(filepath.Join(dir, name), c.extra))
		if code := errorCode(t, out); code != "invalid_config" || errorMessage(t, out) != c.message {
			t.Errorf("%s: %s", name, out)
		}
	}
	// Every MTU case is otherwise valid (in-memory TUN, creatable stateDir),
	// so only the MTU bound can reject it.
	for _, mtu := range []int{1, 1000, 1279, 1421, 1500, 9000, -1280} {
		out := StartWithOptions(tunnelConfig(filepath.Join(dir, "mtu"+strconv.Itoa(mtu)), `"mtu":`+strconv.Itoa(mtu)), node.Options{Tun: faketun.New()})
		if code := errorCode(t, out); code != "invalid_config" || errorMessage(t, out) != mtuMessage {
			t.Errorf("mtu %d: %s", mtu, out)
		}
	}
	if got := debug.SetMemoryLimit(-1); got != limit {
		t.Errorf("memory limit changed: %d → %d", limit, got)
	}
	if got := debug.SetGCPercent(-1); got != gc {
		t.Errorf("GC percent changed: %d → %d", gc, got)
	} else {
		debug.SetGCPercent(gc)
	}

	// Host-mode keys are ignored in tunnel mode: listenTLS=false with a
	// non-loopback control URL is fine (checked without starting anything).
	cfg, err := node.ParseConfig(`{"mode":"tunnel","stateDir":"` + dir + `","hostname":"rd-phone-t1","listenTLS":false,"controlURL":"https://controlplane.example.com","port":70000,"utunFd":7}`)
	if err != nil || cfg.MTU != node.DefaultMTU {
		t.Fatalf("parse: %v, mtu %v", err, cfg)
	}
}

// The MTU bounds are inclusive; 0 means 1280. status.tunnel.mtu reports it.
func TestTunnelMTUBounds(t *testing.T) {
	limit := debug.SetMemoryLimit(-1)
	t.Cleanup(func() { debug.SetMemoryLimit(limit) })
	for _, c := range []struct {
		extra string
		want  int
	}{{`"mtu":1280`, 1280}, {`"mtu":1420`, 1420}, {``, 1280}} {
		out := StartWithOptions(tunnelConfig(filepath.Join(t.TempDir(), "state"), c.extra), node.Options{Tun: faketun.New()})
		var started struct{ Handle int64 }
		json.Unmarshal([]byte(out), &started)
		if started.Handle == 0 {
			t.Fatalf("%q: %s", c.extra, out)
		}
		var st struct{ Tunnel struct{ MTU int } }
		json.Unmarshal([]byte(Status(started.Handle)), &st)
		Stop(started.Handle)
		if st.Tunnel.MTU != c.want {
			t.Fatalf("%q: status mtu %d, want %d", c.extra, st.Tunnel.MTU, c.want)
		}
	}
}

// One tunnel node per process; rd_stop releases it. A second start on the
// same stateDir fails earlier, with state_dir_in_use (docs/tunnel.md).
func TestTunnelInUse(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	out := StartWithOptions(tunnelConfig(dir, ""), node.Options{Tun: faketun.New()})
	var started struct{ Handle int64 }
	json.Unmarshal([]byte(out), &started)
	h := started.Handle
	if h == 0 {
		t.Fatalf("start: %s", out)
	}
	t.Cleanup(func() { Stop(h) })
	out = StartWithOptions(tunnelConfig(filepath.Join(t.TempDir(), "state2"), ""), node.Options{Tun: faketun.New()})
	if errorCode(t, out) != "invalid_config" || errorMessage(t, out) != "tunnel_in_use" {
		t.Fatalf("second tunnel: %s", out)
	}
	out = StartWithOptions(tunnelConfig(dir, ""), node.Options{Tun: faketun.New()})
	if errorCode(t, out) != "invalid_config" || errorMessage(t, out) != "state_dir_in_use" {
		t.Fatalf("second tunnel on the same stateDir: %s", out)
	}
	if out := Stop(h); out != `{"ok":true}` {
		t.Fatalf("stop: %s", out)
	}
	startTunnelDead(t)
}

// A start that fails after taking the process's tunnel slot (here: logPath
// is a directory) releases it, so the next start works.
func TestTunnelSlotReleasedOnFailedStart(t *testing.T) {
	logDir := t.TempDir() // a directory: openRotatingFile fails after claimTunnel
	out := StartWithOptions(tunnelConfig(filepath.Join(t.TempDir(), "state"), `"logPath":"`+logDir+`"`), node.Options{Tun: faketun.New()})
	if errorCode(t, out) != "invalid_config" || errorMessage(t, out) != "logPath를 열 수 없습니다." {
		t.Fatalf("start with a bad logPath: %s", out)
	}
	startTunnelDead(t)
}

func TestTunnelSetDefaultInterface(t *testing.T) {
	if code := errorCode(t, TunnelSetDefaultInterface(987654, "en0")); code != "unknown_handle" {
		t.Fatalf("unknown handle: %q", code)
	}
	p := startDead(t, "proxy", filepath.Join(t.TempDir(), "state"))
	if code := errorCode(t, TunnelSetDefaultInterface(p, "en0")); code != "invalid_config" {
		t.Fatalf("proxy mode: %q", code)
	}
	h := startTunnelDead(t)
	if code := errorCode(t, TunnelSetDefaultInterface(h, "en0; rm")); code != "bad_request" {
		t.Fatalf("bad name: %q", code)
	}
	// A name that exists nowhere is stored and ignored by netmon (it falls
	// back to the route table), so this cannot disturb other tests.
	for _, name := range []string{"rdtest0", ""} {
		if out := TunnelSetDefaultInterface(h, name); out != `{"ok":true}` {
			t.Fatalf("%q: %s", name, out)
		}
	}
	if got, err := netmon.OSDefaultRoute(); err == nil {
		t.Fatalf("rdtest0 resolved to %q", got.InterfaceName)
	}
	// The name reaches netmon: the current default interface (so the
	// process-wide state stays as it is) becomes netmon's OS default route.
	cur, err := netmon.DefaultRouteInterface()
	if err != nil || cur == "" {
		t.Skipf("no default route interface: %v", err)
	}
	if out := TunnelSetDefaultInterface(h, cur); out != `{"ok":true}` {
		t.Fatalf("%q: %s", cur, out)
	}
	if got, err := netmon.OSDefaultRoute(); err != nil || got.InterfaceName != cur {
		t.Fatalf("OS default route %q (%v), want %q", got.InterfaceName, err, cur)
	}
}
