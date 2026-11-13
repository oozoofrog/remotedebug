package host

import (
	"crypto/sha256"
	"encoding/hex"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/ids"
)

// Limits for published resources (protocol-addenda H).
const (
	MaxResourceNameBytes = 255
	MaxResourceBytes     = 4 << 30
	MaxResources         = 500
)

// ResourceDescriptor is a file the host app shares with paired devices
// (protocol-addenda H).
type ResourceDescriptor struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	PublishedAt string `json:"publishedAt"`
	// Link makes this a link resource (protocol-addenda H.5): no file bytes;
	// size is 0 and sha256 is the SHA-256 of the link text.
	Link string `json:"link,omitempty"`
	// Project is the project area the resource belongs to (protocol-addenda
	// H.6). Nil means the common area.
	Project *ResourceProject `json:"project,omitempty"`
}

// ResourceProject names a project area. ID is an opaque token chosen by the
// host app (a short hash, never a path); Name is what the phone shows.
type ResourceProject struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Limits for ResourceProject.
const (
	MaxProjectIDBytes   = 64
	MaxProjectNameBytes = 255
)

// validProject accepts nil (common area) or an id of 1–64 ASCII letters,
// digits, "_" or "-" with a 1–255 byte UTF-8 name without control characters.
func validProject(p *ResourceProject) bool {
	if p == nil {
		return true
	}
	if p.ID == "" || len(p.ID) > MaxProjectIDBytes || p.Name == "" || len(p.Name) > MaxProjectNameBytes || !utf8.ValidString(p.Name) {
		return false
	}
	idOK := !strings.ContainsFunc(p.ID, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-')
	})
	return idOK && !strings.ContainsFunc(p.Name, unicode.IsControl)
}

// MaxLinkBytes bounds ResourceDescriptor.Link.
const MaxLinkBytes = 8 << 10

// validLink accepts an absolute URL with a scheme and no control characters.
func validLink(s string) bool {
	if s == "" || len(s) > MaxLinkBytes || !utf8.ValidString(s) || strings.ContainsFunc(s, unicode.IsControl) {
		return false
	}
	u, err := url.Parse(s)
	return err == nil && u.Scheme != "" // query-only or bare-scheme deep links are valid
}

// ResourcePublishRequest is the rd_host_publish_resource input.
type ResourcePublishRequest struct {
	ResourceDescriptor
	Path string `json:"path"`
}

type resource struct {
	desc ResourceDescriptor
	path string      // core-owned snapshot in snapDir
	fi   os.FileInfo // snapshot identity
}

// validResourceName accepts a single path component that a phone can save
// as is: valid UTF-8, no separators or control characters, not "." or "..".
func validResourceName(name string) bool {
	if name == "" || len(name) > MaxResourceNameBytes || !utf8.ValidString(name) || name == "." || name == ".." {
		return false
	}
	return !strings.ContainsFunc(name, func(r rune) bool {
		return r == '/' || r == '\\' || r == ':' || unicode.IsControl(r)
	})
}

// PublishResource snapshots a file inside the publish directory, checks its
// size and SHA-256 against the descriptor and makes it downloadable by paired
// devices. It returns the resource id.
func (h *Host) PublishResource(req ResourcePublishRequest) (string, error) {
	d := req.ResourceDescriptor
	if !validResourceName(d.Name) {
		return "", apierr.BadRequest("name은 255바이트 이하의 파일 이름이어야 합니다(/, \\, :, 제어 문자 불가).")
	}
	if !validProject(d.Project) {
		return "", apierr.BadRequest("project는 id(영문자·숫자·_·- 64바이트 이하)와 name(255바이트 이하, 제어 문자 불가)이 있어야 합니다.")
	}
	if d.Link != "" {
		return h.publishLink(d)
	}
	if d.Size < 0 || d.Size > MaxResourceBytes {
		return "", apierr.BadRequest("파일이 너무 큽니다(최대 4GiB).")
	}
	src, err := h.resolveIPA(req.Path)
	if err != nil {
		return "", err
	}
	snap, err := h.snapshot(src)
	if err != nil {
		return "", apierr.Internal("파일 사본을 만들지 못했습니다.")
	}
	keep := false
	defer func() {
		if !keep {
			os.Remove(snap)
		}
	}()
	fi, sum, err := hashFile(snap)
	if err != nil {
		return "", apierr.Internal("파일을 읽지 못했습니다.")
	}
	if fi.Size() != d.Size || !strings.EqualFold(sum, d.SHA256) {
		return "", apierr.HashMismatch("파일 크기 또는 SHA-256이 설명과 다릅니다.")
	}
	d.SHA256 = sum
	id := ids.ResourceID(d.Name, sum)
	if d.ID != "" && d.ID != id {
		return "", apierr.BadRequest("id가 name과 SHA-256에서 계산한 값과 다릅니다: " + id)
	}
	d.ID = id
	if _, err := time.Parse(time.RFC3339, d.PublishedAt); err != nil {
		d.PublishedAt = Timestamp(h.now())
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return "", apierr.NotRunning("노드가 종료되었습니다.")
	}
	if old := h.files[id]; old != nil {
		old.desc = d
		return id, nil
	}
	if len(h.files) >= MaxResources {
		return "", apierr.BadRequest("파일은 500개까지 공유할 수 있습니다.")
	}
	final := filepath.Join(h.snapDir, id+".res")
	if err := os.Rename(snap, final); err != nil {
		return "", apierr.Internal("파일 사본을 저장하지 못했습니다.")
	}
	keep = true
	h.files[id] = &resource{desc: d, path: final, fi: fi}
	return id, nil
}

