package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"

import "../camera"
import "../gizmo"
import "../poly"

// Moving, turning and scaling a cage's selection freely, as Blender's edit mode moves its
// selection and ZBrush's gizmo moves a polygroup: with the Model tool's Select action and
// something selected (faces, or points and edges picked), the Move tool's gizmo stands at
// the middle of every picked point and selected face's corner, and its handles (or G, R
// and S, as on a curve's points) move, turn or scale them. Under symmetry the mirror
// images move as images, and a point on a mirror plane stays on it. Falloff eases the move
// out over the points round the selection (Blender's proportional editing), so a few
// points pull a soft bump rather than a spike. Each drag is one undo step of the cage. The
// drag itself is the shared one (point_xform.odin) that a curve's points use.

// The selection's drag under way: the shared drag, the cage, its undo snapshot, every point
// as it was, and what the move takes (poly.point_move_plan, made when the drag goes live).
Cage_Xform :: struct {
	using core: Point_Xform,
	id:         int,
	before:     ^Object_Snapshot,
	start:      [dynamic]Vec3,
	plan:       poly.Point_Move,
}

// The gizmo's drag's memory, freed with the Model tool.
cage_xform_free :: proc(x: ^Cage_Xform) {
	if x.before != nil do history_snapshot_drop(x.before)
	delete(x.start)
	poly.point_move_destroy(&x.plan)
	x^ = {}
}

// The cage whose selection shows the gizmo: the selected object, a shown cage, with the
// Model tool's Select in hand, something selected and no action's press under way.
model_gizmo_object :: proc(app: ^App) -> ^Object {
	m := &app.model
	if app.tool != .Model || m.action != .Select || m.drag.state != .None do return nil
	obj := selected_object(app)
	if obj == nil || obj.cage == nil || obj.off do return nil
	if !model_has_selection(&obj.cage.mesh) do return nil
	return obj
}

// Whether the cage has anything selected the gizmo moves.
model_has_selection :: proc(cage: ^poly.Mesh) -> bool {
	for x in cage.selected do if x do return true
	for x in cage.picked do if x do return true
	return false
}

// The selection's middle in the world: the mean of the points a move carries.
model_selection_middle :: proc(obj: ^Object) -> (mid: Vec3, n: int) {
	points := make([dynamic]u32, context.temp_allocator)
	poly.selection_points(&obj.cage.mesh, &points)
	for v in points do mid += obj.cage.mesh.positions[v]
	n = len(points)
	if n > 0 do mid /= f32(n)
	return to_world(obj.transform, mid), n
}

// The gizmo's arms in the Move tool's orientation: the world's, the cage object's, or the
// view's (Surface, which has no one surface point here, takes the object's).
model_gizmo_axes :: proc(app: ^App, obj: ^Object) -> [3]Vec3 {
	switch app.move.orient {
	case .World:
	case .Object, .Surface:
		t := obj.transform
		return {linalg.normalize0(to_world_dir(t, {1, 0, 0})), linalg.normalize0(to_world_dir(t, {0, 1, 0})), linalg.normalize0(to_world_dir(t, {0, 0, 1}))}
	case .View:
		right, up, back := camera.orbit_basis(app.camera)
		return {right, up, back}
	}
	return gizmo.AXES
}

// The selection's gizmo on screen; not ok when it is not shown. During a drag it stands
// where the points have gone.
model_gizmo_screen :: proc(app: ^App, size: [2]f32) -> (s: gizmo.Screen) {
	obj := model_gizmo_object(app)
	if obj == nil || size.x <= 0 || size.y <= 0 do return
	center, _ := model_selection_middle(obj)
	arm_px := gizmo.ARM_PX * gizmo_scale(app)
	arm := arm_px * camera.orbit_world_per_px(app.camera, center, size.y)
	return gizmo.screen(edit_view_proj(app, size), center, arm, -camera.orbit_toward(app.camera, center), size, arm_px, app.move.mode, model_gizmo_axes(app, obj))
}

// The gizmo's handle under `at`.
model_gizmo_pick :: proc(app: ^App, at, size: [2]f32) -> gizmo.Handle {
	sc := model_gizmo_screen(app, size)
	if !sc.ok do return .None
	return gizmo.pick(sc, app.move.mode, at, gizmo_radius(app))
}

