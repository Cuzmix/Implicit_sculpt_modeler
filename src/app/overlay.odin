package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../camera"
import "../gizmo"
import "../sculpt"
import "../ui"

// Drawing over the viewport through the kit, in the main pane's coordinates Viewport_Input
// uses: the kit's points are window coordinates over `scale`, and the pane starts at
// `origin` in the window. Widths and radii are window coordinates too, as the tools
// measure them.
Overlay :: struct {
	ctx:    ^ui.Context,
	scale:  f32,
	origin: [2]f32,
}

// A viewport point in the kit's points.
@(private = "file")
at :: proc(o: Overlay, p: [2]f32) -> [2]f32 {
	return (p + o.origin) / o.scale
}

// A colour given as red, green, blue and alpha from 0 to 1.
overlay_color :: proc(c: [4]f32) -> ui.Color {
	out: ui.Color
	for i in 0 ..< 4 do out[i] = u8(clamp(c[i], 0, 1) * 255 + 0.5)
	return out
}

overlay_line :: proc(o: Overlay, a, b: [2]f32, color: ui.Color, width: f32) {
	ui.line(o.ctx, at(o, a), at(o, b), color, width / o.scale)
}

overlay_circle :: proc(o: Overlay, center: [2]f32, radius: f32, color: ui.Color, width: f32) {
	ui.stroke_circle(o.ctx, at(o, center), radius / o.scale, color, width / o.scale)
}

overlay_disc :: proc(o: Overlay, center: [2]f32, radius: f32, color: ui.Color) {
	ui.fill_circle(o.ctx, at(o, center), radius / o.scale, color)
}

overlay_polyline :: proc(o: Overlay, points: [][2]f32, color: ui.Color, width: f32, closed := false) {
	shown := make([][2]f32, len(points), context.temp_allocator)
	for p, i in points do shown[i] = at(o, p)
	ui.polyline(o.ctx, shown, color, width / o.scale, closed)
}

// A filled convex polygon.
overlay_fill :: proc(o: Overlay, points: [][2]f32, color: ui.Color) {
	shown := make([][2]f32, len(points), context.temp_allocator)
	for p, i in points do shown[i] = at(o, p)
	ui.fill_convex(o.ctx, shown, color)
}

// The box between two corners, outlined and, when `fill` shows, filled.
overlay_box :: proc(o: Overlay, a, b: [2]f32, color, fill: ui.Color, width: f32) {
	lo := [2]f32{min(a.x, b.x), min(a.y, b.y)}
	hi := [2]f32{max(a.x, b.x), max(a.y, b.y)}
	corners := [4][2]f32{lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}
	if fill.a > 0 do overlay_fill(o, corners[:], fill)
	overlay_polyline(o, corners[:], color, width, closed = true)
}

// The rounded box between corners `lo` and `hi` (lo the smaller), filled when `fill`
// shows and outlined `width` thick when `color` does; the radius is in window
// coordinates, as widths are.
overlay_rect :: proc(o: Overlay, lo, hi: [2]f32, radius: f32, fill, color: ui.Color, width: f32) {
	a, b := at(o, lo), at(o, hi)
	r := ui.Rect{a.x, a.y, b.x - a.x, b.y - a.y}
	if r.w <= 0 || r.h <= 0 do return
	if fill.a > 0 do ui.fill_rect(o.ctx, r, radius / o.scale, fill)
	if color.a > 0 && width > 0 do ui.stroke_rect(o.ctx, r, radius / o.scale, color, width / o.scale)
}

// `s` on a dark plate centred on `center`, since the surface behind is often light.
overlay_label :: proc(o: Overlay, s: string, center: [2]f32) {
	ctx := o.ctx
	t := ctx.theme
	size := t.small_size
	w := ui.text_width(ctx, s, size)
	p := at(o, center)
	ui.fill_rect(ctx, {p.x - w * 0.5 - 8, p.y - size * 0.8 - 4, w + 16, size * 1.6 + 8}, t.radius_small, t.surface)
	ui.text(ctx, s, p.x, p.y, size, t.text, .Regular, .Center)
}

