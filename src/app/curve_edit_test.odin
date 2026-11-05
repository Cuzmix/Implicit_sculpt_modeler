package main

import "core:math/linalg"
import "core:testing"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

@(private = "file")
EDIT_CURVE_SIZE :: [2]f32{1000, 800}

// A sphere and, selected, a curve of three points across its front, the Curve tool on.
@(private = "file")
edit_curve_scene :: proc(app: ^App) -> ^Object {
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
	toward := camera.orbit_toward(app.camera, {})
	right := linalg.normalize(linalg.cross(Vec3{0, 1, 0}, toward))
	pts: [3]geom.Bezier_Point
	for &p, i in pts {
		p.p = toward * 1.05 + right * (f32(i) - 1) * 0.5
		p.h_in, p.h_out = -right * 0.15, right * 0.15
		p.radius, p.intensity = 0.05, 1
	}
	_ = curve_object_add(app, pts[:], false)
	return selected_object(app)
}

@(private = "file")
edit_curve_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		delete(obj.group_materials)
		free(obj)
	}
	delete(app.scene.objects)
	curve_tool_destroy(&app.curve)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
edit_curve_frame :: proc(app: ^App, p: [2]f32, held, press: bool) {
	_ = curve_tool_frame(app, {size = EDIT_CURVE_SIZE, mouse_pos = p, hovered = true, primary = held, press = press})
}

@(private = "file")
edit_curve_drag :: proc(app: ^App, from, to: [2]f32) {
	edit_curve_frame(app, from, true, true)
	for i in 1 ..= 5 do edit_curve_frame(app, linalg.lerp(from, to, f32(i) / 5), true, false)
	edit_curve_frame(app, to, false, false)
}

@(private = "file")
point_on_screen :: proc(app: ^App, obj: ^Object, i: int) -> [2]f32 {
	at, _ := gizmo.project(edit_view_proj(app, EDIT_CURVE_SIZE), to_world(obj.transform, obj.curve.points[i].p), EDIT_CURVE_SIZE)
	return at
}

// Dragging a point moves it, one undo step; a tap picks it (no step), a double tap makes it
// a corner and another smooth again, each a step; nothing new is drawn by those presses.
@(test)
curve_point_drags_and_taps :: proc(t: ^testing.T) {
	app: App
	defer edit_curve_free(&app)
	obj := edit_curve_scene(&app)
	steps := len(app.history.done)
	was := obj.curve.points[1].p
	at := point_on_screen(&app, obj, 1)
	edit_curve_drag(&app, at, at + {0, 50})
	testing.expectf(t, linalg.length(obj.curve.points[1].p - was) > 0.05, "moved %v", linalg.length(obj.curve.points[1].p - was))
	testing.expect_value(t, len(app.history.done), steps + 1)
	testing.expect_value(t, len(app.scene.objects), 2)
	testing.expect_value(t, app.curve.picked, 2)

	at = point_on_screen(&app, obj, 1)
	edit_curve_drag(&app, at, at)
	testing.expect(t, !obj.curve.points[1].corner && obj.curve.points[1].selected, "a tap did not just pick the point")
	edit_curve_drag(&app, at, at)
	testing.expect(t, obj.curve.points[1].corner, "a double tap did not make a corner")
	edit_curve_drag(&app, at, at)
	edit_curve_drag(&app, at, at)
	testing.expect(t, !obj.curve.points[1].corner, "a second double tap did not make it smooth")
	testing.expect_value(t, len(app.history.done), steps + 3)
	testing.expect_value(t, app.curve.edits, 3)
	testing.expect(t, app.curve.drag.before == nil, "a snapshot is still held")
}

// A tap on the line adds a point there; a point dropped on its neighbour merges into it.
@(test)
curve_line_adds_and_points_merge :: proc(t: ^testing.T) {
	app: App
	defer edit_curve_free(&app)
	obj := edit_curve_scene(&app)
	view_proj := edit_view_proj(&app, EDIT_CURVE_SIZE)
	mid, _ := gizmo.project(view_proj, to_world(obj.transform, geom.bezier_at(obj.curve.points[:], false, 0.5)), EDIT_CURVE_SIZE)
	edit_curve_drag(&app, mid, mid)
	testing.expect_value(t, len(obj.curve.points), 4)
	testing.expect_value(t, app.curve.picked, 2)

	from, to := point_on_screen(&app, obj, 1), point_on_screen(&app, obj, 2)
	edit_curve_drag(&app, from, to)
	testing.expect_value(t, len(obj.curve.points), 3)
}

// The rope pull puts the line's place exactly where it was pulled.
@(test)
curve_rope_pull_follows :: proc(t: ^testing.T) {
	cp: Curve_Part
	defer delete(cp.points)
	append(&cp.points, geom.Bezier_Point{p = {0, 0, 0}, h_out = {0.3, 0, 0}}, geom.Bezier_Point{p = {1, 0, 0}, h_in = {-0.3, 0, 0}, h_out = {0.3, 0, 0}}, geom.Bezier_Point{p = {2, 0, 0}, h_in = {-0.3, 0, 0}})
	us := [3]f32{0.3, 0.5, 1.8}
	for u in us {
		before := geom.bezier_at(cp.points[:], false, u)
		delta := Vec3{0, 0.4, 0.1}
		curve_rope_pull(&cp, u, delta)
		after := geom.bezier_at(cp.points[:], false, u)
		testing.expectf(t, linalg.length(after - (before + delta)) < 1e-4, "u %v: %v, wanted %v", u, after, before + delta)
	}
}

