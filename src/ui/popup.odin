package ui

import "core:math"

// What floats over the panels: tooltips, toasts and popovers. Each fades and grows in
// from where it belongs and leaves the same way, and none takes the pointer while it is
// leaving, so a quick click after closing one lands on what is under it.

// Gives the widget `id` at `r` a tooltip. After the pointer rests on it for the theme's
// delay (or at once if another tooltip showed a moment ago) `text` shows beside it.
tip :: proc(ctx: ^Context, id: Id, r: Rect, text: string, keys := "") {
	// A press on the control hides its tooltip until the pointer leaves it, and none
	// shows while a popover is open: it would cover what the press opened.
	if ctx.hot == id && ctx.input.pressed != {} do ctx.tip_pressed = id
	if ctx.hot != id && ctx.tip_pressed == id do ctx.tip_pressed = 0
	if text == "" || ctx.hot != id || ctx.input.down != {} || ctx.tip_pressed == id do return
	open_popup := ctx.popup_open if ctx.popup_open != 0 else ctx.popup_open_prev
	if n := len(ctx.stack); open_popup != 0 && (n == 0 || ctx.stack[n - 1].root != open_popup) do return
	if ctx.tip_id != id {
		ctx.tip_id = id
		ctx.tip_since = ctx.time
		// Moving from one control to the next while tooltips are showing keeps showing
		// them, as a menu bar does.
		if ctx.time - ctx.tip_last < 0.4 do ctx.tip_since = ctx.time - f64(ctx.theme.tooltip_delay)
	}
	ctx.tip_len = copy_text(ctx.tip_text[:], text)
	ctx.tip_keys_len = copy_text(ctx.tip_keys[:], keys)
	ctx.tip_rect = r
}

@(private)
tooltip_draw :: proc(ctx: ^Context) {
	t := ctx.theme
	id := ctx.tip_id
	if id == 0 do return
	// The widget is no longer under the pointer (or was pressed): forget it.
	if ctx.hot != id || ctx.input.down != {} || ctx.tip_len == 0 {
		ctx.tip_id = 0
		ctx.tip_len = 0
		return
	}
	waited := ctx.time - ctx.tip_since >= f64(t.tooltip_delay)
	shown := presence(ctx, salt(id, 7), waited, t.tooltip_time)
	if shown <= 0 {
		ctx.tip_len = 0
		return
	}
	ctx.tip_last = ctx.time
	tip_text := string(ctx.tip_text[:ctx.tip_len])
	tip_keys := string(ctx.tip_keys[:ctx.tip_keys_len])
	text_w := text_width(ctx, tip_text, t.small_size)
	keys_w := text_width(ctx, tip_keys, t.small_size) + 12 if tip_keys != "" else 0
	w := text_w + keys_w + 20
	h: f32 = 28
	r := ctx.tip_rect
	window := ctx.input.window
	// Below the control when there is room, else above; never off the window.
	below := r.y + r.h + 6 + h <= window.y - 4
	x := clamp(r.x + r.w * 0.5 - w * 0.5, 4, window.x - w - 4)
	y := r.y + r.h + 6 if below else r.y - 6 - h
	mark := vertex_mark(ctx)
	draw_set_state(&ctx.draw, .Atlas, 0, full_clip(ctx))
	box := Rect{x, y, w, h}
	shadow_rect(ctx, box, t.radius_small, color_fade(t.shadow, 0.6))
	fill_rect(ctx, box, t.radius_small, t.surface_raised)
	stroke_rect(ctx, box, t.radius_small, t.border_strong, 1)
	text(ctx, tip_text, x + 10, y + h * 0.5, t.small_size, t.text)
	if tip_keys != "" do text(ctx, tip_keys, x + w - 10, y + h * 0.5, t.small_size, t.text_tertiary, .Regular, .Right)
	// It drifts 4 points out from the control as it fades in.
	drift: f32 = (1 - shown) * 4
	transform_since(ctx, mark, shown, 1, {}, {0, -drift if below else drift})
	ctx.tip_len = 0
}

