package main

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../gizmo"
import "../render"
import "../sculpt"

// A curve object: cubic Bézier points that stay editable in the scene until they are
// baked, as Nomad's and Blender's curves do. Its points are in the object's own space, so
// its transform places, turns and sizes it like any object's. What it makes is its `use`:
// with Tube its one level holds the tube swept along it (geom.bezier_tube), made again
// from the points after each edit and on reading, never stored; with None the level is
// empty, as a voxel object's is, and has no GPU buffers. The overlay draws the curve's
// line over either. Brushes and mesh commands refuse a curve whatever it makes; Bake turns
// its tube into a mesh object to sculpt.

Curve_Use :: enum u8 {
	None, // drawn as a line, making nothing
	Tube,
	Lathe,
	Along,
	Brush_Path,
}

@(rodata)
CURVE_USE_NAMES := [Curve_Use]string {
	.None       = "Line",
	.Tube       = "Tube",
	.Lathe      = "Lathe",
	.Along      = "Along",
	.Brush_Path = "Brush path",
}

// The uses built so far, as the settings offer them; Along and Brush path join them as
// they come.
CURVE_USES_BUILT :: [?]Curve_Use{.None, .Tube, .Lathe}

// `obj`'s curve's look with `use` chosen. Choosing Lathe sets its axis to the view's
// vertical in the curve's space, as Nomad does, through the middle of a closed curve (a
// loop through its own first point would pinch) or the first point of an open one.
curve_use_look :: proc(app: ^App, obj: ^Object, use: Curve_Use) -> Curve_Look {
	look := obj.curve.look
	look.use = use
	if use == .Lathe && obj.curve.use != .Lathe {
		_, up, _ := camera.orbit_basis(app.camera)
		look.lathe.axis = linalg.normalize0(to_local_dir(obj.transform, up))
		look.lathe.through = .Middle if obj.curve.closed else .Start
	}
	return look
}

// What a curve makes and each use's options, kept for every use so switching back and
// forth loses nothing.
Curve_Look :: struct {
	use:   Curve_Use,
	tube:  geom.Tube_Options,
	lathe: geom.Lathe_Options,
}

CURVE_LOOK_DEFAULTS :: Curve_Look{use = .None, tube = geom.TUBE_DEFAULTS, lathe = geom.LATHE_DEFAULTS}

Curve_Part :: struct {
	points:     [dynamic]geom.Bezier_Point,
	closed:     bool,
	using look: Curve_Look,
}

// The fewest points a curve has: a curve of one point would be nothing to see or edit.
CURVE_MIN_POINTS :: 2

// Bytes a point takes in a scene file: three vectors, three numbers and the corner byte.
CURVE_POINT_BYTES :: 3 * size_of(Vec3) + 3 * size_of(f32) + 1

// Bytes the tube's options take after the points: profile, radius mode, one, sides,
// density, caps, flatness.
CURVE_TUBE_BYTES :: 4 + 3 * size_of(f32)

// Bytes the lathe's options take after the tube's: axis, through, angle, segments, caps.
CURVE_LATHE_BYTES :: size_of(Vec3) + 1 + size_of(f32) + size_of(u16) + 1

// How far, in pixels, a press may land from a curve's line on screen and pick it.
CURVE_PICK_PX :: 10

// How finely a curve is cut into straight pieces for drawing and picking, in pixels on
// screen at most.
CURVE_DRAW_PX :: 6

object_is_curve :: proc(obj: ^Object) -> bool {return obj != nil && obj.curve != nil}

// Whether `obj` has triangles to draw, upload and pick: everything but a curve making
// nothing. The GPU paths that reach for a level's buffers check this first, so a curve
// never makes buffers for an empty level.
object_draws_triangles :: proc(obj: ^Object) -> bool {
	return obj.curve == nil || len(sculpt.levels_current(&obj.levels).mesh.indices) > 0
}