// The context bar's commands: Delete point keeps two points, Close needs three and toggles.
@(test)
curve_commands :: proc(t: ^testing.T) {
	app: App
	defer edit_curve_free(&app)
	obj := edit_curve_scene(&app)
	testing.expect(t, !command_enabled(&app, .Curve_Delete_Point), "deletes with no point picked")
	testing.expect(t, command_run(&app, .Curve_Close), "Close did not run")
	testing.expect(t, obj.curve.closed, "not closed")
	app.curve.picked = 2
	testing.expect(t, !command_enabled(&app, .Curve_Delete_Point), "a loop of three lost a point")
	testing.expect(t, command_run(&app, .Curve_Close))
	testing.expect(t, command_run(&app, .Curve_Delete_Point))
	testing.expect_value(t, len(obj.curve.points), 2)
	testing.expect(t, !command_enabled(&app, .Curve_Delete_Point), "a curve of two lost a point")
	app.curve.picked = 1
	testing.expect(t, command_run(&app, .Curve_Corner))
	testing.expect(t, command_checked(&app, .Curve_Corner), "not a corner")
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{.Curve})
}

// Shift-taps pick several points, which a drag of one moves together, one undo step; in the
// Edit tab a box over empty space picks those inside and a tap there picks none; Delete
// takes the picked points as one step and keeps the rest.
@(test)
curve_points_picked_move_and_delete_together :: proc(t: ^testing.T) {
	app: App
	defer edit_curve_free(&app)
	obj := edit_curve_scene(&app)
	cp := obj.curve
	steps := len(app.history.done)
	a, b := point_on_screen(&app, obj, 0), point_on_screen(&app, obj, 2)
	edit_curve_drag(&app, a, a)
	_ = curve_tool_frame(&app, {size = EDIT_CURVE_SIZE, mouse_pos = b, hovered = true, primary = true, press = true, smooth = true})
	_ = curve_tool_frame(&app, {size = EDIT_CURVE_SIZE, mouse_pos = b, hovered = true, smooth = true})
	testing.expect_value(t, curve_selected_count(cp), 2)
	testing.expect_value(t, len(app.history.done), steps)
	was0, was1, was2 := cp.points[0].p, cp.points[1].p, cp.points[2].p
	edit_curve_drag(&app, b, b + {0, 60})
	moved := cp.points[2].p - was2
	testing.expectf(t, linalg.length(moved) > 0.05, "moved %v", moved)
	testing.expectf(t, linalg.length(cp.points[0].p - was0 - moved) < 1e-4, "the other picked point moved by %v, not %v", cp.points[0].p - was0, moved)
	testing.expect(t, cp.points[1].p == was1, "a point not picked moved")
	testing.expect_value(t, len(app.history.done), steps + 1)

	// The Edit tab: a tap on empty space picks none, a box round the middle point picks it.
	app.curve.editing = true
	edit_curve_drag(&app, {20, 20}, {20, 20})
	testing.expect_value(t, curve_selected_count(cp), 0)
	m := point_on_screen(&app, obj, 1)
	edit_curve_drag(&app, m - {30, 30}, m + {30, 30})
	testing.expect(t, cp.points[1].selected && curve_selected_count(cp) == 1, "the box did not pick just the middle point")
	testing.expect_value(t, len(app.scene.objects), 2)

	// A curve keeps two points: deleting all three is refused, deleting one is a step.
	curve_select_all(&app)
	testing.expect(t, !command_enabled(&app, .Curve_Delete_Point), "deleting every point is offered")
	curve_select_none(cp)
	cp.points[1].selected = true
	testing.expect(t, command_run(&app, .Curve_Delete_Point))
	testing.expect_value(t, len(cp.points), 2)
	testing.expect_value(t, len(app.history.done), steps + 2)
}

// Handles show on picked points and their neighbours only, unless every point's are asked for.
@(test)
curve_handles_show_round_the_picked :: proc(t: ^testing.T) {
	cp: Curve_Part
	defer delete(cp.points)
	for _ in 0 ..< 5 do append(&cp.points, geom.Bezier_Point{})
	app: App
	testing.expect(t, !curve_handles_shown(&app, &cp, 2), "handles show with nothing picked")
	cp.points[2].selected = true
	for i in 0 ..< 5 do testing.expectf(t, curve_handles_shown(&app, &cp, i) == (i >= 1 && i <= 3), "point %d", i)
	curve_select_none(&cp)
	cp.points[0].selected = true
	testing.expect(t, !curve_handles_shown(&app, &cp, 4), "an open curve's ends are neighbours")
	cp.closed = true
	testing.expect(t, curve_handles_shown(&app, &cp, 4), "a loop's ends are not neighbours")
	app.curve.all_handles = true
	testing.expect(t, curve_handles_shown(&app, &cp, 2), "every point's handles do not show")
}