// How far the falloff reaches on `obj`'s cage, in its own space: the share set of the
// cage's size.
model_falloff_reach :: proc(app: ^App, cage: ^poly.Mesh) -> f32 {
	if app.model.falloff <= 0 do return 0
	b := poly.mesh_bounds(cage)
	return app.model.falloff * linalg.length(b.hi - b.lo)
}

// Starts a drag of the selected cage's selection by `handle` from the pointer at `at`;
// `keys` for one G, R or S started.
@(private = "file")
cage_xform_begin :: proc(app: ^App, handle: gizmo.Handle, at: [2]f32, keys: bool) {
	obj := model_gizmo_object(app)
	x := &app.model.xform
	cage_xform_drop(app)
	x.handle, x.keys, x.down, x.id = handle, keys, at, obj.id
	x.before = history_snapshot(app, obj, "move selection")
	append(&x.start, ..obj.cage.mesh.positions[:])
}

// Lets the drag go without an undo step, the points as they are.
cage_xform_drop :: proc(app: ^App) {
	x := &app.model.xform
	if x.before != nil do history_snapshot_drop(x.before)
	start := x.start
	clear(&start)
	poly.point_move_destroy(&x.plan)
	x^ = {start = start}
}

// The cage the drag is on, while its points are still the ones it began with.
@(private = "file")
cage_xform_object :: proc(app: ^App) -> ^Object {
	x := &app.model.xform
	obj := object_by_id(app, x.id)
	if obj == nil || obj.cage == nil || len(obj.cage.mesh.positions) != len(x.start) do return nil
	return obj
}

// Puts the points back where the drag began and ends it with nothing recorded. Returns
// false only on a GPU failure.
cage_xform_cancel :: proc(app: ^App) -> bool {
	x := &app.model.xform
	ok := true
	if obj := cage_xform_object(app); obj != nil {
		copy(obj.cage.mesh.positions[:], x.start[:])
		ok = cage_positions_moved(app, obj, x.plan.verts[:])
	}
	cage_xform_drop(app)
	return ok
}

// Ends the drag: one undo step of the cage when a point moved.
cage_xform_end :: proc(app: ^App) {
	x := &app.model.xform
	obj := cage_xform_object(app)
	if obj == nil || x.before == nil {
		cage_xform_drop(app)
		return
	}
	changed := false
	for p, v in obj.cage.mesh.positions do if p != x.start[v] {
		changed = true
		break
	}
	if !changed {
		cage_xform_drop(app)
		return
	}
	history_record_swap(app, obj.id, x.before, kind = .Model)
	x.before = nil
	app.model.done += 1
	app.model.xforms += 1
	cage_xform_drop(app)
}

// Sets the drag up from the pointer at `at`: where the gizmo stands and what the move
// takes. False when the handle cannot be dragged from this view.
@(private = "file")
cage_xform_go_live :: proc(app: ^App, obj: ^Object, at, size: [2]f32) -> bool {
	x := &app.model.xform
	cage := &obj.cage.mesh
	pivot, _ := model_selection_middle(obj)
	if !point_xform_go_live(app, &x.core, model_gizmo_screen(app, size), pivot, model_gizmo_axes(app, obj), at, size) do return false
	carried := make([dynamic]u32, context.temp_allocator)
	poly.selection_points(cage, &carried)
	poly.point_move_destroy(&x.plan)
	x.plan = poly.point_move_plan(cage, carried[:], model_axes(app), model_falloff_reach(app, cage))
	// A snap lands on anything but the points that move (the plan's ids are ascending).
	x.skip = {id = obj.id, points = x.plan.verts[:]}
	return true
}

// The world map about `pivot` by `m` then along `move`, seen in the object's own space as
// p ↦ a·p + b (a similarity's frame keeps it affine).
cage_local_map :: proc(t: Transform, pivot: Vec3, m: matrix[3, 3]f32, move: Vec3) -> (a: matrix[3, 3]f32, b: Vec3) {
	f :: proc(t: Transform, p, pivot: Vec3, m: matrix[3, 3]f32, move: Vec3) -> Vec3 {
		return to_local(t, pivot + m * (to_world(t, p) - pivot) + move)
	}
	b = f(t, {}, pivot, m, move)
	for k in 0 ..< 3 {
		e: Vec3
		e[k] = 1
		col := f(t, e, pivot, m, move) - b
		for r in 0 ..< 3 do a[r, k] = col[r]
	}
	return
}

