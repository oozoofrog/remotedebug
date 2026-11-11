package e2e

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"remotedebug/core/internal/api"
	"remotedebug/core/internal/host"
	"remotedebug/core/internal/node"
)

func TestE2EUnpairedNodeForbidden(t *testing.T) {
	h := startHost(t)
	// peerB is paired and owns a session; peerA never paired.
	h.setDevices(peerB)
	buildID, _ := h.publish(1000)
	sessionID, base := h.newSession(peerB, buildID)

	expectStatus(t, h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil), http.StatusForbidden, "not_paired")
	for _, path := range []string{"/v1/info", "/v1/builds", "/v1/sessions/" + sessionID, base + "/manifest.plist", base + "/app.ipa"} {
		expectStatus(t, h.get(peerA, path), http.StatusForbidden, "not_paired")
	}
	for _, path := range []string{"/v1/builds/" + buildID + "/sessions", "/v1/info", "/v1/builds", "/v1/sessions/" + sessionID, "/i/…/manifest.plist", "/i/…/app.ipa"} {
		h.waitEvent("denied", func(e map[string]any) bool {
			return e["path"] == path && e["reason"] == "not_paired" && e["nodeName"] == peerA.name
		})
	}
	// The session is untouched by the denied attempts.
	if state, _ := h.sessionState(peerB, sessionID); state != "created" {
		t.Fatalf("session state %q", state)
	}
	// Unknown routes and wrong methods still carry the protocol header and JSON errors.
	expectStatus(t, h.get(peerA, "/nope"), http.StatusNotFound, "not_found")
	expectStatus(t, h.post(peerA, "/v1/info", nil), http.StatusMethodNotAllowed, "method_not_allowed")
}

func TestE2EDeniedRateLimit(t *testing.T) {
	h := startHost(t)
	for i := 0; i < 3; i++ {
		expectStatus(t, h.get(peerA, "/v1/info"), http.StatusForbidden, "not_paired")
	}
	isInfo := func(e map[string]any) bool { return e["path"] == "/v1/info" }
	if ev := h.waitEvent("denied", isInfo); ev["suppressed"] != nil {
		t.Fatalf("first denied event: %v", ev)
	}
	// Another path is limited separately.
	expectStatus(t, h.get(peerA, "/v1/builds"), http.StatusForbidden, "not_paired")
	h.waitEvent("denied", func(e map[string]any) bool { return e["path"] == "/v1/builds" })
	// After the 5 s window the next event reports what was suppressed.
	h.clock.Advance(5 * time.Second)
	expectStatus(t, h.get(peerA, "/v1/info"), http.StatusForbidden, "not_paired")
	if ev := h.waitEvent("denied", isInfo); ev["suppressed"] != float64(2) {
		t.Fatalf("second denied event: %v", ev)
	}
}

func TestE2EPairingApproved(t *testing.T) {
	h := startHost(t)
	var opened struct{ Code, ExpiresAt string }
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	if len(opened.Code) != 8 {
		t.Fatalf("pairing_open: %+v", opened)
	}
	display := strings.ToLower(opened.Code[:4] + "-" + opened.Code[4:])

	r := h.post(peerA, "/v1/pair/request", map[string]string{"code": display, "deviceName": "내 iPhone", "platform": "iOS 26.1", "clientVersion": "0.1.0"})
	expectStatus(t, r, http.StatusAccepted, "")
	req := r.json(t)
	reqID, _ := req["requestId"].(string)
	if !strings.HasPrefix(reqID, "pr_") || req["state"] != "pending" {
		t.Fatalf("pair request: %s", r.body)
	}
	ev := h.waitEvent("pair-request", nil)
	if ev["requestId"] != reqID || ev["deviceName"] != "내 iPhone" || ev["nodeName"] != peerA.name {
		t.Fatalf("pair-request event: %v", ev)
	}

	// The code is one-time: a second use fails.
	expectStatus(t, h.post(peerB, "/v1/pair/request", map[string]string{"code": opened.Code}), http.StatusForbidden, "pair_code_invalid")

	r = h.get(peerA, "/v1/pair/request/"+reqID)
	expectStatus(t, r, http.StatusOK, "")
	if r.json(t)["state"] != "pending" {
		t.Fatalf("state: %s", r.body)
	}
	// Another node cannot read this request.
	expectStatus(t, h.get(peerB, "/v1/pair/request/"+reqID), http.StatusForbidden, "not_paired")

	out := api.HostPairingDecide(h.handle, reqID, true)
	var decided struct {
		OK     bool
		Device struct {
			ID, Name, NodeStableID, NodeName, PairedAt string
		}
	}
	mustDecode(t, out, &decided)
	if !decided.OK || decided.Device.NodeStableID != peerA.stableID || decided.Device.Name != "내 iPhone" || !strings.HasPrefix(decided.Device.ID, "d_") {
		t.Fatalf("decide: %s", out)
	}
	ev = h.waitEvent("device-added", nil)
	if dev, _ := ev["device"].(map[string]any); dev["nodeStableId"] != peerA.stableID {
		t.Fatalf("device-added: %v", ev)
	}
	h.waitEvent("pair-decided", func(e map[string]any) bool { return e["state"] == "approved" })

	r = h.get(peerA, "/v1/pair/request/"+reqID)
	expectStatus(t, r, http.StatusOK, "")
	st := r.json(t)
	if hostInfo, _ := st["host"].(map[string]any); st["state"] != "approved" || hostInfo["fqdn"] != h.fqdn {
		t.Fatalf("approved state: %s", r.body)
	}

	r = h.get(peerA, "/v1/info")
	expectStatus(t, r, http.StatusOK, "")
	info := r.json(t)
	if info["fqdn"] != h.fqdn || info["protocol"] != float64(1) || !strings.HasPrefix(info["hostId"].(string), "h_") {
		t.Fatalf("info: %s", r.body)
	}
	expectStatus(t, h.get(peerA, "/v1/builds"), http.StatusOK, "")
	expectStatus(t, h.get(peerB, "/v1/info"), http.StatusForbidden, "not_paired")

	var status node.Status
	mustDecode(t, api.Status(h.handle), &status)
	if status.PairedDevices != 1 || status.BackendState != "Running" || len(status.TailscaleIPs) == 0 {
		t.Fatalf("status: %+v", status)
	}
}

