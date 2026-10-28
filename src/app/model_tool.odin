package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../camera"
import "../gizmo"
import "../poly"
import "../sculpt"

// The Model tool's pen grammar, as ZModeler's: an action (what a press does) and a
// target (what it reaches from the face under the pen) are picked first, in the palette,
// on the shelf or by script; then the pen hovers over a cage, which shows what the press
// would reach and says "Action · Target" beside it, and a press acts there. Actions that
// take a drag (Extrude, Inset, Move) change the cage once the pen has moved past the slop
// and follow the drag until the pen lifts; tap actions (Delete, Polygroup, Flip) act on
// the lift. Each is one undo step (History_Kind.Model). A pen that does not hover (a
// finger, an Android pen) gets the same: the press shows the target and acts.
//
// Modifiers: Ctrl (the wheel's Invert sector) gives the action's variant, ZModeler's Alt;
// Shift (the Smooth sector) snaps the drag to steps of a quarter of the faces' mean edge.

Model_Action :: enum u8 {
	Extrude,
	Inset,
	Move,
	Delete,
	Polygroup,
	Flip,
}

@(rodata)
MODEL_ACTION_NAMES := [Model_Action]string {
	.Extrude   = "Extrude",
	.Inset     = "Inset",
	.Move      = "Move",
	.Delete    = "Delete",
	.Polygroup = "Polygroup",
	.Flip      = "Flip",
}

// What each action's variant does, for the palette and the label.
@(rodata)
MODEL_ACTION_ALT := [Model_Action]string {
	.Extrude   = "sides get a new polygroup",
	.Inset     = "each face on its own",
	.Move      = "",
	.Delete    = "closes the hole with one face",
	.Polygroup = "a new polygroup",
	.Flip      = "",
}

// Each action as an undo step names it, in the History panel and the undo button's tip.
@(rodata)
MODEL_ACTION_WHAT := [Model_Action]string {
	.Extrude   = "extrude",
	.Inset     = "inset",
	.Move      = "move faces",
	.Delete    = "delete faces",
	.Polygroup = "polygroup faces",
	.Flip      = "flip faces",
}

// The actions a drag drives; the rest act on a tap.
MODEL_DRAGS :: bit_set[Model_Action]{.Extrude, .Inset, .Move}

Model_Target :: enum u8 {
	Single,
	Face_Loop,
	Island,
	Flat_Island,
	Group_Island,
	Group_All,
}

@(rodata)
MODEL_TARGET_NAMES := [Model_Target]string {
	.Single       = "Single",
	.Face_Loop    = "Face loop",
	.Island       = "Island",
	.Flat_Island  = "Flat island",
	.Group_Island = "Group island",
	.Group_All    = "Group all",
}

// The target each action starts with: one face, but Flip a whole piece, since turning
// over part of one is refused.
@(rodata)
MODEL_DEFAULT_TARGETS := [Model_Action]Model_Target {
	.Extrude   = .Single,
	.Inset     = .Single,
	.Move      = .Single,
	.Delete    = .Single,
	.Polygroup = .Single,
	.Flip      = .Island,
}

// ZModeler's flat island tolerance.
FLAT_ISLAND_DEGREES :: 15

// What the pen is over: a cage's face and the edge of it nearest the pen, and the faces
// the target reaches from there (heap, kept between frames as the hover is).
Model_Hover :: struct {
	object: int, // the object's id, 0 for none
	face:   u32,
	edge:   u32,
	faces:  [dynamic]u32,
}

Model_Drag_State :: enum u8 {
	None,
	Pressed, // on a face, not yet past the slop
	Dragging, // the action is made and follows the pen
}

Model_Drag :: struct {
	state:  Model_Drag_State,
	object: int,
	action: Model_Action,
	press:  [2]f32, // where the pen went down, viewport points
	alt, snap: bool,
	faces:  [dynamic]u32, // the target as pressed (heap)
	before: ^Object_Snapshot,
	set:    poly.Drag_Set,
	// The line Extrude and Move follow, in the object's space, and where on it the press was.
	center, normal: Vec3,
	start:  f32,
	step:   f32, // the snap step, object space
	amount: f32, // as last applied
}

// The Model tool's own state, beside the primitive Add cage makes.
model_tool_free :: proc(m: ^Model_Tool) {
	if m.drag.before != nil do history_snapshot_drop(m.drag.before)
	delete(m.hover.faces)
	delete(m.drag.faces)
	poly.drag_set_destroy(&m.drag.set)
}

