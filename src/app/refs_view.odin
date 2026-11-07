package main

import "core:fmt"
import "core:math"
import "core:slice"

import "../ui"

// Reference pictures over the view (Ref.view), as ZBrush's Spotlight in Reference mode and
// Nomad's overlay: pinned over the main view at their opacity, drawn by the interface
// before every panel, so they lie under the bars and cards and the sculpt passes and the
// idle cache never see them. While the References card is open each takes a finger or the
// mouse: a drag moves it, its corner sizes it, a tap picks it on the board. Two fingers
// landing on one, the card open or shut, pinch it to size, twist it to any angle and carry
// it (refs_touch_gesture), unless it is locked on the view; elsewhere they turn the view
// as ever. The pen always sculpts through them, and with the card shut so do one finger
// and the mouse; the one under the pointer then fades to REF_VIEW_FADE of its opacity so
// the brush never works blind. The Eyedropper picks their colour as it picks the model's.
// One may stand behind the model instead (the picture menu's Behind the model): the
// renderer draws it as a backdrop the model covers (refs_planes_frame), in front of the
// background and the environment, and the interface only takes the pointer on it and
// outlines it; it never fades, as nothing of it covers the model, and where the model
// stands over it the Eyedropper and two fingers find the model.

// What a place under the pointer fades to, and how fast, per second, it goes there and back.
REF_VIEW_FADE :: 0.15
REF_VIEW_FADE_RATE :: 12

// Where place `p` stands over the main view `main`, in points.
refs_view_rect :: proc(main: ui.Rect, p: Ref) -> ui.Rect {
	w := p.view_w * main.w
	h := w * p.size.y / max(p.size.x, 1e-6)
	return {main.x + p.view_at.x * main.w, main.y + p.view_at.y * main.h, w, h}
}

// The corners of rect `r` turned `angle` radians clockwise on screen (y down) about its
// middle: its top left, top right, bottom right and bottom left.
refs_turned :: proc(r: ui.Rect, angle: f32) -> [4][2]f32 {
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	h := [2]f32{r.w * 0.5, r.h * 0.5}
	out: [4][2]f32
	for o, i in ([4][2]f32{{-h.x, -h.y}, {h.x, -h.y}, {h.x, h.y}, {-h.x, h.y}}) do out[i] = c + refs_rotate(o, angle)
	return out
}

// Vector `v` turned `angle` radians clockwise on screen.
refs_rotate :: proc(v: [2]f32, angle: f32) -> [2]f32 {
	if angle == 0 do return v
	c, s := math.cos(angle), math.sin(angle)
	return {v.x * c - v.y * s, v.x * s + v.y * c}
}

// Point `p` where it was before rect `r` was turned `angle` about its middle: the point of
// the upright rect that the turned one shows at `p`.
refs_unturn :: proc(r: ui.Rect, angle: f32, p: [2]f32) -> [2]f32 {
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	return c + refs_rotate(p - c, -angle)
}

