package main

import "core:fmt"
import "core:math/linalg"
import "core:slice"

import "../gizmo"
import "../poly"
import "../sculpt"

// The Topo pen: retopology by hand on a sculpt, as Maya's Quad Draw, Modo's Topology Pen
// and ZBrush's Retopo brush do, every gesture one press, drag and lift.
// - A tap on the sculpt drops a dot there; a Ctrl tap on a dot takes it away, and on a
//   cage face deletes the face.
// - A drag from a point (a dot or a cage point) over two or more others makes a face of
//   them in the order met, turned to face out of the sculpt; the dots become its points.
// - A drag from a point that meets no other moves it over the sculpt, and lifted on
//   another point welds it there (the other lights in the weld colour while dragging).
// - A drag from a border edge grows a quad from it to the pen (Ctrl: the whole border);
//   a new corner landing on a point welds to it.
// - Shift and a drag relaxes the points under the pen, keeping them on the sculpt: from a
//   border point the border slides along itself with the inside pinned, from inside the
//   inside evens out with the border pinned.
// The sculpt is any shown object that is not a cage; points sit a little above it so the
// cage is drawn over it. The first face makes a new cage, "Retopo of" the sculpt, in its
// own colour; later faces go to the cage their points are on, or the selected cage.

// A dot: a point on the sculpt waiting for a face, in world space, and the object it lies
// on. Dots are the tool's, not the scene's: they are no undo steps and are not saved.
Topo_Dot :: struct {
	at:      Vec3,
	surface: int,
}

// A point the pen can take: a dot (by index) or a cage's point (object id and point).
Topo_Point :: struct {
	dot:    int, // -1 for a cage point
	object: int,
	point:  u32,
}

TOPO_NONE :: Topo_Point{dot = -1, point = poly.NONE}

Topo_Drag_Kind :: enum u8 {
	None,
	Point, // from a point: a face, a move or a weld, decided on the lift
	Edge, // from a border edge: a quad, or the whole border, out to the pen
	Relax, // Shift: relaxing under the pen
	Surface, // on the sculpt away from any point: a tap drops a dot
}

Model_Topo :: struct {
	dots:   [dynamic]Topo_Dot,
	// What the pen is over.
	hover:  Topo_Point,
	edge:   u32, // a border edge of hover_object when no point is near, or NONE
	hover_object: int,
	// The drag.
	kind:   Topo_Drag_Kind,
	press:  [2]f32,
	alt:    bool,
	start:  Topo_Point,
	met:    [dynamic]Topo_Point, // the points met after the start, in order (heap)
	stroke: [dynamic][2]f32, // a drag on the sculpt, on screen (heap)
	// Relax's cage before it began (nil until the first change), and whether it moves the
	// border points or the inner ones.
	before: ^Object_Snapshot,
	border: bool,
	object: int, // the cage an edge drag or a relax works on
	pressed_edge: u32, // the border edge an edge drag started on
	// The last cage the pen made faces in, which takes faces of dots alone when no cage
	// is selected.
	cage:   int,
	// Since the start, for the exit stats.
	faces, welds, extends, relaxes, sheets: int,
}

model_topo_free :: proc(t: ^Model_Topo) {
	if t.before != nil do history_snapshot_drop(t.before)
	delete(t.dots)
	delete(t.met)
	delete(t.stroke)
}

// How near on screen the pen must come to a point to take it, and to a border edge;
// the relax brush's radius.
TOPO_PICK :: 16
TOPO_EDGE_PICK :: 12
TOPO_RELAX_RADIUS :: 48
// How far above the sculpt points sit, as a share of its size, so the cage is drawn over
// it rather than through it.
TOPO_LIFT :: 0.002
// The new cage's colour: teal, the face colour of Model mode's hover.
TOPO_COLOR :: [4]f32{0.25, 0.75, 0.72, 1}
TOPO_FILL_COLOR :: [4]f32{0.25, 0.75, 0.72, 0.3}
// The weld colour: a point a lift would weld to.
TOPO_WELD_COLOR :: [4]f32{1.0, 0.35, 0.55, 1}

// What the sculpt is under viewport point `pos`: the nearest shown object that is not a
// cage, where the ray meets it and the surface's normal there (world space), and a point
// TOPO_LIFT above it.
topo_surface :: proc(app: ^App, pos, size: [2]f32) -> (obj: ^Object, hit, normal: Vec3, ok: bool) {
	origin, dir := mouse_ray(app.camera, pos, size)
	best := max(f32)
	for o in app.scene.objects {
		if o.cage != nil || !object_pickable(app, o) do continue
		t := o.transform
		lo, ld := to_local(t, origin), to_local_dir(t, dir)
		local, n: Vec3
		met: bool
		if o.voxel != nil {
			local, n, met = object_raycast_local(o, lo, ld)
		} else {
			tri: u32
			local, tri, met = sculpt.sculptor_raycast_triangle(object_sculptor(o), lo, ld)
			if met {
				m := object_mesh(o)
				a, b, c := m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]
				n = linalg.cross(b - a, c - a)
			}
		}
		if !met do continue
		w := to_world(t, local)
		if d := linalg.length(w - origin); d < best {
			best, obj, hit, ok = d, o, w, true
			normal = linalg.normalize0(transform_rotation(t) * n)
		}
	}
	if !ok do return
	// The normal faces the pen: a sculpt's triangles face out, so this only matters for
	// open shells seen from behind.
	if linalg.dot(normal, dir) > 0 do normal = -normal
	b := object_world_bounds(obj)
	hit += normal * TOPO_LIFT * linalg.length(b.hi - b.lo)
	return
}

