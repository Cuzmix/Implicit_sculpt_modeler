package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "../ui"

// Resizing the Lens panel stack (round 2 of the mockups, screen resize2): the stack's
// inner edge sets its width, an open card's bottom grip the height of what it shows, and a
// floating card's edges and corners its size, as Blender's areas and a desktop's windows
// resize, with targets a finger finds. Sizes snap to an 8 point grid, so cards set by hand
// line up, and a double tap puts one back: the stack to its fresh width, a card to fit
// its content. The stack's width and the docked cards' heights are part of a workspace's
// layout, so Sculpt and Studio can keep different ones.

// A fresh layout's width (the tray's), and how narrow and how wide the edge takes it.
STACK_W :: KIT_INSPECTOR_W
STACK_W_MIN :: 260
STACK_W_MAX :: 440
// A floating card's least and greatest size.
STACK_FLOAT_MIN :: [2]f32{240, 120}
STACK_FLOAT_MAX :: [2]f32{640, 860}
// The least a docked card's content is set to: a drag up past its header folds it instead.
STACK_BODY_MIN :: 48
STACK_SNAP :: 8
// The grip under an open card: a short bar to look at, held anywhere across the card.
STACK_GRIP_H :: 14
// How far the stack's edge takes presses out over the view, and in over the cards.
STACK_EDGE_OUT :: 28
STACK_EDGE_IN :: 4

Stack_Edge :: enum u8 {
	Left,
	Right,
	Top,
	Bottom,
}

Stack_Drag_Kind :: enum u8 {
	None,
	Width, // the stack's inner edge
	Height, // an open card's bottom grip
	Float, // a floating card's edge or corner
}

// A resize under way: what it resizes, from which edges, and the rectangle, pointer and
// set height it started from.
Stack_Drag :: struct {
	kind:   Stack_Drag_Kind,
	card:   Stack_Card,
	edges:  bit_set[Stack_Edge],
	from:   ui.Rect,
	press:  [2]f32,
	before: f32,
}

// `v` on the 8 point grid.
stack_snap :: proc(v: f32) -> f32 {
	return math.round(v / STACK_SNAP) * STACK_SNAP
}

// The stack's width in points: the one set by its edge, or a fresh layout's.
stack_width :: proc(k: ^Kit_State) -> f32 {
	w := k.stack.width
	return clamp(w, STACK_W_MIN, STACK_W_MAX) if w > 0 else STACK_W
}

// The sizes' line in a workspace's layout, `stack_size <width|default> <card>=<height> ...`
// for the docked cards given a height, written only when something differs from a fresh
// layout; a floating card's size lasts for the session, as the card floats only until a
// layout is put in place.
stack_sizes_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	s := &k.stack
	if !s.set do return
	differs := s.width > 0
	for h in s.heights do differs ||= h > 0
	if !differs do return
	strings.write_string(out, "stack_size")
	if s.width > 0 do fmt.sbprintf(out, " %d", int(stack_width(k)))
	else do strings.write_string(out, " default")
	for c in Stack_Card do if s.heights[c] > 0 do fmt.sbprintf(out, " %v=%d", c, int(s.heights[c]))
	strings.write_byte(out, '\n')
}

// Reads a sizes line as stack_sizes_save writes it; what it cannot read stays as it was.
stack_sizes_read :: proc(k: ^Kit_State, f: []string) {
	s := &k.stack
	if !s.set do stack_default(k)
	if len(f) < 2 do return
	if f[1] == "default" do s.width = 0
	else if w, ok := strconv.parse_f32(f[1]); ok && w > 0 do s.width = clamp(stack_snap(w), STACK_W_MIN, STACK_W_MAX)
	for word in f[2:] {
		eq := strings.index_byte(word, '=')
		if eq <= 0 do continue
		h, ok := strconv.parse_f32(word[eq + 1:])
		if !ok || h <= 0 do continue
		for c in Stack_Card do if strings.equal_fold(word[:eq], fmt.tprint(c)) do s.heights[c] = max(stack_snap(h), STACK_BODY_MIN)
	}
}

