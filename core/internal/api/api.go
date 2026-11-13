// Package api implements the C API surface (protocol §9) as plain Go
// functions taking and returning JSON strings. The cgo package capi is a thin
// wrapper around it.
package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"remotedebug/core/internal/apierr"
	"remotedebug/core/internal/host"
	"remotedebug/core/internal/updatepage"
	"remotedebug/core/internal/node"
)

var (
	mu        sync.Mutex
	next      int64
	nodes     = map[int64]*node.Node{}
	stateDirs = map[int64]string{} // handle -> stateDirKey, for live handles
)

// stateDirKey returns the canonical (absolute, clean, symlink-free) form of
// a state directory, creating it if needed.
func stateDirKey(dir string) (string, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(abs, 0o700); err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(filepath.Clean(abs))
}

func errJSON(err error) string { return string(apierr.JSON(err)) }

func okJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return errJSON(apierr.Internal("JSON 인코딩 실패"))
	}
	return string(b)
}

func lookup(h int64) (*node.Node, error) {
	mu.Lock()
	defer mu.Unlock()
	n := nodes[h]
	if n == nil {
		return nil, apierr.UnknownHandle()
	}
	return n, nil
}

func lookupHost(h int64) (*host.Host, error) {
	n, err := lookup(h)
	if err != nil {
		return nil, err
	}
	if n.Host() == nil {
		return nil, apierr.InvalidConfig("host 모드가 아닙니다.")
	}
	return n.Host(), nil
}

// Start implements rd_start.
func Start(configJSON string) string { return StartWithOptions(configJSON, node.Options{}) }

// StartWithOptions is Start with in-process options (fake clock, short TTLs).
// A stateDir can back only one live handle: a second start on it fails with
// invalid_config "state_dir_in_use" until rd_stop releases it.
func StartWithOptions(configJSON string, opt node.Options) string {
	cfg, err := node.ParseConfig(configJSON)
	if err != nil {
		return errJSON(err)
	}
	key, err := stateDirKey(cfg.StateDir)
	if err != nil {
		return errJSON(apierr.InvalidConfig("stateDir를 만들 수 없습니다."))
	}
	mu.Lock()
	for _, k := range stateDirs {
		if k == key {
			mu.Unlock()
			return errJSON(apierr.InvalidConfig("state_dir_in_use"))
		}
	}
	next++
	h := next
	stateDirs[h] = key // reserved while starting
	mu.Unlock()

	n, err := node.Start(cfg, opt)
	mu.Lock()
	defer mu.Unlock()
	if err != nil {
		delete(stateDirs, h)
		return errJSON(err)
	}
	nodes[h] = n
	return okJSON(map[string]int64{"handle": h})
}

// Status implements rd_status.
func Status(h int64) string {
	n, err := lookup(h)
	if err != nil {
		return errJSON(err)
	}
	return okJSON(n.Status())
}

// Stop implements rd_stop.
func Stop(h int64) string {
	mu.Lock()
	n := nodes[h]
	delete(nodes, h)
	mu.Unlock()
	if n == nil {
		return errJSON(apierr.UnknownHandle())
	}
	n.Close()
	mu.Lock()
	delete(stateDirs, h) // the state dir is free only once the node is closed
	mu.Unlock()
	return okJSON(map[string]bool{"ok": true})
}

// HostPublish implements rd_host_publish.
func HostPublish(h int64, buildJSON string) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	var req host.PublishRequest
	if err := json.Unmarshal([]byte(buildJSON), &req); err != nil {
		return errJSON(apierr.BadRequest("빌드 JSON을 읽지 못했습니다."))
	}
	id, err := hs.Publish(req)
	if err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]any{"ok": true, "id": id})
}

// HostUnpublish implements rd_host_unpublish.
func HostUnpublish(h int64, buildID string) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	if err := hs.Unpublish(buildID); err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]bool{"ok": true})
}

// HostPublishResource implements rd_host_publish_resource.
func HostPublishResource(h int64, resourceJSON string) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	var req host.ResourcePublishRequest
	if err := json.Unmarshal([]byte(resourceJSON), &req); err != nil {
		return errJSON(apierr.BadRequest("파일 JSON을 읽지 못했습니다."))
	}
	id, err := hs.PublishResource(req)
	if err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]any{"ok": true, "id": id})
}

// HostUnpublishResource implements rd_host_unpublish_resource.
func HostUnpublishResource(h int64, resourceID string) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	if err := hs.UnpublishResource(resourceID); err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]bool{"ok": true})
}

// HostSetAgentBoard implements rd_host_set_agent_board (protocol-addenda K).
func HostSetAgentBoard(h int64, boardJSON string) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	if err := hs.SetAgentBoard(boardJSON); err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]bool{"ok": true})
}

