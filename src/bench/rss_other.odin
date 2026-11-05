#+build !windows
package bench

import "core:os"
import "core:strconv"
import "core:strings"

// The process's memory where /proc keeps it (Linux and Android); 0 elsewhere.

peak_rss_mb :: proc() -> f64 {return status_mb("VmHWM:")}
rss_mb :: proc() -> f64 {return status_mb("VmRSS:")}

when ODIN_OS == .Linux {
	foreign import libc "system:c"
	@(default_calling_convention = "c")
	foreign libc {
		malloc_trim :: proc(pad: uint) -> i32 ---
	}
}

// The next peak_rss_mb measures from here: on Linux the heap's free pages go back to the
// system (glibc's malloc_trim) and the peak is reset to what the process holds now
// (/proc/self/clear_refs), so a bench row shows its own peak rather than the largest of
// the rows before it, whose freed memory the heap would otherwise keep. Elsewhere the
// peak stays the process's.
peak_rss_reset :: proc() {
	when ODIN_OS == .Linux {
		_ = malloc_trim(0)
		if f, err := os.open("/proc/self/clear_refs", {.Write}); err == nil {
			_, _ = os.write_string(f, "5")
			os.close(f)
		}
	}
}

// A memory figure from /proc/self/status, in MB (0 where unavailable).
status_mb :: proc(key: string) -> f64 {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil do return 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, key) {
			fields := strings.fields(line, context.temp_allocator)
			if kb, ok2 := strconv.parse_f64(fields[1]); ok2 do return kb / 1024
		}
	}
	return 0
}