// Frees the object's curve, if it has one.
curve_part_free :: proc(obj: ^Object) {
	cp := obj.curve
	if cp == nil do return
	delete(cp.points)
	free(cp)
	obj.curve = nil
}

// Gives `obj` the level its curve `cp` makes (the tube, or an empty one) and `cp` as its
// curve. Returns false on a GPU failure, with the curve on the object for the caller to
// drop.
curve_part_attach :: proc(app: ^App, obj: ^Object, cp: ^Curve_Part) -> bool {
	obj.curve = cp
	if mesh, ok := curve_part_mesh(cp); ok {
		if len(mesh.indices) > 0 do return object_build_from(app, obj, mesh, time.tick_now(), normals = true)
		geom.mesh_destroy(&mesh)
	}
	empty := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	sculpt.levels_init(&obj.levels, empty, nil, 64)
	return true
}

// The mesh `cp` makes for its use, in its own space; ok false when it makes nothing (a
// line, or a use whose shape comes to nothing, such as a lathe of a curve on its axis).
curve_part_mesh :: proc(cp: ^Curve_Part) -> (mesh: geom.Mesh, ok: bool) {
	#partial switch cp.use {
	case .Tube:
		return geom.bezier_tube(cp.points[:], cp.closed, cp.tube, geom.tube_up(cp.points[:]))
	case .Lathe:
		return geom.bezier_lathe(cp.points[:], cp.closed, cp.lathe)
	}
	return {}, false
}

// Makes the curve's level again after its points or options changed: the autosave thread
// finishes with it, the old level and buffers go once the GPU is done with them, and the
// curve makes its level anew. Returns false on a GPU failure.
curve_rebuild :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.curve
	if cp == nil do return true
	start := time.tick_now()
	autosave_settle(app)
	obj.curve = nil
	render.wait_idle(&app.renderer)
	object_release_mesh(app, obj, rebuild = false)
	ok := curve_part_attach(app, obj, cp)
	app.curve.tube_ms = time.duration_milliseconds(time.tick_since(start))
	app.curve.rebuilds += 1
	return ok
}

// A tube's options made safe to build: sides 3 to TUBE_SIDES_MAX, positive density and
// flatness, a radius of no less than zero.
curve_tube_clean :: proc(o: geom.Tube_Options) -> geom.Tube_Options {
	c := o
	c.sides = clamp(c.sides, 3, geom.TUBE_SIDES_MAX)
	c.one = max(c.one, 0) if c.one == c.one else geom.TUBE_DEFAULTS.one
	c.density = clamp(c.density, 0.05, 16) if c.density == c.density else 1
	c.flatness = clamp(c.flatness, 0.01, 1) if c.flatness == c.flatness else geom.TUBE_DEFAULTS.flatness
	return c
}

// A lathe's options made safe to build: a unit axis (the default's for none), angle 1 to
// 360, segments 3 to LATHE_SEGMENTS_MAX.
curve_lathe_clean :: proc(o: geom.Lathe_Options) -> geom.Lathe_Options {
	c := o
	c.axis = linalg.normalize0(c.axis) if finite(c.axis) else {}
	if c.axis == {} do c.axis = geom.LATHE_DEFAULTS.axis
	c.angle = clamp(c.angle, 1, 360) if c.angle == c.angle else 360
	c.segments = clamp(c.segments, 3, geom.LATHE_SEGMENTS_MAX)
	return c
}

// A Use or tube slider's drag in progress: the curve it changes and the snapshot from
// before it.
Curve_Look_Drag :: struct {
	object: int,
	before: ^Object_Snapshot,
}

