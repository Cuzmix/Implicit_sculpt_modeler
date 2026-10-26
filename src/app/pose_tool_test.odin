package main

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

// A selected sphere at the world's middle, masked below y = 0, half masked up to
// y = 0.2 and free above, with the Move tool on and no GPU buffers.
@(private = "file")
pose_object :: proc(app: ^App, id: int) -> ^Object {
	obj := new(Object)
	obj.id = id
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	app.camera = camera.orbit_default()
	app.tool = .Move
	s := object_sculptor(obj)
	values := make([]u8, len(s.mesh.positions), context.temp_allocator)
	for p, v in s.mesh.positions do values[v] = 255 if p.y < 0 else (128 if p.y < 0.2 else 0)
	assert(sculpt.sculptor_mask_values(s, values, .Replace))
	history_record(app, obj, .Mask, "Mask")
	return obj
}

@(private = "file")
pose_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.scene.also)
	delete(app.move.members)
	delete(app.move.edit_members)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
POSE_SIZE :: [2]f32{1000, 800}

// A press, a move halfway, the move the rest of the way, and no release.
@(private = "file")
pose_drag_hold :: proc(app: ^App, from, to: [2]f32) {
	app.drag.moving = true
	move_tool_frame(app, {size = POSE_SIZE, mouse_pos = from, hovered = true, primary = true, press = true})
	move_tool_frame(app, {size = POSE_SIZE, mouse_pos = from + (to - from) * 0.5, hovered = true, primary = true})
	move_tool_frame(app, {size = POSE_SIZE, mouse_pos = to, hovered = true, primary = true})
}

@(private = "file")
pose_release :: proc(app: ^App, at: [2]f32) {
	move_tool_frame(app, {size = POSE_SIZE, mouse_pos = at, hovered = true})
}

// The z ring's rightmost point on screen.
@(private = "file")
ring_z_right :: proc(app: ^App) -> [2]f32 {
	sc := gizmo_screen(app, POSE_SIZE)
	right := sc.rings[2][0]
	for q in sc.rings[2] do if q.x > right.x do right = q
	return right
}

// With a mask leaving part of the object free, the gizmo sits on the mask's soft edge, its
// group reads "Pose", and a ring drag turns the free part, not the object, as one undo
// step that undo takes back exactly.
@(test)
pose_ring_drag_turns_the_free_part :: proc(t: ^testing.T) {
	app: App
	defer pose_scene_free(&app)
	obj := pose_object(&app, 1)
	s := object_sculptor(obj)
	testing.expect(t, pose_mode(&app))
	testing.expect_value(t, action_caption(&app, .Gizmo), "Pose")
	pose_release(&app, {})
	testing.expect(t, gizmo_pivot_set(&app))
	c := gizmo_center(&app, obj)
	testing.expectf(t, c.y >= 0 && c.y < 0.2, "pivot %v", c)

	before := slice.clone(s.mesh.positions[:], context.temp_allocator)
	app.move.mode = .Turn
	right := ring_z_right(&app)
	testing.expect_value(t, gizmo_pick(&app, right, POSE_SIZE), gizmo.Handle.Turn_Z)
	pose_drag_hold(&app, right, right + {-20, -60})
	testing.expect(t, sculpt.sculptor_posing(s))
	testing.expect(t, len(move_readout(&app)) > 6 && move_readout(&app)[:6] == "Pose: ")
	pose_release(&app, right + {-20, -60})
	testing.expect_value(t, obj.transform, Transform{scale = 1})
	testing.expect(t, !sculpt.sculptor_posing(s))
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, app.history.done[1].kind, History_Kind.Deform)
	testing.expect_value(t, app.history.done[1].what, "Pose: Turn")
	testing.expect_value(t, app.move.pose_drags, 1)
	testing.expect(t, app.move.pose_moved > 0)
	still, turned := 0, 0
	for a, v in before {
		if s.mask[v] == 255 do still += int(s.mesh.positions[v] == a)
		if s.mask[v] == 0 do turned += int(linalg.length(s.mesh.positions[v] - a) > 1e-4)
	}
	testing.expect(t, still > 0 && turned > 0)
	for a, v in before do if s.mask[v] == 255 do testing.expect(t, s.mesh.positions[v] == a)
	history_undo(&app)
	testing.expect(t, slice.equal(s.mesh.positions[:], before))
}

