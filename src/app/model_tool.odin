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
	Crease,
	Crease_Point,
	Bevel,
	Circle_Loop,
	Space_Loop,
	Flatten_Loop,
	Knife,
	Align,
	Spine,
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
	.Crease         = "Crease",
	.Crease_Point   = "Crease point",
	.Bevel          = "Bevel",
	.Circle_Loop    = "Circle loop",
	.Space_Loop     = "Space loop",
	.Flatten_Loop   = "Flatten loop",
	.Knife          = "Knife",
	.Align          = "Align parts",
	.Spine          = "Spine",
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
	.Crease         = "crease edges",
	.Crease_Point   = "crease points",
	.Bevel          = "bevel edges",
	.Circle_Loop    = "circle loop",
	.Space_Loop     = "space loop",
	.Flatten_Loop   = "flatten loop",
	.Knife          = "knife cut",
	.Align          = "align parts",
	.Spine          = "spine",
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
	.Crease         = "removes the crease",
	.Crease_Point   = "removes the crease",
	.Bevel          = "",
	.Circle_Loop    = "fits the circle inside the loop instead of through it",
	.Space_Loop     = "",
	.Flatten_Loop   = "",
	.Knife          = "",
	.Align          = "faces the same way, so the part passes into the other",
	.Spine          = "an arc from the faces to where the pen lifts, in place of the path drawn",
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
	.Crease         = "Tap an edge to crease what the target reaches, so Smooth keeps it sharp; drag up or down to set how sharp, from soft to fully sharp",
	.Crease_Point   = "Tap a point to keep it a sharp corner when smoothed; drag up or down to set how sharp",
	.Bevel          = "Press on an edge and drag up to round what the target reaches, sideways for more or fewer segments; below where you pressed gives a flat chamfer. Shift snaps the width to steps",
	.Circle_Loop    = "Tap an edge to round its closed loop into a circle in the loop's own plane",
	.Space_Loop     = "Tap an edge to spread its loop's points evenly along it, the ends of an open loop staying",
	.Flatten_Loop   = "Tap an edge to move its loop's points onto the plane the loop lies nearest",
	.Knife          = "Draw a stroke across the cage, starting beside it if you like: each face it crosses is cut along it. Or tap edges in turn to cut a path between them; a tap off the cage ends it",
	.Align          = "Press on a part and lift over a face of another part: they join face to face, centre on centre, the edges lined up. Tap the part just joined to turn it a step; Alt and a tap flips it",
	.Spine          = "Press on a face and draw a path: the target grows along it in steps about its edges long, turning as the path turns, and a pen's pressure sets its size along the way",
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
	.Crease         = .Edge,
	.Crease_Point   = .Point,
	.Bevel          = .Edge,
	.Circle_Loop    = .Edge,
	.Space_Loop     = .Edge,
	.Flatten_Loop   = .Edge,
	.Knife          = .Edge,
	.Align          = .Face,
	.Spine          = .Face,
}

// The actions a drag drives; Insert loop also acts on a tap. The pair actions take a
// second element where the pen lifts; the rest act on a tap.
MODEL_DRAGS :: bit_set[Model_Action]{.Extrude, .Inset, .Move, .Insert_Loop, .Extrude_Edge, .Crease, .Crease_Point, .Bevel}
// The loop shape each loop action gives.
@(rodata)
MODEL_LOOP_SHAPES := #partial [Model_Action]poly.Loop_Shape {
	.Circle_Loop  = .Circle,
	.Space_Loop   = .Space,
	.Flatten_Loop = .Flatten,
}

// The actions that set sharpness: a tap creases, a drag up or down sets how much.
MODEL_CREASES :: bit_set[Model_Action]{.Crease, .Crease_Point}
MODEL_PAIRS :: bit_set[Model_Action]{.Bridge, .Weld, .Connect, .Align}
// The actions a press draws a stroke for: the stroke is the cut, or the path.
MODEL_STROKES :: bit_set[Model_Action]{.Knife, .Spine}
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
	.Crease         = {.Single, .Edge_Loop, .Edge_Ring},
	.Crease_Point   = {.Single},
	.Bevel          = {.Single, .Edge_Loop, .Edge_Ring},
	.Circle_Loop    = {.Edge_Loop, .Border_Loop},
	.Space_Loop     = {.Edge_Loop, .Border_Loop},
	.Flatten_Loop   = {.Edge_Loop, .Border_Loop},
	.Knife          = {.Single},
	.Align          = {.Island},
	.Spine          = FACE_TARGETS,
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
	.Crease         = .Edge_Loop,
	.Crease_Point   = .Single,
	.Bevel          = .Edge_Loop,
	.Circle_Loop    = .Edge_Loop,
	.Space_Loop     = .Edge_Loop,
	.Flatten_Loop   = .Edge_Loop,
	.Knife          = .Single,
	.Align          = .Island,
	.Spine          = .Single,
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
	// The knife's stroke or Spine's path on screen, from the press, and the pen's pressure
	// at each of its points (heap); whether the press was on the cage (a knife stroke may
	// start beside it).
	stroke: [dynamic][2]f32,
	pressure: [dynamic]f32,
	over:   bool,
	// Bevel's cage as pressed (heap), which a change of segments bevels again, the
	// segments it started with and those the cage now has.
	original: poly.Mesh,
	segments_from, segments: int,
}

