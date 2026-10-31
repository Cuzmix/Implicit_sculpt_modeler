package main

import "core:math/linalg"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

// Hold to edit, as Nomad's editable strokes: a stroke ended with the pen held still on the
// screen becomes a Bézier curve fitted to its dabs, drawn over it. Its points, their handles
// and each point's radius and intensity can be dragged, a point tapped to turn it between
// smooth and corner, the curve tapped for a new point, and a point dropped on its neighbour
// merges them; after every change the stroke is put back (sculpt.sculptor_stroke_restore)
// and laid again along the curve, so it stays one stroke, one undo step. Validate keeps it
// (Enter, the context bar, or a press away from the curve, which starts the next stroke);
// Cancel (Escape, or Undo) puts the surface back with nothing recorded.
//
// The curve lives in the object's own space, so the view can turn while editing; dabs go
// straight to the surface under each point of it, never through the screen. The state is
// the app's while the stroke under way (App.stroke) stays open; brush_stroke_finish closes
// it, whoever ends the stroke.

Stroke_Edit :: struct {
	open:           bool,
	points:         [dynamic]geom.Bezier_Point, // radius in the object's units, intensity the brush's strength
	normals:        [dynamic]Vec3, // the surface's normal at each point, the object's space
	radius_each:    bool, // each point its own radius; else one for the whole stroke
	intensity_each: bool,
	tilt:           [2]f32, // the pen's lean the stroke had on average, which its dabs keep
	base_strength:  f32, // the brush's strength when the edit began: the intensity dot's scale
	// The curve changes bump version; laid_version is the one last laid. A lay under way
	// (laying) goes on from lay_at in samples, the dab spacing walked since the last dab in
	// travel, and starts again once done if the curve changed meanwhile.
	version:        int,
	laid_version:   int,
	laying:         bool,
	lay_at:         int,
	travel:         f32,
	samples:        []geom.Bezier_Sample,
	size:           [2]f32, // the viewport's size, to finish a lay when the stroke ends elsewhere
	drag:           Edit_Drag,
}

Edit_Handle :: enum u8 {
	None,
	Point,
	In,
	Out,
	Radius,
	Intensity,
	Curve, // a press on the curve between points, which adds one there on release
}

// What a press in the viewport holds while the curve is edited.
Edit_Drag :: struct {
	handle: Edit_Handle,
	index:  int,
	from:   [2]f32, // where the press was
	moved:  bool, // it went further than TAP_SLOP_PX: a drag, not a tap
	u:      f32, // Curve: where on the curve
}

// How far the pen may wander while held for Hold to edit, in viewport pixels: a hand
// holding a pen on glass drifts a pixel or two.
HOLD_SLOP_PX :: 6
// How long the pen is held still for Hold to edit, as a fresh install has it: long enough
// that a pause mid-stroke does not open it, as Nomad's.
HOLD_EDIT_DEFAULT_S :: 0.45
HOLD_EDIT_MIN_S :: 0.2
HOLD_EDIT_MAX_S :: 2
// How far a fitted curve may stray from the dabs drawn, in brush radii, as a fresh install
// has it: a hand's wobble goes, its intended swings stay.
HOLD_EDIT_SMOOTHNESS_DEFAULT :: 0.3
HOLD_EDIT_SMOOTHNESS_MAX :: 2
// A press within this of a point, handle or dot takes it, in viewport pixels: a fingertip.
EDIT_GRAB_PX :: 14
// A press and release within this is a tap.
TAP_SLOP_PX :: 5
// Where the radius and intensity dots sit off the curve's edge, and how far the intensity
// dot travels for the brush's strength as it was when the edit began.
EDIT_DOT_GAP_PX :: 16
EDIT_INTENSITY_PX :: 50
// Intensity goes up to this many times the strength the edit began with.
EDIT_INTENSITY_MAX :: 3

stroke_edit_destroy :: proc(e: ^Stroke_Edit) {
	delete(e.points)
	delete(e.normals)
	delete(e.samples)
	e^ = {}
}

