package main

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

// A selected sphere at the world's middle with the Move tool on, Lattice picked with three
// points a side and the cage made; masked below y = 0 when asked. No GPU buffers.
@(private = "file")
lattice_scene :: proc(app: ^App, masked := false) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.camera = camera.orbit_default()
	app.tool = .Move
	if masked {
		s := object_sculptor(obj)
		values := make([]u8, len(s.mesh.positions), context.temp_allocator)
		for p, v in s.mesh.positions do values[v] = 255 if p.y < 0 else 0
		assert(sculpt.sculptor_mask_values(s, values, .Replace))
		history_record(app, obj, .Mask, "Mask")
	}
	app.ui.deform.lattice = {on = true, points = 3}
	lattice_frame(app)
	return obj
}

@(private = "file")
lattice_scene_free :: proc(app: ^App) {
	lattice_drop(app)
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
LATTICE_SIZE :: [2]f32{1000, 800}

// The middle point of the cage's +x face, from 1.
@(private = "file")
LATTICE_SIDE :: 2 + 1 * 3 + 1 * 9 + 1

@(private = "file")
lattice_on_screen :: proc(app: ^App, point: int) -> [2]f32 {
	at, ok, _ := lattice_screen(app, selected_object(app), LATTICE_SIZE)
	assert(ok[point - 1])
	return at[point - 1]
}

// A press, a move halfway, the rest of the way, and the release.
@(private = "file")
lattice_drag :: proc(app: ^App, from, to: [2]f32) {
	app.drag.moving = true
	move_tool_frame(app, {size = LATTICE_SIZE, mouse_pos = from, hovered = true, primary = true, press = true})
	move_tool_frame(app, {size = LATTICE_SIZE, mouse_pos = from + (to - from) * 0.5, hovered = true, primary = true})
	move_tool_frame(app, {size = LATTICE_SIZE, mouse_pos = to, hovered = true, primary = true})
	move_tool_frame(app, {size = LATTICE_SIZE, mouse_pos = to, hovered = true})
	app.drag.moving = false
	lattice_frame(app)
}

// Where each vertex goes when the point `point` (from 1) of a cage from `lo` to `hi`
// moves by `offset`, worked out here from the positions before.
@(private = "file")
lattice_expected :: proc(before: []Vec3, lo, hi: Vec3, point: int, offset: Vec3) -> []Vec3 {
	move := sculpt.Lattice_Move{points = 3, point = lattice_index(3, point - 1), offset = offset}
	out := make([]Vec3, len(before), context.temp_allocator)
	for p, v in before do out[v] = p + sculpt.lattice_weight(&move, (p - lo) / (hi - lo)) * offset
	return out
}

@(private = "file")
positions_near :: proc(a, b: []Vec3) -> bool {
	if len(a) != len(b) do return false
	for p, v in a do if linalg.length(p - b[v]) > 1e-5 do return false
	return true
}

// A drag of a cage point is one undo step named Lattice that moves each vertex by the
// point's weight at it, leaves the point where it was let go, and undo takes back exactly;
// the cage is then made again at rest.
@(test)
lattice_drag_is_one_step :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	l := &app.ui.deform.lattice
	testing.expect(t, l.made)
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	from := lattice_on_screen(&app, LATTICE_SIDE)
	testing.expect_value(t, lattice_pick(&app, from, LATTICE_SIZE), LATTICE_SIDE)
	lattice_drag(&app, from, from + {120, -40})
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.history.done[0].what, "Lattice")
	testing.expect_value(t, l.drags, 1)
	offset := l.offsets[LATTICE_SIDE - 1]
	testing.expect(t, linalg.length(offset) > 0.1)
	testing.expect(t, positions_near(object_mesh(obj).positions[:], lattice_expected(before, l.lo, l.hi, LATTICE_SIDE, offset)))
	// The point is drawn where the pointer let it go.
	testing.expect(t, linalg.length(lattice_on_screen(&app, LATTICE_SIDE) - (from + {120, -40})) < 1)
	history_undo(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], before))
	lattice_frame(&app)
	testing.expect_value(t, l.offsets[LATTICE_SIDE - 1], Vec3{})
	testing.expect(t, !sculpt.sculptor_lattice_ready(object_sculptor(obj)))
}

// A second drag picks the point where the first left it, and the two drags make what one
// drag by both moves makes: the cage weighs the vertices by where they were when it was
// made, not by where the first drag put them.
@(test)
lattice_drags_add_up :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	l := &app.ui.deform.lattice
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	lo, hi := l.lo, l.hi
	from := lattice_on_screen(&app, LATTICE_SIDE)
	lattice_drag(&app, from, from + {80, 0})
	mid := lattice_on_screen(&app, LATTICE_SIDE)
	testing.expect_value(t, lattice_pick(&app, mid, LATTICE_SIZE), LATTICE_SIDE)
	lattice_drag(&app, mid, mid + {0, -90})
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, l.drags, 2)
	testing.expect_value(t, l.lo, lo)
	testing.expect(t, positions_near(object_mesh(obj).positions[:], lattice_expected(before, lo, hi, LATTICE_SIDE, l.offsets[LATTICE_SIDE - 1])))
}

// What the mask covers stays where it is.
@(test)
lattice_keeps_the_mask :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app, masked = true)
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	// The cage stands round the free half only.
	testing.expect(t, app.ui.deform.lattice.lo.y > -0.2)
	from := lattice_on_screen(&app, LATTICE_SIDE)
	lattice_drag(&app, from, from + {100, 0})
	moved := 0
	for p, v in object_mesh(obj).positions {
		if before[v].y < 0 do testing.expect_value(t, p, before[v])
		if p != before[v] do moved += 1
	}
	testing.expect(t, moved > 0)
}

