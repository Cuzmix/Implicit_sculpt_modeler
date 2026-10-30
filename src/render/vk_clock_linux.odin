#+build linux
package render

import "core:sys/linux"

import sdl "vendor:sdl3"

// VK_GOOGLE_display_timing reports times on CLOCK_MONOTONIC, which only Linux and Android
// name; elsewhere the backend never turns it on.
VK_CLOCK_MONOTONIC :: true

// A CLOCK_MONOTONIC time as SDL nanoseconds (sdl.GetTicksNS). SDL counts from its start
// on CLOCK_MONOTONIC (Android) or CLOCK_MONOTONIC_RAW (Linux), so the offset is read again
// at each call rather than kept: the two Linux clocks drift apart as NTP slews one.
vk_monotonic_to_ticks :: proc(monotonic_ns: u64) -> u64 {
	now, err := linux.clock_gettime(.MONOTONIC)
	ticks := sdl.GetTicksNS()
	if err != .NONE do return 0
	now_ns := u64(now.time_sec) * 1e9 + u64(now.time_nsec)
	if monotonic_ns + ticks < now_ns do return 0
	return monotonic_ns + ticks - now_ns
}