func TestE2EPairingDenied(t *testing.T) {
	h := startHost(t)
	var opened struct{ Code string }
	mustDecode(t, api.HostPairingOpen(h.handle, 60), &opened)
	r := h.post(peerA, "/v1/pair/request", map[string]string{"code": opened.Code, "deviceName": "x"})
	expectStatus(t, r, http.StatusAccepted, "")
	reqID := r.json(t)["requestId"].(string)

	if out := api.HostPairingDecide(h.handle, reqID, false); out != `{"ok":true}` {
		t.Fatalf("deny: %s", out)
	}
	h.waitEvent("pair-decided", func(e map[string]any) bool { return e["state"] == "denied" && e["requestId"] == reqID })
	r = h.get(peerA, "/v1/pair/request/"+reqID)
	if r.json(t)["state"] != "denied" {
		t.Fatalf("state: %s", r.body)
	}
	expectStatus(t, h.get(peerA, "/v1/info"), http.StatusForbidden, "not_paired")
	if code := apiError(api.HostPairingDecide(h.handle, reqID, true)); code != "bad_request" {
		t.Fatalf("second decide: %s", code)
	}
}

func TestE2EPairCodeAttempts(t *testing.T) {
	// The 5th wrong attempt answers 403 and burns the code; later attempts
	// answer 429 until a new code opens or the code's TTL passes.
	h := startHost(t)
	var opened struct{ Code string }
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	wrong := "00000000"
	if opened.Code == wrong {
		wrong = "11111111"
	}
	for i := 1; i <= 5; i++ {
		expectStatus(t, h.post(peerA, "/v1/pair/request", map[string]string{"code": wrong}), http.StatusForbidden, "pair_code_invalid")
	}
	h.waitEvent("denied", func(e map[string]any) bool { return e["reason"] == "pair_code_invalid" })
	// The code is now burned, even the correct value is refused.
	expectStatus(t, h.post(peerA, "/v1/pair/request", map[string]string{"code": opened.Code}), http.StatusTooManyRequests, "too_many_attempts")
	expectStatus(t, h.post(peerA, "/v1/pair/request", map[string]string{"code": wrong}), http.StatusTooManyRequests, "too_many_attempts")
	// Once the burned code's TTL has passed it is simply invalid.
	h.clock.Advance(300 * time.Second)
	expectStatus(t, h.post(peerA, "/v1/pair/request", map[string]string{"code": opened.Code}), http.StatusForbidden, "pair_code_invalid")
	// A new code resets the counter.
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	expectStatus(t, h.post(peerA, "/v1/pair/request", map[string]string{"code": opened.Code}), http.StatusAccepted, "")
}

