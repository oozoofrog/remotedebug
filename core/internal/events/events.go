// Package events is the bounded event queue behind rd_next_event (protocol §10).
package events

import (
	"fmt"
	"slices"
	"sync"
	"time"
)

// Event is one protocol event; it always has a "type" key.
type Event map[string]any

// DefaultCapacity is the queue bound used by the core.
const DefaultCapacity = 256

// Queue is a bounded FIFO. When full, the oldest low-priority event
// ("denied", "log", "state") is dropped first; high-priority events
// (pair-request, pair-decided, device-added, session) are dropped only when
// nothing else is left. The next Next call reports drops as a "log" event.
type Queue struct {
	mu      sync.Mutex
	items   []Event
	cap     int
	dropped int
	wake    chan struct{} // closed and replaced on every Push
	closed  bool
}

// New returns a queue holding at most capacity events.
func New(capacity int) *Queue {
	return &Queue{cap: capacity, wake: make(chan struct{})}
}

// Push appends e, dropping the oldest event if the queue is full.
func (q *Queue) Push(e Event) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.pushLocked(e)
}

func (q *Queue) pushLocked(e Event) {
	if q.closed {
		return
	}
	if len(q.items) >= q.cap {
		q.dropped++
		i := slices.IndexFunc(q.items, lowPriority)
		switch {
		case i >= 0:
			q.items = slices.Delete(q.items, i, i+1)
		case lowPriority(e):
			return // the queue holds only high-priority events
		default:
			q.items = slices.Delete(q.items, 0, 1)
		}
	}
	q.items = append(q.items, e)
	close(q.wake)
	q.wake = make(chan struct{})
}

// Replace is Push for events where only the latest matters
// ("network-settings"): it first removes every queued event of e's type.
func (q *Queue) Replace(e Event) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.items = slices.DeleteFunc(q.items, func(x Event) bool { return x["type"] == e["type"] })
	q.pushLocked(e)
}

// lowPriority reports whether e may be dropped before other events.
func lowPriority(e Event) bool {
	switch e["type"] {
	case "denied", "log", "state", "device-log":
		return true
	}
	return false
}

// Log pushes a "log" event.
func (q *Queue) Log(level, format string, args ...any) {
	q.Push(Event{"type": "log", "level": level, "message": fmt.Sprintf(format, args...)})
}

// Next returns the next event, waiting up to timeout. It returns nil on
// timeout or after Close.
func (q *Queue) Next(timeout time.Duration) Event {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		q.mu.Lock()
		if q.dropped > 0 {
			n := q.dropped
			q.dropped = 0
			q.mu.Unlock()
			return Event{"type": "log", "level": "warn", "message": fmt.Sprintf("event queue full: dropped %d events", n)}
		}
		if len(q.items) > 0 {
			e := q.items[0]
			q.items[0] = nil
			q.items = q.items[1:]
			q.mu.Unlock()
			return e
		}
		if q.closed {
			q.mu.Unlock()
			return nil
		}
		wake := q.wake
		q.mu.Unlock()
		select {
		case <-wake:
		case <-timer.C:
			return nil
		}
	}
}

// Close wakes all waiters; later Pushes are ignored.
func (q *Queue) Close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if !q.closed {
		q.closed = true
		close(q.wake)
	}
}
