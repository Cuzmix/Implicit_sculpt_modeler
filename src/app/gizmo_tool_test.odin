package main

import "core:math"
import "core:testing"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

// A selected object at the world's middle with no GPU buffers, for tests of the gizmo
// and of transform undo; gizmo_scene_free undoes it.
@(private = "file")
gizmo_object :: proc(app: ^App, id: int) -> ^Object {
	obj := new(Object)
	obj.id = id
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	return obj
}

@(private = "file")
gizmo_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
}

// A transform step undoes and redoes the exact transform, in its place among strokes:
// undo walks back through both, redo forward, and neither disturbs the other.
@(test)
transform_steps_interleave_with_strokes :: proc(t: ^testing.T) {
	app: App
	defer gizmo_scene_free(&app)
	obj := gizmo_object(&app, 1)
	s := object_sculptor(obj)
	start := obj.transform
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	history_record(&app, obj, .Mask, "Mask all")
	moved := Transform{position = {0.5, -1, 2}, scale = 1.5, rotation = {10, -20, 30}}
	obj.transform = moved
	edits := app.history.edits
	history_record_transform(&app, obj, start, "Move")
	testing.expect_value(t, app.history.edits, edits + 1)
	testing.expect_value(t, history_next_label(app.history.done[:]), "Move")
	// Placing it where it already is records nothing.
	history_record_transform(&app, obj, moved, "Move")
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect(t, sculpt.sculptor_mask_command(s, .Clear))
	history_record(&app, obj, .Mask, "Clear mask")

	history_undo(&app) // the clear
	testing.expect(t, sculpt.sculptor_has_mask(s))
	testing.expect_value(t, obj.transform, moved)
	history_undo(&app) // the move
	testing.expect_value(t, obj.transform, start)
	testing.expect(t, sculpt.sculptor_has_mask(s))
	history_undo(&app) // the fill
	testing.expect(t, !sculpt.sculptor_has_mask(s))
	testing.expect_value(t, obj.transform, start)
	history_redo(&app)
	history_redo(&app)
	testing.expect_value(t, obj.transform, moved)
	testing.expect(t, sculpt.sculptor_has_mask(s))
	history_redo(&app)
	testing.expect(t, !sculpt.sculptor_has_mask(s))
	testing.expect_value(t, obj.transform, moved)

	// Forgetting the object's strokes, or one level's, keeps where it was placed.
	history_forget_strokes(&app, obj.id)
	history_forget_level(&app, obj.id, 0)
	testing.expect_value(t, len(app.history.done), 1)
	history_undo(&app)
	testing.expect_value(t, obj.transform, start)
	// A new step drops the transform waiting to be redone.
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	history_record(&app, obj, .Mask, "Mask all")
	testing.expect_value(t, len(app.history.undone), 0)
	// Forgetting every level drops it with the rest.
	obj.transform = moved
	history_record_transform(&app, obj, start, "Move")
	history_forget(&app, obj.id)
	testing.expect_value(t, len(app.history.done), 0)
}

// Undo waits while a gizmo drag or a drag of the inspector's values is under way, and
// the inspector's drag is one step however many frames it changed the values in.
@(test)
transform_drags_are_one_step :: proc(t: ^testing.T) {
	app: App
	defer gizmo_scene_free(&app)
	obj := gizmo_object(&app, 1)
	start := obj.transform
	app.device.down = {.Left}
	for i in 1 ..= 3 {
		before := obj.transform
		obj.transform.position.x = f32(i) * 0.1
		transform_drag_changed(&app, obj, before)
		transform_drag_end(&app)
	}
	testing.expect_value(t, len(app.history.done), 0)
	append(&app.history.done, History_Entry{id = obj.id, kind = .Transform, before = start, after = start})
	testing.expect(t, !history_can_undo(&app))
	pop(&app.history.done)
	app.device.down = {}
	transform_drag_end(&app)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.history.done[0].before, start)
	testing.expect(t, abs(app.history.done[0].after.position.x - 0.3) < 1e-6)
	app.move.drag = {handle = .X, id = obj.id, start = obj.transform}
	testing.expect(t, !history_can_undo(&app))
	move_cancel(&app)
	testing.expect(t, history_can_undo(&app))
	history_undo(&app)
	testing.expect_value(t, obj.transform, start)
}