// The upright box round rect `r` turned `angle` about its middle.
refs_turned_bounds :: proc(r: ui.Rect, angle: f32) -> ui.Rect {
	if angle == 0 do return r
	c := refs_turned(r, angle)
	lo, hi := c[0], c[0]
	for q in c[1:] do lo, hi = {min(lo.x, q.x), min(lo.y, q.y)}, {max(hi.x, q.x), max(hi.y, q.y)}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// An angle brought into the half turn either way of 0.
refs_wrap :: proc(a: f32) -> f32 {
	return a - 2 * math.PI * math.floor((a + math.PI) / (2 * math.PI))
}

// The middle `c` of something scaled by `s`, turned by `twist` and carried by `pan` about
// point `m`, as two fingers do with what lies under them.
refs_turn_about :: proc(c, m: [2]f32, s, twist: f32, pan: [2]f32) -> [2]f32 {
	return m + refs_rotate((c - m) * s, twist) + pan
}

// Keeps place `p` from going wholly off the view `main`, so it can always be taken again.
@(private = "file")
refs_view_keep :: proc(main: ui.Rect, p: ^Ref) {
	r := refs_view_rect(main, p^)
	p.view_at.x = clamp(p.view_at.x, (REF_MIN_SIDE - r.w) / main.w, 1 - REF_MIN_SIDE / main.w)
	p.view_at.y = clamp(p.view_at.y, (REF_MIN_SIDE - r.h) / main.h, 1 - REF_MIN_SIDE / main.h)
}

// Draws the places over the view and, while the References card is open, takes a finger
// or the mouse on them (never the pen, which sculpts through them). Called before every
// panel is laid out, so each panel is above them.
refs_view :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	refs := &app.scene.refs
	main := k.grid.main
	// The planes in the scene first, so the places over the view stand above them.
	refs_planes_view(app)
	if refs.view_off || main.w <= 0 || main.h <= 0 do return
	editing := card_shown(app, .References)
	// The pen sculpts through the pictures even while the card is open: only a finger or
	// the mouse takes one (their containers let the pen through, ui.Box.pen_through).
	takes := editing
	step := clamp(ctx.input.dt, 0, 0.1) * REF_VIEW_FADE_RATE
	for &p in refs.refs {
		if !p.view || p.image == 0 do continue
		r := refs_view_rect(main, p)
		if takes {
			box := refs_turned_bounds(r, p.view_angle)
			ui.begin_at(ctx, fmt.tprintf("ref view %d", p.id), {box.x, box.y}, {width = box.w, height = box.h, pen_through = true})
			a := ui.area(ctx, "ref", {box.w, box.h})
			ui.end(ctx)
			refs_view_input(app, &p, a)
			r = refs_view_rect(main, p)
		}
		// Behind the model the renderer draws it, the interface only while it loads.
		if p.view_behind {
			img := ref_image(refs, p.image)
			if img == nil || img.texture == 0 do refs_picture_draw(app, r, p, u8(clamp(p.opacity, 0, 1) * 255 + 0.5), p.view_angle)
		} else {
			refs_view_picture(app, r, p, editing, step)
		}
		if editing && board_picked(b, p.id) {
			corners := refs_turned(r, p.view_angle)
			ui.polyline(ctx, corners[:], t.accent, 2, closed = true)
			if !p.view_locked do ui.fill_circle(ctx, corners[2], board_corner(ctx) * 0.4, t.accent)
		}
	}
	// Each picked picture's lock at its top right corner (a locked one's always), over
	// every picture, so another never covers it: a locked picture stays where it is on the
	// view, and two fingers on it turn the view instead.
	if takes {
		for &p in refs.refs {
			if !p.view || p.image == 0 || !(p.view_locked || board_picked(b, p.id)) do continue
			corner := refs_turned(refs_view_rect(main, p), p.view_angle)[1]
			ui.begin_at(ctx, fmt.tprintf("ref view lock %d", p.id), corner - REFS_HEAD_BUTTON * 0.5, {radius = t.radius_large, background = .Raised, pen_through = true})
			if ui.icon_button(ctx, "Lock on view##refs view", ui.ICON_LOCK if p.view_locked else ui.ICON_LOCK_OPEN, selected = p.view_locked, size = REFS_HEAD_BUTTON) {
				before := refs_clone(refs.refs[:])
				p.view_locked = !p.view_locked
				history_record_refs(app, before, "Lock reference on view" if p.view_locked else "Unlock reference on view")
			}
			ui.end(ctx)
		}
	}
	// Two fingers lifted from a picture end its gesture as one undo step.
	if app.touch.fingers.count == 0 do refs_gesture_end(app)
	// A place pressed over the view comes to the top, after the loop that drew it.
	if b.view_raise != 0 {
		_ = refs_bring_front(&refs.refs, b.selected[:], b.view_raise)
		b.view_raise = 0
	}
}

// Draws place `p` over the view at `r`, faded while the pointer is over it with the card
// shut, so the brush never works blind.
@(private = "file")
refs_view_picture :: proc(app: ^App, r: ui.Rect, p: Ref, editing: bool, step: f32) {
	ctx := &app.kit.ctx
	b := &app.kit.board
	fade := b.fades[p.id] or_else 1
	under := !editing && ctx.input.mouse_valid && ui.rect_contains(r, refs_unturn(r, p.view_angle, ctx.input.mouse))
	goal: f32 = REF_VIEW_FADE if under else 1
	fade += (goal - fade) * min(step, 1)
	b.fades[p.id] = fade
	alpha := u8(clamp(p.opacity * fade, 0, 1) * 255 + 0.5)
	refs_picture_draw(app, r, p, alpha, p.view_angle)
}

