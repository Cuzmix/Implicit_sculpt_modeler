package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

import "../geom"
import "../sculpt"

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

// Only "<stem> <stamp>.sculpt" and "<stem> <stamp>-N.sculpt" are versions.
@(test)
version_names_match_only_their_own :: proc(t: ^testing.T) {
	testing.expect(t, version_name_matches("head 2026-10-26 14.02.33.sculpt", "head"))
	testing.expect(t, version_name_matches("head 2026-10-26 14.02.33-12.sculpt", "head"))
	testing.expect(t, !version_name_matches("head 2026-10-26 14.02.33.sculpt.partial", "head"))
	testing.expect(t, !version_name_matches("headless 2026-10-26 14.02.33.sculpt", "head"))
	testing.expect(t, !version_name_matches("head 2026-10-26 14:02:33.sculpt", "head"))
	testing.expect(t, !version_name_matches("head 2026-10-26 14.02.33-.sculpt", "head"))
	testing.expect(t, !version_name_matches("head notes.sculpt", "head"))
	testing.expect_value(t, versions_kept(4), 3)
	testing.expect_value(t, versions_kept(99), 10)
}

// Each save over a file keeps the one it replaced, newest first and whole, up to the
// count; other files in the folder are never touched; a copy keeps none and leaves the
// scene's own file alone.
@(test)
saving_over_a_file_keeps_the_earlier_ones :: proc(t: ^testing.T) {
	folder := "build/save_test_versions/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	path := strings.concatenate({folder, "head.sculpt"}, context.temp_allocator)

	app: App
	defer results_destroy(&app)
	app.versions_kept = 3
	// The header stores next_id, so each save's bytes say which one it was.
	saved: [6][]u8
	for i in 0 ..< 6 {
		app.scene.next_id = 100 + i
		testing.expect(t, scene_save(&app, path))
		saved[i], _ = os.read_entire_file(path, context.temp_allocator)
		if i == 0 do testing.expect_value(t, len(versions_found(path)), 0)
		if i == 1 {
			// Something else in the folder stays.
			_ = os.write_entire_file(strings.concatenate({versions_folder(path), "/notes.txt"}, context.temp_allocator), transmute([]u8)string("mine"))
		}
	}
	found := versions_found(path)
	testing.expect_value(t, len(found), 3)
	// Newest first: the saves before the last one, in order.
	for p, i in found {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		testing.expectf(t, string(data) == string(saved[4 - i]), "version %d is not save %d", i, 4 - i)
	}
	testing.expect(t, os.exists(strings.concatenate({versions_folder(path), "/notes.txt"}, context.temp_allocator)))

	copy_path := strings.concatenate({folder, "copy.sculpt"}, context.temp_allocator)
	testing.expect(t, scene_save(&app, copy_path, copy = true))
	testing.expect(t, scene_save(&app, copy_path, copy = true))
	testing.expect_value(t, len(versions_found(copy_path)), 0)
	testing.expect(t, !os.exists(versions_folder(copy_path)))

	// Off keeps no more and deletes none.
	app.versions_kept = 0
	testing.expect(t, scene_save(&app, path))
	testing.expect_value(t, len(versions_found(path)), 3)
}

// A second save in the same second is numbered, and "-10" sorts after "-9".
@(test)
versions_in_one_second_keep_their_order :: proc(t: ^testing.T) {
	folder := "build/save_test_order/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	path := strings.concatenate({folder, "x.sculpt"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(versions_folder(path)) == nil)
	names := [?]string{"x 2026-01-01 10.00.00.sculpt", "x 2026-01-01 10.00.00-9.sculpt", "x 2026-01-01 10.00.00-10.sculpt", "x 2026-01-02 09.00.00.sculpt"}
	for n in names do _ = os.write_entire_file(strings.concatenate({versions_folder(path), "/", n}, context.temp_allocator), transmute([]u8)string(n))
	found := versions_found(path)
	want := [?]int{3, 2, 1, 0}
	testing.expect_value(t, len(found), 4)
	for p, i in found do testing.expectf(t, strings.has_suffix(p, names[want[i]]), "place %d holds %s", i, p)
}

