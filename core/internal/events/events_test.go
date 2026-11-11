package events

import (
	"testing"
	"time"
)

func TestOverflowDropsOldestAndLogs(t *testing.T) {
	q := New(3)
	for i := 0; i < 5; i++ {
		q.Push(Event{"type": "x", "n": i})
	}
	first := q.Next(0)
	if first["type"] != "log" {
		t.Fatalf("first event = %v, want drop log", first)
	}
	for want := 2; want < 5; want++ {
		e := q.Next(0)
		if e["n"] != want {
			t.Fatalf("got %v, want n=%d", e, want)
		}
	}
	if e := q.Next(10 * time.Millisecond); e != nil {
		t.Fatalf("expected timeout, got %v", e)
	}
}

func TestNextWakesOnPush(t *testing.T) {
	q := New(DefaultCapacity)
	go func() {
		time.Sleep(20 * time.Millisecond)
		q.Push(Event{"type": "state"})
	}()
	start := time.Now()
	e := q.Next(2 * time.Second)
	if e == nil || e["type"] != "state" || time.Since(start) > time.Second {
		t.Fatalf("Next = %v after %v", e, time.Since(start))
	}
	q.Close()
	if e := q.Next(time.Second); e != nil {
		t.Fatalf("after Close: %v", e)
	}
}

func TestOverflowKeepsHighPriority(t *testing.T) {
	q := New(3)
	q.Push(Event{"type": "pair-request", "n": 0})
	q.Push(Event{"type": "denied", "n": 1})
	q.Push(Event{"type": "session", "n": 2})
	q.Push(Event{"type": "device-added", "n": 3}) // drops the denied event
	q.Push(Event{"type": "log", "n": 4})          // full of high-priority: dropped
	q.Push(Event{"type": "pair-decided", "n": 5}) // drops the oldest (pair-request)
	if e := q.Next(0); e["type"] != "log" || e["message"] != "event queue full: dropped 3 events" {
		t.Fatalf("first event = %v", e)
	}
	for _, want := range []int{2, 3, 5} {
		if e := q.Next(0); e["n"] != want {
			t.Fatalf("got %v, want n=%d", e, want)
		}
	}
}

// A newer network-settings event replaces one still waiting; other events
// keep their order.
func TestTunnelSettingsEventReplaced(t *testing.T) {
	q := New(DefaultCapacity)
	q.Push(Event{"type": "state", "n": 1})
	q.Replace(Event{"type": "network-settings", "n": 2})
	q.Push(Event{"type": "log", "n": 3})
	q.Replace(Event{"type": "network-settings", "n": 4})
	var got []any
	for e := q.Next(0); e != nil; e = q.Next(0) {
		got = append(got, e["n"])
	}
	if len(got) != 3 || got[0] != 1 || got[1] != 3 || got[2] != 4 {
		t.Fatalf("got %v, want [1 3 4]", got)
	}
}