// What an orbit under way turns about, which stays put while the view turns round it, and
// for a moment after a double tap pinned it, a pulse there to show where.
@(private = "file")
draw_pivot :: proc(app: ^App, o: Overlay, size: [2]f32) {
	view_proj := camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
	dot :: proc(o: Overlay, view_proj: matrix[4, 4]f32, at: Vec3, size: [2]f32, alpha: f32) -> (p: [2]f32, ok: bool) {
		p, ok = gizmo.project(view_proj, at, size)
		if !ok do return
		overlay_disc(o, p, 5, overlay_color({0, 0, 0, 0.5 * alpha}))
		overlay_disc(o, p, 3.5, overlay_color({1, 0.8, 0.4, 0.95 * alpha}))
		return
	}
	// Show the pivot dot off hides the dot while the view turns; a pin still pulses, as
	// the double tap's answer.
	if g := app.drag; app.nav.pivot_dot && g.owner == .Orbit && g.moving {
		_, _ = dot(o, view_proj, g.pivot, size, 1)
	} else if l := app.touch.lift; app.nav.pivot_dot && l.moving {
		_, _ = dot(o, view_proj, l.pivot, size, 1)
	}
	p := app.pivot
	if !p.pinned do return
	age := f32(input_clock(app) - p.flash)
	if age < 0 || age >= PIN_FLASH do return
	obj := object_by_id(app, p.object)
	if obj == nil do return
	fade := 1 - age / PIN_FLASH
	if at, ok := dot(o, view_proj, to_world(obj.transform, p.at), size, 1); ok {
		// A ring that grows out of the dot and fades, as a tap's ripple.
		overlay_circle(o, at, (8 + 22 * (1 - fade * fade)) * o.scale, overlay_color({1, 0.8, 0.4, 0.9 * fade}), 2 * o.scale)
	}
}

// The ring that fills while fingers are held still, toward the command the gesture map
// gives the hold, and once Undo or Redo repeat, how many steps they took.
@(private = "file")
draw_hold_history :: proc(app: ^App, o: Overlay) {
	h := app.touch.hold
	if h.ring < 0 do return
	t := o.ctx.theme
	RADIUS :: 44
	center := h.at
	r := RADIUS * o.scale
	overlay_circle(o, center, r, ui.color_fade(t.border_strong, 0.8), 3 * o.scale)
	n := max(int(h.ring * 48), 1)
	points := make([][2]f32, n + 1, context.temp_allocator)
	for &q, i in points {
		a := -math.PI / 2 + 2 * math.PI * h.ring * f32(i) / f32(n)
		q = center + r * [2]f32{math.cos(a), math.sin(a)}
	}
	overlay_polyline(o, points, t.accent, 3 * o.scale)
	if h.fired > 0 {
		overlay_label(o, fmt.tprintf("%s %d", pie_slot_label(app.nav.gestures[gesture_slot(h.most, true)]), h.taken), center - {0, r + 24 * o.scale})
	}
}

// How much of the brush ring a pen at the edge of its hover range fades away.
HOVER_FADE :: 0.7

// Draws the brush circle, the move gizmo or the gesture being dragged over the viewport,
// under the panels in the layer kit_frame kept over the viewport image, then the brush
// pie over everything. Runs after the tools have handled this frame's input, so the
// overlay matches what gets rendered.
draw_viewport_overlay :: proc(app: ^App, input: Viewport_Input) {
	k := &app.kit
	ctx := &k.ctx
	o := Overlay{ctx, k.scale, app.ui.viewport_origin}
	flash_selection_frame(app)
	if layer, ok := k.layer.?; ok {
		k.layer = nil
		from := ui.layer_begin(ctx)
		overlay_viewport(app, o, input)
		ui.layer_end(ctx, layer, from)
	}
	draw_pie(app, o)
}

// How long the safe zone stays outlined after its width last changed, in seconds.
EDGE_SET_SHOW :: 1.0

