package main

import "core:fmt"
import "core:strings"

import "../ui"

// Arrange's own controls (round 2 of the mockups, screen custom2): the top bar's workspace pill
// gives way to what arranging needs (Reset zone, Reset workspace, Save as new, Done);
// every zone of the layout shows its outline and a name tag, a tap on which picks it for
// Reset zone; and the Library, a sheet over the view, holds the panels' places and the
// bars' Show chips and the dial's sectors. The ringed
// buttons and + tiles of Customise bars still change what each bar holds.

// The zones Arrange names, as their tags call them.
Arrange_Zone :: enum u8 {
	Offhand, // the size and strength sliders
	Dial, // the modifier wheel
	Shelf, // the brushes along the bottom
	Panels, // the stack of cards at the right
	Rail, // the view rail down the pen side
	// The person's own docks (user_docks.odin), while they are in use.
	Dock_1,
	Dock_2,
	Dock_3,
	Dock_4,
}

@(rodata)
ARRANGE_ZONE_NAMES := [Arrange_Zone]string {
	.Offhand = "Off-hand",
	.Dial    = "Dial",
	.Shelf   = "Shelf",
	.Panels  = "Panels",
	.Rail    = "Rail",
	.Dock_1  = "Dock 1",
	.Dock_2  = "Dock 2",
	.Dock_3  = "Dock 3",
	.Dock_4  = "Dock 4",
}

// The Library's tabs.
Library_Tab :: enum u8 {
	Panels,
	Dial,
	Docks,
}

// Arrange's own state in Kit_State: the zone picked for Reset zone, whether the Library
// is put away, its tab, how many resets ran (for the exit stats), and the bar being carried
// by its tag: its outline at the press, where the press was, and whether it went past the
// slop (until then the press is a tap that picks the zone).
Arrange_State :: struct {
	picked:      Maybe(Arrange_Zone),
	library_off: bool,
	tab:         Library_Tab,
	resets:      int,
	carry:       Maybe(Place_Bar),
	carry_from:  ui.Rect,
	carry_press: [2]f32,
	carrying:    bool,
	carries:     int, // bars let go (for the exit stats)
	// The chip bar's section being carried (chip_islands.odin), which shares the bar's
	// carry_from, carry_press and carrying, and how many were let go.
	chip_carry:   Maybe(Chip_Section),
	chip_carries: int,
	// Whether Arrange was on last frame, and how many times it has opened, so its outlines
	// draw in afresh each time (Arrange outlines motion).
	was_on:      bool,
	openings:    int,
	// The person's docks made and deleted (for the exit stats).
	docks_made:    int,
	docks_deleted: int,
}

// The bar a zone's tag carries, if it carries one.
arrange_zone_bar :: proc(z: Arrange_Zone) -> (Place_Bar, bool) {
	#partial switch z {
	case .Offhand: return .Offhand, true
	case .Rail:    return .Rail, true
	case .Shelf:   return .Shelf, true
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4: return Place_Bar(int(Place_Bar.Dock_1) + int(z) - int(Arrange_Zone.Dock_1)), true
	}
	return {}, false
}

// The Library's width, in points.
LIBRARY_W :: 540

// Where zone `z` was drawn last frame, in points; empty while it is not shown.
arrange_zone_rect :: proc(app: ^App, z: Arrange_Zone) -> ui.Rect {
	k := &app.kit
	ctx := &k.ctx
	switch z {
	case .Offhand: return ui.prev_rect(ctx, "brush bar")
	case .Dial:
		r := &app.rail
		if r.outer <= 0 do return {}
		o := r.outer / k.scale
		c := r.center / k.scale
		return {c.x - o * 0.5, c.y - o * 0.5, o, o}
	case .Shelf:  return ui.prev_rect(ctx, "dock")
	case .Panels:
		if r := k.panels.rect[.Right]; r.w > 0 do return r
		return k.panels.rect[.Left]
	case .Rail:   return ui.prev_rect(ctx, "view bar")
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		b, _ := arrange_zone_bar(z)
		if !bar_place_shown(k, b) do return {}
		return ui.prev_rect(ctx, PLACE_BAR_ROOTS[b])
	}
	return {}
}

// The zone's tag: its name, with the shelf's page and the rail's count.
arrange_zone_tag :: proc(app: ^App, z: Arrange_Zone) -> string {
	k := &app.kit
	#partial switch z {
	case .Shelf:
		// Counted among the pages the space shows.
		first, last := shelf_pages_of(k.spaces.current)
		return fmt.tprintf("Shelf · page %d of %d", int(k.shelf.page) - int(first) + 1, int(last) - int(first) + 1)
	case .Rail:  return fmt.tprintf("Rail · %d", len(bar_used(app, .View_Rail)))
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		i := int(z) - int(Arrange_Zone.Dock_1)
		return fmt.tprintf("%s · %d", USER_DOCK_NAMES[i], k.docks[i].list.count)
	}
	return ARRANGE_ZONE_NAMES[z]
}

