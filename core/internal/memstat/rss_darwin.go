//go:build darwin && cgo

package memstat

/*
#include <mach/mach.h>

// rd_phys_footprint returns the task's physical footprint in bytes (the value
// jetsam compares against the Network Extension memory limit), or 0.
static unsigned long long rd_phys_footprint(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return info.phys_footprint;
}
*/
import "C"

// RSSMiB reports the process physical footprint in MiB via mach task_info
// (TASK_VM_INFO.phys_footprint).
func RSSMiB() float64 {
	if b := uint64(C.rd_phys_footprint()); b > 0 {
		return round1(float64(b) / (1 << 20))
	}
	return goRuntimeMiB()
}