// The target the Model tool uses with `action`: the one picked for it, or its default.
model_target :: proc(m: ^Model_Tool, action: Model_Action) -> Model_Target {
	if action in m.targeted do return m.targets[action]
	return MODEL_DEFAULT_TARGETS[action]
}

// Picks the action, and with it the target last used with it.
model_pick_action :: proc(app: ^App, action: Model_Action) {
	app.model.action = action
	app.tool = .Model
}

// Picks the target for the action in hand.
model_pick_target :: proc(app: ^App, target: Model_Target) {
	m := &app.model
	m.targets[m.action] = target
	m.targeted += {m.action}
}

// The faces `target` reaches from face f (edge e of it for a face loop), ascending.
model_resolve :: proc(cage: ^poly.Mesh, target: Model_Target, f, e: u32, out: ^[dynamic]u32) {
	clear(out)
	switch target {
	case .Single:       append(out, f)
	case .Face_Loop:
		poly.face_loop(cage, e, out)
		if len(out) == 0 do append(out, f)
		slice.sort(out[:])
	case .Island:       poly.island(cage, f, out)
	case .Flat_Island:  poly.flat_island(cage, f, FLAT_ISLAND_DEGREES, out)
	case .Group_Island: poly.group_island(cage, f, out)
	case .Group_All:    poly.group_all(cage, cage.group[f], out)
	}
}

// The cage face under viewport point `pos` and the edge of it nearest that point on screen.
model_pick :: proc(app: ^App, pos, size: [2]f32) -> (obj: ^Object, face, edge: u32, ok: bool) {
	origin, dir := mouse_ray(app.camera, pos, size)
	index, _, hit := scene_raycast(app, origin, dir)
	if !hit do return
	obj = app.scene.objects[index]
	cp := obj.cage
	if cp == nil do return obj, 0, 0, false
	t := obj.transform
	_, tri, tri_ok := sculpt.sculptor_raycast_triangle(object_sculptor(obj), to_local(t, origin), to_local_dir(t, dir))
	if !tri_ok || int(tri) >= len(cp.face_of) do return obj, 0, 0, false
	face = cp.face_of[tri]
	vp := view_proj_of(app, size)
	best := max(f32)
	w := poly.face_walk(&cp.mesh, face)
	for h in poly.face_walk_next(&w) {
		a, a_seen := gizmo.project(vp, to_world(t, cp.mesh.positions[cp.mesh.he_vert[h]]), size)
		b, b_seen := gizmo.project(vp, to_world(t, cp.mesh.positions[poly.he_tip(&cp.mesh, h)]), size)
		if !a_seen || !b_seen do continue
		if d := segment_distance(pos, a, b); d < best do best, edge = d, poly.edge_of(h)
	}
	return obj, face, edge, best < max(f32)
}

// How far point p is from segment a-b.
segment_distance :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	t := clamp(linalg.dot(p - a, ab) / max(linalg.dot(ab, ab), 1e-12), 0, 1)
	return linalg.length(p - (a + ab * t))
}

// The Model tool, a frame: the hover, then the press, the drag and the lift. Returns false
// only on a GPU failure.
model_tool_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	m := &app.model
	d := &m.drag
	switch d.state {
	case .Dragging:
		obj := object_by_id(app, d.object)
		if obj == nil || obj.cage == nil {
			model_drag_drop(app)
			return true
		}
		if input.primary {
			model_drag_follow(app, obj, input)
			return true
		}
		model_drag_finish(app, obj)
		return true
	case .Pressed:
		if input.primary {
			if d.action in MODEL_DRAGS && linalg.length(input.mouse_pos - d.press) > app.kit.ctx.theme.slop {
				return model_drag_begin(app, input)
			}
			return true
		}
		// Let go without moving: a tap.
		d.state = .None
		if d.action not_in MODEL_DRAGS do return model_tap(app)
		return true
	case .None:
	}
	model_hover(app, input.mouse_pos, input.size, input.hovered || input.primary)
	if !input.primary || !input.press || m.hover.object == 0 do return true
	obj := object_by_id(app, m.hover.object)
	select_object(app, obj)
	d^ = {state = .Pressed, object = m.hover.object, action = m.action, press = input.mouse_pos, alt = input.invert, snap = input.smooth, faces = d.faces, set = d.set}
	clear(&d.faces)
	append(&d.faces, ..m.hover.faces[:])
	return true
}

