package host

import (
	"bytes"
	"cmp"
	"encoding/xml"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
	"remotedebug/core/internal/ids"
)

type session struct {
	id         string
	token      string
	buildID    string
	peer       Peer
	created    time.Time
	expires    time.Time
	state      string // created, manifest_served, downloading, completed, expired, failed
	manifests  int
	ipaStarted bool
	size       int64
	covered    []span        // merged byte ranges of the IPA actually sent
	inflight   int           // IPA responses being streamed
	revoked    chan struct{} // closed when the session fails; aborts transfers
}

// span is the half-open byte range [start, end).
type span struct{ start, end int64 }

func (s *session) terminal() bool {
	return s.state == "completed" || s.state == "expired" || s.state == "failed"
}

// addSpan merges [a, b) into the covered ranges.
func (s *session) addSpan(a, b int64) {
	if a >= b {
		return
	}
	out := make([]span, 0, len(s.covered)+1)
	for _, c := range s.covered {
		if c.end < a || c.start > b {
			out = append(out, c)
			continue
		}
		a, b = min(a, c.start), max(b, c.end)
	}
	out = append(out, span{a, b})
	slices.SortFunc(out, func(x, y span) int { return cmp.Compare(x.start, y.start) })
	s.covered = out
}

// bytesServed is the number of distinct IPA bytes sent so far.
func (s *session) bytesServed() int64 {
	var n int64
	for _, c := range s.covered {
		n += c.end - c.start
	}
	return n
}

// fullyCovered reports whether every byte of the IPA has been sent.
func (s *session) fullyCovered() bool {
	return s.size == 0 || len(s.covered) == 1 && s.covered[0].start == 0 && s.covered[0].end >= s.size
}

// expireSessionLocked expires s by time, but never while a transfer is in
// flight (the transfer's end decides the final state).
func (h *Host) expireSessionLocked(s *session, now time.Time) {
	if !s.terminal() && s.inflight == 0 && !now.Before(s.expires) {
		s.state = "expired"
		h.emitSessionLocked(s, "")
	}
}

// failSessionLocked makes s terminal as "failed" and aborts its transfers.
func (h *Host) failSessionLocked(s *session) {
	if s.terminal() {
		return
	}
	s.state = "failed"
	close(s.revoked)
	h.emitSessionLocked(s, "")
}

func (h *Host) emitSessionLocked(s *session, userAgent string) {
	h.events.Push(events.Event{
		"type":        "session",
		"sessionId":   s.id,
		"buildId":     s.buildID,
		"nodeName":    s.peer.NodeName,
		"state":       s.state,
		"userAgent":   userAgent,
		"bytesServed": s.bytesServed(),
	})
}

func (h *Host) sessionJSON(s *session) map[string]any {
	return map[string]any{
		"sessionId":   s.id,
		"buildId":     s.buildID,
		"state":       s.state,
		"bytesServed": s.bytesServed(),
		"size":        s.size,
		"expiresAt":   Timestamp(s.expires),
	}
}

func (h *Host) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	peer, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	h.mu.Lock()
	b := h.builds[r.PathValue("id")]
	h.mu.Unlock()
	if b == nil {
		apierr.Write(w, apierr.BuildNotFound())
		return
	}
	if !b.verifyHash() { // hashing runs without the lock held
		apierr.Write(w, apierr.BuildChanged())
		return
	}

	h.mu.Lock()
	if h.builds[b.desc.ID] != b { // unpublished while hashing
		h.mu.Unlock()
		apierr.Write(w, apierr.BuildNotFound())
		return
	}
	now := h.now()
	s := &session{
		id:      ids.NewID("s_"),
		token:   ids.NewToken(),
		buildID: b.desc.ID,
		peer:    peer,
		created: now,
		expires: now.Add(h.lim.SessionTTL),
		state:   "created",
		size:    b.desc.IPA.Size,
		revoked: make(chan struct{}),
	}
	h.sessions[s.id] = s
	h.tokens[s.token] = s
	h.emitSessionLocked(s, r.UserAgent())
	h.mu.Unlock()

	manifestURL := h.baseURL() + "/i/" + s.token + "/manifest.plist"
	writeJSON(w, http.StatusCreated, map[string]any{
		"sessionId":   s.id,
		"state":       "created",
		"manifestUrl": manifestURL,
		"installUrl":  "itms-services://?action=download-manifest&url=" + url.QueryEscape(manifestURL),
		"expiresAt":   Timestamp(s.expires),
	})
}

