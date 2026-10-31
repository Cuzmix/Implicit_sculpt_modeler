package main

import "core:fmt"
import "core:math/linalg"
import "core:strings"

import "../geom"
import "../gizmo"
import "../sculpt"

// A curve object: cubic Bézier points that stay editable in the scene until they are
// baked, as Nomad's and Blender's curves do. Its points are in the object's own space, so
// its transform places, turns and sizes it like any object's; its one level is empty, as
// a voxel object's is, so whatever reads the selected sculptor reads nothing, and it has
// no GPU buffers: the overlay draws it. What it makes (a tube, a lathe, copies along it, a
// brush path) is its `use`.

Curve_Use :: enum u8 {
	None, // drawn as a line, making nothing
	Tube,
	Lathe,
	Along,
	Brush_Path,
}

Curve_Part :: struct {
	points: [dynamic]geom.Bezier_Point,
	closed: bool,
	use:    Curve_Use,
}

// The fewest points a curve has: a curve of one point would be nothing to see or edit.
CURVE_MIN_POINTS :: 2

// Bytes a point takes in a scene file: three vectors, three numbers and the corner byte.
CURVE_POINT_BYTES :: 3 * size_of(Vec3) + 3 * size_of(f32) + 1

// How far, in pixels, a press may land from a curve's line on screen and pick it.
CURVE_PICK_PX :: 10

// How finely a curve is cut into straight pieces for drawing and picking, in pixels on
// screen at most.
CURVE_DRAW_PX :: 6

object_is_curve :: proc(obj: ^Object) -> bool {return obj != nil && obj.curve != nil}

// Whether `obj` has triangles to draw, upload and pick: everything but a curve. The GPU
// paths that reach for a level's buffers check this first, so a curve never makes buffers
// for its empty level.
object_draws_triangles :: proc(obj: ^Object) -> bool {return obj.curve == nil}

// Frees the object's curve, if it has one.
curve_part_free :: proc(obj: ^Object) {
	cp := obj.curve
	if cp == nil do return
	delete(cp.points)
	free(cp)
	obj.curve = nil
}

// Gives `obj` the empty level every curve object keeps and `cp` as its curve.
@(private = "file")
curve_part_attach :: proc(obj: ^Object, cp: ^Curve_Part) {
	empty := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	sculpt.levels_init(&obj.levels, empty, nil, 64)
	obj.curve = cp
}

// Adds a curve through `points` (world space; their handles are offsets, so they carry
// over) as a new selected object named "Curve N" placed at their middle, as one undo
// step. Returns false, adding nothing, for fewer than CURVE_MIN_POINTS points.
curve_object_add :: proc(app: ^App, points: []geom.Bezier_Point, closed: bool) -> bool {
	if len(points) < CURVE_MIN_POINTS do return false
	stroke_finish(app)
	bounds := geom.AABB_EMPTY
	for p in points do geom.aabb_grow(&bounds, p.p)
	middle := 0.5 * (bounds.lo + bounds.hi)
	cp := new(Curve_Part)
	cp.closed = closed
	reserve(&cp.points, len(points))
	for p in points {
		q := p
		q.p -= middle
		append(&cp.points, q)
	}
	obj := new(Object)
	obj.transform, obj.file = {position = middle, scale = 1}, {scale = 1}
	curve_part_attach(obj, cp)
	scene_append(app, obj)
	obj.name = strings.clone(curve_name(app, obj.id))
	history_record_swap(app, obj.id, history_snapshot(app, nil, "add curve"), kind = .Curve)
	app.curve.made += 1
	app.curve.picked = 0
	return true
}

// "Curve N", N one more than the curves already in the scene before it.
@(private = "file")
curve_name :: proc(app: ^App, id: int) -> string {
	n := 0
	for obj in app.scene.objects do if obj.curve != nil && obj.id != id do n += 1
	return fmt.tprintf("Curve %d", n + 1)
}

// Writes the curve in the levels' place of object_put: the count, closed, the use, then
// each point. A use's settings will follow at the end, where an older reader stops.
curve_part_put :: proc(out: ^[dynamic]u8, cp: ^Curve_Part) {
	geom.byte_put(out, u32(len(cp.points)))
	geom.byte_put(out, u8(cp.closed))
	geom.byte_put(out, u8(cp.use))
	for p in cp.points {
		geom.byte_put(out, p.p)
		geom.byte_put(out, p.h_in)
		geom.byte_put(out, p.h_out)
		geom.byte_put(out, p.radius)
		geom.byte_put(out, p.intensity)
		geom.byte_put(out, p.twist)
		geom.byte_put(out, u8(p.corner))
	}
}

