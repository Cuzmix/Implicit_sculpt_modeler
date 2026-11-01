package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// The run's log file and the crash log (README "Crash log"). An interactive run writes every
// log line to sculpt-log.txt in the app's folder as it comes, so nothing is lost when the
// process dies. A crash (a bad memory access, a trap, an Odin panic or failed assertion,
// abort) is caught by the platform's handler (crash_posix.odin, crash_windows.odin), which
// adds lines starting with CRASH_TAG saying what happened, on which thread and the stack,
// then hands the crash on to the system as before, so the system's own crash report is
// still made. The next start keeps the run before's log as sculpt-log-previous.txt and,
// when that run crashed, also as sculpt-log-crash.txt, which stays until the next crash; it
// tells the person once, and Settings > Files > Crash log saves a copy anywhere. Nothing
// is sent anywhere.

// What starts every line a crash handler writes, which is how the next start knows the run
// crashed: a run killed by the system or the person (a tablet closing a background app)
// writes none, so it is not taken for a crash.
CRASH_TAG :: "crash: "
// The log's name in the app's folder (platform_log_path).
CRASH_LOG_NAME :: "sculpt-log.txt"
// Where Settings says the log is.
when ODIN_PLATFORM_SUBTARGET_IOS {
	CRASH_LOG_WHERE :: "Every run writes its log to sculpt-log.txt in Files (On My iPad > Sculpt), and the log of a run that crashed stays there as sculpt-log-crash.txt until the next crash. Nothing is sent anywhere: save a copy to send with a bug report."
} else {
	CRASH_LOG_WHERE :: "Every run writes its log to sculpt-log.txt in the app's own folder, and the log of a run that crashed is kept as sculpt-log-crash.txt until the next crash. Nothing is sent anywhere: save a copy to send with a bug report."
}
// The bytes of ordinary lines a run's log may hold, so a run left open for days cannot fill
// the disk; the crash handler's lines are always written.
CRASH_LOG_CAP :: 16 << 20
// The longest previous log the next start reads to look for a crash.
CRASH_LOG_READ_CAP :: 64 << 20
// Frames of a crash's stack the handlers write: past this deep it is the same few frames.
CRASH_STACK_FRAMES :: 48

// The open log, a global because the crash handlers have no context and may run on any
// thread. Its strings come from the heap allocator.
Crash_Log :: struct {
	file:     ^os.File,
	fd:       uintptr, // the file's descriptor or handle, which the handlers write through
	lock:     sync.Mutex, // ordinary lines come from any thread; the handlers never take it
	path:     string, // sculpt-log.txt
	previous: string, // sculpt-log-previous.txt
	crash:    string, // sculpt-log-crash.txt
	written:  int,
	started:  time.Tick,
	inner:    log.Logger, // the console or system logger each line also goes to
	crashing: i32, // set by the first handler to run, so a second crash does not interleave
	last:     string, // what the previous run's crash was (its first crash line), or ""
	reported: bool, // whether the next start's toast said so
}

crash_log: Crash_Log

// The log's three file names for `path`: a.txt keeps the run before as a-previous.txt and
// the last crash as a-crash.txt, beside it.
crash_log_names :: proc(path: string, allocator := context.allocator) -> (previous, crash: string) {
	ext := filepath.ext(path)
	stem := path[:len(path) - len(ext)]
	return strings.concatenate({stem, "-previous", ext}, allocator), strings.concatenate({stem, "-crash", ext}, allocator)
}

// What a log's crash was: the text of its first crash line, sliced from `data`, or "" when
// the run did not crash.
crash_log_summary :: proc(data: []u8) -> string {
	text := string(data)
	at := 0
	for at < len(text) {
		end := strings.index_byte(text[at:], '\n')
		line := text[at:] if end < 0 else text[at:at + end]
		if strings.has_prefix(line, CRASH_TAG) do return strings.trim_space(line[len(CRASH_TAG):])
		if end < 0 do break
		at += end + 1
	}
	return ""
}

