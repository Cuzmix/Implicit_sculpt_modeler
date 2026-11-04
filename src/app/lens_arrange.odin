package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../ui"

// Every dock carries a faint grip (dock_grip) and a faint corner, so moving or sizing one never
// needs a mode. Edit docks (Arrange), or Edit buttons in one dock's menu for that dock alone
// (k.edit_dock, dock_editing): each dock edited shows its outline, rings on its buttons and
// its +, a tap on its grip opens its menu (Lines, Names, Put back as it comes, Delete for
// one of the person's), and a curved corner on the side facing the
// view's middle that a drag turns into more or fewer lines, a whole button at a time. A
// floating dock carried near another lines up with it (soft alignment), a faint line
// showing which edge. The top bar's space tabs give way to what editing needs (New
// dock, Mirror, Reset layout, Done). The ringed buttons of every dock
// change what each holds, and its + opens the Library to add one. Which bars show, the
// panels' places and the dial's sectors are Settings' (Bars and Wheel).

// Arrange's own state in Kit_State: how many
// resets ran (for the exit stats), and the dock being carried by its head: its outline at
// the press, where the press was, and whether it went past the slop (until then the press
// is a tap that opens the dock's menu).
Arrange_State :: struct {
	resets:      int,
	carry:       Maybe(Dock_Id),
	carry_from:  ui.Rect,
	carry_press: [2]f32,
	carrying:    bool,
	// The grip that took the press, so another dock's grip, which also follows each frame,
	// leaves the carry alone.
	carry_by:    ui.Id,
	carries:     int, // docks let go (for the exit stats)
	// The dock whose corner is dragged, its lines at the press and where the press was,
	// and how many drags changed a dock's lines (for the exit stats).
	resize:       Maybe(Dock_Id),
	resize_lines: int,
	resize_press: [2]f32,
	resizes:      int,
	// Floating drops that lined up with a neighbour (for the exit stats).
	aligns:       int,
	// Whether Arrange was on last frame, and how many times it has opened, so its outlines
	// draw in afresh each time (Arrange outlines motion).
	was_on:      bool,
	openings:    int,
	// The person's docks made and deleted (for the exit stats).
	docks_made:    int,
	docks_deleted: int,
}

// Whether Put back as it comes has anything to put back for dock `d`: the brush bar only
// its place and looks, its items being the person's; one of the person's docks its
// buttons.
dock_resettable :: proc(k: ^Kit_State, d: Dock_Id) -> bool {
	#partial switch d {
	case .Offhand: return k.docks[.Offhand] != {}
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4: return k.dock_lists[int(d) - int(Dock_Id.Dock_1)].count > 0
	}
	return true
}

// Puts dock `d` back as a fresh install has it: the brush bar's place, lines and names;
// the shelf's page shown and its place; the rail's buttons, place, lines and names; one
// of the person's docks is emptied, keeping its place and looks (a dock comes empty).
dock_reset :: proc(app: ^App, d: Dock_Id) {
	k := &app.kit
	k.arrange.resets += 1
	switch d {
	case .Offhand:
		k.docks[.Offhand] = {}
	case .Shelf:
		// The page shown gets its own tiles back (an added one comes empty) and a built-in
		// one its own name; an added page keeps the name it was given.
		k.shelf.lists[k.shelf.page] = shelf_fresh(k.shelf.page)
		if k.shelf.page < SHELF_EXTRA_FIRST do k.shelf.names[k.shelf.page] = {}
		k.docks[.Shelf] = {}
	case .Rail:
		bar_list_k(k, .View_Rail)^ = bar_fresh(.View_Rail)
		k.docks[.Rail] = {}
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		i := int(d) - int(Dock_Id.Dock_1)
		k.dock_lists[i] = bar_fresh(user_dock_which(i))
		report(app, nil, {}, "Emptied %s", DOCK_TITLES[d])
		return
	}
	report(app, nil, {}, "%s is as it comes again", DOCK_TITLES[d])
}

// Puts the dial back as a fresh install has it: every space's sectors, its size, turn and
// place.
dial_reset :: proc(app: ^App) {
	k := &app.kit
	k.dials, k.wheel_size, k.wheel_turn, k.wheel_offset = DIAL_DEFAULTS, .Medium, 0, {}
	k.arrange.resets += 1
	report(app, nil, {}, "The dial is as it comes again")
}

