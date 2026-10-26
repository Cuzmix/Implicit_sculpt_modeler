package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Rest is no input and nothing under way; each thing that can change the scene without
// a press in that frame breaks it.
@(test)
autosave_rest_needs_every_source_still :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, autosave_quiet(&app), "a still app is not at rest")
	busy := [?]proc(app: ^App) {
		proc(app: ^App) {append(&app.device.keys, Key_Press{key = 'a'})},
		proc(app: ^App) {app.device.down = {.Left}},
		proc(app: ^App) {app.device.released = {.Left}},
		proc(app: ^App) {app.device.wheel = 1},
		proc(app: ^App) {app.device.text_len = 1},
		proc(app: ^App) {app.device.cancel = true},
		proc(app: ^App) {app.touch.fingers.count = 1},
		proc(app: ^App) {app.ui.pie.space_down = true},
		proc(app: ^App) {app.stroke.active = true},
		proc(app: ^App) {app.drag.owner = .Orbit},
		proc(app: ^App) {app.dab_wait.active = true},
		proc(app: ^App) {app.timeline.playing = true},
		proc(app: ^App) {app.autosave.scripted = true},
		proc(app: ^App) {app.ui.scene_command.kind = .Remesh},
		proc(app: ^App) {app.saving.kind = .Save},
	}
	for make_busy, i in busy {
		app = {}
		make_busy(&app)
		testing.expectf(t, !autosave_quiet(&app), "busy case %d counts as rest", i)
	}
	app = {}
	app.device.moved = {4, 2} // hovering
	testing.expect(t, autosave_quiet(&app), "hovering is not rest")
}

// Every change a scene file stores moves the fingerprint; a new view does not.
@(test)
autosave_fingerprint_follows_the_scene :: proc(t: ^testing.T) {
	app: App
	defer delete(app.scene.objects)
	obj := Object{id = 3, name = "Sphere 3", transform = {scale = 1}}
	append(&app.scene.objects, &obj)
	changes := [?]proc(app: ^App) {
		proc(app: ^App) {app.history.edits += 1},
		proc(app: ^App) {app.scene_edits += 1},
		proc(app: ^App) {app.scene.objects[0].transform.position.x += 0.5},
		proc(app: ^App) {app.scene.objects[0].transform.rotation.y += 10},
		proc(app: ^App) {app.scene.objects[0].transform.scale *= 2},
		proc(app: ^App) {app.scene.objects[0].boolean = .Subtract},
		proc(app: ^App) {app.scene.objects[0].name = "Head"},
		proc(app: ^App) {app.scene.objects[0].levels.current = 1},
		proc(app: ^App) {app.scene.objects[0].levels.hd.steps = 2},
		proc(app: ^App) {app.scene.objects[0].id = 4},
	}
	for change, i in changes {
		before := scene_fingerprint(&app)
		change(&app)
		testing.expectf(t, scene_fingerprint(&app) != before, "change %d left the fingerprint", i)
	}
	before := scene_fingerprint(&app)
	app.camera.yaw += 1
	app.camera.distance *= 2
	app.history.serial += 1 // forgetting steps changes no saved byte
	testing.expect_value(t, scene_fingerprint(&app), before)
	pop(&app.scene.objects)
	testing.expect(t, scene_fingerprint(&app) != before, "deleting the object left the fingerprint")
}

// A session file reads back as written, skips lines it does not know and refuses a text
// that is not one.
@(test)
autosave_session_file_round_trip :: proc(t: ^testing.T) {
	info := Session_Info{pid = 42, started = 100, alive = 130, scene = "/work/my head.sculpt", saved = 120, newest = 2, at = 125, objects = 3, vertices = 1200000, closed = 0}
	text := session_text(info, context.temp_allocator)
	back, ok := session_parse(strings.concatenate({text, "future 7\n"}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, back, info)
	_, ok = session_parse("not a session\nnewest 1 2 3 4\n", context.temp_allocator)
	testing.expect(t, !ok)
	damaged, dok := session_parse("sculpt-session 1\nnewest 9 -5 x\nsaved -3\n", context.temp_allocator)
	testing.expect(t, dok)
	testing.expect_value(t, damaged.newest, 0)
	testing.expect_value(t, damaged.saved, 0)
	free_all(context.temp_allocator)
}

// The settings file may hold any number: it snaps to an interval Settings offers.
@(test)
autosave_minutes_snap :: proc(t: ^testing.T) {
	testing.expect_value(t, autosave_minutes(0), 0)
	testing.expect_value(t, autosave_minutes(3), 2)
	testing.expect_value(t, autosave_minutes(4), 5)
	testing.expect_value(t, autosave_minutes(99), 10)
	testing.expect_value(t, len(AUTOSAVE_MINUTES), len(AUTOSAVE_MINUTE_NAMES))
}

// At the start: a crash holding an autosave newer than its save is offered; one saved
// since is deleted; only the newest few clean exits stay; a copy still running and its
// files are left alone; half-written files go.
@(test)
autosave_start_sorts_the_sessions :: proc(t: ^testing.T) {
	folder := "build/autosave_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	now := unix_now()
	session :: proc(folder, name: string, info: Session_Info, slots: ..int) {
		_ = session_write(session_path(folder, name), info)
		for k in slots do _ = os.write_entire_file(slot_path(folder, name, k), transmute([]u8)string("scene"))
	}
	session(folder, "crashed", {started = now - 50, alive = now - 1000, newest = 2}, 1, 2)
	session(folder, "saved-since", {started = now - 50, alive = now - 1000, saved = now + 100, newest = 1}, 1)
	session(folder, "running", {pid = os.get_pid(), started = now, alive = now, newest = 1}, 1)
	for i in 0 ..< 5 do session(folder, fmt.tprintf("closed%d", i), {started = now - 50, closed = now - 100 + i64(i), newest = 1}, 1)
	_ = os.write_entire_file(strings.concatenate({folder, "x-1.sculpt.partial"}, context.temp_allocator), transmute([]u8)string("half"))

	app: App
	autosave_init(&app, false, 1, folder, 0, false, false)
	defer autosave_destroy(&app)
	testing.expect_value(t, len(app.autosave.offers), 1)
	if len(app.autosave.offers) == 1 do testing.expect_value(t, app.autosave.offers[0].session, "crashed")
	testing.expect(t, os.exists(slot_path(folder, "crashed", 2)))
	testing.expect(t, !os.exists(slot_path(folder, "saved-since", 1)), "a crash saved since was kept")
	testing.expect(t, os.exists(slot_path(folder, "running", 1)), "a running copy's autosave was touched")
	testing.expect(t, !os.exists(slot_path(folder, "closed0", 1)) && !os.exists(slot_path(folder, "closed1", 1)), "old clean exits were kept")
	testing.expect(t, os.exists(slot_path(folder, "closed4", 1)) && os.exists(slot_path(folder, "closed2", 1)), "a recent clean exit went")
	testing.expect(t, !os.exists(strings.concatenate({folder, "x-1.sculpt.partial"}, context.temp_allocator)))
	free_all(context.temp_allocator)
}