func TestE2EPairingExpiry(t *testing.T) {
	h := startHost(t)
	// Default code TTL (ttl 0 = 300 s): expired exactly at the TTL.
	var opened struct{ Code, ExpiresAt string }
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	if opened.ExpiresAt != "2026-11-11T09:05:00Z" {
		t.Fatalf("expiresAt %q", opened.ExpiresAt)
	}
	h.clock.Advance(300 * time.Second)
	expectStatus(t, h.post(peerA, "/v1/pair/request", map[string]string{"code": opened.Code}), http.StatusForbidden, "pair_code_invalid")

	// Still valid one second before the TTL.
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	h.clock.Advance(299 * time.Second)
	r := h.post(peerA, "/v1/pair/request", map[string]string{"code": opened.Code})
	expectStatus(t, r, http.StatusAccepted, "")
	reqID := r.json(t)["requestId"].(string)
	if exp := r.json(t)["expiresAt"]; exp != "2026-11-11T09:11:59Z" { // 09:09:59 + 120 s
		t.Fatalf("pair request expiresAt %v", exp)
	}
	h.clock.Advance(119 * time.Second)
	if st := h.get(peerA, "/v1/pair/request/"+reqID).json(t)["state"]; st != "pending" {
		t.Fatalf("state just before TTL: %v", st)
	}
	h.clock.Advance(1 * time.Second)
	r = h.get(peerA, "/v1/pair/request/"+reqID)
	if r.json(t)["state"] != "expired" {
		t.Fatalf("state: %s", r.body)
	}
	h.waitEvent("pair-decided", func(e map[string]any) bool { return e["state"] == "expired" })
	if code := apiError(api.HostPairingDecide(h.handle, reqID, true)); code != "bad_request" {
		t.Fatalf("decide after expiry: %q", code)
	}
}

func TestE2EPublishValidation(t *testing.T) {
	h := startHost(t)
	path, sum := writeIPA(t, h.publishDir, "A.ipa", 4096)
	_, escapedSum := writeIPA(t, filepath.Dir(h.publishDir), "x.ipa", 4096)
	writeIPA(t, filepath.Join(h.publishDir, host.SnapshotDirName), "x.ipa", 4096) // same bytes as A.ipa

	cases := []struct {
		name   string
		mutate func(d map[string]any)
		code   string
	}{
		{"debug=false", func(d map[string]any) { d["debug"] = false }, "not_debug_build"},
		{"getTaskAllow=false", func(d map[string]any) { d["signing"].(map[string]any)["getTaskAllow"] = false }, "not_debug_build"},
		{"sha mismatch", func(d map[string]any) { d["ipa"] = map[string]any{"size": 4096, "sha256": strings.Repeat("0", 64)} }, "hash_mismatch"},
		{"size mismatch", func(d map[string]any) { d["ipa"] = map[string]any{"size": 4095, "sha256": sum} }, "hash_mismatch"},
		{"relative path", func(d map[string]any) { d["ipaPath"] = "A.ipa" }, "path_outside_publish_dir"},
		// The escaped target exists with matching size and hash, so only the
		// containment check can refuse it.
		{"dotdot escape", func(d map[string]any) {
			d["ipaPath"] = h.publishDir + "/../x.ipa"
			d["ipa"] = map[string]any{"size": 4096, "sha256": escapedSum}
		}, "path_outside_publish_dir"},
		{"snapshot dir", func(d map[string]any) {
			d["ipaPath"] = filepath.Join(h.publishDir, host.SnapshotDirName, "x.ipa")
		}, "path_outside_publish_dir"},
		{"directory", func(d map[string]any) { d["ipaPath"] = h.publishDir }, "path_outside_publish_dir"},
		{"wrong id", func(d map[string]any) { d["id"] = "b_00000000" }, "bad_request"},
	}
	outsideDir := t.TempDir()
	outside, outsideSum := writeIPA(t, outsideDir, "Out.ipa", 4096)
	link := filepath.Join(h.publishDir, "link.ipa")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	cases = append(cases,
		struct {
			name   string
			mutate func(d map[string]any)
			code   string
		}{"outside file", func(d map[string]any) {
			d["ipaPath"] = outside
			d["ipa"] = map[string]any{"size": 4096, "sha256": outsideSum}
		}, "path_outside_publish_dir"},
		struct {
			name   string
			mutate func(d map[string]any)
			code   string
		}{"symlink escape", func(d map[string]any) {
			d["ipaPath"] = link
			d["ipa"] = map[string]any{"size": 4096, "sha256": outsideSum}
		}, "path_outside_publish_dir"},
	)
	for _, c := range cases {
		d := descriptor(path, sum, 4096)
		c.mutate(d)
		if code := apiError(api.HostPublish(h.handle, mustJSON(d))); code != c.code {
			t.Errorf("%s: got %q, want %q", c.name, code, c.code)
		}
	}
	out := api.HostPublish(h.handle, mustJSON(descriptor(path, sum, 4096)))
	if apiError(out) != "" || !strings.Contains(out, `"id":"b_`) {
		t.Fatalf("valid publish: %s", out)
	}
	var st node.Status
	mustDecode(t, api.Status(h.handle), &st)
	if st.PublishedBuilds != 1 {
		t.Fatalf("publishedBuilds = %d", st.PublishedBuilds)
	}
}