// Sets what `obj`'s curve makes and its uses' options, and makes its level again, as one
// undo step; with `drag` (a slider moving) the step starts at the first change and ends
// when the slider lets go (curve_look_drag_end), as a cage's look does. Returns false
// only on a GPU failure.
object_set_curve_look :: proc(app: ^App, obj: ^Object, wanted: Curve_Look, drag := false) -> bool {
	cp := obj.curve
	look := Curve_Look{wanted.use, curve_tube_clean(wanted.tube), curve_lathe_clean(wanted.lathe)}
	if cp.look == look do return true
	what := "curve use" if cp.use != look.use else "tube" if cp.tube != look.tube else "lathe"
	ld := &app.curve.look_drag
	if drag && ld.before != nil && ld.object != obj.id do curve_look_drag_end(app, force = true)
	before: ^Object_Snapshot
	if !drag {
		before = history_snapshot(app, obj, what)
	} else if ld.before == nil {
		ld^ = {object = obj.id, before = history_snapshot(app, obj, what)}
	}
	cp.look = look
	if !curve_rebuild(app, obj) {
		if before != nil do history_snapshot_drop(before)
		return false
	}
	if before != nil do history_record_swap(app, obj.id, before, kind = .Curve)
	return true
}

// Ends a curve slider's drag as one undo step once the pointer is up (or now, with
// `force`): called each frame, and before any other scene command.
curve_look_drag_end :: proc(app: ^App, force := false) {
	ld := &app.curve.look_drag
	if ld.before == nil || (!force && .Left in app.device.down) do return
	if obj := object_by_id(app, ld.object); obj != nil && obj.curve != nil {
		history_record_swap(app, ld.object, ld.before, kind = .Curve)
	} else {
		history_snapshot_drop(ld.before)
	}
	ld^ = {}
}

// Turns `obj`'s tube into a mesh object to sculpt, as one undo step: the mesh, named as the
// curve was, takes the curve's place, folder and transform and is selected, and the curve
// goes, chained to it, so Undo brings the curve back as it was (Duplicate first keeps a
// copy). Nothing happens to a curve with no tube. Returns false only on a GPU failure.
curve_bake :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.curve
	if cp == nil || !object_draws_triangles(obj) do return true
	mesh, ok := curve_part_mesh(cp)
	if !ok do return true
	stroke_finish(app)
	// The name is copied, since the curve and its name go below.
	name := strings.clone(object_label(obj))
	defer delete(name)
	if !scene_add_mesh(app, mesh, name, {scale = 1}, obj.transform, time.tick_now()) do return false
	baked := selected_object(app)
	baked.folder = obj.folder
	scene_place_after(app, baked, obj)
	history_record_added(app)
	for o, i in app.scene.objects do if o == obj do app.scene.selected = i
	scene_delete_selected(app, chain = true)
	for o, i in app.scene.objects do if o == baked do app.scene.selected = i
	scene_selection_fix(app)
	app.curve.bakes += 1
	app.curve.picked = 0
	return true
}

// Adds a curve through `points` (world space; their handles are offsets, so they carry
// over) making `use`, as a new selected object named "Curve N" placed at their middle, as
// one undo step. Returns false, adding nothing, for fewer than CURVE_MIN_POINTS points or
// on a GPU failure.
curve_object_add :: proc(app: ^App, points: []geom.Bezier_Point, closed: bool, use := Curve_Use.None, tube := geom.TUBE_DEFAULTS) -> bool {
	if len(points) < CURVE_MIN_POINTS do return false
	stroke_finish(app)
	bounds := geom.AABB_EMPTY
	for p in points do geom.aabb_grow(&bounds, p.p)
	middle := 0.5 * (bounds.lo + bounds.hi)
	cp := new(Curve_Part)
	cp.closed, cp.look = closed, CURVE_LOOK_DEFAULTS
	cp.use, cp.tube = use, tube
	reserve(&cp.points, len(points))
	for p in points {
		q := p
		q.p -= middle
		append(&cp.points, q)
	}
	obj := new(Object)
	obj.transform, obj.file = {position = middle, scale = 1}, {scale = 1}
	if !curve_part_attach(app, obj, cp) {
		render.wait_idle(&app.renderer)
		object_discard(app, obj)
		return false
	}
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

// Writes the curve in the levels' place of object_put: the count, closed, the use, each
// point, then the tube's options field by field. A later use's settings follow these, at
// the end, where an older reader stops.
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
	o := cp.tube
	geom.byte_put(out, u8(o.profile))
	geom.byte_put(out, u8(o.radius))
	geom.byte_put(out, o.one)
	geom.byte_put(out, u8(o.sides))
	geom.byte_put(out, o.density)
	geom.byte_put(out, u8(o.caps))
	geom.byte_put(out, o.flatness)
	l := cp.lathe
	geom.byte_put(out, l.axis)
	geom.byte_put(out, u8(l.through))
	geom.byte_put(out, l.angle)
	geom.byte_put(out, u16(l.segments))
	geom.byte_put(out, u8(l.caps))
}

