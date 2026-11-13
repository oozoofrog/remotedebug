package host

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/http"
	"strings"
	"time"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/events"
	"remotedebug/core/internal/ids"
)

// This file is the same-network ("direct") surface of the host
// (docs/protocol-addenda.md O): the enrollment endpoint of the tailnet
// listener and the handler of the direct listener, which authenticates a
// paired device by a per-device token instead of WhoIs.

// DirectInfo describes the running direct listener to enrolling devices.
type DirectInfo struct {
	ID   string // Bonjour instance name
	Port int
	SPKI string // base64 SHA-256 of the certificate's SubjectPublicKeyInfo
}

// DirectAuthScheme is the Authorization scheme of the direct listener:
// "RD-Device <deviceId>.<token>".
const DirectAuthScheme = "RD-Device"

// Failed direct authentications are limited per remote IP: after
// directMaxFailures inside directFailWindow further requests get 429 without
// their token being looked at.
const (
	directMaxFailures = 10
	directFailWindow  = time.Minute
	maxDirectFailKeys = 1024
)

type directFailure struct {
	first time.Time
	count int
}

type peerKey struct{}

// DirectTokenHash is the stored form of a direct token: hex SHA-256 of its 32
// raw bytes. It returns "" for anything that is not such a token.
func DirectTokenHash(token string) string {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 32 {
		return ""
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func directOff() *apierr.Error {
	return apierr.New(http.StatusNotFound, "direct_off", "이 Mac은 같은 네트워크 직접 연결을 받지 않습니다.")
}

// handleDirectEnroll issues (or rotates) the caller's direct token. It is
// registered on the tailnet listener only, so the caller is identified by
// WhoIs and the allow-list.
func (h *Host) handleDirectEnroll(w http.ResponseWriter, r *http.Request) {
	p, ok := h.requirePaired(w, r)
	if !ok {
		return
	}
	var info DirectInfo
	on := false
	if h.direct != nil {
		info, on = h.direct()
	}
	if !on {
		apierr.Write(w, directOff())
		return
	}
	token := ids.NewToken()
	h.mu.Lock()
	d, paired := h.devices[p.StableID]
	if paired {
		d.DirectTokenHash = DirectTokenHash(token)
		h.devices[p.StableID] = d
		// The host app persists the hash; the token itself never leaves this response.
		h.events.Push(events.Event{"type": "device-updated", "device": d})
	}
	h.mu.Unlock()
	if !paired { // removed since requirePaired
		h.deny(w, r, apierr.NotPaired(), p.NodeName)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"directId": info.ID,
		"port":     info.Port,
		"tlsSPKI":  info.SPKI,
		"deviceId": d.ID,
		"token":    token,
	})
}

// DirectHandler returns the HTTP handler for the direct listener. It serves
// the API a paired device needs day to day and nothing else: no pairing, no
// enrollment, no install sessions, no /i/ downloads and no web page.
func (h *Host) DirectHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", h.handleInfo)
	mux.HandleFunc("GET /v1/builds", h.handleBuilds)
	mux.HandleFunc("POST /v1/logs", h.handleDeviceLogs)
	mux.HandleFunc("POST /v1/crashes", h.handleDeviceCrash)
	mux.HandleFunc("GET /v1/agent", h.handleAgentBoard)
	mux.HandleFunc("POST /v1/agent/requests", h.handleAgentRequest)
	mux.HandleFunc("POST /v1/agent/requests/{id}/cancel", h.handleAgentCancel)
	mux.HandleFunc("GET /v1/resources", h.handleResources)
	mux.HandleFunc("GET /v1/resources/{id}", h.handleResourceFile)
	mux.HandleFunc("PUT /v1/devices/self/push-token", h.handlePushTokenPut)
	mux.HandleFunc("DELETE /v1/devices/self/push-token", h.handlePushTokenDelete)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-RD-Protocol", "1")
		// Authentication comes first, so a stranger learns nothing about
		// which paths exist.
		peer, ok := h.directPeer(w, r)
		if !ok {
			return
		}
		if _, pattern := mux.Handler(r); pattern == "" {
			apierr.Write(w, routeError(mux, r))
			return
		}
		mux.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), peerKey{}, peer)))
	})
}

// directPeer authenticates a direct request and returns the device's tailnet
// identity, so handlers and session ownership checks see the same peer as on
// the tailnet listener.
func (h *Host) directPeer(w http.ResponseWriter, r *http.Request) (Peer, bool) {
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		ip = r.RemoteAddr
	}
	if h.directBlocked(ip) {
		apierr.Write(w, apierr.TooManyAttempts())
		return Peer{}, false
	}
	d, ok := h.directDevice(r.Header.Get("Authorization"))
	if !ok {
		h.noteDirectFailure(ip)
		h.deny(w, r, apierr.NotPaired(), "")
		return Peer{}, false
	}
	return Peer{StableID: d.NodeStableID, NodeName: d.NodeName, LoginName: d.LoginName}, true
}

// directDevice returns the allow-list entry the Authorization header proves.
func (h *Host) directDevice(header string) (DeviceEntry, bool) {
	scheme, cred, found := strings.Cut(header, " ")
	if !found || scheme != DirectAuthScheme {
		return DeviceEntry{}, false
	}
	id, token, found := strings.Cut(strings.TrimSpace(cred), ".")
	if !found || id == "" {
		return DeviceEntry{}, false
	}
	got := DirectTokenHash(token)
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, d := range h.devices {
		if d.ID != id {
			continue
		}
		if got == "" || d.DirectTokenHash == "" {
			return DeviceEntry{}, false
		}
		if subtle.ConstantTimeCompare([]byte(got), []byte(d.DirectTokenHash)) != 1 {
			return DeviceEntry{}, false
		}
		return d, true
	}
	return DeviceEntry{}, false
}

func (h *Host) directBlocked(ip string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	f := h.directFails[ip]
	if f == nil {
		return false
	}
	if h.now().Sub(f.first) >= directFailWindow {
		delete(h.directFails, ip)
		return false
	}
	return f.count >= directMaxFailures
}

func (h *Host) noteDirectFailure(ip string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	f := h.directFails[ip]
	if f == nil || now.Sub(f.first) >= directFailWindow {
		if f == nil && len(h.directFails) >= maxDirectFailKeys {
			for k, old := range h.directFails { // make room: drop expired entries, else any one
				if now.Sub(old.first) >= directFailWindow {
					delete(h.directFails, k)
				}
			}
			if len(h.directFails) >= maxDirectFailKeys {
				for k := range h.directFails {
					delete(h.directFails, k)
					break
				}
			}
		}
		h.directFails[ip] = &directFailure{first: now, count: 1}
		return
	}
	f.count++
}
