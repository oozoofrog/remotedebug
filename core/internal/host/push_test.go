package host

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

var testPushToken = strings.Repeat("0123abcd", 8)

func pushBodyJSON(token string) string {
	return `{"token":"` + token + `","bundleId":"com.oozoofrog.app.RemoteDebugPhone","environment":"development"}`
}

func servePush(h *Host, method, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "/v1/devices/self/push-token", strings.NewReader(body))
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	return w
}

func drainEvents(h *Host) []map[string]any {
	var out []map[string]any
	for {
		ev := h.events.Next(0)
		if ev == nil {
			return out
		}
		out = append(out, ev)
	}
}

func TestPushTokenPutAndDeleteOnTailnet(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	drainEvents(h)
	upper := strings.ToUpper(testPushToken)
	w := servePush(h, "PUT", pushBodyJSON(upper))
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"registered":true}` {
		t.Fatalf("PUT: %d %s", w.Code, w.Body)
	}
	if p := h.devices["n_phone"].Push; p == nil || p.Token != testPushToken {
		t.Fatalf("stored %+v", p)
	}
	evs := drainEvents(h)
	if len(evs) != 1 || evs[0]["type"] != "device-updated" {
		t.Fatalf("events %v", evs)
	}
	b, _ := json.Marshal(evs[0]["device"])
	if !strings.Contains(string(b), `"push":{"token":"`+testPushToken+`","bundleId":"com.oozoofrog.app.RemoteDebugPhone","environment":"development"}`) {
		t.Fatalf("device json %s", b)
	}
	if w := servePush(h, "PUT", pushBodyJSON(testPushToken)); w.Code != 200 || len(drainEvents(h)) != 0 {
		t.Fatalf("same PUT: %d", w.Code)
	}
	w = servePush(h, "DELETE", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"registered":false}` || h.devices["n_phone"].Push != nil {
		t.Fatalf("DELETE: %d %s", w.Code, w.Body)
	}
	if len(drainEvents(h)) != 1 {
		t.Fatal("DELETE should emit one event")
	}
	if w := servePush(h, "DELETE", ""); w.Code != 200 || len(drainEvents(h)) != 0 {
		t.Fatalf("second DELETE: %d", w.Code)
	}
}

func TestPushTokenRejectsBadBodies(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	drainEvents(h)
	good := "com.oozoofrog.app.RemoteDebugPhone"
	mk := func(tok, bid, env string) string {
		return `{"token":"` + tok + `","bundleId":"` + bid + `","environment":"` + env + `"}`
	}
	cases := map[string]string{
		"not hex":    mk(strings.Repeat("zz", 32), good, "development"),
		"odd length": mk(testPushToken+"a", good, "development"),
		"too short":  mk(strings.Repeat("ab", 31), good, "development"),
		"too long":   mk(strings.Repeat("ab", 257), good, "development"),
		"empty bid":  mk(testPushToken, "", "development"),
		"bad bid":    mk(testPushToken, "com/evil", "development"),
		"production": mk(testPushToken, good, "production"),
		"not json":   "nope",
		"trailing":   mk(testPushToken, good, "development") + "garbage",
		"over 4 KiB": mk(testPushToken, strings.Repeat("a", 5000), "development"),
	}
	for name, body := range cases {
		w := servePush(h, "PUT", body)
		if w.Code != http.StatusBadRequest || errorCode(t, w) != "bad_request" {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	if h.devices["n_phone"].Push != nil || len(drainEvents(h)) != 0 {
		t.Fatal("state changed by bad bodies")
	}
}

func TestPushTokenNeedsPairing(t *testing.T) {
	h, _ := newResourceTestHost(t, false)
	for _, m := range []string{"PUT", "DELETE"} {
		w := servePush(h, m, pushBodyJSON(testPushToken))
		if w.Code != http.StatusForbidden || errorCode(t, w) != "not_paired" {
			t.Errorf("%s: %d %s", m, w.Code, w.Body)
		}
	}
}

func TestPushTokenOnDirectListener(t *testing.T) {
	h := newDirectTestHost(t)
	e := enroll(t, h)
	drainEvents(h)
	w := serveDirect(h, "PUT", "/v1/devices/self/push-token", authOf(e), strings.NewReader(pushBodyJSON(testPushToken)))
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"registered":true}` || len(drainEvents(h)) != 1 {
		t.Fatalf("PUT: %d %s", w.Code, w.Body)
	}
	w = serveDirect(h, "DELETE", "/v1/devices/self/push-token", authOf(e), nil)
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"registered":false}` || len(drainEvents(h)) != 1 {
		t.Fatalf("DELETE: %d %s", w.Code, w.Body)
	}
	if w := serveDirect(h, "PUT", "/v1/devices/self/push-token", "", strings.NewReader(pushBodyJSON(testPushToken))); w.Code != http.StatusForbidden {
		t.Fatalf("no token: %d", w.Code)
	}
}

func TestSetDevicesKeepsPushAndDropsItWithTheDevice(t *testing.T) {
	h, _ := newResourceTestHost(t, false)
	reg := &PushRegistration{Token: testPushToken, BundleID: "com.oozoofrog.app.RemoteDebugPhone", Environment: "development"}
	if err := h.SetDevices([]DeviceEntry{{ID: "d_1", NodeStableID: "n_phone", Push: reg}}); err != nil {
		t.Fatal(err)
	}
	if h.devices["n_phone"].Push == nil || *h.devices["n_phone"].Push != *reg {
		t.Fatal("push not preserved")
	}
	if err := h.SetDevices([]DeviceEntry{{ID: "d_2", NodeStableID: "n_other"}}); err != nil {
		t.Fatal(err)
	}
	if _, ok := h.devices["n_phone"]; ok {
		t.Fatal("device still present")
	}
	b, _ := json.Marshal(DeviceEntry{ID: "d_2", NodeStableID: "n_other"})
	if strings.Contains(string(b), "push") {
		t.Fatalf("push key present: %s", b)
	}
}
