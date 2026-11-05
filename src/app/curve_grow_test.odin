package main

import "core:math/linalg"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

@(private = "file")
GROW_SIZE :: [2]f32{1000, 800}

// A sphere and, selected, an open curve of three points across its front (right of the
// view's centre by `shift`), the Curve tool on.
@(private = "file")
grow_curve :: proc(app: ^App, shift: f32) -> ^Object {
	toward := camera.orbit_toward(app.camera, {})
	right := linalg.normalize(linalg.cross(Vec3{0, 1, 0}, toward))
	pts: [3]geom.Bezier_Point
	for &p, i in pts {
		p.p = toward * 1.05 + right * ((f32(i) - 1) * 0.3 + shift)
		p.h_in, p.h_out = -right * 0.1, right * 0.1
		p.radius, p.intensity = 0.02, 1
	}
	_ = curve_object_add(app, pts[:], false)
	return selected_object(app)
}

@(private = "file")
grow_scene :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(4), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected, app.scene.next_id = 0, 1
	app.camera = camera.orbit_default()
	app.tool = .Curve
	app.curve = CURVE_DEFAULTS
	app.curve.kind = .Curve
	app.brush.radius_px = 40
	return grow_curve(app, -0.3)
}

@(private = "file")
grow_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		delete(obj.group_materials)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.scene.also)
	curve_tool_destroy(&app.curve)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
grow_frame :: proc(app: ^App, p: [2]f32, held, press: bool) {
	_ = curve_tool_frame(app, {size = GROW_SIZE, mouse_pos = p, hovered = true, primary = held, press = press})
}

@(private = "file")
curve_count :: proc(app: ^App) -> (n: int) {
	for o in app.scene.objects do if o.curve != nil do n += 1
	return
}

// In the Edit tab a press on the nub past the last point adds a point that the drag
// places, one undo step; in the Draw tab, taps with an end picked carry the curve on from
// it, a step each, and make no new curve.
@(test)
curve_grows_from_its_ends :: proc(t: ^testing.T) {
	app: App
	defer grow_free(&app)
	obj := grow_scene(&app)
	steps := len(app.history.done)
	app.curve.editing = true
	at, ok := curve_nub_screen(&app, obj, edit_view_proj(&app, GROW_SIZE), GROW_SIZE, true)
	testing.expect(t, ok, "no nub past the last point")
	end := curve_point_screen(&app, obj, edit_view_proj(&app, GROW_SIZE), GROW_SIZE, 2).point
	out := linalg.normalize(at - end)
	grow_frame(&app, at, true, true)
	for i in 1 ..= 4 do grow_frame(&app, at + out * f32(i) * 10, true, false)
	grow_frame(&app, at + out * 40, false, false)
	cp := obj.curve
	testing.expect_value(t, len(cp.points), 4)
	testing.expect(t, cp.points[3].selected && curve_selected_count(cp) == 1, "the new point is not picked alone")
	testing.expect_value(t, len(app.history.done), steps + 1)
	testing.expect_value(t, cp.points[3].handles, geom.Handle_Type.Auto)
	testing.expectf(t, linalg.length(cp.points[2].h_out) > 1e-4, "the old end has no way out")

	// Draw: taps carry on from the picked end.
	app.curve.editing = false
	testing.expect_value(t, curve_grow_end(&app), 3)
	grow_frame(&app, {900, 300}, true, true)
	grow_frame(&app, {900, 300}, false, false)
	grow_frame(&app, {940, 200}, true, true)
	grow_frame(&app, {940, 200}, false, false)
	testing.expect_value(t, len(cp.points), 6)
	testing.expect(t, cp.points[5].selected, "the last tapped point is not picked")
	testing.expect_value(t, len(app.history.done), steps + 3)
	testing.expect_value(t, curve_count(&app), 1)
	testing.expect_value(t, len(app.curve.placing), 0)
}

// Reverse swaps the ends and each point's handles; Split cuts an open curve in two at the
// picked point (one step, which Undo takes back whole) and opens a loop there.
@(test)
curve_reverses_and_splits :: proc(t: ^testing.T) {
	app: App
	defer grow_free(&app)
	obj := grow_scene(&app)
	cp := obj.curve
	first, last := cp.points[0], cp.points[2]
	testing.expect(t, command_run(&app, .Curve_Reverse))
	testing.expect(t, cp.points[0].p == last.p && cp.points[2].p == first.p, "the ends did not swap")
	testing.expect(t, cp.points[0].h_out == last.h_in, "the handles did not swap")

	steps := len(app.history.done)
	cp.points[1].selected = true
	testing.expect(t, command_run(&app, .Curve_Split))
	testing.expect_value(t, curve_count(&app), 2)
	testing.expect_value(t, len(cp.points), 2)
	testing.expect(t, selected_object(&app) == obj, "the first curve is not still selected")
	other: ^Object
	for o in app.scene.objects do if o.curve != nil && o != obj do other = o
	testing.expect_value(t, len(other.curve.points), 2)
	testing.expectf(t, linalg.length(to_world(other.transform, other.curve.points[0].p) - to_world(obj.transform, cp.points[1].p)) < 1e-5, "the cut point is not in both")
	history_undo(&app)
	testing.expect_value(t, curve_count(&app), 1)
	testing.expect_value(t, len(selected_object(&app).curve.points), 3)
	testing.expect_value(t, len(app.history.done), steps)

	// A loop opens at the point, which is then its start and end.
	obj = selected_object(&app)
	obj.curve.closed = true
	curve_select_none(obj.curve)
	obj.curve.points[1].selected = true
	at := obj.curve.points[1].p
	testing.expect(t, command_run(&app, .Curve_Split))
	testing.expect(t, !obj.curve.closed, "the loop did not open")
	testing.expect_value(t, len(obj.curve.points), 4)
	testing.expect(t, obj.curve.points[0].p == at && obj.curve.points[3].p == at, "the loop did not open at the point")
}

// Join makes two selected curves one at their nearest ends, the second going, one step
// that Undo takes back; with one open curve it closes it.
@(test)
curve_joins_two :: proc(t: ^testing.T) {
	app: App
	defer grow_free(&app)
	a := grow_scene(&app)
	b := grow_curve(&app, 0.6)
	steps := len(app.history.done)
	selection_set(&app, {a.id, b.id})
	testing.expect(t, curve_joinable(&app), "two open curves cannot join")
	ends := [2]Vec3{to_world(a.transform, a.curve.points[0].p), to_world(b.transform, b.curve.points[2].p)}
	testing.expect(t, command_run(&app, .Curve_Join))
	testing.expect_value(t, curve_count(&app), 1)
	testing.expect(t, selected_object(&app) == a, "the joined curve is not selected")
	testing.expect_value(t, len(a.curve.points), 6)
	testing.expectf(t, linalg.length(to_world(a.transform, a.curve.points[0].p) - ends[0]) < 1e-5 && linalg.length(to_world(a.transform, a.curve.points[5].p) - ends[1]) < 1e-5, "the joined run does not go from end to end")
	testing.expect_value(t, len(app.history.done), steps + 2)
	history_undo(&app)
	testing.expect_value(t, curve_count(&app), 2)
	testing.expect_value(t, len(app.history.done), steps)

	// One open curve: Join closes it.
	for o, i in app.scene.objects do if o.curve != nil {
		select_only(&app, i)
		break
	}
	testing.expect(t, command_run(&app, .Curve_Join))
	testing.expect(t, selected_object(&app).curve.closed, "Join did not close the one curve")
}
