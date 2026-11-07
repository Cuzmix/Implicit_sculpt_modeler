package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../gizmo"
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
	Guide, // a line on the surface that Quad remesh's loops follow (quad_guides), making nothing
}

@(rodata)
CURVE_USE_NAMES := [Curve_Use]string {
	.None       = "Line",
	.Tube       = "Tube",
	.Lathe      = "Lathe",
	.Along      = "Along",
	.Brush_Path = "Brush path",
	.Guide      = "Guide",
}

// The uses the settings offer, in their order.
CURVE_USES_BUILT :: [?]Curve_Use{.None, .Tube, .Lathe, .Along, .Brush_Path, .Guide}

// What Along sets along a curve: a stitch, a zipper's tooth or a ball. Copies of another
// object wait for a way to keep a curve in step with the object it copies (rebuilt when
// that object is sculpted, deleted or brought back), which reading a scene must order too.
Along_Part :: enum u8 {
	Stitch,
	Tooth,
	Sphere,
}

@(rodata)
ALONG_PART_NAMES := [Along_Part]string {
	.Stitch = "Stitch",
	.Tooth  = "Tooth",
	.Sphere = "Sphere",
}

Along_Look :: struct {
	part: Along_Part,
	opts: geom.Along_Options,
}

// Each part's own spacing and lift, as the Curve tool's Stitches and Zipper made them:
// stitches lean into each other a little and sit just proud of the surface; teeth
// alternate sides, touching.
along_preset :: proc(part: Along_Part) -> Along_Look {
	look := Along_Look{part = part, opts = geom.ALONG_DEFAULTS}
	switch part {
	case .Stitch:
		look.opts.gap, look.opts.lift = -0.1, 0.02
	case .Tooth:
		look.opts.gap, look.opts.alternate = 0, true
	case .Sphere:
	}
	return look
}

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
	along: Along_Look,
}

CURVE_LOOK_DEFAULTS :: Curve_Look{use = .None, tube = geom.TUBE_DEFAULTS, lathe = geom.LATHE_DEFAULTS, along = {part = .Stitch, opts = {gap = -0.1, lift = 0.02, up = {0, 1, 0}}}}

Curve_Part :: struct {
	points:     [dynamic]geom.Bezier_Point,
	closed:     bool,
	using look: Curve_Look,
}

// The fewest points a curve has: a curve of one point would be nothing to see or edit.
CURVE_MIN_POINTS :: 2

// Bytes a point takes in a scene file, and the options after them, about: what object_put
// reserves for a curve.
CURVE_POINT_BYTES :: 3 * size_of(Vec3) + 3 * size_of(f32) + 1
CURVE_OPTIONS_BYTES :: 4096

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
	case .Along:
		part := along_part_mesh(cp.along.part)
		defer geom.mesh_destroy(&part)
		return geom.bezier_along(cp.points[:], cp.closed, part, cp.along.opts)
	case .Tube:
		return geom.bezier_tube(cp.points[:], cp.closed, cp.tube, geom.tube_up(cp.points[:]))
	case .Lathe:
		return geom.bezier_lathe(cp.points[:], cp.closed, cp.lathe)
	}
	return {}, false
}

// The part Along sets, at width 1 (geom.bezier_along), in a new mesh.
along_part_mesh :: proc(part: Along_Part) -> geom.Mesh {
	switch part {
	case .Stitch:
		return geom.curve_stitch_part(1)
	case .Tooth:
		return geom.curve_tooth_part(1)
	case .Sphere:
		return geom.icosphere(2, 0.5)
	}
	return geom.icosphere(2, 0.5)
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
	object_release_mesh(app, obj, rebuild = false)
	ok := curve_part_attach(app, obj, cp)
	app.curve.tube_ms = time.duration_milliseconds(time.tick_since(start))
	app.curve.rebuilds += 1
	return ok
}

