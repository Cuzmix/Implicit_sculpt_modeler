package main

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "../ui"

// Where the chrome's bars stand (round 3's docks, PRs 3c-1 and 3c-2): the off-hand island
// and the view rail each keep their own place, as the layout has them today (Default), or on
// the left or right edge at a point down it, or floating where Arrange let go of them, as
// Maxon Forger's toolbox snaps to an edge's middle and floats elsewhere; the shelf, a row,
// along the bottom at a point across it, or floating in the window's lower part (what it
// opens, its tiles' popovers and the brush picker, opens above it). The top edge is no
// bar's: the top bar, the view chips, the navigation head and the panels' tops hold it. A bar's place is the
// layout's, since it belongs to the screen (the dial's place, which belongs to the hand, is a
// setting). Places are kept in layout terms, from the start side, so the kit's mirror flips
// them for a left hand as it flips every anchor; they are written as they are.

Bar_Edge :: enum u8 {
	Default, // the place the layout gives the bar, as before places came: first, so a fresh Kit_State has it
	Left,
	Right,
	Bottom,
	Float,
}

// The bars that have a place, by their name in a `bar_place` line.
Place_Bar :: enum u8 {
	Offhand,
	Rail,
	Shelf,
}

@(rodata)
PLACE_BAR_NAMES := [Place_Bar]string {
	.Offhand = "offhand",
	.Rail    = "rail",
	.Shelf   = "shelf",
}

// Each bar's root, which hit tests, keep-clear rules and Arrange's outline find it by.
@(rodata)
PLACE_BAR_ROOTS := [Place_Bar]string {
	.Offhand = "brush bar",
	.Rail    = "view bar",
	.Shelf   = "dock",
}

// The edge each bar's Default stands on, in layout terms.
@(rodata)
PLACE_BAR_HOME := [Place_Bar]Bar_Edge {
	.Offhand = .Left,
	.Rail    = .Right,
	.Shelf   = .Bottom,
}

// The edges each bar may stand on: the columns down the sides, the shelf along the bottom.
bar_place_edges :: proc(b: Place_Bar) -> bit_set[Bar_Edge] {
	return {.Bottom} if b == .Shelf else {.Left, .Right}
}

// The highest a floating shelf's top goes, as a share of the safe area down from its top,
// so what opens above it has room.
SHELF_FLOAT_TOP :: 0.4

// A bar's place: Default, an edge with the bar's top `along` the room down it (0 at the top,
// 1 at the bottom, 0.5 the middle), or floating with its top-left at `at`, points from the
// safe area's start corner.
Bar_Place :: struct {
	edge:  Bar_Edge,
	along: f32,
	at:    [2]f32,
}

// How near the middle of an edge a drop snaps to it, as a share of the room, and how near
// an edge a drop must be to go on it, in points.
PLACE_SNAP :: 0.04
PLACE_REACH :: 72

// The edge bar `b` stands on, Default taken as its home edge; Float for a floating one.
bar_place_edge :: proc(k: ^Kit_State, b: Place_Bar) -> Bar_Edge {
	p := k.places[b]
	return PLACE_BAR_HOME[b] if p.edge == .Default else p.edge
}

// The column bar standing on `edge`, if one is shown there.
bar_place_on :: proc(k: ^Kit_State, edge: Bar_Edge) -> (b: Place_Bar, ok: bool) {
	for p in Place_Bar do if bar_place_edge(k, p) == edge && bar_place_shown(k, p) do return p, true
	return
}

// Whether bar `b` is shown in the layout.
bar_place_shown :: proc(k: ^Kit_State, b: Place_Bar) -> bool {
	switch b {
	case .Offhand: return .Brush_Bar not_in k.hidden
	case .Rail:    return .View_Bar not_in k.hidden
	case .Shelf:   return .Dock not_in k.hidden
	}
	return false
}

// The room an edge bar has down its edge, in points down the safe area: under the view
// chips on the start side and under the top bar on the pen side, and above the dial on the
// dial's side or the palm's band on the pen side.
bar_place_room :: proc(app: ^App, edge: Bar_Edge) -> (lo, hi: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	lo = points_bottom(app) if edge == .Left else TOP_BAR_H + 6
	hi = area.h - t.edge - dock_stack(app) - 8
	side := Rail_Side.Left if edge == .Left else .Right
	if reach := rail_reach(app, side); reach > 0 do hi = min(hi, area.h - reach - 8)
	if edge == .Right do hi = min(hi, area.h - lens_palm(app) - 8)
	if hi < lo + t.target do hi = lo + t.target
	return
}