// The top bar's controls while editing docks, in place of the space tabs: what is being
// edited, New dock, Mirror, Reset layout and Done. Returns their width;
// arrange_top_width says it before they are drawn.
arrange_top_controls :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.begin(ctx, "arrange top bar", {direction = .Row, gap = 6, center = true})
	start := ctx.last_rect.x
	title := arrange_title(app)
	r := ui.place(ctx, {ui.text_width(ctx, title, t.text_size, .Semibold) + 18, t.target})
	ui.text(ctx, title, r.x, r.y + r.h * 0.5, t.text_size, t.accent, .Semibold)
	if k.layouts.modified do ui.fill_circle(ctx, {r.x + r.w - 6, r.y + r.h * 0.5}, 3, t.warning)
	labels := ARRANGE_TOP_LABELS
	_ = command_button(app, .New_Dock, label = "New dock", variant = .Bordered, width = arrange_button_width(ctx, labels[0]))
	_ = command_button(app, .Left_Handed, label = "Mirror", variant = .Bordered, width = arrange_button_width(ctx, labels[1]))
	_ = command_button(app, .Layout_Reset, label = "Reset layout", variant = .Bordered, width = arrange_button_width(ctx, labels[2]))
	if ui.button(ctx, "Done##arrange", .Solid, .Accent, width = arrange_button_width(ctx, labels[3])) do k.bars_edit = false
	end := ctx.last_rect
	ui.end(ctx)
	return end.x + end.w - start
}

@(private = "file")
ARRANGE_TOP_LABELS := [4]string{"New dock", "Mirror", "Reset layout", "Done"}

@(private = "file")
arrange_title :: proc(app: ^App) -> string {
	k := &app.kit
	if one, only := k.edit_dock.?; only do return fmt.tprintf("Editing %s", DOCK_TITLES[one])
	return fmt.tprintf("Editing %s", SPACE_NAMES[k.spaces.current])
}

@(private = "file")
arrange_button_width :: proc(ctx: ^ui.Context, label: string) -> f32 {
	return ui.text_width(ctx, label, ctx.theme.text_size, .Semibold) + 28
}

// How wide arrange_top_controls will be.
arrange_top_width :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	w := ui.text_width(ctx, arrange_title(app), t.text_size, .Semibold) + 18
	for l in ARRANGE_TOP_LABELS do w += 6 + arrange_button_width(ctx, l)
	return w
}

// How long an outline takes to draw in as Arrange opens, and how long after the dock before
// it each one starts.
ARRANGE_DRAW_TIME :: 0.22
ARRANGE_DRAW_STAGGER :: 0.025

// Every shown dock's resize corner, and the outline, edge strips and lining up of a dock
// carried by its grip. While editing docks each dock also shows its outline, and its corner
// is in the accent rather than faint.
kit_arrange_lens :: proc(app: ^App) {
	k := &app.kit
	if !k.bars_edit do k.arrange.was_on = false
	else {
		if !k.arrange.was_on do k.arrange.openings += 1
		k.arrange.was_on = true
	}
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	// A carry whose dock went away under it (hidden, or a layout put in mid-drag) ends with
	// the press, as nothing else would see the release.
	if c, ok := k.arrange.carry.?; ok && !dock_shown(k, c) && .Left not_in ctx.input.down do k.arrange.carry, k.arrange.carrying = nil, false
	carried, carrying := k.arrange.carry.?
	carrying &&= k.arrange.carrying
	align_lines: [2]Align_Line
	for d in Dock_Id {
		if !dock_shown(k, d) do continue
		r := ui.prev_rect(ctx, DOCK_ROOTS[d])
		if r.w <= 0 do continue
		box := ui.Rect{r.x - 4, r.y - 4, r.w + 8, r.h + 8}
		// A dock being carried shows its outline under the pointer, lined up with its
		// neighbours where it would float, the dock staying put until it is let go.
		if carrying && d == carried {
			moved, lines := arrange_carry_box(app, d, ctx.input.mouse)
			align_lines = lines
			box = {moved.x - 4, moved.y - 4, moved.w + 8, moved.h + 8}
			ui.stroke_rect(ctx, box, t.radius_large + 4, t.accent, 2)
			continue
		}
		// The corner faces the view's middle: a column's on its side toward it, a row's on
		// its end, toward the middle up or down.
		end_half := !dock_row(k, d) && box.x + box.w * 0.5 > area.x + area.w * 0.5
		if !dock_editing(k, d) {
			arrange_resize_corner(app, d, box, !end_half, faint = true)
			continue
		}
		// Each outline draws in as editing starts, one dock a moment after another: it fades
		// in and settles from a touch larger onto its dock.
		mark := ui.vertex_mark(ctx)
		draw := ui.tween_from(ctx, ui.salt(ui.hash_under(0, "arrange outline"), u64(d) + 64 * u64(k.arrange.openings)), 0, 1, ARRANGE_DRAW_TIME, .Linear, ARRANGE_DRAW_STAGGER * f32(d), motion_class(.Arrange))
		menu := bar_pop_showing(app, .Dock_Menu) && k.bar_pop.dock == d
		ui.stroke_rect(ctx, box, t.radius_large + 4, t.accent if menu else ui.color_fade(t.accent, 0.5), 2 if menu else 1)
		arrange_resize_corner(app, d, box, !end_half)
		if draw < 1 {
			e := ui.ease(.Out_Cubic, draw)
			ui.transform_since(ctx, mark, e, 1.03 - 0.03 * e, {box.x + box.w * 0.5, box.y + box.h * 0.5})
		}
	}
	if carrying {
		arrange_drop_edges(app, carried)
		for l in align_lines do if l.shown do ui.line(ctx, l.a, l.b, ui.color_fade(t.accent, 0.55), 1)
	}
}

