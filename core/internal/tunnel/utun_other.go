//go:build !darwin

package tunnel

import (
	"errors"

	"github.com/tailscale/wireguard-go/tun"
)

var errUnsupported = errors.New("utun is only supported on darwin/ios")

// CheckUTUN always fails off Apple platforms.
func CheckUTUN(fd int) error { return errUnsupported }

// OpenUTUN always fails off Apple platforms.
func OpenUTUN(fd int) (tun.Device, error) { return nil, errUnsupported }

// setLastKnownDefaultInterface does nothing off Apple platforms.
func setLastKnownDefaultInterface(ifName string) {}
