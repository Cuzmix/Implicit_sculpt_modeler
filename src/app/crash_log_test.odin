package main

import "core:testing"

@(test)
crash_log_summary_is_the_first_crash_line :: proc(t: ^testing.T) {
	log := "Sculpt dev, debug build, Linux amd64\n0.010 info: GPU: test\ncrash: panic: no at a.odin(3)\ncrash: SIGILL (a trap) on the main thread\ncrash:   #0 0x10 sculpt+0x10\ncrash: end\n"
	testing.expect_value(t, crash_log_summary(transmute([]u8)string(log)), "panic: no at a.odin(3)")
}

@(test)
crash_log_summary_is_empty_for_a_clean_or_killed_run :: proc(t: ^testing.T) {
	testing.expect_value(t, crash_log_summary(transmute([]u8)string("Sculpt dev\n0.010 info: a crash: in the middle is not one\nexit: clean\n")), "")
	// A run the system killed ends with no line at all, which is not a crash either.
	testing.expect_value(t, crash_log_summary(transmute([]u8)string("Sculpt dev\n0.010 info: started")), "")
	testing.expect_value(t, crash_log_summary(nil), "")
}

@(test)
crash_log_names_sit_beside_the_log :: proc(t: ^testing.T) {
	previous, crash := crash_log_names("/a/b/sculpt-log.txt", context.temp_allocator)
	testing.expect_value(t, previous, "/a/b/sculpt-log-previous.txt")
	testing.expect_value(t, crash, "/a/b/sculpt-log-crash.txt")
}

@(test)
crash_line_writes_numbers_without_the_heap :: proc(t: ^testing.T) {
	l: Crash_Line
	crash_line_add(&l, "x ")
	crash_line_hex(&l, 0xdead01)
	crash_line_add(&l, " ")
	crash_line_hex(&l, 0)
	crash_line_add(&l, " ")
	crash_line_dec(&l, -1205)
	crash_line_add(&l, " ")
	crash_line_dec(&l, 0)
	testing.expect_value(t, string(l.buf[:l.n]), "x 0xdead01 0x0 -1205 0")
	testing.expect_value(t, crash_base_name("C:\\a\\sculpt.exe"), "sculpt.exe")
	testing.expect_value(t, crash_base_name("/data/app/libmain.so"), "libmain.so")
}

@(test)
crash_line_cut_short_still_ends_its_line :: proc(t: ^testing.T) {
	l: Crash_Line
	for _ in 0 ..< 40 do crash_line_add(&l, "0123456789abcdef0123456789abcdef")
	testing.expect_value(t, l.n, len(l.buf))
	// With no log open nothing is written, but the line is ended and emptied all the same.
	crash_line_write(&l)
	testing.expect_value(t, l.buf[len(l.buf) - 1], u8('\n'))
	testing.expect_value(t, l.n, 0)
}
