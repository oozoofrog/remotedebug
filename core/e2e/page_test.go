package e2e

import (
	"bytes"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"remotedebug/core/internal/api"
)

// webDir is core/internal/host/web, the source of the embedded page files.
func webDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("no caller")
	}
	return filepath.Join(filepath.Dir(file), "..", "internal", "host", "web")
}

// TestE2EInstallPage: an unpaired tailnet device loads the install page and
// its assets while the API still refuses it; after the normal pairing flow
// the same device lists builds and opens an install session.
func TestE2EInstallPage(t *testing.T) {
	h := startHost(t)
	buildID, _ := h.publish(1000)
	dir := webDir(t)

	pages := []struct{ path, file, contentType string }{
		{"/", "index.html", "text/html; charset=utf-8"},
		{"/assets/install.css", "install.css", "text/css; charset=utf-8"},
		{"/assets/install.js", "install.js", "text/javascript; charset=utf-8"},
		{"/assets/logic.js", "logic.js", "text/javascript; charset=utf-8"},
	}
	for _, p := range pages {
		want, err := os.ReadFile(filepath.Join(dir, p.file))
		if err != nil {
			t.Fatal(err)
		}
		r := h.get(peerA, p.path)
		expectStatus(t, r, http.StatusOK, "")
		if !bytes.Equal(r.body, want) {
			t.Fatalf("GET %s: body (%d bytes) differs from %s (%d bytes)", p.path, len(r.body), p.file, len(want))
		}
		if ct := r.header.Get("Content-Type"); ct != p.contentType {
			t.Fatalf("GET %s: Content-Type %q", p.path, ct)
		}
		for k, v := range map[string]string{
			"Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
			"X-Content-Type-Options":  "nosniff",
			"Referrer-Policy":         "no-referrer",
			"Cache-Control":           "no-store",
			"X-Frame-Options":         "DENY",
		} {
			if got := r.header.Get(k); got != v {
				t.Fatalf("GET %s: %s = %q", p.path, k, got)
			}
		}
		if r.header.Get("Set-Cookie") != "" {
			t.Fatalf("GET %s: sets a cookie", p.path)
		}
		t.Logf("unpaired %s %s: %d %s, %d bytes, CSP=%q nosniff=%q referrer=%q cache=%q frame=%q",
			peerA.name, p.path, r.status, r.header.Get("Content-Type"), len(r.body),
			r.header.Get("Content-Security-Policy"), r.header.Get("X-Content-Type-Options"),
			r.header.Get("Referrer-Policy"), r.header.Get("Cache-Control"), r.header.Get("X-Frame-Options"))
	}
	head := do(t, peerA.http, "HEAD", h.base+"/", nil, nil)
	expectStatus(t, head, http.StatusOK, "")
	if len(head.body) != 0 || head.header.Get("Content-Type") != "text/html; charset=utf-8" {
		t.Fatalf("HEAD /: %d bytes, %q", len(head.body), head.header.Get("Content-Type"))
	}
	post := h.post(peerA, "/", nil)
	expectStatus(t, post, http.StatusMethodNotAllowed, "method_not_allowed")
	if post.header.Get("Allow") != "GET, HEAD" {
		t.Fatalf("POST /: Allow %q", post.header.Get("Allow"))
	}
	for _, path := range []string{"/foo", "/assets/", "/assets/%2e%2e/assets/logic.js", "/index.html"} {
		expectStatus(t, h.get(peerA, path), http.StatusNotFound, "not_found")
	}

	// The page reveals nothing: the API still refuses the unpaired node.
	r := h.get(peerA, "/v1/builds")
	expectStatus(t, r, http.StatusForbidden, "not_paired")
	if strings.Contains(string(r.body), buildID) {
		t.Fatalf("build id leaked: %s", r.body)
	}
	// Only the API request produced a denied event; the page requests did not.
	ev := h.waitEvent("denied", nil)
	if ev["path"] != "/v1/builds" || ev["suppressed"] != nil {
		t.Fatalf("first denied event: %v", ev)
	}

	// Normal pairing, exactly as the page sends it.
	var opened struct{ Code string }
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	display := strings.ToLower(opened.Code[:4] + "-" + opened.Code[4:])
	r = h.post(peerA, "/v1/pair/request", map[string]string{"code": strings.ToUpper(strings.ReplaceAll(display, "-", "")), "deviceName": "iPhone(Safari)", "platform": "Web", "clientVersion": "web-1"})
	expectStatus(t, r, http.StatusAccepted, "")
	reqID, _ := r.json(t)["requestId"].(string)
	if ev := h.waitEvent("pair-request", nil); ev["deviceName"] != "iPhone(Safari)" || ev["nodeName"] != peerA.name {
		t.Fatalf("pair-request event: %v", ev)
	}
	if out := api.HostPairingDecide(h.handle, reqID, true); apiError(out) != "" {
		t.Fatalf("decide: %s", out)
	}
	r = h.get(peerA, "/v1/pair/request/"+reqID)
	expectStatus(t, r, http.StatusOK, "")
	if r.json(t)["state"] != "approved" {
		t.Fatalf("pair state: %s", r.body)
	}

	r = h.get(peerA, "/v1/builds")
	expectStatus(t, r, http.StatusOK, "")
	if !strings.Contains(string(r.body), buildID) {
		t.Fatalf("builds: %s", r.body)
	}
	r = h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil)
	expectStatus(t, r, http.StatusCreated, "")
	m := r.json(t)
	manifest, _ := m["manifestUrl"].(string)
	if !strings.HasPrefix(manifest, h.base+"/i/") || !strings.HasSuffix(manifest, "/manifest.plist") || len(manifest) != len(h.base)+len("/i/")+43+len("/manifest.plist") {
		t.Fatalf("manifestUrl %q (page origin %q)", manifest, h.base)
	}
	// The page still loads for the paired node, unchanged.
	idx, _ := os.ReadFile(filepath.Join(dir, "index.html"))
	r = h.get(peerA, "/")
	expectStatus(t, r, http.StatusOK, "")
	if !bytes.Equal(r.body, idx) {
		t.Fatal("page differs after pairing")
	}
}