// Moves the selection by the world map from where it began, and the drawn surface with it.
// Returns false only on a GPU failure.
cage_xform_apply :: proc(app: ^App, obj: ^Object, m: matrix[3, 3]f32, move: Vec3) -> bool {
	x := &app.model.xform
	a, b := cage_local_map(obj.transform, x.pivot, m, move)
	poly.point_move_apply(&obj.cage.mesh, &x.plan, x.start[:], a, b)
	return cage_positions_moved(app, obj, x.plan.verts[:])
}

// A press, drag or release on the selection's gizmo, or a key's drag under way, with the
// Model tool. `taken` while it is theirs, so nothing else takes the press; ok is false only
// on a GPU failure.
model_xform_frame :: proc(app: ^App, input: Viewport_Input) -> (taken, ok: bool) {
	x := &app.model.xform
	if x.handle == .None {
		if !input.press || !input.primary do return false, true
		h := model_gizmo_pick(app, input.mouse_pos, input.size)
		if h == .None do return false, true
		cage_xform_begin(app, h, input.mouse_pos, false)
		return true, true
	}
	obj := cage_xform_object(app)
	if obj == nil {
		cage_xform_drop(app)
		return false, true
	}
	// Escape puts the points back mid-drag, as it puts an object back.
	if !x.keys && key_pressed(&app.device, KEY_ESCAPE) do return true, cage_xform_cancel(app)
	if x.keys {
		// A press keeps the drag; the press is the drag's alone, not a new pick.
		if input.press && input.primary {
			cage_xform_end(app)
			return true, true
		}
		if !x.live && !cage_xform_go_live(app, obj, x.down, input.size) do return true, cage_xform_cancel(app)
		if m, move, mapped := point_xform_map(app, &x.core, input.mouse_pos, input.size); mapped {
			if !cage_xform_apply(app, obj, m, move) do return true, false
		}
		return input.primary, true
	}
	if !input.primary {
		// A tap on a handle, which moved nothing, asks for its value instead, as the object
		// gizmo's does.
		if !x.live && entry_takes(x.handle) do gizmo_entry_open(app, obj, x.handle, x.down, cage = true)
		cage_xform_end(app)
		return true, true
	}
	slop := app.kit.ctx.theme.slop * gizmo_scale(app)
	if !x.live {
		if linalg.length(input.mouse_pos - x.down) <= slop do return true, true
		if !cage_xform_go_live(app, obj, input.mouse_pos, input.size) {
			cage_xform_drop(app)
			return true, true
		}
		// From the pointer's place now, so nothing jumps by the slop.
		x.down = input.mouse_pos
		return true, true
	}
	if m, move, mapped := point_xform_map(app, &x.core, input.mouse_pos, input.size); mapped {
		if !cage_xform_apply(app, obj, m, move) do return true, false
	}
	return true, true
}

// Starts G (move in the view, `.View`), R (turn about the view, `.Turn_View`) or S (scale,
// `.Scale`) on the selection from the pointer's place, as Blender's keys do.
cage_xform_key :: proc(app: ^App, handle: gizmo.Handle) {
	x := &app.model.xform
	if x.handle != .None && !x.keys do return
	if x.keys do _ = cage_xform_cancel(app)
	if model_gizmo_object(app) == nil do return
	cage_xform_begin(app, handle, app.model.pointer, true)
}

// X, Y or Z during a key's drag: keeps it to that axis, or frees it again.
cage_xform_axis :: proc(app: ^App, i: int) {
	x := &app.model.xform
	if !x.keys do return
	if obj := cage_xform_object(app); obj != nil {
		copy(obj.cage.mesh.positions[:], x.start[:])
		_ = cage_positions_moved(app, obj, x.plan.verts[:])
	}
	point_xform_axis(&x.core, i)
}

