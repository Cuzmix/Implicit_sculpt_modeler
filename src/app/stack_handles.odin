package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../geom"
import "../gizmo"
import "../sculpt"
import "../ui"

// The Live stack's handles in the view, while its card shows the row they belong to
// open, as Blender's modifier gizmos and Nomad's repeater handles put a row's main value
// on the model: Array's step as an arrow from the object to its first copy, whose tip a
// drag moves; Radial's pivot as a dot, with the circle its copies stand on, which a drag
// moves; and each of Mirror's planes as an outline through the object with a chip naming
// the side it keeps, which a tap turns over. Only the open row's handle shows, so the
// view never fills with handles and each one says which row it is. A drag moves the
// point across the view at the depth it had, as a light's marker does, one undo step from
// press to release (stack_drag_end); Ctrl or the Move tool's Snap latch snaps it to
// tenths of the object's own units. A press on a handle is always the handle's, before
// the tool's (navigate.odin), so a pinned card's handles never paint a stroke.

// A press on a Live stack handle, between frames.
Stack_Press :: struct {
	active: bool,
	row:    Stack_Row, // Array's tip, Radial's pivot, or a Mirror chip's tap
	object: int,
	from:   [2]f32, // where the press went down, on screen
	at:     [2]f32, // where the handle was on screen then
	depth:  Vec3, // ...and in the scene, whose depth the drag keeps
	hover:  bool, // a mouse or pen hovers on the open row's handle, drawn lit
	moves:  int, // drags and taps made, for the exit stats
}

STACK_ARROW_COLOR :: [4]f32{0.37, 0.84, 0.77, 1}
STACK_PIVOT_COLOR :: [4]f32{0.56, 0.71, 1, 1}
STACK_PLANE_COLOR :: [4]f32{0.94, 0.64, 0.37, 1}
// The tip's and the pivot's dot, in points.
STACK_HANDLE_PX :: 9
// A Mirror chip's height, in points, as the mock's chips are.
STACK_CHIP_H :: 28
// How far each step of a snapped drag moves, in the object's own units.
STACK_HANDLE_SNAP :: 0.1

// The object and the row whose handle shows: the selected object's open row of the Live
// stack card, while the card shows, when the row has a handle and is shown.
stack_handle_row :: proc(app: ^App) -> (obj: ^Object, row: Stack_Row, ok: bool) {
	c := &app.kit.stack
	if !c.opened || !card_shown(app, .Stack) do return
	obj = selected_object(app)
	if obj == nil || obj.id != c.object || !stack_row_in(app, obj, c.open) do return
	#partial switch c.open {
	case .Mirror: ok = obj.stack.mirror.shown && obj.stack.mirror.axes != {}
	case .Array: ok = obj.stack.array.shown
	case .Radial: ok = obj.stack.radial.shown
	}
	return obj, c.open, ok
}

// Where the dragged point of row `row` is in the scene: the first Array step's end, or
// the Radial pivot.
@(private = "file")
stack_handle_world :: proc(obj: ^Object, row: Stack_Row) -> Vec3 {
	p := obj.stack.array.offset if row == .Array else obj.stack.radial.pivot
	q := transform_matrix(obj.transform) * [4]f32{p.x, p.y, p.z, 1}
	return q.xyz
}

// How far the object reaches from its own origin across its own axes, for the Mirror
// planes' size.
@(private = "file")
stack_reach :: proc(obj: ^Object) -> (half: Vec3) {
	local := geom.AABB_EMPTY
	s := object_sculptor(obj)
	if s != nil do for c in s.chunks do if c.bounds.lo.x <= c.bounds.hi.x {
		geom.aabb_grow(&local, c.bounds.lo)
		geom.aabb_grow(&local, c.bounds.hi)
	}
	if local.lo.x > local.hi.x do return {1, 1, 1}
	for k in 0 ..< 3 do half[k] = max(abs(local.lo[k]), abs(local.hi[k])) * 1.15
	return
}

// Mirror plane `a`'s corners in the scene, and the point its chip stands on: half
// way out along the next axis's + side (above the middle on the X plane, as Y is up),
// so two planes' chips never meet at the object's middle.
@(private = "file")
stack_plane :: proc(obj: ^Object, a: int) -> (corners: [4]Vec3, chip: Vec3) {
	half := stack_reach(obj)
	b, c := (a + 1) % 3, (a + 2) % 3
	world := transform_matrix(obj.transform)
	put :: proc(m: matrix[4, 4]f32, p: Vec3) -> Vec3 {return (m * [4]f32{p.x, p.y, p.z, 1}).xyz}
	signs := [4][2]f32{{1, 1}, {1, -1}, {-1, -1}, {-1, 1}}
	for s, i in signs {
		p: Vec3
		p[b], p[c] = s.x * half[b], s.y * half[c]
		corners[i] = put(world, p)
	}
	top: Vec3
	top[b] = 0.5 * half[b]
	return corners, put(world, top)
}

