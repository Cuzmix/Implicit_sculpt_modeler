#+build !windows
package bench

import "core:os"
import "core:strconv"
import "core:strings"

// The process's memory where /proc keeps it (Linux and Android); 0 elsewhere.

peak_rss_mb :: proc() -> f64 {return status_mb("VmHWM:")}
rss_mb :: proc() -> f64 {return status_mb("VmRSS:")}

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
