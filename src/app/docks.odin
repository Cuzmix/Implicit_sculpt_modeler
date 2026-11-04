package main

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

import "../ui"

// Docks: every bar of buttons round the view is a dock, one kind of thing with one set of
// choices. A dock is a list of commands and brush values (a Bar_List, bars.odin) with a
// place, the lines its buttons stand in side by side, whether they show their names, and
// a ⋯ More at its end that adds to it and holds those choices. The brush bar (Size and
// Strength down the off-hand side), the view rail (the cards down the pen side) and the
// person's own docks are drawn by kit_dock; the shelf along the bottom keeps its own
// drawing (pages, brushes as tiles) but its place is a dock's.
//
// A place is the layout's, since it belongs to the screen (the dial's, which belongs to
// the hand, is a setting): as the layout has it (Default), on the left or right edge at a
// point down it (the shelf: along the bottom at a point across it), or floating where
// Arrange let go of it. The top edge is no dock's: the top bar, the readout, the
// navigation head and the panels' tops hold it. Places are kept in layout terms, from the
// start side, so the kit's mirror flips them for a left hand as it flips every anchor.

Dock_Edge :: enum u8 {
	Default, // the place the layout gives the dock: first, so a fresh Kit_State has it
	Left,
	Right,
	Bottom,
	Float,
}

// The docks, by their name in a `dock` layout line.
Dock_Id :: enum u8 {
	Offhand, // the brush bar
	Rail, // the view rail
	Shelf,
	// The person's own docks, made by New dock (the top bar while editing, Search or Settings > Bars).
	Dock_1,
	Dock_2,
	Dock_3,
	Dock_4,
}

USER_DOCKS :: 4

@(rodata)
DOCK_NAMES := [Dock_Id]string {
	.Offhand = "offhand",
	.Rail    = "rail",
	.Shelf   = "shelf",
	.Dock_1  = "dock1",
	.Dock_2  = "dock2",
	.Dock_3  = "dock3",
	.Dock_4  = "dock4",
}

// Each dock's root, which hit tests, keep-clear rules and Arrange's outline find it by.
@(rodata)
DOCK_ROOTS := [Dock_Id]string {
	.Offhand = "brush bar",
	.Rail    = "view bar",
	.Shelf   = "dock",
	.Dock_1  = "user dock 1",
	.Dock_2  = "user dock 2",
	.Dock_3  = "user dock 3",
	.Dock_4  = "user dock 4",
}

// What each dock is called where the person reads it.
@(rodata)
DOCK_TITLES := [Dock_Id]string {
	.Offhand = "Brush bar",
	.Rail    = "View rail",
	.Shelf   = "Shelf",
	.Dock_1  = "Dock 1",
	.Dock_2  = "Dock 2",
	.Dock_3  = "Dock 3",
	.Dock_4  = "Dock 4",
}

// The edge each dock's Default stands on, in layout terms. A dock of the person's has no
// home: it is made floating (user_dock_new) and never stays Default.
@(rodata)
DOCK_HOME := [Dock_Id]Dock_Edge {
	.Offhand = .Left,
	.Rail    = .Right,
	.Shelf   = .Bottom,
	.Dock_1  = .Float,
	.Dock_2  = .Float,
	.Dock_3  = .Float,
	.Dock_4  = .Float,
}

// When a dock's buttons show their names beside their icons. Wide is first, so a fresh
// dock names its buttons on a large desktop display and keeps to icons elsewhere.
Dock_Names :: enum u8 {
	Wide, // while the window is at least DOCK_NAMES_WIDE wide
	Always,
	Off,
}

@(rodata)
DOCK_NAMES_SHOWN := [Dock_Names]string{.Wide = "Wide", .Always = "Always", .Off = "Off"}

// How wide a window is, in points, before Wide names a dock's buttons: a large desktop
// display's (1920 at 100%, 2560 at 150%), wider than any tablet held either way, where the
// room is there for the names without taking it from the view.
DOCK_NAMES_WIDE :: 1700

// The most lines of buttons a dock stands side by side.
DOCK_LINES_MAX :: 6

// One dock's choices, the layout's: its place, how many lines its buttons stand in beyond
// the first, when they show their names, whether its ⋯ More is put away (Arrange still
// shows it), and for a dock of the person's whether it is in use. Its buttons are its bar
// list's (dock_which).
Dock :: struct {
	using place: Dock_Place,
	more_lines:  u8,
	names:       Dock_Names,
	more_off:    bool,
	used:        bool,
}

// A dock's place: Default, an edge with the dock's top `along` the room down it (0 at the
// top, 1 at the bottom, 0.5 the middle), or floating with its top-left at `at`, points
// from the safe area's start corner.
Dock_Place :: struct {
	edge:  Dock_Edge,
	along: f32,
	at:    [2]f32,
}

// The bar list behind dock `d`: the shelf's is the page it shows.
dock_which :: proc(k: ^Kit_State, d: Dock_Id) -> Bar_Which {
	switch d {
	case .Offhand: return .Offhand
	case .Rail:    return .View_Rail
	case .Shelf:   return shelf_which(k.shelf.page)
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4: return user_dock_which(int(d) - int(Dock_Id.Dock_1))
	}
	return .Offhand
}

