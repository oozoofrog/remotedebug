package host

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"remotedebug/core/internal/events"
)

// newPageTestHost returns a host whose WhoIs knows one unpaired node, and the
// number of WhoIs calls made so far.
func newPageTestHost(t *testing.T) (*Host, *events.Queue, *int) {
	t.Helper()
	q := events.New(events.DefaultCapacity)
	calls := 0
	h, err := New(Options{
		WhoIs: func(ctx context.Context, remoteAddr string) (Peer, error) {
			calls++
			return Peer{StableID: "n_unpaired", NodeName: "rd-phone-00000001"}, nil
		},
		Events:     q,
		PublishDir: t.TempDir(),
		Info:       func() Info { return Info{HostID: "h_1", HostName: "Mac", FQDN: "rd-mac-1.example.ts.net"} },
		BaseURL:    func() string { return "https://rd-mac-1.example.ts.net" },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Close)
	return h, q, &calls
}

func serve(h *Host, method, target string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, nil)
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	return w
}

// serveURL sends a request whose URL is set verbatim (for paths that
// httptest.NewRequest would reject or normalize).
func serveURL(h *Host, method string, u *url.URL) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "/", nil)
	r.URL = u
	r.RequestURI = u.RequestURI()
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	return w
}

func errorCode(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var v struct {
		Error struct{ Code, Message string } `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &v); err != nil {
		t.Fatalf("body is not the JSON error shape: %q", w.Body.String())
	}
	if v.Error.Message == "" {
		t.Fatalf("error without message: %q", w.Body.String())
	}
	return v.Error.Code
}

var wantPageHeaders = map[string]string{
	"Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
	"X-Content-Type-Options":  "nosniff",
	"Referrer-Policy":         "no-referrer",
	"Cache-Control":           "no-store",
	"X-Frame-Options":         "DENY",
	"X-RD-Protocol":           "1",
}

func checkPageHeaders(t *testing.T, label string, hdr http.Header) {
	t.Helper()
	for k, v := range wantPageHeaders {
		if got := hdr.Values(k); len(got) != 1 || got[0] != v {
			t.Errorf("%s: header %s = %q, want %q", label, k, got, v)
		}
	}
	if hdr.Get("Set-Cookie") != "" {
		t.Errorf("%s: sets a cookie", label)
	}
}

var pageRoutes = []struct {
	path, file, contentType string
}{
	{"/", "web/index.html", "text/html; charset=utf-8"},
	{"/assets/install.css", "web/install.css", "text/css; charset=utf-8"},
	{"/assets/install.js", "web/install.js", "text/javascript; charset=utf-8"},
	{"/assets/logic.js", "web/logic.js", "text/javascript; charset=utf-8"},
}

func TestPageRoutes(t *testing.T) {
	h, _, _ := newPageTestHost(t)
	for _, rt := range pageRoutes {
		want, err := os.ReadFile(filepath.FromSlash(rt.file))
		if err != nil || len(want) == 0 {
			t.Fatalf("%s: source file: %v", rt.file, err)
		}
		for _, target := range []string{rt.path, rt.path + "?x=1"} {
			w := serve(h, http.MethodGet, target)
			if w.Code != http.StatusOK {
				t.Fatalf("GET %s: %d %q", target, w.Code, w.Body.String())
			}
			if ct := w.Header().Get("Content-Type"); ct != rt.contentType {
				t.Errorf("GET %s: Content-Type %q, want %q", target, ct, rt.contentType)
			}
			if !bytes.Equal(w.Body.Bytes(), want) {
				t.Errorf("GET %s: body differs from %s", target, rt.file)
			}
			if cl := w.Header().Get("Content-Length"); cl != strconv.Itoa(len(want)) {
				t.Errorf("GET %s: Content-Length %q, want %d", target, cl, len(want))
			}
			checkPageHeaders(t, "GET "+target, w.Header())
		}

		w := serve(h, http.MethodHead, rt.path)
		if w.Code != http.StatusOK || w.Body.Len() != 0 {
			t.Errorf("HEAD %s: %d, %d body bytes", rt.path, w.Code, w.Body.Len())
		}
		if ct := w.Header().Get("Content-Type"); ct != rt.contentType {
			t.Errorf("HEAD %s: Content-Type %q", rt.path, ct)
		}
		if cl := w.Header().Get("Content-Length"); cl != strconv.Itoa(len(want)) {
			t.Errorf("HEAD %s: Content-Length %q, want %d", rt.path, cl, len(want))
		}
		checkPageHeaders(t, "HEAD "+rt.path, w.Header())

		for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch, http.MethodOptions} {
			w := serve(h, m, rt.path)
			if w.Code != http.StatusMethodNotAllowed || errorCode(t, w) != "method_not_allowed" {
				t.Errorf("%s %s: %d %q", m, rt.path, w.Code, w.Body.String())
			}
			if allow := w.Header().Get("Allow"); allow != "GET, HEAD" {
				t.Errorf("%s %s: Allow %q", m, rt.path, allow)
			}
			if ct := w.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("%s %s: Content-Type %q", m, rt.path, ct)
			}
			checkPageHeaders(t, m+" "+rt.path, w.Header())
		}
	}
}

func TestPageEmbeddedFilesNonEmpty(t *testing.T) {
	for _, rt := range pageRoutes {
		f, ok := pageFiles[rt.path]
		if !ok || len(f.body) < 200 {
			t.Errorf("%s: embedded file missing or too small (%d bytes)", rt.path, len(f.body))
		}
	}
	if len(pageFiles) != len(pageRoutes) {
		t.Errorf("pageFiles has %d entries, want %d", len(pageFiles), len(pageRoutes))
	}
	html := string(pageFiles["/"].body)
	for _, want := range []string{`lang="ko"`, `name="viewport"`, `src="/assets/logic.js"`, `src="/assets/install.js"`, `href="/assets/install.css"`} {
		if !strings.Contains(html, want) {
			t.Errorf("index.html lacks %s", want)
		}
	}
	// CSP forbids inline script and style, so the page must not depend on them.
	for _, bad := range []string{"<script>", "<style", " style=", "onclick=", "onload=", "javascript:", "http://", "https://"} {
		if strings.Contains(html, bad) {
			t.Errorf("index.html contains %q", bad)
		}
	}
	for _, name := range []string{"/assets/install.js", "/assets/logic.js"} {
		js := string(pageFiles[name].body)
		for _, bad := range []string{"innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "document.cookie", "http://", "https://"} {
			if strings.Contains(js, bad) {
				t.Errorf("%s contains %q", name, bad)
			}
		}
	}
}

func TestPageNotFoundVariants(t *testing.T) {
	h, _, _ := newPageTestHost(t)
	targets := []string{
		"/foo", "/index.html", "/assets", "/assets/", "/assets/install.js/", "/assets/other.js",
		"/assets/../x", "/assets/../assets/install.js", "/assets/./install.js", "/./", "/.",
		"/assets/%2e%2e/assets/install.js", "/assets/%2E%2E/x", "/%2e%2e/", "/assets/install%2Ejs",
		"/assets%2Finstall.js", "/%61ssets/install.js", "/ASSETS/install.js", "/assets/INSTALL.JS",
		"/web/index.html", "/web/logic.js", "/assets/web/logic.js",
	}
	for _, target := range targets {
		w := serve(h, http.MethodGet, target)
		if w.Code != http.StatusNotFound || errorCode(t, w) != "not_found" {
			t.Errorf("GET %s: %d %q, want 404 not_found", target, w.Code, w.Body.String())
		}
		if w.Header().Get("Content-Security-Policy") != "" || strings.Contains(w.Body.String(), "<html") {
			t.Errorf("GET %s: served page content", target)
		}
	}
	// Paths that httptest.NewRequest cannot express.
	for _, u := range []*url.URL{
		{Path: "//"},
		{Path: "//assets/install.js"},
		{Path: `/assets\install.js`},
		{Path: `\`},
		{Path: `/assets/..\install.js`},
		{Path: "/assets/install.js", RawPath: "/assets/install%2Ejs"},
	} {
		w := serveURL(h, http.MethodGet, u)
		if w.Code == http.StatusOK || w.Header().Get("Content-Security-Policy") != "" {
			t.Errorf("GET %q (raw %q): %d, page served", u.Path, u.RawPath, w.Code)
		}
		if w.Code == http.StatusNotFound && errorCode(t, w) != "not_found" {
			t.Errorf("GET %q: wrong error", u.Path)
		}
	}
}

func TestPageEmitsNoDeniedEvents(t *testing.T) {
	h, q, whois := newPageTestHost(t)
	for i := 0; i < 3; i++ {
		for _, rt := range pageRoutes {
			serve(h, http.MethodGet, rt.path)
			serve(h, http.MethodHead, rt.path)
			serve(h, http.MethodPost, rt.path)
		}
	}
	if *whois != 0 {
		t.Fatalf("page requests ran WhoIs %d times", *whois)
	}
	if ev := q.Next(10 * time.Millisecond); ev != nil {
		t.Fatalf("page requests emitted an event: %v", ev)
	}
	h.mu.Lock()
	n := len(h.denials)
	h.mu.Unlock()
	if n != 0 {
		t.Fatalf("page requests touched the denial rate limit: %d keys", n)
	}
	// The first API denial afterwards is emitted with nothing suppressed.
	if w := serve(h, http.MethodGet, "/v1/builds"); w.Code != http.StatusForbidden || errorCode(t, w) != "not_paired" {
		t.Fatalf("GET /v1/builds: %d %q", w.Code, w.Body.String())
	}
	ev := q.Next(time.Second)
	if ev == nil || ev["type"] != "denied" || ev["path"] != "/v1/builds" || ev["suppressed"] != nil {
		t.Fatalf("denied event after page requests: %v", ev)
	}
}

// TestExistingRoutesUnchanged pins the API's routing results for an unpaired
// node, so the page routes cannot shadow or alter them.
func TestExistingRoutesUnchanged(t *testing.T) {
	h, _, _ := newPageTestHost(t)
	token := strings.Repeat("A", 43)
	cases := []struct {
		method, target string
		status         int
		code           string
	}{
		{"GET", "/v1/info", 403, "not_paired"},
		{"HEAD", "/v1/info", 403, ""},
		{"GET", "/v1/builds", 403, "not_paired"},
		{"POST", "/v1/builds/b_00000000/sessions", 403, "not_paired"},
		{"GET", "/v1/sessions/s_00000000", 403, "not_paired"},
		{"GET", "/v1/pair/request/pr_00000000", 403, "not_paired"},
		{"POST", "/v1/pair/request", 400, "bad_request"},
		{"GET", "/i/" + token + "/manifest.plist", 403, "not_paired"},
		{"GET", "/i/" + token + "/app.ipa", 403, "not_paired"},
		{"POST", "/v1/info", 405, "method_not_allowed"},
		{"DELETE", "/v1/builds", 405, "method_not_allowed"},
		{"GET", "/v1/pair/request", 405, "method_not_allowed"},
		{"GET", "/nope", 404, "not_found"},
		{"GET", "/v1", 404, "not_found"},
		{"GET", "/v1/", 404, "not_found"},
		{"GET", "/i/", 404, "not_found"},
	}
	for _, c := range cases {
		w := serve(h, c.method, c.target)
		if w.Code != c.status {
			t.Errorf("%s %s: %d, want %d (%q)", c.method, c.target, w.Code, c.status, w.Body.String())
			continue
		}
		if c.code != "" && errorCode(t, w) != c.code {
			t.Errorf("%s %s: code %q, want %q", c.method, c.target, errorCode(t, w), c.code)
		}
		if w.Header().Get("X-RD-Protocol") != "1" {
			t.Errorf("%s %s: no X-RD-Protocol", c.method, c.target)
		}
		if w.Header().Get("Content-Security-Policy") != "" || w.Header().Get("Allow") != "" {
			t.Errorf("%s %s: page headers on an API route", c.method, c.target)
		}
	}
}

func TestServePageIgnoresOtherPaths(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/v1/info", nil)
	if servePage(httptest.NewRecorder(), r) {
		t.Fatal("servePage answered /v1/info")
	}
}

// TestPageWiring ties index.html to install.js: the scripts load in the order install.js needs, every element id the
// script looks up exists once, and every element the script moves focus to can take focus.
func TestPageWiring(t *testing.T) {
	html := string(pageFiles["/"].body)
	js := string(pageFiles["/assets/install.js"].body)

	// install.js reads RDLogic while it loads, so logic.js has to run first. Both are deferred, which keeps document order.
	logic := strings.Index(html, `<script src="/assets/logic.js" defer></script>`)
	install := strings.Index(html, `<script src="/assets/install.js" defer></script>`)
	if logic < 0 || install < 0 || logic > install {
		t.Errorf("index.html must load logic.js (at %d) before install.js (at %d), both with defer", logic, install)
	}
	if n := strings.Count(html, "<script"); n != 2 {
		t.Errorf("index.html has %d script tags, want 2", n)
	}

	// Every id install.js looks up with $("...") exists exactly once. The views are looked up as "view-" + name.
	ids := map[string]bool{}
	for _, m := range regexp.MustCompile(`\$\("([a-z0-9-]+)"\)`).FindAllStringSubmatch(js, -1) {
		ids[m[1]] = true
	}
	views := regexp.MustCompile(`var views = \[([^\]]*)\]`).FindStringSubmatch(js)
	if views == nil {
		t.Fatal("install.js has no views list")
	}
	for _, v := range regexp.MustCompile(`"([a-z]+)"`).FindAllStringSubmatch(views[1], -1) {
		ids["view-"+v[1]] = true
	}
	if len(ids) < 20 {
		t.Fatalf("found %d element ids in install.js; the patterns no longer match", len(ids))
	}
	for id := range ids {
		if n := strings.Count(html, `id="`+id+`"`); n != 1 {
			t.Errorf("install.js looks up #%s, index.html has %d elements with that id", id, n)
		}
	}

	// install.js calls focus() on the view headings and on the two messages. Script can only focus an element that has
	// a tabindex. The messages are announced by focus alone: a live region that becomes visible with its text already
	// in place is not read, and one that is also focused is cut off or read twice.
	headings := regexp.MustCompile(`<h2 [^>]*>`).FindAllString(html, -1)
	if len(headings) != 5 {
		t.Errorf("index.html has %d view headings, want 5", len(headings))
	}
	for _, tag := range headings {
		if !strings.Contains(tag, `tabindex="-1"`) {
			t.Errorf("heading cannot take focus: %s", tag)
		}
	}
	for _, id := range []string{"notice", "refresh-error"} {
		tag := regexp.MustCompile(`<[a-z0-9]+ [^>]*id="` + id + `"[^>]*>`).FindString(html)
		if !strings.Contains(tag, `tabindex="-1"`) {
			t.Errorf("#%s cannot take focus: %s", id, tag)
		}
		if strings.Contains(tag, "aria-live") || strings.Contains(tag, "role=") {
			t.Errorf("#%s must be announced by focus alone: %s", id, tag)
		}
	}
}