// The Model tool's own state, beside the primitive Add cage makes.
model_tool_free :: proc(m: ^Model_Tool) {
	if m.drag.before != nil do history_snapshot_drop(m.drag.before)
	delete(m.hover.items)
	delete(m.hover.images)
	delete(m.drag.items)
	delete(m.drag.images)
	delete(m.drag.stroke)
	delete(m.drag.pressure)
	poly.drag_set_destroy(&m.drag.set)
	poly.mesh_destroy(&m.drag.original)
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
	// A corner patch of Bevel creases stands for no cage face.
	if face == poly.NONE do return
	vp := view_proj_of(app, size)
	best_edge, best_point := max(f32), max(f32)
	// Points and edges as drawn: on a smoothed cage, on its surface and along its curves.
	line := make([dynamic]Vec3, context.temp_allocator)
	w := poly.face_walk(m, face)
	for h in poly.face_walk_next(&w) {
		v := m.he_vert[h]
		if a, a_seen := gizmo.project(vp, to_world(t, cage_point(cp, v)), size); a_seen {
			if d := linalg.length(pos - a); d < best_point do best_point, point = d, v
		}
		e := poly.edge_of(h)
		if border && !poly.edge_border(m, e) do continue
		// The share along the line runs from the edge's first end, as Insert loop's does.
		cage_edge_points(cp, e, &line)
		pieces := f32(len(line) - 1)
		for i in 0 ..< len(line) - 1 {
			a, a_seen := gizmo.project(vp, to_world(t, line[i]), size)
			b, b_seen := gizmo.project(vp, to_world(t, line[i + 1]), size)
			if !a_seen || !b_seen do continue
			d, along := segment_distance(pos, a, b)
			if d < best_edge do best_edge, edge, at = d, e, (f32(i) + along) / pieces
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
			// The knife and Spine draw their stroke.
			if d.action in MODEL_STROKES {
				if linalg.length(input.mouse_pos - d.stroke[len(d.stroke) - 1]) >= 3 {
					append(&d.stroke, input.mouse_pos)
					append(&d.pressure, model_pressure(input))
				}
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
		if d.action == .Spine {
			append(&d.stroke, input.mouse_pos)
			append(&d.pressure, model_pressure(input))
			return model_spine(app, input.size)
		}
		if d.action == .Knife {
			append(&d.stroke, input.mouse_pos)
			if model_stroke_reach(d.stroke[:], d.press) > app.kit.ctx.theme.slop do return model_knife(app, input.size)
			return model_knife_tap(app, input.size)
		}
		if d.action == .Insert_Loop {
			if !model_drag_begin(app, input) do return false
			if d.state == .Dragging do model_drag_end(app)
			return true
		}
		if d.action not_in MODEL_DRAGS || d.action in MODEL_CREASES do return model_tap(app)
		// A tap with a drag action repeats how far it went last.
		if last := m.last[d.action]; last != 0 {
			if !model_drag_begin(app, input) do return false
			if d.state != .Dragging do return true
			obj := object_by_id(app, d.object)
			if d.action == .Bevel {
				if !model_bevel_to(app, obj, last, m.bevel_segments) {
					model_drag_drop(app)
					return false
				}
			} else {
				d.amount = poly.drag_apply(&obj.cage.mesh, &d.set, last)
				if !cage_positions_moved(app, obj, d.set.verts) {
					model_drag_drop(app)
					return false
				}
			}
			model_drag_finish(app, obj)
		}
		return true
	case .None:
	}
	model_hover(app, input.mouse_pos, input.size, input.hovered || input.primary)
	if m.action != .Knife do m.knife_from = {}
	if !input.primary || !input.press do return true
	over := m.hover.object != 0
	if !over {
		// A knife stroke may start beside the cage, so it can cut clean across it: it cuts
		// the selected cage.
		sel := selected_object(app)
		if m.action != .Knife || sel == nil || sel.cage == nil || sel.off do return true
		m.hover.object = sel.id
	}
	obj := object_by_id(app, m.hover.object)
	select_object(app, obj)
	h := &m.hover
	d^ = {state = .Pressed, object = h.object, action = m.action, press = input.mouse_pos, alt = input.invert, snap = input.smooth, face = h.face, edge = h.edge, point = h.point, at = h.at, items = d.items, images = d.images, set = d.set, stroke = d.stroke, pressure = d.pressure, over = over}
	clear(&d.stroke)
	append(&d.stroke, input.mouse_pos)
	clear(&d.pressure)
	append(&d.pressure, model_pressure(input))
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
	case .Crease, .Crease_Point:
		// Fully sharp, or as sharp as the last drag set; with Alt, no crease. A tap that
		// changes nothing is no undo step.
		changed: bool
		sharpness := 0 if d.alt else model_crease_sharpness(m.last[d.action] if m.last[d.action] != 0 else MODEL_CREASE_STEPS)
		if d.action == .Crease {
			changed = poly.crease_edges(cage, model_all(d), sharpness)
		} else {
			changed = poly.crease_points(cage, model_all(d), sharpness)
		}
		if !changed {
			history_snapshot_drop(before)
			return true
		}
	case .Circle_Loop, .Space_Loop, .Flatten_Loop:
		// The loop and its mirror image, each shaped on its own.
		shape := MODEL_LOOP_SHAPES[d.action]
		shaped := false
		for loop in ([2][]u32{d.items[:], d.images[:]}) {
			if len(loop) == 0 do continue
			points, closed := poly.loop_points(cage, loop, context.temp_allocator)
			if poly.shape_loop(cage, points, closed, shape, d.alt) do shaped = true
		}
		if !shaped {
			history_snapshot_drop(before)
			m.refused += 1
			report(app, nil, {.Warning}, "%s refused: it needs %s", MODEL_ACTION_NAMES[d.action], "a closed loop of three points or more" if shape == .Circle else "a loop of three points or more")
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

// The knife's cut: where the stroke crossed the cage's edges in sight, in the order it
// crossed them, cut as one undo step (with its mirror images under symmetry).
@(private = "file")
model_knife :: proc(app: ^App, size: [2]f32, ends: [2]Maybe(poly.Knife_Point) = {}) -> bool {
	d := &app.model.drag
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil || len(d.stroke) < 2 do return true
	// Before anything temporary: a snapshot frees the frame's temporary memory.
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[.Knife])
	cp := obj.cage
	cage := &cp.mesh
	vp := view_proj_of(app, size)
	t := obj.transform
	b := poly.mesh_bounds(cage)
	slack := linalg.length(b.hi - b.lo) * 1e-3
	Hit :: struct {
		along: f32, // where on the stroke: its segment and the share of it
		point: poly.Knife_Point,
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	line := make([dynamic]Vec3, context.temp_allocator)
	screen := make([dynamic][2]f32, context.temp_allocator)
	for e in 0 ..< u32(len(cage.crease)) {
		cage_edge_points(cp, e, &line)
		clear(&screen)
		seen := true
		for q in line {
			p, ok := gizmo.project(vp, to_world(t, q), size)
			seen &&= ok
			append(&screen, p)
		}
		if !seen do continue
		pieces := f32(len(line) - 1)
		for i in 0 ..< len(screen) - 1 {
			for j in 0 ..< len(d.stroke) - 1 {
				u, w, crossed := segments_cross(d.stroke[j], d.stroke[j + 1], screen[i], screen[i + 1])
				if !crossed do continue
				at := (f32(i) + w) / pieces
				// Through a corner is no cut of the edge.
				if at < MODEL_KNIFE_END || at > 1 - MODEL_KNIFE_END do continue
				if !model_seen(app, obj, linalg.lerp(line[i], line[i + 1], w), size, slack) do continue
				// The edges a tapped cut ends on are its ends already.
				if p, ok := ends[0].?; ok && p.edge == e do continue
				if p, ok := ends[1].?; ok && p.edge == e do continue
				append(&hits, Hit{f32(j) + u, {e, at}})
			}
		}
	}
	extra := int(ends[0] != nil) + int(ends[1] != nil)
	if len(hits) + extra < 2 {
		history_snapshot_drop(before)
		app.model.refused += 1
		report(app, nil, {.Warning}, "Knife: draw the stroke across at least two edges of the cage")
		return true
	}
	slice.sort_by(hits[:], proc(x, y: Hit) -> bool {return x.along < y.along || (x.along == y.along && x.point.edge < y.point.edge)})
	chain := make([dynamic]poly.Knife_Point, 0, len(hits) + 2, context.temp_allocator)
	if p, ok := ends[0].?; ok do append(&chain, p)
	for h in hits do append(&chain, h.point)
	if p, ok := ends[1].?; ok do append(&chain, p)
	chains := make([dynamic][]poly.Knife_Point, context.temp_allocator)
	append(&chains, chain[:])
	append(&chains, ..poly.knife_images(cage, chain[:], model_axes(app), context.temp_allocator))
	r, err := poly.knife_cut(cage, chains[:])
	poly.edit_result_destroy(&r)
	return model_commit(app, obj, before, err)
}

// The pen's pressure now: the last sample's, 1 from a mouse or with no samples.
@(private = "file")
model_pressure :: proc(input: Viewport_Input) -> f32 {
	if len(input.samples) == 0 do return 1
	return input.samples[len(input.samples) - 1].pressure
}

// The last Align parts join: the cage moved and the one joined to (the same for two
// parts of one cage), the moved face and the face it lies on, whether it was flipped,
// and where the moved part ended (its points' middle, or the moved cage's place) (object
// 0 for none). A tap on the part turns it while it is still there, so an undo or any
// other change ends it.
Model_Aligned :: struct {
	object, onto: int,
	from, to:     u32,
	flip:         bool,
	middle:       Vec3,
}

// The middle of the faces' points.
@(private = "file")
model_middle :: proc(cage: ^poly.Mesh, faces: []u32) -> (middle: Vec3) {
	verts := poly.face_set_verts(cage, faces, context.temp_allocator)
	for v in verts do middle += cage.positions[v]
	return middle / f32(max(len(verts), 1))
}

// Align parts: the pressed part joined to the face the pen lifted over, as one undo step.
// On another part of the same cage, the part (its island) moves; on another cage, the
// pressed cage moves whole, as Shapr3D's Align moves a body. Lifted over the part itself,
// which the last join moved, it turns a step about the join (Alt: flips it). Symmetry is
// not used: a part moves whole.
@(private = "file")
model_align :: proc(app: ^App, obj: ^Object) -> bool {
	m := &app.model
	d := &m.drag
	onto := object_by_id(app, m.hover.object)
	if onto == nil || onto.cage == nil do return true
	from, to, flip, turn := d.face, m.hover.face, d.alt, 0
	if onto == obj && slice.contains(d.items[:], to) {
		a := m.aligned
		joined := a.object == obj.id
		if other := object_by_id(app, a.onto); joined && other != nil && other.cage != nil {
			joined = int(a.from) < len(obj.cage.mesh.face_he) && int(a.to) < len(other.cage.mesh.face_he) && slice.contains(d.items[:], a.from)
			if joined && other == obj do joined = !slice.contains(d.items[:], a.to)
			now := model_middle(&obj.cage.mesh, d.items[:]) if other == obj else obj.transform.position
			joined = joined && linalg.length(now - a.middle) <= 1e-5 * max(cage_size(obj.cage), linalg.length(a.middle))
			onto = other
		} else {
			joined = false
		}
		if !joined {
			report(app, nil, {}, "Align parts: lift the pen over a face of another part to join them; a tap on the part just joined turns it")
			return true
		}
		from, to = a.from, a.to
		flip, turn = a.flip, 1
		if d.alt do flip, turn = !a.flip, 0
	}
	if onto != obj {
		// The pressed cage moves whole: its turn and place change, its points do not.
		ta, tb := obj.transform, onto.transform
		ra, rb := transform_rotation(ta), transform_rotation(tb)
		ways := poly.face_ways(&onto.cage.mesh, to, context.temp_allocator)
		for &w in ways do w = rb * w
		way := poly.face_ways(&obj.cage.mesh, from, context.temp_allocator)[0]
		q := poly.align_turn(ra * poly.face_normal(&obj.cage.mesh, from), ra * way, rb * poly.face_normal(&onto.cage.mesh, to), ways, flip, turn)
		ca, cb := to_world(ta, poly.face_center(&obj.cage.mesh, from)), to_world(tb, poly.face_center(&onto.cage.mesh, to))
		before := obj.transform
		obj.transform.rotation = gizmo.rotation_degrees(linalg.matrix3_from_quaternion_f32(q) * ra)
		obj.transform.position = cb + linalg.quaternion_mul_vector3(q, ta.position - ca)
		history_record_transform(app, obj, before, MODEL_ACTION_WHAT[.Align])
		m.aligned = {object = obj.id, onto = onto.id, from = from, to = to, flip = flip, middle = obj.transform.position}
		m.done += 1
		return true
	}
	// Before anything temporary: a snapshot frees the frame's temporary memory.
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[.Align])
	if !poly.align_part(&obj.cage.mesh, d.items[:], from, to, flip, turn) {
		history_snapshot_drop(before)
		return true
	}
	m.aligned = {object = obj.id, onto = obj.id, from = from, to = to, flip = flip, middle = model_middle(&obj.cage.mesh, d.items[:])}
	return model_commit(app, obj, before, .None)
}

// How a Spine's faces scale along the path from the pen's pressure: full size while the
// pressure first rises (a pen landing), then the pressure as a share of the stroke's
// middling pressure, so pressing harder fattens it and lifting off tapers it. A mouse's
// pressure never changes, so its spine keeps its size.
@(private = "file")
model_spine_scale :: proc(pressure: []f32) -> []f32 {
	out := make([]f32, len(pressure), context.temp_allocator)
	sorted := slice.clone(pressure, context.temp_allocator)
	slice.sort(sorted)
	middle := sorted[len(sorted) / 2] if len(sorted) > 0 else 1
	landed := false
	for p, i in pressure {
		landed ||= p >= 0.9 * middle
		out[i] = clamp(p / middle, poly.SPINE_SCALE_MIN, MODEL_SPINE_SCALE_MAX) if landed && middle > 0 else 1
	}
	return out
}

// The most a Spine's faces grow, as a share of their size.
MODEL_SPINE_SCALE_MAX :: 2

// Spine: the target's faces extruded step by step along the path drawn from them, as one
// undo step (with their mirror images under symmetry, along the mirrored path). The path
// lies on the plane through the faces' middle along their normal that faces the view
// most squarely; with Alt it is the arc from the faces leaving along their normal to
// where the pen lifted.
@(private = "file")
model_spine :: proc(app: ^App, size: [2]f32) -> bool {
	m := &app.model
	d := &m.drag
	obj := object_by_id(app, d.object)
	if obj == nil || obj.cage == nil || len(d.items) == 0 || !d.over do return true
	if model_stroke_reach(d.stroke[:], d.press) <= app.kit.ctx.theme.slop {
		report(app, nil, {}, "Spine: press on a face and draw the path for it to grow along")
		return true
	}
	// Before anything temporary: a snapshot frees the frame's temporary memory.
	before := history_snapshot(app, obj, MODEL_ACTION_WHAT[.Spine])
	cage := &obj.cage.mesh
	t := obj.transform
	// The faces' middle, their mean normal, and how long their outline's edges are.
	middle, normal: Vec3
	area: f32
	for f in d.items {
		a := poly.face_area(cage, f)
		middle += poly.face_center(cage, f) * a
		area += a
		normal += poly.face_area_vector(cage, f)
	}
	middle /= max(area, 1e-20)
	normal = linalg.normalize0(normal)
	outline, edges: f32
	for f in d.items {
		w := poly.face_walk(cage, f)
		for h in poly.face_walk_next(&w) {
			other := cage.he_face[poly.twin(h)]
			if other != poly.NONE && slice.contains(d.items[:], other) do continue
			outline += poly.edge_length(cage, poly.edge_of(h))
			edges += 1
		}
	}
	step := MODEL_SPINE_STEP * outline / max(edges, 1)
	// The plane the path is drawn on.
	_, look := mouse_ray(app.camera, d.press, size)
	view := linalg.normalize0(to_local_dir(t, look))
	across := view - normal * linalg.dot(view, normal)
	if linalg.length(across) < MODEL_SPINE_SIDEWAYS || step <= 0 {
		history_snapshot_drop(before)
		m.refused += 1
		report(app, nil, {.Warning}, "Spine: turn the view so the faces are seen from the side, and draw the path out of them")
		return true
	}
	plane := linalg.normalize(across)
	hits := make([dynamic]Vec3, context.temp_allocator)
	kept := make([dynamic]f32, context.temp_allocator)
	for p, i in d.stroke {
		origin, dir := mouse_ray(app.camera, p, size)
		o, w := to_local(t, origin), to_local_dir(t, dir)
		along := linalg.dot(w, plane)
		if abs(along) < 1e-6 do continue
		hit := o + w * (linalg.dot(middle - o, plane) / along)
		append(&hits, hit)
		append(&kept, d.pressure[i] if i < len(d.pressure) else 1)
	}
	path := make([dynamic]Vec3, context.temp_allocator)
	scale: []f32
	if len(hits) >= 2 {
		if d.alt {
			arc := poly.spine_arc(middle, normal, middle + hits[len(hits) - 1] - hits[0], MODEL_SPINE_ARC_POINTS, context.temp_allocator)
			append(&path, ..arc)
		} else {
			for h in hits do append(&path, middle + h - hits[0])
			scale = model_spine_scale(kept[:])
		}
	}
	steps := poly.spine_steps(path[:], scale, middle, normal, step, context.temp_allocator)
	if len(steps) == 0 {
		history_snapshot_drop(before)
		return true
	}
	// The faces, then each mirror image of them apart from those already taken.
	regions := make([dynamic][]u32, context.temp_allocator)
	runs := make([dynamic][]poly.Spine_Step, context.temp_allocator)
	append(&regions, d.items[:])
	append(&runs, steps)
	taken := make(map[u32]bool, allocator = context.temp_allocator)
	for f in d.items do taken[f] = true
	signs := poly.mirror_signs(model_axes(app))
	for sign in signs[1:] {
		faces, found := poly.mirror_faces_by(cage, d.items[:], sign, poly.mirror_slack(cage), context.temp_allocator)
		if !found do continue
		apart := true
		for f in faces do apart &&= !taken[f]
		if !apart do continue
		for f in faces do taken[f] = true
		mirrored := make([]poly.Spine_Step, len(steps), context.temp_allocator)
		for s, i in steps do mirrored[i] = poly.spine_step_mirror(s, sign)
		append(&regions, faces)
		append(&runs, mirrored)
	}
	_, err := poly.spine_faces(cage, regions[:], runs[:], context.temp_allocator)
	return model_commit(app, obj, before, err)
}

// How far from straight on the view must see the faces for Spine (the sine of the angle
// between the view and their normal), and how many points its arc has.
MODEL_SPINE_SIDEWAYS :: 0.25
// How long a Spine's steps are, as a share of its faces' outline edges: half, so a path
// turns smoothly and the rings stay square enough to smooth well.
MODEL_SPINE_STEP :: 0.5
MODEL_SPINE_ARC_POINTS :: 32

// How near an edge's end a crossing may be and still cut the edge, as a share of it.
MODEL_KNIFE_END :: 0.02

// The Knife's last tap: the edge of the cage it snapped to, and where along it.
Model_Knife_Tap :: struct {
	object: int,
	edge:   u32,
	at:     f32,
}

// How far a stroke went from the press at most, in viewport points.
@(private = "file")
model_stroke_reach :: proc(stroke: [][2]f32, press: [2]f32) -> (reach: f32) {
	for p in stroke do reach = max(reach, linalg.length(p - press))
	return
}

// Where the Knife's tap sits on screen: on its edge as drawn, at its share along it.
model_knife_tap_at :: proc(app: ^App, tap: Model_Knife_Tap, size: [2]f32) -> (at: [2]f32, ok: bool) {
	obj := object_by_id(app, tap.object)
	if obj == nil || obj.cage == nil || int(tap.edge) >= len(obj.cage.mesh.crease) do return
	line := make([dynamic]Vec3, context.temp_allocator)
	cage_edge_points(obj.cage, tap.edge, &line)
	pieces := f32(len(line) - 1)
	i := min(int(tap.at * pieces), len(line) - 2)
	p := linalg.lerp(line[i], line[i + 1], tap.at * pieces - f32(i))
	return gizmo.project(view_proj_of(app, size), to_world(obj.transform, p), size)
}

// A tap with the Knife: on an edge it cuts from the last tap's point to this one through
// the faces between, then waits for the next, which cuts on from the point this one made;
// off the cage it ends the path.
@(private = "file")
model_knife_tap :: proc(app: ^App, size: [2]f32) -> bool {
	m := &app.model
	d := &m.drag
	from := m.knife_from
	m.knife_from = {}
	if !d.over do return true
	tap := Model_Knife_Tap{d.object, d.edge, d.at}
	if from.object != tap.object {
		m.knife_from = tap
		return true
	}
	a, a_ok := model_knife_tap_at(app, from, size)
	b, b_ok := model_knife_tap_at(app, tap, size)
	if !a_ok || !b_ok || linalg.length(b - a) < 1 do return true
	// The stroke stops short of both taps, whose edges are the cut's ends already.
	short := linalg.normalize(b - a) * min(2, linalg.length(b - a) / 4)
	clear(&d.stroke)
	append(&d.stroke, a + short, b - short)
	done := m.done
	if !model_knife(app, size, {{from.edge, from.at}, {tap.edge, tap.at}}) do return false
	if m.done == done do return true
	// The cut renumbered the cage: the next tap cuts on from the corner made here.
	obj := object_by_id(app, tap.object)
	vp := view_proj_of(app, size)
	best := f32(3)
	for v in 0 ..< u32(len(obj.cage.mesh.positions)) {
		q, seen := gizmo.project(vp, to_world(obj.transform, cage_point(obj.cage, v)), size)
		if seen && linalg.length(q - b) < best {
			best = linalg.length(q - b)
			k := poly.knife_at_point(&obj.cage.mesh, v)
			m.knife_from = {tap.object, k.edge, k.at}
		}
	}
	return true
}

// Where segments a-b and c-d cross: the share along each, and whether they do.
segments_cross :: proc(a, b, c, d: [2]f32) -> (u, w: f32, crossed: bool) {
	r, s := b - a, d - c
	den := r.x * s.y - r.y * s.x
	if abs(den) < 1e-9 do return
	q := c - a
	u = (q.x * s.y - q.y * s.x) / den
	w = (q.x * r.y - q.y * r.x) / den
	return u, w, u >= 0 && u < 1 && w >= 0 && w <= 1
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
	// Align joins a part to another cage too.
	if d.action == .Align && h.object != 0 do return model_align(app, obj)
	if h.object != d.object {
		second := "point"
		if d.action == .Bridge do second = "border"
		if d.action == .Align do second = "part"
		report(app, nil, {.Warning}, "%s needs its second %s on the same cage: lift the pen over one", MODEL_ACTION_NAMES[d.action], second)
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
	case .Unsupported:         why = "the faces touch their mirror images, so they cannot grow apart" if action == .Spine else "it reaches a border or a point where only two edges meet, which a bevel cannot round"
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
	} else if MODEL_ACTION_ELEMENT[d.action] == .Edge {
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
			slide_from, slide_to = cage_point(obj.cage, ends[0]), cage_point(obj.cage, ends[1])
			err = model_mirror_loops(app, cage, &d.set, loop.pressed)
		}
		model_restore(cage, &kept, err)
		rebuilt = true
	case .Extrude_Edge:
		all := model_all(d)
		for e in all do if !poly.edge_border(cage, e) do err = .Non_Manifold_Edge
		if err == .None do strip, d.set, err = poly.extrude_border(cage, all, d.alt)
		rebuilt = true
	case .Bevel:
		// Kept as pressed, so other segments bevel the same edges again from it.
		d.original = poly.mesh_clone(cage^)
		d.segments = model_bevel_segments(app.model)
		d.segments_from = d.segments
		edit: poly.Edit_Result
		edit, d.set, err = poly.bevel_edges(cage, model_all(d), d.segments)
		poly.edit_result_destroy(&edit)
		rebuilt = true
	}
	poly.face_ring_destroy(&ring)
	poly.border_extrude_destroy(&strip)
	if err != .None {
		poly.loop_insert_destroy(&loop)
		poly.mesh_destroy(&d.original)
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
	// A crease drag sets its sharpness from the first frame, even where that is none.
	d.amount = -1 if d.action in MODEL_CREASES else 0
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
	if d.action in MODEL_CREASES {
		model_crease_follow(app, obj, input)
		return
	}
	amount := model_drag_along(app, obj, input.mouse_pos, input.size) - d.start
	if d.action == .Bevel {
		// Sideways sets the segments, from those the last round bevel had; below the press
		// is a chamfer, one segment.
		if input.smooth && d.step > 0 do amount = math.round(amount / d.step) * d.step
		segments := clamp(d.segments_from + int(math.round((input.mouse_pos.x - d.press.x) / MODEL_BEVEL_PIXELS)), 1, poly.BEVEL_SEGMENTS_MAX)
		if amount == d.amount && (amount < 0 || segments == d.segments) do return
		_ = model_bevel_to(app, obj, amount, segments)
		return
	}
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
	_ = cage_positions_moved(app, obj, d.set.verts)
}

// The segments Bevel starts with, and how many pixels sideways add or take one.
MODEL_BEVEL_SEGMENTS :: 3
MODEL_BEVEL_PIXELS :: 30

// The segments a round bevel takes: those the last one had, or the default.
model_bevel_segments :: proc(m: Model_Tool) -> int {
	return m.bevel_segments if m.bevel_segments > 0 else MODEL_BEVEL_SEGMENTS
}

// Puts the bevel in hand at `amount`: a round bevel of `segments` that wide, or below zero
// a flat chamfer (one segment) of the amount's size. A change of segments bevels the
// cage as pressed again. Returns false only on a GPU failure.
model_bevel_to :: proc(app: ^App, obj: ^Object, amount: f32, segments: int) -> bool {
	d := &app.model.drag
	want := 1 if amount < 0 else clamp(segments, 1, poly.BEVEL_SEGMENTS_MAX)
	if want != d.segments {
		cage := &obj.cage.mesh
		poly.mesh_destroy(cage)
		cage^ = poly.mesh_clone(d.original)
		poly.drag_set_destroy(&d.set)
		edit, set, err := poly.bevel_edges(cage, model_all(d), want)
		poly.edit_result_destroy(&edit)
		// The same edges bevelled with other segments a moment ago; were it refused, the
		// cage stays as pressed.
		if err == .None do d.set = set
		d.segments = want
		if !cage_rebuild(app, obj) do return false
	}
	if amount >= 0 do app.model.bevel_segments = want
	width := poly.drag_apply(&obj.cage.mesh, &d.set, abs(amount))
	d.amount = -width if amount < 0 else width
	return cage_positions_moved(app, obj, d.set.verts)
}

// How many pixels of drag make one step of sharpness, and the steps up to fully sharp
// (the last step is INFINITE_SHARP, which never rounds).
MODEL_CREASE_PIXELS :: 40
MODEL_CREASE_STEPS :: 5

// A crease drag's steps as a sharpness: the top step fully sharp.
model_crease_sharpness :: proc(steps: f32) -> f32 {
	return poly.INFINITE_SHARP if steps >= MODEL_CREASE_STEPS else max(steps, 0)
}

// A crease drag: the pen's height over the press sets how sharp the target is, in steps
// (whole ones with Snap), and the smoothed surface follows.
@(private = "file")
model_crease_follow :: proc(app: ^App, obj: ^Object, input: Viewport_Input) {
	d := &app.model.drag
	steps := clamp((d.press.y - input.mouse_pos.y) / MODEL_CREASE_PIXELS, 0, MODEL_CREASE_STEPS)
	if input.smooth do steps = math.round(steps)
	if d.alt do steps = 0
	if steps == d.amount do return
	d.amount = steps
	cage := &obj.cage.mesh
	if d.action == .Crease {
		poly.crease_edges(cage, model_all(d), model_crease_sharpness(steps))
	} else {
		poly.crease_points(cage, model_all(d), model_crease_sharpness(steps))
	}
	_ = cage_sharpness_changed(app, obj)
}

// The pen lifted: the drag is one undo step.
@(private = "file")
model_drag_finish :: proc(app: ^App, obj: ^Object) {
	d := &app.model.drag
	history_record_swap(app, obj.id, d.before, kind = .Model)
	d.before = nil
	d.state = .None
	poly.mesh_destroy(&d.original)
	app.model.done += 1
	if d.amount != 0 do app.model.last[d.action] = d.amount
	// A bevel adjusts its width; a chamfer's is its amount's size.
	adjust_set_model(app, obj, abs(d.amount) if d.action == .Bevel else d.amount)
}

// Ends a drag whose object went, or whose rebuild failed, recording nothing.
@(private = "file")
model_drag_drop :: proc(app: ^App) {
	d := &app.model.drag
	poly.mesh_destroy(&d.original)
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

// Creased edges and corners, violet as ZModeler's crease marks are drawn apart from the
// cage's edges; a soft crease (one that rounds after a few steps) fainter.
MODEL_CREASE_COLOR :: [4]f32{0.8, 0.4, 1.0, 1}
MODEL_SOFT_CREASE_COLOR :: [4]f32{0.8, 0.4, 1.0, 0.5}

// The mesh check's colours, as Blender's mesh analysis shows them: open edges and
// polygons of five or more corners red, triangles yellow, faces that are not flat pink,
// and poles (inner points where other than four edges meet) green for three and magenta
// for five or more.
MODEL_CHECK_OPEN :: [4]f32{1.0, 0.25, 0.25, 1}
MODEL_CHECK_TRIANGLE :: [4]f32{1.0, 0.85, 0.2, 0.9}
MODEL_CHECK_NGON :: [4]f32{1.0, 0.3, 0.3, 0.9}
MODEL_CHECK_BENT :: [4]f32{1.0, 0.45, 0.75, 0.9}
MODEL_CHECK_POLE_LOW :: [4]f32{0.35, 0.9, 0.4, 1}
MODEL_CHECK_POLE_HIGH :: [4]f32{0.95, 0.35, 0.95, 1}
// How far a face's corners may leave its plane, as a share of its size, and still count
// as flat: a hundredth, below what shows when the cage is lit.
MODEL_CHECK_BEND :: 0.01

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
		if m.check do draw_model_check(app, o, input, obj)
		draw_model_creases(app, o, input, obj)
	}
	// The Knife's last tap, and the cut the next tap would make from it.
	if m.action == .Knife && m.knife_from.object != 0 && d.state != .Pressed {
		if at, ok := model_knife_tap_at(app, m.knife_from, input.size); ok {
			color := overlay_color(MODEL_ELEMENT_COLORS[.Edge])
			overlay_line(o, at, input.mouse_pos, color, 2)
			overlay_disc(o, at, 5, color)
		}
	}
	if d.state != .Dragging {
		if d.state == .Pressed {
			draw_model_items(app, o, input, d.object, MODEL_ACTION_ELEMENT[d.action], d.items[:], MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]])
			draw_model_items(app, o, input, d.object, MODEL_ACTION_ELEMENT[d.action], d.images[:], MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]])
			if d.action in MODEL_PAIRS do overlay_line(o, d.press, input.mouse_pos, overlay_color(MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]]), 2)
			if d.action in MODEL_STROKES && len(d.stroke) > 1 do overlay_polyline(o, d.stroke[:], overlay_color(MODEL_ELEMENT_COLORS[MODEL_ACTION_ELEMENT[d.action]]), 2)
		}
		if d.state == .None || d.action in MODEL_PAIRS {
			draw_model_items(app, o, input, m.hover.object, element, m.hover.items[:], MODEL_ELEMENT_COLORS[element])
			draw_model_items(app, o, input, m.hover.object, element, m.hover.images[:], MODEL_ELEMENT_COLORS[element])
		}
	}
	label := fmt.tprintf("%s · %s", MODEL_ACTION_NAMES[m.action], MODEL_TARGET_NAMES[model_target(m, m.action)])
	// A drag says how far it has gone, as ZModeler's floating value does.
	if d.state == .Dragging {
		amount: string
		switch {
		case d.action == .Insert_Loop:    amount = fmt.tprintf("%+.0f%%", d.amount * 100)
		case d.action in MODEL_CREASES:   amount = "sharp" if d.amount >= MODEL_CREASE_STEPS else fmt.tprintf("%.1f", max(d.amount, 0))
		case d.action == .Bevel:          amount = fmt.tprintf("%.3f chamfer", -d.amount) if d.amount < 0 else fmt.tprintf("%.3f · %d segments", d.amount, d.segments)
		case:                             amount = fmt.tprintf("%+.3f", d.amount)
		}
		label = fmt.tprintf("%s  %s", label, amount)
	}
	overlay_label(o, label, input.mouse_pos + {0, -36})
}