// The dock bar `which` is, if it is one kit_dock draws.
dock_of_bar :: proc(which: Bar_Which) -> (Dock_Id, bool) {
	#partial switch which {
	case .Offhand:   return .Offhand, true
	case .View_Rail: return .Rail, true
	}
	if i, ok := user_dock_of(which); ok do return user_dock_id(i), true
	return {}, false
}

// How many lines dock `d`'s buttons stand in.
dock_lines :: proc(k: ^Kit_State, d: Dock_Id) -> int {
	return clamp(1 + int(k.docks[d].more_lines), 1, dock_lines_most(d))
}

// The most lines dock `d` takes: the shelf's rows of tiles stand over the view's foot,
// so it keeps to SHELF_LINES_MAX.
dock_lines_most :: proc(d: Dock_Id) -> int {
	return SHELF_LINES_MAX if d == .Shelf else DOCK_LINES_MAX
}

SHELF_LINES_MAX :: 3

// Whether dock `d` names its buttons now.
dock_named :: proc(app: ^App, d: Dock_Id) -> bool {
	k := &app.kit
	switch k.docks[d].names {
	case .Off:    return false
	case .Always: return true
	case .Wide:   return ui.safe_area(&k.ctx).w >= DOCK_NAMES_WIDE
	}
	return false
}

// The edges each dock may stand on: the columns down the sides, the shelf along the bottom.
dock_edges :: proc(b: Dock_Id) -> bit_set[Dock_Edge] {
	return {.Bottom} if b == .Shelf else {.Left, .Right}
}

// The highest a floating shelf's top goes, as a share of the safe area down from its top,
// so what opens above it has room.
SHELF_FLOAT_TOP :: 0.4

// How near the middle of an edge a drop snaps to it, as a share of the room, and how near
// an edge a drop must be to go on it, in points.
DOCK_SNAP :: 0.04
DOCK_REACH :: 72

// The edge dock `b` stands on, Default taken as its home edge; Float for a floating one.
dock_edge :: proc(k: ^Kit_State, b: Dock_Id) -> Dock_Edge {
	p := k.docks[b]
	return DOCK_HOME[b] if p.edge == .Default else p.edge
}

// Whether dock `b` is shown in the layout.
dock_shown :: proc(k: ^Kit_State, b: Dock_Id) -> bool {
	switch b {
	case .Offhand: return .Brush_Bar not_in k.hidden
	case .Rail:    return .View_Bar not_in k.hidden
	case .Shelf:   return .Dock not_in k.hidden
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4: return user_dock_shown(k, int(b) - int(Dock_Id.Dock_1))
	}
	return false
}