@(private = "file")
overlay_viewport :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	// Where the safe zone ends, faintly, so it is clear where a press turns the view: while
	// a drag that began in it turns the view and while its width is set, or always when
	// Settings ask, as a guide line through the sculpt the rest of the time.
	edge_in_use := (app.drag.owner != .None && app.drag.edge) || app.kit.ctx.time - app.kit.edge_set_at < EDGE_SET_SHOW
	if app.nav.edge_orbit && (app.nav.edge_show || edge_in_use) && !app.kit.clean {
		lo, hi := edge_inner(app)
		overlay_box(o, lo, hi, overlay_color({1, 1, 1, 0.16}), {}, 1)
	}
	draw_flashes(app, o, input.size)
	draw_history_tint(app, o, input.size)
	draw_layer_tint(app, o, input.size)
	draw_pivot(app, o, input.size)
	draw_hold_history(app, o)
	draw_light_markers(app, o, input.size)
	draw_curve_objects(app, o, input.size)
	draw_focus_marker(app, o, input.size)
	// While the eyedropper's loupe shows, the brush ring under it would only hide the
	// colour being picked.
	if app.ui.eyedrop_held {
		draw_eyedropper(app, o)
		return
	}
	switch app.tool {
	case .Brush:
		draw_size_preview(app, o, input.size, input.hovered || input.dragging)
		draw_symmetry_lines(app, o, input.size)
		draw_shape_pending(app, o, input.size)
		if app.clip.active {
			draw_clip(app, o, input.size)
			break
		}
		if app.mask_shape.active {
			draw_mask_shape(app, o, input.mouse_pos)
			break
		}
		if draw_adjust(app, o) do break
		if app.stroke_edit.open {
			draw_stroke_edit(app, o, input.size)
			break
		}
		if st := app.stroke; st.active && st.rect {
			// The stamp being dragged out: its circle around where it began, and a line to
			// the pointer, the way its top faces.
			color := overlay_color({1, 0.8, 0.4, 0.9})
			overlay_circle(o, st.start, max(linalg.length(input.mouse_pos - st.start), 2), color, 1.5)
			overlay_line(o, st.start, input.mouse_pos, color, 1.5)
			break
		}
		if (input.hovered || input.dragging) && !app.ui.pie.open {
			// A pen hovering high shows the brush faintly, and clearer as it nears the
			// screen, as Procreate's hover preview does, so the ring says how close it is.
			color := overlay_color(brush_ring_color(app, input.primary) * {1, 1, 1, 1 - HOVER_FADE * input.pen_hover})
			center := ring_center(app, input)
			// The brush trails the cursor (the lazy string, the smoothing's lag): the rope
			// runs from where it is to the pointer.
			if app.stroke.active && stroke_trails(app) do overlay_line(o, center, input.mouse_pos, color, 1)
			if brush_alpha(app) != nil && held_brush(input) {
				app.alpha_roll = input.pen_roll
				draw_alpha_outline(app, o, center, color)
			} else {
				// Off the model a ring fixed in the scene is drawn as it would be at the view's
				// middle.
				flat := app.brush.radius_px * brush_size_scale(app, camera.orbit_world_per_px(app.camera, app.camera.target, input.size.y), input.size.y)
				draw_mirror_rings(app, o, input.size, brush_ring_color(app, input.primary) * {1, 1, 1, 1 - HOVER_FADE * input.pen_hover}, flat)
				if !draw_surface_ring(app, o, input.size, color) do overlay_circle(o, center, flat, color, 1.5)
				// A focal shift moves where the brush works: an inner ring where it falls to
				// half strength, as the reference app's cursor shows it.
				if half := brush_half_radius(app); half > 0 {
					inner := overlay_color(brush_ring_color(app, input.primary) * {1, 1, 1, 0.55})
					if !draw_surface_ring(app, o, input.size, inner, half) do overlay_circle(o, center, flat * half, inner, 1)
				}
			}
			// Which way a leaning pen turns the brush, and how far: toward the top of the
			// pen, a radius long at a right angle.
			if lean := input.pen_tilt * app.brush.tilt_strength; app.brush.tilt_strength > 0 && lean != {} {
				angle := min(linalg.to_radians(linalg.length(lean)), camera.MAX_TILT)
				tip := center + linalg.normalize(lean) * (app.brush.radius_px * math.sin(angle))
				overlay_line(o, center, tip, color, 2)
				overlay_disc(o, tip, 3, color)
			}
		}
	case .Move:
		draw_gizmo(app, o, input)
	case .Curve, .Insert:
		draw_curve_overlay(app, o)
		if app.tool == .Curve && app.curve.kind == .Curve do draw_curve_edit(app, o, input.size)
	case .Model:
		draw_model_overlay(app, o, input)
	}
}

