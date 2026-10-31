package main

import "core:math/linalg"

import "../camera"
import "../sculpt"

// Brush path, as Nomad's and ZBrush's curve strokes: the brush in hand laid along a curve
// over the model it lies on. Running it opens the stroke for editing as a stroke held still
// does (stroke_edit.odin), with the curve's points (each with its radius and intensity) in
// the model's space: the Brush tool takes over, the stroke is laid and can be reshaped,
// then Validate keeps it as one undo step and Cancel puts the surface back. The curve
// stays, to run again, with another brush or on another side.

// Why the selected curve cannot run the brush now, or "" when it can. In temp memory.
curve_brush_refusal :: proc(app: ^App) -> string {
	obj := selected_curve(app)
	if obj == nil do return "select a curve"
	if app.stroke.active || app.stroke_edit.open do return "a stroke is under way"
	flags := BRUSHES[app.brush.kind].flags
	if flags & {.Grab, .Hook, .Cloth} != {} do return "the brush moves what it holds, so it has no path to follow"
	if _, ok := curve_brush_target(app, obj); !ok do return "no sculptable mesh lies under the curve"
	return ""
}

// The mesh the curve lies on: the first surface met looking from the eye at the curve's
// first point, curves left out. Refused when that object cannot take a held stroke (clay,
// a cage, dynamic topology, HD).
@(private = "file")
curve_brush_target :: proc(app: ^App, curve: ^Object) -> (^Object, bool) {
	first := to_world(curve.transform, curve.curve.points[0].p)
	eye := camera.orbit_eye(app.camera)
	dir := linalg.normalize0(first - eye)
	if dir == {} do return nil, false
	index, _, _, ok := scene_raycast_surface(app, eye, dir, skip_curves = true)
	if !ok do return nil, false
	obj := app.scene.objects[index]
	if obj.voxel != nil || obj.cage != nil || obj.curve != nil || object_dynamic(obj) || object_in_hd(obj) do return nil, false
	return obj, true
}

// Runs the brush in hand along the selected curve on the mesh under it, opening the stroke
// for editing; false, saying why, when it cannot.
curve_brush_run :: proc(app: ^App) -> bool {
	if why := curve_brush_refusal(app); why != "" {
		report(app, nil, {.Warning}, "Run brush: %s", why)
		return false
	}
	curve := selected_curve(app)
	target, _ := curve_brush_target(app, curve)
	stroke_finish(app)
	ct, tt := curve.transform, target.transform
	scale := ct.scale / tt.scale
	e := &app.stroke_edit
	clear(&e.points)
	clear(&e.normals)
	strength := brush_strength(app)^
	eye := camera.orbit_eye(app.camera)
	for p in curve.curve.points {
		q := p
		world := to_world(ct, p.p)
		q.p = to_local(tt, world)
		q.h_in = to_local_dir(tt, to_world_dir(ct, p.h_in)) * scale
		q.h_out = to_local_dir(tt, to_world_dir(ct, p.h_out)) * scale
		q.radius = p.radius * scale
		q.intensity = p.intensity * strength
		append(&e.points, q)
		// The surface's normal under the point, as the eye sees it; facing the eye where the
		// curve runs off the model.
		n := -linalg.normalize0(world - eye)
		if _, _, hn, ok := scene_raycast_surface(app, eye, linalg.normalize0(world - eye), skip_curves = true); ok do n = hn
		append(&e.normals, linalg.normalize0(to_local_dir(tt, n)))
	}
	if curve.curve.closed {
		// A loop is laid as an open curve through its first point again.
		q := e.points[0]
		append(&e.points, q)
		append(&e.normals, e.normals[0])
	}
	for obj, i in app.scene.objects do if obj == target do app.scene.selected = i
	app.tool = .Brush
	if !stroke_path_start(app, target) {
		clear(&e.points)
		clear(&e.normals)
		return false
	}
	r_lo, r_hi, s_lo, s_hi := max(f32), f32(0), max(f32), f32(0)
	for p in e.points do r_lo, r_hi, s_lo, s_hi = min(r_lo, p.radius), max(r_hi, p.radius), min(s_lo, p.intensity), max(s_hi, p.intensity)
	e.radius_each, e.intensity_each = r_hi > 1.01 * r_lo, s_hi > 1.01 * s_lo
	e.tilt, e.base_strength = {}, max(strength, 0.01)
	e.open, e.drag, e.stamp = true, {}, false
	e.size = app.ui.viewport_size if app.ui.viewport_size.x > 0 else {1000, 800}
	e.version, e.laid_version, e.laying = 1, 0, false
	app.curve.brush_runs += 1
	return true
}

// Starts a Dots stroke of the brush in hand on `obj` with no pointer, for a path laid by
// the stroke edit: the state stroke_start sets for a plain press, nothing laid yet.
@(private = "file")
stroke_path_start :: proc(app: ^App, obj: ^Object) -> bool {
	if !object_editable(app, obj, true) do return false
	st := &app.stroke
	st.active, st.object = true, obj.id
	st.kind, st.held = app.brush.kind, false
	st.blur = false
	st.seed, st.step, st.turn = app.stroke_seed, 0, 0
	app.stroke_seed += 1
	st.scale = 1
	st.pos, st.pressure, st.tilt, st.travel, st.size = {}, 1, {}, 0, app.ui.viewport_size
	st.dir, st.facing, st.even, st.size_scale, st.first_dir = {}, 0, 0, 0, {}
	st.last_set = false
	st.line, st.line_leaving, st.joined, st.smooth_was = false, false, false, false
	clear(&st.pending)
	clear(&st.path)
	st.stamp_set = false
	sculpt.sculptor_stroke_begin(object_sculptor(obj))
	st.mode, st.rect = .Dots, false
	st.grab, st.hook, st.cloth, st.invert = false, false, false, false
	st.hook_dir = {}
	start := app.stroke_edit.points[0].p
	st.start, st.at, st.anchor = {}, start, to_world(obj.transform, start)
	st.pivot_sum, st.pivot_count = start, 1
	return true
}
