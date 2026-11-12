// Package host implements the RemoteDebug host REST API (protocol §3-5):
// WhoIs-based allow-list, pairing, builds, install sessions and IPA serving.
package host

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"sync"
	"time"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
)

// WhoIsFunc resolves the tailnet identity behind a connection's remote address.
type WhoIsFunc func(ctx context.Context, remoteAddr string) (Peer, error)

// Options configures a Host.
type Options struct {
	WhoIs      WhoIsFunc        // required
	Now        func() time.Time // nil means time.Now
	Events     *events.Queue    // required
	PublishDir string           // required
	Info       func() Info      // required; read on each request
	BaseURL    func() string    // required; e.g. https://<fqdn>
	Limits     Limits
}

// Host holds the in-memory host state. All methods are safe for concurrent use.
type Host struct {
	whois      WhoIsFunc
	now        func() time.Time
	events     *events.Queue
	publishDir string // absolute, symlinks resolved
	info       func() Info
	baseURL    func() string
	lim        Limits

	snapDir string // publishDir/.rd-snapshots, owned by the core

	mu       sync.Mutex
	closed   bool
	devices  map[string]DeviceEntry // by node StableID
	code     *pairCode
	requests map[string]*pairRequest
	builds   map[string]*build
	files    map[string]*resource // by resource id
	sessions map[string]*session // by session id
	tokens   map[string]*session // by token
	denials  map[string]*denial  // denied-event rate limit, by node + path
}

// denial is the rate-limit state of "denied" events for one node and path.
type denial struct {
	last       time.Time
	suppressed int
}

// Denied events are limited to one per node and path in this window; the
// next emitted event carries the number suppressed in between.
const (
	deniedWindow   = 5 * time.Second
	maxDenialKeys  = 1024
	denialOverflow = "\x00*" // shared path key once maxDenialKeys is reached
)

// New validates opts and returns a Host.
func New(opts Options) (*Host, error) {
	dir, err := resolvePublishDir(opts.PublishDir)
	if err != nil {
		return nil, err
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	snapDir, err := resetSnapshotDir(dir)
	if err != nil {
		return nil, err
	}
	return &Host{
		whois:      opts.WhoIs,
		now:        now,
		events:     opts.Events,
		publishDir: dir,
		snapDir:    snapDir,
		info:       opts.Info,
		baseURL:    opts.BaseURL,
		lim:        opts.Limits.withDefaults(),
		devices:    map[string]DeviceEntry{},
		requests:   map[string]*pairRequest{},
		builds:     map[string]*build{},
		files:      map[string]*resource{},
		sessions:   map[string]*session{},
		tokens:     map[string]*session{},
		denials:    map[string]*denial{},
	}, nil
}

// Handler returns the HTTP handler for the tailnet listener.
func (h *Host) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", h.handleInfo)
	mux.HandleFunc("GET /v1/builds", h.handleBuilds)
	mux.HandleFunc("POST /v1/pair/request", h.handlePairRequest)
	mux.HandleFunc("GET /v1/pair/request/{id}", h.handlePairStatus)
	mux.HandleFunc("POST /v1/builds/{id}/sessions", h.handleCreateSession)
	mux.HandleFunc("GET /v1/sessions/{id}", h.handleSessionStatus)
	mux.HandleFunc("POST /v1/logs", h.handleDeviceLogs)
	mux.HandleFunc("GET /v1/resources", h.handleResources)
	mux.HandleFunc("GET /v1/resources/{id}", h.handleResourceFile)
	mux.HandleFunc("GET /i/{token}/manifest.plist", h.handleManifest)
	mux.HandleFunc("GET /i/{token}/app.ipa", h.handleIPA)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-RD-Protocol", "1")
		if servePage(w, r) {
			return
		}
		if _, pattern := mux.Handler(r); pattern == "" {
			apierr.Write(w, routeError(mux, r))
			return
		}
		mux.ServeHTTP(w, r)
	})
}

// routeError tells an unknown path (404 not_found) from a known path used
// with the wrong method (405 method_not_allowed).
func routeError(mux *http.ServeMux, r *http.Request) *apierr.Error {
	for _, m := range []string{http.MethodGet, http.MethodPost} {
		probe := r.Clone(r.Context())
		probe.Method = m
		if _, pattern := mux.Handler(probe); pattern != "" {
			return apierr.MethodNotAllowed()
		}
	}
	return apierr.NotFound()
}

