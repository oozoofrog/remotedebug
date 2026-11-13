package host

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"remotedebug/core/internal/direct"
	"remotedebug/core/internal/events"
)

type enrollment struct {
	DirectID string `json:"directId"`
	Port     int    `json:"port"`
	TLSSPKI  string `json:"tlsSPKI"`
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
}

// newDirectTestHost returns a paired host whose direct listener is reported
// as running with fixed values.
func newDirectTestHost(t *testing.T) *Host {
	t.Helper()
	h, _ := newResourceTestHost(t, true)
	h.direct = func() (DirectInfo, bool) {
		return DirectInfo{ID: "0123456789abcdef", Port: 49152, SPKI: "c3BraQ=="}, true
	}
	return h
}

func enroll(t *testing.T, h *Host) enrollment {
	t.Helper()
	w := servePost(h, "/v1/direct/enroll", "")
	if w.Code != http.StatusOK {
		t.Fatalf("enroll status %d: %s", w.Code, w.Body)
	}
	var e enrollment
	if err := json.Unmarshal(w.Body.Bytes(), &e); err != nil {
		t.Fatal(err)
	}
	return e
}

func serveDirect(h *Host, method, target, auth string, body io.Reader) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, body)
	r.RemoteAddr = "192.168.0.20:50000"
	if auth != "" {
		r.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	h.DirectHandler().ServeHTTP(w, r)
	return w
}

func authOf(e enrollment) string { return "RD-Device " + e.DeviceID + "." + e.Token }

func TestDirectEnrollReturnsListenerAndStoresOnlyTheHash(t *testing.T) {
	h := newDirectTestHost(t)
	e := enroll(t, h)
	if e.DirectID != "0123456789abcdef" || e.Port != 49152 || e.TLSSPKI != "c3BraQ==" || e.DeviceID != "d_1" {
		t.Fatalf("enrollment %+v", e)
	}
	hash := DirectTokenHash(e.Token)
	if len(hash) != 64 {
		t.Fatalf("token %q is not a 32-byte token", e.Token)
	}
	d := h.devices["n_phone"]
	if d.DirectTokenHash != hash || strings.Contains(d.DirectTokenHash, e.Token) {
		t.Fatalf("stored %q, want hash %q", d.DirectTokenHash, hash)
	}
	// The host app learns the hash (not the token) through "device-updated".
	var updated bool
	for {
		ev := h.events.Next(0)
		if ev == nil {
			break
		}
		b, _ := json.Marshal(ev)
		if strings.Contains(string(b), e.Token) {
			t.Fatalf("token leaked into event %s", b)
		}
		if ev["type"] == "device-updated" && strings.Contains(string(b), hash) {
			updated = true
		}
	}
	if !updated {
		t.Fatal("no device-updated event with the hash")
	}
}

func TestDirectEnrollNeedsPairingAndARunningListener(t *testing.T) {
	unpaired, _ := newResourceTestHost(t, false)
	unpaired.direct = func() (DirectInfo, bool) { return DirectInfo{ID: "x", Port: 1}, true }
	if w := servePost(unpaired, "/v1/direct/enroll", ""); w.Code != http.StatusForbidden || errorCode(t, w) != "not_paired" {
		t.Fatalf("unpaired: %d %s", w.Code, w.Body)
	}
	off, _ := newResourceTestHost(t, true) // no direct listener
	if w := servePost(off, "/v1/direct/enroll", ""); w.Code != http.StatusNotFound || errorCode(t, w) != "direct_off" {
		t.Fatalf("listener off: %d %s", w.Code, w.Body)
	}
}

