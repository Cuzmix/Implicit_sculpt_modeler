package main

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

@(private = "file")
STAMP_SIZE :: [2]f32{1000, 800}

// A selected sphere with no GPU buffers, Draw held as a Rectangle stroke, Edit stamps on;
// with `alpha` the second built-in alpha, so turning the stamp changes what it lays.
@(private = "file")
stamp_sphere :: proc(app: ^App, alpha: bool) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(5), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.camera = camera.orbit_default()
	app.tool = .Brush
	app.brush.kind, app.brush.radius_px, app.brush.stroke = .Draw, 40, .Drag_Rect
	app.brush.strengths[.Draw] = 0.5
	app.brush.stamp_edit, app.brush.stamp_snap = true, .Fifteen
	app.kit.fixed_dt = 1.0 / 60
	alphas_init(app)
	if alpha do app.brush.alpha = 2
	return obj
}

@(private = "file")
stamp_scene_free :: proc(app: ^App) {
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
	alphas_destroy(app)
}

@(private = "file")
stamp_frame :: proc(app: ^App, p: [2]f32, held, press: bool) {
	app.kit.ctx.time += 1.0 / 60
	kind: Sample_Kind = .Press if press else (.Move if held else .Release)
	samples := []Input_Sample{{pos = p, pressure = 1, kind = kind}}
	_ = sculpt_frame(app, {size = STAMP_SIZE, mouse_pos = p, hovered = true, primary = held, press = press, samples = samples})
}

// A press at `from`, a drag in steps to `to`, and the release there.
@(private = "file")
stamp_drag :: proc(app: ^App, from, to: [2]f32) {
	stamp_frame(app, from, true, true)
	for i in 1 ..= 6 do stamp_frame(app, linalg.lerp(from, to, f32(i) / 6), true, false)
	stamp_frame(app, to, false, false)
}

// A stamp dragged out from the sphere's middle, sixty pixels to the right.
@(private = "file")
stamp_lay :: proc(app: ^App) {
	stamp_drag(app, {500, 400}, {560, 400})
}

// A Rectangle stamp stays open after the release, holding the one dab it laid; Validate
// keeps it as one undo step. With Edit stamps off it ends on the release as before.
@(test)
stamp_stays_open_and_validates :: proc(t: ^testing.T) {
	app: App
	defer stamp_scene_free(&app)
	obj := stamp_sphere(&app, false)
	before := slice.clone(object_sculptor(obj).mesh.positions[:], context.temp_allocator)
	stamp_lay(&app)
	e := &app.stroke_edit
	testing.expect(t, e.open && e.stamp, "the stamp did not stay open")
	testing.expect(t, !slice.equal(before, object_sculptor(obj).mesh.positions[:]), "the stamp laid nothing")
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, app.stroke_end.stamp_edits, 1)
	testing.expect_value(t, len(action_list(&app, .Stroke_Edit)), 2)
	stroke_edit_validate(&app)
	testing.expect(t, !e.open && !app.stroke.active, "still open")
	testing.expect_value(t, len(app.history.done), 1)

	app.brush.stamp_edit = false
	stamp_lay(&app)
	testing.expect(t, !e.open, "opened with Edit stamps off")
	testing.expect_value(t, len(app.history.done), 2)
}

