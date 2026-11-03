package main

import "core:sys/darwin"
import "core:sys/posix"

// The memory the app holds now, in bytes: its physical footprint, the number the iPad and
// the Mac judge an app by (Xcode's memory gauge, and what iPadOS ends an app over); 0 when
// the system does not say.
process_memory :: proc() -> int {
	info: darwin.rusage_info_v0
	if darwin.proc_pid_rusage(posix.getpid(), .V0, &info) != 0 do return 0
	return int(info.ri_phys_footprint)
}