func TestDirectRejectsMissingWrongAndRevokedTokens(t *testing.T) {
	h := newDirectTestHost(t)
	e := enroll(t, h)
	good := authOf(e)
	if w := serveDirect(h, "GET", "/v1/info", good, nil); w.Code != http.StatusOK {
		t.Fatalf("good token: %d %s", w.Code, w.Body)
	}
	other := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	for name, auth := range map[string]string{
		"missing":      "",
		"wrong token":  "RD-Device " + e.DeviceID + "." + other,
		"wrong device": "RD-Device d_other." + e.Token,
		"wrong scheme": "Bearer " + e.DeviceID + "." + e.Token,
		"no dot":       "RD-Device " + e.Token,
		"short token":  "RD-Device " + e.DeviceID + ".abc",
	} {
		w := serveDirect(h, "GET", "/v1/info", auth, nil)
		if w.Code != http.StatusForbidden || errorCode(t, w) != "not_paired" {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
		if w.Header().Get("X-RD-Protocol") != "1" {
			t.Errorf("%s: no protocol header", name)
		}
	}
	// A failed authentication is reported like any other denial.
	var denied bool
	for ev := h.events.Next(0); ev != nil; ev = h.events.Next(0) {
		denied = denied || (ev["type"] == "denied" && ev["path"] == "/v1/info" && ev["reason"] == "not_paired")
	}
	if !denied {
		t.Error("no denied event")
	}

	// Enrolling again rotates the token: the old one stops working.
	e2 := enroll(t, h)
	if e2.Token == e.Token {
		t.Fatal("token was not rotated")
	}
	if w := serveDirect(h, "GET", "/v1/info", good, nil); w.Code != http.StatusForbidden {
		t.Fatalf("old token after rotation: %d", w.Code)
	}
	if w := serveDirect(h, "GET", "/v1/info", authOf(e2), nil); w.Code != http.StatusOK {
		t.Fatalf("new token: %d %s", w.Code, w.Body)
	}

	// Removing the device in the host app revokes direct access at once.
	if err := h.SetDevices(nil); err != nil {
		t.Fatal(err)
	}
	if w := serveDirect(h, "GET", "/v1/info", authOf(e2), nil); w.Code != http.StatusForbidden {
		t.Fatalf("revoked: %d", w.Code)
	}
	// A device entry without a hash (paired, never enrolled) cannot be used either.
	h.SetDevices([]DeviceEntry{{ID: "d_1", NodeStableID: "n_phone"}})
	if w := serveDirect(h, "GET", "/v1/info", "RD-Device d_1.", nil); w.Code != http.StatusForbidden {
		t.Fatalf("empty hash: %d", w.Code)
	}
}

func TestDirectServesOnlyTheDeviceAPI(t *testing.T) {
	h := newDirectTestHost(t)
	auth := authOf(enroll(t, h))
	for _, c := range []struct{ method, path string }{
		{"GET", "/"},
		{"GET", "/assets/app.js"},
		{"POST", "/v1/pair/request"},
		{"GET", "/v1/pair/request/pr_1"},
		{"POST", "/v1/direct/enroll"},
		{"POST", "/v1/builds/b_1/sessions"},
		{"GET", "/v1/sessions/s_1"},
		{"GET", "/i/TOKEN/manifest.plist"},
		{"GET", "/i/TOKEN/app.ipa"},
	} {
		w := serveDirect(h, c.method, c.path, auth, nil)
		if w.Code != http.StatusNotFound || errorCode(t, w) != "not_found" {
			t.Errorf("%s %s with token: %d %s", c.method, c.path, w.Code, w.Body)
		}
		// Without a token nothing about the path is revealed.
		if w := serveDirect(h, c.method, c.path, "", nil); w.Code != http.StatusForbidden {
			t.Errorf("%s %s without token: %d", c.method, c.path, w.Code)
		}
	}
	for _, path := range []string{"/v1/info", "/v1/builds", "/v1/resources", "/v1/agent"} {
		if w := serveDirect(h, "GET", path, auth, nil); w.Code != http.StatusOK {
			t.Errorf("GET %s: %d %s", path, w.Code, w.Body)
		}
	}
	if w := serveDirect(h, "POST", "/v1/info", auth, nil); w.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /v1/info: %d", w.Code)
	}
}

