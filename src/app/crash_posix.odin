#+build !windows
package main

import "core:c"
import "core:sys/posix"

// The crash handlers of Linux, Android, the iPad and the Mac (crash_log.odin): a handler for
// each signal a crash raises writes what happened and the stack into the log, then puts the
// handler that was there before back and returns, so the faulting instruction faults again
// and the system's own handling (a core dump, Android's tombstone, Apple's crash report)
// sees the crash as it was. Everything a handler calls is safe in a signal handler: write,
// sigaction, backtrace (loaded before the first crash) and dladdr.

@(private = "file")
CRASH_SIGNALS := [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGTRAP, .SIGFPE, .SIGABRT}

// Bytes of the stack the handlers run on, so that a stack overflow on the main thread,
// which leaves no stack to run a handler on, is still written down.
@(private = "file")
CRASH_ALT_STACK :: 64 << 10

when ODIN_PLATFORM_SUBTARGET == .Android {
	// Bionic's sigaction is laid out unlike glibc's, which core:sys/posix follows: its flags
	// come first and its signal set is one word on arm64.
	@(private = "file")
	Crash_Action :: struct {
		sa_flags:     posix.SA_Flags,
		sa_sigaction: proc "c" (_: posix.Signal, _: ^posix.siginfo_t, _: rawptr),
		sa_mask:      u64,
		sa_restorer:  rawptr,
	}

	foreign import crash_libc "system:c"
	// dladdr is in libdl, which app/jni/CMakeLists.txt links.
	foreign import crash_libdl "system:dl"

	@(private = "file", default_calling_convention = "c")
	foreign crash_libc {
		@(link_name = "sigaction")
		crash_sigaction :: proc(sig: posix.Signal, act, old: ^Crash_Action) -> c.int ---
		// LLVM's unwinder, which the NDK links into every library; bionic has no backtrace
		// before API 33.
		_Unwind_Backtrace :: proc(trace: proc "c" (ctx: rawptr, arg: rawptr) -> c.int, arg: rawptr) -> c.int ---
		_Unwind_GetIP :: proc(ctx: rawptr) -> uintptr ---
	}
	@(private = "file", default_calling_convention = "c")
	foreign crash_libdl {
		dladdr :: proc(addr: rawptr, info: ^Crash_Dl_Info) -> c.int ---
	}
} else {
	@(private = "file")
	Crash_Action :: posix.sigaction_t

	when ODIN_OS == .Darwin {
		foreign import crash_libc "system:System"
	} else {
		foreign import crash_libc "system:c"
	}

	@(private = "file", default_calling_convention = "c")
	foreign crash_libc {
		@(link_name = "sigaction")
		crash_sigaction :: proc(sig: posix.Signal, act, old: ^Crash_Action) -> c.int ---
		backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
		dladdr :: proc(addr: rawptr, info: ^Crash_Dl_Info) -> c.int ---
	}
}

@(private = "file")
Crash_Dl_Info :: struct {
	dli_fname: cstring,
	dli_fbase: rawptr,
	dli_sname: cstring,
	dli_saddr: rawptr,
}

@(private = "file")
crash_posix: struct {
	old:       [len(CRASH_SIGNALS)]Crash_Action,
	installed: bool,
	main:      posix.pthread_t,
	stack:     [CRASH_ALT_STACK]u8,
}

// Writes `bytes` to the log, all of them unless the file fails.
crash_raw_write :: proc "contextless" (bytes: []u8) {
	fd := posix.FD(crash_log.fd)
	if crash_log.file == nil do return
	at := 0
	for at < len(bytes) {
		rest := bytes[at:]
		n := posix.write(fd, raw_data(rest), c.size_t(len(rest)))
		if n <= 0 do return
		at += int(n)
	}
}

