package main

import "core:math/linalg"
import sdl "vendor:sdl3"

import "../camera"
import "../gizmo"
import "../sculpt"

// Posing (sculpt/pose.odin) from the Move tool, as ZBrush's gizmo does when a mask is on:
// with one object selected and a mask leaving part of it free, a drag of the gizmo's
// handles moves, turns or scales the free part instead of the object, the mask's soft
// edge bending between it and the masked rest. A drag of the object's body still moves
// the whole object. The gizmo sits on the mask's soft edge, where a limb bends, unless a
// pivot was placed by hand since the mask last changed.

// What object_mask_look last found, and for which object, level and history, as
// Mask_Seen keeps whether there is a mask at all.
Pose_Seen :: struct {
	id, level, levels: int,
	serial: u64,
	look:   sculpt.Mask_Look,
	valid:  bool,
}

// The mask the pivot was last put on the soft edge of, and where: a pivot still where
// it was put follows the edge through every step (a pose, its undo), one placed by hand
// stays until the mask changes.
Pose_Placed :: struct {
	id, level: int,
	sum:       u64,
	valid:     bool,
	serial:    u64,
	at:        Vec3,
}

@(rodata)
POSE_WHAT := [gizmo.Mode]string {
	.Move  = "Pose: Move",
	.Turn  = "Pose: Turn",
	.Scale = "Pose: Scale",
}

// Whether the selected object's mask leaves a shown vertex free, and its checksum, kept
// until the object, its level or the history changes (every mask change is a step).
object_mask_look :: proc(app: ^App, obj: ^Object) -> sculpt.Mask_Look {
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	p := &app.move.seen
	if p.valid && p.id == obj.id && p.level == level && p.levels == len(obj.levels.levels) && p.serial == app.history.serial do return p.look
	p^ = {id = obj.id, level = level, levels = len(obj.levels.levels), serial = app.history.serial, valid = true}
	p.look = sculpt.sculptor_mask_look(object_sculptor(obj))
	return p.look
}

// Whether the gizmo's handles pose the selected object rather than move it: the Move
// tool on, one object selected, and a mask on it that leaves something shown free.
pose_mode :: proc(app: ^App) -> bool {
	if app.tool != .Move || len(selection_ids(app)) != 1 do return false
	obj := selected_object(app)
	return obj != nil && object_has_mask(app, obj) && object_mask_look(app, obj).free
}

// Puts the pivot on the mask's soft edge when pose mode finds a mask it has not placed
// one for, so a turn bends where the mask fades, and again after each step while the
// pivot is still where it was put (a pose carries the edge, its undo brings it back). A
// pivot placed by hand stays until the mask changes; nothing moves it mid-drag.
pose_pivot_place :: proc(app: ^App) {
	m := &app.move
	if m.drag.handle != .None || !pose_mode(app) do return
	obj := selected_object(app)
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	sum := object_mask_look(app, obj).sum
	p := &m.placed
	same_mask := p.valid && p.id == obj.id && p.level == level && p.sum == sum
	if same_mask && p.serial == app.history.serial do return
	ours := m.pivot == Gizmo_Pivot{set = true, id = obj.id, at = p.at}
	p^ = {id = obj.id, level = level, sum = sum, valid = true, serial = app.history.serial, at = p.at}
	if same_mask && !ours do return
	if at, ok := sculpt.sculptor_mask_centroid(object_sculptor(obj)); ok {
		m.pivot = {set = true, id = obj.id, at = at}
		p.at = at
	}
}

// Starts posing `obj`. False, saying why, in an HD window, under dynamic topology, or
// with nothing shown left free.
pose_begin :: proc(app: ^App, obj: ^Object) -> bool {
	if object_in_hd(obj) {
		report(app, Kit_Section.Transform, {.Warning}, "Posing needs the HD window left first (A)")
		return false
	}
	if object_dynamic(obj) {
		report(app, Kit_Section.Transform, {.Warning}, "Posing needs dynamic topology off")
		return false
	}
	if !sculpt.sculptor_pose_begin(object_sculptor(obj)) {
		report(app, Kit_Section.Transform, {.Warning}, "Nothing is free to pose: the mask covers all that is shown")
		return false
	}
	return true
}

