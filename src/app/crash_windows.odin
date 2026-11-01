#+build windows
package main

import win "core:sys/windows"

// The crash handler of Windows (crash_log.odin): the unhandled exception filter writes what
// the exception was, where, on which thread and the stack into the log, then lets the search
// go on, so Windows Error Reporting and a debugger see the crash as before. It calls only
// kernel32, never the heap.

foreign import crash_kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign crash_kernel32 {
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: rawptr, phModule: ^win.HMODULE) -> win.BOOL ---
	SetThreadStackGuarantee :: proc(StackSizeInBytes: ^win.ULONG) -> win.BOOL ---
}

// GetModuleHandleExW's flags: the address is inside the module, and its count stays as it is.
@(private = "file")
MODULE_FROM_ADDRESS :: 0x4 | 0x2

// Bytes Windows keeps for the main thread after a stack overflow, so the filter has room to
// run.
@(private = "file")
CRASH_STACK_GUARANTEE :: 64 << 10

@(private = "file")
crash_windows: struct {
	old:       win.LPTOP_LEVEL_EXCEPTION_FILTER,
	installed: bool,
	main:      win.DWORD,
}

// Writes `bytes` to the log, all of them unless the file fails.
crash_raw_write :: proc "contextless" (bytes: []u8) {
	if crash_log.file == nil do return
	handle := win.HANDLE(crash_log.fd)
	at := 0
	for at < len(bytes) {
		written: win.DWORD
		if !win.WriteFile(handle, raw_data(bytes[at:]), win.DWORD(len(bytes) - at), &written, nil) || written == 0 do return
		at += int(written)
	}
}

crash_handlers_install :: proc() {
	w := &crash_windows
	w.main = win.GetCurrentThreadId()
	guarantee := win.ULONG(CRASH_STACK_GUARANTEE)
	_ = SetThreadStackGuarantee(&guarantee)
	w.old = win.SetUnhandledExceptionFilter(crash_filter)
	w.installed = true
}

crash_handlers_remove :: proc() {
	w := &crash_windows
	if !w.installed do return
	_ = win.SetUnhandledExceptionFilter(w.old)
	w.installed = false
}

@(private = "file")
crash_filter :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	if info == nil || info.ExceptionRecord == nil || !crash_take_turn() do return win.EXCEPTION_CONTINUE_SEARCH
	rec := info.ExceptionRecord
	line: Crash_Line
	crash_line_add(&line, CRASH_TAG)
	crash_line_add(&line, "exception ")
	crash_line_hex(&line, uintptr(rec.ExceptionCode))
	switch rec.ExceptionCode {
	case 0xC0000005: crash_line_add(&line, " (a bad memory access)")
	case 0xC00000FD: crash_line_add(&line, " (the stack overflowed)")
	case 0xC000001D: crash_line_add(&line, " (an illegal instruction or a trap)")
	case 0x80000003: crash_line_add(&line, " (a breakpoint)")
	case 0xC0000094: crash_line_add(&line, " (an integer division by zero)")
	case 0xC0000409: crash_line_add(&line, " (a fast fail)")
	}
	crash_line_add(&line, " at ")
	crash_module_offset(&line, uintptr(rec.ExceptionAddress))
	if rec.ExceptionCode == 0xC0000005 && rec.NumberParameters >= 2 {
		crash_line_add(&line, " writing " if uintptr(rec.ExceptionInformation[0]) == 1 else " reading ")
		crash_line_hex(&line, uintptr(rec.ExceptionInformation[1]))
	}
	crash_line_add(&line, " on the main thread\n" if win.GetCurrentThreadId() == crash_windows.main else " on another thread\n")
	crash_line_write(&line)
	frames: [CRASH_STACK_FRAMES]win.PVOID
	n := int(win.RtlCaptureStackBackTrace(0, len(frames), &frames[0], nil))
	for i in 0 ..< n {
		module, base := crash_module(uintptr(frames[i]))
		crash_line_frame(&line, i, uintptr(frames[i]), module, base, "")
	}
	crash_line_add(&line, CRASH_TAG)
	crash_line_add(&line, "end\n")
	crash_line_write(&line)
	return win.EXCEPTION_CONTINUE_SEARCH
}

// The name of the module `address` is in, in a buffer of the thread's own, and its base.
@(private = "file")
crash_module :: proc "contextless" (address: uintptr) -> (name: string, base: uintptr) {
	// Only the first thread to crash writes, so one buffer serves.
	@(static)
	ascii: [260]u8
	module: win.HMODULE
	if !GetModuleHandleExW(MODULE_FROM_ADDRESS, rawptr(address), &module) do return "", 0
	wide: [260]u16
	n := int(win.GetModuleFileNameW(module, &wide[0], len(wide)))
	// The names are only read by people: anything past ASCII becomes '?'.
	for i in 0 ..< n do ascii[i] = u8(wide[i]) if wide[i] < 0x80 else '?'
	return crash_base_name(string(ascii[:n])), uintptr(module)
}

@(private = "file")
crash_module_offset :: proc "contextless" (line: ^Crash_Line, address: uintptr) {
	crash_line_hex(line, address)
	if module, base := crash_module(address); module != "" {
		crash_line_add(line, " ")
		crash_line_add(line, module)
		crash_line_add(line, "+")
		crash_line_hex(line, address - base)
	}
}
