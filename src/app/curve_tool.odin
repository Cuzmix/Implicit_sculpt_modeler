package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../gizmo"
import "../poly"
import "../sculpt"
import "../ui"
import "../voxel"

// The Curve and Insert tools, after ZBrush's curve brushes and insert mesh brushes. A
// Curve drag over the surface makes, on release, a new object along the path: a tube,
// a row of stitches or a zipper. An Insert click puts a shape (a primitive, or a copy of
// any object) on the surface there, standing on the surface's normal; dragging first
// sizes it. Each makes a new object, one undo step, which Insert can mark for the
// booleans straight away (a cylinder marked Subtract drills a hole).

Curve_Kind :: enum u8 {
	Curve, // a curve object, editable until baked (curve_object.odin)
	Tube, // a curve whose use is Tube
	Stitches, // a curve whose use is Along, stitches
	Zipper, // a curve whose use is Along, alternate teeth
}

// Where the Curve tool's points land, as Blender's Draw tool's depth and the drawing planes
// of Feather and Gravity Sketch: a pen on glass has no depth, so the plane gives it one.
// Each plane but Surface passes through an anchor: the view's centre for a curve's first
// point (on the floor grid's height for Floor), then the point before, so a curve stays on
// one plane; dragging a point moves it on the plane through where it is.
Curve_Plane :: enum u8 {
	Surface, // on the model under the pen, else the plane facing the view
	View, // facing the view
	Floor, // level, square to Y
	Front, // upright, square to Z
	Side, // upright, square to X
}

@(rodata)
CURVE_PLANE_NAMES := [Curve_Plane]string {
	.Surface = "Surface",
	.View    = "View",
	.Floor   = "Floor",
	.Front   = "Front",
	.Side    = "Side",
}