// Where carried dock `b`'s outline (its rect at the press, moved with the pointer `p`)
// stands: lined up with its neighbours where the drop would float (dock_align), as it is
// where it would stand on an edge.
@(private = "file")
arrange_carry_box :: proc(app: ^App, b: Dock_Id, p: [2]f32) -> (box: ui.Rect, lines: [2]Align_Line) {
	s := &app.kit.arrange
	box = {s.carry_from.x + p.x - s.carry_press.x, s.carry_from.y + p.y - s.carry_press.y, s.carry_from.w, s.carry_from.h}
	if dock_drop(app, b, box, p, 0).edge != .Float do return
	return dock_align(app, b, box)
}

// Follows a press on dock `b`'s head `a` (its outline `r`): past the slop it carries the
// dock, and let go it puts the dock where it was dropped (dock_drop), lined up with its
// neighbours where it floats. A dock's grip (dock_grip) carries it this way.
arrange_carry_follow :: proc(app: ^App, b: Dock_Id, r: ui.Rect, a: ui.Area) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.arrange
	if a.pressed {
		s.carry, s.carry_from, s.carry_press, s.carrying, s.carry_by = b, r, a.mouse, false, a.id
		return
	}
	carried, ok := s.carry.?
	if !ok || carried != b || s.carry_by != a.id do return
	if a.held {
		d := a.mouse - s.carry_press
		if !s.carrying && d.x * d.x + d.y * d.y > ctx.theme.slop * ctx.theme.slop {
			s.carrying = true
			ui.long_cancel(ctx)
			k.bar_pop.open = false
		}
		return
	}
	if s.carrying {
		box, lines := arrange_carry_box(app, b, a.mouse)
		if lines[0].shown || lines[1].shown do s.aligns += 1
		default_top := brush_bar_top(app) if b == .Offhand else TOP_BAR_H + 6
		dock_place_set(app, b, dock_drop(app, b, box, a.mouse, default_top))
		dock_glide_from(app, b, box)
		s.carries += 1
	}
	s.carry, s.carrying = nil, false
}

// The size of a dock's resize corner, in points, and how far it stands out of the outline.
DOCK_CORNER :: 22

// Dock `d`'s resize corner on its outline `box`: on the side facing the view's middle, away
// from its head (`right` on the screen's right; a left dock's right, a right dock's left;
// the shelf's top end), a quarter curve following the
// outline's round corner, `faint` outside Edit docks until the pointer is on it. A drag across the dock's lines adds or removes a whole line per
// line's width (per tile row on the shelf), 1 to the dock's most.
@(private = "file")
arrange_resize_corner :: proc(app: ^App, d: Dock_Id, box: ui.Rect, right: bool, faint := false) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	// A row's corner stands on its edge facing the middle: the top of a bottom row, the
	// foot of a top one; its drag adds rows toward the middle.
	row := dock_row(k, d)
	up := row && dock_edge(k, d) != .Top
	cx := box.x + box.w - DOCK_CORNER + 6 if right else box.x - 6
	cy := box.y - 6 if up else box.y + box.h - DOCK_CORNER + 6
	ui.begin_at(ctx, fmt.tprintf("dock corner %v", d), {cx, cy}, {direction = .Row})
	a := ui.area(ctx, fmt.tprintf("Resize %s##dock corner", DOCK_TITLES[d]), {DOCK_CORNER, DOCK_CORNER})
	ui.end(ctx)
	s := &k.arrange
	lines := dock_lines(k, d)
	if a.pressed {
		s.resize, s.resize_lines, s.resize_press = d, lines, a.mouse
		k.bar_pop.open = false
	}
	active := false
	if dragged, ok := s.resize.?; ok && dragged == d {
		active = a.held
		// A line is a column's width across a side dock and a row of tiles up the shelf.
		cell := max(box.w - 14, t.target) / f32(lines) if !row else max(box.h - 14, t.target) / f32(lines)
		delta := (a.mouse.x - s.resize_press.x) * (1 if right else -1)
		if row do delta = (s.resize_press.y - a.mouse.y) if up else (a.mouse.y - s.resize_press.y)
		want := clamp(s.resize_lines + int(math.round(delta / cell)), 1, dock_lines_most(d))
		if a.held && want != lines do k.docks[d].more_lines = u8(want - 1)
		if !a.held {
			if dock_lines(k, d) != s.resize_lines do s.resizes += 1
			s.resize = nil
		}
	}
	// The curve: a quarter circle on the outline's corner, thicker while held or hovered.
	rad := t.radius_large + 4
	o := [2]f32{box.x + box.w - rad if right else box.x + rad, box.y + rad if up else box.y + box.h - rad}
	pts: [9][2]f32
	for i in 0 ..< len(pts) {
		ang := f32(i) / f32(len(pts) - 1) * math.PI * 0.5
		dx, dy := math.cos(ang) * rad, math.sin(ang) * rad
		pts[i] = {o.x + (dx if right else -dx), o.y + (-dy if up else dy)}
	}
	lit := active || a.hovered
	ink := t.accent if !faint || lit else ui.color_fade(t.text_tertiary, 0.35)
	ui.polyline(ctx, pts[:], ink, 3.5 if lit else (2 if faint else 2.5))
	ui.tip(ctx, a.id, a.rect, fmt.tprintf("Drag to give %s more or fewer %s", DOCK_TITLES[d], "rows" if row else "lines"))
}

