package host

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
)

// Limits for POST /v1/crashes (protocol-addenda L).
const (
	MaxCrashBodyBytes = 2 << 20
	MaxCrashTextBytes = 1536 << 10
	maxCrashField     = 200
)

// CrashReport is one crash report a paired device sends: an .ips file the
// user shared into the phone app, or a MetricKit crash diagnostic of the
// phone app itself.
type CrashReport struct {
	Kind       string `json:"kind"`
	Name       string `json:"name"`
	BundleID   string `json:"bundleId"`
	AppVersion string `json:"appVersion"`
	CrashedAt  string `json:"crashedAt"`
	Text       string `json:"text"`
}

// handleDeviceCrash accepts one crash report from a paired device and hands it
// to the host app as a "device-crash" event. Nothing is stored here.
func (h *Host) handleDeviceCrash(w http.ResponseWriter, r *http.Request) {
	p, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	var c CrashReport
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, MaxCrashBodyBytes)).Decode(&c); err != nil {
		apierr.Write(w, apierr.BadRequest("크래시 기록 본문을 읽을 수 없습니다."))
		return
	}
	if c.Kind != "ips" && c.Kind != "metrickit" {
		apierr.Write(w, apierr.BadRequest("kind는 ips 또는 metrickit이어야 합니다."))
		return
	}
	c.Text = strings.ToValidUTF8(c.Text, "?")
	if strings.TrimSpace(c.Text) == "" || len(c.Text) > MaxCrashTextBytes {
		apierr.Write(w, apierr.BadRequest("text는 비어 있지 않고 1536KB 이하여야 합니다."))
		return
	}
	c.Name = truncateUTF8(strings.ToValidUTF8(c.Name, "?"), maxCrashField)
	c.BundleID = truncateUTF8(strings.ToValidUTF8(c.BundleID, "?"), maxCrashField)
	c.AppVersion = truncateUTF8(strings.ToValidUTF8(c.AppVersion, "?"), maxCrashField)
	if t, err := time.Parse(time.RFC3339Nano, c.CrashedAt); err == nil {
		c.CrashedAt = t.UTC().Format(time.RFC3339Nano)
	} else {
		c.CrashedAt = Timestamp(h.now())
	}
	h.mu.Lock()
	d, paired := h.devices[p.StableID]
	h.mu.Unlock()
	if !paired { // removed while the body was read
		h.deny(w, r, apierr.NotPaired(), p.NodeName)
		return
	}
	h.events.Push(events.Event{
		"type":       "device-crash",
		"deviceId":   d.ID,
		"deviceName": d.Name,
		"nodeName":   d.NodeName,
		"report":     c,
	})
	writeJSON(w, http.StatusAccepted, map[string]any{"accepted": 1})
}