// The pose in `obj`'s own space that the gizmo's change from `from` to `to` makes of
// handle `h`: the move between them, a turn of `degrees` about the world `axis`, or the
// change of scale, turns and scales about the world `pivot`.
pose_of :: proc(h: gizmo.Handle, from, to: Transform, pivot, axis: Vec3, degrees: f32) -> (p: sculpt.Pose) {
	p.pivot = to_local(from, pivot)
	switch drag_mode(h) {
	case .Move:
		p.kind, p.delta = .Move, to_local_dir(from, to.position - from.position) / from.scale
	case .Turn:
		p.kind, p.axis, p.angle = .Turn, linalg.normalize0(to_local_dir(from, axis)), linalg.to_radians(degrees)
	case .Scale:
		p.kind, p.factor = .Scale, to.scale / from.scale
	}
	return
}

// Whether a pose changes nothing.
pose_is_still :: proc(p: sculpt.Pose) -> bool {
	switch p.kind {
	case .Move:  return p.delta == {}
	case .Turn:  return p.angle == 0 || p.axis == {}
	case .Scale: return p.factor == 1
	case .Deform: return p.deform.amount == 0
	case .Lattice: return p.lattice.offset == {}
	case .Reshape: return p.reshape.amount == 0
	}
	return true
}

// Sets the pose under way to `p` (from where it began), skipping a frame that would set
// it as it is; a move carries the gizmo with the part it moves.
pose_set :: proc(app: ^App, obj: ^Object, p: sculpt.Pose) {
	drag := &app.move.drag
	// Nothing to set until the pointer has changed something, nor again as it is.
	if drag.applied ? drag.pose == p : pose_is_still(p) do return
	sculpt.sculptor_pose_apply(object_sculptor(obj), p)
	drag.pose, drag.applied = p, true
	pose_carry_pivot(app, obj, p)
}

// A move carries the gizmo with the part it moves; a pivot pose mode put there stays its
// own.
@(private = "file")
pose_carry_pivot :: proc(app: ^App, obj: ^Object, p: sculpt.Pose) {
	if p.kind != .Move do return
	m := &app.move
	ours := m.pivot == Gizmo_Pivot{set = true, id = obj.id, at = m.placed.at}
	m.pivot = {set = true, id = obj.id, at = p.pivot + p.delta}
	if ours do m.placed.at = m.pivot.at
}

// Ends the pose under way as one undo step when it changed something, named `what`, or
// for the handle's mode.
pose_end :: proc(app: ^App, obj: ^Object, h: gizmo.Handle, what := "") -> bool {
	s := object_sculptor(obj)
	if !sculpt.sculptor_pose_end(s) do return false
	history_record(app, obj, .Deform, what if what != "" else POSE_WHAT[drag_mode(h)])
	app.move.pose_drags += 1
	app.move.pose_moved = sculpt.sculptor_pose_moved(s)
	app.move.last = h
	return true
}

// Poses `obj` by a typed value for `h`, as one undo step: an offset along an arm, a turn
// in degrees, or a scale factor. False when the value makes no pose.
pose_entry_apply :: proc(app: ^App, obj: ^Object, h: gizmo.Handle, op: u8, v: f32) -> bool {
	pivot := gizmo_center(app, obj)
	to := obj.transform
	axis: Vec3
	degrees: f32
	#partial switch h {
	case .X, .Y, .Z:
		if op != 0 && op != '+' do return false
		to.position += gizmo.AXES[int(h) - int(gizmo.Handle.X)] * v
	case .Turn_X ..= .Turn_View:
		if op != 0 && op != '+' do return false
		i := int(h) - int(gizmo.Handle.Turn_X)
		axis = gizmo.AXES[i] if i < 3 else -camera.orbit_toward(app.camera, pivot)
		degrees = v
	case .Scale:
		factor := 1 + v if op == '+' else v
		if factor <= 0 do return false
		to.scale *= factor
	case:
		return false
	}
	p := pose_of(h, obj.transform, to, pivot, axis, degrees)
	if pose_is_still(p) || !pose_begin(app, obj) do return true
	sculpt.sculptor_pose_apply(object_sculptor(obj), p)
	pose_carry_pivot(app, obj, p)
	_ = pose_end(app, obj, h)
	return true
}