// The stack's inner edge, on the view's side of it: a strip a finger holds to drag the
// stack wider or narrower, with a pill saying how wide while it moves and a dashed line
// where it started. A double tap puts a fresh layout's width back. `r` is the stack as it
// was laid out.
stack_edge :: proc(app: ^App, r: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	if r.w <= 0 || r.h <= 0 do return
	// The inner edge is the left one beside the pen side's rail, the right one when the
	// layout is mirrored for the left hand.
	inward: f32 = 1 if ctx.mirror else -1
	edge := r.x + r.w if ctx.mirror else r.x
	x := edge - STACK_EDGE_IN if ctx.mirror else edge - STACK_EDGE_OUT
	ui.begin_at(ctx, "stack edge", {x, r.y}, {direction = .Column, width = STACK_EDGE_OUT + STACK_EDGE_IN, height = r.h})
	a := ui.area(ctx, "stack edge strip", {STACK_EDGE_OUT + STACK_EDGE_IN, r.h})
	ui.end(ctx)
	ui.tip(ctx, a.id, a.rect, "Drag to make the panels wider or narrower; double tap for the usual width")
	if a.pressed do s.drag = {kind = .Width, from = r, press = a.mouse}
	moving := s.drag.kind == .Width && a.held
	if moving {
		s.width = clamp(stack_snap(s.drag.from.w + (a.mouse.x - s.drag.press.x) * inward), STACK_W_MIN, STACK_W_MAX)
	} else if s.drag.kind == .Width {
		if stack_width(k) != s.drag.from.w do s.resizes += 1
		s.drag = {}
	}
	if a.clicked && handle_double_tap(ctx, &s.tap, a.id) {
		s.width = 0
		s.resizes += 1
	}
	line_x := edge + 6 * inward
	mid := r.y + r.h * 0.5
	if !moving {
		// At rest a short bar says the edge can be held, brighter under the pointer.
		ui.fill_rect(ctx, {line_x - 2, mid - 18, 4, 36}, 2, t.text if a.hovered else t.border_strong)
		return
	}
	// The edge as it moves, the knob under the finger, the width and where it began.
	from_x := (s.drag.from.x + s.drag.from.w if ctx.mirror else s.drag.from.x) + 6 * inward
	for y := r.y; y < r.y + r.h; y += 10 do ui.line(ctx, {from_x, y}, {from_x, min(y + 5, r.y + r.h)}, t.text_tertiary, 1)
	ui.fill_rect(ctx, {line_x - 1.5, r.y, 3, r.h}, 1.5, t.accent)
	ui.stroke_circle(ctx, {line_x, mid}, 14, t.text, 2)
	label := fmt.tprintf("%d pt", int(stack_width(k)))
	lw := ui.text_width(ctx, label, t.small_size, .Semibold) + 20
	px := line_x + (24 if ctx.mirror else -24 - lw)
	ui.fill_rect(ctx, {px, mid - 13, lw, 26}, 13, t.accent)
	ui.text(ctx, label, px + lw * 0.5, mid, t.small_size, t.on_accent, .Semibold, .Center)
}

// The grip under open card `c`'s content in the stack: dragged down or up it sets how tall
// the content shows (scrolling inside when it is taller), up past the header folds the
// card, and a double tap fits the card to its content again. `width` is the card's.
stack_height_grip :: proc(app: ^App, c: Stack_Card, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	g := ui.area(ctx, fmt.tprintf("%v##stack height", c), {width, STACK_GRIP_H})
	ui.tip(ctx, g.id, g.rect, "Drag to set the height; up past the header folds it; double tap to fit")
	if g.pressed do s.drag = {kind = .Height, card = c, from = s.bodies[c], press = g.mouse, before = s.heights[c]}
	mine := s.drag.kind == .Height && s.drag.card == c
	folding := mine && g.mouse.y < s.rects[c].y + t.target
	if mine && g.held {
		s.heights[c] = max(stack_snap(s.drag.from.h + g.mouse.y - s.drag.press.y), STACK_BODY_MIN)
	} else if mine {
		if folding {
			s.open -= {c}
			s.heights[c] = s.drag.before
			s.folds += 1
		} else if s.heights[c] != s.drag.before {
			s.resizes += 1
		}
		s.drag = {}
	}
	if g.clicked && !folding && handle_double_tap(ctx, &s.tap, g.id) {
		s.heights[c] = 0
		s.resizes += 1
	}
	color := t.accent if g.held else (t.text_secondary if g.hovered else t.border_strong)
	if folding do color = t.text_tertiary
	ui.fill_rect(ctx, {g.rect.x + g.rect.w * 0.5 - 16, g.rect.y + g.rect.h * 0.5 - 2, 32, 4}, 2, color)
}