// The pointer on place `p` over the view, through its area `a`: a press picks it on the
// board (Shift adds it) or, while the Eyedropper waits, picks its colour; a drag moves it,
// from its corner sizes it, both one undo step when it lets go; a locked one only picks.
@(private = "file")
refs_view_input :: proc(app: ^App, p: ^Ref, a: ui.Area) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	main := k.grid.main
	if a.pressed {
		r := refs_view_rect(main, p^)
		corners := refs_turned(r, p.view_angle)
		d := a.mouse - corners[2]
		corner := !p.view_locked && d.x * d.x + d.y * d.y <= board_corner(ctx) * board_corner(ctx)
		// The area is the turned picture's upright box: a press in its corners beside the
		// picture is taken but does nothing.
		if !corner && !ui.rect_contains(r, refs_unturn(r, p.view_angle, a.mouse)) do return
		if app.ui.eyedrop_armed {
			app.ui.eyedrop_armed = false
			refs_pick_color(app, p^, r, a.mouse, p.view_angle)
			return
		}
		if ctx.input.shift {
			if !board_picked(b, p.id) do append(&b.selected, p.id)
		} else if !board_picked(b, p.id) {
			clear(&b.selected)
			append(&b.selected, p.id)
		}
		b.view_drag = .None if p.view_locked else (.Size if corner else .Move)
		b.view_id, b.view_last = p.id, a.mouse
		if b.view_drag != .None {
			delete(b.before)
			b.before = refs_clone(app.scene.refs.refs[:])
			// It comes to the top once the loop over the places is done (refs_view), and the
			// drag's undo step holds the raise too.
			b.view_raise = p.id
		}
	}
	if b.view_id != p.id do return
	if a.held && a.mouse != b.view_last {
		d := a.mouse - b.view_last
		b.moved = true
		#partial switch b.view_drag {
		case .Move:
			p.view_at += d / [2]f32{main.w, main.h}
		case .Size:
			// The corner follows the pointer along the picture's turned width, keeping its
			// shape; never smaller than a finger.
			least := REF_MIN_SIDE * 2 / main.w
			p.view_w = clamp(p.view_w + refs_rotate(d, -p.view_angle).x / main.w, least, 4)
		}
		refs_view_keep(main, p)
		b.view_last = a.mouse
	}
	if !a.held && b.view_drag != .None {
		if b.before != nil {
			if !slice.equal(b.before, app.scene.refs.refs[:]) {
				if !b.moved {
					history_record_refs(app, b.before, "Bring reference to front")
				} else {
					history_record_refs(app, b.before, "Move reference on view" if b.view_drag == .Move else "Size reference on view")
					b.moves += 1
				}
			} else do delete(b.before)
			b.before = nil
		}
		b.view_drag = .None
		b.view_id = 0
		b.moved = false
	}
}

// Picks the colour of place `p`, drawn at `r`, under screen point `at` into the Colours
// card, as the Eyedropper does on the model.
refs_pick_color :: proc(app: ^App, p: Ref, r: ui.Rect, at: [2]f32, angle: f32 = 0) {
	rgb, ok := refs_color_at(app, p, r, at, angle)
	if !ok {
		report(app, Section.Paint_Color, {.Warning}, "Eyedropper: the picture is still loading")
		return
	}
	colors_pick(app, rgb)
	report(app, Section.Paint_Color, {.Quiet}, "Picked %s", hex_text(rgb))
}

// The colour of place `p`, drawn at `r` turned `angle`, at screen point `at`, from its
// picture's small copy; false while there is none yet.
refs_color_at :: proc(app: ^App, p: Ref, r: ui.Rect, at: [2]f32, angle: f32 = 0) -> (rgb: [3]f32, ok: bool) {
	img := ref_image(&app.scene.refs, p.image)
	if img == nil || img.sample == nil do return
	q := refs_unturn(r, angle, at)
	f := [2]f32{clamp((q.x - r.x) / max(r.w, 1e-6), 0, 1), clamp((q.y - r.y) / max(r.h, 1e-6), 0, 1)}
	c := ref_corners(p)
	top := c[0] + (c[1] - c[0]) * f.x
	bottom := c[3] + (c[2] - c[3]) * f.x
	uv := top + (bottom - top) * f.y
	x := clamp(int(uv.x * f32(img.sample_size.x)), 0, img.sample_size.x - 1)
	y := clamp(int(uv.y * f32(img.sample_size.y)), 0, img.sample_size.y - 1)
	px := img.sample[(y * img.sample_size.x + x) * 4:]
	rgb = {f32(px[0]) / 255, f32(px[1]) / 255, f32(px[2]) / 255}
	if p.grey {
		y := 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
		rgb = y
	}
	return rgb, true
}

// The colour of the topmost place over the view at viewport point `at` (pixels from the
// viewport's top left), for the Eyedropper: what the person sees there is the picture.
refs_view_color :: proc(app: ^App, at: [2]f32) -> (rgb: [3]f32, over, ok: bool) {
	k := &app.kit
	refs := &app.scene.refs
	if refs.view_off || k.scale <= 0 do return
	point := (app.ui.viewport_origin + at) / k.scale
	// Those in front first, whatever the order: the interface draws them over every one behind.
	for pass in 0 ..< 2 do for i := len(refs.refs) - 1; i >= 0; i -= 1 {
		p := refs.refs[i]
		if !p.view || p.image == 0 || p.view_behind != (pass == 1) do continue
		r := refs_view_rect(k.grid.main, p)
		if !ui.rect_contains(r, refs_unturn(r, p.view_angle, point)) do continue
		if p.view_behind && refs_model_at(app, point) do continue
		rgb, ok = refs_color_at(app, p, r, point, p.view_angle)
		return rgb, true, ok
	}
	return
}