func TestDirectHandlersSeeTheDeviceIdentity(t *testing.T) {
	h := newDirectTestHost(t)
	h.SetDevices([]DeviceEntry{{ID: "d_1", Name: "시험 iPhone", NodeStableID: "n_phone", NodeName: "rd-phone-00000001"}})
	// WhoIs must not be consulted on the direct listener.
	h.whois = nil
	h.devices["n_phone"] = func() DeviceEntry {
		d := h.devices["n_phone"]
		d.DirectTokenHash = DirectTokenHash(base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)))
		return d
	}()
	auth := "RD-Device d_1." + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	body := `{"entries":[{"at":"2026-11-11T09:00:00Z","level":"info","source":"app","message":"hello"}]}`
	w := serveDirect(h, "POST", "/v1/logs", auth, strings.NewReader(body))
	if w.Code != http.StatusAccepted {
		t.Fatalf("logs: %d %s", w.Code, w.Body)
	}
	for ev := h.events.Next(0); ev != nil; ev = h.events.Next(0) {
		if ev["type"] == "device-log" {
			if ev["deviceId"] != "d_1" || ev["deviceName"] != "시험 iPhone" || ev["nodeName"] != "rd-phone-00000001" {
				t.Fatalf("event %v", ev)
			}
			return
		}
	}
	t.Fatal("no device-log event")
}

func TestDirectLimitsFailuresPerAddress(t *testing.T) {
	h := newDirectTestHost(t)
	now := time.Unix(1_794_387_600, 0)
	h.now = func() time.Time { return now }
	good := authOf(enroll(t, h))
	for i := 0; i < directMaxFailures; i++ {
		if w := serveDirect(h, "GET", "/v1/info", "", nil); w.Code != http.StatusForbidden {
			t.Fatalf("failure %d: %d", i, w.Code)
		}
	}
	// Blocked: even the right token is not looked at from this address.
	if w := serveDirect(h, "GET", "/v1/info", good, nil); w.Code != http.StatusTooManyRequests || errorCode(t, w) != "too_many_attempts" {
		t.Fatalf("blocked: %d %s", w.Code, w.Body)
	}
	// Another address is not affected.
	r := httptest.NewRequest("GET", "/v1/info", nil)
	r.RemoteAddr = "192.168.0.21:50000"
	r.Header.Set("Authorization", good)
	w := httptest.NewRecorder()
	h.DirectHandler().ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("other address: %d", w.Code)
	}
	now = now.Add(directFailWindow)
	if w := serveDirect(h, "GET", "/v1/info", good, nil); w.Code != http.StatusOK {
		t.Fatalf("after the window: %d", w.Code)
	}
}

func TestTailnetHandlerIgnoresDirectCredentials(t *testing.T) {
	// The tailnet listener still decides by WhoIs alone: a valid direct token
	// does not help an unknown node there.
	h := newDirectTestHost(t)
	auth := authOf(enroll(t, h))
	h.whois = func(ctx context.Context, remoteAddr string) (Peer, error) {
		return Peer{}, errors.New("unknown node")
	}
	r := httptest.NewRequest("GET", "/v1/info", nil)
	r.Header.Set("Authorization", auth)
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("tailnet with direct token: %d", w.Code)
	}
}

// pinnedClient trusts exactly one SubjectPublicKeyInfo hash, like the iPhone.
func pinnedClient(spki string) *http.Client {
	return &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, // the pin below replaces name and chain checks
			MinVersion:         tls.VersionTLS13,
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				if len(raw) == 0 {
					return errors.New("no certificate")
				}
				cert, err := x509.ParseCertificate(raw[0])
				if err != nil {
					return err
				}
				sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
				if base64.StdEncoding.EncodeToString(sum[:]) != spki {
					return errors.New("pin mismatch")
				}
				return nil
			},
		}},
	}
}

