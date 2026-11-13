package host

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"remotedebug/core/internal/events"
)

func newResourceTestHost(t *testing.T, paired bool) (*Host, string) {
	t.Helper()
	dir := t.TempDir()
	h, err := New(Options{
		WhoIs: func(ctx context.Context, remoteAddr string) (Peer, error) {
			return Peer{StableID: "n_phone", NodeName: "rd-phone-00000001"}, nil
		},
		Events:     events.New(events.DefaultCapacity),
		PublishDir: dir,
		Info:       func() Info { return Info{HostID: "h_1", HostName: "Mac", FQDN: "rd-mac-1.example.ts.net"} },
		BaseURL:    func() string { return "https://rd-mac-1.example.ts.net" },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Close)
	if paired {
		if err := h.SetDevices([]DeviceEntry{{ID: "d_1", NodeStableID: "n_phone", NodeName: "rd-phone-00000001"}}); err != nil {
			t.Fatal(err)
		}
	}
	dir, _ = filepath.EvalSymlinks(dir)
	return h, dir
}

func writeResource(t *testing.T, dir, name, body string) ResourcePublishRequest {
	t.Helper()
	p := filepath.Join(dir, "resources", name)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(body))
	return ResourcePublishRequest{
		ResourceDescriptor: ResourceDescriptor{Name: name, Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])},
		Path:               p,
	}
}

func TestResourcePublishListDownload(t *testing.T) {
	h, dir := newResourceTestHost(t, true)
	req := writeResource(t, dir, "설정 파일.json", `{"a":1}`)
	id, err := h.PublishResource(req)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(id, "r_") {
		t.Fatalf("id %q", id)
	}
	// The source can change after publish; the snapshot is what is served.
	os.WriteFile(req.Path, []byte("changed"), 0o600)

	w := serve(h, "GET", "/v1/resources")
	if w.Code != http.StatusOK {
		t.Fatalf("list status %d: %s", w.Code, w.Body)
	}
	var list struct{ Resources []ResourceDescriptor }
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil || len(list.Resources) != 1 {
		t.Fatalf("list %s", w.Body)
	}
	got := list.Resources[0]
	if got.ID != id || got.Name != "설정 파일.json" || got.Size != 7 || got.SHA256 != req.SHA256 || got.PublishedAt == "" {
		t.Fatalf("descriptor %+v", got)
	}

	w = serve(h, "GET", "/v1/resources/"+id)
	if w.Code != http.StatusOK || w.Body.String() != `{"a":1}` {
		t.Fatalf("file status %d body %q", w.Code, w.Body)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/octet-stream" {
		t.Fatalf("content-type %q", ct)
	}
	if cd := w.Header().Get("Content-Disposition"); !strings.HasPrefix(cd, "attachment;") {
		t.Fatalf("content-disposition %q", cd)
	}

	r := httptest.NewRequest("GET", "/v1/resources/"+id, nil)
	r.Header.Set("Range", "bytes=1-3")
	rw := httptest.NewRecorder()
	h.Handler().ServeHTTP(rw, r)
	if rw.Code != http.StatusPartialContent || rw.Body.String() != `"a"` {
		t.Fatalf("range status %d body %q", rw.Code, rw.Body)
	}

	if err := h.UnpublishResource(id); err != nil {
		t.Fatal(err)
	}
	if w := serve(h, "GET", "/v1/resources/"+id); w.Code != http.StatusNotFound || errorCode(t, w) != "resource_not_found" {
		t.Fatalf("after unpublish %d %s", w.Code, w.Body)
	}
	if err := h.UnpublishResource(id); err == nil {
		t.Fatal("second unpublish succeeded")
	}
}

func TestResourceRequiresPairing(t *testing.T) {
	h, dir := newResourceTestHost(t, false)
	id, err := h.PublishResource(writeResource(t, dir, "a.txt", "x"))
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/v1/resources", "/v1/resources/" + id} {
		if w := serve(h, "GET", p); w.Code != http.StatusForbidden || errorCode(t, w) != "not_paired" {
			t.Fatalf("%s: %d %s", p, w.Code, w.Body)
		}
	}
}

func TestResourcePublishRejects(t *testing.T) {
	h, dir := newResourceTestHost(t, true)
	ok := writeResource(t, dir, "a.txt", "hello")

	bad := ok
	bad.SHA256 = strings.Repeat("0", 64)
	if _, err := h.PublishResource(bad); err == nil || !strings.Contains(err.Error(), "hash_mismatch") {
		t.Fatalf("hash: %v", err)
	}
	for _, name := range []string{"", ".", "..", "a/b", "a\\b", "a:b", "a\nb", strings.Repeat("x", 256)} {
		r := ok
		r.Name = name
		if _, err := h.PublishResource(r); err == nil || !strings.Contains(err.Error(), "bad_request") {
			t.Fatalf("name %q: %v", name, err)
		}
	}
	outside := ok
	outside.Path = filepath.Join(t.TempDir(), "a.txt")
	os.WriteFile(outside.Path, []byte("hello"), 0o600)
	if _, err := h.PublishResource(outside); err == nil || !strings.Contains(err.Error(), "path_outside_publish_dir") {
		t.Fatalf("outside: %v", err)
	}

	// Same name and bytes give the same id.
	id1, err := h.PublishResource(ok)
	if err != nil {
		t.Fatal(err)
	}
	id2, err := h.PublishResource(ok)
	if err != nil || id1 != id2 {
		t.Fatalf("republish %q %q %v", id1, id2, err)
	}
}

