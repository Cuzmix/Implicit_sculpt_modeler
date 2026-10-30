package main

import "core:testing"

import "../geom"
import "../sculpt"

@(private = "file")
flash_object :: proc(app: ^App, id: int, at: Vec3) -> ^Object {
	obj := new(Object)
	obj.id = id
	obj.transform = {position = at, scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	return obj
}

@(private = "file")
flash_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
}

// A flash runs its time on the interface's clock and ends itself; with its kind turned
// off, or motion off, it never shows.
@(test)
flash_runs_its_time_and_follows_the_motion_settings :: proc(t: ^testing.T) {
	app: App
	flash_saved(&app)
	_, ok := flash_progress(&app, &app.flashes.saved, .Save_Tick, SAVE_TICK_TIME)
	testing.expect(t, ok, "a save tick did not show as it began")
	app.kit.ctx.time += SAVE_TICK_TIME / 2
	half, _ := flash_progress(&app, &app.flashes.saved, .Save_Tick, SAVE_TICK_TIME)
	testing.expectf(t, abs(half - 0.5) < 1e-4, "halfway it is %v along", half)
	app.kit.ctx.time += SAVE_TICK_TIME
	_, ok = flash_progress(&app, &app.flashes.saved, .Save_Tick, SAVE_TICK_TIME)
	testing.expect(t, !ok && !app.flashes.saved.on, "a save tick outlived its time")

	app.kit.ctx.motion_off += {int(Motion_Kind.Save_Tick)}
	flash_saved(&app)
	_, ok = flash_progress(&app, &app.flashes.saved, .Save_Tick, SAVE_TICK_TIME)
	testing.expect(t, !ok, "a save tick showed with its kind off")
	app.kit.ctx.motion_off = {}
	app.kit.ctx.motion = .Off
	flash_saved(&app)
	_, ok = flash_progress(&app, &app.flashes.saved, .Save_Tick, SAVE_TICK_TIME)
	testing.expect(t, !ok, "a save tick showed with motion off")
	testing.expect_value(t, app.flashes.saves, 1)
}

// A new selection outlines itself, but what the first frame or an opened scene selects
// does not; nothing selected outlines nothing.
@(test)
selection_outline_flashes_only_a_change :: proc(t: ^testing.T) {
	app: App
	defer flash_scene_free(&app)
	_ = flash_object(&app, 1, {-2, 0, 0})
	_ = flash_object(&app, 2, {2, 0, 0})
	app.scene.selected = 0
	flash_selection_frame(&app)
	testing.expect(t, !app.flashes.selection.on, "the first frame's selection flashed")
	app.scene.selected = 1
	flash_selection_frame(&app)
	testing.expect(t, app.flashes.selection.on && app.flashes.selection.id == 2, "a new selection did not outline itself")
	// Its box is the second object's, to the right of the middle.
	testing.expectf(t, app.flashes.selection.box.lo.x > 0.5, "the outline's box is %v", app.flashes.selection.box)
	app.flashes.selection.on = false
	flash_selection_frame(&app)
	testing.expect(t, !app.flashes.selection.on, "the same selection flashed again")
	flash_scene_opened(&app)
	app.scene.selected = 0
	flash_selection_frame(&app)
	testing.expect(t, !app.flashes.selection.on, "an opened scene's selection flashed")
	app.scene.selected = -1
	flash_selection_frame(&app)
	testing.expect(t, !app.flashes.selection.on, "nothing selected outlined something")
	testing.expect_value(t, app.flashes.selections, 1)
}

// An undo's flash takes the box the frame's upload changed, in the scene's space, and
// one whose change no upload saw falls back to the whole object after its frames.
@(test)
undo_flash_takes_what_changed :: proc(t: ^testing.T) {
	app: App
	defer flash_scene_free(&app)
	obj := flash_object(&app, 7, {3, 0, 0})
	flash_undo_begin(&app, 7)
	flash_damage(&app, obj, geom.AABB_EMPTY)
	flash_damage(&app, obj, {lo = {0, 0, 0}, hi = {0.1, 0.1, 0.1}})
	flash_frame_end(&app)
	f := app.flashes.undo
	testing.expect(t, f.on && app.flashes.undo_wait == 0, "the undo flash did not start once it saw the change")
	testing.expectf(t, abs(f.box.lo.x - 3) < 1e-4 && abs(f.box.hi.x - 3.1) < 1e-4, "the flash's box is %v, not the change placed", f.box)

	flash_undo_begin(&app, 7)
	for _ in 0 ..< UNDO_FLASH_WAIT - 1 do flash_frame_end(&app)
	testing.expect(t, !app.flashes.undo.on, "the flash started before its frames ran out")
	flash_frame_end(&app)
	whole := app.flashes.undo.box
	testing.expectf(t, app.flashes.undo.on && whole.lo.x < 2.5 && whole.hi.x > 3.5, "the fallback box is %v, not the object", whole)
	testing.expect_value(t, app.flashes.undos, 2)
}
