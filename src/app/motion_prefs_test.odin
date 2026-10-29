package main

import "core:os"
import "core:testing"

import "../ui"

// The motion level and the kinds turned off are remembered; a file from before the levels
// with Reduce motion on opens with motion Off.
@(test)
motion_settings_are_remembered :: proc(t: ^testing.T) {
	path := "build/motion_prefs_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	a.kit.ctx.motion = .Reduced
	a.kit.ctx.motion_off = {int(Motion_Kind.Tooltips), int(Motion_Kind.Pages)}
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	testing.expect_value(t, b.kit.ctx.motion, a.kit.ctx.motion)
	testing.expect_value(t, b.kit.ctx.motion_off, a.kit.ctx.motion_off)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("version 7\nreduce_motion 1\nmotion_off Bogus Toasts\n")) == nil)
	c: App
	defer results_destroy(&c)
	settings_load(&c, path)
	testing.expect_value(t, c.kit.ctx.motion, ui.Motion_Level.Off)
	testing.expect_value(t, c.kit.ctx.motion_off, bit_set[0 ..< 32; u32]{int(Motion_Kind.Toasts)})
	free_all(context.temp_allocator)
}