// The selected object's gizmo in its mode, the handle under the pointer or dragged in
// the highlight colour, and while a drag goes, what it has done by the pointer.
@(private = "file")
draw_gizmo :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	// A lattice's cage stands in for the gizmo (lattice.odin).
	if obj := lattice_shown(app); obj != nil {
		draw_lattice(app, o, input, obj)
		draw_move_labels(app, o, input)
		return
	}
	sc := gizmo_screen(app, input.size)
	if !sc.ok do return
	app.move.drawn = sc.center
	m := app.move
	if obj := selected_object(app); obj != nil && gizmo_pivot_set(app) {
		// Away from its origin, the gizmo leaves a dot where the origin is.
		view_proj := camera.orbit_proj(app.camera, input.size.x / max(input.size.y, 1)) * camera.orbit_view(app.camera)
		if p, ok := gizmo.project(view_proj, obj.transform.position, input.size); ok {
			overlay_disc(o, p, 4 * gizmo_scale(app), overlay_color({1, 1, 1, 0.5}))
		}
	}
	active := m.drag.handle if m.drag.handle != .None else m.hover
	px := gizmo_scale(app)
	colors := GIZMO_AXIS_COLORS
	color_of :: proc(h, active: gizmo.Handle, c: [4]f32) -> ui.Color {
		return overlay_color(GIZMO_HIGHLIGHT if h == active else c)
	}
	switch m.mode {
	case .Move:
		draw_move_handles(o, sc, active, px)
		r := f32(gizmo.CENTER_PX) * px
		overlay_box(o, sc.center - r, sc.center + r, color_of(.View, active, {1, 1, 1, 0.85}), {}, 2 * px)
	case .Turn:
		draw_turn_rings(o, sc, active, px)
		draw_turn_drag(app, o, sc, input, px)
		overlay_disc(o, sc.center, 3 * px, overlay_color({1, 1, 1, 0.85}))
	case .Scale:
		color := color_of(.Scale, active, {1, 1, 1, 0.85})
		overlay_circle(o, sc.center, sc.arm_px, color, 2 * px)
		overlay_disc(o, sc.center, gizmo.SCALE_DISC_PX * px, overlay_color(GIZMO_HIGHLIGHT if active == .Scale else {1, 1, 1, 0.5}))
		draw_scale_drag(app, o, input, px)
	case .All:
		// Rings first, then the squares, arms and knobs over them, in the order they pick.
		draw_turn_rings(o, sc, active, px)
		draw_plane_squares(o, sc, active, px)
		for i in 0 ..< 3 {
			if !gizmo.all_arm_shows(sc, i) do continue
			color := color_of(gizmo.Handle(int(gizmo.Handle.X) + i), active, colors[i])
			overlay_line(o, sc.center, sc.ends[i], color, 3 * px)
			draw_arrowhead(o, sc.center, sc.ends[i], color, px)
		}
		// The knobs all scale evenly, so they share one colour rather than their axes'.
		knob := color_of(.Scale, active, {1, 1, 1, 0.95})
		for i in 0 ..< 3 {
			if !gizmo.all_arm_shows(sc, i) do continue
			r := f32(gizmo.KNOB_PX) * px
			overlay_box(o, sc.knobs[i] - r, sc.knobs[i] + r, overlay_color({0.1, 0.1, 0.12, 0.9}), knob, 1.5 * px)
		}
		r := f32(gizmo.CENTER_PX) * px
		overlay_box(o, sc.center - r, sc.center + r, color_of(.View, active, {1, 1, 1, 0.85}), {}, 2 * px)
		draw_turn_drag(app, o, sc, input, px)
		draw_scale_drag(app, o, input, px)
	}
	draw_move_labels(app, o, input)
}

// The turn rings of a gizmo seen as `sc`, `active` lit: the far half of each axis ring
// dims, so which way it turns reads; the view ring stays whole.
@(private = "file")
draw_turn_rings :: proc(o: Overlay, sc: gizmo.Screen, active: gizmo.Handle, px: f32) {
	colors := GIZMO_AXIS_COLORS
	for i in 0 ..< 4 {
		if !sc.ring_ok[i] do continue
		h := gizmo.Handle(int(gizmo.Handle.Turn_X) + i)
		c := colors[i] if i < 3 else [4]f32{1, 1, 1, 0.8}
		width := (3 if h == active else 2) * px
		for k in 0 ..< gizmo.RING_POINTS {
			next := (k + 1) % gizmo.RING_POINTS
			shade := c
			if !sc.ring_front[i][k] || !sc.ring_front[i][next] do shade.a *= 0.3
			overlay_line(o, sc.rings[i][k], sc.rings[i][next], overlay_color(GIZMO_HIGHLIGHT if h == active else shade), width)
		}
	}
}

// While a ring is dragged, a line from the middle to the pointer: the angle the drag is
// turning through.
@(private = "file")
draw_turn_drag :: proc(app: ^App, o: Overlay, sc: gizmo.Screen, input: Viewport_Input, px: f32) {
	if d := app.move.drag; d.live && drag_mode(d.handle) == .Turn {
		overlay_line(o, sc.center, input.mouse_pos, overlay_color(GIZMO_HIGHLIGHT), 1.5 * px)
	}
}

// While the scale is dragged, a circle through the pointer about the middle: how far out
// it is, which is what the factor follows.
@(private = "file")
draw_scale_drag :: proc(app: ^App, o: Overlay, input: Viewport_Input, px: f32) {
	if d := app.move.drag; d.live && d.handle == .Scale {
		overlay_circle(o, d.center, linalg.length(input.mouse_pos - d.center), overlay_color({1, 0.85, 0.3, 0.6}), 1.5 * px)
	}
}

// An arrowhead at `tip`, pointing away from `from`, as the All mode's arms end.
@(private = "file")
draw_arrowhead :: proc(o: Overlay, from, tip: [2]f32, color: ui.Color, px: f32) {
	way := linalg.normalize0(tip - from)
	if way == {} do return
	side := [2]f32{-way.y, way.x} * (gizmo.ARROW_HALF_PX * px)
	base := tip - way * (gizmo.ARROW_PX * px)
	head := [3][2]f32{tip + way * (2 * px), base + side, base - side}
	overlay_fill(o, head[:], color)
}

