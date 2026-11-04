#+build !windows
#+build !darwin
#+build !js
package main

import "core:strconv"
import "core:strings"
import "core:sys/posix"

// The memory the app holds in RAM now, in bytes: the resident pages /proc/self/statm counts
// (Linux and Android), read into a buffer on the stack so a frame allocates nothing; 0 when
// the file cannot be read.
process_memory :: proc() -> int {
	fd := posix.open("/proc/self/statm", {})
	if fd < 0 do return 0
	defer posix.close(fd)
	buf: [128]u8
	n := posix.read(fd, &buf[0], len(buf))
	if n <= 0 do return 0
	// Size, then resident, both in pages.
	fields := strings.fields_iterator
	text := string(buf[:n])
	_, _ = fields(&text)
	resident, ok := fields(&text)
	if !ok do return 0
	pages, parsed := strconv.parse_int(resident)
	if !parsed do return 0
	return pages * int(posix.sysconf(._PAGESIZE))
}

// How much more memory the app can take before the system runs short, in bytes: the
// MemAvailable line of /proc/meminfo (Linux and Android), which counts the free pages and
// the caches the kernel would give back, as the memory check before a heavy step needs
// (memory_check.odin); 0 when it cannot be read, which the check takes as unknown.
memory_headroom :: proc() -> int {
	fd := posix.open("/proc/meminfo", {})
	if fd < 0 do return 0
	defer posix.close(fd)
	buf: [512]u8
	n := posix.read(fd, &buf[0], len(buf))
	if n <= 0 do return 0
	text := string(buf[:n])
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "MemAvailable:") do continue
		rest := line[len("MemAvailable:"):]
		kb, ok := strings.fields_iterator(&rest)
		if !ok do return 0
		value, parsed := strconv.parse_int(kb)
		return value * 1024 if parsed else 0
	}
	return 0
}