// The room an edge dock has down its edge, in points down the safe area: under the view
// chips on the start side and under the top bar on the pen side, and above the dial on the
// dial's side or the palm's band on the pen side.
dock_room :: proc(app: ^App, edge: Dock_Edge) -> (lo, hi: f32) {
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

// Where dock `b`, `size` points big, goes: the anchors and offset its begin_anchored
// takes, in layout terms (the kit mirrors them), and the room it has down the window for
// its content. At Default the brush bar stands down the off-hand side about its middle
// (brush_bar_top) and the rail at the top of the pen side; the shelf's Default is its own.
dock_anchor :: proc(app: ^App, b: Dock_Id, size: [2]f32) -> (x, y: ui.Anchor, offset: [2]f32, room: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	p := k.docks[b].place
	// A dock only a hand-written layout left at Default floats in the middle.
	if p.edge == .Default && DOCK_HOME[b] == .Float do p = {edge = .Float, at = user_dock_middle(k)}
	y = .Start
	switch p.edge {
	case .Bottom:
		lo, hi := shelf_across(app)
		left := lo + clamp(p.along, 0, 1) * max(hi - lo - size.x, 0)
		return .Start, .End, {left, t.edge + dock_lift(app)}, hi - lo
	case .Default, .Left, .Right:
		if p.edge == .Default && b == .Offhand {
			top := brush_bar_top(app)
			return .Start, .Start, {LENS_EDGE, top}, area.h - top - t.edge - dock_stack(app) - 8
		}
		if p.edge == .Default && b == .Rail {
			top: f32 = TOP_BAR_H + 6
			return .End, .Start, {BAR_EDGE + 6, top}, area.h - top - t.edge
		}
		edge := dock_edge(k, b)
		lo, hi := dock_room(app, edge)
		top := lo + clamp(p.along, 0, 1) * max(hi - lo - size.y, 0)
		x = .Start if edge == .Left else .End
		return x, y, {LENS_EDGE, top}, hi - top
	case .Float:
		high: f32 = TOP_BAR_H + 6
		if b == .Shelf do high = area.h * SHELF_FLOAT_TOP
		at := [2]f32{clamp(p.at.x, 0, max(area.w - size.x, 0)), clamp(p.at.y, high, max(area.h - size.y, high))}
		down := area.h - at.y - t.edge
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
	if app.kit.docks[.Shelf].edge == .Float do return {}
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
	if k.docks[.Shelf].edge == .Default do return area.w * 0.5 - size.x * 0.5, area.w * 0.5 + size.x * 0.5
	if size == {} do return area.w * 0.5, area.w * 0.5
	r := ui.prev_rect(ctx, "dock")
	lo, hi = r.x - area.x, r.x - area.x + r.w
	if ctx.mirror do lo, hi = area.w - hi, area.w - lo
	return
}

// Which side a dock's popovers open: away from its edge, and for a floating dock toward
// the window's middle (in layout terms, as popover_begin mirrors sides).
dock_side :: proc(app: ^App, b: Dock_Id) -> ui.Side {
	k := &app.kit
	if b == .Shelf do return .Above_Center
	switch dock_edge(k, b) {
	case .Default, .Left: return .Right
	case .Right:          return .Left
	case .Bottom:         return .Above_Center
	case .Float:
		// Asked from inside the dock, by its buttons.
		r := ui.prev_root_rect(&k.ctx, DOCK_ROOTS[b])
		area := ui.safe_area(&k.ctx)
		start_half := r.x + r.w * 0.5 < area.x + area.w * 0.5
		if k.ctx.mirror do start_half = !start_half
		return .Right if start_half else .Left
	}
	return .Right
}

// What Arrange's drop of dock `b` gives: the outline `box` (screen points) let go with the
// pointer at `p`. Over an edge the dock may take (within DOCK_REACH of it), the dock goes
// on it with its top where the outline's was, snapped to the middle near it and to Default
// at its own default spot; elsewhere it floats where the outline is. `default_top` is
// where its Default puts its top, for that spot. Screen terms become layout terms under
// the mirror.
dock_drop :: proc(app: ^App, b: Dock_Id, box: ui.Rect, p: [2]f32, default_top: f32) -> Dock_Place {
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
	edge := Dock_Edge.Float
	if px < DOCK_REACH do edge = .Left
	else if px > area.w - DOCK_REACH do edge = .Right
	if edge == .Float {
		return {edge = .Float, at = {math.round(x), math.round(box.y - area.y)}}
	}
	lo, hi := dock_room(app, edge)
	span := max(hi - lo - box.h, 1)
	along := clamp((box.y - area.y - lo) / span, 0, 1)
	if abs(along - 0.5) < DOCK_SNAP do along = 0.5
	along = math.round(along * 100) / 100
	if edge == DOCK_HOME[b] && abs(box.y - area.y - default_top) < span * DOCK_SNAP do return {}
	return {edge = edge, along = along}
}

// The shelf's drop: within DOCK_REACH of the bottom it stands along it where the outline
// was across (`x`, layout terms), Default near the middle; elsewhere it floats.
@(private = "file")
shelf_drop :: proc(app: ^App, box: ui.Rect, x, py: f32) -> Dock_Place {
	area := ui.safe_area(&app.kit.ctx)
	if py < area.h - DOCK_REACH {
		return {edge = .Float, at = {math.round(x), math.round(box.y - area.y)}}
	}
	lo, hi := shelf_across(app)
	span := max(hi - lo - box.w, 1)
	along := clamp((x - lo) / span, 0, 1)
	// At about the middle it is where it comes, which the tablet's shift and the panes
	// keep where they put it.
	if abs(x + box.w * 0.5 - area.w * 0.5) < area.w * DOCK_SNAP do return {}
	return {edge = .Bottom, along = math.round(along * 100) / 100}
}

// A faint line soft alignment draws while a floating dock lines up with a neighbour, from
// `a` to `b` in screen points.
Align_Line :: struct {
	a, b:  [2]f32,
	shown: bool,
}

// How near, in points, a floating dock's outline snaps to a neighbour's edge, middle or
// the small gap beside or under it, and that gap.
DOCK_ALIGN :: 10
DOCK_ALIGN_GAP :: 8

// Soft alignment: dock `b`'s outline `box` (screen points) moved onto the nearest match
// within DOCK_ALIGN of another shown dock, across and down apart: the same left, right or
// middle, or just beside it; the same top or bottom, or just under or over it. The lines
// say which edges matched, from one dock's far end to the other's.
dock_align :: proc(app: ^App, b: Dock_Id, box: ui.Rect) -> (out: ui.Rect, lines: [2]Align_Line) {
	k := &app.kit
	out = box
	Match :: struct {
		v, line, d: f32,
		t:          ui.Rect,
		found:      bool,
	}
	bx, by: Match
	for other in Dock_Id {
		if other == b || !dock_shown(k, other) do continue
		t := ui.prev_root_rect(&k.ctx, DOCK_ROOTS[other])
		if t.w <= 0 do continue
		xs := [5][2]f32{{t.x, t.x}, {t.x + t.w - box.w, t.x + t.w}, {t.x + t.w * 0.5 - box.w * 0.5, t.x + t.w * 0.5}, {t.x + t.w + DOCK_ALIGN_GAP, t.x + t.w + DOCK_ALIGN_GAP * 0.5}, {t.x - DOCK_ALIGN_GAP - box.w, t.x - DOCK_ALIGN_GAP * 0.5}}
		for x in xs {
			d := abs(x[0] - box.x)
			if d < DOCK_ALIGN && (!bx.found || d < bx.d) do bx = {x[0], x[1], d, t, true}
		}
		ys := [4][2]f32{{t.y, t.y}, {t.y + t.h - box.h, t.y + t.h}, {t.y + t.h + DOCK_ALIGN_GAP, t.y + t.h + DOCK_ALIGN_GAP * 0.5}, {t.y - DOCK_ALIGN_GAP - box.h, t.y - DOCK_ALIGN_GAP * 0.5}}
		for y in ys {
			d := abs(y[0] - box.y)
			if d < DOCK_ALIGN && (!by.found || d < by.d) do by = {y[0], y[1], d, t, true}
		}
	}
	if bx.found do out.x = bx.v
	if by.found do out.y = by.v
	if bx.found {
		lo, hi := min(out.y, bx.t.y) - 6, max(out.y + out.h, bx.t.y + bx.t.h) + 6
		lines[0] = {{bx.line, lo}, {bx.line, hi}, true}
	}
	if by.found {
		lo, hi := min(out.x, by.t.x) - 6, max(out.x + out.w, by.t.x + by.t.w) + 6
		lines[1] = {{lo, by.line}, {hi, by.line}, true}
	}
	return
}

// Puts dock `b` at `to`: a dock already on that edge takes `b`'s place before, so the two
// swap rather than stand on each other.
dock_place_set :: proc(app: ^App, b: Dock_Id, to: Dock_Place) {
	k := &app.kit
	was := k.docks[b].place
	was_edge := dock_edge(k, b)
	k.docks[b].place = to
	if to.edge == .Float do return
	edge := dock_edge(k, b)
	for other in Dock_Id {
		if other == b || dock_edge(k, other) != edge || !dock_shown(k, other) do continue
		// The other dock takes the edge `b` left, at its old height, or `b`'s old float.
		if was.edge == .Float || was_edge == edge {
			k.docks[other].place = was
		} else {
			k.docks[other].place = {edge = was_edge, along = 0.5 if was.edge == .Default else was.along}
			if was_edge == DOCK_HOME[other] do k.docks[other].place = {}
		}
	}
}

// Whether dock `b` is worth keeping in the layout: every built-in dock is, one of the
// person's only while it is in use.
dock_kept :: proc(k: ^Kit_State, b: Dock_Id) -> bool {
	return DOCK_HOME[b] != .Float || k.docks[b].used
}

// The layout's dock lines, `dock <name> <edge> <along> <x> <y> <lines> <names> <more>`: one
// for each of the person's docks in use, and each built-in one not as it comes.
docks_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for d, b in k.docks {
		if !dock_kept(k, b) do continue
		plain := d
		plain.used = false
		if DOCK_HOME[b] != .Float && plain == {} do continue
		fmt.sbprintfln(out, "dock %s %v %g %g %g %d %v %d", DOCK_NAMES[b], d.edge, d.along, d.at.x, d.at.y, dock_lines(k, b), d.names, 0 if d.more_off else 1)
	}
}

// Reads a `dock` line; a line this version cannot read leaves the dock as it comes. Naming
// one of the person's docks puts it in use.
dock_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 9 do return
	b: Dock_Id
	found := false
	for name, which in DOCK_NAMES do if name == f[1] do b, found = which, true
	if !found do return
	edge, ok := reflect.enum_from_name(Dock_Edge, f[2])
	if !ok || (edge != .Float && edge != .Default && edge not_in dock_edges(b)) do return
	along, a_ok := strconv.parse_f32(f[3])
	x, x_ok := strconv.parse_f32(f[4])
	y, y_ok := strconv.parse_f32(f[5])
	lines, l_ok := strconv.parse_int(f[6])
	names, n_ok := reflect.enum_from_name(Dock_Names, f[7])
	more, m_ok := strconv.parse_int(f[8])
	if !a_ok || !x_ok || !y_ok || !l_ok || !n_ok || !m_ok || !finite(along) || !finite(x) || !finite(y) do return
	k.docks[b] = {
		place      = {edge = edge, along = clamp(along, 0, 1), at = {clamp(x, 0, 1e5), clamp(y, 0, 1e5)}},
		more_lines = u8(clamp(lines, 1, dock_lines_most(b)) - 1),
		names      = names,
		more_off   = more == 0,
		used       = true,
	}

	finite :: proc(v: f32) -> bool {return v == v && abs(v) < 1e30}
}