// Reads what curve_part_put wrote into a new curve on `obj`, and makes its level. `read`
// is false, with nothing made, for damage: too few points, more than the bytes hold, a
// flag, use or option no version wrote, a value that is not a number, or tube or lathe
// options only partly there (a curve from before them has none, and takes the defaults). `made` is
// false on a GPU failure, with the curve on the object for object_discard.
curve_part_get :: proc(app: ^App, r: ^geom.Byte_Reader, obj: ^Object) -> (read, made: bool) {
	count := int(geom.byte_get(r, u32))
	closed := geom.byte_get(r, u8)
	use := geom.byte_get(r, u8)
	if !r.ok || count < CURVE_MIN_POINTS || count > (len(r.data) - r.at) / CURVE_POINT_BYTES || closed > 1 || int(use) >= len(Curve_Use) do return false, false
	cp := new(Curve_Part)
	cp.closed, cp.look = closed == 1, CURVE_LOOK_DEFAULTS
	cp.use = Curve_Use(use)
	reserve(&cp.points, count)
	damaged := false
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
			damaged = true
			break
		}
		append(&cp.points, p)
	}
	if !damaged && r.at < len(r.data) {
		o: geom.Tube_Options
		profile, radius := geom.byte_get(r, u8), geom.byte_get(r, u8)
		o.one = geom.byte_get(r, f32)
		o.sides = int(geom.byte_get(r, u8))
		o.density = geom.byte_get(r, f32)
		caps := geom.byte_get(r, u8)
		o.flatness = geom.byte_get(r, f32)
		damaged = !r.ok || int(profile) >= len(geom.Tube_Profile) || int(radius) >= len(geom.Tube_Radius) || int(caps) >= len(geom.Tube_Caps) || o.sides < 3 || o.sides > geom.TUBE_SIDES_MAX || !finite({o.one, o.density, o.flatness}) || o.one < 0 || o.density <= 0 || o.flatness <= 0
		o.profile, o.radius, o.caps = geom.Tube_Profile(profile), geom.Tube_Radius(radius), geom.Tube_Caps(caps)
		cp.tube = o
	}
	if !damaged && r.at < len(r.data) {
		l: geom.Lathe_Options
		l.axis = geom.byte_get(r, Vec3)
		through := geom.byte_get(r, u8)
		l.angle = geom.byte_get(r, f32)
		l.segments = int(geom.byte_get(r, u16))
		caps := geom.byte_get(r, u8)
		damaged = !r.ok || !finite(l.axis) || linalg.length(l.axis) < 1e-6 || int(through) >= len(geom.Lathe_Through) || !(l.angle >= 1 && l.angle <= 360) || l.segments < 3 || l.segments > geom.LATHE_SEGMENTS_MAX || caps > 1
		l.through, l.caps = geom.Lathe_Through(through), caps == 1
		cp.lathe = l
	}
	if damaged {
		delete(cp.points)
		free(cp)
		return false, false
	}
	return true, curve_part_attach(app, obj, cp)
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
