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
// target (what it reaches from the element under the pen) are picked first, in the
// palette, on the shelf or by script; then the pen hovers over a cage, which shows what
// the press would reach and says "Action · Target" beside it, and a press acts there.
// Each action works on one kind of element, faces, edges or points, and the hover picks
// that kind: the face under the pen, the edge of it nearest the pen, or the corner of it
// nearest the pen. Actions that take a drag (Extrude, Inset, Move, Extrude edge) change
// the cage once the pen has moved past the slop and follow the drag until the pen lifts;
// Insert loop goes in at the press and the drag slides it; pair actions (Bridge, Weld,
// Connect) take the element pressed and the one the pen lifts over; tap actions act on
// the lift. Each is one undo step (History_Kind.Model). A pen that does not hover (a
// finger, an Android pen) gets the same: the press shows the target and acts.
//
// Modifiers: Ctrl (the wheel's Invert sector) gives the action's variant, ZModeler's Alt;
// Shift (the Smooth sector) snaps the drag to steps of a quarter of the mean edge.

Model_Action :: enum u8 {
	Extrude,
	Inset,
	Move,
	Delete,
	Polygroup,
	Flip,
	Insert_Loop,
	Remove_Loop,
	Collapse,
	Spin,
	Close_Hole,
	Extrude_Edge,
	Bridge,
	Weld,
	Connect,
	Dissolve_Point,
}

@(rodata)
MODEL_ACTION_NAMES := [Model_Action]string {
	.Extrude        = "Extrude",
	.Inset          = "Inset",
	.Move           = "Move",
	.Delete         = "Delete",
	.Polygroup      = "Polygroup",
	.Flip           = "Flip",
	.Insert_Loop    = "Insert loop",
	.Remove_Loop    = "Remove loop",
	.Collapse       = "Collapse",
	.Spin           = "Spin",
	.Close_Hole     = "Close hole",
	.Extrude_Edge   = "Extrude edge",
	.Bridge         = "Bridge",
	.Weld           = "Weld",
	.Connect        = "Connect",
	.Dissolve_Point = "Dissolve point",
}

// Each action as an undo step names it, in the History panel and the undo button's tip.
@(rodata)
MODEL_ACTION_WHAT := [Model_Action]string {
	.Extrude        = "extrude",
	.Inset          = "inset",
	.Move           = "move faces",
	.Delete         = "delete faces",
	.Polygroup      = "polygroup faces",
	.Flip           = "flip faces",
	.Insert_Loop    = "insert loop",
	.Remove_Loop    = "remove edges",
	.Collapse       = "collapse edges",
	.Spin           = "spin edge",
	.Close_Hole     = "close hole",
	.Extrude_Edge   = "extrude edges",
	.Bridge         = "bridge",
	.Weld           = "weld points",
	.Connect        = "connect points",
	.Dissolve_Point = "dissolve point",
}

// What each action's variant does, for the palette and the label.
@(rodata)
MODEL_ACTION_ALT := [Model_Action]string {
	.Extrude        = "sides get a new polygroup",
	.Inset          = "each face on its own",
	.Move           = "",
	.Delete         = "closes the hole with one face",
	.Polygroup      = "a new polygroup",
	.Flip           = "",
	.Insert_Loop    = "",
	.Remove_Loop    = "",
	.Collapse       = "",
	.Spin           = "",
	.Close_Hole     = "",
	.Extrude_Edge   = "out along the surface's normal instead of its plane",
	.Bridge         = "",
	.Weld           = "",
	.Connect        = "",
	.Dissolve_Point = "",
}

// What each action's help line says it does.
@(rodata)
MODEL_ACTION_HOW := [Model_Action]string {
	.Extrude        = "Press and drag to pull the faces out; Shift snaps to steps",
	.Inset          = "Press and drag to set the inset's width; Shift snaps to steps",
	.Move           = "Press and drag to move the faces along their normal; Shift snaps to steps",
	.Delete         = "Tap a face to delete what the target reaches",
	.Polygroup      = "Tap a face to give the target the polygroup below",
	.Flip           = "Tap a face to turn the target over",
	.Insert_Loop    = "Tap an edge to put a loop across its ring there; drag to slide it",
	.Remove_Loop    = "Tap an edge to remove the target's edges, joining the faces either side",
	.Collapse       = "Tap an edge to shrink the target's edges to points",
	.Spin           = "Tap an edge to turn it one step round its two faces",
	.Close_Hole     = "Tap a border edge to close its hole with one face",
	.Extrude_Edge   = "Press on a border edge and drag to grow a strip of faces out of it",
	.Bridge         = "Press on one border and lift over another to join them with a band of faces",
	.Weld           = "Press on a point and lift over another to merge the first into the second",
	.Connect        = "Press on a point and lift over another corner of its face to split the face between them",
	.Dissolve_Point = "Tap a point to remove it, joining the faces round it",
}