// A tube's options made safe to build: sides 3 to TUBE_SIDES_MAX, positive density, a
// radius of no less than zero, a profile of three points or more (the round one if not), a
// width along of two points or more (Even if not) with its points in their places.
curve_tube_clean :: proc(o: geom.Tube_Options) -> geom.Tube_Options {
	c := o
	c.sides = clamp(c.sides, 3, geom.TUBE_SIDES_MAX)
	c.one = max(c.one, 0) if c.one == c.one else geom.TUBE_DEFAULTS.one
	c.density = clamp(c.density, 0.05, 16) if c.density == c.density else 1
	if c.profile.count < 3 || c.profile.count > geom.PROFILE_POINTS_MAX do c.profile = geom.PROFILE_ROUND
	if c.width.count < geom.WIDTH_POINTS_MIN || c.width.count > geom.PROFILE_POINTS_MAX do c.width = geom.WIDTH_EVEN
	for i in 0 ..< c.width.count do geom.width_hold(&c.width, i)
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

// Along's options made safe to build: a gap of more than -0.9 (copies overlapping by no
// more than nine tenths), a lift within four widths, a unit up (the default's for none).
curve_along_clean :: proc(a: Along_Look) -> Along_Look {
	c := a
	c.opts.gap = clamp(c.opts.gap, -0.9, 10) if c.opts.gap == c.opts.gap else 0
	c.opts.lift = clamp(c.opts.lift, -4, 4) if c.opts.lift == c.opts.lift else 0
	c.opts.up = linalg.normalize0(c.opts.up) if finite(c.opts.up) else {}
	if c.opts.up == {} do c.opts.up = geom.ALONG_DEFAULTS.up
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
	look := Curve_Look{wanted.use, curve_tube_clean(wanted.tube), curve_lathe_clean(wanted.lathe), curve_along_clean(wanted.along)}
	if cp.look == look do return true
	what := "curve use" if cp.use != look.use else "tube" if cp.tube != look.tube else "lathe" if cp.lathe != look.lathe else "along"
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
curve_object_add :: proc(app: ^App, points: []geom.Bezier_Point, closed: bool, look := CURVE_LOOK_DEFAULTS, chain := false) -> bool {
	if len(points) < CURVE_MIN_POINTS do return false
	stroke_finish(app)
	bounds := geom.AABB_EMPTY
	for p in points do geom.aabb_grow(&bounds, p.p)
	middle := 0.5 * (bounds.lo + bounds.hi)
	cp := new(Curve_Part)
	cp.closed, cp.look = closed, look
	reserve(&cp.points, len(points))
	for p in points {
		q := p
		q.p -= middle
		append(&cp.points, q)
	}
	obj := new(Object)
	obj.transform, obj.file = {position = middle, scale = 1}, {scale = 1}
	if !curve_part_attach(app, obj, cp) {
		object_discard(app, obj)
		return false
	}
	scene_append(app, obj)
	obj.name = strings.clone(curve_name(app, obj.id))
	history_record_swap(app, obj.id, history_snapshot(app, nil, "add curve"), chain = chain, kind = .Curve)
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

// A curve object's fields in the scene file (curve_part_put); tags are never reused or
// retyped (geom/record.odin). The points are runs of values, one a point, so every run
// must hold as many as the positions.
Curve_Tag :: enum u16 {
	Closed    = 1,  // u8
	Use       = 2,  // u8 Curve_Use
	Points    = 3,  // Vec3 per point, required
	Handle_In = 4,  // Vec3 per point
	Handle_Out = 5, // Vec3 per point
	Radius    = 6,  // f32 per point
	Intensity = 7,  // f32 per point
	Twist     = 8,  // f32 per point
	Handles   = 9,  // u8 Handle_Type per point
	Tube      = 10, // Tube_Tag record
	Lathe     = 11, // Lathe_Tag record
	Along     = 12, // Along_Tag record
}

Tube_Tag :: enum u16 {
	Radius          = 1,  // u8 Tube_Radius
	One             = 2,  // f32
	Sides           = 3,  // u8
	Density         = 4,  // f32
	Caps            = 5,  // u8 Tube_Caps
	Profile_Count   = 6,  // u8
	Profile_Mirror  = 7,  // u8
	Profile         = 8,  // [2]f32 per profile slot, used or not
	Profile_In      = 9,  // [2]f32 per slot
	Profile_Out     = 10, // [2]f32 per slot
	Profile_Handles = 11, // u8 per slot
	Width_Count     = 12, // u8
	Width           = 13, // [2]f32 per width slot, used or not
	Width_In        = 14, // [2]f32 per slot
	Width_Out       = 15, // [2]f32 per slot
	Width_Handles   = 16, // u8 per slot
}

Lathe_Tag :: enum u16 {
	Axis     = 1, // Vec3
	Through  = 2, // u8 Lathe_Through
	Angle    = 3, // f32 degrees
	Segments = 4, // u16
	Caps     = 5, // u8
}

Along_Tag :: enum u16 {
	Part      = 1, // u8 Along_Part
	Gap       = 2, // f32
	Alternate = 3, // u8
	Lift      = 4, // f32
	Up        = 5, // Vec3
}

// Writes the curve in the levels' place of object_put, as a record: closed, the use, the
// points as runs of values, then the tube's, lathe's and Along's options.
curve_part_put :: proc(out: ^[dynamic]u8, cp: ^Curve_Part) {
	rec := geom.record_begin(out)
	defer geom.record_end(out, rec)
	geom.rec_put(out, Curve_Tag.Closed, u8(cp.closed))
	geom.rec_put(out, Curve_Tag.Use, u8(cp.use))
	n := len(cp.points)
	t := context.temp_allocator
	p, h_in, h_out := make([]Vec3, n, t), make([]Vec3, n, t), make([]Vec3, n, t)
	radius, intensity, twist := make([]f32, n, t), make([]f32, n, t), make([]f32, n, t)
	handles := make([]u8, n, t)
	for q, i in cp.points {
		p[i], h_in[i], h_out[i] = q.p, q.h_in, q.h_out
		radius[i], intensity[i], twist[i], handles[i] = q.radius, q.intensity, q.twist, u8(q.handles)
	}
	geom.rec_put_slice(out, Curve_Tag.Points, p)
	geom.rec_put_slice(out, Curve_Tag.Handle_In, h_in)
	geom.rec_put_slice(out, Curve_Tag.Handle_Out, h_out)
	geom.rec_put_slice(out, Curve_Tag.Radius, radius)
	geom.rec_put_slice(out, Curve_Tag.Intensity, intensity)
	geom.rec_put_slice(out, Curve_Tag.Twist, twist)
	geom.rec_put_slice(out, Curve_Tag.Handles, handles)
	o := cp.tube
	at := geom.rec_begin(out, Curve_Tag.Tube)
	geom.rec_put(out, Tube_Tag.Radius, u8(o.radius))
	geom.rec_put(out, Tube_Tag.One, o.one)
	geom.rec_put(out, Tube_Tag.Sides, u8(o.sides))
	geom.rec_put(out, Tube_Tag.Density, o.density)
	geom.rec_put(out, Tube_Tag.Caps, u8(o.caps))
	geom.rec_put(out, Tube_Tag.Profile_Count, u8(o.profile.count))
	geom.rec_put(out, Tube_Tag.Profile_Mirror, u8(o.profile.mirror))
	shape_put(out, o.profile.points[:], Tube_Tag.Profile, Tube_Tag.Profile_In, Tube_Tag.Profile_Out, Tube_Tag.Profile_Handles)
	geom.rec_put(out, Tube_Tag.Width_Count, u8(o.width.count))
	shape_put(out, o.width.points[:], Tube_Tag.Width, Tube_Tag.Width_In, Tube_Tag.Width_Out, Tube_Tag.Width_Handles)
	geom.rec_end(out, at)
	l := cp.lathe
	at = geom.rec_begin(out, Curve_Tag.Lathe)
	geom.rec_put(out, Lathe_Tag.Axis, l.axis)
	geom.rec_put(out, Lathe_Tag.Through, u8(l.through))
	geom.rec_put(out, Lathe_Tag.Angle, l.angle)
	geom.rec_put(out, Lathe_Tag.Segments, u16(l.segments))
	geom.rec_put(out, Lathe_Tag.Caps, u8(l.caps))
	geom.rec_end(out, at)
	a := cp.along
	at = geom.rec_begin(out, Curve_Tag.Along)
	geom.rec_put(out, Along_Tag.Part, u8(a.part))
	geom.rec_put(out, Along_Tag.Gap, a.opts.gap)
	geom.rec_put(out, Along_Tag.Alternate, u8(a.opts.alternate))
	geom.rec_put(out, Along_Tag.Lift, a.opts.lift)
	geom.rec_put(out, Along_Tag.Up, a.opts.up)
	geom.rec_end(out, at)
}

// A profile's or width's slots as four runs of values.
@(private = "file")
shape_put :: proc(out: ^[dynamic]u8, points: []geom.Profile_Point, p, h_in, h_out, handles: Tube_Tag) {
	n := len(points)
	t := context.temp_allocator
	ps, ins, outs, hs := make([][2]f32, n, t), make([][2]f32, n, t), make([][2]f32, n, t), make([]u8, n, t)
	for q, i in points do ps[i], ins[i], outs[i], hs[i] = q.p, q.h_in, q.h_out, u8(q.handles)
	geom.rec_put_slice(out, p, ps)
	geom.rec_put_slice(out, h_in, ins)
	geom.rec_put_slice(out, h_out, outs)
	geom.rec_put_slice(out, handles, hs)
}

// Reads the slots shape_put wrote into `points`, which keep their values where the file has
// none; false when a run holds another count of slots, a handle type no version wrote or
// a value that is not a number.
@(private = "file")
shape_get :: proc(rec: ^geom.Record, points: []geom.Profile_Point, p, h_in, h_out, handles: Tube_Tag) -> bool {
	n := len(points)
	t := context.temp_allocator
	if !geom.rec_has(rec, p) do return true
	ps := geom.rec_get_slice(rec, p, [2]f32, t)
	ins := geom.rec_get_slice(rec, h_in, [2]f32, t)
	outs := geom.rec_get_slice(rec, h_out, [2]f32, t)
	hs := geom.rec_get_slice(rec, handles, u8, t)
	if !rec.ok || len(ps) != n || len(ins) != n || len(outs) != n || len(hs) != n do return false
	for &q, i in points {
		q = {p = ps[i], h_in = ins[i], h_out = outs[i], handles = geom.Handle_Type(hs[i])}
		if int(hs[i]) >= len(geom.Handle_Type) || !finite({q.p.x, q.p.y, q.h_in.x}) || !finite({q.h_in.y, q.h_out.x, q.h_out.y}) do return false
	}
	return true
}

// Reads what curve_part_put wrote into a new curve on `obj`, and makes its level. `read`
// is false, with nothing made, for damage: too few points, runs of other counts, a flag,
// use or option no version wrote, or a value that is not a number. Options the file lacks
// take the defaults a new curve has. `made` is false on a GPU failure, with the curve on
// the object for object_discard.
curve_part_get :: proc(app: ^App, r: ^geom.Byte_Reader, obj: ^Object) -> (read, made: bool) {
	rec := geom.record_take(r)
	if !rec.ok do return false, false
	if known, _ := geom.record_known(&rec, Curve_Tag); !known do return false, false
	t := context.temp_allocator
	closed := geom.rec_get(&rec, Curve_Tag.Closed, u8, 0)
	use := geom.rec_get(&rec, Curve_Tag.Use, u8, 0)
	if !geom.rec_has(&rec, Curve_Tag.Points) do return false, false
	p := geom.rec_get_slice(&rec, Curve_Tag.Points, Vec3, t)
	n := len(p)
	h_in, h_out := make([]Vec3, n, t), make([]Vec3, n, t)
	radius, intensity, twist := make([]f32, n, t), make([]f32, n, t), make([]f32, n, t)
	handles := make([]u8, n, t)
	for &x in radius do x = 1
	for &x in intensity do x = 1
	geom.rec_get_into(&rec, Curve_Tag.Handle_In, h_in)
	geom.rec_get_into(&rec, Curve_Tag.Handle_Out, h_out)
	geom.rec_get_into(&rec, Curve_Tag.Radius, radius)
	geom.rec_get_into(&rec, Curve_Tag.Intensity, intensity)
	geom.rec_get_into(&rec, Curve_Tag.Twist, twist)
	geom.rec_get_into(&rec, Curve_Tag.Handles, handles)
	if !rec.ok || n < CURVE_MIN_POINTS || closed > 1 || int(use) >= len(Curve_Use) do return false, false
	for i in 0 ..< n {
		if int(handles[i]) >= len(geom.Handle_Type) || !finite(p[i]) || !finite(h_in[i]) || !finite(h_out[i]) || !finite({radius[i], intensity[i], twist[i]}) do return false, false
	}

	look := CURVE_LOOK_DEFAULTS
	look.use = Curve_Use(use)
	tr, _ := geom.rec_sub(&rec, Curve_Tag.Tube)
	o := look.tube
	radius_kind := geom.rec_get(&tr, Tube_Tag.Radius, u8, u8(o.radius))
	o.one = geom.rec_get(&tr, Tube_Tag.One, f32, o.one)
	o.sides = int(geom.rec_get(&tr, Tube_Tag.Sides, u8, u8(o.sides)))
	o.density = geom.rec_get(&tr, Tube_Tag.Density, f32, o.density)
	caps := geom.rec_get(&tr, Tube_Tag.Caps, u8, u8(o.caps))
	count := geom.rec_get(&tr, Tube_Tag.Profile_Count, u8, u8(o.profile.count))
	mirror := geom.rec_get(&tr, Tube_Tag.Profile_Mirror, u8, u8(o.profile.mirror))
	width_count := geom.rec_get(&tr, Tube_Tag.Width_Count, u8, u8(o.width.count))
	shapes_ok := shape_get(&tr, o.profile.points[:], Tube_Tag.Profile, Tube_Tag.Profile_In, Tube_Tag.Profile_Out, Tube_Tag.Profile_Handles)
	shapes_ok &&= shape_get(&tr, o.width.points[:], Tube_Tag.Width, Tube_Tag.Width_In, Tube_Tag.Width_Out, Tube_Tag.Width_Handles)
	o.profile.count, o.profile.mirror, o.width.count = int(count), mirror == 1, int(width_count)
	if !rec.ok || !tr.ok || !shapes_ok || int(width_count) < geom.WIDTH_POINTS_MIN || int(width_count) > geom.PROFILE_POINTS_MAX || count < 3 || int(count) > geom.PROFILE_POINTS_MAX || mirror > 1 || int(radius_kind) >= len(geom.Tube_Radius) || int(caps) >= len(geom.Tube_Caps) || o.sides < 3 || o.sides > geom.TUBE_SIDES_MAX || !finite({o.one, o.density, 0}) || o.one < 0 || o.density <= 0 do return false, false
	o.radius, o.caps = geom.Tube_Radius(radius_kind), geom.Tube_Caps(caps)
	look.tube = o

	lr, _ := geom.rec_sub(&rec, Curve_Tag.Lathe)
	l := look.lathe
	l.axis = geom.rec_get(&lr, Lathe_Tag.Axis, Vec3, l.axis)
	through := geom.rec_get(&lr, Lathe_Tag.Through, u8, u8(l.through))
	l.angle = geom.rec_get(&lr, Lathe_Tag.Angle, f32, l.angle)
	l.segments = int(geom.rec_get(&lr, Lathe_Tag.Segments, u16, u16(l.segments)))
	lathe_caps := geom.rec_get(&lr, Lathe_Tag.Caps, u8, u8(l.caps))
	if !rec.ok || !lr.ok || !finite(l.axis) || linalg.length(l.axis) < 1e-6 || int(through) >= len(geom.Lathe_Through) || !(l.angle >= 1 && l.angle <= 360) || l.segments < 3 || l.segments > geom.LATHE_SEGMENTS_MAX || lathe_caps > 1 do return false, false
	l.through, l.caps = geom.Lathe_Through(through), lathe_caps == 1
	look.lathe = l

	ar, _ := geom.rec_sub(&rec, Curve_Tag.Along)
	a := look.along
	part := geom.rec_get(&ar, Along_Tag.Part, u8, u8(a.part))
	a.opts.gap = geom.rec_get(&ar, Along_Tag.Gap, f32, a.opts.gap)
	alternate := geom.rec_get(&ar, Along_Tag.Alternate, u8, u8(a.opts.alternate))
	a.opts.lift = geom.rec_get(&ar, Along_Tag.Lift, f32, a.opts.lift)
	a.opts.up = geom.rec_get(&ar, Along_Tag.Up, Vec3, a.opts.up)
	if !rec.ok || !ar.ok || int(part) >= len(Along_Part) || alternate > 1 || !finite({a.opts.gap, a.opts.lift, 0}) || !finite(a.opts.up) || linalg.length(a.opts.up) < 1e-6 do return false, false
	a.part, a.opts.alternate = Along_Part(part), alternate == 1
	look.along = a

	cp := new(Curve_Part)
	cp.closed, cp.look = closed == 1, look
	reserve(&cp.points, n)
	for i in 0 ..< n {
		append(&cp.points, geom.Bezier_Point{p = p[i], h_in = h_in[i], h_out = h_out[i], radius = radius[i], intensity = intensity[i], twist = twist[i], handles = geom.Handle_Type(handles[i])})
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

// The curves Add › Curve makes, as Blender's Add › Curve and Nomad's curve primitives: a
// start for a curve that is not drawn on anything.
Curve_Shape :: enum u8 {
	None, // not a curve: Add makes the mesh shape
	Line,
	Bezier,
	Circle,
	Spiral,
	Helix,
}

@(rodata)
CURVE_SHAPE_NAMES := [Curve_Shape]string {
	.None   = "",
	.Line   = "Line",
	.Bezier = "Bézier",
	.Circle = "Circle",
	.Spiral = "Spiral",
	.Helix  = "Helix",
}

// The length of a quarter turn's handles on a circle of radius 1, so four smooth points make
// a circle to within 0.03 % (4/3 · tan(π/8)).
CURVE_CIRCLE_HANDLE :: 0.5522847

// Turns, and points a turn, of the spiral and the helix.
CURVE_SPIRAL_TURNS :: 2
CURVE_HELIX_TURNS :: 3
CURVE_TURN_POINTS :: 4

// The points of `shape` round `middle`, `size` from its middle to its edge, laid in the
// plane of `right` and `up` (the helix rising along `up`, turning toward `back`), each smooth
// with `radius`. A spiral and a helix take each handle along the curve's derivative there,
// a third of the step, as a cubic through samples of a smooth curve does.
curve_shape_points :: proc(shape: Curve_Shape, middle, right, up, back: Vec3, size, radius: f32, allocator := context.temp_allocator) -> (points: []geom.Bezier_Point, closed: bool) {
	at :: proc(middle, right, up: Vec3, size, x, y: f32) -> Vec3 {return middle + (right * x + up * y) * size}
	switch shape {
	case .None:
		return nil, false
	case .Line:
		points = make([]geom.Bezier_Point, 2, allocator)
		points[0] = {p = at(middle, right, up, size, -1, 0), h_out = right * (2 * size / 3)}
		points[1] = {p = at(middle, right, up, size, 1, 0), h_in = -right * (2 * size / 3)}
		points[0].h_in, points[1].h_out = -points[0].h_out, -points[1].h_in
	case .Bezier:
		// Blender's default: two points with handles leaning the same way, an S.
		lean := (right + up) * (size / 2)
		points = make([]geom.Bezier_Point, 2, allocator)
		points[0] = {p = at(middle, right, up, size, -1, 0), h_in = -lean, h_out = lean}
		points[1] = {p = at(middle, right, up, size, 1, 0), h_in = -lean, h_out = lean}
	case .Circle:
		closed = true
		points = make([]geom.Bezier_Point, 4, allocator)
		for &p, i in points {
			a := f32(i) * math.PI / 2
			c, s := math.cos(a), math.sin(a)
			tangent := (-right * s + up * c) * (CURVE_CIRCLE_HANDLE * size)
			p = {p = at(middle, right, up, size, c, s), h_in = -tangent, h_out = tangent}
		}
	case .Spiral:
		// Archimedean, from a tenth of the size out to all of it.
		n := CURVE_SPIRAL_TURNS * CURVE_TURN_POINTS + 1
		step := f32(2 * math.PI / CURVE_TURN_POINTS)
		grow := f32(0.9 / (CURVE_SPIRAL_TURNS * 2 * math.PI))
		points = make([]geom.Bezier_Point, n, allocator)
		for &p, i in points {
			a := f32(i) * step
			r := 0.1 + grow * a
			c, s := math.cos(a), math.sin(a)
			d := (right * (grow * c - r * s) + up * (grow * s + r * c)) * (size * step / 3)
			p = {p = at(middle, right, up, size, r * c, r * s), h_in = -d, h_out = d}
		}
	case .Helix:
		// Round `up`, rising from the bottom to the top at three fifths of the size across.
		n := CURVE_HELIX_TURNS * CURVE_TURN_POINTS + 1
		step := f32(2 * math.PI / CURVE_TURN_POINTS)
		wide: f32 = 0.6
		rise := f32(2 / (CURVE_HELIX_TURNS * 2 * math.PI))
		points = make([]geom.Bezier_Point, n, allocator)
		for &p, i in points {
			a := f32(i) * step
			c, s := math.cos(a), math.sin(a)
			pos := middle + (right * (wide * c) + back * (wide * s) + up * (rise * a - 1)) * size
			d := (right * (-wide * s) + back * (wide * c) + up * rise) * (size * step / 3)
			p = {p = pos, h_in = -d, h_out = d}
		}
	}
	for &p in points do p.radius, p.intensity = radius, 1
	return
}

// Half the size, in pixels on screen, of a curve Add › Curve makes: a fifth of the view's
// height across.
CURVE_SHAPE_PX :: 0.1

// Adds `shape` as a curve object round `at` (world space), facing the view and sized to it,
// selected, as one undo step; the Curve tool picks its last point to edit. False only when
// it could not be made.
curve_shape_add :: proc(app: ^App, shape: Curve_Shape, at: Vec3) -> bool {
	right, up, back := camera.orbit_basis(app.camera)
	size := app.ui.viewport_size
	per_px := camera.orbit_world_per_px(app.camera, at, max(size.y, 1))
	half := CURVE_SHAPE_PX * max(size.y, 1) * per_px
	radius := app.brush.radius_px * per_px * app.curve.size
	points, closed := curve_shape_points(shape, at, right, up, back, half, radius)
	if !curve_object_add(app, points, closed) do return false
	app.curve.picked = 1 if closed else len(points)
	return true
}