// Whether Reset zone has anything to put back for `z`: the off-hand island only its
// place, its items being the person's.
arrange_zone_resettable :: proc(k: ^Kit_State, z: Arrange_Zone) -> bool {
	#partial switch z {
	case .Offhand: return k.places[.Offhand].edge != .Default
	// A dock's reset empties it, keeping its place and how its buttons show.
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4: return k.docks[int(z) - int(Arrange_Zone.Dock_1)].list.count > 0
	}
	return true
}

// Puts zone `z` back as a fresh install has it: the island's place; the dial's sectors,
// size, turn and place; the shelf's page shown; the stack of cards; the rail's buttons and
// place; a dock's buttons (a dock comes empty).
arrange_zone_reset :: proc(app: ^App, z: Arrange_Zone) {
	k := &app.kit
	switch z {
	case .Offhand:
		k.places[.Offhand] = {}
	case .Dial:
		k.dials, k.wheel_size, k.wheel_turn, k.wheel_offset = DIAL_DEFAULTS, .Medium, 0, {}
	case .Shelf:
		k.shelf.lists[k.shelf.page] = shelf_fresh(k.shelf.page)
		k.tools = bar_fresh(.Tools)
		k.places[.Shelf] = {}
	case .Panels:
		stack_default(k)
	case .Rail:
		bar_list_k(k, .View_Rail)^ = bar_fresh(.View_Rail)
		k.places[.Rail] = {}
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		i := int(z) - int(Arrange_Zone.Dock_1)
		k.docks[i].list = bar_fresh(user_dock_which(i))
		k.arrange.resets += 1
		report(app, nil, {}, "Emptied %s", USER_DOCK_NAMES[i])
		return
	}
	k.arrange.resets += 1
	report(app, nil, {}, "%s is as it comes again", ARRANGE_ZONE_NAMES[z])
}

// The top bar's controls while arranging, in place of the workspace pill: what is being
// arranged, the Library, Reset zone, Reset workspace, Save as new and Done. Returns their
// width; arrange_top_width says it before they are drawn.
arrange_top_controls :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	w := &k.workspaces
	ui.begin(ctx, "arrange top bar", {direction = .Row, gap = 6, center = true})
	start := ctx.last_rect.x
	title := arrange_title(app)
	r := ui.place(ctx, {ui.text_width(ctx, title, t.text_size, .Semibold) + 18, t.target})
	ui.text(ctx, title, r.x, r.y + r.h * 0.5, t.text_size, t.accent, .Semibold)
	if w.modified do ui.fill_circle(ctx, {r.x + r.w - 6, r.y + r.h * 0.5}, 3, t.warning)
	labels := ARRANGE_TOP_LABELS
	if ui.toggle_button(ctx, "Library##arrange", !k.arrange.library_off, arrange_button_width(ctx, labels[0]), tooltip = "Panels' places, the bars to show and the dial's sectors") do k.arrange.library_off = !k.arrange.library_off
	picked, has := k.arrange.picked.?
	if ui.button(ctx, "Reset zone##arrange", .Bordered, width = arrange_button_width(ctx, labels[1]), enabled = has && arrange_zone_resettable(k, picked)) do arrange_zone_reset(app, picked)
	_ = command_button(app, .Workspace_Revert, label = "Reset workspace", variant = .Bordered, width = arrange_button_width(ctx, labels[2]))
	_ = command_button(app, .Workspace_Save_As, label = "Save as new", variant = .Bordered, width = arrange_button_width(ctx, labels[3]))
	if ui.button(ctx, "Done##arrange", .Solid, .Accent, width = arrange_button_width(ctx, labels[4])) do k.bars_edit = false
	end := ctx.last_rect
	ui.end(ctx)
	return end.x + end.w - start
}

@(private = "file")
ARRANGE_TOP_LABELS := [5]string{"Library", "Reset zone", "Reset workspace", "Save as new", "Done"}