// Where a point is, world space.
topo_point_at :: proc(app: ^App, p: Topo_Point) -> (at: Vec3, ok: bool) {
	t := &app.model.topo
	if p.dot >= 0 {
		if p.dot >= len(t.dots) do return
		return t.dots[p.dot].at, true
	}
	obj := object_by_id(app, p.object)
	if obj == nil || obj.cage == nil || int(p.point) >= len(obj.cage.mesh.positions) do return
	return to_world(obj.transform, cage_point(obj.cage, p.point)), true
}

topo_same :: proc(a, b: Topo_Point) -> bool {
	return a.dot == b.dot && (a.dot >= 0 || (a.object == b.object && a.point == b.point))
}

// Whether a world point is in sight: nothing in the scene lies before it by more than
// `slack`.
topo_seen :: proc(app: ^App, p: Vec3, size: [2]f32, slack: f32) -> bool {
	screen, on := gizmo.project(view_proj_of(app, size), p, size)
	if !on do return false
	origin, dir := mouse_ray(app.camera, screen, size)
	_, hit, met := scene_raycast(app, origin, dir)
	return !met || linalg.length(hit - origin) >= linalg.length(p - origin) - slack
}

// The point nearest `pos` on screen within TOPO_PICK, among the dots and the shown cages'
// points in sight, skipping `skip`; TOPO_NONE when none.
topo_point_near :: proc(app: ^App, pos, size: [2]f32, skip := TOPO_NONE) -> Topo_Point {
	t := &app.model.topo
	vp := view_proj_of(app, size)
	best, found := f32(TOPO_PICK), TOPO_NONE
	for d, i in t.dots {
		s, on := gizmo.project(vp, d.at, size)
		p := Topo_Point{dot = i, point = poly.NONE}
		if on && !topo_same(p, skip) && linalg.length(s - pos) < best do best, found = linalg.length(s - pos), p
	}
	for obj in app.scene.objects {
		cp := obj.cage
		if cp == nil || !object_shown(app, obj) do continue
		slack := cage_size(cp) * 0.01 * obj.transform.scale
		for v in 0 ..< u32(len(cp.mesh.positions)) {
			w := to_world(obj.transform, cage_point(cp, v))
			s, on := gizmo.project(vp, w, size)
			if !on || linalg.length(s - pos) >= best do continue
			p := Topo_Point{dot = -1, object = obj.id, point = v}
			if topo_same(p, skip) || !topo_seen(app, w, size, slack) do continue
			best, found = linalg.length(s - pos), p
		}
	}
	return found
}

// The border edge of a shown cage nearest `pos` on screen within TOPO_EDGE_PICK, in sight.
topo_edge_near :: proc(app: ^App, pos, size: [2]f32) -> (object: int, edge: u32) {
	vp := view_proj_of(app, size)
	best := f32(TOPO_EDGE_PICK)
	edge = poly.NONE
	for obj in app.scene.objects {
		cp := obj.cage
		if cp == nil || !object_shown(app, obj) do continue
		slack := cage_size(cp) * 0.01 * obj.transform.scale
		for e in 0 ..< u32(len(cp.mesh.crease)) {
			if !poly.edge_border(&cp.mesh, e) do continue
			a, b := poly.edge_verts(&cp.mesh, e)
			wa, wb := to_world(obj.transform, cage_point(cp, a)), to_world(obj.transform, cage_point(cp, b))
			sa, a_on := gizmo.project(vp, wa, size)
			sb, b_on := gizmo.project(vp, wb, size)
			if !a_on || !b_on do continue
			d, _ := segment_distance(pos, sa, sb)
			// Its ends in sight: its middle may dip under a curved sculpt.
			if d >= best || !topo_seen(app, wa, size, slack) || !topo_seen(app, wb, size, slack) do continue
			best, object, edge = d, obj.id, e
		}
	}
	return
}