// The Model tool's own keys before the bindings, while the gizmo shows or a key's drag
// goes: G, R and S start a move, turn or scale; X, Y and Z keep it to an axis; Enter keeps
// it and Escape puts the points back. True for a chord they take.
model_key_taken :: proc(app: ^App, chord: Chord) -> bool {
	if app.tool != .Model || chord.mods != {} do return false
	switch chord.key {
	case KEY_G, KEY_R, KEY_S:
		return model_gizmo_object(app) != nil || app.model.xform.keys
	case KEY_X, KEY_Y, KEY_Z, KEY_RETURN, KEY_KP_ENTER, KEY_ESCAPE:
		return app.model.xform.keys
	}
	return false
}

model_keys :: proc(app: ^App) {
	d := &app.device
	if app.tool != .Model do return
	if model_key_taken(app, {key = KEY_G}) {
		if chord_down(d, {key = KEY_G}) do cage_xform_key(app, .View)
		if chord_down(d, {key = KEY_R}) do cage_xform_key(app, .Turn_View)
		if chord_down(d, {key = KEY_S}) do cage_xform_key(app, .Scale)
	}
	if !app.model.xform.keys do return
	for k, i in ([3]Key{KEY_X, KEY_Y, KEY_Z}) do if chord_down(d, {key = k}) do cage_xform_axis(app, i)
	if chord_down(d, {key = KEY_RETURN}) || chord_down(d, {key = KEY_KP_ENTER}) do cage_xform_end(app)
	if chord_down(d, {key = KEY_ESCAPE}) do _ = cage_xform_cancel(app)
}

// The selection's gizmo over the cage, the handle held or under the pointer lit, and the
// falloff's reach ringed round the middle while a drag with one goes.
draw_model_gizmo :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	x := &app.model.xform
	sc := model_gizmo_screen(app, input.size)
	hover := gizmo.Handle.None
	if x.handle == .None && input.hovered do hover = model_gizmo_pick(app, input.mouse_pos, input.size)
	draw_point_xform(app, o, input, &x.core, sc, hover)
	// The reach shows only while a drag goes, as Blender's proportional circle does, so a
	// still view is not crossed by a ring wider than the cage.
	obj := model_gizmo_object(app)
	if obj == nil || !sc.ok || app.model.falloff <= 0 || !x.live do return
	reach := model_falloff_reach(app, &obj.cage.mesh) * obj.transform.scale
	center, _ := model_selection_middle(obj)
	px := reach / max(camera.orbit_world_per_px(app.camera, center, input.size.y), 1e-9)
	overlay_circle(o, sc.center, px, overlay_color({1, 0.55, 0.15, 0.5}), 1.5 * gizmo_scale(app))
}

// The `cage` script verb: `cage pick 0 4 5` picks those points of the selected cage (as
// Select picking points does), `cage move x y z` moves its selection that far in the world,
// `cage turn x|y|z degrees` turns it about its middle, `cage scale f` scales it there, each
// as the gizmo's drag would, with the symmetry and falloff set, one undo step. Returns
// why not, or "".
cage_script :: proc(app: ^App, obj: ^Object, text: string) -> string {
	USAGE :: "cage takes pick 0 4 5 (point numbers), move x y z, turn x|y|z degrees or scale f"
	if obj == nil || obj.cage == nil do return "the selected object is not a cage"
	words := strings.fields(text, context.temp_allocator)
	if len(words) < 2 do return USAGE
	cage := &obj.cage.mesh
	number :: proc(w: string) -> (f32, bool) {
		v, ok := strconv.parse_f32(w)
		return v, ok
	}
	if words[0] == "pick" {
		// On the heap: the snapshot frees the temp memory (object_put), so nothing temp made
		// before it is read after.
		points := make([dynamic]u32)
		defer delete(points)
		for w in words[1:] {
			v, ok := strconv.parse_int(w)
			if !ok || v < 0 || v >= len(cage.positions) do return fmt.tprintf("%q is no point of the cage (it has %d)", w, len(cage.positions))
			append(&points, u32(v))
		}
		before := history_snapshot(app, obj, "pick points")
		if !poly.pick_points(cage, points[:], true) {
			history_snapshot_drop(before)
			return "those points were picked already"
		}
		if !cage_rebuild(app, obj) {
			history_snapshot_drop(before)
			return "the cage could not be drawn"
		}
		history_record_swap(app, obj.id, before, kind = .Model)
		return ""
	}
	m := matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	move: Vec3
	switch words[0] {
	case "move":
		if len(words) != 4 do return USAGE
		for k in 0 ..< 3 {
			v, ok := number(words[1 + k])
			if !ok do return USAGE
			move[k] = v
		}
	case "turn":
		if len(words) != 3 do return USAGE
		axis: Vec3
		switch words[1] {
		case "x": axis = {1, 0, 0}
		case "y": axis = {0, 1, 0}
		case "z": axis = {0, 0, 1}
		case: return USAGE
		}
		degrees, ok := number(words[2])
		if !ok do return USAGE
		m = linalg.matrix3_rotate_f32(linalg.to_radians(degrees), axis)
	case "scale":
		if len(words) != 2 do return USAGE
		f, ok := number(words[1])
		if !ok || f <= 0 do return USAGE
		m = point_xform_scale_matrix({}, f, false)
	case:
		return USAGE
	}
	if !model_has_selection(cage) do return "the cage has nothing selected"
	if !cage_selection_map(app, obj, m, move) do return "the cage could not be drawn"
	return ""
}