// The places as the exit stats print them: `offhand:left:0.50,rail:default`.
dock_places_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for d, b in k.docks {
		if !dock_kept(k, b) do continue
		if strings.builder_len(out) > 0 do strings.write_byte(&out, ',')
		edge := strings.to_lower(fmt.tprint(d.edge), context.temp_allocator)
		switch d.edge {
		case .Default:               fmt.sbprintf(&out, "%s:%s", DOCK_NAMES[b], edge)
		case .Left, .Right, .Bottom: fmt.sbprintf(&out, "%s:%s:%.2f", DOCK_NAMES[b], edge, d.along)
		case .Float:                 fmt.sbprintf(&out, "%s:%s:%.0f,%.0f", DOCK_NAMES[b], edge, d.at.x, d.at.y)
		}
	}
	return strings.to_string(out)
}

// Each dock's lines and names for the exit stats, `offhand:1:wide,rail:2:off`, the
// person's docks only while in use.
dock_looks_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for d, b in k.docks {
		if !dock_kept(k, b) do continue
		if strings.builder_len(out) > 0 do strings.write_byte(&out, ',')
		fmt.sbprintf(&out, "%s:%d:%s%s", DOCK_NAMES[b], dock_lines(k, b), strings.to_lower(DOCK_NAMES_SHOWN[d.names], context.temp_allocator), ":nomore" if d.more_off else "")
	}
	return strings.to_string(out)
}