// W with the Move tool on steps the gizmo through its modes; the toolbar's button, which
// runs the same command, only picks the tool. Reset puts the object back as one step.
@(test)
move_key_steps_the_gizmo :: proc(t: ^testing.T) {
	app: App
	defer gizmo_scene_free(&app)
	obj := gizmo_object(&app, 1)
	app.tool = .Brush
	press :: proc(app: ^App) {
		clear(&app.device.keys)
		append(&app.device.keys, Key_Press{key = sdl.K_W})
		commands_handle_keys(app)
		clear(&app.device.keys)
	}
	press(&app)
	testing.expect_value(t, app.tool, Tool.Move)
	testing.expect_value(t, app.move.mode, gizmo.Mode.Move)
	press(&app)
	testing.expect_value(t, app.move.mode, gizmo.Mode.Turn)
	press(&app)
	testing.expect_value(t, app.move.mode, gizmo.Mode.Scale)
	testing.expect(t, command_run(&app, .Tool_Move))
	testing.expect_value(t, app.move.mode, gizmo.Mode.Scale)
	press(&app)
	testing.expect_value(t, app.move.mode, gizmo.Mode.Move)
	testing.expect(t, command_run(&app, .Gizmo, int(gizmo.Mode.Turn)))
	testing.expect(t, command_checked(&app, .Gizmo, int(gizmo.Mode.Turn)))

	obj.transform = {position = {1, 2, 3}, scale = 2, rotation = {0, 45, 0}}
	testing.expect(t, command_run(&app, .Reset_Transform))
	testing.expect_value(t, obj.transform, Transform{scale = 1})
	history_undo(&app)
	testing.expect_value(t, obj.transform.position, Vec3{1, 2, 3})
}

// Gizmo drags with the mouse: an arm moves along its axis only and snaps to the grid's
// steps; a ring turns about its axis only, 15 degrees at a time when snapping; the middle
// scales. Each release is one undo step.
@(test)
gizmo_drags_move_turn_and_scale :: proc(t: ^testing.T) {
	app: App
	defer gizmo_scene_free(&app)
	obj := gizmo_object(&app, 1)
	app.camera = camera.orbit_default()
	app.tool = .Move
	app.drag.moving = true
	size := [2]f32{1000, 800}
	drag :: proc(app: ^App, from, to, size: [2]f32) {
		move_tool_frame(app, {size = size, mouse_pos = from, hovered = true, primary = true, press = true})
		move_tool_frame(app, {size = size, mouse_pos = from + (to - from) * 0.5, hovered = true, primary = true})
		move_tool_frame(app, {size = size, mouse_pos = to, hovered = true, primary = true})
		move_tool_frame(app, {size = size, mouse_pos = to, hovered = true})
	}
	sc := gizmo_screen(&app, size)
	testing.expect(t, sc.ok)
	x_mid := (sc.center + sc.tips[0]) * 0.5
	testing.expect_value(t, gizmo_pick(&app, x_mid, size), gizmo.Handle.X)

	app.move.snap = true
	drag(&app, x_mid, x_mid + {37, 3}, size)
	p := obj.transform.position
	testing.expect(t, p.x > 0 && p.y == 0 && p.z == 0)
	step := gizmo.grid_step(camera.orbit_world_per_px(app.camera, {}, size.y))
	testing.expectf(t, abs(p.x / step - math.round(p.x / step)) < 1e-3, "%v is no multiple of %v", p.x, step)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.move.last, gizmo.Handle.X)

	app.move.mode = .Turn
	sc = gizmo_screen(&app, size)
	// The z ring faces the default camera: its rightmost point, dragged up, turns it about
	// z by a snapped amount.
	right := sc.rings[2][0]
	for q in sc.rings[2] do if q.x > right.x do right = q
	testing.expect_value(t, gizmo_pick(&app, right, size), gizmo.Handle.Turn_Z)
	drag(&app, right, right + {-20, -60}, size)
	r := obj.transform.rotation
	testing.expectf(t, r.x == 0 && r.y == 0 && r.z != 0, "turned %v", r)
	testing.expectf(t, abs(r.z / 15 - math.round(r.z / 15)) < 1e-3, "%v is no multiple of 15", r.z)
	testing.expect_value(t, len(app.history.done), 2)

	app.move.mode = .Scale
	app.move.snap = false
	sc = gizmo_screen(&app, size)
	drag(&app, sc.center + {4, 0}, sc.center + {4 + sc.arm_px, 0}, size)
	testing.expect(t, abs(obj.transform.scale - math.E) < 1e-3)
	testing.expect_value(t, len(app.history.done), 3)
	history_undo(&app)
	history_undo(&app)
	history_undo(&app)
	testing.expect_value(t, obj.transform, Transform{scale = 1})
}
