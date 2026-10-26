package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../sculpt"
import "../ui"

// The Curve and Insert tools, after ZBrush's curve brushes and insert mesh brushes. A
// Curve drag over the surface makes, on release, a new object along the path: a tube,
// a row of stitches or a zipper. An Insert click puts a shape (a primitive, or a copy of
// any object) on the surface there, standing on the surface's normal; dragging first
// sizes it. Each makes a new object, one undo step, which Insert can mark for the
// booleans straight away (a cylinder marked Subtract drills a hole).

Curve_Kind :: enum u8 {
	Tube,
	Stitches,
	Zipper,
}

Curve_Tool :: struct {
	kind:   Curve_Kind,
	size:   f32, // the tube's width, or the stitches' or zipper's, over the brush's diameter
	lift:   f32, // the tube's middle out from the surface, over its radius (1 rests on it)
	sides:  i32, // round the tube
	// A drag in progress: the path on the surface (world space) and on screen.
	active: bool,
	points: [dynamic]geom.Curve_Point,
	screen: [dynamic][2]f32,
	radius: f32, // the brush's radius in world units where the path began
}

Insert_Tool :: struct {
	shape:    geom.Primitive,
	object:   int, // id of the object to insert copies of; 0 inserts `shape`
	vertices: i32,
	sink:     f32, // how far into the surface, over the inserted shape's half size
	mode:     Boolean_Mode, // what the new object is marked for the booleans
	// A press in progress: where on the surface, and the size dragged so far.
	active:   bool,
	at:       Vec3,
	normal:   Vec3,
	start:    [2]f32,
	px:       f32,
	per_px:   f32, // world units a pixel covers at `at`
}

CURVE_DEFAULTS :: Curve_Tool{size = 0.5, lift = 0.5, sides = 12}
INSERT_DEFAULTS :: Insert_Tool{shape = .Sphere, vertices = 20_000, sink = 0.3}

curve_tool_destroy :: proc(c: ^Curve_Tool) {
	delete(c.points)
	delete(c.screen)
}

// The nearest surface along the ray, with the triangle's normal there, in world space.
scene_raycast_surface :: proc(app: ^App, origin, dir: Vec3) -> (index: int, hit, normal: Vec3, ok: bool) {
	best := max(f32)
	for obj, i in app.scene.objects {
		if !object_pickable(app, obj) do continue
		t := obj.transform
		s := object_sculptor(obj)
		lo, ld := to_local(t, origin), to_local_dir(t, dir)
		d, tri, found := geom.bvh_raycast(&s.bvh, s.mesh^, lo, ld, sculpt.sculptor_hidden_tris(s))
		if !found do continue
		world := to_world(t, lo + d * ld)
		if dist := linalg.length(world - origin); dist < best {
			m := s.mesh^
			a, b, c := m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]
			best, index, hit, ok = dist, i, world, true
			normal = linalg.normalize0(to_world_dir(t, linalg.cross(b - a, c - a)))
		}
	}
	return
}

// Follows a Curve drag; on release makes its object. Returns false only on a GPU failure.
curve_tool_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	c := &app.curve
	if input.primary {
		if input.press {
			c.active = true
			clear(&c.points)
			clear(&c.screen)
		}
		if c.active do curve_add_point(app, input.mouse_pos, input.size)
		return true
	}
	if !c.active do return true
	c.active = false
	return curve_make(app)
}

// Adds the surface point under `pos` (a viewport point) to the path, when there is one
// far enough from the last.
curve_add_point :: proc(app: ^App, pos, size: [2]f32) {
	c := &app.curve
	origin, dir := mouse_ray(app.camera, pos, size)
	_, hit, n, ok := scene_raycast_surface(app, origin, dir)
	if !ok do return
	if len(c.points) == 0 do c.radius = app.brush.radius_px * camera.orbit_world_per_px(app.camera, hit, size.y)
	if len(c.points) > 0 && linalg.length(hit - c.points[len(c.points) - 1].p) < 0.05 * c.radius do return
	append(&c.points, geom.Curve_Point{hit, n})
	append(&c.screen, pos)
}

