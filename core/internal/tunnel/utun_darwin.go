//go:build darwin

package tunnel

import (
	"fmt"
	"os"
	"strings"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/sys/unix"

	"tailscale.com/net/netmon"
)

// utunName returns the interface name of a utun control socket. It only
// reads (getsockopt), so it is safe as a pre-start check.
func utunName(fd int) (string, error) {
	return unix.GetsockoptString(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */)
}

// CheckUTUN reports whether fd is an open utun control socket: its peer is
// a kernel control (AF_SYSTEM) and it names a "utunN" interface. It only
// reads, so it is safe before any side effect.
func CheckUTUN(fd int) error {
	if fd <= 0 {
		return fmt.Errorf("utun fd %d", fd)
	}
	sa, err := unix.Getpeername(fd)
	if err != nil {
		return fmt.Errorf("fd %d: getpeername: %w", fd, err)
	}
	if _, ok := sa.(*unix.SockaddrCtl); !ok {
		return fmt.Errorf("fd %d is not a kernel control socket", fd)
	}
	name, err := utunName(fd)
	if err != nil || !strings.HasPrefix(name, "utun") {
		return fmt.Errorf("fd %d is not a utun socket", fd)
	}
	return nil
}

// OpenUTUN wraps a duplicate of fd as a TUN device. The caller keeps fd and
// stays its owner; closing the device closes only the duplicate.
func OpenUTUN(fd int) (tun.Device, error) {
	dup, err := unix.Dup(fd)
	if err != nil {
		return nil, fmt.Errorf("dup utun fd %d: %w", fd, err)
	}
	unix.CloseOnExec(dup)
	// Non-blocking so the Go netpoller owns it and Close interrupts a blocked
	// Read. O_NONBLOCK is shared with fd (same open file description).
	if err := unix.SetNonblock(dup, true); err != nil {
		unix.Close(dup)
		return nil, fmt.Errorf("set nonblock: %w", err)
	}
	// mtu 0: keep the utun MTU (set by NEPacketTunnelNetworkSettings.mtu);
	// CreateTUNFromFile closes the file on every error path.
	return tun.CreateTUNFromFile(os.NewFile(uintptr(dup), "/dev/tun"), 0)
}

// setLastKnownDefaultInterface stores the default interface name in
// netmon (process-global). netmon keeps the last name but falls back to the
// route table when that interface is down or has no address. It does not
// re-evaluate anything by itself: see Node.SetDefaultInterface.
func setLastKnownDefaultInterface(ifName string) {
	netmon.UpdateLastKnownDefaultRouteInterface(ifName)
}
