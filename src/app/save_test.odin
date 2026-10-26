package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

// A durable write replaces the file whole and leaves nothing beside it; a write that
// cannot happen leaves the old file as it was.
@(test)
write_durably_replaces_whole :: proc(t: ^testing.T) {
	folder := "build/save_test_write/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	path := strings.concatenate({folder, "a.sculpt"}, context.temp_allocator)
	testing.expect_value(t, write_durably(path, transmute([]u8)string("first")), "")
	testing.expect_value(t, write_durably(path, transmute([]u8)string("second, longer")), "")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), "second, longer")
	testing.expect(t, !os.exists(strings.concatenate({path, ".partial"}, context.temp_allocator)), "the partial file stayed")

	missing := strings.concatenate({folder, "no such folder/b.sculpt"}, context.temp_allocator)
	testing.expect(t, write_durably(missing, transmute([]u8)string("x")) != "", "a write into a missing folder said it worked")
}

// A save big enough to show "Saving..." first waits for its toast to come in, then
// saves; anything about to change the scene, or the app closing, runs it at once.
@(test)
a_big_save_waits_for_its_toast :: proc(t: ^testing.T) {
	folder := "build/save_test_pending/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	path := strings.concatenate({folder, "big.sculpt"}, context.temp_allocator)

	app: App
	defer results_destroy(&app)
	defer delete(app.scene_path)
	app.kit.ctx.theme.toast_time = 0.25
	app.saving = {.Save, strings.clone(path, runtime.heap_allocator())}
	app.saving_at = 10
	testing.expect(t, !autosave_quiet(&app), "a waiting save counts as rest")

	app.kit.ctx.time = 10.1
	save_pending(&app, false)
	testing.expect(t, app.saving.kind == .Save && !os.exists(path), "saved before the toast was up")
	app.kit.ctx.time = 10.4
	save_pending(&app, false)
	testing.expect(t, app.saving.kind == .None && os.exists(path), "did not save once the toast was up")
	testing.expect_value(t, app.scene_path, path)

	_ = os.remove(path)
	app.saving = {.Save, strings.clone(path, runtime.heap_allocator())}
	app.saving_at = app.kit.ctx.time
	save_pending(&app, true)
	testing.expect(t, app.saving.kind == .None && os.exists(path), "did not save when told to at once")
}
