// Package faketun is an in-memory tun.Device for tests: the test plays the
// OS side of a utun. It is used only by tests, never by the shipped core.
package faketun

import (
	"os"
	"slices"
	"sync"

	"github.com/tailscale/wireguard-go/tun"
)

// Device is an in-memory TUN. Packets the test sends on FromOS are read by
// the engine; packets the engine writes come out on ToOS.
type Device struct {
	FromOS chan []byte // test → engine
	ToOS   chan []byte // engine → test; closed by Close

	mu      sync.Mutex
	closed  chan struct{}
	isClose bool
	readErr chan error
	events  chan tun.Event
}

// New returns an open device that reports itself up.
func New() *Device {
	d := &Device{
		FromOS:  make(chan []byte, 1024),
		ToOS:    make(chan []byte, 1024),
		closed:  make(chan struct{}),
		readErr: make(chan error, 1),
		events:  make(chan tun.Event, 1),
	}
	d.events <- tun.EventUp
	return d
}

// Closed is closed once the device is closed.
func (d *Device) Closed() <-chan struct{} { return d.closed }

// FailRead makes the next Read return err, as a dying utun would.
func (d *Device) FailRead(err error) {
	select {
	case d.readErr <- err:
	default:
	}
}

// File returns nil: there is no OS file.
func (d *Device) File() *os.File { return nil }

// Read blocks for one packet. It never returns (0, nil), which would make
// the engine spin.
func (d *Device) Read(slab []byte, pkts []tun.ReadPacket) (int, error) {
	select {
	case <-d.closed:
		return 0, os.ErrClosed
	case err := <-d.readErr:
		return 0, err
	case p := <-d.FromOS:
		if len(p) > len(slab)-2*tun.ReadPacketSpacing {
			return 0, tun.ErrTooManySegments
		}
		pkts[0].Offset = tun.ReadPacketSpacing
		pkts[0].Size = copy(slab[tun.ReadPacketSpacing:], p)
		return 1, nil
	}
}

// Write hands packets to ToOS. It drops packets when ToOS is full and never
// blocks the engine.
func (d *Device) Write(bufs [][]byte, offset int) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.isClose {
		return 0, os.ErrClosed
	}
	for _, b := range bufs {
		if p := b[offset:]; len(p) > 0 {
			select {
			case d.ToOS <- slices.Clone(p):
			default:
			}
		}
	}
	return len(bufs), nil
}

func (d *Device) MTU() (int, error)        { return 1280, nil }
func (d *Device) Name() (string, error)    { return "faketun", nil }
func (d *Device) Events() <-chan tun.Event { return d.events }
func (d *Device) BatchSize() int           { return 1 }

// Close closes ToOS and the event channel. It is idempotent.
func (d *Device) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.isClose {
		d.isClose = true
		close(d.closed)
		close(d.ToOS)
		close(d.events)
	}
	return nil
}