// Whether the stroke under way can be held to edit: a Dots stroke laying dabs on a mesh
// whose stroke can be put back (as the Line switch needs), not a straight line nor a
// stroke joined to the last, with Hold to edit on and no take recording or playing.
stroke_edit_allowed :: proc(app: ^App) -> bool {
	st := &app.stroke
	if !app.brush.hold_edit || !st.active || app.stroke_edit.open do return false
	if st.grab || st.hook || st.cloth || st.rect || st.mode != .Dots || st.line || st.joined do return false
	if app.replay.recording || replay_busy(app) do return false
	obj := object_by_id(app, st.object)
	return obj != nil && obj.voxel == nil && !object_dynamic(obj) && len(st.path) >= 2
}

// Watches a stroke for the pen held still: once it has stayed within HOLD_SLOP_PX for
// hold_edit_s, the stroke opens for editing.
stroke_hold_watch :: proc(app: ^App, input: Viewport_Input) {
	st := &app.stroke
	if !st.active || app.stroke_edit.open do return
	now := input_clock(app)
	for s in input.samples {
		if linalg.length(s.pos - st.still_pos) > HOLD_SLOP_PX do st.still_pos, st.still_since = s.pos, now
	}
	if len(input.samples) == 0 && linalg.length(input.mouse_pos - st.still_pos) > HOLD_SLOP_PX do st.still_pos, st.still_since = input.mouse_pos, now
	if now - st.still_since < f64(clamp(app.brush.hold_edit_s, HOLD_EDIT_MIN_S, HOLD_EDIT_MAX_S)) do return
	if stroke_edit_allowed(app) do stroke_edit_begin(app, input.size)
}

// Opens the stroke under way for editing: the curve fitted to its dabs, each point taking
// the radius and strength of the dab it sits on, Each on for either that varies by more
// than a tenth, else the average for all.
stroke_edit_begin :: proc(app: ^App, size: [2]f32) {
	st := &app.stroke
	e := &app.stroke_edit
	path := st.path[:]
	at := make([]Vec3, len(path), context.temp_allocator)
	mean_radius: f32
	e.tilt = {}
	for p, i in path {
		at[i] = p.at
		mean_radius += p.radius
		e.tilt += p.tilt
	}
	mean_radius /= f32(len(path))
	e.tilt /= f32(len(path))
	smooth := clamp(app.brush.hold_edit_smoothness, 0.01, HOLD_EDIT_SMOOTHNESS_MAX)
	points, source := geom.bezier_fit(at, smooth * mean_radius, context.temp_allocator)
	if len(points) < 2 do return
	clear(&e.points)
	clear(&e.normals)
	r_lo, r_hi, s_lo, s_hi := max(f32), f32(0), max(f32), f32(0)
	r_sum, s_sum: f32
	for &p, i in points {
		src := path[source[i]]
		p.radius, p.intensity = src.radius, src.strength
		r_lo, r_hi, s_lo, s_hi = min(r_lo, p.radius), max(r_hi, p.radius), min(s_lo, p.intensity), max(s_hi, p.intensity)
		r_sum += p.radius
		s_sum += p.intensity
		append(&e.points, p)
		append(&e.normals, linalg.normalize0(src.normal))
	}
	n := f32(len(points))
	e.radius_each = r_hi > 1.1 * r_lo
	e.intensity_each = s_hi > 1.1 * s_lo
	if !e.radius_each do for &p in e.points do p.radius = r_sum / n
	if !e.intensity_each do for &p in e.points do p.intensity = s_sum / n
	e.base_strength = max(s_sum / n, 0.01)
	e.open, e.size, e.drag = true, size, {}
	app.stroke_end.edits += 1
	// The first lay replaces the drawn dabs with the curve's.
	e.version, e.laid_version, e.laying = 1, 0, false
}