// What kind of element each action takes.
Model_Element :: enum u8 {
	Face,
	Edge,
	Point,
}

@(rodata)
MODEL_ACTION_ELEMENT := [Model_Action]Model_Element {
	.Extrude        = .Face,
	.Inset          = .Face,
	.Move           = .Face,
	.Delete         = .Face,
	.Polygroup      = .Face,
	.Flip           = .Face,
	.Insert_Loop    = .Edge,
	.Remove_Loop    = .Edge,
	.Collapse       = .Edge,
	.Spin           = .Edge,
	.Close_Hole     = .Edge,
	.Extrude_Edge   = .Edge,
	.Bridge         = .Edge,
	.Weld           = .Point,
	.Connect        = .Point,
	.Dissolve_Point = .Point,
}

// The actions a drag drives; Insert loop also acts on a tap. The pair actions take a
// second element where the pen lifts; the rest act on a tap.
MODEL_DRAGS :: bit_set[Model_Action]{.Extrude, .Inset, .Move, .Insert_Loop, .Extrude_Edge}
MODEL_PAIRS :: bit_set[Model_Action]{.Bridge, .Weld, .Connect}
// The edge actions that work only on border edges, whose hover picks the face's nearest
// border edge.
MODEL_BORDER_ACTIONS :: bit_set[Model_Action]{.Close_Hole, .Extrude_Edge, .Bridge}

Model_Target :: enum u8 {
	Single,
	Face_Loop,
	Island,
	Flat_Island,
	Group_Island,
	Group_All,
	Edge_Loop,
	Edge_Ring,
	Border_Loop,
}

@(rodata)
MODEL_TARGET_NAMES := [Model_Target]string {
	.Single       = "Single",
	.Face_Loop    = "Face loop",
	.Island       = "Island",
	.Flat_Island  = "Flat island",
	.Group_Island = "Group island",
	.Group_All    = "Group all",
	.Edge_Loop    = "Edge loop",
	.Edge_Ring    = "Edge ring",
	.Border_Loop  = "Border loop",
}

FACE_TARGETS :: bit_set[Model_Target]{.Single, .Face_Loop, .Island, .Flat_Island, .Group_Island, .Group_All}

// The targets each action can take; the first default is in MODEL_DEFAULT_TARGETS.
@(rodata)
MODEL_ACTION_TARGETS := [Model_Action]bit_set[Model_Target] {
	.Extrude        = FACE_TARGETS,
	.Inset          = FACE_TARGETS,
	.Move           = FACE_TARGETS,
	.Delete         = FACE_TARGETS,
	.Polygroup      = FACE_TARGETS,
	.Flip           = FACE_TARGETS,
	.Insert_Loop    = {.Edge_Ring},
	.Remove_Loop    = {.Single, .Edge_Loop, .Edge_Ring},
	.Collapse       = {.Single, .Edge_Loop, .Edge_Ring},
	.Spin           = {.Single},
	.Close_Hole     = {.Border_Loop},
	.Extrude_Edge   = {.Single, .Border_Loop},
	.Bridge         = {.Border_Loop},
	.Weld           = {.Single},
	.Connect        = {.Single},
	.Dissolve_Point = {.Single},
}

// The target each action starts with: one face, but Flip a whole piece, since turning
// over part of one is refused; a whole loop for the actions that mean one.
@(rodata)
MODEL_DEFAULT_TARGETS := [Model_Action]Model_Target {
	.Extrude        = .Single,
	.Inset          = .Single,
	.Move           = .Single,
	.Delete         = .Single,
	.Polygroup      = .Single,
	.Flip           = .Island,
	.Insert_Loop    = .Edge_Ring,
	.Remove_Loop    = .Edge_Loop,
	.Collapse       = .Single,
	.Spin           = .Single,
	.Close_Hole     = .Border_Loop,
	.Extrude_Edge   = .Border_Loop,
	.Bridge         = .Border_Loop,
	.Weld           = .Single,
	.Connect        = .Single,
	.Dissolve_Point = .Single,
}

