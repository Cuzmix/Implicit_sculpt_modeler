package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../camera"
import "../gizmo"
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

// Draws the brush circle, the move gizmo or the gesture being dragged over the viewport,
// under the panels in the layer kit_frame kept over the viewport image, then the brush
// pie over everything. Runs after the tools have handled this frame's input, so the
// overlay matches what gets rendered.
draw_viewport_overlay :: proc(app: ^App, input: Viewport_Input) {
	k := &app.kit
	ctx := &k.ctx
	o := Overlay{ctx, k.scale, app.ui.viewport_origin}
	if layer, ok := k.layer.?; ok {
		k.layer = nil
		from := ui.layer_begin(ctx)
		overlay_viewport(app, o, input)
		ui.layer_end(ctx, layer, from)
	}
	draw_pie(app, o)
}

@(private = "file")
overlay_viewport :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	// Where the safe zone ends, faintly, so it is clear where a press turns the view.
	if app.nav.edge_orbit && app.nav.edge_show && !app.kit.clean {
		lo, hi := edge_inner(app)
		overlay_box(o, lo, hi, overlay_color({1, 1, 1, 0.16}), {}, 1)
	}
	draw_pivot(app, o, input.size)
	draw_hold_history(app, o)
	draw_light_markers(app, o, input.size)
	draw_focus_marker(app, o, input.size)
	// While the eyedropper's loupe shows, the brush ring under it would only hide the
	// colour being picked.
	if app.ui.eyedrop_held {
		draw_eyedropper(app, o)
		return
	}
	switch app.tool {
	case .Brush:
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
		if st := app.stroke; st.active && st.rect {
			// The stamp being dragged out: its circle around where it began, and a line to
			// the pointer, the way its top faces.
			color := overlay_color({1, 0.8, 0.4, 0.9})
			overlay_circle(o, st.start, max(linalg.length(input.mouse_pos - st.start), 2), color, 1.5)
			overlay_line(o, st.start, input.mouse_pos, color, 1.5)
			break
		}
		if (input.hovered || input.dragging) && !app.ui.pie.open {
			color := overlay_color(brush_ring_color(app, input.primary))
			center := input.mouse_pos
			if app.stroke.active && app.brush.lazy_px > 0 {
				// The brush trails the cursor: draw it where it is, on its string.
				center = app.stroke.pos
				overlay_line(o, center, input.mouse_pos, color, 1)
			}
			if brush_alpha(app) != nil && held_brush(input) {
				draw_alpha_outline(app, o, center, color)
			} else {
				if !draw_surface_ring(app, o, input.size, color) do overlay_circle(o, center, app.brush.radius_px, color, 1.5)
				// A focal shift moves where the brush works: an inner ring where it falls to
				// half strength, as the reference app's cursor shows it.
				if half := brush_half_radius(app); half > 0 {
					inner := overlay_color(brush_ring_color(app, input.primary) * {1, 1, 1, 0.55})
					if !draw_surface_ring(app, o, input.size, inner, half) do overlay_circle(o, center, app.brush.radius_px * half, inner, 1)
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
		// The far half of each axis ring dims, so which way it turns reads.
		for i in 0 ..< 4 {
			if !sc.ring_ok[i] do continue
			h := gizmo.Handle(int(gizmo.Handle.Turn_X) + i)
			c := colors[i] if i < 3 else [4]f32{1, 1, 1, 0.8}
			width := (3 if h == active else 2) * px
			for k in 0 ..< gizmo.RING_POINTS {
				next := (k + 1) % gizmo.RING_POINTS
				shade := c
				if !sc.ring_front[i][k] || !sc.ring_front[i][next] do shade.a *= 0.3
				overlay_line(o, sc.rings[i][k], sc.rings[i][next], color_of(h, active, shade), width)
			}
		}
		if d := m.drag; d.live && drag_mode(d.handle) == .Turn {
			// From the middle to the pointer: the angle the drag is turning through.
			overlay_line(o, sc.center, input.mouse_pos, overlay_color(GIZMO_HIGHLIGHT), 1.5 * px)
		}
		overlay_disc(o, sc.center, 3 * px, overlay_color({1, 1, 1, 0.85}))
	case .Scale:
		color := color_of(.Scale, active, {1, 1, 1, 0.85})
		overlay_circle(o, sc.center, sc.arm_px, color, 2 * px)
		overlay_disc(o, sc.center, gizmo.SCALE_DISC_PX * px, overlay_color(GIZMO_HIGHLIGHT if active == .Scale else {1, 1, 1, 0.5}))
		if d := m.drag; d.live && d.handle == .Scale {
			overlay_circle(o, sc.center, linalg.length(input.mouse_pos - d.center), overlay_color({1, 0.85, 0.3, 0.6}), 1.5 * px)
		}
	}
	draw_move_labels(app, o, input)
}

// The move handles of a gizmo seen as `sc`, `active` lit: the plane squares first,
// under the arms, each in the colour of the axis it holds still, then an arm along each
// axis. The middle is the caller's: the Move tool's square, a light's marker.
draw_move_handles :: proc(o: Overlay, sc: gizmo.Screen, active: gizmo.Handle, px: f32) {
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
	for i in 0 ..< 3 {
		if !gizmo.arm_shows(sc, i) do continue
		color := color_of(gizmo.Handle(int(gizmo.Handle.X) + i), active, colors[i])
		overlay_line(o, sc.center, sc.tips[i], color, 3 * px)
		overlay_disc(o, sc.tips[i], 5 * px, color)
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
	if !c.ok do return false
	view_proj := camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
	// Two directions across the surface, square to its normal and to each other.
	u := linalg.normalize(linalg.cross(c.normal, Vec3{0, 1, 0} if abs(c.normal.y) < 0.9 else Vec3{1, 0, 0}))
	v := linalg.cross(c.normal, u)
	points: [RING_POINTS][2]f32
	for &p, i in points {
		a := 2 * math.PI * f32(i) / RING_POINTS
		ok: bool
		p, ok = gizmo.project(view_proj, c.at + (u * math.cos(a) + v * math.sin(a)) * (c.radius * scale), size)
		if !ok do return false
	}
	overlay_polyline(o, points[:], color, 1.5 if scale == 1 else 1, closed = true)
	if scale != 1 do return true
	middle, middle_ok := gizmo.project(view_proj, c.at, size)
	tip, tip_ok := gizmo.project(view_proj, c.at + c.normal * (c.radius * 0.5), size)
	if middle_ok && tip_ok do overlay_line(o, middle, tip, color, 1.5)
	return true
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
	for i in 0 ..< n {
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
		if lens && slot.id != .None do glyph, name = bar_icon(slot), shelf_label(slot)
		ui.icon(ctx, glyph, {label.x, label.y - 12}, t.icon_small, color)
		ui.text(ctx, ui.text_fit(ctx, name, t.small_size, room), label.x, label.y + 10, t.small_size, color, font, .Center)
	}
	// The middle, and which way the pointer points from it. A user pie's middle names it.
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
			ui.text(ctx, ui.text_fit(ctx, shelf_label(slot), t.small_size, PIE_INNER * 2 - 8, .Semibold), c.x, c.y - 7, t.small_size, t.accent, .Semibold, .Center)
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

// The unit vector `a` radians clockwise (y down) from the right.
@(private = "file")
angle_dir :: proc(a: f32) -> [2]f32 {
	return {math.cos(a), math.sin(a)}
}