// TestDirectEndToEnd runs the real pieces together on loopback: persisted
// identity, TLS 1.3 listener, enrollment through the tailnet handler, and a
// pinned, token-authenticated client.
func TestDirectEndToEnd(t *testing.T) {
	stateDir := t.TempDir()
	id, err := direct.Load(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	allowAll := func(net.Addr) bool { return true }
	ln, err := id.Listen(direct.Options{Host: "127.0.0.1", Allow: allowAll})
	if err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	h, err := New(Options{
		WhoIs: func(ctx context.Context, remoteAddr string) (Peer, error) {
			return Peer{StableID: "n_phone", NodeName: "rd-phone-00000001"}, nil
		},
		Events:     events.New(events.DefaultCapacity),
		PublishDir: dir,
		Info:       func() Info { return Info{HostID: "h_1", HostName: "Mac", FQDN: "rd-mac-1.example.ts.net"} },
		BaseURL:    func() string { return "https://rd-mac-1.example.ts.net" },
		Direct: func() (DirectInfo, bool) {
			return DirectInfo{ID: id.ID(), Port: id.Port(), SPKI: id.SPKI()}, true
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Close)
	h.SetDevices([]DeviceEntry{{ID: "d_1", Name: "시험 iPhone", NodeStableID: "n_phone", NodeName: "rd-phone-00000001"}})
	srv := &http.Server{Handler: h.DirectHandler()}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	pub, _ := filepath.EvalSymlinks(dir)
	req := writeResource(t, pub, "notes.txt", "direct bytes")
	resID, err := h.PublishResource(req)
	if err != nil {
		t.Fatal(err)
	}

	e := enroll(t, h) // over the "tailnet" handler
	if e.Port != ln.Addr().(*net.TCPAddr).Port || len(e.DirectID) != 16 {
		t.Fatalf("enrollment %+v, listener %v", e, ln.Addr())
	}
	base := "https://127.0.0.1:" + strconv.Itoa(e.Port)
	get := func(c *http.Client, path, auth string) (*http.Response, string, error) {
		r, _ := http.NewRequest("GET", base+path, nil)
		if auth != "" {
			r.Header.Set("Authorization", auth)
		}
		resp, err := c.Do(r)
		if err != nil {
			return nil, "", err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b), nil
	}

	client := pinnedClient(e.TLSSPKI)
	resp, body, err := get(client, "/v1/info", authOf(e))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 || !strings.Contains(body, `"hostId":"h_1"`) || resp.TLS.Version != tls.VersionTLS13 {
		t.Fatalf("info: %d %s tls %x", resp.StatusCode, body, resp.TLS.Version)
	}
	if resp, body, err = get(client, "/v1/resources/"+resID, authOf(e)); err != nil || resp.StatusCode != 200 || body != "direct bytes" {
		t.Fatalf("download: %v %v %q", err, resp, body)
	}
	if resp, _, err = get(client, "/v1/info", ""); err != nil || resp.StatusCode != 403 {
		t.Fatalf("no token: %v %v", err, resp)
	}
	if resp, _, err = get(client, "/v1/pair/request/pr_1", authOf(e)); err != nil || resp.StatusCode != 404 {
		t.Fatalf("pairing on the direct port: %v %v", err, resp)
	}

	// A client pinned to another key (a spoofed advertisement) fails in the
	// handshake, before any request is written.
	if _, _, err := get(pinnedClient(base64.StdEncoding.EncodeToString(make([]byte, 32))), "/v1/info", authOf(e)); err == nil {
		t.Fatal("pin mismatch was accepted")
	}
	// TLS 1.2 is refused.
	old := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MaxVersion: tls.VersionTLS12}}}
	if _, _, err := get(old, "/v1/info", authOf(e)); err == nil {
		t.Fatal("TLS 1.2 was accepted")
	}

	// The identity survives a restart: same id, port and key.
	srv.Close()
	again, err := direct.Load(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID() != id.ID() || again.Port() != id.Port() || again.SPKI() != id.SPKI() {
		t.Fatalf("identity changed: %s/%d/%s", again.ID(), again.Port(), again.SPKI())
	}
}
