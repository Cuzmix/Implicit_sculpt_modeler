package main

import win32 "core:sys/windows"

// The memory the app holds in RAM now, in bytes, as Task Manager's working set counts it;
// 0 when Windows does not say.
process_memory :: proc() -> int {
	c: win32.PROCESS_MEMORY_COUNTERS
	c.cb = size_of(c)
	if !win32.GetProcessMemoryInfo(win32.GetCurrentProcess(), &c, size_of(c)) do return 0
	return int(c.WorkingSetSize)
}