func (h *Host) handleSessionStatus(w http.ResponseWriter, r *http.Request) {
	peer, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	h.mu.Lock()
	s := h.sessions[r.PathValue("id")]
	if s == nil || s.peer.StableID != peer.StableID {
		h.mu.Unlock()
		h.deny(w, r, apierr.TokenInvalid(), peer.NodeName)
		return
	}
	h.expireSessionLocked(s, h.now())
	resp := h.sessionJSON(s)
	h.mu.Unlock()
	writeJSON(w, http.StatusOK, resp)
}

// sessionForToken authenticates an /i/{token}/… request. On success it returns
// the session and its build with h.mu held; on failure it has written the
// response and h.mu is not held.
func (h *Host) sessionForToken(w http.ResponseWriter, r *http.Request) (*session, *build, bool) {
	peer, ok := h.requirePaired(w, r)
	if !ok {
		return nil, nil, false
	}
	h.mu.Lock()
	s := h.tokens[r.PathValue("token")]
	if s == nil || s.peer.StableID != peer.StableID {
		h.mu.Unlock()
		h.deny(w, r, apierr.TokenInvalid(), peer.NodeName)
		return nil, nil, false
	}
	h.expireSessionLocked(s, h.now())
	if s.terminal() {
		h.mu.Unlock()
		apierr.Write(w, apierr.SessionExpired())
		return nil, nil, false
	}
	b := h.builds[s.buildID]
	if b == nil { // Unpublish fails its sessions, so this is a safety net
		h.failSessionLocked(s)
		h.mu.Unlock()
		apierr.Write(w, apierr.BuildNotFound())
		return nil, nil, false
	}
	return s, b, true
}

// HEAD on /i/* answers with headers only: it uses no manifest fetch, does not
// start the download clock and changes no session state.
func (h *Host) handleManifest(w http.ResponseWriter, r *http.Request) {
	s, b, ok := h.sessionForToken(w, r)
	if !ok {
		return
	}
	head := r.Method == http.MethodHead
	if s.manifests >= h.lim.ManifestMaxFetches {
		h.mu.Unlock()
		apierr.Write(w, apierr.SessionExpired())
		return
	}
	if err := b.check(); err != nil {
		if !head {
			h.failSessionLocked(s)
		}
		h.mu.Unlock()
		apierr.Write(w, apierr.From(err))
		return
	}
	if !head {
		s.manifests++
		if s.state == "created" {
			s.state = "manifest_served"
		}
		h.emitSessionLocked(s, r.UserAgent())
	}
	ipaURL := h.baseURL() + "/i/" + s.token + "/app.ipa"
	desc := b.desc
	h.mu.Unlock()

	body := Manifest(ipaURL, desc.BundleID, desc.Version, desc.DisplayName)
	w.Header().Set("Content-Type", "text/xml")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
}

// errRevoked aborts a transfer whose session failed.
var errRevoked = errors.New("session revoked")