// Mirror plane `a`'s chip text.
@(private = "file")
stack_plane_chip :: proc(obj: ^Object, a: int) -> string {
	return fmt.tprintf("Mirror %v · keeps %s", sculpt.Axis(a), "−" if obj.stack.mirror.minus else "+")
}

// The half size of a chip with text `s`, in window pixels.
@(private = "file")
stack_chip_half :: proc(app: ^App, s: string) -> [2]f32 {
	t := app.kit.ctx.theme
	px := gizmo_scale(app)
	return {(ui.text_width(&app.kit.ctx, s, t.small_size) * 0.5 + 10) * px, STACK_CHIP_H * 0.5 * px}
}

// Whether a press at `at` lands on the open row's handle: the tip, the pivot, or a
// shown Mirror plane's chip.
stack_handle_pick :: proc(app: ^App, at, size: [2]f32) -> bool {
	obj, row, ok := stack_handle_row(app)
	if !ok || size.x <= 0 || size.y <= 0 do return false
	vp := view_proj_of(app, size)
	if row == .Mirror {
		for a in 0 ..< 3 {
			if plane_off(obj, a) do continue
			_, chip := stack_plane(obj, a)
			s, seen := gizmo.project(vp, chip, size)
			if !seen do continue
			half := stack_chip_half(app, stack_plane_chip(obj, a))
			if abs(at.x - s.x) <= half.x && abs(at.y - s.y) <= half.y do return true
		}
		return false
	}
	s, seen := gizmo.project(vp, stack_handle_world(obj, row), size)
	return seen && linalg.length(at - s) <= gizmo_radius(app)
}

@(private = "file")
plane_off :: proc(obj: ^Object, a: int) -> bool {return sculpt.Axis(a) not_in obj.stack.mirror.axes}

// Whether a press at `at` is the Live stack handles' rather than a tool's.
stack_handles_take_press :: proc(app: ^App, at, size: [2]f32) -> bool {
	return stack_handle_pick(app, at, size)
}

// Follows the viewport's input for the handles. Returns true while a press on one runs
// (or ended this frame), so no tool sees it.
stack_handles_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	p := &app.ui.stack_press
	if !p.active {
		p.hover = input.hovered && !input.primary && stack_handle_pick(app, input.mouse_pos, input.size)
	}
	if p.active {
		obj := object_by_id(app, p.object)
		if !input.primary || obj == nil {
			p.active = false
			p.moves += 1
			stack_drag_end(app, force = true)
			return true
		}
		if p.row == .Mirror do return true
		// Across the view at the depth it had, by as much as the pointer moved.
		origin, dir := mouse_ray(app.camera, p.at + input.mouse_pos - p.from, input.size)
		forward := linalg.transpose(view_rotation(app)) * Vec3{0, 0, -1}
		along := linalg.dot(dir, forward)
		if abs(along) < 1e-6 do return true
		moved := origin + dir * (linalg.dot(p.depth - origin, forward) / along)
		local := (linalg.inverse(transform_matrix(obj.transform)) * [4]f32{moved.x, moved.y, moved.z, 1}).xyz
		if app.move.snap || app.device.ctrl do for &x in local do x = gizmo.snap(x, STACK_HANDLE_SNAP)
		if !vec_ok(local) do return true
		before := obj.stack
		if p.row == .Array do obj.stack.array.offset = local
		else do obj.stack.radial.pivot = local
		if obj.stack != before do stack_drag_changed(app, obj, before)
		return true
	}
	if !input.press || !input.primary do return false
	start := gesture_start(input)
	if !stack_handle_pick(app, start, input.size) do return false
	obj, row, _ := stack_handle_row(app)
	p^ = {active = true, row = row, object = obj.id, from = start, moves = p.moves}
	if row == .Mirror {
		// A tap on a plane's chip turns the kept side over, for every plane, as the card's
		// switch does, since the row keeps one side for all of them.
		s := obj.stack
		s.mirror.minus = !s.mirror.minus
		stack_set(app, obj, s, "Mirror side")
		return true
	}
	p.depth = stack_handle_world(obj, row)
	p.at, _ = gizmo.project(view_proj_of(app, input.size), p.depth, input.size)
	return true
}

@(private = "file")
vec_ok :: proc(v: Vec3) -> bool {
	for x in v do if !(abs(x) <= 100) do return false
	return true
}