// Finds what the pen is over and what the target reaches from it; nothing when `over` is
// false (the pen is elsewhere).
model_hover :: proc(app: ^App, pos, size: [2]f32, over: bool) {
	h := &app.model.hover
	h.object = 0
	clear(&h.faces)
	if !over do return
	obj, face, edge, ok := model_pick(app, pos, size)
	if !ok do return
	h.object, h.face, h.edge = obj.id, face, edge
	model_resolve(&obj.cage.mesh, model_target(&app.model, app.model.action), face, edge, &h.faces)
}

// A tap action on the pressed target: one undo step, or a note saying why not.
@(private = "file")
model_tap :: proc(app: ^App) -> bool {
	m := &app.model
	d := &m.drag
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil || len(d.faces) == 0 do return true
	cage := &obj.cage.mesh
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[d.action])
	err := poly.Build_Error.None
	#partial switch d.action {
	case .Delete:
		if len(d.faces) == len(cage.face_he) {
			report(app, nil, {.Warning}, "Delete would leave %s with no faces: delete the object instead", object_label(obj))
			history_snapshot_drop(before)
			return true
		}
		r: poly.Edit_Result
		r, err = poly.delete_or_dissolve(cage, d.faces[:], d.alt)
		poly.edit_result_destroy(&r)
	case .Flip:
		r: poly.Edit_Result
		r, err = poly.flip_faces(cage, d.faces[:])
		poly.edit_result_destroy(&r)
	case .Polygroup:
		group := poly.group_next(cage) if d.alt else m.group
		poly.group_faces(cage, d.faces[:], group)
	}
	if err != .None {
		history_snapshot_drop(before)
		model_refused(app, d.action, err)
		return true
	}
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	m.done += 1
	return true
}

// Says why the cage could not take the action.
@(private = "file")
model_refused :: proc(app: ^App, action: Model_Action, err: poly.Build_Error) {
	app.model.refused += 1
	why: string
	#partial switch err {
	case .Inconsistent:        why = "faces would face opposite ways across an edge (Flip turns a whole island)"
	case .Non_Manifold_Vertex: why = "what is left would touch itself at a single point"
	case .Non_Manifold_Edge:   why = "an edge would have more than two faces, or the faces leave more than one hole"
	case:                      why = "the faces it would make are not a valid cage"
	}
	report(app, nil, {.Warning}, "%s refused: %s", MODEL_ACTION_NAMES[action], why)
}

// The drag passed the slop: the action changes the cage (Extrude and Inset add their
// faces with nothing moved yet) and the drag starts following the pen.
@(private = "file")
model_drag_begin :: proc(app: ^App, input: Viewport_Input) -> bool {
	m := &app.model
	d := &m.drag
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil || len(d.faces) == 0 {
		d.state = .None
		return true
	}
	cage := &obj.cage.mesh
	// The snap step and the line are measured on the faces as they are.
	edges, length: f32
	center, normal: Vec3
	for f in d.faces {
		w := poly.face_walk(cage, f)
		for h in poly.face_walk_next(&w) {
			length += poly.edge_length(cage, poly.edge_of(h))
			edges += 1
		}
		center += poly.face_center(cage, f)
		normal += poly.face_area_vector(cage, f)
	}
	d.step = length / max(edges, 1) / 4
	d.center = center / f32(len(d.faces))
	d.normal = linalg.normalize0(normal)
	d.before = history_snapshot(app, obj, MODEL_ACTION_WHAT[d.action])
	poly.drag_set_destroy(&d.set)
	err := poly.Build_Error.None
	ring: poly.Face_Ring
	rebuilt := false
	#partial switch d.action {
	case .Extrude:
		ring, d.set, err = poly.extrude_faces(cage, d.faces[:], false, d.alt)
		rebuilt = true
	case .Inset:
		ring, d.set, err = poly.inset_faces(cage, d.faces[:], d.alt)
		rebuilt = true
	case .Move:
		d.set = poly.move_faces(cage, d.faces[:])
	}
	poly.face_ring_destroy(&ring)
	if err != .None {
		history_snapshot_drop(d.before)
		d.before = nil
		d.state = .None
		model_refused(app, d.action, err)
		return true
	}
	if rebuilt && !cage_rebuild(app, obj) {
		model_drag_drop(app)
		return false
	}
	d.state = .Dragging
	d.amount = 0
	d.start = model_drag_along(app, obj, d.press, input.size)
	model_drag_follow(app, obj, input)
	return true
}

