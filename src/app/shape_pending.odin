package main

import "core:math/linalg"

import "../ui"

// Two-phase shapes, as Nomad's: a mask or hide shape, or a Clip, Slice or Knife line, drawn with
// a finger or the pen waits on screen with Apply, Flip and Cancel under it instead of
// applying as the drag lets go, since a finger draws roughly and the view often wants
// turning first. Its handles (corners, a line's ends, the middle to move it all) can be
// dragged meanwhile; the view turns under it, and Apply uses the view as it is then.
// A mouse's shape applies at once, as before (Settings > Touch > Shapes apply).

Shape_Kind :: enum u8 {
	None,
	Mask,
	Hide,
	Clip,
	Slice,
	Knife,
}

// Whether shapes of `kind` are a line of two points across the view.
shape_is_line :: proc(kind: Shape_Kind) -> bool {
	return kind == .Clip || kind == .Slice || kind == .Knife
}

// When a drawn shape applies (Settings > Touch).
Shape_Apply :: enum u8 {
	Auto, // the mouse's at once, a finger's or the pen's after Apply
	Now, // always as the drag lets go
	Confirm, // always after Apply
}

Shape_Request :: enum u8 {
	None,
	Apply,
	Flip,
	Cancel,
}

Shape_Pending :: struct {
	kind:      Shape_Kind,
	rectangle: bool, // a mask or hide rectangle (else a lasso); a line is always two points
	flip:      bool, // unmask, hide inside, or clip the other side
	// Window coordinates: a rectangle's two opposite corners, a line's two ends, or the
	// lasso's points.
	points:    [dynamic][2]f32,
	size:      [2]f32, // the window it was drawn in
	before:    [dynamic][2]f32, // the points as a handle drag found them, for a cancel
	grab:      int, // the handle being dragged (shape_handles), or -1
	// What the bar or a key asked for, carried out where the shape is applied (the
	// Brush tool's turn in the frame), never from the interface's layout.
	request:   Shape_Request,
}

// Whether a shape drawn by `pointer` applies as its drag lets go.
shape_apply_now :: proc(setting: Shape_Apply, pointer: ui.Pointer_Kind) -> bool {
	switch setting {
	case .Now:     return true
	case .Confirm: return false
	case .Auto:
	}
	return pointer == .Mouse
}

// Takes a shape whose drag just let go: applies it now when the setting says so for the
// pointer that drew it, else keeps it waiting (in place of any other).
shape_finish :: proc(app: ^App, kind: Shape_Kind, points: [][2]f32, rectangle, flip: bool, size: [2]f32, pointer: ui.Pointer_Kind) {
	p := &app.shape_pending
	p.kind, p.rectangle, p.flip, p.size, p.grab, p.request = kind, rectangle, flip, size, -1, .None
	clear(&p.points)
	if rectangle || shape_is_line(kind) {
		append(&p.points, points[0], points[len(points) - 1])
	} else {
		append(&p.points, ..points)
	}
	// The shape drawn is a path completed, which a Pencil Pro feels.
	if pointer == .Pen do haptic(app, .Path_Completed)
	if shape_apply_now(app.nav.shape_apply, pointer) do shape_apply(app)
}

// Applies the waiting shape with the view as it is now, and lets it go.
shape_apply :: proc(app: ^App) {
	p := &app.shape_pending
	defer shape_clear(p)
	if !shape_can_apply(app) do return
	size := p.size
	switch p.kind {
	case .None:
	case .Mask, .Hide:
		polygon := shape_polygon(p.points[:], p.rectangle, size)
		if len(polygon) < 3 do return
		if p.kind == .Mask do mask_shape_command(app, polygon, size, p.flip)
		else do hide_shape_command(app, polygon, size, p.flip)
	case .Clip:
		clip_command(app, p.points[0], p.points[1], p.flip, size)
	case .Slice:
		slice_request(app, p.points[0], p.points[1], size)
	case .Knife:
		knife_request(app, p.points[0], p.points[1], p.flip, size)
	}
}

// Whether Apply can do anything: an object to apply to, and a shape that is still one
// after its handles were dragged.
shape_can_apply :: proc(app: ^App) -> bool {
	p := &app.shape_pending
	if p.kind == .None || selected_object(app) == nil || len(p.points) < 2 do return false
	reach: f32 = 0
	for q in p.points do reach = max(reach, linalg.length(q - p.points[0]))
	return reach >= gesture_min_px(app)
}

