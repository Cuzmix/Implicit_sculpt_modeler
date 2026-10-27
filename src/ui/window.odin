package ui

import "core:math/linalg"

// A floating panel that behaves as a desktop window does: a title bar to drag it about
// by, a button that folds it to that bar and one that closes it. The app keeps one per
// panel and may remember it between runs; the kit changes it as the bar is used. Until
// it is dragged it sits where the app's default anchors put it; once dragged it keeps
// to the window edges nearest it (the side its middle is on, the top or bottom half its
// title bar is in), so a panel moved to the right stays on the right when the window or
// tablet changes size, and its title bar stays put while its content grows or shrinks.
Window :: struct {
	minimized: bool, // folded to its title bar
	moved:     bool, // placed by a drag rather than by the app's default anchors
	x, y:      Anchor, // once moved: the edges it keeps its distance from (Start or End)...
	offset:    [2]f32, // ...and how far in, in points
	// The title bar's widget while it is held (as of last frame; 0 otherwise), where on the
	// window the pointer took hold, and whether the pointer has gone past the slop (until
	// then a press is a tap). A window hidden mid-drag finds its bar no longer held.
	held:      Id,
	grab:      [2]f32,
	dragging:  bool,
}

// Opens the window `name`, titled `title`, as a root container with `box` (whose fixed
// width the title bar spans): where `w` says once moved, else as begin_anchored would
// place it with `x`, `y` and `offset`, and in either case with its whole title bar inside
// the safe area. Draws the title bar: the title, which drags the window and, folded,
// opens it again at a tap; Minimise (Restore, folded); and Close, whose tooltip shows
// `close_keys`. Returns whether to lay out the window's content (false while folded),
// whether Close was clicked, and whether a press landed anywhere on the window this
// frame, for the app to bring it in front of the others. Close it with window_end.
window_begin :: proc(ctx: ^Context, name, title: string, w: ^Window, x, y: Anchor, offset: [2]f32, box: Box, close_keys := "") -> (body, closed, raised: bool) {
	t := ctx.theme
	id := id_of(ctx, name)
	box := box
	if w.minimized do box.height = 0
	size := prev_size(ctx, id, box)
	// A held title bar moves the window before it is placed, so it follows the pointer
	// this frame rather than the next.
	if in_ := ctx.input; w.held != 0 && ctx.active == w.held && .Left in in_.down && !in_.cancel {
		if !w.dragging && linalg.length(in_.mouse - ctx.press_mouse) > t.slop do w.dragging = true
		if w.dragging do window_move(ctx, w, in_.mouse - w.grab, size, box.padding)
	}
	ax, ay, off := x, y, offset
	if w.moved do ax, ay, off = w.x, w.y, w.offset
	pos := window_clamp(ctx, anchored_pos(safe_area(ctx), ax, ay, off, size), size, box.padding)
	raised = !box.inert && ctx.pointer_root == id && .Left in ctx.input.pressed
	open(ctx, id, {pos.x, pos.y, size.x, size.y}, box, root = true)

	inner := fill_width(ctx)
	begin(ctx, "window bar", {direction = .Row, width = inner, center = true})
	r := place(ctx, {max(inner - 2 * t.target, t.target), t.target})
	bar := id_of(ctx, "window title")
	hovered, held, clicked, pressed := interact(ctx, bar, r)
	if pressed {
		// Its drag goes wherever the pointer does: nothing scrolls from it.
		_ = claim_drag(ctx, -1)
		w.grab, w.dragging = ctx.input.mouse - pos, false
	}
	if clicked && !w.dragging && w.minimized do w.minimized = false
	w.held = bar if held else 0
	if !held do w.dragging = false
	_ = feedback(ctx, bar, r, t.radius_medium, hovered, held)
	text(ctx, label_text(title), r.x + 6, r.y + r.h * 0.5, t.text_size, t.text, .Semibold)
	if icon_button(ctx, "Restore" if w.minimized else "Minimise", ICON_RESTORE if w.minimized else ICON_MINIMISE) do w.minimized = !w.minimized
	if icon_button(ctx, "Close", ICON_CLOSE, keys = close_keys) do closed = true
	end(ctx)
	return !w.minimized, closed, raised
}

window_end :: proc(ctx: ^Context) {
	end(ctx)
}

