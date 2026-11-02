#+build windows
package bench

import win "core:sys/windows"

// The process's memory on Windows, which has no /proc: its working set, the memory it
// holds in RAM, as the process's memory counters give it (0 if they cannot be read).

peak_rss_mb :: proc() -> f64 {
	c, ok := memory_counters()
	return f64(c.PeakWorkingSetSize) / (1 << 20) if ok else 0
}

rss_mb :: proc() -> f64 {
	c, ok := memory_counters()
	return f64(c.WorkingSetSize) / (1 << 20) if ok else 0
}

@(private = "file")
memory_counters :: proc() -> (c: win.PROCESS_MEMORY_COUNTERS, ok: bool) {
	c.cb = size_of(c)
	ok = bool(win.GetProcessMemoryInfo(win.GetCurrentProcess(), &c, size_of(c)))
	return
}
