package node

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
	"tailscale.com/types/key"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
	"remotedebug/core/internal/faketailnet"
)

func TestPublicState(t *testing.T) {
	cases := []struct {
		raw, backendErr, listenErr string
		want, wantMsg              string
	}{
		{"NoState", "", "", "Starting", ""},
		{"", "", "", "Starting", ""},
		{"Starting", "", "", "Starting", ""},
		{"NeedsLogin", "", "", "NeedsLogin", ""},
		{"NeedsMachineAuth", "", "", "NeedsMachineAuth", ""},
		{"Stopped", "", "", "Stopped", ""},
		{"Running", "", "", "Running", ""},
		{"SomethingNew", "", "", "Starting", ""},
		{"InUseOtherUser", "", "", "Error", "다른 사용자가 이 노드를 쓰고 있습니다."},
		{"NoState", "invalid key", "", "Error", "invalid key"},
		{"Running", "stale error", "", "Running", ""},
		{"Running", "", "host listener: boom", "Error", "host listener: boom"},
		{"NeedsLogin", "", "host listener: boom", "NeedsLogin", ""},
	}
	for _, c := range cases {
		got, msg := publicState(c.raw, c.backendErr, c.listenErr)
		if got != c.want || msg != c.wantMsg {
			t.Errorf("publicState(%q,%q,%q) = %q,%q; want %q,%q", c.raw, c.backendErr, c.listenErr, got, msg, c.want, c.wantMsg)
		}
	}
}

func TestNeedLoginKick(t *testing.T) {
	t0 := time.Date(2026, 11, 11, 9, 0, 0, 0, time.UTC)
	later := t0.Add(loginKickInterval)
	cases := []struct {
		name    string
		raw     string
		authURL string
		authKey bool
		now     time.Time
		want    bool
	}{
		{"expired key, no URL", "NeedsLogin", "", false, later, true},
		{"too soon", "NeedsLogin", "", false, later.Add(-time.Second), false},
		{"URL present", "NeedsLogin", "https://login.example/a", false, later, false},
		{"auth key logs in itself", "NeedsLogin", "", true, later, false},
		{"running", "Running", "", false, later, false},
	}
	for _, c := range cases {
		if got := needLoginKick(c.raw, c.authURL, c.authKey, t0, c.now); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

func TestParseConfigBounds(t *testing.T) {
	base := `"mode":"proxy","stateDir":"/x","hostname":"rd-p-1","controlURL":"http://127.0.0.1:1"`
	cases := map[string]bool{ // config fragment -> valid
		`"goMemLimitMiB":0`:                                              true,
		`"goMemLimitMiB":4096`:                                           true,
		`"goMemLimitMiB":4097`:                                           false,
		`"goMemLimitMiB":17592186044416`:                                 false,
		`"goMemLimitMiB":-1`:                                             false,
		`"allowedTargets":["rd-mac-a.example.ts.net:443"]`:               true,
		`"allowedTargets":["100.64.0.10:443","[fd7a:115c:a1e0::5]:443"]`: true,
		`"allowedTargets":["example.com:443"]`:                           false,
		`"allowedTargets":["8.8.8.8:443"]`:                               false,
		`"allowedTargets":["rd-mac-a.example.ts.net"]`:                   false,
	}
	for frag, valid := range cases {
		_, err := ParseConfig("{" + base + "," + frag + "}")
		var e *apierr.Error
		if valid != (err == nil) || (!valid && (!errors.As(err, &e) || e.Code != "invalid_config")) {
			t.Errorf("%s: err %v", frag, err)
		}
	}
}

func TestRotatingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.log")
	f, err := openRotatingFile(path, 100)
	if err != nil {
		t.Fatal(err)
	}
	line := []byte("0123456789012345678901234567890123456789\n") // 41 bytes
	for i := 0; i < 10; i++ {
		f.Write(line)
	}
	f.Close()
	cur, _ := os.Stat(path)
	old, err := os.Stat(path + ".1")
	if err != nil || cur.Size() > 100 || old.Size() > 100 {
		t.Fatalf("sizes: cur %v old %v err %v", cur.Size(), old, err)
	}
}

// testNode is a minimal Node for exercising background loops directly.
func testNode() *Node {
	n := &Node{
		cfg:          &Config{Hostname: "rd-mac-test"},
		events:       events.New(events.DefaultCapacity),
		backend:      "Running",
		fqdn:         "rd-mac-test.example.ts.net",
		certRetryMin: time.Millisecond,
		certRetryMax: 4 * time.Millisecond,
	}
	n.ctx, n.cancel = context.WithCancel(context.Background())
	n.logger = log.New(io.Discard, "", 0)
	return n
}

func TestCertLoopRetries(t *testing.T) {
	n := testNode()
	defer n.cancel()
	var calls atomic.Int32
	n.certFn = func(ctx context.Context, fqdn string) error {
		if fqdn != "rd-mac-test.example.ts.net" {
			t.Errorf("fqdn %q", fqdn)
		}
		if calls.Add(1) < 4 {
			return errors.New("acme: temporary failure")
		}
		return nil
	}
	n.certLoop()
	if calls.Load() != 4 || !n.Status().TLSReady {
		t.Fatalf("calls %d, tlsReady %v", calls.Load(), n.Status().TLSReady)
	}
}

func TestCertLoopStopsOnClose(t *testing.T) {
	n := testNode()
	n.certRetryMin, n.certRetryMax = time.Hour, time.Hour
	n.certFn = func(context.Context, string) error { return errors.New("no cert") }
	done := make(chan struct{})
	go func() { n.certLoop(); close(done) }()
	time.Sleep(50 * time.Millisecond)
	n.cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("certLoop did not stop")
	}
	if n.Status().TLSReady {
		t.Fatal("tlsReady without a certificate")
	}
}