// Starts the log at `path`: the log there becomes the previous one (and the crash log if it
// has a crash), and a new one is opened with `header` as its first line. False when it
// cannot be written, and the run goes on with no log file.
crash_log_open :: proc(path, header: string) -> bool {
	heap := runtime.heap_allocator()
	l := &crash_log
	l.path = strings.clone(path, heap)
	l.previous, l.crash = crash_log_names(path, heap)
	if info, err := os.stat(path, context.temp_allocator); err == nil && info.size <= CRASH_LOG_READ_CAP {
		if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
			if last := crash_log_summary(data); last != "" {
				l.last = strings.clone(last, heap)
				_ = os.write_entire_file(l.crash, data)
			}
		}
	}
	_ = os.rename(path, l.previous)
	file, err := os.create(path)
	if err != nil {
		crash_log_free()
		return false
	}
	l.file, l.fd = file, os.fd(file)
	l.started = time.tick_now()
	crash_raw_write(transmute([]u8)header)
	crash_raw_write({'\n'})
	crash_handlers_install()
	return true
}

// Ends the log as a clean exit, which the last line says.
crash_log_close :: proc() {
	l := &crash_log
	if l.file != nil {
		sync.guard(&l.lock)
		crash_raw_write(transmute([]u8)string("exit: clean\n"))
		crash_handlers_remove()
		_ = os.close(l.file)
		l.file, l.fd = nil, 0
	}
	crash_log_free()
}

@(private = "file")
crash_log_free :: proc() {
	heap := runtime.heap_allocator()
	l := &crash_log
	delete(l.path, heap)
	delete(l.previous, heap)
	delete(l.crash, heap)
	delete(l.last, heap)
	l^ = {}
}

// The logger that writes each line to the log as well as to `inner` (the console or the
// system log). Its data is crash_log.inner.
crash_logger :: proc(inner: log.Logger) -> log.Logger {
	crash_log.inner = inner
	return {procedure = crash_logger_proc, data = &crash_log.inner, lowest_level = inner.lowest_level, options = inner.options}
}

@(private = "file")
crash_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	inner := (^log.Logger)(data)
	if inner.procedure != nil && level >= inner.lowest_level do inner.procedure(inner.data, level, text, options, location)
	name: string
	switch level {
	case .Debug:   name = "debug"
	case .Info:    name = "info"
	case .Warning: name = "warning"
	case .Error:   name = "error"
	case .Fatal:   name = "fatal"
	}
	// Built on the stack: worker threads log too, and their temp allocators are never freed.
	buf: [2048]u8
	line := fmt.bprintf(buf[:], "%.3f %s: %s\n", time.duration_seconds(time.tick_since(crash_log.started)), name, text)
	if len(line) == len(buf) do buf[len(buf) - 1] = '\n'
	l := &crash_log
	sync.guard(&l.lock)
	if l.file == nil || l.written + len(line) > CRASH_LOG_CAP do return
	l.written += len(line)
	crash_raw_write(transmute([]u8)line)
}

// The panic, failed assertion or ensure of the threads whose context the app made (the main
// thread's): its message and place go into the log before Odin's own procedure prints them
// and traps, which the handler then logs with the stack.
crash_assertion :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	line: Crash_Line
	crash_line_add(&line, CRASH_TAG)
	crash_line_add(&line, prefix)
	if message != "" {
		crash_line_add(&line, ": ")
		crash_line_add(&line, message)
	}
	crash_line_add(&line, " at ")
	crash_line_add(&line, filepath.base(loc.file_path))
	crash_line_add(&line, "(")
	crash_line_dec(&line, int(loc.line))
	crash_line_add(&line, ")\n")
	crash_line_write(&line)
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// Tells the person once, after a start, that the run before crashed and where its log is.
crash_log_report :: proc(app: ^App) {
	l := &crash_log
	if l.last == "" || l.reported do return
	l.reported = true
	report(app, nil, {.Warning}, "Sculpt crashed last time: %s. Its log is kept: Settings > Files > Crash log saves a copy.", l.last)
}

// Whether a crash log is there to save.
crash_log_kept :: proc() -> bool {
	return crash_log.crash != "" && os.exists(crash_log.crash)
}

// Copies the crash log to `path`, the file a save dialog picked (an Android content:// URI
// too); the outcome is a toast.
crash_log_save :: proc(app: ^App, path: string) -> bool {
	if !crash_log_kept() {
		file_note(app, true, "There is no crash log to save")
		return false
	}
	data, err := os.read_entire_file(crash_log.crash, context.temp_allocator)
	if err != nil {
		file_note(app, true, "The crash log could not be read: %v", err)
		return false
	}
	if why := write_durably(path, data); why != "" {
		file_note(app, true, "The crash log was not saved: %s", why)
		return false
	}
	file_note(app, false, "Saved the crash log as %s", path)
	return true
}