// A cancel mid-drag (Escape, or a second finger) puts the mesh and the pivot back with no
// step; a command run mid-drag (stroke_finish) ends the pose as its own step first.
@(test)
pose_cancel_and_finish_mid_drag :: proc(t: ^testing.T) {
	app: App
	defer pose_scene_free(&app)
	obj := pose_object(&app, 1)
	s := object_sculptor(obj)
	pose_release(&app, {})
	pivot := app.move.pivot
	before := slice.clone(s.mesh.positions[:], context.temp_allocator)
	sc := gizmo_screen(&app, POSE_SIZE)
	x_mid := (sc.center + sc.tips[0]) * 0.5
	testing.expect_value(t, gizmo_pick(&app, x_mid, POSE_SIZE), gizmo.Handle.X)
	pose_drag_hold(&app, x_mid, x_mid + {80, 0})
	testing.expect(t, !slice.equal(s.mesh.positions[:], before))
	// The gizmo rides with the part a move carries.
	testing.expect(t, app.move.pivot.at.x > pivot.at.x)
	move_cancel(&app)
	testing.expect(t, slice.equal(s.mesh.positions[:], before))
	testing.expect_value(t, app.move.pivot, pivot)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, !sculpt.sculptor_posing(s))

	pose_drag_hold(&app, x_mid, x_mid + {80, 0})
	stroke_finish(&app)
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, app.history.done[1].what, "Pose: Move")
	posed := slice.clone(s.mesh.positions[:], context.temp_allocator)
	// The rest of the press does nothing more.
	move_tool_frame(&app, {size = POSE_SIZE, mouse_pos = x_mid + {160, 0}, hovered = true, primary = true})
	pose_release(&app, x_mid + {160, 0})
	testing.expect(t, slice.equal(s.mesh.positions[:], posed))
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, obj.transform, Transform{scale = 1})
}

// A typed value poses by an offset in pose mode; with a second object selected, or the
// mask taking everything, the gizmo moves objects again.
@(test)
pose_entry_and_when_the_gizmo_moves_objects :: proc(t: ^testing.T) {
	app: App
	defer pose_scene_free(&app)
	obj := pose_object(&app, 1)
	s := object_sculptor(obj)
	pose_release(&app, {})
	pivot := app.move.pivot.at
	before := slice.clone(s.mesh.positions[:], context.temp_allocator)
	testing.expect(t, gizmo_entry_apply(&app, obj, .X, "0.5"))
	testing.expect_value(t, obj.transform, Transform{scale = 1})
	for a, v in before {
		w := f32(255 - s.mask[v]) / 255
		testing.expect(t, linalg.length(s.mesh.positions[v] - (a + {0.5 * w, 0, 0})) < 1e-5)
	}
	testing.expect(t, abs(app.move.pivot.at.x - (pivot.x + 0.5)) < 1e-5)
	testing.expect_value(t, app.history.done[len(app.history.done) - 1].what, "Pose: Move")

	// A second object selected: the gizmo moves the selection.
	append(&app.scene.also, 2)
	app.scene.also_for = obj.id
	testing.expect(t, !pose_mode(&app))
	clear(&app.scene.also)
	testing.expect(t, pose_mode(&app))
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	history_record(&app, obj, .Mask, "Mask all")
	testing.expect(t, !pose_mode(&app))
	testing.expect_value(t, action_caption(&app, .Gizmo), "Gizmo")
	testing.expect(t, gizmo_entry_apply(&app, obj, .X, "0.25"))
	testing.expect_value(t, obj.transform.position, Vec3{0.25, 0, 0})
}

// A click on a handle that holds still leaves no step; undoing a move puts the gizmo back
// on the mask's edge with the mesh, and a pivot placed by hand stays through a pose.
@(test)
pose_click_leaves_nothing_and_the_pivot_follows_undo :: proc(t: ^testing.T) {
	app: App
	defer pose_scene_free(&app)
	obj := pose_object(&app, 1)
	s := object_sculptor(obj)
	pose_release(&app, {})
	edge := app.move.pivot
	sc := gizmo_screen(&app, POSE_SIZE)
	x_mid := (sc.center + sc.tips[0]) * 0.5
	app.drag.moving = true
	move_tool_frame(&app, {size = POSE_SIZE, mouse_pos = x_mid, hovered = true, primary = true, press = true})
	move_tool_frame(&app, {size = POSE_SIZE, mouse_pos = x_mid, hovered = true, primary = true})
	move_tool_frame(&app, {size = POSE_SIZE, mouse_pos = x_mid, hovered = true, primary = true})
	pose_release(&app, x_mid)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.move.pose_drags, 0)
	testing.expect(t, !sculpt.sculptor_posing(s))
	testing.expect(t, app.kit.gizmo_entry.open)
	app.kit.gizmo_entry = {}

	pose_drag_hold(&app, x_mid, x_mid + {80, 0})
	pose_release(&app, x_mid + {80, 0})
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect(t, app.move.pivot.at.x > edge.at.x)
	history_undo(&app)
	pose_release(&app, {})
	testing.expect(t, linalg.length(app.move.pivot.at - edge.at) < 1e-5)

	hand := Gizmo_Pivot{set = true, id = obj.id, at = {0, 0.5, 0.5}}
	app.move.pivot = hand
	pose_release(&app, {})
	testing.expect(t, gizmo_entry_apply(&app, obj, .Turn_Y, "30"))
	pose_release(&app, {})
	testing.expect_value(t, app.move.pivot, hand)
}