// The open row's handle: Array's arrow and tip with its step, Radial's ring and pivot,
// or Mirror's plane outlines and their chips; lit while held or hovered.
draw_stack_handles :: proc(app: ^App, o: Overlay, size: [2]f32) {
	obj, row, ok := stack_handle_row(app)
	if !ok do return
	t := o.ctx.theme
	vp := view_proj_of(app, size)
	px := gizmo_scale(app)
	p := app.ui.stack_press
	lit := p.hover || (p.active && p.row == row)
	origin, origin_seen := gizmo.project(vp, obj.transform.position, size)
	switch row {
	case .Mirror:
		for a in 0 ..< 3 {
			if plane_off(obj, a) do continue
			corners, chip := stack_plane(obj, a)
			shown: [4][2]f32
			seen := true
			for c, i in corners {
				s, in_front := gizmo.project(vp, c, size)
				shown[i] = s
				seen = seen && in_front
			}
			if seen {
				overlay_fill(o, shown[:], overlay_color({STACK_PLANE_COLOR.r, STACK_PLANE_COLOR.g, STACK_PLANE_COLOR.b, 0.07}))
				overlay_polyline(o, shown[:], overlay_color({STACK_PLANE_COLOR.r, STACK_PLANE_COLOR.g, STACK_PLANE_COLOR.b, 0.75}), 1.5 * px, closed = true)
			}
			if s, chip_seen := gizmo.project(vp, chip, size); chip_seen {
				text := stack_plane_chip(obj, a)
				half := stack_chip_half(app, text)
				edge := overlay_color(STACK_PLANE_COLOR)
				overlay_rect(o, s - half, s + half, half.y, t.surface, edge, (2 if lit else 1.25) * px)
				ui.text(o.ctx, text, (s.x + o.origin.x) / o.scale, (s.y + o.origin.y) / o.scale, t.small_size, edge, .Semibold, .Center)
			}
		}
	case .Array:
		tip, seen := gizmo.project(vp, stack_handle_world(obj, row), size)
		if !seen || !origin_seen do return
		color := overlay_color(STACK_ARROW_COLOR)
		overlay_line(o, origin, tip, color, 2 * px)
		if d := tip - origin; linalg.length(d) > 1 {
			// An arrowhead just short of the tip's dot.
			u := linalg.normalize(d)
			n := [2]f32{-u.y, u.x}
			back := tip - u * (STACK_HANDLE_PX + 2) * px
			head := [3][2]f32{back, back - u * 12 * px + n * 7 * px, back - u * 12 * px - n * 7 * px}
			overlay_fill(o, head[:], color)
		}
		stack_dot(o, tip, STACK_ARROW_COLOR, lit, px)
		// The step's values past the tip, along the arrow, so they never sit on it.
		ahead := [2]f32{0, 1}
		if d := tip - origin; linalg.length(d) > 1 do ahead = linalg.normalize(d)
		a := obj.stack.array.offset
		overlay_label(o, fmt.tprintf("Step %.2f, %.2f, %.2f", a.x, a.y, a.z), tip + ahead * 30 * px)
	case .Radial:
		pivot := stack_handle_world(obj, row)
		pivot_at, seen := gizmo.project(vp, pivot, size)
		if !seen do return
		// The circle the object's origin goes round, which its copies stand on.
		turn := transform_rotation(obj.transform)
		axis: Vec3
		axis[int(obj.stack.radial.axis)] = 1
		axis = linalg.normalize(turn * axis)
		u := obj.transform.position - pivot
		u -= axis * linalg.dot(u, axis)
		if linalg.length(u) > 1e-5 {
			v := linalg.cross(axis, u)
			ring: [64][2]f32
			all := true
			for &r, i in ring {
				w := f32(i) / len(ring) * 2 * math.PI
				s, front := gizmo.project(vp, pivot + u * math.cos(w) + v * math.sin(w), size)
				r = s
				all = all && front
			}
			if all do overlay_polyline(o, ring[:], overlay_color({STACK_PIVOT_COLOR.r, STACK_PIVOT_COLOR.g, STACK_PIVOT_COLOR.b, 0.45}), 1.5 * px, closed = true)
			if origin_seen do overlay_line(o, pivot_at, origin, overlay_color({STACK_PIVOT_COLOR.r, STACK_PIVOT_COLOR.g, STACK_PIVOT_COLOR.b, 0.45}), 1.5 * px)
		}
		stack_dot(o, pivot_at, STACK_PIVOT_COLOR, lit, px)
		overlay_label(o, "Pivot", pivot_at + {0, 28 * px})
	case .Smooth, .Cage_Mirror, .Thickness, .Bevel, .Along:
	}
}

// A handle's dot: a dark plate ringed in its colour, filled while lit.
@(private = "file")
stack_dot :: proc(o: Overlay, at: [2]f32, color: [4]f32, lit: bool, px: f32) {
	r := STACK_HANDLE_PX * px
	overlay_disc(o, at, r + 2 * px, overlay_color({0.08, 0.08, 0.09, 0.85}))
	overlay_disc(o, at, r, overlay_color(color) if lit else overlay_color({color.r, color.g, color.b, 0.35}))
	overlay_circle(o, at, r, overlay_color(color), 2 * px)
}