// Closes the edit. With `keep` the curve is laid to its end first, so what the stroke keeps
// is the curve as it stands.
stroke_edit_close :: proc(app: ^App, keep: bool) {
	e := &app.stroke_edit
	if !e.open do return
	if keep {
		res: Sculpt_Frame_Result
		for !stroke_edit_lay(app, {size = e.size}, &res, bounded = false) {}
	}
	e.open, e.laying, e.drag = false, false, {}
	clear(&e.points)
	clear(&e.normals)
	delete(e.samples)
	e.samples = nil
}

// Keeps the edited stroke as it stands: one undo step.
stroke_edit_validate :: proc(app: ^App) {
	if app.stroke_edit.open do brush_stroke_finish(app)
}

// Puts the surface back as it was before the stroke and records nothing.
stroke_edit_cancel :: proc(app: ^App) {
	e := &app.stroke_edit
	if !e.open do return
	st := &app.stroke
	stroke_edit_close(app, keep = false)
	obj := object_by_id(app, st.object)
	if obj != nil && sculpt.sculptor_stroke_discard(object_sculptor(obj)) {
		st.active = false
		delete(st.path)
		st.path = nil
		return
	}
	// Nothing to discard by (the step holds what discarding cannot put back): the stroke is
	// put back and kept as an empty step instead.
	if obj != nil do _ = sculpt.sculptor_stroke_restore(object_sculptor(obj))
	brush_stroke_finish(app)
}

// Sets every point's radius (or intensity) to their mean, for One.
stroke_edit_set_each :: proc(app: ^App, radius: bool, each: bool) {
	e := &app.stroke_edit
	if radius do e.radius_each = each
	else do e.intensity_each = each
	if each || len(e.points) == 0 do return
	sum: f32
	for p in e.points do sum += p.radius if radius else p.intensity
	for &p in e.points {
		if radius do p.radius = sum / f32(len(e.points))
		else do p.intensity = sum / f32(len(e.points))
	}
	e.version += 1
}

// The curve sampled for laying: finer than the closest dabs, so each dab lands within a
// sliver of its spacing.
stroke_edit_sample :: proc(app: ^App) {
	e := &app.stroke_edit
	smallest := max(f32)
	for p in e.points do smallest = min(smallest, p.radius)
	delete(e.samples)
	e.samples = geom.bezier_sample(e.points[:], false, max(0.25 * dot_spacing(app) * smallest, 1e-6))
}

// Where a dab for curve sample `s` goes: the surface under it, found along the surface's
// normal there (blended between its points), or the sample itself where the ray misses.
stroke_edit_surface :: proc(app: ^App, obj: ^Object, s: geom.Bezier_Sample) -> (at, normal: Vec3) {
	e := &app.stroke_edit
	i := clamp(int(s.u), 0, len(e.normals) - 1)
	j := min(i + 1, len(e.normals) - 1)
	n := linalg.normalize0(linalg.lerp(e.normals[i], e.normals[j], s.u - f32(i)))
	if n == {} do return s.p, {}
	reach := 2 * max(s.radius, 1e-4)
	hit, hn, ok := object_raycast_local(obj, s.p + reach * n, -n)
	if ok && linalg.length(hit - s.p) <= 2 * reach do return hit, hn
	return s.p, n
}

// The camera's view and projection for a viewport `size`.
@(private = "file")
edit_view_proj :: proc(app: ^App, size: [2]f32) -> matrix[4, 4]f32 {
	return camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
}

// Where the edited curve's handles are on screen, for drawing and for hit testing.
Edit_Screen :: struct {
	point, h_in, h_out, radius, intensity: [2]f32,
	ok:                                     bool,
	radius_px:                              f32,
}