// The move handles of a gizmo seen as `sc`, `active` lit: the plane squares first,
// under the arms, each in the colour of the axis it holds still, then an arm along each
// axis. The middle is the caller's: the Move tool's square, a light's marker.
draw_move_handles :: proc(o: Overlay, sc: gizmo.Screen, active: gizmo.Handle, px: f32) {
	colors := GIZMO_AXIS_COLORS
	draw_plane_squares(o, sc, active, px)
	for i in 0 ..< 3 {
		if !gizmo.arm_shows(sc, i) do continue
		color := overlay_color(GIZMO_HIGHLIGHT if gizmo.Handle(int(gizmo.Handle.X) + i) == active else colors[i])
		overlay_line(o, sc.center, sc.tips[i], color, 3 * px)
		overlay_disc(o, sc.tips[i], 5 * px, color)
	}
}

// The plane squares of a gizmo seen as `sc`, each in the colour of the axis it holds
// still, `active` lit.
@(private = "file")
draw_plane_squares :: proc(o: Overlay, sc: gizmo.Screen, active: gizmo.Handle, px: f32) {
	colors := GIZMO_AXIS_COLORS
	color_of :: proc(h, active: gizmo.Handle, c: [4]f32) -> ui.Color {
		return overlay_color(GIZMO_HIGHLIGHT if h == active else c)
	}
	for i in 0 ..< 3 {
		q, ok := gizmo.square_of(sc, i)
		if !ok do continue
		h := gizmo.Handle(int(gizmo.Handle.YZ) + i)
		c := colors[i]
		c.a = 0.75 if h == active else 0.3
		overlay_fill(o, q[:], color_of(h, active, c))
		c.a = 0.9
		overlay_polyline(o, q[:], color_of(h, active, c), 1.5 * px, closed = true)
	}
}

// What the Move tool shows by the pointer whatever stands in the middle: a topological
// mask's reach, as a circle about the press, and what the drag in progress has done.
@(private = "file")
draw_move_labels :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	px := gizmo_scale(app)
	if g := app.move.topo; g.phase == .Live {
		overlay_circle(o, g.down, linalg.length(input.mouse_pos - g.down), overlay_color({1, 0.85, 0.3, 0.6}), 1.5 * px)
	}
	if text := move_readout(app); text != "" {
		overlay_label(o, text, input.mouse_pos + [2]f32{0, -40 * px})
	}
}

// Points around the brush ring lying on the surface: smooth at the largest brush.
RING_POINTS :: 64

// The brush ring lying on the surface (Brush_Cursor): the brush's circle in the plane the
// surface faces, seen in perspective, with a short tick out along the surface's normal
// from its middle, as ZBrush draws it; with `scale` under 1, a ring that much of the
// brush's radius across, without the tick. False when there is none this frame (off the
// model, or part of it behind the eye), and the flat circle is drawn instead.
@(private = "file")
draw_surface_ring :: proc(app: ^App, o: Overlay, size: [2]f32, color: ui.Color, scale: f32 = 1) -> bool {
	c := app.cursor
	if !c.ok || !app.kit.surface_ring do return false
	view_proj := camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
	if !draw_lying_ring(o, view_proj, size, c.at, c.normal, c.radius * scale, color, 1.5 if scale == 1 else 1, RING_POINTS) do return false
	if scale != 1 do return true
	middle, middle_ok := gizmo.project(view_proj, c.at, size)
	tip, tip_ok := gizmo.project(view_proj, c.at + c.normal * (c.radius * 0.5), size)
	if middle_ok && tip_ok do overlay_line(o, middle, tip, color, 1.5)
	return true
}

// A circle of `radius` about `at` in the plane square to `normal`, seen through
// `view_proj` with `count` points (at most RING_POINTS); false, drawing nothing, when part
// of it is behind the eye.
@(private = "file")
draw_lying_ring :: proc(o: Overlay, view_proj: matrix[4, 4]f32, size: [2]f32, at, normal: Vec3, radius: f32, color: ui.Color, width: f32, count: int) -> bool {
	// Two directions across the surface, square to its normal and to each other.
	u := linalg.normalize(linalg.cross(normal, Vec3{0, 1, 0} if abs(normal.y) < 0.9 else Vec3{1, 0, 0}))
	v := linalg.cross(normal, u)
	points: [RING_POINTS][2]f32
	n := clamp(count, 3, RING_POINTS)
	for &p, i in points[:n] {
		a := 2 * math.PI * f32(i) / f32(n)
		ok: bool
		p, ok = gizmo.project(view_proj, at + (u * math.cos(a) + v * math.sin(a)) * radius, size)
		if !ok do return false
	}
	overlay_polyline(o, points[:n], color, width, closed = true)
	return true
}

