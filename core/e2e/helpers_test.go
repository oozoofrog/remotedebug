package e2e

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/tsnet"

	"remotedebug/core/internal/api"
	"remotedebug/core/internal/faketailnet"
	"remotedebug/core/internal/host"
	"remotedebug/core/internal/node"
)

var (
	env          *faketailnet.Env
	peerA, peerB *peer
	tmpRoot      string
	hostSeq      atomic.Int32
)

func TestMain(m *testing.M) {
	os.Exit(run(m))
}

func run(m *testing.M) int {
	var err error
	tmpRoot, err = os.MkdirTemp("", "rd-e2e-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(tmpRoot)
	env, err = faketailnet.Start(nil)
	if err != nil {
		panic(err)
	}
	defer env.Close()
	peerA = startPeer("rd-phone-aaaa0001")
	defer peerA.srv.Close()
	peerB = startPeer("rd-phone-bbbb0002")
	defer peerB.srv.Close()
	return m.Run()
}

// peer is a client tsnet node standing in for an iPhone.
type peer struct {
	srv      *tsnet.Server
	http     *http.Client
	stableID string
	name     string
}

func startPeer(hostname string) *peer {
	srv := &tsnet.Server{
		Dir:        filepath.Join(tmpRoot, hostname),
		Hostname:   hostname,
		ControlURL: env.ControlURL,
		Ephemeral:  true,
		UserLogf:   func(string, ...any) {},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	st, err := srv.Up(ctx)
	if err != nil {
		panic(err)
	}
	return &peer{srv: srv, http: srv.HTTPClient(), stableID: string(st.Self.ID), name: hostname}
}

// fakeClock is the injectable clock for TTL tests.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock { return &fakeClock{t: time.Date(2026, 11, 11, 9, 0, 0, 0, time.UTC)} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// testHost is a host-mode core started through the JSON API.
type testHost struct {
	t          *testing.T
	handle     int64
	base       string // http://<fqdn>:<port>
	fqdn       string
	port       int
	publishDir string
	clock      *fakeClock
}

func startHost(t *testing.T) *testHost {
	t.Helper()
	return startHostWith(t, host.Limits{})
}

// startHostWith starts a host with overridden protocol limits.
func startHostWith(t *testing.T, limits host.Limits) *testHost {
	t.Helper()
	n := hostSeq.Add(1)
	name := fmt.Sprintf("rd-mac-%08d", n)
	dir := t.TempDir()
	publishDir := filepath.Join(dir, "published")
	os.MkdirAll(publishDir, 0o755)
	clock := newFakeClock()
	cfg := map[string]any{
		"mode":       "host",
		"stateDir":   filepath.Join(dir, "state"),
		"hostname":   name,
		"controlURL": env.ControlURL,
		"ephemeral":  true,
		"listenTLS":  false,
		"port":       8080,
		"publishDir": publishDir,
	}
	out := api.StartWithOptions(mustJSON(cfg), node.Options{Now: clock.Now, Limits: limits})
	var started struct{ Handle int64 }
	mustDecode(t, out, &started)
	if started.Handle == 0 {
		t.Fatalf("rd_start: %s", out)
	}
	h := &testHost{t: t, handle: started.Handle, port: 8080, publishDir: publishDir, clock: clock}
	t.Cleanup(func() { api.Stop(h.handle) })

	deadline := time.Now().Add(60 * time.Second)
	for {
		var st node.Status
		mustDecode(t, api.Status(h.handle), &st)
		if st.BackendState == "Running" && st.Listening && st.FQDN != "" {
			h.fqdn = st.FQDN
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("host did not become ready: %+v", st)
		}
		time.Sleep(100 * time.Millisecond)
	}
	h.base = fmt.Sprintf("http://%s:%d", h.fqdn, h.port)
	return h
}

func mustJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func mustDecode(t *testing.T, s string, v any) {
	t.Helper()
	if err := json.Unmarshal([]byte(s), v); err != nil {
		t.Fatalf("decode %q: %v", s, err)
	}
}

// apiError returns the error code of a C API result, or "".
func apiError(s string) string {
	var v struct {
		Error *struct{ Code string } `json:"error"`
	}
	json.Unmarshal([]byte(s), &v)
	if v.Error == nil {
		return ""
	}
	return v.Error.Code
}

// response is a decoded HTTP response.
type response struct {
	status int
	header http.Header
	body   []byte
}

func (r response) json(t *testing.T) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(r.body, &m); err != nil {
		t.Fatalf("body is not JSON (%d): %q", r.status, r.body)
	}
	return m
}

func (r response) errorCode() string {
	var v struct {
		Error struct{ Code string } `json:"error"`
	}
	json.Unmarshal(r.body, &v)
	return v.Error.Code
}

// do sends a request from client c, retrying dial errors while the netmap
// propagates the new host.
func do(t *testing.T, c *http.Client, method, url string, body any, header map[string]string) response {
	t.Helper()
	var payload []byte
	if body != nil {
		payload = []byte(mustJSON(body))
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		req, _ := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(payload))
		for k, v := range header {
			req.Header.Set(k, v)
		}
		resp, err := c.Do(req)
		if err == nil {
			b, rerr := io.ReadAll(resp.Body)
			resp.Body.Close()
			cancel()
			if rerr != nil {
				t.Fatalf("%s %s: read: %v", method, url, rerr)
			}
			return response{status: resp.StatusCode, header: resp.Header, body: b}
		}
		cancel()
		if time.Now().After(deadline) {
			t.Fatalf("%s %s: %v", method, url, err)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (h *testHost) get(p *peer, path string) response {
	return do(h.t, p.http, "GET", h.base+path, nil, nil)
}

func (h *testHost) post(p *peer, path string, body any) response {
	return do(h.t, p.http, "POST", h.base+path, body, nil)
}

// expectStatus fails unless r has the status and (if non-empty) error code.
func expectStatus(t *testing.T, r response, status int, code string) {
	t.Helper()
	if r.status != status || (code != "" && r.errorCode() != code) {
		body := r.body
		if len(body) > 300 {
			body = append(body[:300:300], "…"...)
		}
		t.Fatalf("got %d %q, want %d %s", r.status, body, status, code)
	}
	if r.header.Get("X-RD-Protocol") != "1" {
		t.Fatalf("missing X-RD-Protocol header: %v", r.header)
	}
}

// waitEvent drains events until one matches typ and pred.
func (h *testHost) waitEvent(typ string, pred func(map[string]any) bool) map[string]any {
	h.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		var v struct{ Event map[string]any }
		mustDecode(h.t, api.NextEvent(h.handle, 500), &v)
		if v.Event != nil && v.Event["type"] == typ && (pred == nil || pred(v.Event)) {
			return v.Event
		}
	}
	h.t.Fatalf("no %q event", typ)
	return nil
}

// setDevices puts peers on the allow-list directly.
func (h *testHost) setDevices(peers ...*peer) {
	h.t.Helper()
	var list []map[string]any
	for i, p := range peers {
		list = append(list, map[string]any{"id": fmt.Sprintf("d_%08d", i), "name": p.name, "nodeStableId": p.stableID, "nodeName": p.name})
	}
	if out := api.HostSetDevices(h.handle, mustJSON(map[string]any{"devices": list})); apiError(out) != "" {
		h.t.Fatalf("set_devices: %s", out)
	}
}

// writeIPA writes size pseudo-random bytes and returns path and SHA-256.
func writeIPA(t *testing.T, dir, name string, size int) (string, string) {
	t.Helper()
	b := make([]byte, size)
	for i := range b {
		b[i] = byte(i*7 + i/251)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	return p, hex.EncodeToString(sum[:])
}

func descriptor(path, sum string, size int) map[string]any {
	return map[string]any{
		"bundleId":              "com.example.app.Sample",
		"displayName":           "Sample",
		"version":               "1.4.0",
		"buildNumber":           "128",
		"minOS":                 "26.0",
		"debug":                 true,
		"configuration":         "Debug",
		"configurationEvidence": "path",
		"signing": map[string]any{
			"teamId": "ABCDE12345", "profileName": "Dev", "profileExpires": "2027-05-01T00:00:00Z",
			"provisionedDeviceCount": 1, "getTaskAllow": true,
		},
		"ipa":     map[string]any{"size": size, "sha256": sum},
		"ipaPath": path,
	}
}

// publish writes and publishes a build; it returns the build id and path.
func (h *testHost) publish(size int) (string, string) {
	h.t.Helper()
	path, sum := writeIPA(h.t, h.publishDir, "Sample.ipa", size)
	return h.publishFile(path, sum, size), path
}

// publishFile publishes an existing IPA and returns the build id.
func (h *testHost) publishFile(path, sum string, size int) string {
	h.t.Helper()
	out := api.HostPublish(h.handle, mustJSON(descriptor(path, sum, size)))
	var v struct {
		OK bool
		ID string
	}
	mustDecode(h.t, out, &v)
	if !v.OK || v.ID == "" {
		h.t.Fatalf("publish: %s", out)
	}
	return v.ID
}

// snapshotPath is where the core keeps the served copy of a build.
func (h *testHost) snapshotPath(buildID string) string {
	return filepath.Join(h.publishDir, host.SnapshotDirName, buildID+".ipa")
}

// newSession creates an install session for peer p and returns its id and
// the "/i/<token>" path prefix.
func (h *testHost) newSession(p *peer, buildID string) (string, string) {
	h.t.Helper()
	r := h.post(p, "/v1/builds/"+buildID+"/sessions", nil)
	expectStatus(h.t, r, http.StatusCreated, "")
	m := r.json(h.t)
	return m["sessionId"].(string), strings.TrimSuffix(strings.TrimPrefix(m["manifestUrl"].(string), h.base), "/manifest.plist")
}

// sessionState returns the session's state and bytesServed as seen by p.
func (h *testHost) sessionState(p *peer, id string) (string, float64) {
	h.t.Helper()
	r := h.get(p, "/v1/sessions/"+id)
	expectStatus(h.t, r, http.StatusOK, "")
	m := r.json(h.t)
	n, _ := m["bytesServed"].(float64)
	return m["state"].(string), n
}

// openStream starts a GET whose body the caller reads at its own pace, so a
// transfer can be held in flight. It reads the first n bytes before returning.
func openStream(t *testing.T, c *http.Client, url string, n int) (*http.Response, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: %d", url, resp.StatusCode)
	}
	head := make([]byte, n)
	if _, err := io.ReadFull(resp.Body, head); err != nil {
		t.Fatalf("read head: %v", err)
	}
	return resp, head
}

// connectVia opens a CONNECT tunnel through the loopback proxy.
func connectVia(proxyAddr, target string) (net.Conn, int, error) {
	c, err := net.DialTimeout("tcp", proxyAddr, 5*time.Second)
	if err != nil {
		return nil, 0, err
	}
	c.SetDeadline(time.Now().Add(30 * time.Second))
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: "CONNECT"})
	if err != nil {
		c.Close()
		return nil, 0, err
	}
	if resp.StatusCode != http.StatusOK {
		c.Close()
		return nil, resp.StatusCode, nil
	}
	c.SetDeadline(time.Time{})
	if br.Buffered() > 0 {
		return nil, 0, fmt.Errorf("unexpected bytes after CONNECT response")
	}
	return c, resp.StatusCode, nil
}
