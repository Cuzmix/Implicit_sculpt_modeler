#+build !linux
package render

// VK_GOOGLE_display_timing reports times on CLOCK_MONOTONIC, which only Linux and Android
// name; elsewhere the backend never turns it on (vk_clock_linux.odin).
VK_CLOCK_MONOTONIC :: false

vk_monotonic_to_ticks :: proc(monotonic_ns: u64) -> u64 {
	return 0
}
