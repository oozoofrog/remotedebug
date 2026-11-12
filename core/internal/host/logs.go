package host

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
)

// Limits for POST /v1/logs (protocol-addenda G).
const (
	MaxDeviceLogBodyBytes = 128 << 10
	MaxDeviceLogEntries   = 200
	MaxDeviceLogMessage   = 4096
	maxDeviceLogSource    = 40
)

// DeviceLogEntry is one log line a paired device sends.
type DeviceLogEntry struct {
	At      string `json:"at"`
	Level   string `json:"level"`
	Source  string `json:"source"`
	Message string `json:"message"`
}

// truncateUTF8 cuts s to at most n bytes on a rune boundary.
func truncateUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

func (h *Host) cleanLogEntry(e DeviceLogEntry) DeviceLogEntry {
	if t, err := time.Parse(time.RFC3339Nano, e.At); err == nil {
		e.At = t.UTC().Format(time.RFC3339Nano)
	} else {
		e.At = Timestamp(h.now())
	}
	switch e.Level {
	case "debug", "info", "warning", "error":
	default:
		e.Level = "info"
	}
	e.Source = truncateUTF8(strings.ToValidUTF8(e.Source, "?"), maxDeviceLogSource)
	e.Message = truncateUTF8(strings.ToValidUTF8(e.Message, "?"), MaxDeviceLogMessage)
	return e
}

// handleDeviceLogs accepts a batch of log lines from a paired device and hands
// them to the host app as one "device-log" event. Nothing is stored here.
func (h *Host) handleDeviceLogs(w http.ResponseWriter, r *http.Request) {
	p, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	var body struct {
		Entries []DeviceLogEntry `json:"entries"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, MaxDeviceLogBodyBytes)).Decode(&body); err != nil {
		apierr.Write(w, apierr.BadRequest("로그 본문을 읽을 수 없습니다."))
		return
	}
	if len(body.Entries) == 0 || len(body.Entries) > MaxDeviceLogEntries {
		apierr.Write(w, apierr.BadRequest("entries는 1~200개여야 합니다."))
		return
	}
	entries := make([]DeviceLogEntry, len(body.Entries))
	for i, e := range body.Entries {
		entries[i] = h.cleanLogEntry(e)
	}
	h.mu.Lock()
	d, paired := h.devices[p.StableID]
	h.mu.Unlock()
	if !paired { // removed while the body was read
		h.deny(w, r, apierr.NotPaired(), p.NodeName)
		return
	}
	h.events.Push(events.Event{
		"type":       "device-log",
		"deviceId":   d.ID,
		"deviceName": d.Name,
		"nodeName":   d.NodeName,
		"entries":    entries,
	})
	writeJSON(w, http.StatusAccepted, map[string]any{"accepted": len(entries)})
}