// publishLink adds a link resource; there is no file to snapshot.
func (h *Host) publishLink(d ResourceDescriptor) (string, error) {
	if !validLink(d.Link) {
		return "", apierr.BadRequest("link는 8KiB 이하의 절대 URL이어야 합니다.")
	}
	sum := sha256.Sum256([]byte(d.Link))
	d.Size = 0
	d.SHA256 = hex.EncodeToString(sum[:])
	id := ids.ResourceID(d.Name, d.SHA256)
	if d.ID != "" && d.ID != id {
		return "", apierr.BadRequest("id가 name과 SHA-256에서 계산한 값과 다릅니다: " + id)
	}
	d.ID = id
	if _, err := time.Parse(time.RFC3339, d.PublishedAt); err != nil {
		d.PublishedAt = Timestamp(h.now())
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return "", apierr.NotRunning("노드가 종료되었습니다.")
	}
	if old := h.files[id]; old != nil {
		old.desc = d
		return id, nil
	}
	if len(h.files) >= MaxResources {
		return "", apierr.BadRequest("파일은 500개까지 공유할 수 있습니다.")
	}
	h.files[id] = &resource{desc: d}
	return id, nil
}

// UnpublishResource removes a resource and its snapshot. Downloads in flight
// keep reading the open snapshot until they finish.
func (h *Host) UnpublishResource(id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	f, ok := h.files[id]
	if !ok {
		return apierr.ResourceNotFound()
	}
	delete(h.files, id)
	if f.path != "" {
		os.Remove(f.path)
	}
	return nil
}

func (h *Host) handleResources(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.requirePaired(w, r); !ok {
		return
	}
	h.mu.Lock()
	list := make([]ResourceDescriptor, 0, len(h.files))
	for _, f := range h.files {
		list = append(list, f.desc)
	}
	h.mu.Unlock()
	slices.SortFunc(list, func(a, b ResourceDescriptor) int {
		if c := strings.Compare(b.PublishedAt, a.PublishedAt); c != 0 {
			return c // newest first
		}
		return strings.Compare(a.ID, b.ID)
	})
	writeJSON(w, http.StatusOK, map[string]any{"resources": list})
}

// handleResourceFile serves a resource's bytes (Range and HEAD supported).
func (h *Host) handleResourceFile(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.requirePaired(w, r); !ok {
		return
	}
	h.mu.Lock()
	f := h.files[r.PathValue("id")]
	h.mu.Unlock()
	if f == nil || f.desc.Link != "" { // links have no bytes; the list carries them
		apierr.Write(w, apierr.ResourceNotFound())
		return
	}
	file, err := os.Open(f.path)
	if err != nil {
		apierr.Write(w, apierr.ResourceNotFound())
		return
	}
	defer file.Close()
	if fi, err := file.Stat(); err != nil || !os.SameFile(fi, f.fi) || fi.Size() != f.fi.Size() {
		apierr.Write(w, apierr.ResourceNotFound())
		return
	}
	hdr := w.Header()
	hdr.Set("Content-Type", "application/octet-stream")
	hdr.Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": f.desc.Name}))
	hdr.Set("X-Content-Type-Options", "nosniff")
	hdr.Set("Cache-Control", "no-store")
	hdr.Set("ETag", `"`+f.desc.SHA256+`"`)
	http.ServeContent(w, r, "", f.fi.ModTime(), file)
}
