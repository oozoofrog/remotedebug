package host

import (
	"net/http"
	"strings"
	"testing"
)

func TestDeviceCrashNeedsPairing(t *testing.T) {
	h, _ := newResourceTestHost(t, false)
	w := servePost(h, "/v1/crashes", `{"kind":"ips","text":"x"}`)
	if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "not_paired") {
		t.Fatalf("status %d body %s", w.Code, w.Body)
	}
}

func TestDeviceCrashValidatesBody(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	for _, body := range []string{
		`{"kind":"other","text":"x"}`,
		`{"kind":"ips","text":"  "}`,
		`{"kind":"ips","text":"` + strings.Repeat("x", MaxCrashTextBytes+1) + `"}`,
		`not json`,
	} {
		if w := servePost(h, "/v1/crashes", body); w.Code != http.StatusBadRequest {
			t.Fatalf("status %d for %.40s", w.Code, body)
		}
	}
	w := servePost(h, "/v1/crashes", `{"kind":"ips","name":"App.ips","bundleId":"com.example.app","crashedAt":"soon","text":"{\"bug_type\":\"309\"}"}`)
	if w.Code != http.StatusAccepted || !strings.Contains(w.Body.String(), `"accepted":1`) {
		t.Fatalf("status %d body %s", w.Code, w.Body)
	}
	w = servePost(h, "/v1/crashes", `{"kind":"feedback","bundleId":"com.example.app","text":"버튼이 눌리지 않아요"}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("feedback status %d body %s", w.Code, w.Body)
	}
}