// The person's own docks: up to four, made by New dock, floating where
// they are made until carried to an edge. Each space and workspace keeps its own, as the
// rail's buttons are the screen's; the built-in workspaces have none.

// The size a new dock's outline is taken to have, for where it first floats.
@(private = "file")
DOCK_NEW_SIZE :: [2]f32{52, 120}

// Which of the person's docks bar `which` is, if it is one.
user_dock_of :: proc(which: Bar_Which) -> (int, bool) {
	i := int(which) - int(Bar_Which.Dock_1)
	return i, i >= 0 && i < USER_DOCKS
}

user_dock_which :: proc(i: int) -> Bar_Which {
	return Bar_Which(int(Bar_Which.Dock_1) + i)
}

user_dock_id :: proc(i: int) -> Dock_Id {
	return Dock_Id(int(Dock_Id.Dock_1) + i)
}

// Whether the person's dock `i` is drawn: in use, and holding a button or being arranged
// (where its + is); Focus mode and Inspect put it away with the rest of the view's chrome.
user_dock_shown :: proc(k: ^Kit_State, i: int) -> bool {
	if !k.docks[user_dock_id(i)].used do return false
	return k.bars_edit || (k.dock_lists[i].count > 0 && !k.focus_mode && !k.inspect.on)
}

// Where a new dock floats: its outline's top-left at the safe area's middle, in layout
// terms, whole points.
user_dock_middle :: proc(k: ^Kit_State) -> [2]f32 {
	area := ui.safe_area(&k.ctx)
	size := DOCK_NEW_SIZE
	return {math.round(max(area.w * 0.5 - size.x * 0.5, 0)), math.round(max(area.h * 0.5 - size.y * 0.5, TOP_BAR_H + 6))}
}

// Where a new dock floats: the middle of the view (layout terms).
@(private = "file")
user_dock_spot :: proc(k: ^Kit_State) -> [2]f32 {
	return user_dock_middle(k)
}

// How many of the person's docks are in use.
user_docks_used :: proc(k: ^Kit_State) -> int {
	n := 0
	for i in 0 ..< USER_DOCKS do if k.docks[user_dock_id(i)].used do n += 1
	return n
}

// Makes the first free dock: floating in the middle (beside the Library), empty but for
// its +. Opens Arrange first, as only Arrange fills it. False when
// all four are in use.
user_dock_new :: proc(app: ^App) -> bool {
	k := &app.kit
	for i in 0 ..< USER_DOCKS {
		d := &k.docks[user_dock_id(i)]
		if d.used do continue
		d^ = {used = true, place = {edge = .Float, at = user_dock_spot(k)}}
		k.dock_lists[i] = bar_fresh(user_dock_which(i))
		k.dock_scroll[user_dock_id(i)] = 0
		if !k.bars_edit do command_run(app, .Customise_Bars)
		k.arrange.docks_made += 1
		report(app, nil, {}, "Made %s: its + adds a button, and its head carries it to an edge", DOCK_TITLES[user_dock_id(i)])
		return true
	}
	report(app, nil, {.Warning}, "There are %d docks at most: delete one first", USER_DOCKS)
	return false
}

// Takes the person's dock `i` away, its buttons and place with it.
user_dock_delete :: proc(app: ^App, i: int) {
	k := &app.kit
	id := user_dock_id(i)
	if !k.docks[id].used do return
	count := k.dock_lists[i].count
	k.docks[id], k.dock_lists[i] = {}, {}
	if b, ok := k.arrange.carry.?; ok && b == id do k.arrange.carry, k.arrange.carrying = nil, false
	if k.bar_slot.open && k.bar_slot.which == user_dock_which(i) do k.bar_slot.open = false
	k.arrange.docks_deleted += 1
	report(app, nil, {}, "Deleted %s (%d button%s)", DOCK_TITLES[id], count, "" if count == 1 else "s")
}