func init() { host.UpdatePageURL = updatepage.PublicURL }

// UpdatePageSet implements rd_update_page_set (protocol-addenda I).
func UpdatePageSet(configJSON string) string {
	var c updatepage.Config
	if err := json.Unmarshal([]byte(configJSON), &c); err != nil {
		return errJSON(apierr.BadRequest("업데이트 페이지 JSON을 읽지 못했습니다."))
	}
	addr, err := updatepage.Set(c)
	if err != nil {
		return errJSON(apierr.BadRequest(err.Error()))
	}
	return okJSON(map[string]any{"ok": true, "addr": addr})
}

// HostSetDevices implements rd_host_set_devices.
func HostSetDevices(h int64, devicesJSON string) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	var in struct {
		Devices *[]host.DeviceEntry `json:"devices"`
	}
	if err := json.Unmarshal([]byte(devicesJSON), &in); err != nil || in.Devices == nil {
		return errJSON(apierr.BadRequest(`{"devices":[…]} 형식의 기기 목록 JSON이 필요합니다.`))
	}
	if err := hs.SetDevices(*in.Devices); err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]bool{"ok": true})
}

// HostPairingOpen implements rd_host_pairing_open (ttl <= 0 means 300 s).
func HostPairingOpen(h int64, ttlSeconds int) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	if ttlSeconds > 3600 {
		return errJSON(apierr.BadRequest("ttl_seconds는 3600 이하여야 합니다."))
	}
	code, exp := hs.OpenPairing(time.Duration(ttlSeconds) * time.Second)
	return okJSON(map[string]string{"code": code, "expiresAt": host.Timestamp(exp)})
}

// HostPairingDecide implements rd_host_pairing_decide.
func HostPairingDecide(h int64, requestID string, allow bool) string {
	hs, err := lookupHost(h)
	if err != nil {
		return errJSON(err)
	}
	d, err := hs.Decide(requestID, allow)
	if err != nil {
		return errJSON(err)
	}
	if d == nil {
		return okJSON(map[string]bool{"ok": true})
	}
	return okJSON(map[string]any{"ok": true, "device": d})
}

// ProxyStart implements rd_proxy_start.
func ProxyStart(h int64, listenAddr string) string {
	n, err := lookup(h)
	if err != nil {
		return errJSON(err)
	}
	addr, err := n.StartProxy(listenAddr)
	if err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]string{"addr": addr})
}

// TunnelSetDefaultInterface implements rd_tunnel_set_default_interface:
// the interface name that now carries the device's default route (from
// NWPathMonitor). An empty name is accepted and ignored.
func TunnelSetDefaultInterface(h int64, ifName string) string {
	n, err := lookup(h)
	if err != nil {
		return errJSON(err)
	}
	if n.Config().Mode != "tunnel" {
		return errJSON(apierr.InvalidConfig("tunnel 모드가 아닙니다."))
	}
	if !validIfName(ifName) {
		return errJSON(apierr.BadRequest("인터페이스 이름이 올바르지 않습니다."))
	}
	n.SetDefaultInterface(ifName)
	return okJSON(map[string]bool{"ok": true})
}

// TunnelSetPathPeer implements rd_tunnel_set_path_peer: the MagicDNS name of
// the peer whose path rd_status reports as peerPath. "" stops reporting.
func TunnelSetPathPeer(h int64, fqdn string) string {
	n, err := lookup(h)
	if err != nil {
		return errJSON(err)
	}
	if n.Config().Mode != "tunnel" {
		return errJSON(apierr.InvalidConfig("tunnel 모드가 아닙니다."))
	}
	if len(fqdn) > 253 {
		return errJSON(apierr.BadRequest("피어 이름이 올바르지 않습니다."))
	}
	n.SetPathPeer(fqdn)
	return okJSON(map[string]bool{"ok": true})
}

// validIfName accepts "" and BSD interface names (en0, pdp_ip0; < IFNAMSIZ).
func validIfName(s string) bool {
	if len(s) > 15 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '.' || r == '-') {
			return false
		}
	}
	return true
}

// NextEvent implements rd_next_event; it blocks up to timeoutMs.
func NextEvent(h int64, timeoutMs int) string {
	n, err := lookup(h)
	if err != nil {
		return errJSON(err)
	}
	if timeoutMs < 0 {
		timeoutMs = 0
	}
	ev := n.Events().Next(time.Duration(timeoutMs) * time.Millisecond)
	if ev == nil {
		return `{"event":null}`
	}
	return okJSON(map[string]any{"event": ev})
}