@(private = "file")
arrange_title :: proc(app: ^App) -> string {
	k := &app.kit
	name := workspace_name(k, k.workspaces.current) if len(k.workspaces.list) > 0 else "Sculpt"
	return fmt.tprintf("Arranging %s", name)
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

// How long an outline takes to draw in as Arrange opens, and how long after the zone before
// it each one starts.
ARRANGE_DRAW_TIME :: 0.22
ARRANGE_DRAW_STAGGER :: 0.025

// While arranging: each zone's outline and name tag, then the Library. Leaving
// Arrange forgets the zone picked and brings the Library back for the next time.
kit_arrange_lens :: proc(app: ^App) {
	k := &app.kit
	if !k.bars_edit {
		k.arrange.picked, k.arrange.library_off = nil, false
		k.arrange.carry, k.arrange.carrying = nil, false
		k.arrange.chip_carry = nil
		k.arrange.was_on = false
		return
	}
	if !k.arrange.was_on do k.arrange.openings += 1
	k.arrange.was_on = true
	ctx := &k.ctx
	t := ctx.theme
	top := kit_top() - 12
	carried, carrying := k.arrange.carry.?
	carrying &&= k.arrange.carrying
	for z in Arrange_Zone {
		r := arrange_zone_rect(app, z)
		if r.w <= 0 do continue
		picked := k.arrange.picked == z
		bar, carries := arrange_zone_bar(z)
		box := ui.Rect{r.x - 4, r.y - 4, r.w + 8, r.h + 8}
		// A bar being carried shows its outline under the pointer, the bar staying put
		// until it is let go.
		if carrying && carries && bar == carried {
			from := k.arrange.carry_from
			m := ctx.input.mouse
			box = {from.x - 4 + m.x - k.arrange.carry_press.x, from.y - 4 + m.y - k.arrange.carry_press.y, from.w + 8, from.h + 8}
		}
		// Each outline draws in as Arrange opens, one zone a moment after another: it fades
		// in and settles from a touch larger onto its bar.
		mark := ui.vertex_mark(ctx)
		draw := ui.tween_from(ctx, ui.salt(ui.hash_under(0, "arrange outline"), u64(z) + 64 * u64(k.arrange.openings)), 0, 1, ARRANGE_DRAW_TIME, .Linear, ARRANGE_DRAW_STAGGER * f32(z), motion_class(.Arrange))
		ui.stroke_rect(ctx, box, t.radius_large + 4, t.accent if picked else ui.color_fade(t.accent, 0.5), 2 if picked else 1)
		// The tag at the outline's top left, kept under the top bar. On a bar that has a
		// place it is the bar's grip too: a drag past the slop carries the bar.
		tag := arrange_zone_tag(app, z)
		tw := ui.text_width(ctx, tag, t.small_size, .Semibold) + 16
		at := [2]f32{box.x + 6, max(box.y - 11, top)}
		ui.begin_at(ctx, fmt.tprintf("arrange tag %v", z), at, {direction = .Row})
		a := ui.area(ctx, fmt.tprintf("%s##arrange tag", ARRANGE_ZONE_NAMES[z]), {tw, 22}, drag = carries)
		ui.fill_rect(ctx, a.rect, t.radius_medium, t.accent if picked else t.surface_raised)
		ui.stroke_rect(ctx, a.rect, t.radius_medium, ui.color_fade(t.accent, 0.7), 1)
		ui.text(ctx, tag, a.rect.x + 8, a.rect.y + a.rect.h * 0.5, t.small_size, t.frame if picked else t.accent, .Semibold)
		hint := fmt.tprintf("Drag to move %s to an edge or anywhere; tap to pick it for Reset zone", ARRANGE_ZONE_NAMES[z]) if carries else fmt.tprintf("Pick %s for Reset zone", ARRANGE_ZONE_NAMES[z])
		ui.tip(ctx, a.id, a.rect, hint)
		was_carrying := carrying && carries && bar == carried
		if carries do arrange_carry_follow(app, bar, r, a)
		if a.clicked && !was_carrying do k.arrange.picked = nil if picked else z
		ui.end(ctx)
		if draw < 1 {
			e := ui.ease(.Out_Cubic, draw)
			ui.transform_since(ctx, mark, e, 1.03 - 0.03 * e, {box.x + box.w * 0.5, box.y + box.h * 0.5})
		}
	}
	if carrying do arrange_drop_edges(app, carried)
	chips := arrange_chip_sections(app)
	// The Library steps aside while a bar or a section is carried, so the view under it
	// takes the drop.
	if !carrying && !chips do kit_library(app)
}

// Follows a press on bar `b`'s tag `a` (its outline `r`): past the slop it carries the
// bar, and let go it puts the bar where it was dropped (bar_place_drop).
@(private = "file")
arrange_carry_follow :: proc(app: ^App, b: Place_Bar, r: ui.Rect, a: ui.Area) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.arrange
	if a.pressed {
		s.chip_carry = nil
		s.carry, s.carry_from, s.carry_press, s.carrying = b, r, a.mouse, false
		return
	}
	carried, ok := s.carry.?
	if !ok || carried != b do return
	if a.held {
		d := a.mouse - s.carry_press
		if !s.carrying && d.x * d.x + d.y * d.y > ctx.theme.slop * ctx.theme.slop {
			s.carrying = true
			ui.long_cancel(ctx)
		}
		return
	}
	if s.carrying {
		box := ui.Rect{s.carry_from.x + a.mouse.x - s.carry_press.x, s.carry_from.y + a.mouse.y - s.carry_press.y, s.carry_from.w, s.carry_from.h}
		default_top := brush_bar_top(app) if b == .Offhand else TOP_BAR_H + 6
		bar_place_set(app, b, bar_place_drop(app, b, box, a.mouse, default_top))
		s.carries += 1
	}
	s.carry, s.carrying = nil, false
}

