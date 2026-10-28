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
// Symmetry (the Symmetry panel's X, Y and Z) mirrors every action across those planes
// through the cage's origin, as ZModeler's and Blender's mirror editing do: the hover
// lights the images too, and the action works on both sides as one undo step.
//
// The selection (Select, and the palette's All, None, Invert, Grow and Shrink) is a flag
// per cage face, shown orange; the face actions' Selected target works on it wherever
// the press lands on that cage, as Blender's edit mode works on its selection.
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
	Select,
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
	.Select         = "Select",
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
	.Select         = "select faces",
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
	.Select         = "deselects instead",
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
	.Select         = "Tap a face, or drag across faces, to select what the target reaches; the face actions' Selected target then works on them",
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
	.Select         = .Face,
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
	Selection,
	Similar,
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
	.Selection    = "Selected",
	.Similar      = "Similar",
}

FACE_TARGETS :: bit_set[Model_Target]{.Single, .Face_Loop, .Island, .Flat_Island, .Group_Island, .Group_All, .Similar, .Selection}

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
	.Select         = FACE_TARGETS - {.Selection},
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
	.Select         = .Single,
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
	images: [dynamic]u32, // under symmetry, the items' mirror images not among them
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
	images: [dynamic]u32,
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
	delete(m.hover.images)
	delete(m.drag.items)
	delete(m.drag.images)
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
		case .Selection:
			// The selected faces, or with none the face under the pen.
			poly.selected_faces(cage, out)
			if len(out) == 0 do append(out, f)
		case .Similar:      poly.similar_faces(cage, f, out)
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
			// Select paints: what the target reaches under the pen joins as it goes.
			if d.action == .Select {
				model_hover(app, input.mouse_pos, input.size, true)
				if m.hover.object == d.object {
					for f in m.hover.items do if !slice.contains(d.items[:], f) do append(&d.items, f)
					for f in m.hover.images do if !slice.contains(d.images[:], f) do append(&d.images, f)
				}
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
		// A tap with a drag action repeats how far it went last.
		if last := m.last[d.action]; last != 0 {
			if !model_drag_begin(app, input) do return false
			if d.state != .Dragging do return true
			obj := object_by_id(app, d.object)
			d.amount = poly.drag_apply(&obj.cage.mesh, &d.set, last)
			cage_positions_moved(app, obj, d.set.verts)
			model_drag_finish(app, obj)
		}
		return true
	case .None:
	}
	model_hover(app, input.mouse_pos, input.size, input.hovered || input.primary)
	if !input.primary || !input.press || m.hover.object == 0 do return true
	obj := object_by_id(app, m.hover.object)
	select_object(app, obj)
	h := &m.hover
	d^ = {state = .Pressed, object = h.object, action = m.action, press = input.mouse_pos, alt = input.invert, snap = input.smooth, face = h.face, edge = h.edge, point = h.point, at = h.at, items = d.items, images = d.images, set = d.set}
	clear(&d.items)
	append(&d.items, ..h.items[:])
	clear(&d.images)
	append(&d.images, ..h.images[:])
	return true
}

// Finds what the pen is over and what the target reaches from it; nothing when `over` is
// false (the pen is elsewhere).
model_hover :: proc(app: ^App, pos, size: [2]f32, over: bool) {
	m := &app.model
	h := &m.hover
	h.object = 0
	clear(&h.items)
	clear(&h.images)
	if !over do return
	obj, face, edge, point, at, ok := model_pick(app, pos, size, m.action in MODEL_BORDER_ACTIONS)
	if !ok do return
	h.object, h.face, h.edge, h.point, h.at = obj.id, face, edge, point, at
	model_resolve(&obj.cage.mesh, MODEL_ACTION_ELEMENT[m.action], model_target(m, m.action), face, edge, point, &h.items)
	model_images(app, &obj.cage.mesh, MODEL_ACTION_ELEMENT[m.action], h.items[:], &h.images)
}

// The symmetry's planes, as the cage's mirrors name them.
model_axes :: proc(app: ^App) -> poly.Mirror_Axes {
	axes: poly.Mirror_Axes
	for a in app.brush.symmetry do axes += {poly.Mirror_Axis(a)}
	return axes
}