// Shows `message` at the bottom of the window for a few seconds. The text is copied
// (up to 120 bytes), so it may be a temp string.
toast :: proc(ctx: ^Context, message: string, kind := Toast_Kind.Info) {
	if ctx.toast_count == TOASTS {
		// The oldest goes to make room.
		copy(ctx.toasts[:], ctx.toasts[1:])
		ctx.toast_count -= 1
	}
	ctx.toast_serial += 1
	to := &ctx.toasts[ctx.toast_count]
	to^ = {kind = kind, born = ctx.time, life = 5 if kind == .Warning || kind == .Error else 3.2, id = salt(0x70a57, u64(ctx.toast_serial))}
	to.len = copy(to.text[:], message)
	ctx.toast_count += 1
}

@(private)
toasts_draw :: proc(ctx: ^Context) {
	t := ctx.theme
	// Drop those that have finished leaving.
	leave := t.toast_time
	n := 0
	for i in 0 ..< ctx.toast_count {
		to := ctx.toasts[i]
		if ctx.time - to.born < f64(to.life + leave) {
			ctx.toasts[n] = to
			n += 1
		}
	}
	ctx.toast_count = n
	if n == 0 do return
	window := ctx.input.window
	y := window.y - ctx.toast_bottom
	draw_set_state(&ctx.draw, .Atlas, 0, full_clip(ctx))
	// Newest at the bottom, the others stacked above it; each slides as the stack moves.
	#reverse for &to, i in ctx.toasts[:n] {
		msg := string(to.text[:to.len])
		staying := ctx.time - to.born < f64(to.life)
		// A burst of toasts comes in one after another, 40 ms apart.
		shown := tween_from(ctx, to.id, 0, 1 if staying else 0, t.toast_time, .Out_Cubic, 0.04 * f32(n - 1 - i) if staying else 0)
		h: f32 = 40
		w := text_width(ctx, msg, t.text_size) + 16 + 12 + 10 + 16
		target_y := y - h
		top := tween(ctx, salt(to.id, 1), target_y, t.toast_time, .Out_Cubic)
		r := Rect{math.round(window.x * 0.5 - w * 0.5), top, w, h}
		mark := vertex_mark(ctx)
		shadow_rect(ctx, r, t.radius_large, t.shadow)
		fill_rect(ctx, r, t.radius_large, t.surface_raised)
		stroke_rect(ctx, r, t.radius_large, t.border_strong, 1)
		dot := t.accent
		switch to.kind {
		case .Info:
		case .Success: dot = t.success
		case .Warning: dot = t.warning
		case .Error:   dot = t.danger
		}
		fill_circle(ctx, {r.x + 16 + 4, r.y + h * 0.5}, 4, dot)
		text(ctx, msg, r.x + 16 + 12 + 6, r.y + h * 0.5, t.text_size, t.text)
		transform_since(ctx, mark, shown, 0.96 + 0.04 * shown, {r.x + r.w * 0.5, r.y + r.h}, {0, (1 - shown) * 12})
		// A toast takes the pointer like a panel, and a click on it dismisses it early.
		append(&ctx.placed, Placed{id = to.id, rect = r, root = true})
		if staying && ctx.input.mouse_valid && .Left in ctx.input.pressed && rect_contains(r, ctx.input.mouse) {
			to.life = f32(ctx.time - to.born)
		}
		y = target_y - 8
	}
}

// The whole window in pixels: what floats over everything is not clipped by a panel.
@(private)
full_clip :: proc(ctx: ^Context) -> Rect {
	d := px(ctx)
	return {0, 0, ctx.input.window.x * d, ctx.input.window.y * d}
}

// Where a popover opens relative to the control that opened it.
Side :: enum u8 {
	Below, // under it, left edges lined up
	Above, // over it, left edges lined up
	Below_End, // under it, right edges lined up
	Above_Center, // over it, centred
	Right, // to its right, tops lined up
	Pointer, // at the anchor's top-left corner: a context menu at the pointer
}