shape_clear :: proc(p: ^Shape_Pending) {
	p.kind, p.grab, p.request = .None, -1, .None
	clear(&p.points)
}

// Carries out what was asked of the waiting shape, and follows the window: a new size
// scales the shape about the middle by the change in height, as the view's projection
// keeps its vertical angle, so it stays over the same part of the model. Leaving the
// Brush tool lets it go. Runs at the Brush tool's turn in the frame, and for the others.
shape_pending_frame :: proc(app: ^App, size: [2]f32) {
	p := &app.shape_pending
	if p.kind == .None do return
	if app.tool != .Brush {
		shape_clear(p)
		return
	}
	if size != p.size && size.y > 0 && p.size.y > 0 {
		k := size.y / p.size.y
		for &q in p.points do q = size * 0.5 + (q - p.size * 0.5) * k
		p.size = size
	}
	request := p.request
	p.request = .None
	switch request {
	case .None:
	case .Apply:  shape_apply(app)
	case .Flip:   p.flip = !p.flip
	case .Cancel: shape_clear(p)
	}
}

// The shape's handles in window coordinates: a rectangle's four corners or a line's two
// ends, then (always last) the middle, which moves it all. A lasso has only the middle.
shape_handles :: proc(p: ^Shape_Pending) -> (handles: [5][2]f32, n: int) {
	if len(p.points) == 0 do return
	lo, hi := p.points[0], p.points[0]
	for q in p.points do lo, hi = linalg.min(lo, q), linalg.max(hi, q)
	switch {
	case shape_is_line(p.kind):
		handles[0], handles[1], n = p.points[0], p.points[1], 2
	case p.rectangle:
		a, b := p.points[0], p.points[1]
		handles[0], handles[1], handles[2], handles[3], n = a, {b.x, a.y}, b, {a.x, b.y}, 4
	}
	handles[n] = (lo + hi) * 0.5
	n += 1
	return
}

// How near a press must be to a handle to take it, in window coordinates: half a touch
// target, so a finger finds it as it finds any control.
shape_handle_reach :: proc(app: ^App) -> f32 {
	return app.kit.ctx.theme.target * 0.5 * app.kit.scale
}

// The handle under `at`, the nearest when two are in reach, or -1.
shape_handle_at :: proc(app: ^App, at: [2]f32) -> int {
	p := &app.shape_pending
	if p.kind == .None || app.tool != .Brush do return -1
	handles, n := shape_handles(p)
	best, found := shape_handle_reach(app), -1
	for i in 0 ..< n {
		if d := linalg.length(handles[i] - at); d <= best do best, found = d, i
	}
	return found
}

// Starts dragging handle `h`, keeping the shape as it is for a cancel.
shape_grab :: proc(app: ^App, h: int) {
	p := &app.shape_pending
	p.grab = h
	clear(&p.before)
	append(&p.before, ..p.points[:])
}

// Moves the grabbed handle by `delta`.
shape_drag :: proc(app: ^App, delta: [2]f32) {
	p := &app.shape_pending
	if p.grab < 0 || delta == {} do return
	_, n := shape_handles(p)
	if p.grab == n - 1 {
		for &q in p.points do q += delta
		return
	}
	if !p.rectangle || shape_is_line(p.kind) {
		p.points[p.grab] += delta
		return
	}
	// A rectangle keeps two opposite corners; the other two share their coordinates.
	a, b := &p.points[0], &p.points[1]
	switch p.grab {
	case 0: a^ += delta
	case 1: b.x += delta.x; a.y += delta.y
	case 2: b^ += delta
	case 3: a.x += delta.x; b.y += delta.y
	}
}

// Ends a handle drag; `cancel` (another finger made it a gesture) puts the shape back.
shape_release :: proc(app: ^App, cancel: bool) {
	p := &app.shape_pending
	if cancel && p.grab >= 0 && len(p.before) == len(p.points) do copy(p.points[:], p.before[:])
	p.grab = -1
}

shape_pending_destroy :: proc(p: ^Shape_Pending) {
	delete(p.points)
	delete(p.before)
}