// Makes the object along the path drawn. Returns false only on a GPU failure.
curve_make :: proc(app: ^App) -> bool {
	c := &app.curve
	defer {
		clear(&c.points)
		clear(&c.screen)
	}
	width := 2 * c.radius * c.size
	if len(c.points) < 2 || !(width > 0) do return true
	start := time.tick_now()
	mesh: geom.Mesh
	made: bool
	switch c.kind {
	case .Tube:
		r := width / 2
		sides := int(clamp(c.sides, 3, 64))
		path := geom.curve_resample(c.points[:], 2 * 3.14159 * r / f32(sides), 3, context.temp_allocator)
		mesh, made = geom.curve_tube(path, r, c.lift * r, sides)
	case .Stitches, .Zipper:
		stitch := c.kind == .Stitches
		path := geom.curve_resample(c.points[:], width * (0.6 if stitch else 0.28), 3, context.temp_allocator)
		part := geom.curve_stitch_part(width) if stitch else geom.curve_tooth_part(width)
		defer geom.mesh_destroy(&part)
		mesh, made = geom.curve_place(path, part, 0.02 * width if stitch else 0, alternate = !stitch)
	}
	free_all(context.temp_allocator)
	if !made {
		log.warn("curve: the path is too short for its width")
		return true
	}
	return add_made_object(app, &mesh, fmt.tprintf("%v", c.kind), .None, start)
}