// ZModeler's flat island tolerance.
FLAT_ISLAND_DEGREES :: 15

// What the pen is over: a cage's face, the edge of it and the corner of it nearest the
// pen, and the elements the target reaches from there (heap, kept between frames as the
// hover is): faces, edges or points, by the action's element.
Model_Hover :: struct {
	object: int, // the object's id, 0 for none
	face:   u32,
	edge:   u32,
	point:  u32,
	at:     f32, // where along the edge the pen is, from its first end (0) to its other (1)
	items:  [dynamic]u32,
}

Model_Drag_State :: enum u8 {
	None,
	Pressed, // on an element, not yet past the slop
	Dragging, // the action is made and follows the pen
}

Model_Drag :: struct {
	state:  Model_Drag_State,
	object: int,
	action: Model_Action,
	press:  [2]f32, // where the pen went down, viewport points
	alt, snap: bool,
	// The element pressed, and the target as pressed (heap).
	face, edge, point: u32,
	at:     f32,
	items:  [dynamic]u32,
	before: ^Object_Snapshot,
	set:    poly.Drag_Set,
	// The line Extrude, Move and Extrude edge follow, in the object's space, and where
	// on it the press was.
	center, normal: Vec3,
	start:  f32,
	step:   f32, // the snap step, object space
	amount: f32, // as last applied
	// Insert loop's slide: the pressed edge from its first end to its other, on screen.
	slide_from, slide_to: [2]f32,
}

// The Model tool's own state, beside the primitive Add cage makes.
model_tool_free :: proc(m: ^Model_Tool) {
	if m.drag.before != nil do history_snapshot_drop(m.drag.before)
	delete(m.hover.items)
	delete(m.drag.items)
	poly.drag_set_destroy(&m.drag.set)
}

// The target the Model tool uses with `action`: the one picked for it, or its default.
model_target :: proc(m: ^Model_Tool, action: Model_Action) -> Model_Target {
	if action in m.targeted && m.targets[action] in MODEL_ACTION_TARGETS[action] do return m.targets[action]
	return MODEL_DEFAULT_TARGETS[action]
}

// Picks the action, and with it the target last used with it.
model_pick_action :: proc(app: ^App, action: Model_Action) {
	app.model.action = action
	app.tool = .Model
}

// Picks the target for the action in hand, when the action can take it.
model_pick_target :: proc(app: ^App, target: Model_Target) {
	m := &app.model
	if target not_in MODEL_ACTION_TARGETS[m.action] do return
	m.targets[m.action] = target
	m.targeted += {m.action}
}