// Moves the window `w`, `size` points big, to have its top-left corner at `pos` (kept so
// its title bar is inside the safe area), anchoring it to the nearer side and, by where
// its title bar is, the nearer of the top and bottom.
window_move :: proc(ctx: ^Context, w: ^Window, pos: [2]f32, size: [2]f32, padding: f32) {
	area := safe_area(ctx)
	p := window_clamp(ctx, pos, size, padding)
	w.moved = true
	if p.x + size.x * 0.5 < area.x + area.w * 0.5 {
		w.x, w.offset.x = .Start, p.x - area.x
	} else {
		w.x, w.offset.x = .End, area.x + area.w - (p.x + size.x)
	}
	if p.y < area.y + area.h * 0.5 {
		w.y, w.offset.y = .Start, p.y - area.y
	} else {
		w.y, w.offset.y = .End, area.y + area.h - (p.y + size.y)
	}
}

// `pos` moved as little as it takes to keep a window `size` points big, with `padding`
// round its title bar, inside the safe area: all of it across when it fits (else its left
// edge), and its title bar from top to bottom, so it can always be dragged back.
@(private)
window_clamp :: proc(ctx: ^Context, pos: [2]f32, size: [2]f32, padding: f32) -> [2]f32 {
	area := safe_area(ctx)
	p := pos
	p.x = clamp(p.x, area.x, max(area.x + area.w - size.x, area.x))
	p.y = clamp(p.y, area.y, max(area.y + area.h - (2 * padding + ctx.theme.target), area.y))
	return p
}

// Opens the card `name`, a window without a title bar, as ZBrush for iPad's quick-access
// cards are: a strip of dots along its top that drags it like a title bar, then `title`
// large and centred. Placed as window_begin places a window. Returns whether a press
// landed on it this frame, to bring it to the front, and whether the dots were long
// pressed (the app docks the card back into its palette). Close it with window_end.
card_begin :: proc(ctx: ^Context, name, title: string, w: ^Window, x, y: Anchor, offset: [2]f32, box: Box) -> (raised, dock: bool) {
	t := ctx.theme
	id := id_of(ctx, name)
	size := prev_size(ctx, id, box)
	if in_ := ctx.input; w.held != 0 && ctx.active == w.held && .Left in in_.down && !in_.cancel {
		if !w.dragging && linalg.length(in_.mouse - ctx.press_mouse) > t.slop do w.dragging = true
		if w.dragging do window_move(ctx, w, in_.mouse - w.grab, size, box.padding)
	}
	ax, ay, off := x, y, offset
	if w.moved do ax, ay, off = w.x, w.y, w.offset
	pos := window_clamp(ctx, anchored_pos(safe_area(ctx), ax, ay, off, size), size, box.padding)
	raised = !box.inert && ctx.pointer_root == id && .Left in ctx.input.pressed
	open(ctx, id, {pos.x, pos.y, size.x, size.y}, box, root = true)

	inner := fill_width(ctx)
	// The dots are a thin strip to look at but a full target to hold.
	GRIP_H :: 18
	r := place(ctx, {inner, GRIP_H})
	grip := id_of(ctx, "card grip")
	hit := Rect{r.x, r.y - (t.target - GRIP_H) * 0.5, r.w, t.target}
	hovered, held, _, pressed := interact(ctx, grip, hit)
	if pressed {
		_ = claim_drag(ctx, -1)
		w.grab, w.dragging = ctx.input.mouse - pos, false
	}
	dock = secondary(ctx)
	w.held = grip if held else 0
	if !held do w.dragging = false
	color := t.accent if held else (t.text if hovered else t.text_tertiary)
	for row in 0 ..< 2 do for col in 0 ..< 6 {
		c := [2]f32{r.x + r.w * 0.5 + (f32(col) - 2.5) * 5, r.y + r.h * 0.5 + (f32(row) - 0.5) * 5}
		fill_circle(ctx, c, 1.2, color)
	}
	tip(ctx, grip, hit, "Drag to move; hold to put back in the palette")
	// Large, as the cards' titles are: about half again the panels' headings.
	title_r := place(ctx, {inner, 40})
	text(ctx, label_text(title), title_r.x + title_r.w * 0.5, title_r.y + title_r.h * 0.5, t.heading_size * 1.4, t.text, .Semibold, .Center)
	return
}
