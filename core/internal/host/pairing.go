package host

import (
	"encoding/json"
	"net/http"
	"time"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
	"remotedebug/core/internal/ids"
)

type pairCode struct {
	code     string
	expires  time.Time
	failures int
	burned   bool // too many wrong attempts; only a new code helps
}

type pairRequest struct {
	id            string
	peer          Peer
	deviceName    string
	platform      string
	clientVersion string
	expires       time.Time
	state         string // pending, approved, denied, expired
}

// DefaultPairCodeTTL is used when rd_host_pairing_open gets ttl <= 0.
const DefaultPairCodeTTL = 300 * time.Second

// OpenPairing creates a new one-time pairing code, replacing any open one.
func (h *Host) OpenPairing(ttl time.Duration) (code string, expires time.Time) {
	if ttl <= 0 {
		ttl = DefaultPairCodeTTL
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	expires = h.now().Add(ttl)
	code = ids.NewPairCode()
	h.code = &pairCode{code: code, expires: expires}
	return code, expires
}

// Decide approves or denies a pending pair request. Approval adds the node to
// the allow-list and emits "device-added".
func (h *Host) Decide(requestID string, allow bool) (*DeviceEntry, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	pr := h.requests[requestID]
	if pr == nil {
		return nil, apierr.BadRequest("알 수 없는 페어링 요청입니다.")
	}
	h.expirePairLocked(pr, h.now())
	if pr.state != "pending" {
		return nil, apierr.BadRequest("이미 처리되었거나 만료된 페어링 요청입니다: " + pr.state)
	}
	if !allow {
		pr.state = "denied"
		h.events.Push(events.Event{"type": "pair-decided", "requestId": pr.id, "state": "denied"})
		return nil, nil
	}
	pr.state = "approved"
	d := DeviceEntry{
		ID:           ids.NewID("d_"),
		Name:         pr.deviceName,
		NodeStableID: pr.peer.StableID,
		NodeName:     pr.peer.NodeName,
		LoginName:    pr.peer.LoginName,
		PairedAt:     Timestamp(h.now()),
	}
	if old, ok := h.devices[d.NodeStableID]; ok {
		d.ID = old.ID
	}
	h.devices[d.NodeStableID] = d
	h.events.Push(events.Event{"type": "device-added", "device": d})
	h.events.Push(events.Event{"type": "pair-decided", "requestId": pr.id, "state": "approved"})
	return &d, nil
}

// SetDevices replaces the allow-list. Open sessions of nodes that are no
// longer listed become "failed" and their transfers are aborted.
func (h *Host) SetDevices(devices []DeviceEntry) error {
	m := make(map[string]DeviceEntry, len(devices))
	for _, d := range devices {
		if d.NodeStableID == "" {
			return apierr.BadRequest("nodeStableId가 비어 있습니다.")
		}
		m[d.NodeStableID] = d
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.devices = m
	for _, s := range h.sessions {
		if _, ok := m[s.peer.StableID]; !ok {
			h.failSessionLocked(s)
		}
	}
	return nil
}

func (h *Host) expirePairLocked(pr *pairRequest, now time.Time) {
	if pr.state == "pending" && !now.Before(pr.expires) {
		pr.state = "expired"
		h.events.Push(events.Event{"type": "pair-decided", "requestId": pr.id, "state": "expired"})
	}
}

type pairRequestBody struct {
	Code          string `json:"code"`
	DeviceName    string `json:"deviceName"`
	Platform      string `json:"platform"`
	ClientVersion string `json:"clientVersion"`
}

func (h *Host) handlePairRequest(w http.ResponseWriter, r *http.Request) {
	peer, ok := h.identify(w, r)
	if !ok {
		return
	}
	var body pairRequestBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&body); err != nil {
		apierr.Write(w, apierr.BadRequest("요청 본문이 올바른 JSON이 아닙니다."))
		return
	}
	if len(body.DeviceName) > 200 || len(body.Platform) > 200 || len(body.ClientVersion) > 100 {
		apierr.Write(w, apierr.BadRequest("필드가 너무 깁니다."))
		return
	}

	h.mu.Lock()
	now := h.now()
	c := h.code
	var fail *apierr.Error
	switch {
	case c == nil:
		fail = apierr.PairCodeInvalid()
	case !now.Before(c.expires): // checked first: an expired burned code is just expired
		h.code = nil
		fail = apierr.PairCodeInvalid()
	case c.burned:
		fail = apierr.TooManyAttempts()
	case !ids.PairCodeEqual(c.code, body.Code):
		c.failures++
		if c.failures >= h.lim.PairMaxFailures {
			c.burned = true
		}
		fail = apierr.PairCodeInvalid()
	}
	if fail != nil {
		h.mu.Unlock()
		h.deny(w, r, fail, peer.NodeName)
		return
	}
	h.code = nil // one-time use
	pr := &pairRequest{
		id:            ids.NewID("pr_"),
		peer:          peer,
		deviceName:    body.DeviceName,
		platform:      body.Platform,
		clientVersion: body.ClientVersion,
		expires:       now.Add(h.lim.PairRequestTTL),
		state:         "pending",
	}
	h.requests[pr.id] = pr
	h.events.Push(events.Event{
		"type":       "pair-request",
		"requestId":  pr.id,
		"deviceName": pr.deviceName,
		"nodeName":   peer.NodeName,
		"loginName":  peer.LoginName,
		"expiresAt":  Timestamp(pr.expires),
	})
	h.mu.Unlock()

	writeJSON(w, http.StatusAccepted, map[string]any{
		"requestId": pr.id,
		"state":     "pending",
		"expiresAt": Timestamp(pr.expires),
	})
}

func (h *Host) handlePairStatus(w http.ResponseWriter, r *http.Request) {
	peer, ok := h.identify(w, r)
	if !ok {
		return
	}
	h.mu.Lock()
	pr := h.requests[r.PathValue("id")]
	if pr == nil || pr.peer.StableID != peer.StableID {
		h.mu.Unlock()
		h.deny(w, r, apierr.NotPaired(), peer.NodeName)
		return
	}
	h.expirePairLocked(pr, h.now())
	resp := map[string]any{"requestId": pr.id, "state": pr.state}
	h.mu.Unlock()

	if resp["state"] == "approved" {
		info := h.info()
		resp["host"] = map[string]any{"hostId": info.HostID, "hostName": info.HostName, "fqdn": info.FQDN}
	}
	writeJSON(w, http.StatusOK, resp)
}