// The Topo pen, a frame: the hover, then the press, the drag and the lift. Returns false
// only on a GPU failure.
model_topo_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	t := &app.model.topo
	slop := app.kit.ctx.theme.slop
	switch t.kind {
	case .None:
	case .Point:
		if input.primary {
			// A point met joins the path; the one last met does not count twice.
			if p := topo_point_near(app, input.mouse_pos, input.size, t.start); p != TOPO_NONE {
				if len(t.met) == 0 || !topo_same(t.met[len(t.met) - 1], p) do append(&t.met, p)
			}
			return true
		}
		t.kind = .None
		return topo_point_lift(app, input)
	case .Edge:
		if input.primary do return true
		t.kind = .None
		if linalg.length(input.mouse_pos - t.press) <= slop do return true
		return topo_extend(app, input)
	case .Relax:
		if input.primary do return topo_relax(app, input)
		t.kind = .None
		topo_relax_end(app)
		return true
	case .Surface:
		if input.primary {
			if linalg.length(input.mouse_pos - t.stroke[len(t.stroke) - 1]) >= 3 do append(&t.stroke, input.mouse_pos)
			return true
		}
		t.kind = .None
		append(&t.stroke, input.mouse_pos)
		if model_stroke_reach(t.stroke[:], t.press) > slop do return topo_sheet(app, input)
		return topo_tap_surface(app, input)
	}
	// The hover: a point, else a border edge.
	t.hover, t.edge, t.hover_object = TOPO_NONE, poly.NONE, 0
	if input.hovered || input.primary {
		t.hover = topo_point_near(app, input.mouse_pos, input.size)
		if t.hover == TOPO_NONE do t.hover_object, t.edge = topo_edge_near(app, input.mouse_pos, input.size)
	}
	if !input.primary || !input.press do return true
	t.press, t.alt, t.start = input.mouse_pos, input.invert, t.hover
	clear(&t.met)
	clear(&t.stroke)
	append(&t.stroke, input.mouse_pos)
	switch {
	case input.smooth:
		t.kind, t.object, t.border = .Relax, 0, false
		// From a border point the border relaxes; from anywhere else the inside.
		if t.hover.dot < 0 && t.hover != TOPO_NONE {
			obj := object_by_id(app, t.hover.object)
			t.object, t.border = t.hover.object, poly.vert_border(&obj.cage.mesh, t.hover.point)
		} else if sel := selected_object(app); sel != nil && sel.cage != nil {
			t.object = sel.id
		}
		return topo_relax(app, input)
	case t.hover != TOPO_NONE:
		t.kind = .Point
	case t.edge != poly.NONE:
		t.kind, t.object, t.pressed_edge = .Edge, t.hover_object, t.edge
	case:
		t.kind = .Surface
	}
	return true
}

// The cage face under viewport point `pos` as the overlay draws it: of the faces whose
// corners are all in sight and whose outline on screen holds the point, the nearest. A
// ray would meet the sculpt first where a flat face dips under it.
topo_face_at :: proc(app: ^App, pos, size: [2]f32) -> (obj: ^Object, face: u32, ok: bool) {
	vp := view_proj_of(app, size)
	eye, _ := mouse_ray(app.camera, pos, size)
	best := max(f32)
	outline := make([dynamic][2]f32, context.temp_allocator)
	for o in app.scene.objects {
		cp := o.cage
		if cp == nil || !object_shown(app, o) do continue
		slack := cage_size(cp) * 0.01 * o.transform.scale
		for f in 0 ..< u32(len(cp.mesh.face_he)) {
			clear(&outline)
			all := true
			middle: Vec3
			w := poly.face_walk(&cp.mesh, f)
			for h in poly.face_walk_next(&w) {
				p := to_world(o.transform, cage_point(cp, cp.mesh.he_vert[h]))
				s, on := gizmo.project(vp, p, size)
				all &&= on && topo_seen(app, p, size, slack)
				append(&outline, s)
				middle += p
			}
			if !all || !topo_inside(outline[:], pos) do continue
			middle /= f32(len(outline))
			if d := linalg.length(middle - eye); d < best do best, obj, face, ok = d, o, f, true
		}
	}
	return
}

// Whether point p lies inside the polygon (even-odd crossings).
@(private = "file")
topo_inside :: proc(polygon: [][2]f32, p: [2]f32) -> bool {
	inside := false
	for a, i in polygon {
		b := polygon[(i + 1) % len(polygon)]
		if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) do inside = !inside
	}
	return inside
}

// A tap on the sculpt: a dot there; with Ctrl, on a cage face, the face goes.
@(private = "file")
topo_tap_surface :: proc(app: ^App, input: Viewport_Input) -> bool {
	t := &app.model.topo
	if t.alt {
		obj, face, ok := topo_face_at(app, input.mouse_pos, input.size)
		if !ok do return true
		cage := &obj.cage.mesh
		if len(cage.face_he) <= 1 {
			report(app, nil, {.Warning}, "Topo pen: that is the cage's last face; delete the object instead")
			return true
		}
		before := history_snapshot(app, obj, "delete retopo face")
		r, err := poly.delete_faces(cage, {face})
		poly.edit_result_destroy(&r)
		return topo_commit(app, obj, before, err)
	}
	surface, hit, _, ok := topo_surface(app, input.mouse_pos, input.size)
	if !ok do return true
	append(&t.dots, Topo_Dot{at = hit, surface = surface.id})
	return true
}

// The lift of a drag from a point: a face through the points met, a weld onto the point
// lifted over, or the point moved over the sculpt to where the pen lifted. A tap with
// Ctrl takes a dot away.
@(private = "file")
topo_point_lift :: proc(app: ^App, input: Viewport_Input) -> bool {
	t := &app.model.topo
	moved := linalg.length(input.mouse_pos - t.press) > app.kit.ctx.theme.slop
	if !moved {
		if t.alt && t.start.dot >= 0 && t.start.dot < len(t.dots) do ordered_remove(&t.dots, t.start.dot)
		return true
	}
	if len(t.met) >= 2 do return topo_make_face(app, input.size)
	under := topo_point_near(app, input.mouse_pos, input.size, t.start)
	if under != TOPO_NONE do return topo_weld(app, t.start, under)
	_, hit, _, ok := topo_surface(app, input.mouse_pos, input.size)
	if !ok do return true
	return topo_move(app, t.start, hit)
}