// The elements `target` reaches from face f, edge e or point p, by the element kind:
// faces ascending, edges along their loop, the point alone.
model_resolve :: proc(cage: ^poly.Mesh, element: Model_Element, target: Model_Target, f, e, p: u32, out: ^[dynamic]u32) {
	clear(out)
	switch element {
	case .Point:
		append(out, p)
	case .Edge:
		#partial switch target {
		case .Edge_Loop:   poly.edge_loop(cage, e, out)
		case .Edge_Ring:   poly.edge_ring(cage, e, out)
		case .Border_Loop: poly.border_loop(cage, e, out)
		case:              append(out, e)
		}
		if len(out) == 0 do append(out, e)
	case .Face:
		switch target {
		case .Single, .Edge_Loop, .Edge_Ring, .Border_Loop: append(out, f)
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
}

// What is under viewport point `pos`: the cage face, the edge of it nearest the point on
// screen (with `border`, the nearest border edge, or none), the corner of it nearest, and
// where along that edge the point lies.
model_pick :: proc(app: ^App, pos, size: [2]f32, border := false) -> (obj: ^Object, face, edge, point: u32, at: f32, ok: bool) {
	origin, dir := mouse_ray(app.camera, pos, size)
	index, _, hit := scene_raycast(app, origin, dir)
	if !hit do return
	obj = app.scene.objects[index]
	cp := obj.cage
	if cp == nil do return
	t := obj.transform
	_, tri, tri_ok := sculpt.sculptor_raycast_triangle(object_sculptor(obj), to_local(t, origin), to_local_dir(t, dir))
	if !tri_ok || int(tri) >= len(cp.face_of) do return
	m := &cp.mesh
	face = cp.face_of[tri]
	vp := view_proj_of(app, size)
	best_edge, best_point := max(f32), max(f32)
	w := poly.face_walk(m, face)
	for h in poly.face_walk_next(&w) {
		a, a_seen := gizmo.project(vp, to_world(t, m.positions[m.he_vert[h]]), size)
		b, b_seen := gizmo.project(vp, to_world(t, m.positions[poly.he_tip(m, h)]), size)
		if !a_seen || !b_seen do continue
		if d := linalg.length(pos - a); d < best_point do best_point, point = d, m.he_vert[h]
		if border && !poly.edge_border(m, poly.edge_of(h)) do continue
		d, along := segment_distance(pos, a, b)
		if d < best_edge {
			best_edge, edge = d, poly.edge_of(h)
			// Shares run from the edge's first end, which this half-edge may start at or end at.
			at = along if m.he_vert[h] == m.he_vert[2 * edge] else 1 - along
		}
	}
	return obj, face, edge, point, at, best_edge < max(f32) && best_point < max(f32)
}

// How far point p is from segment a-b, and where along it (0 at a, 1 at b) it is nearest.
segment_distance :: proc(p, a, b: [2]f32) -> (distance, along: f32) {
	ab := b - a
	along = clamp(linalg.dot(p - a, ab) / max(linalg.dot(ab, ab), 1e-12), 0, 1)
	return linalg.length(p - (a + ab * along)), along
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
			// A pair action shows the second element under the pen as it goes.
			if d.action in MODEL_PAIRS {
				model_hover(app, input.mouse_pos, input.size, true)
				return true
			}
			if d.action in MODEL_DRAGS && linalg.length(input.mouse_pos - d.press) > app.kit.ctx.theme.slop {
				return model_drag_begin(app, input)
			}
			return true
		}
		// Let go: a tap, or the end of a pair.
		d.state = .None
		if d.action in MODEL_PAIRS {
			model_hover(app, input.mouse_pos, input.size, true)
			return model_pair(app)
		}
		if d.action == .Insert_Loop {
			if !model_drag_begin(app, input) do return false
			if d.state == .Dragging do model_drag_end(app)
			return true
		}
		if d.action not_in MODEL_DRAGS do return model_tap(app)
		return true
	case .None:
	}
	model_hover(app, input.mouse_pos, input.size, input.hovered || input.primary)
	if !input.primary || !input.press || m.hover.object == 0 do return true
	obj := object_by_id(app, m.hover.object)
	select_object(app, obj)
	h := &m.hover
	d^ = {state = .Pressed, object = h.object, action = m.action, press = input.mouse_pos, alt = input.invert, snap = input.smooth, face = h.face, edge = h.edge, point = h.point, at = h.at, items = d.items, set = d.set}
	clear(&d.items)
	append(&d.items, ..h.items[:])
	return true
}

// Finds what the pen is over and what the target reaches from it; nothing when `over` is
// false (the pen is elsewhere).
model_hover :: proc(app: ^App, pos, size: [2]f32, over: bool) {
	m := &app.model
	h := &m.hover
	h.object = 0
	clear(&h.items)
	if !over do return
	obj, face, edge, point, at, ok := model_pick(app, pos, size, m.action in MODEL_BORDER_ACTIONS)
	if !ok do return
	h.object, h.face, h.edge, h.point, h.at = obj.id, face, edge, point, at
	model_resolve(&obj.cage.mesh, MODEL_ACTION_ELEMENT[m.action], model_target(m, m.action), face, edge, point, &h.items)
}

// A tap action on the pressed target: one undo step, or a note saying why not.
@(private = "file")
model_tap :: proc(app: ^App) -> bool {
	m := &app.model
	d := &m.drag
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil || len(d.items) == 0 do return true
	cage := &obj.cage.mesh
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[d.action])
	err := poly.Build_Error.None
	r: poly.Edit_Result
	#partial switch d.action {
	case .Delete:
		if len(d.items) == len(cage.face_he) {
			report(app, nil, {.Warning}, "Delete would leave %s with no faces: delete the object instead", object_label(obj))
			history_snapshot_drop(before)
			return true
		}
		r, err = poly.delete_or_dissolve(cage, d.items[:], d.alt)
	case .Flip:
		r, err = poly.flip_faces(cage, d.items[:])
	case .Polygroup:
		group := poly.group_next(cage) if d.alt else m.group
		poly.group_faces(cage, d.items[:], group)
	case .Remove_Loop:
		r, err = poly.dissolve_edges(cage, d.items[:])
	case .Collapse:
		r, err = poly.collapse_edges(cage, d.items[:])
	case .Spin:
		r, err = poly.spin_edge(cage, d.edge)
	case .Close_Hole:
		r, err = poly.close_hole(cage, d.edge, model_border_group(cage, d.edge))
	case .Dissolve_Point:
		r, err = poly.dissolve_point(cage, d.point)
	}
	poly.edit_result_destroy(&r)
	return model_commit(app, obj, before, err)
}