Curve_Tool :: struct {
	kind:   Curve_Kind,
	plane:  Curve_Plane,
	size:   f32, // the tube's width, or the stitches' or zipper's, over the brush's diameter
	lift:   f32, // the tube's middle out from the surface, over its radius (1 rests on it)
	sides:  i32, // round the tube
	// A drag in progress: the path on the surface (world space) and on screen.
	active: bool,
	points: [dynamic]geom.Curve_Point,
	screen: [dynamic][2]f32,
	radius: f32, // the brush's radius in world units where the path began
	// Points tapped one by one for a curve (world space), until Enter, Done or a tap on the
	// first point ends it.
	placing: [dynamic]Vec3,
	placing_n: [dynamic]Vec3, // the surface's normal under each, for a tube's lift
	made:    int, // curve objects made, for the exit stats
	// Tubes made again after an edit, and how long the last took, for the exit stats.
	rebuilds: int,
	tube_ms:  f64,
	bakes:    int,
	// Editing the selected curve (curve_edit.odin): the press under way, the point picked
	// for the context bar (from 1; 0 for none) and edits made, for the exit stats.
	drag:    Curve_Drag,
	picked:  int,
	edits:   int,
	// The Edit tab (Tab): a press on empty space drags a box that picks points rather than
	// drawing a new curve. `box` is that drag; `tap` the last tap on a point, for a double
	// tap; `all_handles` shows every point's handles rather than the picked points' and
	// their neighbours'.
	editing:     bool,
	box:         Curve_Box,
	tap:         Curve_Tap,
	all_handles: bool,
	// A move, turn or scale of the picked points by the gizmo or G, R or S (curve_gizmo.odin),
	// and the pointer's last place over the view, where a key's move starts.
	xform:   Curve_Xform,
	pointer: [2]f32,
	// A Use or tube slider's drag on the selected curve, one undo step when it lets go.
	look_drag: Curve_Look_Drag,
	brush_runs: int, // Run brush along a curve (curve_brush.odin), for the exit stats
	// Pipe, Lathe and Loft cages made from curves (curve_cage.odin): their rings and steps,
	// and how many were made and how many of them lofts, for the exit stats.
	cage:       poly.Curve_Cage_Options,
	cages:      int,
	lofts:      int,
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

CURVE_DEFAULTS :: Curve_Tool{size = 0.5, lift = 0.5, sides = 12, cage = poly.CURVE_CAGE_DEFAULTS}
INSERT_DEFAULTS :: Insert_Tool{shape = .Sphere, vertices = 20_000, sink = 0.3}

curve_tool_destroy :: proc(c: ^Curve_Tool) {
	delete(c.points)
	delete(c.screen)
	delete(c.placing)
	delete(c.placing_n)
	if c.drag.before != nil do history_snapshot_drop(c.drag.before)
	if c.xform.before != nil do history_snapshot_drop(c.xform.before)
	delete(c.xform.start)
}

// The nearest surface along the ray, with the triangle's normal there, in world space.
// With `skip_curves`, a curve's tube is passed through, so a curve drawn or edited never
// lands on a tube, its own above all. With `only`, that object alone is looked for.
scene_raycast_surface :: proc(app: ^App, origin, dir: Vec3, skip_curves := false, only := -1) -> (index: int, hit, normal: Vec3, ok: bool) {
	best := max(f32)
	for obj, i in app.scene.objects {
		if (only >= 0 && i != only) || !object_pickable(app, obj) || (skip_curves && obj.curve != nil) do continue
		t := obj.transform
		s := object_sculptor(obj)
		lo, ld := to_local(t, origin), to_local_dir(t, dir)
		if vp := obj.voxel; vp != nil {
			// The clay's surface, with the field's gradient for the normal.
			local_hit, local_normal, on := voxel.clay_raycast(&vp.clay, lo, ld)
			if !on do continue
			world := to_world(t, local_hit)
			if dist := linalg.length(world - origin); dist < best {
				best, index, hit, ok = dist, i, world, true
				normal = linalg.normalize0(to_world_dir(t, local_normal))
			}
			continue
		}
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

// How near to edge on, as the cosine between the eye's ray and a plane, a plane may be
// seen and still take points: nearer, a point would land far off, so it lands on the plane
// facing the view through the anchor instead.
CURVE_PLANE_GRAZE :: 0.05

// The plane `plane` through `anchor` (world space): a point on it and its normal, turned
// toward the viewer. Surface's plane, for points off the model, faces the view: square to
// the view's direction, so it lies flat to the screen wherever the anchor is.
curve_plane_at :: proc(app: ^App, plane: Curve_Plane, anchor: Vec3) -> (at, normal: Vec3) {
	toward := camera.orbit_toward(app.camera, app.camera.target)
	at = anchor
	switch plane {
	case .Surface, .View:
		normal = -toward
	case .Floor:
		normal = {0, 1, 0}
	case .Front:
		normal = {0, 0, 1}
	case .Side:
		normal = {1, 0, 0}
	}
	if linalg.dot(normal, toward) > 0 do normal = -normal
	return
}

// Where the ray from `origin` along `dir` meets `plane` through `anchor`, with the plane's
// normal toward the viewer. A plane seen edge on gives way to the one facing the view
// through the anchor; false only when the ray runs away from that too.
curve_plane_hit :: proc(app: ^App, origin, dir: Vec3, plane: Curve_Plane, anchor: Vec3) -> (p, normal: Vec3, ok: bool) {
	at, n := curve_plane_at(app, plane, anchor)
	if abs(linalg.dot(dir, n)) < CURVE_PLANE_GRAZE do at, n = curve_plane_at(app, .View, anchor)
	den := linalg.dot(dir, n)
	if abs(den) < 1e-6 do return
	t := linalg.dot(at - origin, n) / den
	if t <= 0 do return
	return origin + dir * t, n, true
}

// The anchor of a curve's first point: the view's centre, on the floor grid's height for
// Floor, so a first point lands where the grid shows.
curve_first_anchor :: proc(app: ^App) -> Vec3 {
	at := app.camera.target
	if app.curve.plane == .Floor {
		bounds := app.floor_state.bounds if app.floor_state.key != 0 else floor_scene_bounds(app)
		at.y = floor_grid_place(bounds, camera.orbit_eye(app.camera), app.floor).at[1]
	}
	return at
}

// The anchor of the next point placed by taps: the last one placed, or the first anchor.
curve_next_anchor :: proc(app: ^App) -> Vec3 {
	c := &app.curve
	return c.placing[len(c.placing) - 1] if len(c.placing) > 0 else curve_first_anchor(app)
}

// Where a point of the Curve tool lands under `pos` (a viewport point): on the model under
// it with Surface, else on the Draw on plane through `anchor`; with the surface's normal
// there, or the plane's toward the viewer.
curve_land :: proc(app: ^App, pos, size: [2]f32, anchor: Vec3) -> (p, normal: Vec3, ok: bool) {
	origin, dir := mouse_ray(app.camera, pos, size)
	if app.curve.plane == .Surface {
		if _, hit, n, on := scene_raycast_surface(app, origin, dir, skip_curves = true); on do return hit, n, true
	}
	return curve_plane_hit(app, origin, dir, app.curve.plane, anchor)
}

// Follows a Curve drag; on release makes its object. Returns false only on a GPU failure.
curve_tool_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	c := &app.curve
	if input.hovered do c.pointer = input.mouse_pos
	// The picked points' gizmo, or a G, R or S under way, before anything else.
	if !c.active && c.drag.handle == .None && !c.box.active && curve_xform_frame(app, input) do return true
	// A press on the selected curve's points, handles or line edits it instead.
	if !c.active && curve_edit_frame(app, input) do return true
	// In the Edit tab a press on empty space drags a box that picks points.
	if c.editing && !c.active && len(c.placing) == 0 {
		if obj := selected_curve(app); obj != nil {
			curve_box_frame(app, obj, input)
			return true
		}
	}
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
	curve_drawn(app, input.mouse_pos, input.size)
	return true
}

// Makes a curve object of `points` for the tool's kind: Tube lifts the points along the
// surface's normals by Lift radii and sweeps a tube of the tool's sides along them;
// Stitches and Zipper set the Along use's presets with the surface's normal at the first
// point as the copies' up.
@(private = "file")
curve_kind_add :: proc(app: ^App, points: []geom.Bezier_Point, normals: []Vec3, closed: bool) {
	c := &app.curve
	look := CURVE_LOOK_DEFAULTS
	switch c.kind {
	case .Curve:
	case .Tube:
		for &p, i in points do p.p += normals[i] * (c.lift * p.radius)
		look.use = .Tube
		look.tube.one = c.radius * c.size
		look.tube.sides = int(clamp(c.sides, 3, geom.TUBE_SIDES_MAX))
	case .Stitches, .Zipper:
		look.use = .Along
		look.along = along_preset(.Stitch if c.kind == .Stitches else .Tooth)
		if len(normals) > 0 do look.along.opts.up = normals[0]
	}
	_ = curve_object_add(app, points, closed, look)
}

// How far a press may move on screen and still be a tap that places a point.
CURVE_TAP_PX :: 6

// How closely a freehand curve follows the path drawn, as a share of the brush's radius:
// more keeps fewer points.
CURVE_FIT_TOLERANCE :: 0.25

// Ends a press of the Curve kind at `pos`: a drag becomes a curve object fitted to its
// path; a tap places a point, and a tap on the first of three or more closes the curve.
curve_drawn :: proc(app: ^App, pos, size: [2]f32) {
	c := &app.curve
	defer {
		clear(&c.points)
		clear(&c.screen)
	}
	travel: f32
	for i in 1 ..< len(c.screen) do travel += linalg.length(c.screen[i] - c.screen[i - 1])
	if len(c.points) >= 2 && travel > CURVE_TAP_PX {
		path := make([]Vec3, len(c.points), context.temp_allocator)
		for p, i in c.points do path[i] = p.p
		points, source := geom.bezier_fit(path, CURVE_FIT_TOLERANCE * c.radius, context.temp_allocator)
		normals := make([]Vec3, len(points), context.temp_allocator)
		for &p, i in points {
			p.radius, p.intensity = c.radius * c.size, 1
			normals[i] = c.points[source[i]].n
		}
		curve_kind_add(app, points, normals, false)
		clear(&c.placing)
		clear(&c.placing_n)
		return
	}
	// A tap on the first point placed closes the curve.
	if len(c.placing) >= 3 {
		view_proj := edit_view_proj(app, size)
		if first, ok := gizmo.project(view_proj, c.placing[0], size); ok && linalg.length(first - pos) < CURVE_PICK_PX {
			curve_place_finish(app, true)
			return
		}
	}
	if hit, n, ok := curve_land(app, pos, size, curve_next_anchor(app)); ok {
		if len(c.placing) == 0 do c.radius = app.brush.radius_px * camera.orbit_world_per_px(app.camera, hit, size.y)
		append(&c.placing, hit)
		append(&c.placing_n, n)
	}
}

// Makes the points placed one by one into a curve object (closed or not), smooth through
// each as a Catmull-Rom spline is: each handle a sixth of the way between its neighbours.
// Fewer than two points make nothing. Enter ends an open curve.
curve_place_finish :: proc(app: ^App, closed: bool) {
	c := &app.curve
	defer {
		clear(&c.placing)
		clear(&c.placing_n)
	}
	n := len(c.placing)
	if n < 2 do return
	points := make([]geom.Bezier_Point, n, context.temp_allocator)
	for p, i in c.placing {
		prev := c.placing[(i + n - 1) % n] if closed || i > 0 else p
		next := c.placing[(i + 1) % n] if closed || i < n - 1 else p
		way := (next - prev) / 6
		points[i] = {p = p, h_in = -way, h_out = way, radius = c.radius * c.size, intensity = 1}
	}
	curve_kind_add(app, points, c.placing_n[:], closed)
}

// Adds the point under `pos` (a viewport point) to the path, where it lands (curve_land),
// when it is far enough from the last. A drag keeps to the plane through its first point.
curve_add_point :: proc(app: ^App, pos, size: [2]f32) {
	c := &app.curve
	anchor := c.points[0].p if len(c.points) > 0 else curve_next_anchor(app)
	hit, n, ok := curve_land(app, pos, size, anchor)
	if !ok do return
	if len(c.points) == 0 do c.radius = app.brush.radius_px * camera.orbit_world_per_px(app.camera, hit, size.y)
	if len(c.points) > 0 && linalg.length(hit - c.points[len(c.points) - 1].p) < 0.05 * c.radius do return
	append(&c.points, geom.Curve_Point{hit, n})
	append(&c.screen, pos)
}

// Adds `mesh` (in world space) as a new object around its middle, selected, as one undo
// step, marked `mode`. Returns false only on a GPU failure.
@(private = "file")
add_made_object :: proc(app: ^App, mesh: ^geom.Mesh, label: string, mode: Boolean_Mode, start: time.Tick, material: Material = {}) -> bool {
	bounds := geom.AABB_EMPTY
	for p in mesh.positions do geom.aabb_grow(&bounds, p)
	middle := 0.5 * (bounds.lo + bounds.hi)
	for &p in mesh.positions do p -= middle
	stroke_finish(app)
	name := fmt.aprintf("%s %d", label, app.scene.next_id + 1)
	defer delete(name)
	if !scene_add_mesh(app, mesh^, name, {scale = 1}, {position = middle, scale = 1}, start, material = material) do return false
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
	material: Material // a copy of an object is shaded as the object is
	if src := object_by_id(app, s.object); src != nil {
		material = src.material
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
	return add_made_object(app, &source, label, s.mode, start, material)
}

// Draws the curve being drawn, or the size of the shape being inserted.
draw_curve_overlay :: proc(app: ^App, o: Overlay) {
	color := overlay_color({0.4, 0.85, 1, 1})
	if c := &app.curve; c.active && len(c.screen) >= 2 do overlay_polyline(o, c.screen[:], color, 2)
	// The points placed so far, joined, the first larger since a tap on it closes the curve.
	if c := &app.curve; len(c.placing) > 0 {
		size := app.ui.viewport_size
		view_proj := edit_view_proj(app, size)
		line := make([dynamic][2]f32, 0, len(c.placing), context.temp_allocator)
		for p in c.placing do if at, ok := gizmo.project(view_proj, p, size); ok do append(&line, at)
		if len(line) >= 2 do overlay_polyline(o, line[:], color, 2)
		for at, i in line do overlay_disc(o, at, (6 if i == 0 else 4) * o.scale, color)
	}
	if s := &app.insert; s.active do overlay_circle(o, s.start, s.px, color, 1.5)
	if app.tool == .Curve && app.curve.plane != .Surface do draw_curve_plane(app, o)
}

// About how far apart, in pixels, the drawing plane's grid lines are, and how many cells
// the grid reaches each way from its middle.
CURVE_GRID_PX :: 48
CURVE_GRID_CELLS :: 6

// The Draw on plane while the Curve tool is on, as a faint grid round where the next point
// lands (the drag's first point while drawing), ringed there, so the depth a point takes
// shows before it lands. An axis plane's lines keep to the world's grid of that cell size.
@(private = "file")
draw_curve_plane :: proc(app: ^App, o: Overlay) {
	c := &app.curve
	size := app.ui.viewport_size
	anchor := c.points[0].p if c.active && len(c.points) > 0 else curve_next_anchor(app)
	at, n := curve_plane_at(app, c.plane, anchor)
	cell := floor_cell_fit(camera.orbit_world_per_px(app.camera, at, size.y) * CURVE_GRID_PX * 8)
	u := linalg.normalize(linalg.cross(n, Vec3{1, 0, 0} if abs(n.y) > 0.9 else Vec3{0, 1, 0}))
	v := linalg.cross(n, u)
	if c.plane != .View do for i in 0 ..< 3 do if abs(n[i]) < 0.5 do at[i] = math.round(at[i] / cell) * cell
	view_proj := edit_view_proj(app, size)
	color := overlay_color({0.4, 0.85, 1, 0.18})
	reach := f32(CURVE_GRID_CELLS) * cell
	for i in -CURVE_GRID_CELLS ..= CURVE_GRID_CELLS {
		off := f32(i) * cell
		for pair in ([2][2]Vec3{{u, v}, {v, u}}) {
			a, ok_a := gizmo.project(view_proj, at + pair[0] * off - pair[1] * reach, size)
			b, ok_b := gizmo.project(view_proj, at + pair[0] * off + pair[1] * reach, size)
			if ok_a && ok_b do overlay_line(o, a, b, color, 1)
		}
	}
	if mid, ok := gizmo.project(view_proj, anchor, size); ok do overlay_circle(o, mid, 5 * o.scale, overlay_color({0.4, 0.85, 1, 0.6}), 1)
}

// The Curve tool's settings in the interface.
kit_curve_settings :: proc(app: ^App) {
	ctx := &app.kit.ctx
	c := &app.curve
	kinds: [len(Curve_Kind)]string
	for kind, i in Curve_Kind do kinds[i] = fmt.tprint(kind)
	if picked := ui.tabs(ctx, "curve kind", kinds[:], int(c.kind)); picked >= 0 do c.kind = Curve_Kind(picked)
	// Draw makes new curves from presses on empty space; Edit picks the selected curve's
	// points there with a box instead (Tab switches).
	if c.kind == .Curve {
		modes := [2]string{"Draw", "Edit"}
		keys := [2]string{"Tab", "Tab"}
		if picked := ui.tabs(ctx, "curve mode", modes[:], int(c.editing), keys = keys[:]); picked >= 0 do c.editing = picked == 1
		_ = ui.switch_row(ctx, "Show every point's handles", &c.all_handles)
		if obj := selected_curve(app); obj != nil && c.editing {
			// The picked points' handle type, as the last picked point's shows.
			ui.label(ctx, "Handles", ctx.theme.small_size)
			types: [len(geom.Handle_Type)]string
			for kind, i in geom.Handle_Type do types[i] = fmt.tprint(kind)
			shown := -1
			if c.picked >= 1 && c.picked <= len(obj.curve.points) do shown = int(obj.curve.points[c.picked - 1].handles)
			hints: [len(geom.Handle_Type)]string
			for &h, i in hints do h = command_hint(app, .Curve_Handles, i)
			if picked := ui.tabs(ctx, "curve handles", types[:], shown, keys = hints[:]); picked >= 0 do command_run(app, .Curve_Handles, picked)
		}
		if c.editing {
			// The Move tool's gizmo settings, which the picked points' gizmo shares.
			modes: [len(gizmo.Mode)]string
			for name, mode in GIZMO_MODE_NAMES do modes[int(mode)] = name
			if picked := ui.tabs(ctx, "curve gizmo mode", modes[:], int(app.move.mode)); picked >= 0 do app.move.mode = gizmo.Mode(picked)
			orients: [len(Gizmo_Orient)]string
			for name, o in GIZMO_ORIENT_NAMES do orients[int(o)] = name
			if picked := ui.tabs(ctx, "curve gizmo orientation", orients[:], int(app.move.orient)); picked >= 0 do app.move.orient = Gizmo_Orient(picked)
			_ = ui.switch_row(ctx, "Snap", &app.move.snap)
		}
	}
	ui.label(ctx, "Draw on", ctx.theme.small_size)
	planes: [len(Curve_Plane)]string
	for name, plane in CURVE_PLANE_NAMES do planes[int(plane)] = name
	if picked := ui.tabs(ctx, "curve plane", planes[:], int(c.plane)); picked >= 0 do c.plane = Curve_Plane(picked)
	_ = ui.slider(ctx, "Width", &c.size, 0.05, 2, .Logarithmic, fmt.tprintf("%.2f x brush", c.size))
	if c.kind == .Tube {
		_ = ui.slider(ctx, "Lift", &c.lift, -1, 2, .Linear, fmt.tprintf("%.2f radius", c.lift))
		sides := f32(c.sides)
		if ui.slider(ctx, "Sides", &sides, 3, 64, .Linear, fmt.tprintf("%d", c.sides)) do c.sides = i32(sides + 0.5)
	}
	if obj := selected_curve(app); obj != nil do kit_curve_look(app, obj)
}

// The selected curve's own settings under the tool's: what it makes and that use's
// options. Each change is a Curve_Look command, one undo step; a slider's drag is one step
// when it lets go.
@(private = "file")
kit_curve_look :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.curve
	look := cp.look
	set :: proc(app: ^App, look: Curve_Look, drag := false) {
		app.ui.scene_command = {kind = .Curve_Look, curve = look, look_drag = drag}
	}
	ui.caption(ctx, strings.to_upper(object_label(obj), context.temp_allocator))
	uses: [len(CURVE_USES_BUILT)]string
	hints: [len(CURVE_USES_BUILT)]string
	at := -1
	built := CURVE_USES_BUILT
	for use, i in built {
		uses[i] = CURVE_USE_NAMES[use]
		hints[i] = command_hint(app, .Curve_Use, int(use))
		if use == cp.use do at = i
	}
	if picked := ui.tabs(ctx, "curve use", uses[:], at, keys = hints[:]); picked >= 0 do command_run(app, .Curve_Use, int(built[picked]))
	#partial switch cp.use {
	case .Tube:
		kit_curve_tube(app, obj, look)
	case .Lathe:
		kit_curve_lathe(app, obj, look)
	case .Along:
		kit_curve_along(app, look)
	case .Brush_Path:
		ui.paragraph(ctx, "Runs the brush in hand along the curve on the model under it, as a stroke held to edit: reshape it, then Validate (Enter) or Cancel (Escape).")
		_ = command_button(app, .Curve_Brush_Run, width = ui.fill_width(ctx))
		kit_curve_cage(app)
		return
	case .Guide:
		ui.paragraph(ctx, "Quad Remesh runs its loops along the curve where it lies on the object, as firmly as Guide strength asks (Rebuild > Quads > More options).")
		kit_curve_cage(app)
		return
	case:
		kit_curve_cage(app)
		return
	}
	_ = command_button(app, .Curve_Bake, width = ui.fill_width(ctx))
	kit_curve_cage(app)

	kit_curve_tube :: proc(app: ^App, obj: ^Object, look: Curve_Look) {
		ctx := &app.kit.ctx
		cp := obj.curve
		look := look
		o := &look.tube
		profiles := [len(geom.Tube_Profile)]string{"Round", "Square", "Ribbon", "Star", "Half"}
		if picked := ui.tabs(ctx, "tube profile", profiles[:], int(o.profile)); picked >= 0 {
			o.profile = geom.Tube_Profile(picked)
			set(app, look)
		}
		radii := [len(geom.Tube_Radius)]string{"One radius", "Ends", "Each point"}
		if picked := ui.tabs(ctx, "tube radius", radii[:], int(o.radius)); picked >= 0 {
			o.radius = geom.Tube_Radius(picked)
			// One starts from the points' mean, so the tube keeps its size.
			if o.radius == .One {
				mean: f32
				for p in cp.points do mean += p.radius
				o.one = mean / f32(len(cp.points))
			}
			set(app, look)
		}
		if o.radius == .One {
			r := o.one * obj.transform.scale
			if ui.slider(ctx, "Radius", &r, 1e-3, 1, .Logarithmic, fmt.tprintf("%.3f", r)) {
				o.one = r / obj.transform.scale
				set(app, look, true)
			}
		}
		sides := f32(o.sides)
		if ui.slider(ctx, "Tube sides", &sides, 3, geom.TUBE_SIDES_MAX, .Linear, fmt.tprintf("%d", o.sides)) {
			o.sides = int(sides + 0.5)
			set(app, look, true)
		}
		if ui.slider(ctx, "Density", &o.density, 0.25, 8, .Logarithmic, fmt.tprintf("%.2f rings a radius", o.density)) do set(app, look, true)
		if !cp.closed {
			caps := [len(geom.Tube_Caps)]string{"Flat caps", "Round caps", "Open"}
			if picked := ui.tabs(ctx, "tube caps", caps[:], int(o.caps)); picked >= 0 {
				o.caps = geom.Tube_Caps(picked)
				set(app, look)
			}
		}
		if o.profile == .Ribbon {
			if ui.slider(ctx, "Flatness", &o.flatness, 0.02, 1, .Linear, fmt.tprintf("%.2f", o.flatness)) do set(app, look, true)
		}
	}

	kit_curve_along :: proc(app: ^App, look: Curve_Look) {
		ctx := &app.kit.ctx
		look := look
		a := &look.along
		parts: [len(Along_Part)]string
		for part, i in Along_Part do parts[i] = ALONG_PART_NAMES[part]
		if picked := ui.tabs(ctx, "along part", parts[:], int(a.part)); picked >= 0 {
			// A part comes with its own spacing and lift; the way up stays the curve's.
			up := a.opts.up
			a^ = along_preset(Along_Part(picked))
			a.opts.up = up
			set(app, look)
		}
		if ui.slider(ctx, "Gap", &a.opts.gap, -0.9, 3, .Linear, fmt.tprintf("%.2f of a copy", a.opts.gap)) do set(app, look, true)
		if ui.slider(ctx, "Lift", &a.opts.lift, -1, 1, .Linear, fmt.tprintf("%.2f of a width", a.opts.lift)) do set(app, look, true)
		if ui.switch_row(ctx, "Alternate sides", &a.opts.alternate) do set(app, look)
	}

	kit_curve_lathe :: proc(app: ^App, obj: ^Object, look: Curve_Look) {
		ctx := &app.kit.ctx
		look := look
		o := &look.lathe
		// The axis: the view's vertical as it is now, or a world axis, each in the curve's
		// space. Which world axis it is lights its tab; View lights none, being a moment's.
		axes := [4]string{"View", "X", "Y", "Z"}
		lit := -1
		for i in 1 ..= 3 {
			w: Vec3
			w[i - 1] = 1
			if linalg.length(linalg.normalize0(to_local_dir(obj.transform, w)) - o.axis) < 1e-4 do lit = i
		}
		if picked := ui.tabs(ctx, "lathe axis", axes[:], lit); picked >= 0 {
			w: Vec3
			if picked == 0 do _, w, _ = camera.orbit_basis(app.camera)
			else do w[picked - 1] = 1
			o.axis = linalg.normalize0(to_local_dir(obj.transform, w))
			set(app, look)
		}
		through := [len(geom.Lathe_Through)]string{"Through start", "End", "Middle"}
		if picked := ui.tabs(ctx, "lathe through", through[:], int(o.through)); picked >= 0 {
			o.through = geom.Lathe_Through(picked)
			set(app, look)
		}
		if ui.slider(ctx, "Angle", &o.angle, 1, 360, .Linear, fmt.tprintf("%.0f°", o.angle)) do set(app, look, true)
		segments := f32(o.segments)
		if ui.slider(ctx, "Segments", &segments, 3, 128, .Linear, fmt.tprintf("%d", o.segments)) {
			o.segments = int(segments + 0.5)
			set(app, look, true)
		}
		if !obj.curve.closed && ui.switch_row(ctx, "Caps", &o.caps) do set(app, look)
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