// Puts every dock as a fresh layout has it: the built-in ones at Default with one line,
// none of the person's.
docks_clear :: proc(k: ^Kit_State) {
	k.docks, k.dock_lists = {}, {}
}

// The person's docks for the exit stats: `1:3,2:0` (number, buttons), or none.
user_docks_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for i in 0 ..< USER_DOCKS {
		if !k.docks[user_dock_id(i)].used do continue
		if strings.builder_len(out) > 0 do strings.write_byte(&out, ',')
		fmt.sbprintf(&out, "%d:%d", i + 1, k.dock_lists[i].count)
	}
	if strings.builder_len(out) == 0 do return "none"
	return strings.to_string(out)
}

// Every one of the person's docks shown.
kit_user_docks :: proc(app: ^App) {
	k := &app.kit
	for i in 0 ..< USER_DOCKS do if user_dock_shown(k, i) do kit_dock(app, user_dock_id(i))
}

// Dock `id` (any but the shelf): its buttons in its lines where its place says, scrolling
// where the room is less than they need, then the ⋯ More (and while arranging the + that
// adds one). A brush value shown as a slider stands as a tall slider a thumb drags without
// looking (Size and Strength on the brush bar at first); a window too short for every
// slider shows the last ones as chips. A card's button opens its card in the column
// beside it (column.odin).
kit_dock :: proc(app: ^App, id: Dock_Id) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	d := &k.docks[id]
	which := dock_which(k, id)
	used := bar_used(app, which)
	root := DOCK_ROOTS[id]
	more := k.bars_edit || !d.more_off
	// A brush bar with nothing in it and no More is put away.
	if len(used) == 0 && !k.bars_edit && !more do return
	size, _ := ui.prev_layout(ctx, root)
	x, y, offset, room := dock_anchor(app, id, size)
	lines := dock_lines(k, id)
	named := dock_named(app, id)
	width := t.target
	if named {
		longest: f32 = 0
		for s in used do longest = max(longest, ui.text_width(ctx, rail_label(app, s), t.small_size))
		width = t.target + longest + 10
	}
	// The foot under the buttons: the + while arranging and the ⋯, each a target and a gap.
	foot: f32 = 2 * 3 + DOCK_GRIP_H + 3 + (t.target + 6 if k.bars_edit else 0) + (t.target + 7 if more else 0)
	// Sliders until the buttons outgrow the room, then the last sliders as chips.
	sliders := 0
	tall := dock_rows_tall(app, id, used, lines, len(used))
	for s, i in used {
		if _, value := value_of(s); value && v_slider(k, which, i) do sliders += 1
	}
	for sliders > 0 && tall > room - foot {
		sliders -= 1
		tall = dock_rows_tall(app, id, used, lines, sliders)
	}
	ui.begin_anchored(ctx, root, x, y, offset, {direction = .Column, padding = 3, radius = t.radius_large, background = .Panel, center = true})
	dock_grip(app, id, width * f32(lines))
	scroll := kit_scroll_begin(ctx, fmt.tprintf("%s body", root), &k.dock_scroll[id], ui.id_of(ctx, root), width * f32(lines), max(room - foot, t.target * 2), 0)
	if id == .Offhand do k.island_sliders, k.island_frame = {}, k.frame
	shown := 0
	for i := 0; i < len(used); i += lines {
		if lines > 1 do ui.begin(ctx, fmt.tprintf("%s line %d", root, i / lines), {direction = .Row, center = true})
		for j in i ..< min(i + lines, len(used)) {
			s := used[j]
			v, value := value_of(s)
			switch {
			case value && v_slider(k, which, j) && shown < sliders && !k.bars_edit:
				dock_slider(app, id, j, v, width)
				shown += 1
				if id == .Offhand do k.island_sliders += {v}
			case value && id == .Offhand:
				value_item(app, which, j, v)
			case:
				bar_slot_button(app, which, j, s, named = rail_label(app, s) if named else "", width = width)
			}
		}
		if lines > 1 do ui.end(ctx)
	}
	kit_scroll_end(ctx, scroll)
	if k.bars_edit do bar_add_button(app, which, len(used), width)
	if more do dock_more_button(app, id, width * f32(lines))
	ui.end(ctx)

	v_slider :: proc(k: ^Kit_State, which: Bar_Which, i: int) -> bool {return bar_look(k, which, i) == .Slider}
}

// How tall dock `id`'s buttons stand in `lines` lines, the first `sliders` of its sliders
// as tall sliders and the rest as chips.
@(private = "file")
dock_rows_tall :: proc(app: ^App, id: Dock_Id, used: []Bar_Slot, lines, sliders: int) -> f32 {
	k := &app.kit
	t := k.ctx.theme
	which := dock_which(k, id)
	tall: f32 = 0
	seen := 0
	for i := 0; i < len(used); i += lines {
		row: f32 = 0
		for j in i ..< min(i + lines, len(used)) {
			h := t.target
			if _, value := value_of(used[j]); value {
				switch {
				case bar_look(k, which, j) == .Slider && seen < sliders:
					h = DOCK_SLIDER_TALL
					seen += 1
				case id == .Offhand:
					h = VALUE_CHIP.y
				case:
					h = VALUE_CHIP.y - 4
				}
			}
			row = max(row, h)
		}
		tall += row
	}
	return tall
}