func (h *Host) handleIPA(w http.ResponseWriter, r *http.Request) {
	s, b, ok := h.sessionForToken(w, r)
	if !ok {
		return
	}
	head := r.Method == http.MethodHead
	f, err := b.open()
	if err != nil {
		if !head {
			h.failSessionLocked(s)
		}
		h.mu.Unlock()
		apierr.Write(w, apierr.From(err))
		return
	}
	defer f.Close()
	modTime := b.fi.ModTime()
	// Multi-range requests get the whole file (200) instead of multipart.
	if strings.Contains(r.Header.Get("Range"), ",") {
		r.Header.Del("Range")
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	if head {
		h.mu.Unlock()
		http.ServeContent(w, r, "app.ipa", modTime, f)
		return
	}
	if !s.ipaStarted {
		s.ipaStarted = true
		s.expires = s.created.Add(h.lim.SessionMaxTTL)
	}
	s.state = "downloading"
	s.inflight++
	h.emitSessionLocked(s, r.UserAgent())
	// Hard cap: the response cannot outlive SessionMaxTTL from creation.
	deadline := time.Now().Add(s.created.Add(h.lim.SessionMaxTTL).Sub(h.now()))
	h.mu.Unlock()

	rc := http.NewResponseController(w)
	rc.SetWriteDeadline(deadline)
	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() { // unblock a stalled write as soon as the session fails
		defer close(stopped)
		select {
		case <-s.revoked:
			rc.SetWriteDeadline(time.Now())
		case <-stop:
		}
	}()
	rd := &ipaReader{h: h, s: s, f: f}
	cw := &errWriter{ResponseWriter: w}
	http.ServeContent(cw, r, "app.ipa", modTime, rd)
	close(stop)
	<-stopped
	rc.SetWriteDeadline(time.Time{})
	if cw.err == nil {
		rd.commit() // the last chunk was written too
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	s.inflight--
	if rd.readErr != nil {
		h.failSessionLocked(s)
	}
	switch {
	case s.terminal():
	case s.fullyCovered():
		s.state = "completed" // token is now dead: later requests get 410
		h.emitSessionLocked(s, r.UserAgent())
	default:
		h.expireSessionLocked(s, h.now())
	}
}

// ipaReader serves the snapshot and records which byte ranges were sent. A
// chunk counts once the next Read starts (io.Copy writes each chunk fully
// before reading again) or, for the last chunk, when the response ended
// without a write error. Every Read first checks that the session is alive.
type ipaReader struct {
	h       *Host
	s       *session
	f       *os.File
	pos     int64
	pending span
	readErr error
}

func (t *ipaReader) Read(p []byte) (int, error) {
	t.commit()
	select {
	case <-t.s.revoked:
		return 0, errRevoked
	default:
	}
	n, err := t.f.Read(p)
	t.pending = span{t.pos, t.pos + int64(n)}
	t.pos += int64(n)
	if err != nil && err != io.EOF {
		t.readErr = err
	}
	return n, err
}

func (t *ipaReader) Seek(off int64, whence int) (int64, error) {
	t.pending = span{} // bytes read before a seek were not sent
	p, err := t.f.Seek(off, whence)
	if err == nil {
		t.pos = p
	}
	return p, err
}

func (t *ipaReader) commit() {
	if t.pending.end > t.pending.start {
		t.h.mu.Lock()
		t.s.addSpan(t.pending.start, t.pending.end)
		t.h.mu.Unlock()
	}
	t.pending = span{}
}

// errWriter remembers body write errors.
type errWriter struct {
	http.ResponseWriter
	err error
}

func (c *errWriter) Write(p []byte) (int, error) {
	n, err := c.ResponseWriter.Write(p)
	if err != nil && c.err == nil {
		c.err = err
	}
	return n, err
}

// ReadFrom keeps io.Copy using our Write (so errors are seen) with 32 KiB chunks.
func (c *errWriter) ReadFrom(r io.Reader) (int64, error) {
	return io.CopyBuffer(struct{ io.Writer }{c}, r, make([]byte, 32<<10))
}

// Manifest renders the OTA manifest plist (protocol §4.5).
func Manifest(ipaURL, bundleID, version, title string) []byte {
	esc := func(s string) string {
		var b bytes.Buffer
		xml.EscapeText(&b, []byte(s))
		return b.String()
	}
	var b bytes.Buffer
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>` + esc(ipaURL) + `</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>` + esc(bundleID) + `</string>
        <key>bundle-version</key><string>` + esc(version) + `</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>` + esc(title) + `</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`)
	return b.Bytes()
}