// Dragging the blue dot round the ring turns the stamp, snapping to the 45° notch from 47°,
// and lays it again turned; the square sizes it, the green dot sets its intensity.
@(test)
stamp_turns_and_sizes :: proc(t: ^testing.T) {
	app: App
	defer stamp_scene_free(&app)
	obj := stamp_sphere(&app, true)
	stamp_lay(&app)
	e := &app.stroke_edit
	testing.expect(t, e.open, "not open")
	if !e.open do return
	sc := stamp_screen(&app, obj, STAMP_SIZE)
	testing.expectf(t, abs(sc.degrees - 90) < 2, "laid at %v degrees", sc.degrees)
	laid := slice.clone(object_sculptor(obj).mesh.positions[:], context.temp_allocator)
	a := linalg.to_radians(f32(47))
	stamp_drag(&app, sc.turn, sc.center + sc.ring * [2]f32{math.sin(a), -math.cos(a)})
	sc = stamp_screen(&app, obj, STAMP_SIZE)
	testing.expectf(t, abs(sc.degrees - 45) < 1, "turned to %v degrees", sc.degrees)
	testing.expect(t, !slice.equal(laid, object_sculptor(obj).mesh.positions[:]), "the turn laid nothing new")

	radius := e.stamp_radius
	stamp_drag(&app, sc.size, sc.size + {30, 30})
	testing.expectf(t, e.stamp_radius > 1.3 * radius, "radius %v from %v", e.stamp_radius, radius)
	sc = stamp_screen(&app, obj, STAMP_SIZE)
	strength := e.stamp_strength
	stamp_drag(&app, sc.intensity, sc.intensity - {40, 0})
	testing.expectf(t, e.stamp_strength > 1.5 * strength, "strength %v from %v", e.stamp_strength, strength)
	testing.expect(t, e.open, "an edit closed it")
	testing.expect_value(t, len(app.history.done), 0)
}

// A drag inside the ring slides the stamp over the surface; a press outside the ring keeps
// it and starts the next stroke.
@(test)
stamp_slides_then_keeps :: proc(t: ^testing.T) {
	app: App
	defer stamp_scene_free(&app)
	obj := stamp_sphere(&app, false)
	stamp_lay(&app)
	e := &app.stroke_edit
	if !e.open {
		testing.fail_now(t, "not open")
	}
	at := e.stamp_at
	sc := stamp_screen(&app, obj, STAMP_SIZE)
	stamp_drag(&app, sc.center + {5, 5}, sc.center + {5, 65})
	testing.expectf(t, linalg.length(e.stamp_at - at) > 0.05, "moved %v", linalg.length(e.stamp_at - at))
	testing.expect(t, e.open, "a slide closed it")
	stamp_frame(&app, {350, 250}, true, true)
	testing.expect(t, !e.open, "a press outside did not keep it")
	testing.expect_value(t, len(app.history.done), 1)
	stamp_frame(&app, {350, 250}, false, false)
}

// Cancel puts every vertex back bit for bit after a slide and records nothing; Undo too.
@(test)
stamp_cancels :: proc(t: ^testing.T) {
	cases := [2]bool{false, true}
	for by_undo in cases {
		app: App
		obj := stamp_sphere(&app, true)
		before := slice.clone(object_sculptor(obj).mesh.positions[:], context.temp_allocator)
		stamp_lay(&app)
		testing.expect(t, app.stroke_edit.open, "not open")
		sc := stamp_screen(&app, obj, STAMP_SIZE)
		stamp_drag(&app, sc.center, sc.center + {40, 0})
		if by_undo do undo_run(&app)
		else do stroke_edit_cancel(&app)
		testing.expect(t, !app.stroke_edit.open && !app.stroke.active, "still open")
		testing.expect(t, slice.equal(before, object_sculptor(obj).mesh.positions[:]), "the surface did not come back")
		testing.expect_value(t, len(app.history.done), 0)
		stamp_scene_free(&app)
	}
}

// The Turn snap clicks within about a quarter of its step and nowhere else; Off never.
@(test)
stamp_snap_steps :: proc(t: ^testing.T) {
	testing.expect_value(t, stamp_snap_angle(47, .Fifteen), 45)
	testing.expect_value(t, stamp_snap_angle(52, .Fifteen), 52)
	testing.expect_value(t, stamp_snap_angle(6, .Five), 5)
	testing.expect_value(t, stamp_snap_angle(57, .Forty_Five), 45)
	testing.expect_value(t, stamp_snap_angle(47, .Off), 47)
	testing.expect_value(t, stamp_snap_angle(-91, .Fifteen), -90)
}