// Where along the drag's line viewport point `pos` lies, in the object's units: the
// nearest point of the line to the ray through `pos`; for a line seen end on, the
// pen's height on screen instead, up for out.
@(private = "file")
model_drag_along :: proc(app: ^App, obj: ^Object, pos, size: [2]f32) -> f32 {
	d := &app.model.drag
	t := obj.transform
	origin, dir := mouse_ray(app.camera, pos, size)
	o, r := to_local(t, origin), to_local_dir(t, dir)
	n := d.normal
	if d.action == .Inset || n == {} || abs(linalg.dot(n, r)) > 0.97 {
		px := camera.orbit_world_per_px(app.camera, to_world(t, d.center), size.y) / t.scale
		return -pos.y * px
	}
	// The closest points of the line center + n s and the ray o + r u.
	w := d.center - o
	b := linalg.dot(n, r)
	den := 1 - b * b
	return (b * linalg.dot(r, w) - linalg.dot(n, w)) / den
}

// Moves the drag's vertices as far as the pen has gone and sends them to the level.
@(private = "file")
model_drag_follow :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	d := &app.model.drag
	amount := model_drag_along(app, obj, input.mouse_pos, input.size) - d.start
	// An inset grows with the pen's travel whichever way it goes.
	if d.action == .Inset {
		px := camera.orbit_world_per_px(app.camera, to_world(obj.transform, d.center), input.size.y) / obj.transform.scale
		amount = linalg.length(input.mouse_pos - d.press) * px
	}
	if input.smooth && d.step > 0 do amount = math.round(amount / d.step) * d.step
	if amount == d.amount do return
	d.amount = poly.drag_apply(&obj.cage.mesh, &d.set, amount)
	cage_positions_moved(app, obj, d.set.verts)
}

// The pen lifted: the drag is one undo step.
@(private = "file")
model_drag_finish :: proc(app: ^App, obj: ^Object) {
	d := &app.model.drag
	history_record_swap(app, obj.id, d.before, kind = .Model)
	d.before = nil
	d.state = .None
	app.model.done += 1
}

// Ends a drag whose object went, or whose rebuild failed, recording nothing.
@(private = "file")
model_drag_drop :: proc(app: ^App) {
	d := &app.model.drag
	if d.before != nil do history_snapshot_drop(d.before)
	d.before = nil
	d.state = .None
}

// Ends any drag in hand, as when the tool changes under it: what it did stays, as one step.
model_drag_end :: proc(app: ^App) {
	d := &app.model.drag
	if d.state != .Dragging {
		d.state = .None
		return
	}
	if obj := object_by_id(app, d.object); obj != nil && obj.cage != nil {
		model_drag_finish(app, obj)
		return
	}
	model_drag_drop(app)
}

// The Model tool's hover and its label: the faces the press would reach, filled and
// outlined, and "Action · Target" beside the pen.
draw_model_overlay :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	m := &app.model
	faces := m.hover.faces[:]
	id := m.hover.object
	if m.drag.state != .None do faces, id = m.drag.faces[:], m.drag.object
	obj := object_by_id(app, id)
	if obj == nil || obj.cage == nil do return
	cage := &obj.cage.mesh
	vp := view_proj_of(app, input.size)
	fill := overlay_color({0.2, 0.75, 0.7, 0.25})
	line := overlay_color({0.3, 0.9, 0.85, 0.9})
	points := make([dynamic][2]f32, context.temp_allocator)
	if m.drag.state != .Dragging {
		for f in faces {
			if int(f) >= len(cage.face_he) do continue
			clear(&points)
			w := poly.face_walk(cage, f)
			seen := true
			for h in poly.face_walk_next(&w) {
				p, ok := gizmo.project(vp, to_world(obj.transform, cage.positions[cage.he_vert[h]]), input.size)
				seen &&= ok
				append(&points, p)
			}
			if !seen do continue
			overlay_fill(o, points[:], fill)
			overlay_polyline(o, points[:], line, 2, closed = true)
		}
	}
	target := model_target(m, m.action)
	label := fmt.tprintf("%s · %s", MODEL_ACTION_NAMES[m.action], MODEL_TARGET_NAMES[target])
	overlay_label(o, label, input.mouse_pos + {0, -36})
}
