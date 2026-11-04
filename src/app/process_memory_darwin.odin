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

when ODIN_PLATFORM_SUBTARGET_IOS {
	foreign import memory_libsystem "system:System"

	@(default_calling_convention = "c")
	foreign memory_libsystem {
		// libSystem's own count (os/proc.h, iOS 13): what this app may still take before
		// iPadOS ends it, its limit less its footprint.
		os_proc_available_memory :: proc() -> uint ---
	}
}

// How much more memory the app can take before the system ends it or runs short, in
// bytes, for the check before a heavy step (memory_check.odin). On the iPad it is the
// system's own number, the one Nomad shows as Free. The Mac pages to disk and compresses
// memory rather than ending the app, and gives no limit to measure against, so it says 0,
// which the check takes as unknown.
memory_headroom :: proc() -> int {
	when ODIN_PLATFORM_SUBTARGET_IOS {
		return int(os_proc_available_memory())
	} else {
		return 0
	}
}