// The mirror images of `items` (faces, edges or points) under the symmetry, without the
// items themselves, into `out` (cleared first).
model_images :: proc(app: ^App, cage: ^poly.Mesh, element: Model_Element, items: []u32, out: ^[dynamic]u32) {
	clear(out)
	axes := model_axes(app)
	if axes == {} || len(items) == 0 do return
	all: []u32
	switch element {
	case .Face:  all = poly.mirror_faces(cage, items, axes, context.temp_allocator)
	case .Edge:  all = poly.mirror_edges(cage, items, axes, context.temp_allocator)
	case .Point: all = poly.mirror_points(cage, items, axes, context.temp_allocator)
	}
	for x in all do if !slice.contains(items, x) do append(out, x)
}

// The target and its images together.
@(private = "file")
model_all :: proc(d: ^Model_Drag) -> []u32 {
	all := make([]u32, len(d.items) + len(d.images), context.temp_allocator)
	copy(all, d.items[:])
	copy(all[len(d.items):], d.images[:])
	return all
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
	kept := model_keep(cage, len(d.images) > 0)
	defer model_restore(cage, &kept, err)
	#partial switch d.action {
	case .Delete:
		if len(model_all(d)) == len(cage.face_he) {
			report(app, nil, {.Warning}, "Delete would leave %s with no faces: delete the object instead", object_label(obj))
			history_snapshot_drop(before)
			return true
		}
		r, err = poly.delete_or_dissolve(cage, model_all(d), d.alt)
	case .Flip:
		r, err = poly.flip_faces(cage, model_all(d))
	case .Polygroup:
		group := poly.group_next(cage) if d.alt else m.group
		poly.group_faces(cage, model_all(d), group)
	case .Select:
		// A selection that changes nothing is no undo step.
		if !poly.select_set(cage, model_all(d), !d.alt) {
			history_snapshot_drop(before)
			return true
		}
	case .Remove_Loop:
		r, err = poly.dissolve_edges(cage, model_all(d))
	case .Collapse:
		r, err = poly.collapse_edges(cage, model_all(d))
	case .Spin, .Close_Hole:
		// One at a time, the pressed edge first; each found again by its ends.
		ends := model_edge_ends(cage, {d.edge}, d.images[:])
		for pair, i in ends {
			e := model_edge_by_ends(cage, pair[0], pair[1])
			if e == poly.NONE do continue
			// A hole an earlier close already filled is left alone.
			if d.action == .Close_Hole && !poly.edge_border(cage, e) do continue
			step: poly.Edit_Result
			if d.action == .Spin {
				step, err = poly.spin_edge(cage, e)
			} else {
				step, err = poly.close_hole(cage, e, model_border_group(cage, e))
			}
			if err == .None do for &q in ends[i + 1:] do q = {model_remap(&step, q[0]), model_remap(&step, q[1])}
			poly.edit_result_destroy(&step)
			if err != .None do break
		}
	case .Dissolve_Point:
		// One at a time, each found again through the new numbering.
		points := model_all(d)
		for i in 0 ..< len(points) {
			v := points[i]
			if v == poly.NONE do continue
			step: poly.Edit_Result
			step, err = poly.dissolve_point(cage, v)
			if err != .None {
				poly.edit_result_destroy(&step)
				break
			}
			for &w in points[i + 1:] do w = model_remap(&step, w)
			poly.edit_result_destroy(&step)
		}
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

// The ends of `first`'s edges, then of `images`', in that order.
@(private = "file")
model_edge_ends :: proc(cage: ^poly.Mesh, first: []u32, images: []u32) -> [][2]u32 {
	out := make([dynamic][2]u32, context.temp_allocator)
	for e in first {
		a, b := poly.edge_verts(cage, e)
		append(&out, [2]u32{a, b})
	}
	for e in images {
		a, b := poly.edge_verts(cage, e)
		append(&out, [2]u32{a, b})
	}
	return out[:]
}

// Where point v went in an edit: its new id, or NONE when it went (or was NONE).
@(private = "file")
model_remap :: proc(r: ^poly.Edit_Result, v: u32) -> u32 {
	return poly.NONE if v == poly.NONE || int(v) >= len(r.vert) else r.vert[v]
}

// A copy of the cage before an action of several steps (symmetry's images, one at a
// time), when `several`: a refusal part way puts it back, as a refused single step leaves
// the cage as it was.
@(private = "file")
model_keep :: proc(cage: ^poly.Mesh, several: bool) -> (kept: Maybe(poly.Mesh)) {
	if several do kept = poly.mesh_clone(cage^)
	return
}

// Puts the kept copy back when `err` refused the action, and frees it either way.
@(private = "file")
model_restore :: proc(cage: ^poly.Mesh, kept: ^Maybe(poly.Mesh), err: poly.Build_Error) {
	k, ok := kept.?
	if !ok do return
	if err != .None {
		poly.mesh_destroy(cage)
		cage^ = k
	} else {
		poly.mesh_destroy(&k)
	}
	kept^ = nil
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
	// Before anything temporary: a snapshot frees the frame's temporary memory.
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[d.action])
	// The pair as the points that name it, the pressed element's then the lifted one's
	// (edges by their two ends, points alone, NONE after), then under symmetry each image
	// of it, found before any step renumbers the points.
	named: [4]u32 = {d.point, poly.NONE, h.point, poly.NONE}
	if d.action == .Bridge {
		named[0], named[1] = poly.edge_verts(cage, d.edge)
		named[2], named[3] = poly.edge_verts(cage, h.edge)
	}
	quads := make([dynamic][4]u32, context.temp_allocator)
	append(&quads, named)
	if axes := model_axes(app); axes != {} {
		each: [4][dynamic; 8]u32
		for v, i in named do if v != poly.NONE do each[i] = poly.mirror_point_each(cage, v, axes)
		for k in 1 ..< len(each[0]) {
			q := [4]u32{poly.NONE, poly.NONE, poly.NONE, poly.NONE}
			for i in 0 ..< 4 do if named[i] != poly.NONE do q[i] = each[i][k]
			append(&quads, q)
		}
	}
	err := poly.Build_Error.None
	kept := model_keep(cage, len(quads) > 1)
	defer model_restore(cage, &kept, err)
	if d.action == .Weld {
		// The pressed point goes onto the one lifted over, as ZModeler's Weld points does;
		// a point welded to its own image meets it halfway instead, on the plane.
		pairs := make([dynamic][2]u32, context.temp_allocator)
		mean := false
		for q, i in quads {
			if q[0] == poly.NONE || q[2] == poly.NONE do continue
			append(&pairs, [2]u32{q[2], q[0]})
			if i > 0 && (q[0] == d.point || q[0] == h.point) do mean = true
		}
		r: poly.Edit_Result
		r, err = poly.merge_points(cage, pairs[:], keep_first = !mean)
		poly.edit_result_destroy(&r)
		return model_commit(app, obj, before, err)
	}
	// Bridge and Connect: one at a time, each image found again by its points; an image
	// an earlier step already joined (a border bridged to its own mirror, two points
	// connected across the plane) is left alone.
	for i in 0 ..< len(quads) {
		q := quads[i]
		step: poly.Edit_Result
		if d.action == .Bridge {
			a, b := model_edge_by_ends(cage, q[0], q[1]), model_edge_by_ends(cage, q[2], q[3])
			if a == poly.NONE || b == poly.NONE || !poly.edge_border(cage, a) || !poly.edge_border(cage, b) do continue
			step, err = poly.bridge_borders(cage, a, b)
		} else {
			if q[0] == poly.NONE || q[2] == poly.NONE || model_edge_by_ends(cage, q[0], q[2]) != poly.NONE do continue
			face, found := model_shared_face(cage, q[0], q[2])
			if !found && i == 0 {
				history_snapshot_drop(before)
				report(app, nil, {.Warning}, "Connect needs two corners of one face")
				m.refused += 1
				return true
			}
			if !found do continue
			step, err = poly.connect_points(cage, face, q[0], q[2])
		}
		if err == .None do for &rest in quads[i + 1:] do for &v in rest do v = model_remap(&step, v)
		poly.edit_result_destroy(&step)
		if err != .None do break
	}
	return model_commit(app, obj, before, err)
}