// Reads what curve_part_put wrote into a new curve on `obj`, with its empty level. False,
// with nothing made, for damage: too few points, more than the bytes hold, a flag or use
// no version wrote, or a value that is not a number.
curve_part_get :: proc(r: ^geom.Byte_Reader, obj: ^Object) -> bool {
	count := int(geom.byte_get(r, u32))
	closed := geom.byte_get(r, u8)
	use := geom.byte_get(r, u8)
	if !r.ok || count < CURVE_MIN_POINTS || count > (len(r.data) - r.at) / CURVE_POINT_BYTES || closed > 1 || int(use) >= len(Curve_Use) do return false
	cp := new(Curve_Part)
	cp.closed, cp.use = closed == 1, Curve_Use(use)
	reserve(&cp.points, count)
	for _ in 0 ..< count {
		p: geom.Bezier_Point
		p.p = geom.byte_get(r, Vec3)
		p.h_in = geom.byte_get(r, Vec3)
		p.h_out = geom.byte_get(r, Vec3)
		p.radius = geom.byte_get(r, f32)
		p.intensity = geom.byte_get(r, f32)
		p.twist = geom.byte_get(r, f32)
		corner := geom.byte_get(r, u8)
		p.corner = corner == 1
		if !r.ok || corner > 1 || !finite(p.p) || !finite(p.h_in) || !finite(p.h_out) || !finite({p.radius, p.intensity, p.twist}) {
			delete(cp.points)
			free(cp)
			return false
		}
		append(&cp.points, p)
	}
	curve_part_attach(obj, cp)
	return true
}

// The curve of `obj` cut into points on screen (viewport pixels), at most CURVE_DRAW_PX
// apart where it faces the view; nil when any of it is behind the eye.
curve_screen_line :: proc(app: ^App, obj: ^Object, size: [2]f32, allocator := context.temp_allocator) -> [][2]f32 {
	cp := obj.curve
	if cp == nil || len(cp.points) < CURVE_MIN_POINTS do return nil
	t := obj.transform
	view_proj := edit_view_proj(app, size)
	// The spacing from the curve's length on screen between its points, so a far curve
	// is not cut into thousands of pieces.
	length_px: f32
	prev: [2]f32
	for p, i in cp.points {
		at, ok := gizmo.project(view_proj, to_world(t, p.p), size)
		if !ok do return nil
		if i > 0 do length_px += linalg.length(at - prev)
		prev = at
	}
	length := geom.bezier_length(cp.points[:], cp.closed)
	if !(length > 0) do return nil
	pieces := clamp(int(length_px * 1.5 / CURVE_DRAW_PX) + 8, 8, 4096)
	samples := geom.bezier_sample(cp.points[:], cp.closed, length / f32(pieces), context.temp_allocator)
	line := make([dynamic][2]f32, 0, len(samples), allocator)
	for s in samples {
		at, ok := gizmo.project(view_proj, to_world(t, s.p), size)
		if !ok {
			delete(line)
			return nil
		}
		append(&line, at)
	}
	return line[:]
}

// The index of the shown, unlocked curve whose line passes nearest `pos` within
// CURVE_PICK_PX, or -1.
curve_pick :: proc(app: ^App, pos, size: [2]f32) -> int {
	best, found := f32(CURVE_PICK_PX), -1
	for obj, i in app.scene.objects {
		if obj.curve == nil || !object_shown(app, obj) || obj.locked || obj.ghost do continue
		line := curve_screen_line(app, obj, size)
		for k in 1 ..< len(line) {
			if d := gizmo.segment_distance(pos, line[k - 1], line[k]); d < best do best, found = d, i
		}
	}
	return found
}

// Draws every shown curve as its line: white, brighter and wider when selected, its
// points as small squares then; a ghost faintly.
draw_curve_objects :: proc(app: ^App, o: Overlay, size: [2]f32) {
	selected := selected_object(app)
	for obj in app.scene.objects {
		if obj.curve == nil || !object_shown(app, obj) do continue
		line := curve_screen_line(app, obj, size)
		if len(line) < 2 do continue
		chosen := obj == selected
		alpha: f32 = 0.35 if obj.ghost else (1 if chosen else 0.7)
		dark := overlay_color({0.04, 0.06, 0.08, 0.6 * alpha})
		overlay_polyline(o, line, dark, (4 if chosen else 3) * o.scale, obj.curve.closed)
		color := overlay_color({0.4, 0.85, 1, alpha} if chosen else {1, 1, 1, alpha})
		overlay_polyline(o, line, color, (2 if chosen else 1.5) * o.scale, obj.curve.closed)
		if !chosen do continue
		view_proj := edit_view_proj(app, size)
		half := 3.5 * o.scale
		for p in obj.curve.points {
			at, ok := gizmo.project(view_proj, to_world(obj.transform, p.p), size)
			if !ok do continue
			overlay_rect(o, at - half, at + half, 1 * o.scale, overlay_color({1, 1, 1, 1}), dark, 1 * o.scale)
		}
	}
}

// The curves in the scene and their points in all, for the exit stats.
curve_counts :: proc(app: ^App) -> (curves, points: int) {
	for obj in app.scene.objects do if cp := obj.curve; cp != nil {
		curves += 1
		points += len(cp.points)
	}
	return
}