// A topological mask made with the Move tool (sculpt/topo_mask.odin): Ctrl (or the
// rail's Mask) and a press on an object selects it, then a drag sets how far the mask
// reaches along the surface from the press, the length of the drag on screen; Alt the
// other way round. Near the press stays free, so the gizmo, which then goes to the soft
// edge, poses the part pressed. A tap selects only. The gesture goes on after the
// release until the search has settled everything within the reach, one mask undo step.
Topo_Gesture :: struct {
	phase:  Topo_Phase,
	id:     int, // the object
	down:   [2]f32, // the press, in viewport points
	origin: Vec3, // the press's ray in the object's own space
	dir:    Vec3,
	per_px: f32, // the object's own units a pixel at the press
	invert: bool,
	reach:  f32, // the reach set last, in the object's own units
}

Topo_Phase :: enum u8 {
	None,
	Pressed, // not yet past the slop
	Live, // the drag sets the reach
	Settling, // let go; the search finishes the reach set last
}

// Vertices the search settles a frame, so a reach across a dense mesh stays a drag
// rather than a stall: about 20 ms on the test VM (release, 655k-vertex sphere).
TOPO_BUDGET :: 50_000

// Starts the gesture for a press on `obj` at `at` (viewport points) along the world ray
// `origin`, `dir`, which met it at `hit`.
topo_press :: proc(app: ^App, obj: ^Object, at: [2]f32, origin, dir, hit: Vec3, size: [2]f32, invert: bool) {
	t := obj.transform
	app.move.topo = {
		phase  = .Pressed,
		id     = obj.id,
		down   = at,
		origin = to_local(t, origin),
		dir    = linalg.normalize(to_local_dir(t, dir)),
		per_px = camera.orbit_world_per_px(app.camera, hit, size.y) / t.scale,
		invert = invert,
	}
}

// Runs the gesture for this frame; true while there is one, which then has the pointer.
topo_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	g := &app.move.topo
	if g.phase == .None do return false
	obj := object_by_id(app, g.id)
	if obj == nil {
		g^ = {}
		return false
	}
	if key_pressed(&app.device, sdl.K_ESCAPE) && topo_held(app) {
		topo_cancel(app)
		return true
	}
	// A press while the last one settles finishes it and is the Move tool's as usual.
	if g.phase == .Settling && input.press {
		topo_end(app)
		return false
	}
	s := object_sculptor(obj)
	if g.phase == .Pressed {
		if !input.primary {
			g^ = {}
			return true
		}
		if linalg.length(input.mouse_pos - g.down) <= app.kit.ctx.theme.slop * gizmo_scale(app) do return true
		if !sculpt.sculptor_topo_mask_begin(s, g.origin, g.dir, g.invert) {
			g^ = {}
			return true
		}
		g.phase = .Live
	}
	if g.phase == .Live {
		if input.primary do g.reach = linalg.length(input.mouse_pos - g.down) * g.per_px
		else do g.phase = .Settling
	}
	if sculpt.sculptor_topo_mask_reach(s, g.reach, TOPO_BUDGET) && g.phase == .Settling do topo_end(app)
	return true
}

// Ends the gesture, settling what is left of the reach first, as one mask undo step.
topo_end :: proc(app: ^App) {
	g := app.move.topo
	app.move.topo = {}
	if g.phase != .Live && g.phase != .Settling do return
	obj := object_by_id(app, g.id)
	if obj == nil do return
	s := object_sculptor(obj)
	_ = sculpt.sculptor_topo_mask_reach(s, g.reach, max(int))
	if sculpt.sculptor_topo_mask_end(s) {
		history_record(app, obj, .Mask, "Topological mask")
		app.move.topo_masks += 1
		app.move.topo_reach = g.reach
	}
}

// Finishes a topological mask that was let go and is still settling, as its step.
topo_settle :: proc(app: ^App) {
	if app.move.topo.phase == .Settling do topo_end(app)
}

// Whether a topological mask has the pointer: pressed and not yet let go.
topo_held :: proc(app: ^App) -> bool {
	return app.move.topo.phase == .Pressed || app.move.topo.phase == .Live
}

// Puts the mask back as it was and ends the gesture with nothing recorded; one already
// let go is the user's, and finishes instead.
topo_cancel :: proc(app: ^App) {
	if app.move.topo.phase == .Settling {
		topo_end(app)
		return
	}
	g := app.move.topo
	app.move.topo = {}
	if obj := object_by_id(app, g.id); obj != nil do sculpt.sculptor_topo_mask_cancel(object_sculptor(obj))
}

// Whether the Move tool has the pointer: a drag of the gizmo or an object, or a
// topological mask, which become steps of their own when they end.
move_busy :: proc(app: ^App) -> bool {
	return app.move.drag.handle != .None || app.move.topo.phase != .None
}