// While dock `b` is carried: the edges it may go on as strips down the window's sides and
// along the top (under the top bar) and the bottom, the one the pointer is nearest lit.
@(private = "file")
arrange_drop_edges :: proc(app: ^App, b: Dock_Id) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	m := ctx.input.mouse
	near := dock_drop(app, b, {m.x, m.y, 1, 1}, m, -1e9).edge
	lo, hi := shelf_across(app)
	x0, x1 := area.x + lo, area.x + hi
	if ctx.mirror do x0, x1 = area.x + area.w - hi, area.x + area.w - lo
	for edge in dock_edges(b) {
		strip: ui.Rect
		switch edge {
		case .Left, .Right:
			top, bottom := dock_room(app, edge)
			screen_left := (edge == .Left) != ctx.mirror
			strip = {area.x + 4 if screen_left else area.x + area.w - 10, area.y + top, 6, bottom - top}
		case .Top:    strip = {x0, area.y + TOP_BAR_H + 2, x1 - x0, 6}
		case .Bottom: strip = {x0, area.y + area.h - 8, x1 - x0, 6}
		case .Default, .Float: continue
		}
		ui.fill_rect(ctx, strip, 3, t.accent if near == edge || (near == .Default && edge == DOCK_HOME[b]) else ui.color_fade(t.accent, 0.35))
	}
}

// What each sector of the current space's dial does (Settings > Wheel), and its reset.
dial_sector_rows :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	space := k.spaces.current
	dial := dial_of(k)
	ui.caption(ctx, fmt.tprintf("%s DIAL SECTORS (CLOCKWISE FROM THE TOP)", strings.to_upper(SPACE_NAMES[space], context.temp_allocator)))
	for place, i in DIAL_PLACES {
		ui.begin(ctx, fmt.tprintf("dial sector %d", i), {direction = .Row, center = true, gap = 8, width = width})
		r := ui.place(ctx, {110, t.target})
		ui.text(ctx, place, r.x, r.y + r.h * 0.5, t.text_size, t.text)
		options := make([dynamic]string, 0, 8, context.temp_allocator)
		for m in Modifier do append(&options, modifier_name(app, m))
		append(&options, "Brush pie")
		chosen := 0
		switch v in dial[i] {
		case Modifier: chosen = int(v)
		case Bar_Slot:
			chosen = len(Modifier)
			if v.id != .Brush_Pie {
				append(&options, bar_label(app, v))
				chosen = len(options) - 1
			}
		}
		append(&options, "Choose a command...")
		picked := ui.select(ctx, fmt.tprintf("%s sector##dial", place), options[:], chosen, width = width - 118)
		switch {
		case picked < 0 || picked == chosen:
		case picked < len(Modifier):
			dial[i] = Modifier(picked)
		case picked == len(Modifier):
			dial[i] = Bar_Slot{.Brush_Pie, 0}
		case picked == len(options) - 1:
			palette_open(app)
			k.palette_for = Dial_Pick(i)
		}
		ui.end(ctx)
	}
	// Smooth and Mask have no gesture, so a Sculpt dial without them leaves only the keys;
	// the other spaces' dials hold what those spaces use instead.
	missing := make([dynamic]string, 0, 2, context.temp_allocator)
	if space == .Sculpt do for m in ([]Modifier{.Smooth, .Mask}) do if !dial_has(k, m) do append(&missing, MODIFIER_NAMES[m])
	if len(missing) > 0 {
		ui.paragraph(ctx, fmt.tprintf("No sector holds %s now: on a tablet without a keyboard nothing else does.", strings.join(missing[:], " or ", context.temp_allocator)))
	}
	if ui.button(ctx, "Put the dial back as it comes##sectors", .Bordered, width = width) do dial_reset(app)
}
