//go:build darwin

package tunnel

import (
	"testing"

	"golang.org/x/sys/unix"
)

// A socket that is not a utun is rejected by the read-only check, and a
// failed OpenUTUN closes only its own duplicate: the caller's fd stays open.
func TestTunnelOpenUTUNKeepsCallerFD(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	if err := CheckUTUN(fds[0]); err == nil {
		t.Fatal("CheckUTUN accepted a unix socket")
	}
	if err := CheckUTUN(-1); err == nil {
		t.Fatal("CheckUTUN accepted -1")
	}
	if dev, err := OpenUTUN(fds[0]); err == nil {
		dev.Close()
		t.Fatal("OpenUTUN accepted a unix socket")
	}
	if _, err := unix.FcntlInt(uintptr(fds[0]), unix.F_GETFD, 0); err != nil {
		t.Fatalf("caller's fd was closed: %v", err)
	}
}