// Draws the waiting shape as it was dragged, with its handles.
draw_shape_pending :: proc(app: ^App, o: Overlay, size: [2]f32) {
	p := &app.shape_pending
	if p.kind == .None do return
	switch p.kind {
	case .None:
	case .Mask:
		color := overlay_color({0.95, 0.55, 0.35, 1} if !p.flip else {0.5, 0.8, 1, 1})
		fill := overlay_color({0.95, 0.55, 0.35, 0.12} if !p.flip else {0.5, 0.8, 1, 0.12})
		draw_shape_outline(o, p.points[:], p.points[len(p.points) - 1], p.rectangle, color, fill)
	case .Hide:
		color := overlay_color({0.45, 0.9, 0.5, 1} if !p.flip else {1, 0.45, 0.4, 1})
		fill := overlay_color({0.45, 0.9, 0.5, 0.12} if !p.flip else {1, 0.45, 0.4, 0.12})
		draw_shape_outline(o, p.points[:], p.points[len(p.points) - 1], p.rectangle, color, fill)
	case .Clip, .Slice, .Knife:
		// Clip and Knife shade the side that goes; Slice keeps both.
		draw_clip_line(o, p.points[0], p.points[1], p.flip, p.kind != .Slice, size)
	}
	handles, n := shape_handles(p)
	r := 6 * app.kit.scale
	for i in 0 ..< n {
		grabbed := i == p.grab
		overlay_disc(o, handles[i], r + 1.5, overlay_color({0, 0, 0, 0.45}))
		overlay_disc(o, handles[i], r, overlay_color({1, 1, 1, 1} if !grabbed else {1, 0.85, 0.3, 1}))
	}
	// The middle handle is a ring round its dot, so it reads as "move" apart from corners.
	overlay_circle(o, handles[n - 1], r + 5 * app.kit.scale, overlay_color({1, 1, 1, 0.8}), 1.5)
}

// The bar under the waiting shape: Apply, Flip and Cancel. It asks; the frame acts
// (shape_pending_frame), so the interface changes nothing of the sculpt itself.
kit_shape_bar :: proc(app: ^App) {
	p := &app.shape_pending
	if p.kind == .None || app.tool != .Brush do return
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	lo, hi := p.points[0], p.points[0]
	for q in p.points do lo, hi = linalg.min(lo, q), linalg.max(hi, q)
	// The shape's points are the main pane's; the bar is placed in the window's points.
	o := app.ui.viewport_origin
	lo, hi = (lo + o) / k.scale, (hi + o) / k.scale
	if shape_is_line(p.kind) {
		// A line reaches across the view: the bar goes by the end it was dragged to.
		lo, hi = (p.points[1] + o) / k.scale, (p.points[1] + o) / k.scale
	}
	size, _ := ui.prev_layout(ctx, "shape bar")
	if size == {} do size = {300, t.target + 8}
	area := ui.safe_area(ctx)
	dock := shelf_bottom_size(app)
	gap := t.target * 0.5 + 8 // clear of the handles
	pos := [2]f32{(lo.x + hi.x - size.x) * 0.5, hi.y + gap}
	// Above the shape where under it would reach the dock.
	if pos.y + size.y > area.y + area.h - t.edge - dock_lift(app) - dock.y - 8 do pos.y = lo.y - gap - size.y
	pos.x = clamp(pos.x, area.x + t.edge, max(area.x + area.w - t.edge - size.x, area.x + t.edge))
	pos.y = clamp(pos.y, area.y + t.edge, max(area.y + area.h - t.edge - size.y, area.y + t.edge))
	ui.begin_at(ctx, "shape bar", pos, {direction = .Row, gap = 4, padding = 4, radius = t.radius_large + 4, background = .Panel, center = true})
	if ui.button(ctx, "Apply", .Solid, .Accent, glyph = ui.ICON_CHECK, keys = "Enter", enabled = shape_can_apply(app)) do p.request = .Apply
	if p.kind != .Slice && ui.button(ctx, SHAPE_FLIP_NAMES[p.kind] if !p.flip else SHAPE_UNFLIP_NAMES[p.kind], .Light) do p.request = .Flip
	if ui.button(ctx, "Cancel", .Light, glyph = ui.ICON_CLOSE, keys = "Escape") do p.request = .Cancel
	ui.end(ctx)
}

// What Flip turns the shape into, as its button says.
@(rodata, private = "file")
SHAPE_FLIP_NAMES := [Shape_Kind]string {
	.None  = "",
	.Mask  = "Unmask",
	.Hide  = "Hide inside",
	.Clip  = "Other side",
	.Slice = "",
	.Knife = "Other side",
}

@(rodata, private = "file")
SHAPE_UNFLIP_NAMES := [Shape_Kind]string {
	.None  = "",
	.Mask  = "Mask",
	.Hide  = "Show inside",
	.Clip  = "Other side",
	.Slice = "",
	.Knife = "Other side",
}