// The platform's name in the log's first line.
crash_log_platform :: proc() -> string {
	when ODIN_PLATFORM_SUBTARGET == .Android {
		return "Android"
	} else when ODIN_PLATFORM_SUBTARGET_IOS {
		return "iPadOS"
	} else {
		return fmt.tprintf("%v", ODIN_OS)
	}
}

// The log's first line: the build and when the run started.
crash_log_header :: proc() -> string {
	stamp := ""
	if lt, ok := platform_local_time(time.now()); ok {
		stamp = fmt.tprintf(", started %04d-%02d-%02d %02d:%02d:%02d", lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second)
	}
	return fmt.tprintf("Sculpt %s, %s build, %s %v%s", SCULPT_VERSION, "debug" when ODIN_DEBUG else "release", crash_log_platform(), ODIN_ARCH, stamp)
}

// A line the crash handlers build without the heap or a context: they may run in the middle
// of a malloc, on a thread whose stack is nearly gone. Text past its size is dropped.
Crash_Line :: struct {
	buf: [1024]u8,
	n:   int,
}

crash_line_add :: proc "contextless" (l: ^Crash_Line, s: string) {
	n := min(len(s), len(l.buf) - l.n)
	for i in 0 ..< n do l.buf[l.n + i] = s[i]
	l.n += n
}

crash_line_hex :: proc "contextless" (l: ^Crash_Line, v: uintptr) {
	HEX := "0123456789abcdef"
	digits: [2 + 2 * size_of(uintptr)]u8
	n := len(digits)
	v := v
	for {
		n -= 1
		digits[n] = HEX[v & 15]
		v >>= 4
		if v == 0 do break
	}
	n -= 2
	digits[n], digits[n + 1] = '0', 'x'
	crash_line_add(l, string(digits[n:]))
}

crash_line_dec :: proc "contextless" (l: ^Crash_Line, v: int) {
	digits: [24]u8
	n := len(digits)
	u := uint(abs(v))
	for {
		n -= 1
		digits[n] = u8('0' + u % 10)
		u /= 10
		if u == 0 do break
	}
	if v < 0 {
		n -= 1
		digits[n] = '-'
	}
	crash_line_add(l, string(digits[n:]))
}

crash_line_write :: proc "contextless" (l: ^Crash_Line) {
	// A line cut short still ends its line.
	if l.n == len(l.buf) do l.buf[l.n - 1] = '\n'
	crash_raw_write(l.buf[:l.n])
	l.n = 0
}

// One stack frame's line: its number, its address, and the module it is in with the offset
// into it, which the build's symbols turn into a procedure and line.
crash_line_frame :: proc "contextless" (l: ^Crash_Line, index: int, address: uintptr, module: string, base: uintptr, symbol: string) {
	crash_line_add(l, CRASH_TAG)
	crash_line_add(l, "  #")
	crash_line_dec(l, index)
	crash_line_add(l, " ")
	crash_line_hex(l, address)
	if module != "" {
		crash_line_add(l, " ")
		crash_line_add(l, module)
		crash_line_add(l, "+")
		crash_line_hex(l, address - base)
	}
	if symbol != "" {
		crash_line_add(l, " ")
		crash_line_add(l, symbol)
	}
	crash_line_add(l, "\n")
	crash_line_write(l)
}

// The last part of a path, for a module's name.
crash_base_name :: proc "contextless" (path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 do if path[i] == '/' || path[i] == '\\' do return path[i + 1:]
	return path
}

// Whether this thread is the first to crash: the others leave the log to it.
crash_take_turn :: proc "contextless" () -> bool {
	_, ok := sync.atomic_compare_exchange_strong(&crash_log.crashing, 0, 1)
	return ok
}

// The test crashes of --crash-test, which prove the handlers write the log.
crash_test :: proc(kind: string) {
	switch kind {
	case "":
	case "panic":
		panic("the crash test asked for it")
	case "segv":
		crash_test_fault()
	case "thread":
		crash_test_thread()
	case:
		log.warnf("--crash-test=%s: not a crash test (panic, segv or thread)", kind)
	}
}

// A write through a null pointer, which the optimiser may not drop.
crash_test_fault :: proc "contextless" () {
	intrinsics.volatile_store((^int)(nil), 1)
}

// The same on a thread of its own, as a crash in a job would be.
crash_test_thread :: proc() {
	t := thread.create_and_start(proc() {crash_test_fault()})
	thread.join(t)
	thread.destroy(t)
}