// Where bar `b`, `size` points big, goes that is not Default: the anchors and offset its
// begin_anchored takes, in layout terms (the kit mirrors them), and the room it has down
// the window for its content.
bar_place_anchor :: proc(app: ^App, b: Place_Bar, size: [2]f32) -> (x, y: ui.Anchor, offset: [2]f32, room: f32) {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	p := k.places[b]
	y = .Start
	switch p.edge {
	case .Bottom:
		lo, hi := shelf_across(app)
		left := lo + clamp(p.along, 0, 1) * max(hi - lo - size.x, 0)
		return .Start, .End, {left, ctx.theme.edge + dock_lift(app)}, hi - lo
	case .Default, .Left, .Right:
		edge := bar_place_edge(k, b)
		lo, hi := bar_place_room(app, edge)
		top := lo + clamp(p.along, 0, 1) * max(hi - lo - size.y, 0)
		x = .Start if edge == .Left else .End
		return x, y, {LENS_EDGE, top}, hi - top
	case .Float:
		high: f32 = TOP_BAR_H + 6
		if b == .Shelf do high = area.h * SHELF_FLOAT_TOP
		at := [2]f32{clamp(p.at.x, 0, max(area.w - size.x, 0)), clamp(p.at.y, high, max(area.h - size.y, high))}
		down := area.h - at.y - ctx.theme.edge
		if b == .Shelf do down = area.w - 2 * LENS_EDGE
		return .Start, y, at, down
	}
	return
}

// How far across the bottom a shelf off its Default spot may stand, in points from the
// start side (layout terms): clear of the dial in its corner on either side.
shelf_across :: proc(app: ^App) -> (lo, hi: f32) {
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	lo, hi = LENS_EDGE, area.w - LENS_EDGE
	if across := rail_reach_across(app); across > 0 {
		if rail_shown(k) == .Left do lo = max(lo, across + 8)
		else do hi = min(hi, area.w - across - 8)
	}
	return
}

// The shelf's size as the bottom's keep-clear rules see it (the action bar, the toasts,
// History, the shape bar, the columns, the dial): last frame's while it stands along the
// bottom, none while it floats.
shelf_bottom_size :: proc(app: ^App) -> [2]f32 {
	if app.kit.places[.Shelf].edge == .Float do return {}
	size, _ := ui.prev_layout(&app.kit.ctx, "dock")
	return size
}

// Where the shelf reaches across the bottom, in points from the start side (layout
// terms): about the middle at Default, as the rules have always measured it, else where it
// was laid out last frame; nothing while it floats.
shelf_bottom_span :: proc(app: ^App) -> (lo, hi: f32) {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	size := shelf_bottom_size(app)
	if k.places[.Shelf].edge == .Default do return area.w * 0.5 - size.x * 0.5, area.w * 0.5 + size.x * 0.5
	if size == {} do return area.w * 0.5, area.w * 0.5
	r := ui.prev_rect(ctx, "dock")
	lo, hi = r.x - area.x, r.x - area.x + r.w
	if ctx.mirror do lo, hi = area.w - hi, area.w - lo
	return
}

// Which side a bar's popovers open: away from its edge, and for a floating bar toward the
// window's middle (in layout terms, as popover_begin mirrors sides).
bar_place_side :: proc(app: ^App, b: Place_Bar) -> ui.Side {
	k := &app.kit
	if b == .Shelf do return .Above_Center
	switch bar_place_edge(k, b) {
	case .Default, .Left: return .Right
	case .Right:          return .Left
	case .Bottom:         return .Above_Center
	case .Float:
		r := ui.prev_rect(&k.ctx, PLACE_BAR_ROOTS[b])
		area := ui.safe_area(&k.ctx)
		start_half := r.x + r.w * 0.5 < area.x + area.w * 0.5
		if k.ctx.mirror do start_half = !start_half
		return .Right if start_half else .Left
	}
	return .Right
}

// What Arrange's drop of bar `b` gives: the outline `box` (screen points) let go with the
// pointer at `p`. Over an edge the bar may take (within PLACE_REACH of it), the bar goes on
// it with its top where the outline's was, snapped to the middle near it and to Default at
// its own default spot; elsewhere it floats where the outline is. `default_top` is where its
// Default puts its top, for that spot. Screen terms become layout terms under the mirror.
bar_place_drop :: proc(app: ^App, b: Place_Bar, box: ui.Rect, p: [2]f32, default_top: f32) -> Bar_Place {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	x := box.x - area.x
	px := p.x - area.x
	if ctx.mirror {
		x = area.w - x - box.w
		px = area.w - px
	}
	if b == .Shelf do return shelf_drop(app, box, x, p.y - area.y)
	edge := Bar_Edge.Float
	if px < PLACE_REACH do edge = .Left
	else if px > area.w - PLACE_REACH do edge = .Right
	if edge == .Float {
		return {edge = .Float, at = {math.round(x), math.round(box.y - area.y)}}
	}
	lo, hi := bar_place_room(app, edge)
	span := max(hi - lo - box.h, 1)
	along := clamp((box.y - area.y - lo) / span, 0, 1)
	if abs(along - 0.5) < PLACE_SNAP do along = 0.5
	along = math.round(along * 100) / 100
	if edge == PLACE_BAR_HOME[b] && abs(box.y - area.y - default_top) < span * PLACE_SNAP do return {}
	return {edge = edge, along = along}
}

