package host

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func servePost(h *Host, target, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", target, strings.NewReader(body))
	w := httptest.NewRecorder()
	h.Handler().ServeHTTP(w, r)
	return w
}

func TestAgentBoardDefaultsToDisabled(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	w := serve(h, "GET", "/v1/agent")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"enabled":false`) {
		t.Fatalf("status %d body %s", w.Code, w.Body)
	}
	w = servePost(h, "/v1/agent/requests", `{"text":"hi"}`)
	if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "agent_disabled") {
		t.Fatalf("status %d body %s", w.Code, w.Body)
	}
}

func TestAgentRequestNeedsPairing(t *testing.T) {
	h, _ := newResourceTestHost(t, false)
	h.SetAgentBoard(`{"enabled":true}`)
	for _, w := range []*httptest.ResponseRecorder{
		serve(h, "GET", "/v1/agent"),
		servePost(h, "/v1/agent/requests", `{"text":"hi"}`),
		servePost(h, "/v1/agent/requests/a_1/cancel", ``),
	} {
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "not_paired") {
			t.Fatalf("status %d body %s", w.Code, w.Body)
		}
	}
}

func TestAgentRequestBecomesEvent(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	board := `{"enabled":true,"projects":[{"id":"p1","name":"App"}],"agents":["claude"],"requests":[]}`
	if err := h.SetAgentBoard(board); err != nil {
		t.Fatal(err)
	}
	if w := serve(h, "GET", "/v1/agent"); w.Body.String() != board {
		t.Fatalf("board %s", w.Body)
	}
	w := servePost(h, "/v1/agent/requests", `{"text":"  테스트를 고쳐줘 ","project":"p1","agent":"claude"}`)
	if w.Code != http.StatusAccepted {
		t.Fatalf("status %d body %s", w.Code, w.Body)
	}
	var out struct{ ID string }
	json.Unmarshal(w.Body.Bytes(), &out)
	if !strings.HasPrefix(out.ID, "a_") {
		t.Fatalf("id %q", out.ID)
	}
	ev := h.events.Next(0)
	if ev["type"] != "agent-request" || ev["requestId"] != out.ID || ev["text"] != "테스트를 고쳐줘" ||
		ev["project"] != "p1" || ev["deviceId"] != "d_1" {
		t.Fatalf("event %v", ev)
	}

	w = servePost(h, "/v1/agent/requests/"+out.ID+"/cancel", ``)
	if w.Code != http.StatusAccepted {
		t.Fatalf("cancel status %d", w.Code)
	}
	ev = h.events.Next(0)
	if ev["type"] != "agent-cancel" || ev["requestId"] != out.ID {
		t.Fatalf("event %v", ev)
	}
}

func TestAgentRequestRejectsBadInput(t *testing.T) {
	h, _ := newResourceTestHost(t, true)
	h.SetAgentBoard(`{"enabled":true}`)
	for _, body := range []string{
		`{"text":"   "}`,
		`not json`,
		`{"text":"` + strings.Repeat("a", MaxAgentTextBytes+1) + `"}`,
		`{"text":"hi","project":"` + strings.Repeat("p", 200) + `"}`,
	} {
		if w := servePost(h, "/v1/agent/requests", body); w.Code != http.StatusBadRequest {
			t.Fatalf("status %d for %.40s", w.Code, body)
		}
	}
	if err := h.SetAgentBoard(`nope`); err == nil {
		t.Fatal("bad board accepted")
	}
}