func TestE2EInstallSessionFlow(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	const size = 300_000
	buildID, path := h.publish(size)
	want, _ := os.ReadFile(path)

	r := h.get(peerA, "/v1/builds")
	expectStatus(t, r, http.StatusOK, "")
	if !strings.Contains(string(r.body), buildID) || strings.Contains(string(r.body), "ipaPath") || strings.Contains(string(r.body), h.publishDir) {
		t.Fatalf("builds: %s", r.body)
	}

	expectStatus(t, h.post(peerA, "/v1/builds/b_nope0000/sessions", nil), http.StatusNotFound, "build_not_found")
	r = h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil)
	expectStatus(t, r, http.StatusCreated, "")
	sess := r.json(t)
	sessionID := sess["sessionId"].(string)
	manifestURL := sess["manifestUrl"].(string)
	prefix := h.base + "/i/"
	token := strings.TrimSuffix(strings.TrimPrefix(manifestURL, prefix), "/manifest.plist")
	if !strings.HasPrefix(manifestURL, prefix) || len(token) != 43 {
		t.Fatalf("manifestUrl %q (token %q)", manifestURL, token)
	}
	if sess["installUrl"] != "itms-services://?action=download-manifest&url="+url.QueryEscape(manifestURL) {
		t.Fatalf("installUrl %q", sess["installUrl"])
	}
	h.waitEvent("session", func(e map[string]any) bool { return e["sessionId"] == sessionID && e["state"] == "created" })

	r = do(t, peerA.http, "GET", manifestURL, nil, map[string]string{"User-Agent": "com.apple.appstored/1.0"})
	expectStatus(t, r, http.StatusOK, "")
	if ct := r.header.Get("Content-Type"); ct != "text/xml" {
		t.Fatalf("manifest content type %q", ct)
	}
	ipaURL := h.base + "/i/" + token + "/app.ipa"
	for _, s := range []string{"<string>" + ipaURL + "</string>", "<string>com.example.app.Sample</string>", "<string>1.4.0</string>", "<string>Sample</string>"} {
		if !strings.Contains(string(r.body), s) {
			t.Fatalf("manifest missing %q:\n%s", s, r.body)
		}
	}
	h.waitEvent("session", func(e map[string]any) bool {
		return e["state"] == "manifest_served" && e["userAgent"] == "com.apple.appstored/1.0" && e["nodeName"] == peerA.name
	})

	// Range request (partial download), then resume to the end.
	r = do(t, peerA.http, "GET", ipaURL, nil, map[string]string{"Range": "bytes=0-99"})
	if r.status != http.StatusPartialContent || string(r.body) != string(want[:100]) {
		t.Fatalf("range: %d len %d", r.status, len(r.body))
	}
	if r.header.Get("Content-Range") != fmt.Sprintf("bytes 0-99/%d", size) {
		t.Fatalf("Content-Range %q", r.header.Get("Content-Range"))
	}
	r = h.get(peerA, "/v1/sessions/"+sessionID)
	st := r.json(t)
	if st["state"] != "downloading" || st["bytesServed"] != float64(100) || st["expiresAt"] != "2026-11-11T09:10:00Z" {
		t.Fatalf("session status: %s", r.body)
	}

	r = do(t, peerA.http, "GET", ipaURL, nil, map[string]string{"Range": "bytes=100-"})
	if r.status != http.StatusPartialContent || string(r.body) != string(want[100:]) {
		t.Fatalf("resume: %d len %d", r.status, len(r.body))
	}
	h.waitEvent("session", func(e map[string]any) bool { return e["state"] == "completed" && e["bytesServed"] == float64(size) })
	r = h.get(peerA, "/v1/sessions/"+sessionID)
	if r.json(t)["state"] != "completed" {
		t.Fatalf("after completion: %s", r.body)
	}
	expectStatus(t, h.get(peerA, "/i/"+token+"/app.ipa"), http.StatusGone, "session_expired")
	expectStatus(t, h.get(peerA, "/i/"+token+"/manifest.plist"), http.StatusGone, "session_expired")

	// A full single download also completes a fresh session.
	r = h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil)
	token2 := strings.TrimSuffix(strings.TrimPrefix(r.json(t)["manifestUrl"].(string), prefix), "/manifest.plist")
	r = h.get(peerA, "/i/"+token2+"/app.ipa")
	if r.status != http.StatusOK || len(r.body) != size || r.header.Get("Content-Type") != "application/octet-stream" {
		t.Fatalf("full download: %d len %d", r.status, len(r.body))
	}
	expectStatus(t, h.get(peerA, "/i/"+token2+"/app.ipa"), http.StatusGone, "session_expired")
}