// The shelf's drop: within PLACE_REACH of the bottom it stands along it where the outline
// was across (`x`, layout terms), Default near the middle; elsewhere it floats.
@(private = "file")
shelf_drop :: proc(app: ^App, box: ui.Rect, x, py: f32) -> Bar_Place {
	area := ui.safe_area(&app.kit.ctx)
	if py < area.h - PLACE_REACH {
		return {edge = .Float, at = {math.round(x), math.round(box.y - area.y)}}
	}
	lo, hi := shelf_across(app)
	span := max(hi - lo - box.w, 1)
	along := clamp((x - lo) / span, 0, 1)
	// At about the middle it is where it comes, which the tablet's shift and the panes
	// keep where they put it.
	if abs(x + box.w * 0.5 - area.w * 0.5) < area.w * PLACE_SNAP do return {}
	return {edge = .Bottom, along = math.round(along * 100) / 100}
}

// Puts bar `b` at `to`: a bar already on that edge takes `b`'s place before, so the two
// swap rather than stand on each other.
bar_place_set :: proc(app: ^App, b: Place_Bar, to: Bar_Place) {
	k := &app.kit
	was := k.places[b]
	was_edge := bar_place_edge(k, b)
	k.places[b] = to
	if to.edge == .Float do return
	edge := bar_place_edge(k, b)
	for other in Place_Bar {
		if other == b || bar_place_edge(k, other) != edge || !bar_place_shown(k, other) do continue
		// The other bar takes the edge `b` left, at its old height, or `b`'s old float.
		if was.edge == .Float || was_edge == edge {
			k.places[other] = was
		} else {
			k.places[other] = {edge = was_edge, along = 0.5 if was.edge == .Default else was.along}
			if was_edge == PLACE_BAR_HOME[other] do k.places[other] = {}
		}
	}
}

// The layout's place lines: one for each bar not at Default.
bar_places_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for p, b in k.places {
		if p.edge == .Default do continue
		fmt.sbprintfln(out, "bar_place %s %v %g %g %g", PLACE_BAR_NAMES[b], p.edge, p.along, p.at.x, p.at.y)
	}
}

// Reads a `bar_place <bar> <edge> <along> <x> <y>` line; a bar, an edge or a number this
// version does not take leaves the bar at Default.
bar_place_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 6 do return
	b: Place_Bar
	found := false
	for name, which in PLACE_BAR_NAMES do if name == f[1] do b, found = which, true
	if !found do return
	edge, ok := reflect.enum_from_name(Bar_Edge, f[2])
	if !ok || (edge != .Float && edge not_in bar_place_edges(b)) do return
	along, a_ok := strconv.parse_f32(f[3])
	x, x_ok := strconv.parse_f32(f[4])
	y, y_ok := strconv.parse_f32(f[5])
	if !a_ok || !x_ok || !y_ok || !finite(along) || !finite(x) || !finite(y) do return
	k.places[b] = {edge = edge, along = clamp(along, 0, 1), at = {clamp(x, 0, 1e5), clamp(y, 0, 1e5)}}

	finite :: proc(v: f32) -> bool {return v == v && abs(v) < 1e30}
}

// The places as the exit stats print them: `offhand:left:0.50,rail:default`.
bar_places_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for p, b in k.places {
		if strings.builder_len(out) > 0 do strings.write_byte(&out, ',')
		edge := strings.to_lower(fmt.tprint(p.edge), context.temp_allocator)
		switch p.edge {
		case .Default:               fmt.sbprintf(&out, "%s:%s", PLACE_BAR_NAMES[b], edge)
		case .Left, .Right, .Bottom: fmt.sbprintf(&out, "%s:%s:%.2f", PLACE_BAR_NAMES[b], edge, p.along)
		case .Float:        fmt.sbprintf(&out, "%s:%s:%.0f,%.0f", PLACE_BAR_NAMES[b], edge, p.at.x, p.at.y)
		}
	}
	return strings.to_string(out)
}