// Puts point p at world point `at`: a dot simply, a cage point as one undo step.
@(private = "file")
topo_move :: proc(app: ^App, p: Topo_Point, at: Vec3) -> bool {
	t := &app.model.topo
	if p.dot >= 0 {
		if p.dot < len(t.dots) do t.dots[p.dot].at = at
		return true
	}
	obj := object_by_id(app, p.object)
	if obj == nil || obj.cage == nil do return true
	before := history_snapshot(app, obj, "move retopo point")
	obj.cage.mesh.positions[p.point] = to_local(obj.transform, at)
	if !cage_positions_moved(app, obj, {p.point}) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	app.model.done += 1
	return true
}

// Welds point `from` onto point `onto`: a dot onto anything goes away (moved there, for a
// cage point onto a dot); two points of one cage merge where `onto` is.
@(private = "file")
topo_weld :: proc(app: ^App, from, onto: Topo_Point) -> bool {
	t := &app.model.topo
	switch {
	case from.dot >= 0:
		ordered_remove(&t.dots, from.dot)
		t.welds += 1
		return true
	case onto.dot >= 0:
		at := t.dots[onto.dot].at
		ordered_remove(&t.dots, onto.dot)
		t.welds += 1
		return topo_move(app, from, at)
	case from.object != onto.object:
		report(app, nil, {.Warning}, "Topo pen: points of two cages cannot weld; move the point instead")
		return true
	}
	obj := object_by_id(app, from.object)
	if obj == nil || obj.cage == nil do return true
	before := history_snapshot(app, obj, "weld retopo points")
	r, err := poly.merge_points(&obj.cage.mesh, {{onto.point, from.point}}, keep_first = true)
	poly.edit_result_destroy(&r)
	if err == .None do t.welds += 1
	return topo_commit(app, obj, before, err)
}

// A face through the drag's start and the points it met, as one undo step: in the cage
// their cage points are in (dots alone go to the selected cage, else the last one the pen
// made, else a new one), turned to face out of the sculpt.
@(private = "file")
topo_make_face :: proc(app: ^App, size: [2]f32) -> bool {
	t := &app.model.topo
	// On the heap: the undo snapshot below frees the frame's temporary memory.
	points := make([dynamic]Topo_Point)
	defer delete(points)
	append(&points, t.start)
	for p in t.met do if !topo_same(p, t.start) do append(&points, p)
	if len(points) < 3 || len(points) > TOPO_FACE_MAX {
		report(app, nil, {.Warning}, "Topo pen: a face takes 3 to %d points; drag over them in turn", TOPO_FACE_MAX)
		return true
	}
	// The cage: the one the cage points are in, which must be one.
	cage_id := 0
	for p in points {
		if p.dot >= 0 do continue
		if cage_id != 0 && cage_id != p.object {
			report(app, nil, {.Warning}, "Topo pen: a face cannot join points of two cages")
			return true
		}
		cage_id = p.object
	}
	if cage_id == 0 do cage_id = topo_target_cage(app)
	// The corners in world space, and the way out of the sculpt at their middle.
	world := make([]Vec3, len(points))
	defer delete(world)
	for p, i in points do world[i], _ = topo_point_at(app, p)
	middle: Vec3
	for w in world do middle += w
	middle /= f32(len(world))
	outward := topo_outward(app, middle, size)
	normal: Vec3
	for w, i in world do normal += linalg.cross(w - middle, world[(i + 1) % len(world)] - middle)
	if linalg.dot(normal, outward) < 0 {
		slice.reverse(points[:])
		slice.reverse(world)
	}
	// The dots the face takes, highest first so removing one leaves the others' indices.
	taken := make([dynamic]int)
	defer delete(taken)
	for p in points do if p.dot >= 0 do append(&taken, p.dot)
	slice.sort(taken[:])
	if cage_id == 0 {
		// A new cage on the sculpt the first dot lies on, in its space.
		surface := object_by_id(app, t.dots[points[0].dot].surface if points[0].dot >= 0 else 0)
		tr := surface.transform if surface != nil else Transform{scale = 1}
		local := make([]Vec3, len(world), context.temp_allocator)
		for w, i in world do local[i] = to_local(tr, w)
		mesh, err := poly.polygon_mesh(local, 0)
		if err != .None {
			report(app, nil, {.Warning}, "Topo pen: those points do not make a face")
			return true
		}
		if !topo_new_cage(app, surface, mesh) do return false
	} else {
		obj := object_by_id(app, cage_id)
		before := history_snapshot(app, obj, "retopo face")
		corners := make([]poly.Topo_Corner, len(points), context.temp_allocator)
		for p, i in points {
			corners[i] = {point = p.point} if p.dot < 0 else {point = poly.NONE, at = to_local(obj.transform, world[i])}
		}
		r, err := poly.add_polygon(&obj.cage.mesh, corners, model_border_group_near(&obj.cage.mesh, corners))
		poly.edit_result_destroy(&r)
		if err != .None {
			history_snapshot_drop(before)
			app.model.refused += 1
			report(app, nil, {.Warning}, "Topo pen: that face would %s", "run against a face beside it, or give an edge a third face" if err == .Inconsistent || err == .Non_Manifold_Edge else "not make a sound cage")
			return true
		}
		if !topo_commit(app, obj, before, .None) do return false
		t.cage = obj.id
	}
	#reverse for i in taken do ordered_remove(&t.dots, i)
	t.faces += 1
	return true
}