// Ends an action that changed the cage at once: the level made again and the undo step
// listed, or with `err` the note saying why it was refused (the cage is as it was).
@(private = "file")
model_commit :: proc(app: ^App, obj: ^Object, before: ^Object_Snapshot, err: poly.Build_Error) -> bool {
	m := &app.model
	if err != .None {
		history_snapshot_drop(before)
		model_refused(app, m.drag.action, err)
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

// The group a face closing a hole takes: that of a face beside the hole.
@(private = "file")
model_border_group :: proc(cage: ^poly.Mesh, e: u32) -> u16 {
	f := cage.he_face[2 * e]
	if f == poly.NONE do f = cage.he_face[2 * e + 1]
	return cage.group[f] if f != poly.NONE else 0
}

// A pair action: the element pressed and the one the pen lifted over (the hover), on the
// same cage.
@(private = "file")
model_pair :: proc(app: ^App) -> bool {
	m := &app.model
	d := &m.drag
	h := &m.hover
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil do return true
	if h.object != d.object {
		report(app, nil, {.Warning}, "%s needs its second %s on the same cage: lift the pen over one", MODEL_ACTION_NAMES[d.action], "border" if d.action == .Bridge else "point")
		m.refused += 1
		return true
	}
	cage := &obj.cage.mesh
	// The same element twice is a press that changed its mind.
	if (d.action == .Bridge && slice.contains(d.items[:], h.edge)) || (d.action != .Bridge && h.point == d.point) do return true
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[d.action])
	err := poly.Build_Error.None
	r: poly.Edit_Result
	#partial switch d.action {
	case .Bridge:
		r, err = poly.bridge_borders(cage, d.edge, h.edge)
	case .Weld:
		// The pressed point goes onto the one lifted over, as ZModeler's Weld points does.
		pairs := [1][2]u32{{h.point, d.point}}
		r, err = poly.merge_points(cage, pairs[:], keep_first = true)
	case .Connect:
		face, found := model_shared_face(cage, d.point, h.point)
		if !found {
			history_snapshot_drop(before)
			report(app, nil, {.Warning}, "Connect needs two corners of one face")
			m.refused += 1
			return true
		}
		r, err = poly.connect_points(cage, face, d.point, h.point)
	}
	poly.edit_result_destroy(&r)
	return model_commit(app, obj, before, err)
}

// A face with corners u and v, not joined by an edge of it: the lowest such face.
@(private = "file")
model_shared_face :: proc(cage: ^poly.Mesh, u, v: u32) -> (face: u32, ok: bool) {
	face = poly.NONE
	w := poly.vertex_walk(cage, u)
	corners := make([dynamic]u32, context.temp_allocator)
	for h in poly.vertex_walk_next(&w) {
		f := cage.he_face[h]
		if f == poly.NONE || (face != poly.NONE && f >= face) do continue
		poly.face_verts(cage, f, &corners)
		if slice.contains(corners[:], v) do face = f
	}
	return face, face != poly.NONE
}

// Says why the cage could not take the action.
@(private = "file")
model_refused :: proc(app: ^App, action: Model_Action, err: poly.Build_Error) {
	app.model.refused += 1
	why: string
	#partial switch err {
	case .Inconsistent:        why = "faces would face opposite ways across an edge (Flip turns a whole island; Bridge joins borders that run opposite ways)"
	case .Non_Manifold_Vertex: why = "what is left would touch itself at a single point"
	case .Non_Manifold_Edge:   why = "an edge would have more than two faces, the faces would leave more than one hole, or the edge needs a border it does not have"
	case .Degenerate_Face:     why = "a face would have fewer than three corners (Bridge needs two borders of as many edges; Connect two corners not side by side)"
	case:                      why = "the faces it would make are not a valid cage"
	}
	report(app, nil, {.Warning}, "%s refused: %s", MODEL_ACTION_NAMES[action], why)
}