// TestListenTLSHonorsContext: the TLS listener waits for Running with the
// caller's context, so a backend that never runs cannot block it forever.
func TestListenTLSHonorsContext(t *testing.T) {
	srv := &tsnet.Server{
		Dir:        t.TempDir(),
		Hostname:   "rd-mac-ctx",
		ControlURL: "http://127.0.0.1:1", // nothing listens: never Running
		Ephemeral:  true,
		UserLogf:   func(string, ...any) {},
		Logf:       func(string, ...any) {},
	}
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := listenTailnetTLS(ctx, srv, 443); err == nil {
		t.Fatal("listener without a running backend")
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("returned after %v", d)
	}
}

// TestStopWhileListenerBlocked: rd_stop returns even when the host listener
// is stuck waiting on the backend (e.g. it left Running mid-call).
func TestStopWhileListenerBlocked(t *testing.T) {
	env, err := faketailnet.Start(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer env.Close()
	called := make(chan struct{}, 1)
	listenTLSFunc = func(ctx context.Context, _ *tsnet.Server, _ int) (net.Listener, error) {
		called <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}
	t.Cleanup(func() { listenTLSFunc = listenTailnetTLS })

	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "pub"), 0o755)
	tls := true
	n, err := Start(&Config{
		Mode: "host", StateDir: filepath.Join(dir, "state"), Hostname: "rd-mac-stop", ControlURL: env.ControlURL,
		Ephemeral: true, ListenTLS: &tls, Port: 443, PublishDir: filepath.Join(dir, "pub"),
	}, Options{})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-called:
	case <-time.After(60 * time.Second):
		n.Close()
		t.Fatal("listener never attempted")
	}
	closed := make(chan struct{})
	go func() { n.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(20 * time.Second):
		t.Fatal("Close deadlocked")
	}
	if st := n.Status(); st.BackendState != "Stopped" {
		t.Fatalf("state %q", st.BackendState)
	}
}

