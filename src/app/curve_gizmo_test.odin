package main

import "core:math/linalg"
import "core:testing"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

@(private = "file")
GIZMO_CURVE_SIZE :: [2]f32{1000, 800}

// A sphere and, selected, a curve of three points across its front in the Curve tool's
// Edit tab, its first two points picked.
@(private = "file")
gizmo_curve_scene :: proc(app: ^App) -> ^Object {
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
	app.curve.editing = true
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
	curve := selected_object(app)
	curve.curve.points[0].selected = true
	curve.curve.points[1].selected = true
	return curve
}

@(private = "file")
gizmo_curve_free :: proc(app: ^App) {
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
gizmo_curve_frame :: proc(app: ^App, p: [2]f32, held, press: bool) {
	_ = curve_tool_frame(app, {size = GIZMO_CURVE_SIZE, mouse_pos = p, hovered = true, primary = held, press = press})
}

// The gizmo's X arm drags the picked points along X alone, their handles with them, the
// third point staying; one undo step, which Undo takes back.
@(test)
curve_gizmo_arm_moves_the_picked_points :: proc(t: ^testing.T) {
	app: App
	defer gizmo_curve_free(&app)
	obj := gizmo_curve_scene(&app)
	cp := obj.curve
	app.move.mode, app.move.orient = .Move, .World
	steps := len(app.history.done)
	was := [3]geom.Bezier_Point{cp.points[0], cp.points[1], cp.points[2]}
	sc := curve_gizmo_screen(&app, GIZMO_CURVE_SIZE)
	testing.expect(t, sc.ok, "no gizmo on the picked points")
	from := sc.center + (sc.tips[0] - sc.center) * 0.8
	testing.expect_value(t, curve_gizmo_pick(&app, from, GIZMO_CURVE_SIZE), gizmo.Handle.X)
	way := linalg.normalize(sc.tips[0] - sc.center)
	gizmo_curve_frame(&app, from, true, true)
	for i in 1 ..= 6 do gizmo_curve_frame(&app, from + way * f32(i) * 20, true, false)
	gizmo_curve_frame(&app, from + way * 120, false, false)
	d := cp.points[0].p - was[0].p
	testing.expectf(t, d.x > 0.05 && abs(d.y) < 1e-4 && abs(d.z) < 1e-4, "moved by %v, not along X", d)
	testing.expectf(t, linalg.length(cp.points[1].p - was[1].p - d) < 1e-4, "the second picked point moved by %v", cp.points[1].p - was[1].p)
	testing.expectf(t, linalg.length(cp.points[0].h_out - was[0].h_out) < 1e-4, "a moved handle changed: %v", cp.points[0].h_out)
	testing.expect(t, cp.points[2].p == was[2].p, "the point not picked moved")
	testing.expect_value(t, len(app.history.done), steps + 1)
	testing.expect_value(t, app.curve.edits, 1)
	history_undo(&app)
	obj = selected_object(&app)
	testing.expectf(t, linalg.length(obj.curve.points[0].p - was[0].p) < 1e-6, "undo left %v", obj.curve.points[0].p)
}

// G then X moves the picked points along X with the pointer and no button, and a press
// keeps it; R turns them about the view by the pointer's angle round their middle, keeping
// their distance from it, and Escape puts them back; S with Snap scales them in steps.
@(test)
curve_keys_move_turn_and_scale :: proc(t: ^testing.T) {
	app: App
	defer gizmo_curve_free(&app)
	obj := gizmo_curve_scene(&app)
	cp := obj.curve
	app.move.orient = .World
	steps := len(app.history.done)
	start := [3]Vec3{cp.points[0].p, cp.points[1].p, cp.points[2].p}
	at := [2]f32{600, 300}
	gizmo_curve_frame(&app, at, false, false)
	curve_xform_key(&app, .View)
	curve_xform_axis(&app, 0)
	testing.expect_value(t, app.curve.xform.handle, gizmo.Handle.X)
	for i in 1 ..= 4 do gizmo_curve_frame(&app, at + {f32(i) * 25, f32(i) * 10}, false, false)
	gizmo_curve_frame(&app, at + {100, 40}, true, true)
	gizmo_curve_frame(&app, at + {100, 40}, false, false)
	d := cp.points[0].p - start[0]
	testing.expectf(t, abs(d.x) > 0.05 && abs(d.y) < 1e-4 && abs(d.z) < 1e-4, "G X moved by %v", d)
	testing.expect_value(t, app.curve.xform.handle, gizmo.Handle.None)
	testing.expect_value(t, len(app.history.done), steps + 1)
	testing.expect(t, cp.points[2].p == start[2], "the point not picked moved")

	// R: a quarter turn of the pointer round the middle keeps each point's distance from it.
	mid, _ := curve_picked_middle(obj)
	moved := [2]Vec3{to_world(obj.transform, cp.points[0].p), to_world(obj.transform, cp.points[1].p)}
	sc := curve_gizmo_screen(&app, GIZMO_CURVE_SIZE)
	gizmo_curve_frame(&app, sc.center + {100, 0}, false, false)
	curve_xform_key(&app, .Turn_View)
	gizmo_curve_frame(&app, sc.center + {100, 0}, false, false)
	gizmo_curve_frame(&app, sc.center + {0, -100}, false, false)
	testing.expectf(t, abs(app.curve.xform.amount - 90) < 1e-3, "turned %v degrees", app.curve.xform.amount)
	for k in 0 ..< 2 {
		was, now := linalg.length(moved[k] - mid), linalg.length(to_world(obj.transform, cp.points[k].p) - mid)
		testing.expectf(t, abs(was - now) < 1e-4, "point %d went from %v to %v from the middle", k, was, now)
		testing.expectf(t, linalg.length(to_world(obj.transform, cp.points[k].p) - moved[k]) > 0.1, "point %d did not turn", k)
	}
	curve_xform_cancel(&app)
	for k in 0 ..< 2 do testing.expect(t, linalg.length(to_world(obj.transform, cp.points[k].p) - moved[k]) < 1e-5, "Escape left a point turned")
	testing.expect_value(t, len(app.history.done), steps + 1)

	// S with Snap: the pointer half again as far from the middle scales by 1.5.
	app.move.snap = true
	gizmo_curve_frame(&app, sc.center + {100, 0}, false, false)
	curve_xform_key(&app, .Scale)
	gizmo_curve_frame(&app, sc.center + {100, 0}, false, false)
	gizmo_curve_frame(&app, sc.center + {152, 0}, false, false)
	testing.expectf(t, abs(app.curve.xform.amount - 1.5) < 1e-4, "scaled by %v", app.curve.xform.amount)
	curve_xform_end(&app)
	for k in 0 ..< 2 {
		was, now := linalg.length(moved[k] - mid), linalg.length(to_world(obj.transform, cp.points[k].p) - mid)
		testing.expectf(t, abs(now - was * 1.5) < 1e-3, "point %d went from %v to %v from the middle", k, was, now)
	}
	testing.expect_value(t, len(app.history.done), steps + 2)
}

// Handles: the command sets the picked points' type as one undo step, and an Auto point's
// handles follow when its neighbours are moved by the gizmo's keys.
@(test)
curve_handle_types_follow_moved_points :: proc(t: ^testing.T) {
	app: App
	defer gizmo_curve_free(&app)
	obj := gizmo_curve_scene(&app)
	cp := obj.curve
	steps := len(app.history.done)
	curve_select_none(cp)
	cp.points[1].selected = true
	app.curve.picked = 2
	testing.expect(t, command_run(&app, .Curve_Handles, int(geom.Handle_Type.Auto)))
	testing.expect_value(t, cp.points[1].handles, geom.Handle_Type.Auto)
	testing.expect(t, command_checked(&app, .Curve_Handles, int(geom.Handle_Type.Auto)), "Auto is not shown as set")
	testing.expect_value(t, len(app.history.done), steps + 1)
	was := cp.points[1].h_out
	// The point after it moves up the view; the Auto point's handles turn toward it.
	curve_select_none(cp)
	cp.points[2].selected = true
	at := [2]f32{500, 400}
	gizmo_curve_frame(&app, at, false, false)
	curve_xform_key(&app, .View)
	gizmo_curve_frame(&app, at + {0, -80}, false, false)
	curve_xform_end(&app)
	testing.expectf(t, linalg.length(cp.points[1].h_out - was) > 1e-3, "the Auto point's handle stayed at %v", was)
	testing.expectf(t, linalg.length(cp.points[1].h_in + cp.points[1].h_out * (linalg.length(cp.points[1].h_in) / linalg.length(cp.points[1].h_out))) < 1e-4, "the Auto handles are not in one line")
	testing.expect_value(t, len(app.history.done), steps + 2)
}

// The Point section moves the picked points by the change to their middle, radius and
// tilt, the rest staying, one undo step that Undo takes back; a drag of the values is one
// step when it ends.
@(test)
curve_point_values_move_the_picked :: proc(t: ^testing.T) {
	app: App
	defer gizmo_curve_free(&app)
	obj := gizmo_curve_scene(&app)
	steps := len(app.history.done)
	first, last := obj.curve.points[0], obj.curve.points[2]
	v, n := curve_point_values(obj)
	testing.expect_value(t, n, 2)
	testing.expectf(t, abs(v.radius - 0.05) < 1e-6 && v.tilt == 0, "values %v", v)
	w := v
	w.middle.y += 0.2
	w.radius, w.tilt = 0.1, 30
	testing.expect(t, curve_set_point_values(&app, obj, w))
	testing.expect_value(t, len(app.history.done), steps + 1)
	p := obj.curve.points[0]
	testing.expectf(t, linalg.length(p.p - (first.p + {0, 0.2, 0})) < 1e-5, "the point is at %v", p.p)
	testing.expectf(t, abs(p.radius - 0.1) < 1e-6 && abs(p.twist - linalg.to_radians(f32(30))) < 1e-5, "radius %v tilt %v", p.radius, p.twist)
	testing.expect(t, obj.curve.points[2] == last, "a point not picked moved")
	// Undo brings the curve back as a new object, so it is looked up again.
	history_undo(&app)
	obj = selected_object(&app)
	testing.expect(t, obj.curve.points[0].p == first.p, "Undo did not put it back")

	// A drag: two changes, one step once it ends.
	steps = len(app.history.done)
	obj.curve.points[0].selected, obj.curve.points[1].selected = true, true
	for k in 1 ..= 2 {
		w, _ = curve_point_values(obj)
		w.middle.x += 0.05 * f32(k)
		testing.expect(t, curve_set_point_values(&app, obj, w, drag = true))
	}
	curve_look_drag_end(&app, force = true)
	testing.expect_value(t, len(app.history.done), steps + 1)
}
