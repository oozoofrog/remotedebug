package host

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
)

// 기기 푸시 토큰 등록·삭제 (docs/protocol-addenda.md P). 발신은 Mac 앱이 하고,
// 코어는 토큰을 기기 항목에 보관만 한다.

const (
	maxPushBodyBytes = 4 << 10
	minPushTokenLen  = 64
	maxPushTokenLen  = 512
	pushEnvironment  = "development"
)

type pushBody struct {
	Token       string `json:"token"`
	BundleID    string `json:"bundleId"`
	Environment string `json:"environment"`
}

func isHex(s string) bool {
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func isBundleID(s string) bool {
	if len(s) < 1 || len(s) > 255 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}

func (h *Host) handlePushTokenPut(w http.ResponseWriter, r *http.Request) {
	p, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	var body pushBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPushBodyBytes))
	if err := dec.Decode(&body); err != nil {
		apierr.Write(w, apierr.BadRequest("요청 본문이 올바른 JSON이 아닙니다."))
		return
	}
	// JSON 값 하나 뒤에 다른 내용이 붙어 있으면 받지 않는다.
	if _, err := dec.Token(); err != io.EOF {
		apierr.Write(w, apierr.BadRequest("요청 본문이 올바른 JSON이 아닙니다."))
		return
	}
	n := len(body.Token)
	if n < minPushTokenLen || n > maxPushTokenLen || n%2 != 0 || !isHex(body.Token) {
		apierr.Write(w, apierr.BadRequest("token은 64~512자의 짝수 길이 16진수여야 합니다."))
		return
	}
	if !isBundleID(body.BundleID) {
		apierr.Write(w, apierr.BadRequest("bundleId가 올바르지 않습니다."))
		return
	}
	if body.Environment != pushEnvironment {
		apierr.Write(w, apierr.BadRequest("environment는 development만 받습니다."))
		return
	}
	reg := &PushRegistration{Token: strings.ToLower(body.Token), BundleID: body.BundleID, Environment: body.Environment}
	h.setPush(w, r, p, reg)
}

func (h *Host) handlePushTokenDelete(w http.ResponseWriter, r *http.Request) {
	p, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	h.setPush(w, r, p, nil)
}

// setPush stores reg (nil deletes) and emits device-updated only on a change.
func (h *Host) setPush(w http.ResponseWriter, r *http.Request, p Peer, reg *PushRegistration) {
	h.mu.Lock()
	d, paired := h.devices[p.StableID]
	if paired {
		same := (d.Push == nil && reg == nil) || (d.Push != nil && reg != nil && *d.Push == *reg)
		if !same {
			d.Push = reg
			h.devices[p.StableID] = d
			h.events.Push(events.Event{"type": "device-updated", "device": d})
		}
	}
	h.mu.Unlock()
	if !paired { // requirePaired 뒤에 지워진 기기
		h.deny(w, r, apierr.NotPaired(), p.NodeName)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"registered": reg != nil})
}