// How tall a dock's slider stands: its track, its name above it and its value under it.
DOCK_SLIDER_TALL :: OFFHAND_TRACK + 80

// Value `v` in slot `slot` of dock `id` as a tall slider. Size and Strength keep the
// names, keys and pen roll they always had on the brush bar.
@(private = "file")
dock_slider :: proc(app: ^App, id: Dock_Id, slot: int, v: Brush_Value, width: f32) {
	ctx := &app.kit.ctx
	which := dock_which(&app.kit, id)
	tag := "island" if id == .Offhand else fmt.tprintf("%s %d", DOCK_ROOTS[id], slot)
	ui.begin(ctx, fmt.tprintf("%s slider %d", DOCK_ROOTS[id], slot), {direction = .Column, width = width, center = true})
	#partial switch v {
	case .Size:
		_ = ui.vslider(ctx, fmt.tprintf("Size##%s", tag), &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px), keys = slider_hint(app, "S, [ ]", .Size_Up), track = OFFHAND_TRACK, roll = false)
		if roll := island_roll(ctx); roll != 0 do app.brush.radius_px = clamp(app.brush.radius_px * math.pow(2, roll * ROLL_POINTS / ROLL_SIZE_DOUBLE), MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Strength:
		strength := brush_strength(app)
		_ = ui.vslider(ctx, fmt.tprintf("Strength##%s", tag), strength, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", strength^), keys = slider_hint(app, "U, Shift+[ ]", .Strength_Up), track = OFFHAND_TRACK, roll = false)
		if roll := island_roll(ctx); roll != 0 do strength^ = clamp(strength^ + roll * ROLL_POINTS / ROLL_STRENGTH_FULL, MIN_STRENGTH, 1)
	case:
		lo, hi, scale := value_range(v)
		x := value_get(app, v)
		if ui.vslider(ctx, fmt.tprintf("%s##%s %d", BRUSH_VALUE_NAMES[v], tag, slot), &x, lo, hi, scale, value_short(app, v), keys = command_hint(app, .Brush_Value, int(v)), track = OFFHAND_TRACK) && value_enabled(app, v) do value_set(app, v, x)
	}
	if ui.secondary(ctx) do value_menu_open(app, which, slot, v, ctx.last_rect, dock_side(app, id))
	ui.end(ctx)
}

// The degrees the pen's roll moves the slider just drawn this frame (ui.hover_roll), which
// its value follows by these figures rather than the kit's sweep, which its sliders are
// told to leave alone.
@(private = "file")
island_roll :: proc(ctx: ^ui.Context) -> f32 {
	return ui.hover_roll(ctx, ctx.last_id, ctx.hot == ctx.last_id)
}

// The ⋯ at a dock's end, under a hairline: opens the dock's menu (kit_dock_menu).
@(private = "file")
dock_more_button :: proc(app: ^App, id: Dock_Id, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	r := ui.place(ctx, {width, 1})
	ui.fill_rect(ctx, {r.x + 8, r.y, max(r.w - 16, 8), 1}, 0, t.border)
	open := bar_pop_showing(app, .Dock_Menu) && k.bar_pop.dock == id
	if ui.icon_button(ctx, fmt.tprintf("More##%s", DOCK_ROOTS[id]), ui.ICON_MORE, open, keys = "", width = width) do dock_menu_toggle(app, id, ctx.last_rect)
	dock_more_hold(app)
}

// A long press (or a right click) on a dock's ⋯, the widget just drawn, starts editing
// docks, as a home screen's icons start moving under a held finger.
dock_more_hold :: proc(app: ^App) {
	if app.kit.bars_edit || !ui.secondary(&app.kit.ctx) do return
	app.kit.bar_pop.open = false
	command_run(app, .Customise_Bars)
}

// Opens dock `id`'s menu beside `at`, or closes it when it shows already.
dock_menu_toggle :: proc(app: ^App, id: Dock_Id, at: ui.Rect) {
	k := &app.kit
	if bar_pop_showing(app, .Dock_Menu) && k.bar_pop.dock == id {
		k.bar_pop.open = false
		return
	}
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = .Dock_Menu, dock = id, at = at, side = dock_side(app, id)}
}

