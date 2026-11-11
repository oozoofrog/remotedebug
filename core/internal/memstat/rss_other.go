//go:build !(darwin && cgo)

package memstat

// RSSMiB falls back to memory obtained by the Go runtime when mach
// task_info is unavailable (non-darwin or CGO_ENABLED=0 builds).
func RSSMiB() float64 { return goRuntimeMiB() }