func TestE2ETokenBoundToNode(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA, peerB)
	buildID, _ := h.publish(1000)
	r := h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil)
	expectStatus(t, r, http.StatusCreated, "")
	sess := r.json(t)
	path := strings.TrimPrefix(sess["manifestUrl"].(string), h.base)

	expectStatus(t, h.get(peerB, path), http.StatusForbidden, "token_invalid")
	expectStatus(t, h.get(peerB, strings.Replace(path, "manifest.plist", "app.ipa", 1)), http.StatusForbidden, "token_invalid")
	expectStatus(t, h.get(peerB, "/v1/sessions/"+sess["sessionId"].(string)), http.StatusForbidden, "token_invalid")
	expectStatus(t, h.get(peerA, "/i/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/app.ipa"), http.StatusForbidden, "token_invalid")
	ev := h.waitEvent("denied", func(e map[string]any) bool { return e["reason"] == "token_invalid" })
	if strings.Contains(fmt.Sprint(ev), strings.Split(path, "/")[2]) {
		t.Fatalf("token leaked into event: %v", ev)
	}

	// Removing a device from the allow-list fails its session for good.
	h.setDevices(peerB)
	expectStatus(t, h.get(peerA, path), http.StatusForbidden, "not_paired")
	h.waitEvent("session", func(e map[string]any) bool { return e["sessionId"] == sess["sessionId"] && e["state"] == "failed" })
	// Re-adding the node does not bring the session back.
	h.setDevices(peerA)
	expectStatus(t, h.get(peerA, path), http.StatusGone, "session_expired")
	if state, _ := h.sessionState(peerA, sess["sessionId"].(string)); state != "failed" {
		t.Fatalf("state %q", state)
	}
}

func TestE2ESessionExpiry(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	buildID, _ := h.publish(2000)

	newSession := func() (string, string) {
		r := h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil)
		expectStatus(t, r, http.StatusCreated, "")
		m := r.json(t)
		return m["sessionId"].(string), strings.TrimSuffix(strings.TrimPrefix(m["manifestUrl"].(string), h.base), "/manifest.plist")
	}

	// Unused session: valid until 180 s, expired at 180 s.
	r := h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil)
	expectStatus(t, r, http.StatusCreated, "")
	if exp := r.json(t)["expiresAt"]; exp != "2026-11-11T09:03:00Z" {
		t.Fatalf("expiresAt %v", exp)
	}
	id, base := newSession()
	h.clock.Advance(179 * time.Second)
	if state, _ := h.sessionState(peerA, id); state != "created" {
		t.Fatalf("state before TTL: %q", state)
	}
	h.clock.Advance(1 * time.Second)
	expectStatus(t, h.get(peerA, base+"/manifest.plist"), http.StatusGone, "session_expired")
	if st := h.get(peerA, "/v1/sessions/"+id).json(t); st["state"] != "expired" {
		t.Fatalf("state %v", st)
	}
	h.waitEvent("session", func(e map[string]any) bool { return e["sessionId"] == id && e["state"] == "expired" })

	// Starting the IPA download extends the session to 600 s from creation.
	id, base = newSession()
	r = do(t, peerA.http, "GET", h.base+base+"/app.ipa", nil, map[string]string{"Range": "bytes=0-9"})
	if r.status != http.StatusPartialContent {
		t.Fatalf("range: %d", r.status)
	}
	h.clock.Advance(300 * time.Second)
	if r := do(t, peerA.http, "GET", h.base+base+"/app.ipa", nil, map[string]string{"Range": "bytes=10-19"}); r.status != http.StatusPartialContent {
		t.Fatalf("after 300 s: %d %s", r.status, r.body)
	}
	h.clock.Advance(301 * time.Second)
	expectStatus(t, h.get(peerA, base+"/app.ipa"), http.StatusGone, "session_expired")

	// The manifest can be fetched at most 5 times.
	_, base = newSession()
	for i := 0; i < 5; i++ {
		expectStatus(t, h.get(peerA, base+"/manifest.plist"), http.StatusOK, "")
	}
	expectStatus(t, h.get(peerA, base+"/manifest.plist"), http.StatusGone, "session_expired")
}

