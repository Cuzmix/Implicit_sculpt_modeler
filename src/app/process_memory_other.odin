#+build !windows
#+build !darwin
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