// Adds `mesh` (in `surface`'s space) as a new retopo cage in the sculpt's place, named
// after it and in the Topo pen's colour, as an added object. Returns false only on a GPU
// failure.
@(private = "file")
topo_new_cage :: proc(app: ^App, surface: ^Object, mesh: poly.Mesh) -> bool {
	obj := new(Object)
	obj.transform, obj.file = surface.transform if surface != nil else Transform{scale = 1}, {scale = 1}
	if !object_build_cage(app, obj, mesh) {
		free(obj)
		return false
	}
	obj.name = fmt.aprintf("Retopo of %s", object_label(surface) if surface != nil else "the scene")
	obj.material = current_material(app)
	obj.material.label, obj.material.pack, obj.material.matcap = "Custom", 0, 0
	obj.material.selected, obj.material.idle = TOPO_COLOR, TOPO_COLOR
	scene_append(app, obj)
	history_record_added(app)
	app.model.topo.cage = obj.id
	return true
}

// The cage new faces of dots alone go to: the selected cage, else the last the pen made
// faces in, when shown; 0 for a new one.
@(private = "file")
topo_target_cage :: proc(app: ^App) -> int {
	if sel := selected_object(app); sel != nil && sel.cage != nil && object_shown(app, sel) do return sel.id
	if last := object_by_id(app, app.model.topo.cage); last != nil && last.cage != nil && object_shown(app, last) do return last.id
	return 0
}

// A drag on the sculpt, let go: a strip of quads along the stroke, as wide as the brush;
// a stroke that comes back to its start fills its outline with a grid of quads; with Ctrl,
// a grid patch over the rectangle from the press to the lift. Each point is on the sculpt
// under where it lies on screen, and the whole is one undo step.
@(private = "file")
topo_sheet :: proc(app: ^App, input: Viewport_Input) -> bool {
	t := &app.model.topo
	width := max(app.brush.radius_px, TOPO_SHEET_MIN)
	screen: [][2]f32
	sizes: []int
	corners: []u32
	stroke := t.stroke[:]
	length: f32
	for i in 1 ..< len(stroke) do length += linalg.length(stroke[i] - stroke[i - 1])
	closed := len(stroke) > 3 && linalg.length(stroke[len(stroke) - 1] - stroke[0]) < 2 * TOPO_PICK && length > 4 * width
	switch {
	case t.alt:
		a, b := t.press, input.mouse_pos
		across := clamp(int(abs(b.x - a.x) / width + 0.5), 1, TOPO_SHEET_MAX)
		down := clamp(int(abs(b.y - a.y) / width + 0.5), 1, TOPO_SHEET_MAX)
		screen = make([][2]f32, (across + 1) * (down + 1), context.temp_allocator)
		for j in 0 ..= down do for i in 0 ..= across {
			screen[j * (across + 1) + i] = {linalg.lerp(a.x, b.x, f32(i) / f32(across)), linalg.lerp(a.y, b.y, f32(j) / f32(down))}
		}
		sizes, corners = poly.grid_quads(across, down, context.temp_allocator)
	case closed:
		// The outline at even steps, an even number of them, its sides from its sharpest
		// turn: across and down as near equal as the count allows.
		count := clamp(2 * int(length / (2 * width) + 0.5), 8, 4 * TOPO_SHEET_MAX)
		outline := topo_resample(stroke, count, true)
		sharpest, least := 0, f32(2)
		for i in 0 ..< count {
			into := linalg.normalize0(outline[i] - outline[(i + count - 1) % count])
			out := linalg.normalize0(outline[(i + 1) % count] - outline[i])
			if c := linalg.dot(into, out); c < least do sharpest, least = i, c
		}
		turned := make([][2]f32, count, context.temp_allocator)
		for i in 0 ..< count do turned[i] = outline[(sharpest + i) % count]
		across := count / 4
		down := count / 2 - across
		screen = poly.coons_fill(turned, across, down, context.temp_allocator)
		sizes, corners = poly.grid_quads(across, down, context.temp_allocator)
	case:
		steps := clamp(int(length / width + 0.5), 1, 4 * TOPO_SHEET_MAX)
		middle := topo_resample(stroke, steps + 1, false)
		screen = make([][2]f32, 2 * (steps + 1), context.temp_allocator)
		for c, k in middle {
			ahead := middle[min(k + 1, steps)] - middle[max(k - 1, 0)]
			side := linalg.normalize0([2]f32{-ahead.y, ahead.x}) * width / 2
			screen[k], screen[steps + 1 + k] = c + side, c - side
		}
		sizes, corners = poly.grid_quads(steps, 1, context.temp_allocator)
	}
	// Every point onto the sculpt, or none.
	surface: ^Object
	world := make([]Vec3, len(screen))
	defer delete(world)
	for p, i in screen {
		obj, hit, _, ok := topo_surface(app, p, input.size)
		if !ok {
			report(app, nil, {.Warning}, "Topo pen: part of the %s would leave the sculpt", "patch" if t.alt || closed else "strip")
			return true
		}
		if surface == nil do surface = obj
		world[i] = hit
	}
	// Turned to face out of the sculpt, by its first face.
	q := corners[:4]
	n := linalg.cross(world[q[1]] - world[q[0]], world[q[2]] - world[q[0]])
	if linalg.dot(n, topo_outward(app, (world[q[0]] + world[q[2]]) / 2, input.size)) < 0 {
		for k in 0 ..< len(sizes) do slice.reverse(corners[4 * k:4 * k + 4])
	}
	kept_sizes := slice.clone(sizes)
	kept_corners := slice.clone(corners)
	defer delete(kept_sizes)
	defer delete(kept_corners)
	cage_id := topo_target_cage(app)
	if cage_id == 0 {
		tr := surface.transform
		local := make([]Vec3, len(world), context.temp_allocator)
		for w, i in world do local[i] = to_local(tr, w)
		mesh, err := poly.mesh_from_polygons(local, kept_sizes, kept_corners)
		if err != .None {
			report(app, nil, {.Warning}, "Topo pen: that %s folds over itself; draw it smoother", "patch" if t.alt || closed else "strip")
			return true
		}
		if !topo_new_cage(app, surface, mesh) do return false
	} else {
		obj := object_by_id(app, cage_id)
		before := history_snapshot(app, obj, "retopo strip")
		local := make([]Vec3, len(world), context.temp_allocator)
		for w, i in world do local[i] = to_local(obj.transform, w)
		r, err := poly.add_polygons(&obj.cage.mesh, local, kept_sizes, kept_corners, 0)
		poly.edit_result_destroy(&r)
		if !topo_commit(app, obj, before, err) do return false
	}
	t.sheets += 1
	return true
}