crash_handlers_install :: proc() {
	p := &crash_posix
	p.main = posix.pthread_self()
	when ODIN_PLATFORM_SUBTARGET != .Android {
		// glibc loads its unwinder on the first backtrace, which allocates: done here, never
		// in a handler.
		warm: [4]rawptr
		_ = backtrace(&warm[0], len(warm))
	}
	alt := posix.stack_t {
		ss_sp   = &p.stack[0],
		ss_size = len(p.stack),
	}
	_ = posix.sigaltstack(&alt, nil)
	act: Crash_Action
	act.sa_sigaction = crash_signal
	act.sa_flags = {.SIGINFO, .ONSTACK}
	for sig, i in CRASH_SIGNALS do _ = crash_sigaction(sig, &act, &p.old[i])
	p.installed = true
	when MOBILE {
		// A tablet app's standard error goes nowhere, and Odin's runtime writes there what a
		// failed bounds check or a worker thread's panic says before it traps: into the log
		// it goes instead.
		_ = posix.dup2(posix.FD(crash_log.fd), 2)
	}
}

crash_handlers_remove :: proc() {
	p := &crash_posix
	if !p.installed do return
	for sig, i in CRASH_SIGNALS do _ = crash_sigaction(sig, &p.old[i], nil)
	p.installed = false
}

@(private = "file")
crash_signal :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, _: rawptr) {
	p := &crash_posix
	index := 0
	for s, i in CRASH_SIGNALS do if s == sig do index = i
	// The handler that was there before comes back first, so a crash inside this one ends
	// the process as it would have.
	_ = crash_sigaction(sig, &p.old[index], nil)
	if crash_take_turn() {
		line: Crash_Line
		crash_line_add(&line, CRASH_TAG)
		#partial switch sig {
		case .SIGSEGV: crash_line_add(&line, "SIGSEGV (a bad memory access)")
		case .SIGBUS:  crash_line_add(&line, "SIGBUS (a bad memory access)")
		case .SIGILL:  crash_line_add(&line, "SIGILL (an illegal instruction or a trap)")
		case .SIGTRAP: crash_line_add(&line, "SIGTRAP (a trap)")
		case .SIGFPE:  crash_line_add(&line, "SIGFPE (an arithmetic error)")
		case .SIGABRT: crash_line_add(&line, "SIGABRT (abort)")
		}
		if (sig == .SIGSEGV || sig == .SIGBUS) && info != nil {
			crash_line_add(&line, " at ")
			crash_line_hex(&line, uintptr(info.si_addr))
		}
		crash_line_add(&line, " on the main thread\n" if posix.pthread_self() == p.main else " on another thread\n")
		crash_line_write(&line)
		crash_stack(&line)
		crash_line_add(&line, CRASH_TAG)
		crash_line_add(&line, "end\n")
		crash_line_write(&line)
	}
	// A fault returns to fault again, now with the system's handler. Abort and a trap may
	// return past the instruction that raised them, so they are raised again.
	if sig == .SIGABRT || sig == .SIGTRAP do _ = posix.raise(sig)
}

// The stack of the crashing thread, a line a frame, each with its module and offset.
@(private = "file")
crash_stack :: proc "contextless" (line: ^Crash_Line) {
	frames: [CRASH_STACK_FRAMES]rawptr
	n := 0
	when ODIN_PLATFORM_SUBTARGET == .Android {
		Walk :: struct {
			frames: ^[CRASH_STACK_FRAMES]rawptr,
			n:      int,
		}
		walk := Walk{&frames, 0}
		_ = _Unwind_Backtrace(proc "c" (ctx: rawptr, arg: rawptr) -> c.int {
			w := (^Walk)(arg)
			if w.n >= len(w.frames) do return 5 // _URC_END_OF_STACK
			w.frames[w.n] = rawptr(_Unwind_GetIP(ctx))
			w.n += 1
			return 0 // _URC_NO_REASON
		}, &walk)
		n = walk.n
	} else {
		n = int(backtrace(&frames[0], len(frames)))
	}
	for i in 0 ..< n {
		address := uintptr(frames[i])
		info: Crash_Dl_Info
		module, symbol: string
		base: uintptr
		if dladdr(frames[i], &info) != 0 {
			if info.dli_fname != nil do module = crash_base_name(string(info.dli_fname))
			if info.dli_sname != nil do symbol = string(info.dli_sname)
			base = uintptr(info.dli_fbase)
		}
		crash_line_frame(line, i, address, module, base, symbol)
	}
}