// The cage stands in for the gizmo with the Move tool; with another tool, or Lattice not
// picked, the gizmo is back and the cage's places are let go.
@(test)
lattice_stands_in_for_the_gizmo :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	center := gizmo_screen(&app, LATTICE_SIZE).center
	testing.expect_value(t, gizmo_pick(&app, center, LATTICE_SIZE), gizmo.Handle.None)
	from := lattice_on_screen(&app, LATTICE_SIDE)
	lattice_drag(&app, from, from + {60, 0})
	testing.expect(t, sculpt.sculptor_lattice_ready(object_sculptor(obj)))
	app.tool = .Brush
	testing.expect(t, lattice_object(&app) == nil)
	testing.expect_value(t, lattice_pick(&app, from + {60, 0}, LATTICE_SIZE), 0)
	app.tool = .Move
	app.ui.deform.lattice.on = false
	lattice_frame(&app)
	testing.expect(t, !app.ui.deform.lattice.made)
	testing.expect(t, !sculpt.sculptor_lattice_ready(object_sculptor(obj)))
	testing.expect(t, gizmo_pick(&app, center, LATTICE_SIZE) != gizmo.Handle.None)
}

// A cage dragged on one level and made again after the levels changed lets go of its
// places on every level, so the next cage, on whichever level, notes its own and pulls by
// them, not by places noted for another box.
@(test)
lattice_made_again_after_a_new_level :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	from := lattice_on_screen(&app, LATTICE_SIDE)
	lattice_drag(&app, from, from + {100, 0})
	testing.expect(t, sculpt.levels_subdivide(&obj.levels))
	history_record(&app, obj, .Deform, "Subdivide")
	lattice_frame(&app)
	testing.expect_value(t, app.ui.deform.lattice.level, 1)
	testing.expect(t, !sculpt.sculptor_lattice_ready(&obj.levels.levels[0].sculptor))
	sculpt.levels_set_current(&obj.levels, 0)
	history_record(&app, obj, .Deform, "Level")
	lattice_frame(&app)
	l := &app.ui.deform.lattice
	testing.expect_value(t, l.level, 0)
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	from = lattice_on_screen(&app, LATTICE_SIDE)
	lattice_drag(&app, from, from + {0, -100})
	testing.expect(t, positions_near(object_mesh(obj).positions[:], lattice_expected(before, l.lo, l.hi, LATTICE_SIDE, l.offsets[LATTICE_SIDE - 1])))
}

// Lattice turned off while a point is dragged (a key bound to another deformer) leaves the
// drag its places: it ends as its step, pulling as it did, and only then is the cage let go.
@(test)
lattice_off_mid_drag_ends_the_drag_first :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	l := &app.ui.deform.lattice
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	from := lattice_on_screen(&app, LATTICE_SIDE)
	to := from + {100, 0}
	app.drag.moving = true
	move_tool_frame(&app, {size = LATTICE_SIZE, mouse_pos = from, hovered = true, primary = true, press = true})
	move_tool_frame(&app, {size = LATTICE_SIZE, mouse_pos = from + {50, 0}, hovered = true, primary = true})
	move_tool_frame(&app, {size = LATTICE_SIZE, mouse_pos = to, hovered = true, primary = true})
	lo, hi := l.lo, l.hi
	l.on = false
	lattice_frame(&app)
	testing.expect(t, sculpt.sculptor_lattice_ready(object_sculptor(obj)))
	move_tool_frame(&app, {size = LATTICE_SIZE, mouse_pos = to, hovered = true})
	app.drag.moving = false
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, l.drags, 1)
	testing.expect(t, positions_near(object_mesh(obj).positions[:], lattice_expected(before, lo, hi, LATTICE_SIDE, l.offsets[LATTICE_SIDE - 1])))
	lattice_frame(&app)
	testing.expect(t, !l.made)
	testing.expect(t, !sculpt.sculptor_lattice_ready(object_sculptor(obj)))
}

// With another tool the cage waits while nothing changes and goes, places and all, once
// a step makes it stale.
@(test)
lattice_goes_when_stale_under_another_tool :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	from := lattice_on_screen(&app, LATTICE_SIDE)
	lattice_drag(&app, from, from + {60, 0})
	app.tool = .Brush
	lattice_frame(&app)
	testing.expect(t, app.ui.deform.lattice.made)
	testing.expect(t, sculpt.sculptor_lattice_ready(object_sculptor(obj)))
	s := object_sculptor(obj)
	values := make([]u8, len(s.mesh.positions), context.temp_allocator)
	for p, v in s.mesh.positions do values[v] = 255 if p.y < -0.5 else 0
	testing.expect(t, sculpt.sculptor_mask_values(s, values, .Replace))
	history_record(&app, obj, .Mask, "Mask")
	lattice_frame(&app)
	testing.expect(t, !app.ui.deform.lattice.made)
	testing.expect(t, !sculpt.sculptor_lattice_ready(s))
}

// With nothing free to put a cage round, the gizmo is drawn and takes presses again.
@(test)
lattice_with_nothing_free_gives_the_gizmo_back :: proc(t: ^testing.T) {
	app: App
	defer lattice_scene_free(&app)
	obj := lattice_scene(&app)
	s := object_sculptor(obj)
	values := make([]u8, len(s.mesh.positions), context.temp_allocator)
	slice.fill(values, 255)
	testing.expect(t, sculpt.sculptor_mask_values(s, values, .Replace))
	history_record(&app, obj, .Mask, "Mask")
	lattice_frame(&app)
	testing.expect(t, !app.ui.deform.lattice.made)
	testing.expect(t, lattice_shown(&app) == nil)
	testing.expect(t, gizmo_pick(&app, gizmo_screen(&app, LATTICE_SIZE).center, LATTICE_SIZE) != gizmo.Handle.None)
}