// A floating card's eight handles, at its corners and the middles of its edges, each a
// full target that reaches only a little way into the card, so its header's buttons stay
// its own. A drag sets the card's size on the 8 point grid, moving the edges it holds and
// keeping the others where they are; a double tap puts a fresh card's size back. Called
// after the card's window ends, so the handles come out over it.
stack_float_handles :: proc(app: ^App, c: Stack_Card) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	r := ui.prev_rect(ctx, fmt.tprintf("stack card %v", c))
	if r.w <= 0 || r.h <= 0 do return
	HIT :: 36
	INSIDE :: 8
	mine := s.drag.kind == .Float && s.drag.card == c
	for i in 0 ..< 8 {
		// Clockwise from the top left: corners on the even steps, edges' middles between.
		edges: bit_set[Stack_Edge]
		switch i {
		case 0: edges = {.Left, .Top}
		case 1: edges = {.Top}
		case 2: edges = {.Right, .Top}
		case 3: edges = {.Right}
		case 4: edges = {.Right, .Bottom}
		case 5: edges = {.Bottom}
		case 6: edges = {.Left, .Bottom}
		case 7: edges = {.Left}
		}
		at := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
		out := [2]f32{0, 0}
		if .Left in edges do at.x, out.x = r.x, -1
		if .Right in edges do at.x, out.x = r.x + r.w, 1
		if .Top in edges do at.y, out.y = r.y, -1
		if .Bottom in edges do at.y, out.y = r.y + r.h, 1
		// The target sits mostly outside the card, its inner side INSIDE points in.
		box := at - HIT * 0.5 + out * (HIT * 0.5 - INSIDE)
		ui.begin_at(ctx, fmt.tprintf("stack size %v %d", c, i), box, {direction = .Column, width = HIT, height = HIT})
		a := ui.area(ctx, "handle", {HIT, HIT})
		ui.end(ctx)
		ui.tip(ctx, a.id, a.rect, "Drag to resize; double tap for the usual size")
		if a.pressed do s.drag = {kind = .Float, card = c, edges = edges, from = r, press = a.mouse}
		if mine && s.drag.edges == edges && a.held {
			stack_float_resize(app, c, a.mouse - s.drag.press)
		} else if mine && s.drag.edges == edges {
			if r.w != s.drag.from.w || r.h != s.drag.from.h do s.resizes += 1
			s.drag = {}
		}
		if a.clicked && handle_double_tap(ctx, &s.tap, a.id) {
			s.sizes[c] = {}
			s.resizes += 1
		}
		held := mine && s.drag.edges == edges
		fill := t.accent if held else t.text
		if held && card(edges) == 2 do ui.fill_rect(ctx, {at.x - 6, at.y - 6, 12, 12}, 2, fill)
		else do ui.fill_circle(ctx, at, 5 if a.hovered || held else 4, fill)
		ui.stroke_circle(ctx, at, 5, t.surface, 1)
	}
	if !mine do return
	// While it is resized, the size under the card.
	label := fmt.tprintf("%d × %d · drag any edge", int(r.w), int(r.h))
	lw := ui.text_width(ctx, label, t.small_size, .Semibold) + 24
	ui.fill_rect(ctx, {r.x + r.w * 0.5 - lw * 0.5, r.y + r.h + 18, lw, 26}, 13, t.surface)
	ui.text(ctx, label, r.x + r.w * 0.5, r.y + r.h + 31, t.small_size, t.text, .Semibold, .Center)
}

// Card `c`'s size as its held edges moved by `d` from where the drag began.
@(private = "file")
stack_float_resize :: proc(app: ^App, c: Stack_Card, d: [2]f32) {
	k := &app.kit
	s := &k.stack
	from, e := s.drag.from, s.drag.edges
	size := [2]f32{from.w, from.h}
	if .Left in e do size.x -= d.x
	if .Right in e do size.x += d.x
	if .Top in e do size.y -= d.y
	if .Bottom in e do size.y += d.y
	lo, hi := STACK_FLOAT_MIN, STACK_FLOAT_MAX
	for axis in 0 ..< 2 do size[axis] = clamp(stack_snap(size[axis]), lo[axis], hi[axis])
	pos := [2]f32{from.x, from.y}
	if .Left in e do pos.x = from.x + from.w - size.x
	if .Top in e do pos.y = from.y + from.h - size.y
	// Only a drag that moves the top or bottom edge sets a height: one across keeps the card
	// fitting its content, as it did.
	if .Left in e || .Right in e do s.sizes[c].x = size.x
	if .Top in e || .Bottom in e do s.sizes[c].y = size.y
	ui.window_move(&k.ctx, &s.windows[c], pos, size, 10)
}

// How tall floating card `c`'s content shows: its set height less the dots, the header,
// the gaps and the padding round them (card_begin's and stack_float_card's); 0 while
// it fits its content.
stack_float_body :: proc(app: ^App, c: Stack_Card) -> f32 {
	h := app.kit.stack.sizes[c].y
	if h <= 0 do return 0
	return max(h - (2 * 10 + 18 + 6 + app.kit.ctx.theme.target + 6), 40)
}

// The heights set on docked cards and the sizes on floating ones, for the exit stats:
// `Brush=320,Layers+240x300`, or "none".
stack_sizes_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in Stack_Card {
		h, sz := k.stack.heights[c], k.stack.sizes[c]
		if h <= 0 && sz == {} do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%v", c)
		if h > 0 do fmt.sbprintf(&b, "=%d", int(h))
		if sz != {} do fmt.sbprintf(&b, "+%dx%d", int(sz.x), int(sz.y))
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}