// How much of the brush ring's colour its symmetry copies keep, and those on a side of
// the model turned away from the viewer, which the model hides.
MIRROR_RING_FADE :: 0.6
MIRROR_RING_AWAY :: 0.45
// More copies than this (Radial's many) are drawn with fewer points each, so a 256-copy
// brush costs about what eight smooth rings do.
MIRROR_RINGS_SMOOTH :: 8

// The brush ring's symmetry copies (Brush_Cursor.images), each a dimmer ring with a dot
// at its middle, as ZBrush marks the mirrored brush: lying on the surface as the ring
// does, or flat on the screen `flat` across while the ring is.
@(private = "file")
draw_mirror_rings :: proc(app: ^App, o: Overlay, size: [2]f32, base: [4]f32, flat: f32) {
	c := &app.cursor
	if !c.ok || len(c.images) == 0 do return
	view_proj := camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
	points := RING_POINTS if len(c.images) <= MIRROR_RINGS_SMOOTH else 24
	for img in c.images {
		middle, ok := gizmo.project(view_proj, img.at, size)
		if !ok do continue
		fade: f32 = MIRROR_RING_FADE
		if linalg.dot(img.normal, camera.orbit_toward(app.camera, img.at)) > 0 do fade *= MIRROR_RING_AWAY
		color := overlay_color(base * {1, 1, 1, fade})
		if !app.kit.surface_ring || !draw_lying_ring(o, view_proj, size, img.at, img.normal, c.radius, color, 1, points) {
			overlay_circle(o, middle, flat, color, 1)
		}
		overlay_disc(o, middle, 3, color)
	}
}

// How far apart, in pixels, the symmetry line's drawn points are at the least: the cut
// through a dense mesh has points much closer than a pixel, which would only cost.
SYMMETRY_LINE_STEP_PX :: 2

// The symmetry line (Symmetry_Lines): where each mirror plane cuts the selected object,
// in the plane's axis colour, leaving out the parts on faces turned away from the viewer,
// which the model hides; with Radial, its axis across the object's box.
@(private = "file")
draw_symmetry_lines :: proc(app: ^App, o: Overlay, size: [2]f32) {
	if !app.kit.symmetry_line do return
	obj, l := symmetry_lines(app)
	if l == nil do return
	t := obj.transform
	view_proj := camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
	colors := GIZMO_AXIS_COLORS
	for axis in sculpt.Axis {
		sec := &l.cuts[axis]
		color := overlay_color(colors[int(axis)] * {1, 1, 1, 0.9})
		for line in sec.lines do draw_section_line(app, o, view_proj, size, t, sec.points[line.first:][:line.count], line.closed, color)
	}
	if b := app.brush; b.radial_on && l.box.lo.x <= l.box.hi.x {
		// The axis through the symmetry's centre, from one side of the box to the other.
		a := int(b.radial_axis)
		from, to := l.center, l.center
		from[a], to[a] = l.box.lo[a], l.box.hi[a]
		p, p_ok := gizmo.project(view_proj, to_world(t, from), size)
		q, q_ok := gizmo.project(view_proj, to_world(t, to), size)
		if p_ok && q_ok do overlay_line(o, p, q, overlay_color(colors[a] * {1, 1, 1, 0.9}), 1.5)
	}
}

// One polyline of a symmetry line, in runs over the faces turned toward the viewer.
@(private = "file")
draw_section_line :: proc(app: ^App, o: Overlay, view_proj: matrix[4, 4]f32, size: [2]f32, t: Transform, points: []sculpt.Section_Point, closed: bool, color: ui.Color) {
	run := make([dynamic][2]f32, 0, 64, context.temp_allocator)
	tail: [2]f32
	tail_kept := true
	flush :: proc(o: Overlay, run: ^[dynamic][2]f32, tail: [2]f32, tail_kept: bool, color: ui.Color) {
		if !tail_kept do append(run, tail)
		if len(run) >= 2 do overlay_polyline(o, run[:], color, 1.5)
		clear(run)
	}
	n := len(points)
	segments := n if closed else n - 1
	prev, prev_ok := gizmo.project(view_proj, to_world(t, points[0].at), size)
	for i in 0 ..< segments {
		j := (i + 1) % n
		w := to_world(t, points[j].at)
		next, next_ok := gizmo.project(view_proj, w, size)
		facing := linalg.dot(to_world_dir(t, points[i].normal), camera.orbit_toward(app.camera, w)) < 0
		if !(facing && prev_ok && next_ok) {
			flush(o, &run, tail, tail_kept, color)
			tail_kept = true
		} else {
			if len(run) == 0 do append(&run, prev)
			if linalg.length(next - run[len(run) - 1]) >= SYMMETRY_LINE_STEP_PX {
				append(&run, next)
				tail_kept = true
			} else {
				tail, tail_kept = next, false
			}
		}
		prev, prev_ok = next, next_ok
	}
	flush(o, &run, tail, tail_kept, color)
}