// Opens a popover beside `anchor` while `open^` is true (and while it is still leaving
// after), as a container to fill and close with popover_end. A press outside both the
// popover and `anchor` closes it; if that press was on the viewport it is swallowed, so
// dismissing never sculpts. Returns false when there is nothing to draw.
popover_begin :: proc(ctx: ^Context, name: string, open: ^bool, anchor: Rect, side: Side, box: Box) -> (shown: bool) {
	t := ctx.theme
	id := id_of(ctx, name)
	size, _ := prev_layout(ctx, name)
	// Fixed sizes are known before the first frame; content sizes only after it, so the
	// first frame of a fitting popover is drawn invisibly and measured.
	if box.width > 0 do size.x = box.width
	if box.height > 0 do size.y = box.height
	// Only a popover that was on screen last frame can be dismissed: the press that opens
	// one (a right click opening a context menu) is not outside it.
	popup, shown_before := Rect{}, false
	for p in ctx.placed_prev {
		if p.id == id {
			popup, shown_before = p.hit, true
		}
	}
	if open^ && shown_before && ctx.input.pressed != {} && ctx.input.mouse_valid {
		m := ctx.input.mouse
		if !rect_contains(popup, m) && !rect_contains(anchor, m) {
			open^ = false
			if ctx.pointer_root == 0 || ctx.viewport_drag {
				ctx.swallow = true
				ctx.viewport_drag = false
				ctx.pointer_root = 0
			}
		}
	}
	p := presence(ctx, salt(id, 9), open^, t.popover_time)
	if p <= 0 do return false
	window := ctx.input.window
	pos: [2]f32
	switch side {
	case .Below:        pos = {anchor.x, anchor.y + anchor.h + 6}
	case .Above:        pos = {anchor.x, anchor.y - 6 - size.y}
	case .Below_End:    pos = {anchor.x + anchor.w - size.x, anchor.y + anchor.h + 6}
	case .Above_Center: pos = {anchor.x + anchor.w * 0.5 - size.x * 0.5, anchor.y - 8 - size.y}
	case .Right:        pos = {anchor.x + anchor.w + 6, anchor.y}
	case .Pointer:      pos = {anchor.x, anchor.y}
	}
	// A popover that would run off the bottom opens upward instead when there is room.
	side := side
	if (side == .Below || side == .Below_End) && pos.y + size.y > window.y - 4 && anchor.y - 6 - size.y >= 4 {
		pos.y = anchor.y - 6 - size.y
		side = .Above
	}
	pos.x = clamp(pos.x, 4, max(window.x - size.x - 4, 4))
	pos.y = clamp(pos.y, 4, max(window.y - size.y - 4, 4))
	b := box
	if b.background == .None do b.background = .Raised
	if b.radius == 0 do b.radius = t.radius_large
	b.inert = !open^
	ctx.popup_stack_mark = vertex_mark(ctx)
	ctx.popup_anim = p
	ctx.popup_origin = popover_origin(anchor, side, pos, size)
	ctx.popup_measuring = size == {}
	if open^ do ctx.popup_open = id
	begin_at(ctx, name, pos, b)
	return true
}

popover_end :: proc(ctx: ^Context) {
	end(ctx)
	p := ctx.popup_anim
	if ctx.popup_measuring do p = 0
	transform_since(ctx, ctx.popup_stack_mark, p, 0.96 + 0.04 * p, ctx.popup_origin)
}

// The point a popover grows from: the middle of the edge that faces its trigger.
@(private)
popover_origin :: proc(anchor: Rect, side: Side, pos, size: [2]f32) -> [2]f32 {
	switch side {
	case .Below, .Below_End:
		return {clamp(anchor.x + anchor.w * 0.5, pos.x, pos.x + size.x), pos.y}
	case .Above, .Above_Center:
		return {clamp(anchor.x + anchor.w * 0.5, pos.x, pos.x + size.x), pos.y + size.y}
	case .Right:
		return {pos.x, pos.y + 16}
	case .Pointer:
		return pos
	}
	return pos
}