// The edge joining points a and b, either way round, or NONE.
@(private = "file")
model_edge_by_ends :: proc(cage: ^poly.Mesh, a, b: u32) -> u32 {
	if a == poly.NONE || b == poly.NONE do return poly.NONE
	h := poly.find_half_edge(cage, a, b)
	if h == poly.NONE do h = poly.find_half_edge(cage, b, a)
	return poly.NONE if h == poly.NONE else poly.edge_of(h)
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
	slide_from, slide_to: Vec3
	rebuilt := false
	#partial switch d.action {
	case .Extrude:
		ring, d.set, err = poly.extrude_faces(cage, model_all(d), false, d.alt)
		rebuilt = true
	case .Inset:
		ring, d.set, err = poly.inset_faces(cage, model_all(d), d.alt)
		rebuilt = true
	case .Move:
		d.set = poly.move_faces(cage, model_all(d))
	case .Insert_Loop:
		kept := model_keep(cage, len(d.images) > 0)
		loop, err = poly.insert_loop(cage, d.edge, d.at)
		if err == .None {
			d.set = poly.loop_slide(cage, &loop)
			// The slide's line on screen runs along the pressed edge, from the end a share of
			// 0 lies on; found before any image renumbers the points.
			ends := loop.ends[loop.pressed]
			slide_from, slide_to = cage.positions[ends[0]], cage.positions[ends[1]]
			err = model_mirror_loops(app, cage, &d.set, loop.pressed)
		}
		model_restore(cage, &kept, err)
		rebuilt = true
	case .Extrude_Edge:
		all := model_all(d)
		for e in all do if !poly.edge_border(cage, e) do err = .Non_Manifold_Edge
		if err == .None do strip, d.set, err = poly.extrude_border(cage, all, d.alt)
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
	// An edge strip follows the mean of its points' ways out from their middle: the points
	// of the pressed edges, which extrude_border lists first, so a mirrored strip, whose
	// ways cancel these, does not turn the line.
	if d.action == .Extrude_Edge && len(d.set.verts) > 0 {
		c, n: Vec3
		k := model_point_count(cage, d.items[:])
		for i in 0 ..< k {
			c += cage.positions[d.set.verts[i]]
			n += d.set.dir[i]
		}
		d.center, d.normal = c / f32(k), linalg.normalize0(n)
	}
	if d.action == .Insert_Loop {
		vp := view_proj_of(app, input.size)
		t := obj.transform
		d.slide_from, _ = gizmo.project(vp, to_world(t, slide_from), input.size)
		d.slide_to, _ = gizmo.project(vp, to_world(t, slide_to), input.size)
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

// Under symmetry, Insert loop's images: a loop through the mirror image of the pressed
// point on each image of the pressed edge, its slide joined to `set` so the loops slide as
// mirror images of each other. An image that falls on a point adds no loop: the press was
// on the plane, where one loop is its own image and stays there. `pressed` is the pressed
// point's place in `set`.
@(private = "file")
model_mirror_loops :: proc(app: ^App, cage: ^poly.Mesh, set: ^poly.Drag_Set, pressed: int) -> poly.Build_Error {
	axes := model_axes(app)
	if axes == {} do return .None
	p0, dir0 := cage.positions[set.verts[pressed]], set.dir[pressed]
	slack := poly.mirror_slack(cage)
	signs := poly.mirror_signs(axes)
	for s in signs[1:] {
		// Loops on either side of a plane meet on it, so the slide stops short of it; a
		// loop on the plane stays (a range of a millionth, drag_apply's "no range" being
		// an empty one).
		for k in 0 ..< 3 do if s[k] < 0 && dir0[k] != 0 {
			if abs(p0[k]) <= slack {
				set.lo, set.hi = -1e-6, 1e-6
				continue
			}
			u := -p0[k] / dir0[k]
			if u > 0 do set.hi = min(set.hi, u * 0.98)
			else do set.lo = max(set.lo, u * 0.98)
		}
		e, share, found := poly.edge_through(cage, p0 * s, dir0 * s, slack)
		if !found do continue
		loop, err := poly.insert_loop(cage, e, share)
		if err != .None do return err
		img := poly.loop_slide(cage, &loop)
		// In the first loop's units (a share of its edges, not of the part of an edge an
		// earlier loop left) and moving as the mirror of it.
		way := img.dir[loop.pressed]
		scale := linalg.length(dir0) / max(linalg.length(way), 1e-12)
		if linalg.dot(way, dir0 * s) < 0 do scale = -scale
		for &w in img.dir do w *= scale
		lo, hi := img.lo / scale, img.hi / scale
		if scale < 0 do lo, hi = hi, lo
		model_join_slides(set, &img, &loop.edit, lo, hi)
		poly.loop_insert_destroy(&loop)
	}
	return .None
}

// Joins slide `img`, which `edit` just made, to `set`, whose points `edit` renumbered;
// the joined slide stays within both ranges.
@(private = "file")
model_join_slides :: proc(set, img: ^poly.Drag_Set, edit: ^poly.Edit_Result, lo, hi: f32) {
	n, k := len(set.verts), len(img.verts)
	joined := poly.Drag_Set {
		verts = make([]u32, n + k),
		base  = make([]Vec3, n + k),
		dir   = make([]Vec3, n + k),
		lo    = max(set.lo, lo),
		hi    = min(set.hi, hi),
	}
	for v, i in set.verts do joined.verts[i] = edit.vert[v]
	copy(joined.verts[n:], img.verts)
	copy(joined.base, set.base)
	copy(joined.base[n:], img.base)
	copy(joined.dir, set.dir)
	copy(joined.dir[n:], img.dir)
	poly.drag_set_destroy(set)
	poly.drag_set_destroy(img)
	set^ = joined
}

// How many points `edges` have between them.
@(private = "file")
model_point_count :: proc(cage: ^poly.Mesh, edges: []u32) -> int {
	points := make([dynamic]u32, context.temp_allocator)
	for e in edges {
		a, b := poly.edge_verts(cage, e)
		if !slice.contains(points[:], a) do append(&points, a)
		if !slice.contains(points[:], b) do append(&points, b)
	}
	return max(len(points), 1)
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
	if d.amount != 0 do app.model.last[d.action] = d.amount
	adjust_set_model(app, obj, d.amount)
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

// The selected faces' colour, Blender's edit mode orange.
MODEL_SELECTION_COLOR :: [4]f32{1.0, 0.55, 0.15, 0.9}

// The Model tool's hover and its label: the elements the press would reach, lit, and
// "Action · Target" beside the pen. A pair action in hand shows its first element too,
// and a line from it to the pen.
draw_model_overlay :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	m := &app.model
	d := &m.drag
	element := MODEL_ACTION_ELEMENT[m.action]
	// Each shown cage's selection, under the hover.
	picked := make([dynamic]u32, context.temp_allocator)
	for obj in app.scene.objects {
		if obj.cage == nil || !object_shown(app, obj) do continue
		poly.selected_faces(&obj.cage.mesh, &picked)
		if len(picked) > 0 do draw_model_items(app, o, input, obj.id, .Face, picked[:], MODEL_SELECTION_COLOR)
	}
	if d.state != .Dragging {
		if d.state == .Pressed {
			draw_model_items(app, o, input, d.object, MODEL_ACTION_ELEMENT[d.action], d.items[:], MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]])
			draw_model_items(app, o, input, d.object, MODEL_ACTION_ELEMENT[d.action], d.images[:], MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]])
			if d.action in MODEL_PAIRS do overlay_line(o, d.press, input.mouse_pos, overlay_color(MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]]), 2)
		}
		if d.state == .None || d.action in MODEL_PAIRS {
			draw_model_items(app, o, input, m.hover.object, element, m.hover.items[:], MODEL_ELEMENT_COLORS[element])
			draw_model_items(app, o, input, m.hover.object, element, m.hover.images[:], MODEL_ELEMENT_COLORS[element])
		}
	}
	label := fmt.tprintf("%s · %s", MODEL_ACTION_NAMES[m.action], MODEL_TARGET_NAMES[model_target(m, m.action)])
	// A drag says how far it has gone, as ZModeler's floating value does.
	if d.state == .Dragging {
		amount := fmt.tprintf("%+.0f%%", d.amount * 100) if d.action == .Insert_Loop else fmt.tprintf("%+.3f", d.amount)
		label = fmt.tprintf("%s  %s", label, amount)
	}
	overlay_label(o, label, input.mouse_pos + {0, -36})
}

@(private = "file")
draw_model_items :: proc(app: ^App, o: Overlay, input: Viewport_Input, id: int, element: Model_Element, items: []u32, color: [4]f32) {
	obj := object_by_id(app, id)
	if obj == nil || obj.cage == nil do return
	cage := &obj.cage.mesh
	vp := view_proj_of(app, input.size)
	t := obj.transform
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
