package host

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/ids"
)

type build struct {
	desc BuildDescriptor
	path string      // core-owned snapshot in snapDir; the only file served
	fi   os.FileInfo // snapshot identity (dev/inode, size, mtime)
	sum  string      // snapshot SHA-256; unlike desc, never changes
}

// SnapshotDirName is the core-owned folder inside publishDir that holds the
// immutable copies of published IPAs.
const SnapshotDirName = ".rd-snapshots"

func resolvePublishDir(dir string) (string, error) {
	if dir == "" {
		return "", apierr.InvalidConfig("publishDir가 필요합니다.")
	}
	abs, err := filepath.Abs(dir)
	if err == nil {
		abs, err = filepath.EvalSymlinks(abs)
	}
	if err != nil {
		return "", apierr.InvalidConfig("publishDir를 찾을 수 없습니다.")
	}
	if fi, err := os.Stat(abs); err != nil || !fi.IsDir() {
		return "", apierr.InvalidConfig("publishDir가 폴더가 아닙니다.")
	}
	return abs, nil
}

// resetSnapshotDir empties (or creates) the snapshot folder. Leftovers come
// from a previous run that did not stop cleanly.
func resetSnapshotDir(publishDir string) (string, error) {
	dir := filepath.Join(publishDir, SnapshotDirName)
	if err := os.RemoveAll(dir); err != nil {
		return "", apierr.InvalidConfig("게시 폴더의 " + SnapshotDirName + "를 비울 수 없습니다.")
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		return "", apierr.InvalidConfig("게시 폴더에 " + SnapshotDirName + "를 만들 수 없습니다.")
	}
	return dir, nil
}

// resolveIPA returns the symlink-free path of ipaPath if it is a regular file
// inside the publish directory (and not one of the core's snapshots).
func (h *Host) resolveIPA(ipaPath string) (string, error) {
	if ipaPath == "" || !filepath.IsAbs(ipaPath) {
		return "", apierr.PathOutsidePublishDir()
	}
	p, err := filepath.EvalSymlinks(ipaPath)
	if err != nil {
		return "", apierr.PathOutsidePublishDir()
	}
	rel, err := filepath.Rel(h.publishDir, p)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) ||
		strings.HasPrefix(rel, SnapshotDirName+string(filepath.Separator)) {
		return "", apierr.PathOutsidePublishDir()
	}
	fi, err := os.Lstat(p)
	if err != nil || !fi.Mode().IsRegular() {
		return "", apierr.PathOutsidePublishDir()
	}
	return p, nil
}

// copyFile copies src to a new file dst (fallback when cloning fails).
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	os.Remove(dst)
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.CopyBuffer(out, in, make([]byte, 256<<10)); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// snapshot clones src into a new read-only file in the snapshot folder.
func (h *Host) snapshot(src string) (string, error) {
	dst := filepath.Join(h.snapDir, ids.NewID("tmp-")+".ipa")
	if err := cloneFile(src, dst); err != nil {
		os.Remove(dst)
		return "", err
	}
	if err := os.Chmod(dst, 0o400); err != nil {
		os.Remove(dst)
		return "", err
	}
	return dst, nil
}

// hashFile opens path and returns its FileInfo (from the open descriptor),
// size-checked SHA-256 hex digest.
func hashFile(path string) (os.FileInfo, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, "", err
	}
	hash := sha256.New()
	buf := make([]byte, 32<<10)
	n, err := io.CopyBuffer(hash, f, buf)
	if err != nil {
		return nil, "", err
	}
	if n != fi.Size() {
		return nil, "", fmt.Errorf("file size changed while hashing")
	}
	return fi, hex.EncodeToString(hash.Sum(nil)), nil
}