// Point `i`'s handles on screen. With One, only the first point's dots are shown (and dragging
// them sets all).
@(private = "file")
edit_screen :: proc(app: ^App, obj: ^Object, view_proj: matrix[4, 4]f32, size: [2]f32, i: int) -> (sc: Edit_Screen) {
	e := &app.stroke_edit
	t := obj.transform
	p := e.points[i]
	world := to_world(t, p.p)
	sc.point, sc.ok = gizmo.project(view_proj, world, size)
	if !sc.ok do return
	sc.h_in, _ = gizmo.project(view_proj, to_world(t, p.p + p.h_in), size)
	sc.h_out, _ = gizmo.project(view_proj, to_world(t, p.p + p.h_out), size)
	// Across the curve on screen: square to the way it runs through the point.
	way := sc.h_out - sc.h_in
	if linalg.length(way) < 1e-3 {
		k := min(i + 1, len(e.points) - 1)
		nb, _ := gizmo.project(view_proj, to_world(t, e.points[k].p), size)
		way = nb - sc.point
	}
	across := linalg.normalize0([2]f32{-way.y, way.x})
	if across == {} do across = {0, -1}
	per_px := camera.orbit_world_per_px(app.camera, world, size.y)
	sc.radius_px = p.radius * t.scale / max(per_px, 1e-12)
	sc.radius = sc.point + across * (sc.radius_px + EDIT_DOT_GAP_PX)
	sc.intensity = sc.point - across * (sc.radius_px + EDIT_DOT_GAP_PX + EDIT_INTENSITY_PX * p.intensity / e.base_strength)
	return
}

// The curve on screen as a polyline, with each vertex's place on it (u).
@(private = "file")
edit_polyline :: proc(app: ^App, obj: ^Object, view_proj: matrix[4, 4]f32, size: [2]f32) -> (line: [][2]f32, us: []f32) {
	e := &app.stroke_edit
	segs := geom.bezier_segments(len(e.points), false)
	STEPS :: 24
	line = make([][2]f32, segs * STEPS + 1, context.temp_allocator)
	us = make([]f32, segs * STEPS + 1, context.temp_allocator)
	for k in 0 ..= segs * STEPS {
		u := f32(k) / STEPS
		line[k], _ = gizmo.project(view_proj, to_world(obj.transform, geom.bezier_at(e.points[:], false, u)), size)
		us[k] = u
	}
	return
}

// Whether point `i` shows its radius and intensity dots: every point with Each, else only
// the first.
@(private = "file")
edit_shows_dot :: proc(e: ^Stroke_Edit, i: int, radius: bool) -> bool {
	each := e.radius_each if radius else e.intensity_each
	return each || i == 0
}

// What is under `pos`: a point first, then a handle, a dot, then the curve.
@(private = "file")
edit_hit :: proc(app: ^App, obj: ^Object, size, pos: [2]f32) -> (d: Edit_Drag) {
	e := &app.stroke_edit
	view_proj := edit_view_proj(app, size)
	best := f32(EDIT_GRAB_PX)
	try :: proc(d: ^Edit_Drag, best: ^f32, at, pos: [2]f32, h: Edit_Handle, i: int) {
		if l := linalg.length(at - pos); l < best^ do best^, d.handle, d.index = l, h, i
	}
	for i in 0 ..< len(e.points) {
		sc := edit_screen(app, obj, view_proj, size, i)
		if sc.ok do try(&d, &best, sc.point, pos, .Point, i)
	}
	if d.handle != .None do return
	for i in 0 ..< len(e.points) {
		sc := edit_screen(app, obj, view_proj, size, i)
		if !sc.ok do continue
		if i > 0 do try(&d, &best, sc.h_in, pos, .In, i)
		if i < len(e.points) - 1 do try(&d, &best, sc.h_out, pos, .Out, i)
		if edit_shows_dot(e, i, true) do try(&d, &best, sc.radius, pos, .Radius, i)
		if edit_shows_dot(e, i, false) do try(&d, &best, sc.intensity, pos, .Intensity, i)
	}
	if d.handle != .None do return
	line, us := edit_polyline(app, obj, view_proj, size)
	for k in 1 ..< len(line) {
		if l := gizmo.segment_distance(pos, line[k - 1], line[k]); l < best do best, d.handle, d.u = l, .Curve, 0.5 * (us[k - 1] + us[k])
	}
	return
}