// While bar `b` is carried: the edges it may go on as strips down the window's sides (or
// along its bottom for the shelf), the one the pointer is near lit.
@(private = "file")
arrange_drop_edges :: proc(app: ^App, b: Place_Bar) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	m := ctx.input.mouse
	if b == .Shelf {
		lo, hi := shelf_across(app)
		x0, x1 := area.x + lo, area.x + hi
		if ctx.mirror do x0, x1 = area.x + area.w - hi, area.x + area.w - lo
		near := m.y > area.y + area.h - PLACE_REACH
		ui.fill_rect(ctx, {x0, area.y + area.h - 8, x1 - x0, 6}, 3, t.accent if near else ui.color_fade(t.accent, 0.35))
		return
	}
	for edge in ([]Bar_Edge{.Left, .Right}) {
		lo, hi := bar_place_room(app, edge)
		screen_left := (edge == .Left) != ctx.mirror
		x := area.x + 4 if screen_left else area.x + area.w - 10
		near := m.x < area.x + PLACE_REACH if screen_left else m.x > area.x + area.w - PLACE_REACH
		strip := ui.Rect{x, area.y + lo, 6, hi - lo}
		ui.fill_rect(ctx, strip, 3, t.accent if near else ui.color_fade(t.accent, 0.35))
	}
}

// The Library: a sheet over the view, left of the middle, with Panels and Dial.
@(private = "file")
kit_library :: proc(app: ^App) {
	k := &app.kit
	if k.arrange.library_off do return
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	width := min(f32(LIBRARY_W), area.w - 32)
	ui.begin_anchored(ctx, "arrange library", .Center, .Start, {-min(area.w * 0.14, 200), kit_top() + 24}, {direction = .Column, gap = 8, padding = 14, width = width, radius = t.radius_large, background = .Raised})
	inner := width - 28
	ui.begin(ctx, "library head", {direction = .Row, center = true, width = inner})
	head := ui.place(ctx, {inner - t.target, t.target})
	ui.icon(ctx, ui.ICON_GRID, {head.x + 10, head.y + head.h * 0.5}, t.icon_size, t.text_secondary)
	ui.text(ctx, "Library", head.x + 28, head.y + head.h * 0.5, t.heading_size, t.text, .Semibold)
	if ui.icon_button(ctx, "Put the Library away", ui.ICON_CLOSE) do k.arrange.library_off = true
	ui.end(ctx)
	names := [len(Library_Tab)]string{"Panels", "Dial", "Docks"}
	if picked := ui.tabs(ctx, "Library tab", names[:], int(k.arrange.tab), item_width = 110); picked >= 0 do k.arrange.tab = Library_Tab(picked)
	switch k.arrange.tab {
	case .Panels:
		arrange_show_chips(app)
		arrange_panel_rows(app)
	case .Dial:
		library_dial(app, inner)
	case .Docks:
		library_docks(app, inner)
		library_chip_sections(app, inner)
	}
	ui.end(ctx)
}

// Library > Dial: what each sector of the current space's dial does, then the dial's
// size, what its sectors show, and whether it stays in clean view (those three are every
// space's).
@(private = "file")
library_dial :: proc(app: ^App, width: f32) {
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
				append(&options, bar_label(v))
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
	ui.caption(ctx, "DIAL")
	ui.label(ctx, "Size")
	sizes: [len(Wheel_Size)]string
	for name, s in WHEEL_SIZE_NAMES do sizes[s] = name
	if picked := ui.tabs(ctx, "Dial size", sizes[:], int(k.wheel_size)); picked >= 0 do k.wheel_size = Wheel_Size(picked)
	ui.label(ctx, "Sectors show")
	labels := [len(Wheel_Labels)]string{"Icons", "Icons and names", "Names"}
	if picked := ui.tabs(ctx, "Dial sectors show", labels[:], int(k.wheel_labels)); picked >= 0 do k.wheel_labels = Wheel_Labels(picked)
	_ = ui.switch_row(ctx, "Keep the dial in clean view##library", &k.clean_dial)
}