// Each creased edge and corner of `obj`'s cage, fully sharp ones solid.
@(private = "file")
draw_model_creases :: proc(app: ^App, o: Overlay, input: Viewport_Input, obj: ^Object) {
	cage := &obj.cage.mesh
	sharp := make([dynamic]u32, context.temp_allocator)
	soft := make([dynamic]u32, context.temp_allocator)
	for c, e in cage.crease do if c > 0 do append(&sharp if c >= poly.INFINITE_SHARP else &soft, u32(e))
	draw_model_items(app, o, input, obj.id, .Edge, sharp[:], MODEL_CREASE_COLOR)
	draw_model_items(app, o, input, obj.id, .Edge, soft[:], MODEL_SOFT_CREASE_COLOR)
	clear(&sharp)
	clear(&soft)
	for c, v in cage.corner do if c > 0 do append(&sharp if c >= poly.INFINITE_SHARP else &soft, u32(v))
	draw_model_items(app, o, input, obj.id, .Point, sharp[:], MODEL_CREASE_COLOR)
	draw_model_items(app, o, input, obj.id, .Point, soft[:], MODEL_SOFT_CREASE_COLOR)
}

// The mesh check on `obj`'s cage: what would trouble smoothing, printing or a game engine,
// coloured where it is.
@(private = "file")
draw_model_check :: proc(app: ^App, o: Overlay, input: Viewport_Input, obj: ^Object) {
	cage := &obj.cage.mesh
	open := make([dynamic]u32, context.temp_allocator)
	triangles := make([dynamic]u32, context.temp_allocator)
	ngons := make([dynamic]u32, context.temp_allocator)
	bent := make([dynamic]u32, context.temp_allocator)
	low := make([dynamic]u32, context.temp_allocator)
	high := make([dynamic]u32, context.temp_allocator)
	for e in 0 ..< u32(len(cage.crease)) do if poly.edge_border(cage, e) do append(&open, e)
	for f in 0 ..< u32(len(cage.face_he)) {
		n := poly.face_size(cage, f)
		if n == 3 do append(&triangles, f)
		if n > 4 do append(&ngons, f)
		if n > 3 && poly.face_bend(cage, f) > MODEL_CHECK_BEND do append(&bent, f)
	}
	for v in 0 ..< u32(len(cage.positions)) {
		if poly.vert_border(cage, v) do continue
		n := poly.valence(cage, v)
		if n < 4 do append(&low, v)
		if n > 4 do append(&high, v)
	}
	draw_model_items(app, o, input, obj.id, .Face, triangles[:], MODEL_CHECK_TRIANGLE)
	draw_model_items(app, o, input, obj.id, .Face, ngons[:], MODEL_CHECK_NGON)
	draw_model_items(app, o, input, obj.id, .Face, bent[:], MODEL_CHECK_BENT)
	draw_model_items(app, o, input, obj.id, .Edge, open[:], MODEL_CHECK_OPEN)
	draw_model_items(app, o, input, obj.id, .Point, low[:], MODEL_CHECK_POLE_LOW)
	draw_model_items(app, o, input, obj.id, .Point, high[:], MODEL_CHECK_POLE_HIGH)
}