// A frame while the stroke is edited: presses take what is under them and drags move it;
// a press on nothing keeps the stroke and returns false, so the press starts the next one.
// Every frame lays the curve again if it changed, as far as the frame allows.
stroke_edit_frame :: proc(app: ^App, input: Viewport_Input, res: ^Sculpt_Frame_Result) -> bool {
	e := &app.stroke_edit
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		stroke_edit_cancel(app)
		return false
	}
	if input.size.x > 0 && input.size.y > 0 do e.size = input.size
	if input.press && input.primary && e.drag.handle == .None {
		d := edit_hit(app, obj, input.size, input.mouse_pos)
		if d.handle == .None {
			stroke_edit_validate(app)
			return false
		}
		d.from = input.mouse_pos
		e.drag = d
	}
	if e.drag.handle != .None {
		if input.primary {
			if linalg.length(input.mouse_pos - e.drag.from) > TAP_SLOP_PX do e.drag.moved = true
			if e.drag.moved do edit_drag_to(app, obj, input)
		} else {
			edit_release(app, obj, input)
			e.drag = {}
		}
	}
	_ = stroke_edit_lay(app, input, res, bounded = true)
	return true
}

// Moves what the press holds to the pointer.
@(private = "file")
edit_drag_to :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	e := &app.stroke_edit
	d := &e.drag
	t := obj.transform
	i := d.index
	if d.handle == .Curve {
		// Dragging the curve between points adds a point there and takes it.
		at := geom.bezier_insert(&e.points, false, d.u)
		if at < 0 {
			d.handle = .None
			return
		}
		inject_at(&e.normals, at, linalg.normalize0(e.normals[at - 1] + e.normals[at]))
		d.handle, d.index, i = .Point, at, at
	}
	p := &e.points[i]
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	lo, ld := to_local(t, origin), to_local_dir(t, dir)
	// On the plane through the point facing the view, for handles and a point off the model.
	facing := linalg.normalize0(to_local_dir(t, camera.orbit_toward(app.camera, to_world(t, p.p))))
	plane_hit := p.p
	if den := linalg.dot(ld, facing); abs(den) > 1e-8 do plane_hit = lo + ld * (linalg.dot(p.p - lo, facing) / den)
	switch d.handle {
	case .None, .Curve:
	case .Point:
		if hit, n, ok := object_raycast_local(obj, lo, ld); ok {
			p.p, e.normals[i] = hit, linalg.normalize0(n)
		} else {
			p.p = plane_hit
		}
	case .In:
		p.h_in = plane_hit - p.p
		geom.bezier_align_handles(p, false)
	case .Out:
		p.h_out = plane_hit - p.p
		geom.bezier_align_handles(p, true)
	case .Radius, .Intensity:
		view_proj := edit_view_proj(app, input.size)
		sc := edit_screen(app, obj, view_proj, input.size, i)
		if !sc.ok do return
		dist := linalg.length(input.mouse_pos - sc.point)
		if d.handle == .Radius {
			px := max(dist - EDIT_DOT_GAP_PX, 1)
			r := px * camera.orbit_world_per_px(app.camera, to_world(t, p.p), input.size.y) / t.scale
			if e.radius_each do p.radius = r
			else do for &q in e.points do q.radius = r
		} else {
			v := clamp((dist - sc.radius_px - EDIT_DOT_GAP_PX) / EDIT_INTENSITY_PX, 0, EDIT_INTENSITY_MAX) * e.base_strength
			if e.intensity_each do p.intensity = v
			else do for &q in e.points do q.intensity = v
		}
	}
	e.version += 1
}