func TestResourceLinks(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	link := "sampleapp://open/item?id=42&tab=detail"
	id, err := h.PublishResource(ResourcePublishRequest{ResourceDescriptor: ResourceDescriptor{Name: "상품 42 열기", Link: link, Size: 99}})
	if err != nil {
		t.Fatal(err)
	}
	w := serve(h, "GET", "/v1/resources")
	var list struct{ Resources []ResourceDescriptor }
	json.Unmarshal(w.Body.Bytes(), &list)
	if len(list.Resources) != 1 || list.Resources[0].Link != link || list.Resources[0].Size != 0 || list.Resources[0].ID != id {
		t.Fatalf("list %s", w.Body)
	}
	sum := sha256.Sum256([]byte(link))
	if list.Resources[0].SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("sha %q", list.Resources[0].SHA256)
	}
	if w := serve(h, "GET", "/v1/resources/"+id); w.Code != http.StatusNotFound {
		t.Fatalf("link bytes served: %d", w.Code)
	}
	for _, bad := range []string{"", "no-scheme", "https://a\nb", strings.Repeat("x", 9000)} {
		if _, err := h.PublishResource(ResourcePublishRequest{ResourceDescriptor: ResourceDescriptor{Name: "x", Link: bad}}); err == nil && bad != "" {
			t.Fatalf("link %q accepted", bad)
		}
	}
	for _, ok := range []string{"maps://?q=%EC%84%9C%EC%9A%B8", "app-settings:", "mailto:a@example.com"} {
		if _, err := h.PublishResource(ResourcePublishRequest{ResourceDescriptor: ResourceDescriptor{Name: "ok", Link: ok}}); err != nil {
			t.Fatalf("link %q rejected: %v", ok, err)
		}
	}
	if err := h.UnpublishResource(id); err != nil {
		t.Fatal(err)
	}
}

func TestResourceProjectArea(t *testing.T) {
	h, dir := newResourceTestHost(t, true)
	req := writeResource(t, dir, "a.txt", "hello")
	req.Project = &ResourceProject{ID: "0a1b2c3d4e5f", Name: "SampleApp"}
	id, err := h.PublishResource(req)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.PublishResource(ResourcePublishRequest{ResourceDescriptor: ResourceDescriptor{Name: "문서", Link: "https://example.com/docs"}}); err != nil {
		t.Fatal(err)
	}
	list := func() map[string]*ResourceProject {
		w := serve(h, "GET", "/v1/resources")
		var body struct{ Resources []ResourceDescriptor }
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		out := map[string]*ResourceProject{}
		for _, r := range body.Resources {
			out[r.Name] = r.Project
		}
		return out
	}
	got := list()
	if p := got["a.txt"]; p == nil || p.ID != "0a1b2c3d4e5f" || p.Name != "SampleApp" {
		t.Fatalf("project %+v", p)
	}
	if got["문서"] != nil {
		t.Fatalf("common resource has project %+v", got["문서"])
	}
	// The common area leaves the key out so older clients see the old shape.
	if body := serve(h, "GET", "/v1/resources").Body.String(); strings.Count(body, `"project"`) != 1 {
		t.Fatalf("project key count: %s", body)
	}

	// Publishing the same id again moves it: to another project, then to common.
	req.Project = &ResourceProject{ID: "ffffffffffff", Name: "다른 앱"}
	if id2, err := h.PublishResource(req); err != nil || id2 != id {
		t.Fatalf("move %q %v", id2, err)
	}
	if p := list()["a.txt"]; p == nil || p.Name != "다른 앱" {
		t.Fatalf("moved %+v", p)
	}
	req.Project = nil
	if _, err := h.PublishResource(req); err != nil {
		t.Fatal(err)
	}
	if p := list()["a.txt"]; p != nil {
		t.Fatalf("still in project %+v", p)
	}

	for _, bad := range []ResourceProject{
		{ID: "", Name: "x"}, {ID: "abc", Name: ""}, {ID: "a/b", Name: "x"}, {ID: "a b", Name: "x"}, {ID: "한글", Name: "x"},
		{ID: strings.Repeat("a", MaxProjectIDBytes+1), Name: "x"}, {ID: "abc", Name: "a\nb"},
		{ID: "abc", Name: strings.Repeat("x", MaxProjectNameBytes+1)}, {ID: "abc", Name: "\xff"},
	} {
		r := req
		r.Project = &bad
		if _, err := h.PublishResource(r); err == nil || !strings.Contains(err.Error(), "bad_request") {
			t.Fatalf("project %+v: %v", bad, err)
		}
		link := ResourcePublishRequest{ResourceDescriptor: ResourceDescriptor{Name: "x", Link: "https://example.com", Project: &bad}}
		if _, err := h.PublishResource(link); err == nil || !strings.Contains(err.Error(), "bad_request") {
			t.Fatalf("link project %+v: %v", bad, err)
		}
	}
	edge := req
	edge.Project = &ResourceProject{ID: strings.Repeat("a", MaxProjectIDBytes), Name: strings.Repeat("x", MaxProjectNameBytes)}
	if _, err := h.PublishResource(edge); err != nil {
		t.Fatalf("limits rejected: %v", err)
	}
}
