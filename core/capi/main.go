// Command capi is the cgo C API of the RemoteDebug core (protocol §9), built
// with -buildmode=c-archive. Every function returns a NUL-terminated JSON
// string allocated with malloc; callers release it with rd_free. The stable
// public header is include/rdcore.h (the Go-generated header is not shipped).
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"remotedebug/core/internal/api"
)

func out(s string) *C.char { return C.CString(s) }

//export rd_start
func rd_start(configJSON *C.char) *C.char { return out(api.Start(C.GoString(configJSON))) }

//export rd_status
func rd_status(handle C.int64_t) *C.char { return out(api.Status(int64(handle))) }

//export rd_stop
func rd_stop(handle C.int64_t) *C.char { return out(api.Stop(int64(handle))) }

//export rd_host_publish
func rd_host_publish(handle C.int64_t, buildJSON *C.char) *C.char {
	return out(api.HostPublish(int64(handle), C.GoString(buildJSON)))
}

//export rd_host_unpublish
func rd_host_unpublish(handle C.int64_t, buildID *C.char) *C.char {
	return out(api.HostUnpublish(int64(handle), C.GoString(buildID)))
}

//export rd_host_publish_resource
func rd_host_publish_resource(handle C.int64_t, resourceJSON *C.char) *C.char {
	return out(api.HostPublishResource(int64(handle), C.GoString(resourceJSON)))
}

//export rd_host_unpublish_resource
func rd_host_unpublish_resource(handle C.int64_t, resourceID *C.char) *C.char {
	return out(api.HostUnpublishResource(int64(handle), C.GoString(resourceID)))
}

//export rd_host_set_agent_board
func rd_host_set_agent_board(handle C.int64_t, boardJSON *C.char) *C.char {
	return out(api.HostSetAgentBoard(int64(handle), C.GoString(boardJSON)))
}

//export rd_update_page_set
func rd_update_page_set(configJSON *C.char) *C.char {
	return out(api.UpdatePageSet(C.GoString(configJSON)))
}

//export rd_host_set_devices
func rd_host_set_devices(handle C.int64_t, devicesJSON *C.char) *C.char {
	return out(api.HostSetDevices(int64(handle), C.GoString(devicesJSON)))
}

//export rd_host_pairing_open
func rd_host_pairing_open(handle C.int64_t, ttlSeconds C.int32_t) *C.char {
	return out(api.HostPairingOpen(int64(handle), int(ttlSeconds)))
}

//export rd_host_pairing_decide
func rd_host_pairing_decide(handle C.int64_t, requestID *C.char, allow C.int32_t) *C.char {
	return out(api.HostPairingDecide(int64(handle), C.GoString(requestID), allow != 0))
}

//export rd_proxy_start
func rd_proxy_start(handle C.int64_t, listenAddr *C.char) *C.char {
	return out(api.ProxyStart(int64(handle), C.GoString(listenAddr)))
}

//export rd_tunnel_set_default_interface
func rd_tunnel_set_default_interface(handle C.int64_t, ifName *C.char) *C.char {
	return out(api.TunnelSetDefaultInterface(int64(handle), C.GoString(ifName)))
}

//export rd_tunnel_set_path_peer
func rd_tunnel_set_path_peer(handle C.int64_t, fqdn *C.char) *C.char {
	return out(api.TunnelSetPathPeer(int64(handle), C.GoString(fqdn)))
}

//export rd_next_event
func rd_next_event(handle C.int64_t, timeoutMs C.int32_t) *C.char {
	return out(api.NextEvent(int64(handle), int(timeoutMs)))
}

//export rd_free
func rd_free(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