// When the earlier save cannot be kept (here a file sits where the folder would go), the
// save still happens and says so.
@(test)
a_save_goes_ahead_when_the_earlier_one_cannot_be_kept :: proc(t: ^testing.T) {
	folder := "build/save_test_blocked/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	path := strings.concatenate({folder, "head.sculpt"}, context.temp_allocator)
	app: App
	defer results_destroy(&app)
	app.versions_kept = 5
	testing.expect(t, scene_save(&app, path))
	_ = os.write_entire_file(versions_folder(path), transmute([]u8)string("in the way"))
	app.scene.next_id = 7
	testing.expect(t, scene_save(&app, path))
	testing.expect(t, .Warning in app.result.flags, "the note did not warn")
	testing.expect(t, strings.contains(app.result.text, "not kept"), app.result.text)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, len(data) > 0 && !os.exists(strings.concatenate({path, ".partial"}, context.temp_allocator)))
}

// Earlier saves read as a person says them: today, yesterday, a date, with the year
// only when it is not this one, and the seconds only when asked for.
@(test)
earlier_saves_read_as_days :: proc(t: ^testing.T) {
	today, yesterday := "2026-10-26 15.00.00", "2026-10-25 15.00.00"
	testing.expect_value(t, version_when("2026-10-26 14.02.33", today, yesterday, false), "Today 14:02")
	testing.expect_value(t, version_when("2026-10-26 14.02.33", today, yesterday, true), "Today 14:02:33")
	testing.expect_value(t, version_when("2026-10-25 09.15.00", today, yesterday, false), "Yesterday 09:15")
	testing.expect_value(t, version_when("2026-10-12 09.15.00", today, yesterday, false), "12 Oct 09:15")
	testing.expect_value(t, version_when("2025-03-01 23.59.59", today, yesterday, false), "1 Mar 2025 23:59")
}

// A big export waits for its "Exporting..." toast as a big save does, then writes the
// object selected by then; a small one is written at once.
@(test)
a_big_export_waits_for_its_toast :: proc(t: ^testing.T) {
	folder := "build/save_test_export/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	// Not temporary: an export frees the temporary allocator, as the frame does.
	small := strings.concatenate({folder, "small.glb"})
	defer delete(small)
	big := strings.concatenate({folder, "big.glb"})
	defer delete(big)

	app: App
	defer results_destroy(&app)
	obj := new(Object)
	obj.id, obj.transform, obj.file = 1, {scale = 1}, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	defer {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
		delete(app.scene.objects)
		history_destroy(&app.history)
	}
	app.scene.selected = 0
	testing.expect(t, object_export_bytes(obj) < SAVE_SHOW_FIRST)
	testing.expect(t, file_apply(&app, {.Export, small}))
	testing.expectf(t, app.saving.kind == .None && os.exists(small), "a small export waited: %s", app.result.text)

	app.kit.ctx.theme.toast_time = 0.25
	app.saving = {.Export, strings.clone(big, runtime.heap_allocator())}
	app.saving_at = 10
	app.kit.ctx.time = 10.1
	save_pending(&app, false)
	testing.expect(t, app.saving.kind == .Export && !os.exists(big), "exported before the toast was up")
	app.kit.ctx.time = 10.4
	save_pending(&app, false)
	testing.expect(t, app.saving.kind == .None && os.exists(big), "did not export once the toast was up")
	a, _ := os.read_entire_file(small, context.allocator)
	defer delete(a)
	b, _ := os.read_entire_file(big, context.allocator)
	defer delete(b)
	testing.expect(t, len(a) > 0 && string(a) == string(b), "the waiting export wrote something else")
}
