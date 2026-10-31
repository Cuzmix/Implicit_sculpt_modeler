package main

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

@(private = "file")
EDIT_SIZE :: [2]f32{1000, 800}

// A selected sphere with no GPU buffers, Draw held, Hold to edit on.
@(private = "file")
edit_sphere :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(5), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.camera = camera.orbit_default()
	app.tool = .Brush
	app.brush.kind, app.brush.radius_px = .Draw, 40
	app.brush.strengths[.Draw] = 0.5
	app.brush.hold_edit, app.brush.hold_edit_s, app.brush.hold_edit_smoothness = true, HOLD_EDIT_DEFAULT_S, HOLD_EDIT_SMOOTHNESS_DEFAULT
	app.kit.fixed_dt = 1.0 / 60
	return obj
}

@(private = "file")
edit_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.stroke.pending)
	delete(app.stroke.path)
	stroke_edit_destroy(&app.stroke_edit)
	history_destroy(&app.history)
	results_destroy(app)
}

// One frame of the pointer at `p`, held or not, the clock a sixtieth of a second on.
@(private = "file")
edit_frame :: proc(app: ^App, p: [2]f32, held, press: bool) {
	app.kit.ctx.time += 1.0 / 60
	kind: Sample_Kind = .Press if press else (.Move if held else .Release)
	samples := []Input_Sample{{pos = p, pressure = 1, kind = kind}}
	_ = sculpt_frame(app, {size = EDIT_SIZE, mouse_pos = p, hovered = true, primary = held, press = press, samples = samples})
}

// A stroke along an arc over the sphere's front, then, with `hold`, the pen kept still for
// a second before letting go.
@(private = "file")
edit_stroke :: proc(app: ^App, hold: bool) {
	for i in 0 ..= 30 {
		x := 380 + f32(i) * 8
		y := 400 - 60 * linalg.sin(f32(i) / 30 * 3.14159)
		edit_frame(app, {x, y}, true, i == 0)
	}
	if hold do for _ in 0 ..< 60 do edit_frame(app, {620, 400}, true, false)
	edit_frame(app, {620, 400}, false, false)
}

@(private = "file")
moved_total :: proc(a, b: []Vec3) -> (sum: f32) {
	for p, i in a do sum += linalg.length(p - b[i])
	return
}

// A stroke held still at its end opens for editing and stays open after the pen lifts; its
// first lay, from the fitted curve, moves the surface about as much as the stroke drawn;
// Validate keeps it as one undo step.
@(test)
held_stroke_opens_and_validates :: proc(t: ^testing.T) {
	plain, held: App
	defer edit_scene_free(&plain)
	defer edit_scene_free(&held)
	a, b := edit_sphere(&plain), edit_sphere(&held)
	before := slice.clone(object_sculptor(a).mesh.positions[:], context.temp_allocator)
	edit_stroke(&plain, false)
	edit_stroke(&held, true)
	testing.expect(t, !plain.stroke_edit.open, "a stroke not held opened")
	testing.expect(t, held.stroke_edit.open, "the held stroke did not open")
	testing.expect(t, held.stroke.active, "the stroke ended on lift")
	testing.expectf(t, len(held.stroke_edit.points) >= 2 && len(held.stroke_edit.points) < 12, "%d points", len(held.stroke_edit.points))
	testing.expect_value(t, len(held.history.done), 0)
	drawn := moved_total(object_sculptor(a).mesh.positions[:], before)
	laid := moved_total(object_sculptor(b).mesh.positions[:], before)
	testing.expectf(t, laid > 0.7 * drawn && laid < 1.3 * drawn, "drawn moved %v, the curve %v", drawn, laid)
	stroke_edit_validate(&held)
	testing.expect(t, !held.stroke_edit.open && !held.stroke.active, "still open")
	testing.expect_value(t, len(held.history.done), 1)
}

// Cancel puts every vertex back bit for bit and records nothing; Undo does the same.
@(test)
held_stroke_cancels :: proc(t: ^testing.T) {
	cases := [2]bool{false, true}
	for by_undo in cases {
		app: App
		obj := edit_sphere(&app)
		before := slice.clone(object_sculptor(obj).mesh.positions[:], context.temp_allocator)
		edit_stroke(&app, true)
		testing.expect(t, app.stroke_edit.open, "not open")
		testing.expect(t, !slice.equal(before, object_sculptor(obj).mesh.positions[:]), "the stroke moved nothing")
		if by_undo do undo_run(&app)
		else do stroke_edit_cancel(&app)
		testing.expect(t, !app.stroke_edit.open && !app.stroke.active, "still open")
		testing.expect(t, slice.equal(before, object_sculptor(obj).mesh.positions[:]), "the surface did not come back")
		testing.expect_value(t, len(app.history.done), 0)
		edit_scene_free(&app)
	}
}

// Dragging a point lays the stroke again where it went; a tap turns it into a corner; a
// press away from the curve keeps the stroke and starts the next.
@(test)
held_stroke_follows_its_points :: proc(t: ^testing.T) {
	app: App
	defer edit_scene_free(&app)
	obj := edit_sphere(&app)
	edit_stroke(&app, true)
	e := &app.stroke_edit
	testing.expect(t, e.open, "not open")
	if !e.open do return
	view_proj := camera.orbit_proj(app.camera, EDIT_SIZE.x / EDIT_SIZE.y) * camera.orbit_view(app.camera)
	at, _ := gizmo_project(view_proj, e.points[1].p, EDIT_SIZE)
	first := e.points[1].p
	after_lay := slice.clone(object_sculptor(obj).mesh.positions[:], context.temp_allocator)
	edit_frame(&app, at, true, true)
	edit_frame(&app, at + {0, 40}, true, false)
	edit_frame(&app, at + {0, 80}, true, false)
	edit_frame(&app, at + {0, 80}, false, false)
	testing.expect(t, linalg.length(e.points[1].p - first) > 0.05, "the point did not move")
	testing.expect(t, !slice.equal(after_lay, object_sculptor(obj).mesh.positions[:]), "the stroke was not laid again")
	at, _ = gizmo_project(view_proj, e.points[1].p, EDIT_SIZE)
	edit_frame(&app, at, true, true)
	edit_frame(&app, at, false, false)
	testing.expect(t, e.points[1].corner, "a tap did not make a corner")
	edit_frame(&app, {100, 100}, true, true)
	testing.expect(t, !e.open, "a press away did not keep it")
	testing.expect_value(t, len(app.history.done), 1)
	edit_frame(&app, {100, 100}, false, false)
}

// Hold to edit off, or the Line switch on, a held stroke ends as drawn.
@(test)
held_stroke_refused :: proc(t: ^testing.T) {
	lines := [2]bool{false, true}
	for line in lines {
		app: App
		_ = edit_sphere(&app)
		if line do app.brush.line = true
		else do app.brush.hold_edit = false
		edit_stroke(&app, true)
		testing.expect(t, !app.stroke_edit.open, "it opened")
		testing.expect_value(t, len(app.history.done), 1)
		edit_scene_free(&app)
	}
}

@(private = "file")
gizmo_project :: proc(view_proj: matrix[4, 4]f32, p: Vec3, size: [2]f32) -> ([2]f32, bool) {
	h := view_proj * [4]f32{p.x, p.y, p.z, 1}
	if h.w <= 1e-6 do return {}, false
	ndc := h.xy / h.w
	return {(ndc.x + 1) * 0.5 * size.x, (1 - ndc.y) * 0.5 * size.y}, true
}
