package host

import (
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
	"remotedebug/core/internal/ids"
)

// Limits for agent requests (protocol-addenda K).
const (
	MaxAgentTextBytes  = 16 << 10
	MaxAgentBodyBytes  = 32 << 10
	MaxAgentBoardBytes = 2 << 20
	maxAgentFieldBytes = 128
)

const emptyAgentBoard = `{"enabled":false,"projects":[],"agents":[],"requests":[]}`

// SetAgentBoard replaces the document served by GET /v1/agent. The host app
// owns its contents; the core reads only "enabled", which gates
// POST /v1/agent/requests.
func (h *Host) SetAgentBoard(boardJSON string) error {
	if len(boardJSON) > MaxAgentBoardBytes {
		return apierr.BadRequest("에이전트 상태 JSON이 너무 큽니다(최대 2MiB).")
	}
	var head struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.Unmarshal([]byte(boardJSON), &head); err != nil {
		return apierr.BadRequest("에이전트 상태 JSON을 읽지 못했습니다.")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.agentBoard = []byte(boardJSON)
	h.agentEnabled = head.Enabled
	return nil
}

func agentDisabled() *apierr.Error {
	return apierr.New(http.StatusForbidden, "agent_disabled", "이 Mac은 iPhone의 에이전트 요청을 받지 않습니다. Mac 앱의 에이전트 화면에서 켭니다.")
}

func (h *Host) handleAgentBoard(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.requirePaired(w, r); !ok {
		return
	}
	h.mu.Lock()
	board := h.agentBoard
	h.mu.Unlock()
	if board == nil {
		board = []byte(emptyAgentBoard)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(board)
}

// agentDevice checks pairing and the host app's switch, and returns the
// allow-list entry of the caller.
func (h *Host) agentDevice(w http.ResponseWriter, r *http.Request) (DeviceEntry, bool) {
	p, ok := h.requirePaired(w, r)
	if !ok {
		return DeviceEntry{}, false
	}
	h.mu.Lock()
	d, paired := h.devices[p.StableID]
	enabled := h.agentEnabled
	h.mu.Unlock()
	if !paired { // removed since requirePaired
		h.deny(w, r, apierr.NotPaired(), p.NodeName)
		return DeviceEntry{}, false
	}
	if !enabled {
		apierr.Write(w, agentDisabled())
		return DeviceEntry{}, false
	}
	return d, true
}

func validAgentField(s string) bool {
	return len(s) <= maxAgentFieldBytes && utf8.ValidString(s)
}

// handleAgentRequest accepts a request for the user's coding agent and hands
// it to the host app as one "agent-request" event. The host app runs it and
// reports progress through SetAgentBoard.
func (h *Host) handleAgentRequest(w http.ResponseWriter, r *http.Request) {
	d, ok := h.agentDevice(w, r)
	if !ok {
		return
	}
	var body struct {
		Text      string `json:"text"`
		Project   string `json:"project"`
		Agent     string `json:"agent"`
		Continues string `json:"continues"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, MaxAgentBodyBytes)).Decode(&body); err != nil {
		apierr.Write(w, apierr.BadRequest("요청 본문을 읽을 수 없습니다."))
		return
	}
	text := strings.TrimSpace(body.Text)
	if text == "" || len(text) > MaxAgentTextBytes || !utf8.ValidString(text) {
		apierr.Write(w, apierr.BadRequest("text는 1바이트 이상 16KiB 이하의 UTF-8이어야 합니다."))
		return
	}
	if !validAgentField(body.Project) || !validAgentField(body.Agent) || !validAgentField(body.Continues) {
		apierr.Write(w, apierr.BadRequest("project, agent, continues는 128바이트 이하여야 합니다."))
		return
	}
	id := ids.NewID("a_")
	h.events.Push(events.Event{
		"type":       "agent-request",
		"requestId":  id,
		"deviceId":   d.ID,
		"deviceName": d.Name,
		"nodeName":   d.NodeName,
		"text":       text,
		"project":    body.Project,
		"agent":      body.Agent,
		"continues":  body.Continues,
	})
	writeJSON(w, http.StatusAccepted, map[string]any{"id": id})
}

// handleAgentCancel asks the host app to stop a request.
func (h *Host) handleAgentCancel(w http.ResponseWriter, r *http.Request) {
	d, ok := h.agentDevice(w, r)
	if !ok {
		return
	}
	h.events.Push(events.Event{
		"type":       "agent-cancel",
		"requestId":  r.PathValue("id"),
		"deviceId":   d.ID,
		"deviceName": d.Name,
	})
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}