// The place over the view whose picture shows at point `at` (in points), topmost first,
// or 0 when none does or the topmost there is locked on the view.
refs_view_hit :: proc(app: ^App, at: [2]f32) -> u32 {
	refs := &app.scene.refs
	if refs.view_off do return 0
	main := app.kit.grid.main
	// Those in front first, whatever the order: the interface draws them over every one behind.
	for pass in 0 ..< 2 do for i := len(refs.refs) - 1; i >= 0; i -= 1 {
		p := refs.refs[i]
		if !p.view || p.image == 0 || p.view_behind != (pass == 1) do continue
		r := refs_view_rect(main, p)
		if !ui.rect_contains(r, refs_unturn(r, p.view_angle, at)) do continue
		if p.view_behind && refs_model_at(app, at) do continue
		return 0 if p.view_locked else p.id
	}
	return 0
}

// Whether the model shows at point `at` (in points) of the main view, covering a picture
// behind it there.
@(private = "file")
refs_model_at :: proc(app: ^App, at: [2]f32) -> bool {
	// The ray is cast in the window's coordinates, as the viewport's input is.
	main := app.kit.grid.main
	size := [2]f32{main.w, main.h} * app.kit.scale
	if size.x <= 0 || size.y <= 0 do return false
	origin, dir := mouse_ray(app.camera, at * app.kit.scale - app.ui.viewport_origin, size)
	_, _, hit := scene_raycast(app, origin, dir)
	return hit
}

// Two fingers on an unlocked picture over the view pinch it to size, twist it to any
// angle and carry it with their middle, all about that middle, as one undo step once the
// last lifts; the camera never sees them. They are the picture's when the touch is the
// view's and either finger landed on it, or when a finger had taken it as a drag while
// the References card is open and a second joined. Decided once a touch; called by
// touch_route each frame with the fingers' change, true while they are the picture's.
refs_touch_gesture :: proc(app: ^App, change: ui.Finger_Change) -> bool {
	t := &app.touch
	f := &t.fingers
	k := &app.kit
	b := &k.board
	refs := &app.scene.refs
	if f.count == 0 {
		refs_gesture_end(app)
		return false
	}
	scale := max(k.scale, 1e-3)
	if b.gesture_id == 0 {
		if b.gesture_tried || f.count < 2 do return false
		b.gesture_tried = true
		id: u32
		if t.owner == .Interface && b.view_id != 0 && b.view_drag != .None {
			// The drag's undo step becomes the gesture's, holding where the drag began.
			id = b.view_id
			delete(b.gesture_before)
			b.gesture_before, b.before = b.before, nil
			b.view_drag, b.view_id, b.moved = .None, 0, false
		} else if t.owner == .Viewport && t.gesture {
			id = refs_view_hit(app, f.down[0].start / scale)
			if id == 0 do id = refs_view_hit(app, f.down[1].start / scale)
			if id != 0 {
				delete(b.gesture_before)
				b.gesture_before = refs_clone(refs.refs[:])
			}
		}
		if id == 0 do return false
		b.gesture_id = id
	}
	i := ref_index(refs, b.gesture_id)
	// Lifting one of the fingers ends what they do, as for the camera; the touch stays the picture's.
	if i < 0 || f.count < 2 || f.count != f.most do return true
	main := k.grid.main
	p := &refs.refs[i]
	r := refs_view_rect(main, p^)
	least := REF_MIN_SIDE * 2 / main.w
	w := clamp(p.view_w * change.zoom, least, 4)
	s := w / p.view_w
	c := refs_turn_about({r.x + r.w * 0.5, r.y + r.h * 0.5}, change.middle / scale, s, change.twist, change.pan / scale)
	p.view_w = w
	p.view_angle = refs_wrap(p.view_angle + change.twist)
	r = refs_view_rect(main, p^)
	p.view_at = {(c.x - r.w * 0.5 - main.x) / main.w, (c.y - r.h * 0.5 - main.y) / main.h}
	refs_view_keep(main, p)
	app.scene_edits += 1
	return true
}

// Ends two fingers' gesture on a picture over the view: one undo step when it changed it.
refs_gesture_end :: proc(app: ^App) {
	b := &app.kit.board
	b.gesture_tried = false
	if b.gesture_before != nil {
		if !slice.equal(b.gesture_before, app.scene.refs.refs[:]) {
			history_record_refs(app, b.gesture_before, "Turn and size reference on view")
			b.turns += 1
		} else do delete(b.gesture_before)
		b.gesture_before = nil
	}
	b.gesture_id = 0
}

// The Show refs command: hides or shows every place over the view and in the scene at once.
refs_view_toggle :: proc(app: ^App) {
	app.scene.refs.view_off = !app.scene.refs.view_off
	app.scene_edits += 1
}