// The drag passed the slop (Insert loop: the press lifted or passed it): the action
// changes the cage (Extrude and Inset add their faces with nothing moved yet) and the
// drag starts following the pen.
@(private = "file")
model_drag_begin :: proc(app: ^App, input: Viewport_Input) -> bool {
	m := &app.model
	d := &m.drag
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil || len(d.items) == 0 {
		d.state = .None
		return true
	}
	cage := &obj.cage.mesh
	// The snap step and the line are measured on the elements as they are.
	edges, length: f32
	center, normal: Vec3
	if MODEL_ACTION_ELEMENT[d.action] == .Face {
		for f in d.items {
			w := poly.face_walk(cage, f)
			for h in poly.face_walk_next(&w) {
				length += poly.edge_length(cage, poly.edge_of(h))
				edges += 1
			}
			center += poly.face_center(cage, f)
			normal += poly.face_area_vector(cage, f)
		}
		center /= f32(len(d.items))
	} else {
		for e in d.items {
			length += poly.edge_length(cage, e)
			edges += 1
		}
	}
	d.step = length / max(edges, 1) / 4
	d.center = center
	d.normal = linalg.normalize0(normal)
	d.before = history_snapshot(app, obj, MODEL_ACTION_WHAT[d.action])
	poly.drag_set_destroy(&d.set)
	err := poly.Build_Error.None
	ring: poly.Face_Ring
	loop: poly.Loop_Insert
	strip: poly.Border_Extrude
	rebuilt := false
	#partial switch d.action {
	case .Extrude:
		ring, d.set, err = poly.extrude_faces(cage, d.items[:], false, d.alt)
		rebuilt = true
	case .Inset:
		ring, d.set, err = poly.inset_faces(cage, d.items[:], d.alt)
		rebuilt = true
	case .Move:
		d.set = poly.move_faces(cage, d.items[:])
	case .Insert_Loop:
		loop, err = poly.insert_loop(cage, d.edge, d.at)
		if err == .None do d.set = poly.loop_slide(cage, &loop)
		rebuilt = true
	case .Extrude_Edge:
		for e in d.items do if !poly.edge_border(cage, e) do err = .Non_Manifold_Edge
		if err == .None do strip, d.set, err = poly.extrude_border(cage, d.items[:], d.alt)
		rebuilt = true
	}
	poly.face_ring_destroy(&ring)
	poly.border_extrude_destroy(&strip)
	if err != .None {
		poly.loop_insert_destroy(&loop)
		history_snapshot_drop(d.before)
		d.before = nil
		d.state = .None
		model_refused(app, d.action, err)
		return true
	}
	// An edge strip follows the mean of its points' ways out from their middle.
	if d.action == .Extrude_Edge && len(d.set.verts) > 0 {
		c, n: Vec3
		for v, i in d.set.verts {
			c += cage.positions[v]
			n += d.set.dir[i]
		}
		d.center, d.normal = c / f32(len(d.set.verts)), linalg.normalize0(n)
	}
	if d.action == .Insert_Loop {
		vp := view_proj_of(app, input.size)
		t := obj.transform
		ends := loop.ends[loop.pressed]
		d.slide_from, _ = gizmo.project(vp, to_world(t, cage.positions[ends[0]]), input.size)
		d.slide_to, _ = gizmo.project(vp, to_world(t, cage.positions[ends[1]]), input.size)
	}
	poly.loop_insert_destroy(&loop)
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
	if d.action == .Inset || d.action == .Insert_Loop || n == {} || abs(linalg.dot(n, r)) > 0.97 {
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
	#partial switch d.action {
	case .Inset:
		// An inset grows with the pen's travel whichever way it goes.
		px := camera.orbit_world_per_px(app.camera, to_world(obj.transform, d.center), input.size.y) / obj.transform.scale
		amount = linalg.length(input.mouse_pos - d.press) * px
	case .Insert_Loop:
		// A slide follows the pen along the pressed edge on screen, as a share of it.
		along := d.slide_to - d.slide_from
		amount = linalg.dot(input.mouse_pos - d.press, along) / max(linalg.dot(along, along), 1)
	}
	if input.smooth && d.step > 0 && d.action != .Insert_Loop do amount = math.round(amount / d.step) * d.step
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