func TestPathOf(t *testing.T) {
	cases := []struct {
		name string
		ps   *ipnstate.PeerStatus
		want *PeerPath
	}{
		{"nil", nil, nil},
		{"direct", &ipnstate.PeerStatus{CurAddr: "192.168.0.10:41641", Relay: "tok", Active: true}, &PeerPath{Direct: true, Addr: "192.168.0.10:41641", Relay: "tok"}},
		{"relayed", &ipnstate.PeerStatus{Relay: "tok", Active: true}, &PeerPath{Relay: "tok"}},
		{"idle", &ipnstate.PeerStatus{Relay: "tok"}, nil},
	}
	for _, c := range cases {
		if got := pathOf(c.ps); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestPathLookup(t *testing.T) {
	st := &ipnstate.Status{Peer: map[key.NodePublic]*ipnstate.PeerStatus{
		key.NewNode().Public(): {ID: "nMac1", DNSName: "RD-Mac-Test.example.ts.net.", CurAddr: "192.168.0.10:41641", Relay: "tok"},
		key.NewNode().Public(): {ID: "nPhone1", DNSName: "rd-phone-a.example.ts.net.", Relay: "tok", Active: true},
		key.NewNode().Public(): {ID: "nPhone2", DNSName: "rd-phone-b.example.ts.net.", Relay: "tok"},
	}}
	if p := pathToName(st, "rd-mac-test.example.ts.net"); p == nil || !p.Direct || p.Addr != "192.168.0.10:41641" {
		t.Errorf("by name: %+v", p)
	}
	if p := pathToName(st, "other.example.ts.net"); p != nil {
		t.Errorf("unknown peer: %+v", p)
	}
	if p := pathToName(st, ""); p != nil {
		t.Errorf("no target: %+v", p)
	}
	got := pathsToDevices(st, []string{"nPhone1", "nPhone2", "nGone"})
	want := map[string]PeerPath{"nPhone1": {Relay: "tok"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("devices: got %+v, want %+v", got, want)
	}
	if got := pathsToDevices(st, nil); got != nil {
		t.Errorf("no devices: %+v", got)
	}
}

func TestStatusPeerPath(t *testing.T) {
	n := testNode()
	raw := func() map[string]json.RawMessage {
		b, err := json.Marshal(n.Status())
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]json.RawMessage
		json.Unmarshal(b, &m)
		return m
	}
	m := raw()
	if _, ok := m["peerPath"]; ok {
		t.Errorf("peerPath without a peer: %s", m["peerPath"])
	}
	if _, ok := m["peerPaths"]; ok {
		t.Errorf("peerPaths without devices: %s", m["peerPaths"])
	}

	n.SetPathPeer("RD-Mac-Test.example.ts.net.")
	if n.pathPeer != "rd-mac-test.example.ts.net" {
		t.Errorf("pathPeer = %q", n.pathPeer)
	}
	n.peerPath = &PeerPath{Direct: true, Addr: "192.168.0.10:41641", Relay: "tok"}
	n.peerPaths = map[string]PeerPath{"nPhone1": {Relay: "tok"}}
	m = raw()
	if got := string(m["peerPath"]); got != `{"direct":true,"addr":"192.168.0.10:41641","relay":"tok"}` {
		t.Errorf("peerPath = %s", got)
	}
	if got := string(m["peerPaths"]); got != `{"nPhone1":{"direct":false,"relay":"tok"}}` {
		t.Errorf("peerPaths = %s", got)
	}

	// A new target forgets the old peer's path.
	n.SetPathPeer("other.example.ts.net")
	if _, ok := raw()["peerPath"]; ok {
		t.Error("peerPath kept after the target changed")
	}
	// Not Running: no path.
	n.SetPathPeer("")
	n.peerPath = &PeerPath{Relay: "tok"}
	n.backend = "NeedsLogin"
	if _, ok := raw()["peerPath"]; ok {
		t.Error("peerPath while not Running")
	}
}