// The press let go: a tap on a point turns it between smooth and corner, a tap on the curve
// adds a point there, and a point dropped on its neighbour merges into it.
@(private = "file")
edit_release :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	e := &app.stroke_edit
	d := e.drag
	if !d.moved {
		#partial switch d.handle {
		case .Point:
			if e.points[d.index].corner do geom.bezier_make_smooth(e.points[:], false, d.index)
			else do geom.bezier_make_corner(e.points[:], false, d.index)
			e.version += 1
		case .Curve:
			if at := geom.bezier_insert(&e.points, false, d.u); at >= 0 {
				inject_at(&e.normals, at, linalg.normalize0(e.normals[at - 1] + e.normals[at]))
				e.version += 1
			}
		}
		return
	}
	if d.handle != .Point || len(e.points) <= 2 do return
	view_proj := edit_view_proj(app, input.size)
	me := edit_screen(app, obj, view_proj, input.size, d.index)
	neighbours := [2]int{d.index - 1, d.index + 1}
	for k in neighbours {
		if k < 0 || k >= len(e.points) do continue
		other := edit_screen(app, obj, view_proj, input.size, k)
		if !me.ok || !other.ok || linalg.length(me.point - other.point) > EDIT_GRAB_PX do continue
		// The dropped point goes; its neighbour keeps its place and takes the larger values.
		e.points[k].radius = max(e.points[k].radius, e.points[d.index].radius)
		e.points[k].intensity = max(e.points[k].intensity, e.points[d.index].intensity)
		ordered_remove(&e.points, d.index)
		ordered_remove(&e.normals, d.index)
		e.version += 1
		return
	}
}

// The curve being edited over the viewport: the curve, each point's handles, the points
// (squares smooth, diamonds corners), and the radius (white) and intensity (green) dots.
draw_stroke_edit :: proc(app: ^App, o: Overlay, size: [2]f32) {
	e := &app.stroke_edit
	if !e.open do return
	obj := object_by_id(app, app.stroke.object)
	if obj == nil do return
	view_proj := edit_view_proj(app, size)
	line, _ := edit_polyline(app, obj, view_proj, size)
	curve := overlay_color({0.4, 0.85, 1, 1})
	handle := overlay_color({0.95, 0.66, 0.23, 1})
	white := overlay_color({1, 1, 1, 0.95})
	green := overlay_color({0.18, 0.75, 0.48, 1})
	dark := overlay_color({0.04, 0.16, 0.21, 1})
	overlay_polyline(o, line, curve, 1.6 * o.scale)
	for i in 0 ..< len(e.points) {
		sc := edit_screen(app, obj, view_proj, size, i)
		if !sc.ok do continue
		if i > 0 {
			overlay_line(o, sc.point, sc.h_in, handle, 1.2 * o.scale)
			overlay_disc(o, sc.h_in, 4.5 * o.scale, handle)
		}
		if i < len(e.points) - 1 {
			overlay_line(o, sc.point, sc.h_out, handle, 1.2 * o.scale)
			overlay_disc(o, sc.h_out, 4.5 * o.scale, handle)
		}
		if edit_shows_dot(e, i, true) {
			overlay_disc(o, sc.radius, 7 * o.scale, dark)
			overlay_disc(o, sc.radius, 5.5 * o.scale, white)
		}
		if edit_shows_dot(e, i, false) {
			overlay_line(o, sc.point, sc.intensity, overlay_color({0.18, 0.75, 0.48, 0.5}), 1 * o.scale)
			overlay_disc(o, sc.intensity, 7 * o.scale, dark)
			overlay_disc(o, sc.intensity, 5.5 * o.scale, green)
		}
	}
	for p, i in e.points {
		sc := edit_screen(app, obj, view_proj, size, i)
		if !sc.ok do continue
		r := 6.5 * o.scale
		chosen := e.drag.handle == .Point && e.drag.index == i
		fill := overlay_color({1, 1, 1, 1}) if chosen else curve
		if p.corner {
			diamond := [4][2]f32{sc.point + {0, -r * 1.3}, sc.point + {r * 1.3, 0}, sc.point + {0, r * 1.3}, sc.point + {-r * 1.3, 0}}
			overlay_fill(o, diamond[:], fill)
			overlay_polyline(o, diamond[:], dark, 1.5 * o.scale, closed = true)
		} else {
			overlay_rect(o, sc.point - r, sc.point + r, 2 * o.scale, fill, dark, 1.5 * o.scale)
		}
	}
}