func TestE2EBuildChanged(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	buildID, _ := h.publish(5000)
	snap := h.snapshotPath(buildID)
	if fi, err := os.Stat(snap); err != nil || fi.Mode().Perm() != 0o400 {
		t.Fatalf("snapshot %v %v", fi, err)
	}

	// Replacing the snapshot (new inode) is caught at serve time and fails the session.
	id, base := h.newSession(peerA, buildID)
	tmp, _ := writeIPA(t, h.publishDir, "tmp.ipa", 5001)
	if err := os.Rename(tmp, snap); err != nil {
		t.Fatal(err)
	}
	expectStatus(t, h.get(peerA, base+"/app.ipa"), http.StatusConflict, "build_changed")
	h.waitEvent("session", func(e map[string]any) bool { return e["sessionId"] == id && e["state"] == "failed" })
	expectStatus(t, h.get(peerA, base+"/manifest.plist"), http.StatusGone, "session_expired")
	expectStatus(t, h.post(peerA, "/v1/builds/"+buildID+"/sessions", nil), http.StatusConflict, "build_changed")

	// Same size, same inode, modified bytes and restored mtime: caught by the re-hash.
	h2 := startHost(t)
	h2.setDevices(peerA)
	buildID, _ = h2.publish(5000)
	snap = h2.snapshotPath(buildID)
	fi, _ := os.Stat(snap)
	os.Chmod(snap, 0o600)
	f, _ := os.OpenFile(snap, os.O_WRONLY, 0)
	f.WriteAt([]byte{0xFF, 0xFE}, 10)
	f.Close()
	os.Chtimes(snap, fi.ModTime(), fi.ModTime())
	expectStatus(t, h2.post(peerA, "/v1/builds/"+buildID+"/sessions", nil), http.StatusConflict, "build_changed")

	// Unpublish: unknown build afterwards, snapshot removed.
	if out := api.HostUnpublish(h2.handle, buildID); out != `{"ok":true}` {
		t.Fatalf("unpublish: %s", out)
	}
	if _, err := os.Stat(snap); !os.IsNotExist(err) {
		t.Fatalf("snapshot still present: %v", err)
	}
	expectStatus(t, h2.post(peerA, "/v1/builds/"+buildID+"/sessions", nil), http.StatusNotFound, "build_not_found")
	if code := apiError(api.HostUnpublish(h2.handle, buildID)); code != "build_not_found" {
		t.Fatalf("second unpublish: %q", code)
	}
}

func TestE2ESnapshotImmutable(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	buildID, path := h.publish(5000)
	want, _ := os.ReadFile(path)
	_, base := h.newSession(peerA, buildID)

	// The app overwrites its file in place and then replaces it by rename:
	// neither changes what is served under the published build.
	os.WriteFile(path, bytes.Repeat([]byte{'Z'}, 5000), 0o644)
	tmp, _ := writeIPA(t, h.publishDir, "next.ipa", 7000)
	os.Rename(tmp, path)
	r := h.get(peerA, base+"/app.ipa")
	if r.status != http.StatusOK || !bytes.Equal(r.body, want) {
		t.Fatalf("served %d, %d bytes, equal=%v", r.status, len(r.body), bytes.Equal(r.body, want))
	}
	// New sessions still verify against the snapshot.
	h.newSession(peerA, buildID)

	// rd_stop removes the snapshots.
	snap := h.snapshotPath(buildID)
	api.Stop(h.handle)
	if _, err := os.Stat(snap); !os.IsNotExist(err) {
		t.Fatalf("snapshot after stop: %v", err)
	}
}

func TestE2ECoverageCompletion(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	buildID, path := h.publish(4096)
	want, _ := os.ReadFile(path)
	id, base := h.newSession(peerA, buildID)
	get := func(rng string) response {
		return do(t, peerA.http, "GET", h.base+base+"/app.ipa", nil, map[string]string{"Range": rng})
	}

	// Repeating the same tail range never completes the session.
	for i := 0; i < 4; i++ {
		if r := get("bytes=3000-"); r.status != http.StatusPartialContent || !bytes.Equal(r.body, want[3000:]) {
			t.Fatalf("tail %d: %d", i, r.status)
		}
	}
	if state, n := h.sessionState(peerA, id); state != "downloading" || n != 1096 {
		t.Fatalf("after tails: %s %v", state, n)
	}
	get("bytes=0-1999")
	if state, n := h.sessionState(peerA, id); state != "downloading" || n != 3096 {
		t.Fatalf("after head: %s %v", state, n)
	}
	// An overlapping range closes the gap [2000, 3000).
	get("bytes=1500-3100")
	h.waitEvent("session", func(e map[string]any) bool {
		return e["sessionId"] == id && e["state"] == "completed" && e["bytesServed"] == float64(4096)
	})

	// Multi-range requests get the whole file (no multipart).
	id, base = h.newSession(peerA, buildID)
	r := get("bytes=-1,-1,-1")
	if r.status != http.StatusOK || !bytes.Equal(r.body, want) {
		t.Fatalf("multi-range: %d len %d", r.status, len(r.body))
	}
	if state, _ := h.sessionState(peerA, id); state != "completed" {
		t.Fatalf("after multi-range: %s", state)
	}
}