// How wide, in points, a label centred `r` points out at angle `mid` can be before it
// meets its neighbours `step` either side, for labels `height` tall: a neighbour far
// enough above or below leaves the width free, one beside it the gap between the two.
pie_label_room :: proc(r, mid, step, height: f32) -> f32 {
	ROOM_MAX :: 120
	room: f32 = ROOM_MAX
	here := r * angle_dir(mid)
	for side in ([2]f32{-1, 1}) {
		d := r * angle_dir(mid + side * step) - here
		if abs(d.y) < height do room = min(room, abs(d.x) - 4)
	}
	return max(room, 0)
}

// Draws the open pie over everything, so it shows whole even near the viewport's edge.
// Each slice shows its command's icon over its label, a band on one that is on now (the
// brush in use), dimmed when it cannot run, and "Empty" for an empty slot.
draw_pie :: proc(app: ^App, o: Overlay) {
	p := app.ui.pie
	if !p.open do return
	ctx := o.ctx
	t := ctx.theme
	n := pie_slot_count(app, p.which)
	// The brush pie is drawn as round 2's: the slice pointed at stands out, and the middle
	// names it; a user pie keeps the plain ring.
	lens := p.which == 0
	step := 2 * math.PI / f32(n)
	GAP :: 0.02 // radians between slices
	ARC :: 12 // segments along each edge of a slice
	// The pie is sized in points (pie.odin); the overlay takes window coordinates.
	pt := o.scale
	middle := at(o, p.center)
	for i in 0 ..< n {
		mark := ui.vertex_mark(ctx)
		defer pie_unfold(app, mark, middle, i)
		mid := -math.PI / 2 + f32(i) * step
		a0, a1 := mid - step / 2 + GAP, mid + step / 2 - GAP
		usable := pie_pickable(app, p.which, i)
		hover := i == p.hover && usable
		// The slice: along its outer edge, then back along its inner one. Its inner edge
		// dips so little across a slice that it fills as a convex shape.
		// Lens's slice pointed at stands out from the ring, tinted and outlined, so the
		// brush it names stays readable in the slice's own colours.
		outer: f32 = PIE_OUTER + 10 if hover && lens else PIE_OUTER
		outline: [2 * (ARC + 1)][2]f32
		for s in 0 ..= ARC {
			f := f32(s) / ARC
			outline[s] = p.center + outer * pt * angle_dir(a0 + (a1 - a0) * f)
			outline[ARC + 1 + s] = p.center + (PIE_INNER + 6) * pt * angle_dir(a1 - (a1 - a0) * f)
		}
		if lens && hover {
			overlay_fill(o, outline[:], ui.color_mix(t.surface, t.accent, 0.22))
			overlay_polyline(o, outline[:], t.accent, 1.5 * pt, closed = true)
		} else {
			overlay_fill(o, outline[:], t.accent if hover else t.surface)
		}
		on: bool
		slot: Pie_Slot
		if lens {
			slot = pie_slot(app, 0, i)
			on = slot.id != .None && command_checked(app, slot.id, slot.arg)
		} else {
			slot = app.kit.pies[p.which - 1][i]
			on = slot.id != .None && command_checked(app, slot.id, slot.arg)
		}
		if on {
			// The brush in use, or a command that is on: a band along the slice's outside.
			band: [ARC + 1][2]f32
			for s in 0 ..= ARC do band[s] = p.center + (PIE_OUTER - 3) * pt * angle_dir(a0 + (a1 - a0) * f32(s) / ARC)
			overlay_polyline(o, band[:], t.on_accent if hover && !lens else t.accent, 4 * pt)
		}
		// Past the ring's middle, where neighbouring slices are furthest apart.
		r: f32 = PIE_INNER + 0.62 * (PIE_OUTER - PIE_INNER)
		label := at(o, p.center + r * pt * angle_dir(mid))
		font := ui.Font.Semibold if hover else ui.Font.Regular
		color := (t.accent if lens else t.on_accent) if hover else t.text
		if !usable do color = ui.color_fade(t.text_secondary, 0.5)
		// Eight slices leave each label about a slice's chord across, and a little more: a
		// label lies flat while the slice turns, so the side slices have more room than that.
		room := 2 * r * math.sin(step / 2) + 16
		glyph := ui.ICON_PLUS if slot.id == .None else (COMMANDS[slot.id].icon if COMMANDS[slot.id].icon != 0 else ui.ICON_WAND)
		name := pie_slot_label(slot)
		if lens && slot.id != .None do glyph, name = bar_icon(app, slot), shelf_label(app, slot)
		ui.icon(ctx, glyph, {label.x, label.y - 12}, t.icon_small, color)
		ui.text(ctx, ui.text_fit(ctx, name, t.small_size, room), label.x, label.y + 10, t.small_size, color, font, .Center)
	}
	// The middle, and which way the pointer points from it. A user pie's middle names it.
	mark := ui.vertex_mark(ctx)
	defer pie_unfold(app, mark, middle, -1)
	overlay_disc(o, p.center, PIE_INNER * pt, t.surface)
	overlay_circle(o, p.center, PIE_INNER * pt, t.border_strong, 1.5 * pt)
	if p.which > 0 {
		c := at(o, p.center)
		ui.text(ctx, fmt.tprint(p.which), c.x, c.y, t.text_size, t.text_secondary, .Semibold, .Center)
	} else if lens && p.hover >= 0 {
		// Lens's middle names the brush pointed at, and how it is picked.
		c := at(o, p.center)
		slot := pie_slot(app, 0, p.hover)
		if slot.id != .None {
			ui.text(ctx, ui.text_fit(ctx, shelf_label(app, slot), t.small_size, PIE_INNER * 2 - 8, .Semibold), c.x, c.y - 7, t.small_size, t.accent, .Semibold, .Center)
			ui.text(ctx, "lift to pick" if p.hold || p.pressed_on > 0 else "tap to pick", c.x, c.y + 8, t.small_size - 1, t.text_tertiary, .Regular, .Center)
		}
	}
	if p.hover >= 0 {
		d := linalg.normalize0(app.ui.viewport_mouse - p.center)
		if !lens {
			overlay_disc(o, p.center + (PIE_INNER - 6) * pt * d, 4 * pt, t.accent)
		} else {
			// Lens draws the flick itself, dotted from the middle's edge to the pointer, so a
			// short flick shows which way it went.
			from := p.center + PIE_INNER * pt * d
			length := min(linalg.length(app.ui.viewport_mouse - from), (PIE_OUTER - PIE_INNER) * pt)
			DOT :: 6
			for f: f32 = 0; f < length && linalg.dot(app.ui.viewport_mouse - p.center, d) > PIE_INNER * pt; f += DOT * pt {
				overlay_disc(o, from + f * d, 1.5 * pt, t.accent)
			}
		}
	}
}

