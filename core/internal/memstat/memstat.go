// Package memstat reports process memory for rd_status and applies the
// Network Extension memory settings.
package memstat

import (
	"math"
	"runtime/debug"
	"runtime/metrics"
)

// goRuntimeMiB returns the memory mapped by the Go runtime in MiB.
func goRuntimeMiB() float64 {
	s := []metrics.Sample{{Name: "/memory/classes/total:bytes"}}
	metrics.Read(s)
	if s[0].Value.Kind() != metrics.KindUint64 {
		return 0
	}
	return round1(float64(s[0].Value.Uint64()) / (1 << 20))
}

func round1(v float64) float64 { return math.Round(v*10) / 10 }

// ApplyLimit sets a soft Go memory limit and a more aggressive GC when
// limitMiB > 0 (process-wide; intended for the iOS Network Extension).
func ApplyLimit(limitMiB int) {
	if limitMiB <= 0 {
		return
	}
	debug.SetMemoryLimit(int64(limitMiB) << 20)
	debug.SetGCPercent(50)
}