// `count` points spread evenly along a stroke (closed: round its loop, the first not
// repeated).
@(private = "file")
topo_resample :: proc(stroke: [][2]f32, count: int, closed: bool) -> [][2]f32 {
	pts := make([dynamic][2]f32, context.temp_allocator)
	append(&pts, ..stroke)
	if closed do append(&pts, stroke[0])
	run := make([]f32, len(pts), context.temp_allocator)
	for i in 1 ..< len(pts) do run[i] = run[i - 1] + linalg.length(pts[i] - pts[i - 1])
	total := run[len(pts) - 1]
	out := make([][2]f32, count, context.temp_allocator)
	span := count if closed else count - 1
	j := 0
	for k in 0 ..< count {
		want := total * f32(k) / f32(max(span, 1))
		for j < len(pts) - 2 && run[j + 1] < want do j += 1
		gap := run[j + 1] - run[j]
		u := clamp((want - run[j]) / gap, 0, 1) if gap > 0 else 0
		out[k] = linalg.lerp(pts[j], pts[j + 1], u)
	}
	return out
}

// The narrowest strip cell on screen, and the most cells a patch side or strip takes.
TOPO_SHEET_MIN :: 12
TOPO_SHEET_MAX :: 32

// The polygroup a new face takes: that of a face beside one of its existing corners, so
// a retopo stays one group until the user groups it.
@(private = "file")
model_border_group_near :: proc(cage: ^poly.Mesh, corners: []poly.Topo_Corner) -> u16 {
	for c in corners {
		if c.point == poly.NONE do continue
		w := poly.vertex_walk(cage, c.point)
		for h in poly.vertex_walk_next(&w) do if f := cage.he_face[h]; f != poly.NONE do return cage.group[f]
	}
	return 0
}

// Most corners a Topo face takes.
TOPO_FACE_MAX :: 8

// The way out of the sculpt at world point p: the surface's normal where the view's ray
// through p meets it, or toward the camera when it meets none.
@(private = "file")
topo_outward :: proc(app: ^App, p: Vec3, size: [2]f32) -> Vec3 {
	screen, on := gizmo.project(view_proj_of(app, size), p, size)
	if on {
		if _, _, n, ok := topo_surface(app, screen, size); ok do return n
	}
	origin, _ := mouse_ray(app.camera, screen, size)
	return linalg.normalize0(origin - p)
}