// Close fails every open session (aborting transfers in flight) and removes
// the build and resource snapshots. The host serves nothing afterwards.
func (h *Host) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for _, s := range h.sessions {
		h.failSessionLocked(s)
	}
	for id, b := range h.builds {
		os.Remove(b.path)
		delete(h.builds, id)
	}
	for id, f := range h.files {
		if f.path != "" {
			os.Remove(f.path)
		}
		delete(h.files, id)
	}
}

// Counts returns the number of published builds and paired devices.
func (h *Host) Counts() (builds, devices int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.builds), len(h.devices)
}

// Sweep expires pending pair requests and sessions and forgets old records.
// The core calls it periodically; handlers also expire lazily.
func (h *Host) Sweep() {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	for id, pr := range h.requests {
		h.expirePairLocked(pr, now)
		if pr.state != "pending" && now.Sub(pr.expires) > time.Hour {
			delete(h.requests, id)
		}
	}
	for id, s := range h.sessions {
		h.expireSessionLocked(s, now)
		if s.terminal() && s.inflight == 0 && now.Sub(s.expires) > time.Hour {
			delete(h.sessions, id)
			delete(h.tokens, s.token)
		}
	}
	for k, d := range h.denials {
		if d.suppressed == 0 && now.Sub(d.last) >= deniedWindow {
			delete(h.denials, k)
		}
	}
}

// identify runs WhoIs; failure maps to 403 not_paired.
func (h *Host) identify(w http.ResponseWriter, r *http.Request) (Peer, bool) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	p, err := h.whois(ctx, r.RemoteAddr)
	if err != nil || p.StableID == "" {
		h.deny(w, r, apierr.NotPaired(), "")
		return Peer{}, false
	}
	return p, true
}

// requirePaired enforces allow-list authentication (protocol §3).
func (h *Host) requirePaired(w http.ResponseWriter, r *http.Request) (Peer, bool) {
	p, ok := h.identify(w, r)
	if !ok {
		return p, false
	}
	h.mu.Lock()
	_, paired := h.devices[p.StableID]
	h.mu.Unlock()
	if !paired {
		h.deny(w, r, apierr.NotPaired(), p.NodeName)
		return p, false
	}
	return p, true
}

// deny writes an authorization failure and emits a rate-limited "denied" event.
func (h *Host) deny(w http.ResponseWriter, r *http.Request, e *apierr.Error, nodeName string) {
	path := redactPath(r.URL.Path)
	if suppressed, ok := h.allowDenied(nodeName, path); ok {
		ev := events.Event{"type": "denied", "path": path, "reason": e.Code}
		if nodeName != "" {
			ev["nodeName"] = nodeName
		}
		if suppressed > 0 {
			ev["suppressed"] = suppressed
		}
		h.events.Push(ev)
	}
	apierr.Write(w, e)
}

// allowDenied reports whether a "denied" event for node and path may be
// emitted now, and how many were suppressed since the last one.
func (h *Host) allowDenied(node, path string) (int, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	key := node + "\x00" + path
	d := h.denials[key]
	if d == nil && len(h.denials) >= maxDenialKeys {
		key = node + denialOverflow
		d = h.denials[key]
	}
	if d == nil {
		h.denials[key] = &denial{last: now}
		return 0, true
	}
	if now.Sub(d.last) < deniedWindow {
		d.suppressed++
		return 0, false
	}
	n := d.suppressed
	d.last, d.suppressed = now, 0
	return n, true
}

// redactPath hides install tokens so they never reach events or logs.
func redactPath(p string) string {
	const prefix = "/i/"
	if len(p) > len(prefix) && p[:len(prefix)] == prefix {
		rest := p[len(prefix):]
		for i := 0; i < len(rest); i++ {
			if rest[i] == '/' {
				return prefix + "…" + rest[i:]
			}
		}
		return prefix + "…"
	}
	return p
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// UpdatePageURL reports the official-Tailscale address of the iPhone app's
// update page (protocol-addenda I), or "". The api package wires it.
var UpdatePageURL = func() string { return "" }

func (h *Host) handleInfo(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.requirePaired(w, r); !ok {
		return
	}
	info := h.info()
	n, _ := h.Counts()
	body := map[string]any{
		"hostId":     info.HostID,
		"hostName":   info.HostName,
		"fqdn":       info.FQDN,
		"protocol":   1,
		"appVersion": info.AppVersion,
		"buildCount": n,
	}
	if u := UpdatePageURL(); u != "" {
		body["updatePage"] = u
	}
	writeJSON(w, http.StatusOK, body)
}
