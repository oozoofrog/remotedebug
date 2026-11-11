package host

import (
	"embed"
	"net/http"
	"strconv"

	"remotedebug/core/internal/apierr"
)

// The install web page (docs/protocol-addenda.md E): a static page that a
// tailnet device without the RemoteDebug app opens in Safari. It talks to the
// same /v1/* API as the iPhone app, so it can only show builds after the
// device is paired. The page files hold no build data and need no
// authentication.

//go:embed web/index.html web/install.css web/install.js web/logic.js
var webFiles embed.FS

type pageFile struct {
	contentType string
	body        []byte
}

// pageFiles maps the exact request path (no cleaning, no decoding) to the
// embedded file it serves.
var pageFiles = map[string]pageFile{
	"/":                  mustPageFile("web/index.html", "text/html; charset=utf-8"),
	"/assets/install.css": mustPageFile("web/install.css", "text/css; charset=utf-8"),
	"/assets/install.js":  mustPageFile("web/install.js", "text/javascript; charset=utf-8"),
	"/assets/logic.js":    mustPageFile("web/logic.js", "text/javascript; charset=utf-8"),
}

// pageHeaders are set on every page response, including 405.
var pageHeaders = [][2]string{
	{"Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"},
	{"X-Content-Type-Options", "nosniff"},
	{"Referrer-Policy", "no-referrer"},
	{"Cache-Control", "no-store"},
	{"X-Frame-Options", "DENY"},
}

const pageAllow = "GET, HEAD"

func mustPageFile(name, contentType string) pageFile {
	b, err := webFiles.ReadFile(name)
	if err != nil || len(b) == 0 {
		panic("host: missing embedded page file " + name)
	}
	return pageFile{contentType: contentType, body: b}
}

// servePage answers a request for one of the page files and reports whether
// it did. Only an exact, unencoded path matches; anything else (other paths,
// percent-encoded or dot segments, double slashes) is left to the API mux,
// which answers 404. Page requests never run WhoIs, never emit "denied"
// events and never touch the denial rate limit.
func servePage(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.EscapedPath() != r.URL.Path {
		return false
	}
	f, ok := pageFiles[r.URL.Path]
	if !ok {
		return false
	}
	h := w.Header()
	for _, kv := range pageHeaders {
		h.Set(kv[0], kv[1])
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		h.Set("Allow", pageAllow)
		apierr.Write(w, apierr.MethodNotAllowed())
		return true
	}
	h.Set("Content-Type", f.contentType)
	h.Set("Content-Length", strconv.Itoa(len(f.body)))
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		w.Write(f.body)
	}
	return true
}