// How long one slice takes to unfold, and how long after the one before it each begins,
// clockwise from the top, so the ring opens round the way the eye reads it.
PIE_UNFOLD_TIME :: 0.16
PIE_UNFOLD_STAGGER :: 0.012

// How far the open pie has unfolded, 0 to 1: its last slice's share, 1 when motion does
// not unfold it; 0 while it is closed. For the exit stats.
pie_unfolded :: proc(app: ^App) -> f32 {
	p := app.ui.pie
	if !p.open do return 0
	ctx := &app.kit.ctx
	run := ui.motion_duration(ctx, motion_class(.Pie), PIE_UNFOLD_TIME)
	if run <= 0 do return 1
	last := f64(pie_slot_count(app, p.which) - 1) * PIE_UNFOLD_STAGGER
	return clamp(f32(ctx.time - p.shown_at - last) / run, 0, 1)
}

// Unfolds what was drawn since `mark` for slice `i` (-1 for the middle, which comes first)
// as the pie opens: it grows from 60% about the middle with a slight overshoot and fades
// in, its slice a moment after the one before. Reduced fades it in place; Off or Pies and
// the dial off show it whole at once.
@(private = "file")
pie_unfold :: proc(app: ^App, mark: int, middle: [2]f32, i: int) {
	ctx := &app.kit.ctx
	run := ui.motion_duration(ctx, motion_class(.Pie), PIE_UNFOLD_TIME)
	if run <= 0 do return
	t := f32(ctx.time - app.ui.pie.shown_at - f64(max(i, 0)) * PIE_UNFOLD_STAGGER) / run
	if t >= 1 do return
	grow := ui.ease(.Out_Back, t)
	ui.transform_since(ctx, mark, ui.ease(.Out_Cubic, t), 0.6 + 0.4 * grow, middle)
}

// The unit vector `a` radians clockwise (y down) from the right.
@(private = "file")
angle_dir :: proc(a: f32) -> [2]f32 {
	return {math.cos(a), math.sin(a)}
}