// Adds `mesh` (in world space) as a new object around its middle, selected, as one undo
// step, marked `mode`. Returns false only on a GPU failure.
@(private = "file")
add_made_object :: proc(app: ^App, mesh: ^geom.Mesh, label: string, mode: Boolean_Mode, start: time.Tick) -> bool {
	bounds := geom.AABB_EMPTY
	for p in mesh.positions do geom.aabb_grow(&bounds, p)
	middle := 0.5 * (bounds.lo + bounds.hi)
	for &p in mesh.positions do p -= middle
	stroke_finish(app)
	name := fmt.aprintf("%s %d", label, app.scene.next_id + 1)
	defer delete(name)
	if !scene_add_mesh(app, mesh^, name, {scale = 1}, {position = middle, scale = 1}, start) do return false
	selected_object(app).boolean = mode
	history_record_added(app)
	log.infof("%s: %d vertices in %.0f ms", name, len(mesh.positions), time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Follows an Insert press; on release puts the shape there. Returns false only on a GPU
// failure.
insert_tool_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	s := &app.insert
	if input.primary {
		if input.press {
			origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
			_, hit, n, ok := scene_raycast_surface(app, origin, dir)
			s.active = ok && n != {}
			if s.active {
				s.at, s.normal, s.start = hit, n, input.mouse_pos
				s.per_px = camera.orbit_world_per_px(app.camera, hit, input.size.y)
			}
		}
		// A drag sizes it; a click takes the brush's size.
		if s.active {
			dragged := linalg.length(input.mouse_pos - s.start)
			s.px = dragged if dragged > 4 else app.brush.radius_px
		}
		return true
	}
	if !s.active do return true
	s.active = false
	return insert_make(app, s.at, s.normal, s.px * s.per_px)
}

// Puts the Insert shape on the surface at `at`, its up (+y) along `normal`, `half` its
// half size, sunk in by Sink. Returns false only on a GPU failure.
insert_make :: proc(app: ^App, at, normal: Vec3, half: f32) -> bool {
	s := &app.insert
	start := time.tick_now()
	source: geom.Mesh
	label: string
	if src := object_by_id(app, s.object); src != nil {
		if object_dynamic(src) {
			mask: []u8
			source, mask = sculpt.sculptor_compact_mesh(object_sculptor(src))
			delete(mask)
		} else {
			m := object_mesh(src)^
			source = {
				positions = make([dynamic]geom.Vec3, len(m.positions)),
				indices   = make([dynamic]u32, len(m.indices)),
				normals   = make([dynamic]geom.Vec3, len(m.positions)),
			}
			copy(source.positions[:], m.positions[:])
			copy(source.indices[:], m.indices[:])
		}
		label = fmt.tprintf("%s insert", object_label(src))
	} else {
		made: bool
		source, made = geom.primitive(s.shape, int(s.vertices), &app.pool)
		if !made do return true
		label = fmt.tprintf("Insert %v", s.shape)
	}
	// Fits it in a cube of `half` either way, standing on the normal: x along the view's
	// right where it can be, so a shape turns with the view the way it was seen.
	bounds := geom.AABB_EMPTY
	for p in source.positions do geom.aabb_grow(&bounds, p)
	middle := 0.5 * (bounds.lo + bounds.hi)
	extent := 0.5 * (bounds.hi - bounds.lo)
	fit := half / max(extent.x, extent.y, extent.z, 1e-6)
	view := camera.orbit_view(app.camera)
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	x := right - linalg.dot(right, normal) * normal
	x = linalg.normalize(x) if linalg.length(x) > 1e-3 else geom.any_square_to(normal)
	z := linalg.cross(x, normal)
	base := at - normal * (s.sink * half)
	for &p in source.positions {
		q := (p - middle) * fit
		p = base + q.x * x + q.y * normal + q.z * z
	}
	// The label is in temp memory, which building the object frees after naming it.
	return add_made_object(app, &source, label, s.mode, start)
}

// Draws the curve being drawn, or the size of the shape being inserted.
draw_curve_overlay :: proc(app: ^App, o: Overlay) {
	color := overlay_color({0.4, 0.85, 1, 1})
	if c := &app.curve; c.active && len(c.screen) >= 2 do overlay_polyline(o, c.screen[:], color, 2)
	if s := &app.insert; s.active do overlay_circle(o, s.start, s.px, color, 1.5)
}

// The Curve tool's settings in the interface.
kit_curve_settings :: proc(app: ^App) {
	ctx := &app.kit.ctx
	c := &app.curve
	kinds: [len(Curve_Kind)]string
	for kind, i in Curve_Kind do kinds[i] = fmt.tprint(kind)
	if picked := ui.tabs(ctx, "curve kind", kinds[:], int(c.kind)); picked >= 0 do c.kind = Curve_Kind(picked)
	_ = ui.slider(ctx, "Width", &c.size, 0.05, 2, .Logarithmic, fmt.tprintf("%.2f x brush", c.size))
	if c.kind == .Tube {
		_ = ui.slider(ctx, "Lift", &c.lift, -1, 2, .Linear, fmt.tprintf("%.2f radius", c.lift))
		sides := f32(c.sides)
		if ui.slider(ctx, "Sides", &sides, 3, 64, .Linear, fmt.tprintf("%d", c.sides)) do c.sides = i32(sides + 0.5)
	}
}

// The Insert tool's settings in the interface: a shape, or a copy of an object.
kit_insert_settings :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	s := &app.insert
	src := object_by_id(app, s.object)
	names := make([dynamic]string, context.temp_allocator)
	for p in geom.Primitive do append(&names, fmt.tprint(p))
	chosen := int(s.shape)
	for obj, i in app.scene.objects {
		append(&names, fmt.tprintf("Copy of %s##%d", object_label(obj), obj.id))
		if obj == src do chosen = len(geom.Primitive) + i
	}
	if picked := ui.select(ctx, "insert shape", names[:], chosen); picked >= 0 {
		if picked < len(geom.Primitive) {
			s.shape, s.object = geom.Primitive(picked), 0
		} else {
			s.object = app.scene.objects[picked - len(geom.Primitive)].id
		}
	}
	_ = kit_count(ctx, "Vertices", &s.vertices, 500, 2_000_000)
	_ = ui.slider(ctx, "Sink", &s.sink, -1, 1, .Linear, fmt.tprintf("%.2f", s.sink))
	ui.label(ctx, "Mark it as", t.small_size)
	modes: [len(Boolean_Mode)]string
	for m, i in Boolean_Mode do modes[i] = fmt.tprint(m)
	if picked := ui.tabs(ctx, "insert mark", modes[:], int(s.mode)); picked >= 0 do s.mode = Boolean_Mode(picked)
}