// Moves `obj`'s cage selection by the world map about its middle by `m`, then along
// `move`, with the symmetry and falloff set, as one undo step (none when nothing moved).
// Returns false only on a GPU failure.
cage_selection_map :: proc(app: ^App, obj: ^Object, m: matrix[3, 3]f32, move: Vec3) -> bool {
	cage := &obj.cage.mesh
	x := &app.model.xform
	cage_xform_drop(app)
	x.id = obj.id
	x.before = history_snapshot(app, obj, "move selection")
	append(&x.start, ..cage.positions[:])
	x.pivot, _ = model_selection_middle(obj)
	carried := make([dynamic]u32, context.temp_allocator)
	poly.selection_points(cage, &carried)
	x.plan = poly.point_move_plan(cage, carried[:], model_axes(app), model_falloff_reach(app, cage))
	if !cage_xform_apply(app, obj, m, move) {
		cage_xform_drop(app)
		return false
	}
	cage_xform_end(app)
	return true
}

// Moves the cage's selection by the value typed for `handle`, as one undo step: an arm's
// number sets the selection's middle along it ("+0.5" moves it that far), a ring's turns
// it that many degrees, a knob's or the scale's is the factor ("+0.5" adds half). False,
// changing nothing, when the text is no value.
cage_entry_apply :: proc(app: ^App, obj: ^Object, handle: gizmo.Handle, text: string) -> bool {
	if obj.cage == nil || !model_has_selection(&obj.cage.mesh) do return false
	s := strings.trim_space(text)
	op: u8
	if len(s) > 0 && (s[0] == '+' || s[0] == '*' || s[0] == 'x') {
		op = s[0]
		s = strings.trim_space(s[1:])
	}
	v, ok := strconv.parse_f32(s)
	if !ok || math.is_nan(v) || math.is_inf(v) do return false
	axes := model_gizmo_axes(app, obj)
	mid, _ := model_selection_middle(obj)
	m := matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	move: Vec3
	#partial switch handle {
	case .X, .Y, .Z:
		axis := axes[int(handle) - int(gizmo.Handle.X)]
		switch op {
		case '+': move = axis * v
		case 0:   move = axis * (v - linalg.dot(mid, axis))
		case:     return false
		}
	case .Turn_X ..= .Turn_View:
		if op != 0 && op != '+' do return false
		i := int(handle) - int(gizmo.Handle.Turn_X)
		axis := axes[i] if i < 3 else -camera.orbit_toward(app.camera, mid)
		m = linalg.matrix3_rotate_f32(linalg.to_radians(v), linalg.normalize(axis))
	case .Scale, .Scale_X, .Scale_Y, .Scale_Z:
		f := 1 + v if op == '+' else v
		if f <= 0 do return false
		i := gizmo.stretch_axis(handle)
		m = point_xform_scale_matrix(axes[i] if i >= 0 else {}, f, i >= 0)
	case:
		return false
	}
	return cage_selection_map(app, obj, m, move)
}