func TestE2EHeadHasNoSideEffects(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	buildID, _ := h.publish(3000)
	id, base := h.newSession(peerA, buildID)

	for i := 0; i < 6; i++ {
		r := do(t, peerA.http, "HEAD", h.base+base+"/manifest.plist", nil, nil)
		expectStatus(t, r, http.StatusOK, "")
		if len(r.body) != 0 || r.header.Get("Content-Type") != "text/xml" {
			t.Fatalf("HEAD manifest: %q %v", r.body, r.header)
		}
	}
	r := do(t, peerA.http, "HEAD", h.base+base+"/app.ipa", nil, nil)
	expectStatus(t, r, http.StatusOK, "")
	if r.header.Get("Content-Length") != "3000" || len(r.body) != 0 {
		t.Fatalf("HEAD ipa: %v", r.header)
	}
	sess := h.get(peerA, "/v1/sessions/"+id).json(t)
	if sess["state"] != "created" || sess["expiresAt"] != "2026-11-11T09:03:00Z" || sess["bytesServed"] != float64(0) {
		t.Fatalf("after HEAD: %v", sess)
	}
	// All five manifest fetches are still available.
	for i := 0; i < 5; i++ {
		expectStatus(t, h.get(peerA, base+"/manifest.plist"), http.StatusOK, "")
	}
	expectStatus(t, h.get(peerA, base+"/manifest.plist"), http.StatusGone, "session_expired")
}

// bigIPA is large enough that a paused client keeps the transfer in flight.
const bigIPA = 32 << 20

// expectAborted reads the rest of a revoked transfer: it must end early with an error.
func expectAborted(t *testing.T, resp *http.Response) {
	t.Helper()
	start := time.Now()
	n, err := io.Copy(io.Discard, resp.Body)
	if err == nil || n >= bigIPA-64<<10 {
		t.Fatalf("transfer not aborted: read %d more bytes, err %v", n, err)
	}
	if time.Since(start) > 15*time.Second {
		t.Fatalf("abort took %v", time.Since(start))
	}
}

func TestE2ERevokeInFlight(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	path, sum := writeIPA(t, h.publishDir, "Big.ipa", bigIPA)
	buildID := h.publishFile(path, sum, bigIPA)

	// Unpublish aborts the download and fails the session.
	id, base := h.newSession(peerA, buildID)
	resp, _ := openStream(t, peerA.http, h.base+base+"/app.ipa", 64<<10)
	if out := api.HostUnpublish(h.handle, buildID); out != `{"ok":true}` {
		t.Fatalf("unpublish: %s", out)
	}
	expectAborted(t, resp)
	if state, _ := h.sessionState(peerA, id); state != "failed" {
		t.Fatalf("after unpublish: %s", state)
	}
	// Publishing the same build again does not revive the old token.
	if again := h.publishFile(path, sum, bigIPA); again != buildID {
		t.Fatalf("republished id %s", again)
	}
	expectStatus(t, h.get(peerA, base+"/app.ipa"), http.StatusGone, "session_expired")

	// Removing the device aborts its download and fails the session.
	id, base = h.newSession(peerA, buildID)
	resp, _ = openStream(t, peerA.http, h.base+base+"/app.ipa", 64<<10)
	h.setDevices(peerB)
	expectAborted(t, resp)
	h.waitEvent("session", func(e map[string]any) bool { return e["sessionId"] == id && e["state"] == "failed" })
}

func TestE2EInFlightPastTTL(t *testing.T) {
	h := startHost(t)
	h.setDevices(peerA)
	path, sum := writeIPA(t, h.publishDir, "Big.ipa", bigIPA)
	want, _ := os.ReadFile(path)
	buildID := h.publishFile(path, sum, bigIPA)
	id, base := h.newSession(peerA, buildID)

	resp, head := openStream(t, peerA.http, h.base+base+"/app.ipa", 64<<10)
	// Past the 600 s session lifetime (by the session clock) while streaming:
	// neither the status poll nor the periodic sweep expires it.
	h.clock.Advance(700 * time.Second)
	time.Sleep(2500 * time.Millisecond) // let the monitor's sweep run
	if state, _ := h.sessionState(peerA, id); state != "downloading" {
		t.Fatalf("in flight past TTL: %s", state)
	}
	rest, err := io.ReadAll(resp.Body)
	if err != nil || !bytes.Equal(append(head, rest...), want) {
		t.Fatalf("body: %d bytes, err %v", len(head)+len(rest), err)
	}
	h.waitEvent("session", func(e map[string]any) bool { return e["sessionId"] == id && e["state"] == "completed" })
	if state, n := h.sessionState(peerA, id); state != "completed" || n != bigIPA {
		t.Fatalf("after transfer: %s %v", state, n)
	}
}

func TestE2ETransferHardCap(t *testing.T) {
	// SessionMaxTTL bounds a transfer in real time through the write deadline.
	h := startHostWith(t, host.Limits{SessionMaxTTL: 2 * time.Second})
	h.setDevices(peerA)
	path, sum := writeIPA(t, h.publishDir, "Big.ipa", bigIPA)
	buildID := h.publishFile(path, sum, bigIPA)
	id, base := h.newSession(peerA, buildID)

	resp, _ := openStream(t, peerA.http, h.base+base+"/app.ipa", 64<<10)
	time.Sleep(3 * time.Second)
	expectAborted(t, resp)
	h.clock.Advance(3 * time.Second)
	if state, _ := h.sessionState(peerA, id); state != "expired" {
		t.Fatalf("after hard cap: %s", state)
	}
}