// A dock's menu, from its ⋯: add a button (the rail's cards from the Panels
// picker too), how many lines its buttons stand in, when they show their names, and
// whether the ⋯ stays (Arrange always shows it).
kit_dock_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p := &k.bar_pop
	id := p.dock
	d := &k.docks[id]
	which := dock_which(k, id)
	W :: 248
	if !ui.popover_begin(ctx, "dock menu", &p.open, p.at, p.side, {direction = .Column, gap = 4, padding = 10, width = W + 20}) do return
	defer ui.popover_end(ctx)
	ui.label(ctx, DOCK_TITLES[id], t.title_size, t.text, .Semibold)
	full := bar_count(app, which)^ >= bar_capacity(which)
	// The Library, on this dock's own kind of button (library_open_for).
	if ui.menu_item(ctx, "Add a button...", glyph = ui.ICON_PLUS, enabled = !full) {
		p.open = false
		bar_choose(app, {which = which, slot = len(bar_used(app, which)), add = true})
		return
	}
	ui.caption(ctx, "LINES")
	ui.begin(ctx, "dock menu lines", {direction = .Row, gap = 4, center = true})
	lines := dock_lines(k, id)
	if ui.icon_button(ctx, "Fewer lines", ui.ICON_MINIMISE, enabled = lines > 1) do d.more_lines -= 1
	r := ui.place(ctx, {W - 2 * t.target - 8, t.target})
	ui.text(ctx, fmt.tprintf("%d line%s", lines, "" if lines == 1 else "s"), r.x + r.w * 0.5 - ui.text_width(ctx, fmt.tprintf("%d line%s", lines, "" if lines == 1 else "s"), t.text_size) * 0.5, r.y + r.h * 0.5, t.text_size, t.text)
	if ui.icon_button(ctx, "More lines", ui.ICON_PLUS, enabled = lines < dock_lines_most(id)) do d.more_lines += 1
	ui.end(ctx)
	// The shelf's tiles always show their names under their icons.
	if id != .Shelf {
		ui.caption(ctx, "NAMES")
		names := [len(Dock_Names)]string{DOCK_NAMES_SHOWN[.Wide], DOCK_NAMES_SHOWN[.Always], DOCK_NAMES_SHOWN[.Off]}
		if picked := ui.tabs(ctx, "Names##dock menu", names[:], int(d.names), W / 3); picked >= 0 do d.names = Dock_Names(picked)
	}
	if !k.bars_edit && ui.menu_item(ctx, "Hide this button", glyph = ui.ICON_EYE_OFF) {
		d.more_off = true
		p.open = false
		report(app, nil, {}, "Edit docks shows the ⋯ again")
	} else if k.bars_edit && d.more_off && ui.menu_item(ctx, "Show this button", glyph = ui.ICON_EYE) {
		d.more_off = false
	}
	if !k.bars_edit {
		if command_menu_item(app, .Customise_Bars, label = "Edit docks") do p.open = false
		return
	}
	ui.divider(ctx, W, across = true)
	if ui.menu_item(ctx, "Put back as it comes", glyph = ui.ICON_UNDO, enabled = dock_resettable(k, id)) {
		p.open = false
		dock_reset(app, id)
	}
	if DOCK_HOME[id] == .Float && ui.menu_item(ctx, "Delete dock", glyph = ui.ICON_TRASH, tone = .Danger) {
		p.open = false
		user_dock_delete(app, int(id) - int(Dock_Id.Dock_1))
	}
}

// Settings > Bars: how many of the person's docks are in use, and New dock.
your_docks_rows :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, fmt.tprintf("YOUR DOCKS  %d OF %d", user_docks_used(k), USER_DOCKS))
	_ = command_button(app, .New_Dock, label = "New dock", variant = .Bordered, width = width)
	ui.paragraph(ctx, "A dock is a column of any commands and brush values, as the rail is. Its + adds one from the Library, a tap on a button moves or removes it, its head in the view carries it to the left or right edge or anywhere and a tap on the head opens its menu (lines, names, delete), and its curved corner gives it more or fewer lines. Each workspace keeps its own docks.")
}

// How tall a dock's grip is, in points: a strip at the dock's start that is easy to find
// with a finger without taking a button's room.
DOCK_GRIP_H :: 14

// Dock `id`'s grip, `width` wide, at its start: a faint pill that brightens under the
// pointer. A drag carries the dock to an edge or anywhere, as Arrange's head does (the
// outline, edge strips and lining up draw in kit_arrange_lens), and a tap opens its menu.
// It is there all the time, so moving a dock never needs Edit docks.
dock_grip :: proc(app: ^App, id: Dock_Id, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	a := ui.area(ctx, fmt.tprintf("Move %s##dock grip", DOCK_TITLES[id]), {width, DOCK_GRIP_H})
	carried, carrying := k.arrange.carry.?
	carrying &&= k.arrange.carrying && carried == id
	lit := a.hovered || a.held || carrying
	pill := ui.Rect{a.rect.x + a.rect.w * 0.5 - 11, a.rect.y + a.rect.h * 0.5 - 2, 22, 4}
	ui.fill_rect(ctx, pill, 2, ui.color_fade(t.text_secondary if lit else t.text_tertiary, 0.9 if lit else 0.35))
	ui.tip(ctx, a.id, a.rect, fmt.tprintf("Drag to move %s to an edge or anywhere; tap for its lines, names and reset", DOCK_TITLES[id]))
	was_carrying := carrying
	arrange_carry_follow(app, id, ui.prev_root_rect(ctx, DOCK_ROOTS[id]), a)
	if a.clicked && !was_carrying do dock_menu_toggle(app, id, a.rect)
}