@(private = "file")
draw_model_items :: proc(app: ^App, o: Overlay, input: Viewport_Input, id: int, element: Model_Element, items: []u32, color: [4]f32) {
	obj := object_by_id(app, id)
	if obj == nil || obj.cage == nil do return
	cp := obj.cage
	cage := &cp.mesh
	vp := view_proj_of(app, input.size)
	t := obj.transform
	line := make([dynamic]Vec3, context.temp_allocator)
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
			// Round the face along its edges as drawn, each the way the face runs.
			for h in poly.face_walk_next(&w) {
				e := poly.edge_of(h)
				cage_edge_points(cp, e, &line)
				if cage.he_vert[h] != cage.he_vert[2 * e] do slice.reverse(line[:])
				for q in line[:len(line) - 1] {
					p, ok := gizmo.project(vp, to_world(t, q), input.size)
					seen &&= ok
					append(&points, p)
				}
			}
			if !seen do continue
			front := model_seen(app, obj, cage_face_center(cp, f), input.size, slack)
			if front do overlay_fill(o, points[:], fill)
			overlay_polyline(o, points[:], shown if front else hidden, 2, closed = true)
		}
	case .Edge:
		for e in items {
			if int(e) >= len(cage.crease) do continue
			cage_edge_points(cp, e, &line)
			clear(&points)
			seen := true
			for q in line {
				p, ok := gizmo.project(vp, to_world(t, q), input.size)
				seen &&= ok
				append(&points, p)
			}
			if !seen do continue
			front := model_seen(app, obj, line[len(line) / 2], input.size, slack)
			overlay_polyline(o, points[:], shown if front else hidden, 3 if front else 2)
		}
	case .Point:
		for v in items {
			if int(v) >= len(cage.positions) do continue
			p, ok := gizmo.project(vp, to_world(t, cage_point(cp, v)), input.size)
			if !ok do continue
			front := model_seen(app, obj, cage_point(cp, v), input.size, slack)
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