// A drag from a border edge, let go: a quad from the edge to where the pen is, each new
// corner on the sculpt under where the edge's end moved to on screen (or welded to a point
// there); with Ctrl the whole border grows that far, every new point on the sculpt.
@(private = "file")
topo_extend :: proc(app: ^App, input: Viewport_Input) -> bool {
	t := &app.model.topo
	obj := object_by_id(app, t.object)
	if obj == nil || obj.cage == nil do return true
	cp := obj.cage
	shift := input.mouse_pos - t.press
	vp := view_proj_of(app, input.size)
	// Where a cage point lands: on the sculpt under its screen place moved by the drag.
	landing :: proc(app: ^App, obj: ^Object, v: u32, shift: [2]f32, vp: matrix[4, 4]f32, size: [2]f32) -> (at: Vec3, ok: bool) {
		s, on := gizmo.project(vp, to_world(obj.transform, cage_point(obj.cage, v)), size)
		if !on do return
		_, at, _, ok = topo_surface(app, s + shift, size)
		return
	}
	if t.alt {
		// On the heap: the undo snapshot below frees the frame's temporary memory.
		loop := make([dynamic]u32)
		defer delete(loop)
		poly.border_loop(&cp.mesh, t.pressed_edge, &loop)
		// Every landing first: a point that lands nowhere refuses the whole border. The
		// points in the order extrude_border copies them, which its drag lists them in.
		order := make([dynamic]u32)
		defer delete(order)
		for e in loop {
			h := 2 * e if cp.mesh.he_face[2 * e] == poly.NONE else 2 * e + 1
			for v in ([2]u32{cp.mesh.he_vert[h], poly.he_tip(&cp.mesh, h)}) do if !slice.contains(order[:], v) do append(&order, v)
		}
		lands := make(map[u32]Vec3)
		defer delete(lands)
		for v in order {
			at, ok := landing(app, obj, v, shift, vp, input.size)
			if !ok {
				report(app, nil, {.Warning}, "Topo pen: part of the border would leave the sculpt; drag a shorter way")
				return true
			}
			lands[v] = to_local(obj.transform, at)
		}
		before := history_snapshot(app, obj, "extend retopo border")
		r, d, err := poly.extrude_border(&cp.mesh, loop[:], false)
		defer poly.border_extrude_destroy(&r)
		defer poly.drag_set_destroy(&d)
		if err == .None {
			// Each new point is its old point's copy: placed where that one lands.
			for v, i in order do cp.mesh.positions[d.verts[i]] = lands[v]
			t.extends += 1
		}
		return topo_commit(app, obj, before, err)
	}
	e := t.pressed_edge
	h := 2 * e if cp.mesh.he_face[2 * e] == poly.NONE else 2 * e + 1
	a, b := cp.mesh.he_vert[h], poly.he_tip(&cp.mesh, h)
	corners: [4]poly.Topo_Corner = {{point = a}, {point = b}, {point = poly.NONE}, {point = poly.NONE}}
	for v, i in ([2]u32{b, a}) {
		s, _ := gizmo.project(vp, to_world(obj.transform, cage_point(cp, v)), input.size)
		// A point of the same cage where it lands takes the corner: a weld.
		if p := topo_point_near(app, s + shift, input.size); p.dot < 0 && p.object == obj.id && p.point != a && p.point != b {
			corners[2 + i] = {point = p.point}
			continue
		}
		at, ok := landing(app, obj, v, shift, vp, input.size)
		if !ok {
			report(app, nil, {.Warning}, "Topo pen: the new edge would leave the sculpt")
			return true
		}
		corners[2 + i] = {point = poly.NONE, at = to_local(obj.transform, at)}
	}
	before := history_snapshot(app, obj, "extend retopo edge")
	r, err := poly.add_polygon(&cp.mesh, corners[:], cp.mesh.group[cp.mesh.he_face[poly.twin(h)]])
	poly.edit_result_destroy(&r)
	if err == .None do t.extends += 1
	return topo_commit(app, obj, before, err)
}

// Relaxes the cage points within TOPO_RELAX_RADIUS of the pen, one step a frame, each put
// back on the sculpt under where it moved to on screen: the border points alone when the
// drag began on one, else the inner ones. The first change takes the undo snapshot.
@(private = "file")
topo_relax :: proc(app: ^App, input: Viewport_Input) -> bool {
	t := &app.model.topo
	obj := object_by_id(app, t.object)
	if obj == nil || obj.cage == nil do return true
	cp := obj.cage
	vp := view_proj_of(app, input.size)
	slack := cage_size(cp) * 0.01 * obj.transform.scale
	points := make([dynamic]u32, context.temp_allocator)
	for v in 0 ..< u32(len(cp.mesh.positions)) {
		if poly.vert_border(&cp.mesh, v) != t.border do continue
		w := to_world(obj.transform, cp.mesh.positions[v])
		s, on := gizmo.project(vp, w, input.size)
		if !on || linalg.length(s - input.mouse_pos) > TOPO_RELAX_RADIUS || !topo_seen(app, w, input.size, slack) do continue
		append(&points, v)
	}
	if len(points) == 0 do return true
	goals := poly.relax_points(&cp.mesh, points[:], context.temp_allocator)
	// Each goal back on the sculpt, under where it lies on screen.
	placed := make([dynamic]u32, context.temp_allocator)
	at := make([dynamic]Vec3, context.temp_allocator)
	for v, i in points {
		s, on := gizmo.project(vp, to_world(obj.transform, goals[i]), input.size)
		if !on do continue
		_, hit, _, ok := topo_surface(app, s, input.size)
		if !ok do continue
		append(&placed, v)
		append(&at, to_local(obj.transform, hit))
	}
	if len(placed) == 0 do return true
	if t.before == nil {
		// The snapshot frees the frame's temporary memory: the places are kept on the heap
		// across it.
		kept_v := slice.clone(placed[:])
		kept_at := slice.clone(at[:])
		defer delete(kept_v)
		defer delete(kept_at)
		t.before = history_snapshot(app, obj, "relax retopo")
		for v, i in kept_v do cp.mesh.positions[v] = kept_at[i]
		return cage_positions_moved(app, obj, kept_v)
	}
	for v, i in placed do cp.mesh.positions[v] = at[i]
	return cage_positions_moved(app, obj, placed[:])
}

// The relax lets go: its changes are one undo step.
@(private = "file")
topo_relax_end :: proc(app: ^App) {
	t := &app.model.topo
	if t.before == nil do return
	history_record_swap(app, t.object, t.before, kind = .Model)
	t.before = nil
	t.relaxes += 1
	app.model.done += 1
}

// A topology change to the cage made: built again and recorded as one undo step, or with
// `err` refused with a note and the cage as it was.
@(private = "file")
topo_commit :: proc(app: ^App, obj: ^Object, before: ^Object_Snapshot, err: poly.Build_Error) -> bool {
	if err != .None {
		history_snapshot_drop(before)
		app.model.refused += 1
		report(app, nil, {.Warning}, "Topo pen refused: the change would not leave a sound cage (an edge with three faces, or faces running against each other)")
		return true
	}
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	app.model.done += 1
	return true
}