// The hover's colours, as the plan's: points blue, edges amber, faces teal.
@(rodata)
MODEL_ELEMENT_COLORS := [Model_Element][4]f32 {
	.Face  = {0.3, 0.9, 0.85, 0.9},
	.Edge  = {1.0, 0.72, 0.2, 1},
	.Point = {0.35, 0.6, 1.0, 1},
}

// The Model tool's hover and its label: the elements the press would reach, lit, and
// "Action · Target" beside the pen. A pair action in hand shows its first element too,
// and a line from it to the pen.
draw_model_overlay :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	m := &app.model
	d := &m.drag
	element := MODEL_ACTION_ELEMENT[m.action]
	if d.state != .Dragging {
		if d.state == .Pressed {
			draw_model_items(app, o, input, d.object, MODEL_ACTION_ELEMENT[d.action], d.items[:])
			if d.action in MODEL_PAIRS do overlay_line(o, d.press, input.mouse_pos, overlay_color(MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]]), 2)
		}
		if d.state == .None || d.action in MODEL_PAIRS do draw_model_items(app, o, input, m.hover.object, element, m.hover.items[:])
	}
	label := fmt.tprintf("%s · %s", MODEL_ACTION_NAMES[m.action], MODEL_TARGET_NAMES[model_target(m, m.action)])
	overlay_label(o, label, input.mouse_pos + {0, -36})
}

@(private = "file")
draw_model_items :: proc(app: ^App, o: Overlay, input: Viewport_Input, id: int, element: Model_Element, items: []u32) {
	obj := object_by_id(app, id)
	if obj == nil || obj.cage == nil do return
	cage := &obj.cage.mesh
	vp := view_proj_of(app, input.size)
	t := obj.transform
	color := MODEL_ELEMENT_COLORS[element]
	// Elements behind the surface show faintly, so a ring or loop reads whole without
	// looking as if it were in front.
	shown, hidden := overlay_color(color), overlay_color({color.r, color.g, color.b, 0.3})
	b := poly.mesh_bounds(cage)
	slack := linalg.length(b.hi - b.lo) * 1e-3
	points := make([dynamic][2]f32, context.temp_allocator)
	switch element {
	case .Face:
		fill := overlay_color({color.r, color.g, color.b, 0.25})
		for f in items {
			if int(f) >= len(cage.face_he) do continue
			clear(&points)
			w := poly.face_walk(cage, f)
			seen := true
			for h in poly.face_walk_next(&w) {
				p, ok := gizmo.project(vp, to_world(t, cage.positions[cage.he_vert[h]]), input.size)
				seen &&= ok
				append(&points, p)
			}
			if !seen do continue
			front := model_seen(app, obj, poly.face_center(cage, f), input.size, slack)
			if front do overlay_fill(o, points[:], fill)
			overlay_polyline(o, points[:], shown if front else hidden, 2, closed = true)
		}
	case .Edge:
		for e in items {
			if int(e) >= len(cage.crease) do continue
			a, b := poly.edge_verts(cage, e)
			pa, a_ok := gizmo.project(vp, to_world(t, cage.positions[a]), input.size)
			pb, b_ok := gizmo.project(vp, to_world(t, cage.positions[b]), input.size)
			if !a_ok || !b_ok do continue
			front := model_seen(app, obj, (cage.positions[a] + cage.positions[b]) * 0.5, input.size, slack)
			overlay_line(o, pa, pb, shown if front else hidden, 3 if front else 2)
		}
	case .Point:
		for v in items {
			if int(v) >= len(cage.positions) do continue
			p, ok := gizmo.project(vp, to_world(t, cage.positions[v]), input.size)
			if !ok do continue
			front := model_seen(app, obj, cage.positions[v], input.size, slack)
			overlay_disc(o, p, 5 if front else 3, shown if front else hidden)
		}
	}
}

// Whether point p of `obj` (its own space) is in sight: the ray through where it shows
// on screen meets the object no nearer than p, within `slack`.
@(private = "file")
model_seen :: proc(app: ^App, obj: ^Object, p: Vec3, size: [2]f32, slack: f32) -> bool {
	t := obj.transform
	screen, ok := gizmo.project(view_proj_of(app, size), to_world(t, p), size)
	if !ok do return false
	origin, dir := mouse_ray(app.camera, screen, size)
	o, r := to_local(t, origin), linalg.normalize0(to_local_dir(t, dir))
	hit, met := sculpt.sculptor_raycast(object_sculptor(obj), o, r)
	if !met do return true
	return linalg.length(hit - o) >= linalg.length(p - o) - slack
}