// Publish re-verifies a build (debug flags, location, size and SHA-256) and
// makes it available to paired devices. The IPA is snapshotted first and the
// checks run on the snapshot, which is the only file ever served. It returns
// the build id.
func (h *Host) Publish(req PublishRequest) (string, error) {
	d := req.BuildDescriptor
	if !d.Debug {
		return "", apierr.NotDebugBuild("debug가 true가 아닙니다.")
	}
	if !d.Signing.GetTaskAllow {
		return "", apierr.NotDebugBuild("signing.getTaskAllow가 true가 아닙니다.")
	}
	if d.BundleID == "" {
		return "", apierr.BadRequest("bundleId가 필요합니다.")
	}
	src, err := h.resolveIPA(req.IPAPath)
	if err != nil {
		return "", err
	}
	snap, err := h.snapshot(src)
	if err != nil {
		return "", apierr.Internal("IPA 사본을 만들지 못했습니다.")
	}
	keep := false
	defer func() {
		if !keep {
			os.Remove(snap)
		}
	}()
	fi, sum, err := hashFile(snap)
	if err != nil {
		return "", apierr.Internal("IPA를 읽지 못했습니다.")
	}
	if fi.Size() != d.IPA.Size || !strings.EqualFold(sum, d.IPA.SHA256) {
		return "", apierr.HashMismatch("IPA 크기 또는 SHA-256이 설명과 다릅니다.")
	}
	d.IPA.SHA256 = sum
	id := ids.BuildID(d.BundleID, sum)
	if d.ID != "" && d.ID != id {
		return "", apierr.BadRequest("id가 bundleId와 IPA 해시에서 계산한 값과 다릅니다: " + id)
	}
	d.ID = id
	if d.PublishedAt == "" {
		d.PublishedAt = Timestamp(h.now())
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return "", apierr.NotRunning("노드가 종료되었습니다.")
	}
	if old := h.builds[id]; old != nil {
		old.desc = d // same bytes: keep serving the existing snapshot
		return id, nil
	}
	final := filepath.Join(h.snapDir, id+".ipa")
	if err := os.Rename(snap, final); err != nil {
		return "", apierr.Internal("IPA 사본을 저장하지 못했습니다.")
	}
	keep = true
	h.builds[id] = &build{desc: d, path: final, fi: fi, sum: sum}
	return id, nil
}

// Unpublish removes a build and its snapshot. Its open sessions become
// "failed" and transfers in flight are aborted.
func (h *Host) Unpublish(id string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	b, ok := h.builds[id]
	if !ok {
		return apierr.BuildNotFound()
	}
	delete(h.builds, id)
	for _, s := range h.sessions {
		if s.buildID == id {
			h.failSessionLocked(s)
		}
	}
	os.Remove(b.path)
	return nil
}

// sameFile reports whether fi still describes the snapshot.
func (b *build) sameFile(fi os.FileInfo) bool {
	return os.SameFile(b.fi, fi) && fi.Size() == b.fi.Size() && fi.ModTime().Equal(b.fi.ModTime())
}

// verifyHash re-hashes the snapshot (used at session creation).
func (b *build) verifyHash() bool {
	fi, sum, err := hashFile(b.path)
	return err == nil && b.sameFile(fi) && sum == b.sum
}

// check reports build_changed if the snapshot's identity changed.
func (b *build) check() error {
	fi, err := os.Stat(b.path)
	if err != nil || !b.sameFile(fi) {
		return apierr.BuildChanged()
	}
	return nil
}

// open opens the snapshot and checks it has not changed since publish
// (size, mtime, inode). The caller serves from the returned descriptor.
func (b *build) open() (*os.File, error) {
	f, err := os.Open(b.path)
	if err != nil {
		return nil, apierr.BuildChanged()
	}
	fi, err := f.Stat()
	if err != nil || !b.sameFile(fi) {
		f.Close()
		return nil, apierr.BuildChanged()
	}
	return f, nil
}

func (h *Host) handleBuilds(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.requirePaired(w, r); !ok {
		return
	}
	h.mu.Lock()
	list := make([]BuildDescriptor, 0, len(h.builds))
	for _, b := range h.builds {
		list = append(list, b.desc)
	}
	h.mu.Unlock()
	slices.SortFunc(list, func(a, b BuildDescriptor) int {
		if c := strings.Compare(b.PublishedAt, a.PublishedAt); c != 0 {
			return c // newest first
		}
		return strings.Compare(a.ID, b.ID)
	})
	writeJSON(w, http.StatusOK, map[string]any{"builds": list})
}