// The Topo pen over the view: the dots, the point or border edge under the pen, and while
// dragging the path through the points met (the weld target in the weld colour), the
// quad an edge drag would make, or the relax brush.
draw_topo_overlay :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	t := &app.model.topo
	vp := view_proj_of(app, input.size)
	point_color := overlay_color(MODEL_ELEMENT_COLORS[.Point])
	// Every shown cage over the sculpt, in its colour: a flat face between points on a
	// curved sculpt dips under it, so the 3D cage alone would show only in patches. A face
	// shows when all its corners are in sight.
	fill, line := overlay_color(TOPO_FILL_COLOR), overlay_color(TOPO_COLOR)
	for obj in app.scene.objects {
		cp := obj.cage
		if cp == nil || !object_shown(app, obj) do continue
		slack := cage_size(cp) * 0.01 * obj.transform.scale
		screen := make([][2]f32, len(cp.mesh.positions), context.temp_allocator)
		seen := make([]bool, len(cp.mesh.positions), context.temp_allocator)
		for v in 0 ..< len(cp.mesh.positions) {
			w := to_world(obj.transform, cage_point(cp, u32(v)))
			on: bool
			screen[v], on = gizmo.project(vp, w, input.size)
			seen[v] = on && topo_seen(app, w, input.size, slack)
		}
		corners := make([dynamic][2]f32, context.temp_allocator)
		for f in 0 ..< u32(len(cp.mesh.face_he)) {
			clear(&corners)
			all := true
			w := poly.face_walk(&cp.mesh, f)
			for h in poly.face_walk_next(&w) {
				v := cp.mesh.he_vert[h]
				all &&= seen[v]
				append(&corners, screen[v])
			}
			if !all do continue
			overlay_fill(o, corners[:], fill)
			overlay_polyline(o, corners[:], line, 1.5, closed = true)
		}
	}
	for d in t.dots {
		if s, on := gizmo.project(vp, d.at, input.size); on do overlay_disc(o, s, 4, point_color)
	}
	screen :: proc(app: ^App, p: Topo_Point, vp: matrix[4, 4]f32, size: [2]f32) -> (s: [2]f32, ok: bool) {
		at := topo_point_at(app, p) or_return
		return gizmo.project(vp, at, size)
	}
	switch t.kind {
	case .None:
		if s, ok := screen(app, t.hover, vp, input.size); ok do overlay_circle(o, s, 8, point_color, 2)
		if obj := object_by_id(app, t.hover_object); obj != nil && obj.cage != nil && t.edge != poly.NONE {
			a, b := poly.edge_verts(&obj.cage.mesh, t.edge)
			sa, a_on := gizmo.project(vp, to_world(obj.transform, cage_point(obj.cage, a)), input.size)
			sb, b_on := gizmo.project(vp, to_world(obj.transform, cage_point(obj.cage, b)), input.size)
			if a_on && b_on do overlay_line(o, sa, sb, overlay_color(MODEL_ELEMENT_COLORS[.Edge]), 4)
		}
	case .Point:
		path := make([dynamic][2]f32, context.temp_allocator)
		if s, ok := screen(app, t.start, vp, input.size); ok do append(&path, s)
		for p in t.met do if s, ok := screen(app, p, vp, input.size); ok do append(&path, s)
		append(&path, input.mouse_pos)
		overlay_polyline(o, path[:], overlay_color(MODEL_ELEMENT_COLORS[.Face]), 2)
		for s in path[:len(path) - 1] do overlay_disc(o, s, 6, point_color)
		// With no face in the making, a point under the pen is where the lift welds.
		if len(t.met) < 2 {
			if p := topo_point_near(app, input.mouse_pos, input.size, t.start); p != TOPO_NONE {
				if s, ok := screen(app, p, vp, input.size); ok do overlay_circle(o, s, 10, overlay_color(TOPO_WELD_COLOR), 3)
			}
		}
	case .Edge:
		if obj := object_by_id(app, t.object); obj != nil && obj.cage != nil && int(t.pressed_edge) < len(obj.cage.mesh.crease) {
			a, b := poly.edge_verts(&obj.cage.mesh, t.pressed_edge)
			sa, a_on := gizmo.project(vp, to_world(obj.transform, cage_point(obj.cage, a)), input.size)
			sb, b_on := gizmo.project(vp, to_world(obj.transform, cage_point(obj.cage, b)), input.size)
			shift := input.mouse_pos - t.press
			if a_on && b_on do overlay_polyline(o, {sa, sb, sb + shift, sa + shift}, overlay_color(MODEL_ELEMENT_COLORS[.Face]), 2, closed = true)
		}
	case .Relax:
		overlay_circle(o, input.mouse_pos, TOPO_RELAX_RADIUS, overlay_color(MODEL_ELEMENT_COLORS[.Point]), 2)
	case .Surface:
		// The strip's path, or with Ctrl the patch's rectangle.
		if t.alt {
			a, b := t.press, input.mouse_pos
			overlay_polyline(o, {a, {b.x, a.y}, b, {a.x, b.y}}, overlay_color(TOPO_COLOR), 2, closed = true)
		} else if len(t.stroke) > 1 {
			overlay_polyline(o, t.stroke[:], overlay_color(TOPO_COLOR), max(app.brush.radius_px, TOPO_SHEET_MIN), closed = false)
		}
	}
}
