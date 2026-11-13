/* RemoteDebug core C API (docs/protocol.md §9).
 *
 * Every function except rd_free returns a NUL-terminated UTF-8 JSON string
 * that the caller must release with rd_free. Failures are returned as
 * {"error":{"code":"…","message":"…"}}. NULL string arguments are treated as
 * empty strings. */
#ifndef RDCORE_H
#define RDCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Starts a node (mode host|proxy|tunnel; tunnel: docs/tunnel.md). Returns {"handle":N}. */
char *rd_start(const char *config_json);
/* Returns the status JSON (protocol §9). */
char *rd_status(int64_t handle);
/* Stops the node and invalidates the handle. Returns {"ok":true}. */
char *rd_stop(int64_t handle);
/* Publishes BuildDescriptor + ipaPath. Returns {"ok":true,"id":"b_…"}. */
char *rd_host_publish(int64_t handle, const char *build_json);
/* Returns {"ok":true}. */
char *rd_host_unpublish(int64_t handle, const char *build_id);
/* Shares a file with paired devices (protocol-addenda H): {"name","size","sha256","path"}.
 * Returns {"ok":true,"id":"r_…"}. */
char *rd_host_publish_resource(int64_t handle, const char *resource_json);
/* Returns {"ok":true}. */
char *rd_host_unpublish_resource(int64_t handle, const char *resource_id);
/* Replaces the document served by GET /v1/agent (protocol-addenda K):
 * {"enabled","projects","agents","requests"}. "enabled" gates POST /v1/agent/requests.
 * Returns {"ok":true}. */
char *rd_host_set_agent_board(int64_t handle, const char *board_json);
/* Starts, updates or stops (empty "listen") the loopback update page for the
 * iPhone app itself (protocol-addenda I). Not tied to a handle.
 * Returns {"ok":true,"addr":"127.0.0.1:P"}. */
char *rd_update_page_set(const char *config_json);
/* Replaces the allow-list with {"devices":[DeviceEntry]}. Returns {"ok":true}. */
char *rd_host_set_devices(int64_t handle, const char *devices_json);
/* Opens a pairing code; ttl_seconds <= 0 means 300. Returns {"code":"…","expiresAt":"…"}. */
char *rd_host_pairing_open(int64_t handle, int32_t ttl_seconds);
/* allow is 0 or 1. Returns {"ok":true,"device":{…}} on approval, {"ok":true} on denial. */
char *rd_host_pairing_decide(int64_t handle, const char *request_id, int32_t allow);
/* Starts the loopback CONNECT proxy (proxy mode). Returns {"addr":"127.0.0.1:P"}. */
char *rd_proxy_start(int64_t handle, const char *listen_addr);
/* Tunnel mode: name of the interface that now carries the default route
 * (NWPathMonitor), e.g. "en0" or "pdp_ip0". "" is ignored. A changed name makes
 * the core re-check the network at once and rebind its sockets. Returns {"ok":true}. */
char *rd_tunnel_set_default_interface(int64_t handle, const char *if_name);
/* Tunnel mode: MagicDNS name of the peer whose path rd_status reports as
 * "peerPath" ({"direct":bool,"addr":"…","relay":"…"}). "" stops reporting.
 * Returns {"ok":true}. */
char *rd_tunnel_set_path_peer(int64_t handle, const char *fqdn);
/* Waits up to timeout_ms. Returns {"event":{…}} or {"event":null}. */
char *rd_next_event(int64_t handle, int32_t timeout_ms);
/* Frees a string returned by any rd_* function. */
void rd_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* RDCORE_H */