func TestE2EProxyConnect(t *testing.T) {
	h := startHost(t)
	target := fmt.Sprintf("%s:%d", strings.ToUpper(h.fqdn), h.port) // host match is case-insensitive

	cfg := map[string]any{
		"mode":           "proxy",
		"stateDir":       filepath.Join(t.TempDir(), "state"),
		"hostname":       fmt.Sprintf("rd-phone-px%06d", hostSeq.Add(1)),
		"controlURL":     env.ControlURL,
		"ephemeral":      true,
		"listenTLS":      false,
		"allowedTargets": []string{target},
		"goMemLimitMiB":  0,
	}
	out := api.Start(mustJSON(cfg))
	var started struct{ Handle int64 }
	mustDecode(t, out, &started)
	if started.Handle == 0 {
		t.Fatalf("rd_start proxy: %s", out)
	}
	defer api.Stop(started.Handle)

	if code := apiError(api.ProxyStart(started.Handle, "0.0.0.0:0")); code != "invalid_config" {
		t.Fatalf("non-loopback listen: %q", code)
	}
	if code := apiError(api.ProxyStart(h.handle, "127.0.0.1:0")); code != "invalid_config" {
		t.Fatalf("proxy on host-mode node: %q", code)
	}
	var px struct{ Addr string }
	mustDecode(t, api.ProxyStart(started.Handle, "127.0.0.1:0"), &px)
	if !strings.HasPrefix(px.Addr, "127.0.0.1:") {
		t.Fatalf("proxy addr %q", px.Addr)
	}

	// Disallowed target.
	if _, code, err := connectVia(px.Addr, h.fqdn+":443"); err != nil || code != http.StatusForbidden {
		t.Fatalf("disallowed: code %d err %v", code, err)
	}
	// Non-CONNECT requests.
	proxyURL, _ := url.Parse("http://" + px.Addr)
	plain := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)}, Timeout: 10 * time.Second}
	resp, err := plain.Get(h.base + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("non-CONNECT: %d", resp.StatusCode)
	}

	// Allowed target: HTTP over the tunnel reaches the host, which identifies the proxy node.
	tunneled := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			deadline := time.Now().Add(30 * time.Second)
			for {
				c, code, err := connectVia(px.Addr, target)
				if err == nil && code == http.StatusOK {
					return c, nil
				}
				if time.Now().After(deadline) {
					return nil, fmt.Errorf("CONNECT: code %d err %v", code, err)
				}
				time.Sleep(200 * time.Millisecond)
			}
		},
	}}
	r := do(t, tunneled, "GET", h.base+"/v1/info", nil, nil)
	expectStatus(t, r, http.StatusForbidden, "not_paired")
	h.waitEvent("denied", func(e map[string]any) bool { return e["nodeName"] == cfg["hostname"] })

	// Pair through the tunnel, then the API answers.
	var opened struct{ Code string }
	mustDecode(t, api.HostPairingOpen(h.handle, 0), &opened)
	r = do(t, tunneled, "POST", h.base+"/v1/pair/request", map[string]string{"code": opened.Code, "deviceName": "tunnel"}, nil)
	expectStatus(t, r, http.StatusAccepted, "")
	if out := api.HostPairingDecide(h.handle, r.json(t)["requestId"].(string), true); apiError(out) != "" {
		t.Fatalf("decide: %s", out)
	}
	expectStatus(t, do(t, tunneled, "GET", h.base+"/v1/info", nil, nil), http.StatusOK, "")

	var st node.Status
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(100 * time.Millisecond) {
		mustDecode(t, api.Status(started.Handle), &st)
		if st.Listening && st.BackendState == "Running" && st.RSSMiB > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("proxy status: %+v", st)
		}
	}
	if out := api.Stop(started.Handle); out != `{"ok":true}` {
		t.Fatalf("stop: %s", out)
	}
	if code := apiError(api.Status(started.Handle)); code != "unknown_handle" {
		t.Fatalf("status after stop: %q", code)
	}
}

func TestE2EStateEvents(t *testing.T) {
	h := startHost(t)
	ev := h.waitEvent("state", func(e map[string]any) bool {
		st, _ := e["status"].(map[string]any)
		return st["backendState"] == "Running" && st["listening"] == true
	})
	if st := ev["status"].(map[string]any); st["fqdn"] != h.fqdn {
		t.Fatalf("state event: %v", ev)
	}
}
