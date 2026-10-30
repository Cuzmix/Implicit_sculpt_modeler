package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// Lens's panels (the Lens UI direction, P0 step 1, and round 3's PR 9e): the panel stack,
// Stats, History, the Objects card, the Colors card and the thumbnail. The stack, which holds
// every card and section, docks on the right or the left under the top bar beside a side
// bar, or floats as one window round its cards; the others float as windows and cards. A
// docked stack takes its column's height and scrolls when its cards are taller. Folded, a
// floating panel keeps its header. The two columns that once held any panel went with PR
// 9e: Blender's and Photoshop's panels are one kind whatever they hold, and one place for
// the palettes keeps a layout from breaking, as the Lens report argues.

// The sides the stack docks on, in layout terms: the brush bar's (the left, unless the
// layout is left-handed) and the view bar's. The free area keeps clear of each.
Column_Side :: enum u8 {
	Left,
	Right,
}

// Where the panel stack goes, in layout terms (the left hand's layout mirrors them): docked
// on the right, which a fresh layout has, docked on the left, or floating.
Stack_Place :: enum u8 {
	Right,
	Left,
	Float,
}

// A panel: one of the windows Panel options and Arrange place (a union, as the pinned
// sections once shared it).
Panel_Ref :: union {
	Kit_Window,
}

// The windows that are panels; Settings, Help, Macros and Library stay side panels in the
// stack's place, which hides while one is open.
PANEL_WINDOWS :: bit_set[Kit_Window]{.Inspector, .Stats, .History, .Objects, .Colors, .Thumbnail}

// The gap between the stack's cards.
COLUMN_GAP :: 8
// The fewest points the docked stack's body gets, however short its column is.
PANEL_BODY_MIN :: 96

// What a panel was last laid out as: docked or floating, where, and (docked) the height
// it wanted and the height its column gave it.
Panel_Seen :: struct {
	ref:    Panel_Ref,
	frame:  int, // the frame it was laid out in; earlier means not shown since
	docked: bool,
	rect:   ui.Rect,
	want:   f32,
	allot:  f32,
	faded:  bool, // a stroke passed under it (Lens): it shows faint until the stroke ends
}

// The panels' state in Kit_State.
Panels :: struct {
	seen:    [dynamic; len(Kit_Window)]Panel_Seen,
	scroll:  f32, // the docked stack's body
	// Where the docked stack went on each side (last frame's, until it is laid out), empty
	// on the side it is not, for what keeps clear of it.
	rect:    [Column_Side]ui.Rect,
	// While the docked stack is laid out: its side, and where it goes (its offset from its
	// edge and its top, in the safe area's points).
	laying:  Maybe(Column_Side),
	at:      [2]f32,
	width:   f32,
	// The panel menu (Panel options): open, for which panel, beside what.
	menu:    bool,
	menu_of: Panel_Ref,
	menu_at: ui.Rect,
	moves:   int, // the stack docked or floated, for the exit stats
	// On a narrow window (stack_narrow): the docked stack shown over the view now, never
	// kept; whether it was open last frame, so opening it pops it; and how many times it
	// popped, for the exit stats.
	popped:    bool,
	open_last: bool,
	open_seen: bool, // open_last holds a frame's state: the first frame pops nothing
	pops:      int,
}

// What panel_begin opened, for the caller's content and panel_end.
Panel_Frame :: struct {
	ref:    Panel_Ref,
	body:   bool, // lay out the content (false while folded)
	closed: bool, // Close was tapped
	raised: bool, // a press landed on it: bring it to the front (floating only)
	dock:   bool, // a card's grip was long pressed (floating cards only)
	docked: bool,
	// The root container a press on the panel lands in: what a scrolling body inside it
	// is dragged for (kit_scroll_begin's owner).
	owner:  ui.Id,
	// How tall the content may be under the header: the room a floating window has down
	// to the safe area's bottom, or the docked stack's share of its column.
	room:   f32,
	// The content's natural height, when the caller scrolls it itself: what the docked
	// stack asks its column for. 0 takes the body's own.
	want:   f32,
	scroll: Kit_Scroll, // the docked stack's body
	padding, gap: f32, // its box's
	// Where its drawing starts and how opaque it ends up: faint while a stroke passes
	// under it (panel_fade).
	mark:   int,
	fade:   f32,
}

// The panels as a new user finds them: nothing remembered of where they were drawn, and
// the windows in their starting order. Where the stack goes is the layout's (stack_default).
panels_default :: proc(k: ^Kit_State) {
	p := &k.panels
	clear(&p.seen)
	p.scroll = 0
	p.menu = false
	k.order = {}
	for w in KIT_WINDOW_ORDER do append(&k.order, Float_Ref(w))
}

// The panel's container name at the root, as its window or card is named when it floats.
panel_name :: proc(ref: Panel_Ref) -> string {
	switch r in ref {
	case Kit_Window:
		names := [Kit_Window]string{.Inspector = "inspector", .Stats = "stats", .History = "history panel", .Settings = "settings", .Help = "help", .Macros = "macros", .Library = "library", .Objects = "objects card", .Colors = "colors card", .Thumbnail = "thumbnail"}
		return names[r]
	}
	return ""
}

// A stable id for the panel's own animations (its presence), the same docked or
// floating: ids taken inside a column hash with the column's.
panel_id :: proc(ref: Panel_Ref) -> ui.Id {
	return ui.hash_under(0, fmt.tprintf("panel %s", panel_name(ref)))
}

// The window that holds where the panel floats and whether it is folded.
panel_window :: proc(k: ^Kit_State, ref: Panel_Ref) -> ^ui.Window {
	switch r in ref {
	case Kit_Window:  return &k.windows[r]
	}
	return nil
}

// Whether the panel is shown (open), wherever it is.
panel_open :: proc(app: ^App, ref: Panel_Ref) -> bool {
	k := &app.kit
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Inspector: return k.inspector
		case .Stats:     return k.stats
		case .History:   return k.history
		case .Objects:   return k.objects_card
		case .Colors:    return k.colors_card
		case .Thumbnail: return k.thumbnail
		}
	}
	return false
}

// Opens or closes the panel.
panel_set_open :: proc(app: ^App, ref: Panel_Ref, open: bool) {
	k := &app.kit
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Inspector: k.inspector = open
		case .Stats:     k.stats = open
		case .History:   k.history = open
		case .Objects:   k.objects_card = open
		case .Colors:    k.colors_card = open
		case .Thumbnail: k.thumbnail = open
		}
	}
}

// The side the panel stack is docked on, if it is docked.
stack_docked :: proc(k: ^Kit_State) -> (side: Column_Side, ok: bool) {
	switch k.stack.place {
	case .Right: return .Right, true
	case .Left:  return .Left, true
	case .Float:
	}
	return .Right, false
}

// Puts the panel stack where `place` says, unfolded. Floated from a column, it floats where
// it was docked, a little down and in so it is seen to lift out.
stack_place_set :: proc(app: ^App, place: Stack_Place) {
	k := &app.kit
	if k.stack.place == place do return
	if _, docked := stack_docked(k); docked && place == .Float {
		r := panel_rect(app, Kit_Window.Inspector)
		if r.w > 0 do ui.window_move(&k.ctx, &k.windows[.Inspector], {r.x + 24, r.y + 24}, {r.w, r.h}, 12)
		window_raise(k, Kit_Window.Inspector)
	}
	if !k.stack.set do stack_default(k)
	k.stack.place = place
	k.windows[.Inspector].minimized = false
	k.panels.moves += 1
}

// The layout's line for where the stack goes, `stack_place left|float`, only when it is not
// on the right, so a fresh layout's text stays as it was.
stack_place_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	switch k.stack.place {
	case .Right:
	case .Left:  strings.write_string(out, "stack_place left\n")
	case .Float: strings.write_string(out, "stack_place float\n")
	}
}

// Reads a `stack_place right|left|float` line; another word leaves it on the right.
stack_place_read :: proc(k: ^Kit_State, f: []string) {
	if !k.stack.set do stack_default(k)
	k.stack.place = .Right
	if len(f) < 2 do return
	if strings.equal_fold(f[1], "left") do k.stack.place = .Left
	if strings.equal_fold(f[1], "float") do k.stack.place = .Float
}

// Where the panel was laid out this frame (or the last, during the layout); empty when
// it was not.
panel_rect :: proc(app: ^App, ref: Panel_Ref) -> ui.Rect {
	k := &app.kit
	for s in k.panels.seen do if s.ref == ref && s.frame >= k.frame - 1 do return s.rect
	return {}
}

@(private = "file")
panel_seen :: proc(k: ^Kit_State, ref: Panel_Ref) -> ^Panel_Seen {
	for &s in k.panels.seen do if s.ref == ref do return &s
	if len(k.panels.seen) == cap(k.panels.seen) do clear(&k.panels.seen)
	append(&k.panels.seen, Panel_Seen{ref = ref})
	return &k.panels.seen[len(k.panels.seen) - 1]
}

// The panel's name in its header and menus.
panel_title :: proc(app: ^App, ref: Panel_Ref) -> string {
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Inspector: return "Panels"
		case .Stats:     return "Statistics"
		case .History:   return "History"
		case .Objects:   return "Objects"
		case .Colors:    return "Colors"
		case .Thumbnail: return "Thumbnail"
		}
	}
	return ""
}

// The line a folded panel keeps beside its title: what it holds, in a few words.
panel_summary :: proc(app: ^App, ref: Panel_Ref) -> string {
	k := &app.kit
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Inspector:
			return ""
		case .Stats:
			if app.stats.frame_ms.count == 0 do return ""
			p50, _ := ring_percentiles(app.stats.frame_ms)
			return fmt.tprintf("%.1f ms a frame", p50)
		case .History:
			return fmt.tprintf("Step %d of %d", len(app.history.done), history_total(app))
		case .Objects:
			n := len(app.scene.objects)
			return fmt.tprintf("%d object%s", n, "" if n == 1 else "s")
		case .Colors:
			return hex_text(colors_target(app)^)
		case .Thumbnail:
			return fmt.tprintf("%s · %s", SECOND_CAMERA_NAMES[k.second.camera], second_shows_name(&k.second))
		}
	}
	return ""
}

// What section `sec` holds, in a few words, for its folded card.
section_summary :: proc(app: ^App, sec: Kit_Section) -> string {
	obj := selected_object(app)
	{
		#partial switch sec {
		case .Camera:
			return "Orthographic" if app.camera.ortho else "Perspective"
		case .Lights:
			n := int(app.scene.lights.count)
			return fmt.tprintf("%d light%s", n, "" if n == 1 else "s")
		case .Layers:
			if obj == nil || obj.voxel != nil do return ""
			n := sculpt.levels_layer_count(&obj.levels)
			return fmt.tprintf("%d layer%s", n, "" if n == 1 else "s")
		case .Stroke, .Falloff, .Samples, .Alpha, .Pen, .Options, .Preset:
			return BRUSHES[app.brush.kind].name
		case .Levels:
			if obj == nil || obj.voxel != nil do return ""
			return fmt.tprintf("Level %d of %d", obj.levels.current + 1, len(obj.levels.levels))
		case .Topology:
			return "Dynamic on" if command_checked(app, .Dyntopo_Toggle, 0) else "Dynamic off"
		case .Material:
			if obj == nil || obj.material.label == nil do return ""
			return string(obj.material.label)
		case .Objects:
			n := len(app.scene.objects)
			return fmt.tprintf("%d object%s", n, "" if n == 1 else "s")
		case .Render:
			if !render_switch_on(app) do return "Off"
			return "Full" if app.render_on else "Fast"
		case .Turntable:
			return fmt.tprintf("%d frames", int(app.turntable_frames))
		case .Print:
			return fmt.tprintf("%g mm a unit", print_scale(app))
		case .Floor:
			return "Grid on" if app.floor.on else "Grid off"
		}
	}
	return ""
}

// Where the stack docked on `side` stands this frame: its offset from its edge, its top and
// the room it has down to what sits under it (the dock where they would meet, the modifier
// wheel on its side), in the safe area's points.
@(private = "file")
stack_room :: proc(app: ^App, side: Column_Side, width: f32) -> (offset, top, room: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	dock_lo, dock_hi := shelf_bottom_span(app)
	stack_h := dock_stack(app)
	below: f32 = 0
	if side == .Right {
		offset, top = kit_right(app), kit_top()
		if dock_hi + 8 > area.w - offset - width do below = stack_h + 8
		if reach := rail_reach(app, .Right); reach > 0 do below = max(below, reach - t.edge + 8)
		// Lens's mini view sits under the panels on this side.
		if reach := lens_mini_reach(app); reach > 0 do below = max(below, reach - t.edge + 8)
	} else {
		offset, top = kit_left(app), points_bottom(app)
		if dock_lo - 8 < offset + width do below = stack_h + 8
		if reach := rail_reach(app, .Left); reach > 0 do below = max(below, reach - t.edge + 8)
	}
	room = area.h - top - t.edge - below
	return
}

// Whether the docked stack pops over the view rather than stands beside it: a window
// narrower than COLUMNS_MIN_W, where it would cover a third of the view for good (the Lens
// report's "below 1180 pt columns become popovers from the rails").
stack_narrow :: proc(app: ^App) -> bool {
	return app.kit.column_popovers && ui.safe_area(&app.kit.ctx).w < COLUMNS_MIN_W
}

// Whether the docked stack is drawn now: always on a wide window; on a narrow one while it
// is popped, and while arranging, so it is there to arrange.
stack_visible :: proc(app: ^App) -> bool {
	k := &app.kit
	return !stack_narrow(app) || k.panels.popped || k.bars_edit
}

// Whether the stack is on screen, which lights Palettes: open, not giving its place to a
// side panel, and not docked and put away on a narrow window.
tray_shown :: proc(app: ^App) -> bool {
	k := &app.kit
	if !k.inspector || side_panel_open(k) do return false
	if _, docked := stack_docked(k); docked do return stack_visible(app)
	return true
}

// Pops the docked stack over the view, or puts it away.
stack_pop :: proc(app: ^App, on: bool) {
	p := &app.kit.panels
	if on && !p.popped do p.pops += 1
	p.popped = on
}

// On a narrow window, pops the docked stack over the view, so a card just opened or kept
// there is in sight even when the stack was open already.
stack_pop_open :: proc(app: ^App) {
	if _, docked := stack_docked(&app.kit); docked && stack_narrow(app) do stack_pop(app, true)
}

// On a narrow window, before the stack is laid out: a press on the view puts the popped
// stack away (and goes no further, as a popover's dismissing press does, so it never
// sculpts), and opening it pops it. On a wide window nothing is popped, so narrowing it
// starts with the stack away.
@(private = "file")
stack_pop_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.panels
	_, docked := stack_docked(k)
	open := docked && k.inspector
	if !stack_narrow(app) || !docked {
		p.popped = false
	} else {
		if p.open_seen && open && !p.open_last do stack_pop(app, true)
		if !open do p.popped = false
		if p.popped && ctx.input.pressed != {} && ctx.input.mouse_valid && (ctx.pointer_root == 0 || ctx.viewport_drag) {
			p.popped = false
			ctx.swallow = true
			ctx.viewport_drag = false
			ctx.pointer_root = 0
		}
	}
	p.open_last = open
	p.open_seen = true
}

// On a narrow window, the docked stack put away while open: a tab at its top beside its
// bar, the stack's icon, which pops it.
@(private = "file")
kit_stack_pop_tab :: proc(app: ^App, side: Column_Side) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if !k.inspector || stack_visible(app) || side_panel_open(k) do return
	area := ui.safe_area(ctx)
	offset, top, _ := stack_room(app, side, 0)
	on_left := (side == .Left) != ctx.mirror
	w := t.target
	x := area.x + offset if on_left else area.x + area.w - offset - w
	ui.begin_at(ctx, fmt.tprintf("column tab %v", side), {x, area.y + top}, {direction = .Row, center = true, width = w, height = t.target, radius = t.radius_large, background = .Panel})
	a := ui.area(ctx, "tab", {w, t.target})
	icon := rune(0xe21d) if on_left else rune(0xe439) // panel-left-open, panel-right-open
	c := [2]f32{a.rect.x + t.target * 0.5, a.rect.y + a.rect.h * 0.5}
	ui.icon(ctx, icon, c, t.icon_size, t.accent if a.hovered else t.text)
	ui.tip(ctx, a.id, a.rect, "Show the panel stack")
	if a.clicked do stack_pop(app, true)
	ui.end(ctx)
}

// Lays out the docked stack by `draw` (kit_layout's, which knows the stack's proc) in its
// column, or its tab on a narrow window. Before the floating panels, which stay over it.
kit_stack_dock :: proc(app: ^App, draw: proc(app: ^App, ref: Panel_Ref) -> bool) {
	k := &app.kit
	stack_pop_update(app)
	k.panels.rect = {}
	k.panels.width = 0
	side, docked := stack_docked(k)
	if !docked do return
	if !k.inspector || side_panel_open(k) || !stack_visible(app) {
		kit_stack_pop_tab(app, side)
		return
	}
	ref := Panel_Ref(Kit_Window.Inspector)
	width := STACK_STRIP_W if stack_strip_shown(app) else stack_width(k) + stack_docked_extra(k)
	k.panels.width = width
	offset, top, room := stack_room(app, side, width)
	// The room it is given, by what it wanted last frame; never laid out yet, it asks for
	// all of it until it has been.
	s := panel_seen(k, ref)
	s.allot = min(s.want if s.want > 0 else room, max(room, 0))
	// The stack is a root container of its own: the column is where it stands, not a
	// container, so it keeps its ids (and its animations, its scroll) whether docked or
	// floating, and its proc reads the bars' places at the root as it does floating.
	k.panels.laying = side
	k.panels.at = {offset, top}
	_ = draw(app, ref)
	k.panels.laying = nil
	if pr := panel_rect(app, ref); pr.w > 0 && s.docked && s.frame == k.frame do k.panels.rect[side] = pr
}

// Opens panel `ref` as it is placed: a floating window (or, with `card`, a card titled
// `title`, "" for none) where it floats, with `x`, `y` and `offset` its default anchors
// as window_begin takes them; or, for the docked stack while kit_stack_dock lays it out,
// a root of its own in its column, without a header (each card has its own), its body
// scrolled. `box` is its look; docked, the stack takes its column's width. End it with
// panel_end, whatever body says.
panel_begin :: proc(app: ^App, ref: Panel_Ref, title: string, x, y: ui.Anchor, offset: [2]f32, box: ui.Box, close_keys := "", card := false) -> (p: Panel_Frame) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p.ref, p.padding, p.gap = ref, box.padding, box.gap
	p.mark, p.fade = ui.vertex_mark(ctx), panel_fade(app, panel_seen(k, ref))
	w := panel_window(k, ref)
	name := panel_name(ref)
	box := box
	seen := panel_seen(k, ref)
	p.owner = ui.hash_under(0, name)
	// Only while kit_stack_dock lays it out is the stack drawn docked.
	side, laying := k.panels.laying.?
	if !laying || ref != Panel_Ref(Kit_Window.Inspector) {
		options := false
		head: f32
		if card {
			p.raised, p.dock = ui.card_begin(ctx, name, title, w, x, y, offset, box, &options)
			p.body = true
			head = 18 + box.gap + (40 + box.gap if title != "" else 0)
		} else {
			p.body, p.closed, p.raised = ui.window_begin(ctx, name, title, w, x, y, offset, box, close_keys, &options)
			head = t.target + box.gap
		}
		p.room = window_room(app, w^, offset.y) - head - 2 * box.padding
		if options do panel_menu_open(app, ref)
		seen.docked = false
		return
	}
	p.docked = true
	width := k.panels.width
	inner := width - 2 * box.padding
	box.width, box.height = width, 0
	ui.begin_anchored(ctx, name, .Start if side == .Left else .End, .Start, k.panels.at, box)
	p.body = true
	p.room = max(seen.allot - 2 * box.padding, PANEL_BODY_MIN)
	p.scroll = kit_scroll_begin(ctx, "panel body", &k.panels.scroll, p.owner, inner, p.room, box.gap)
	return
}

// A panel the pointer passes over during a stroke that began on the viewport
// fades to PANEL_FADED until the stroke ends, so the work under it shows; the stroke
// stays the viewport's all the while. Returns how opaque the panel is now.
panel_fade :: proc(app: ^App, seen: ^Panel_Seen) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	if !ui.viewport_dragging(ctx) || !app.ui.viewport_stroke {
		seen.faded = false
	} else if !seen.faded && seen.frame >= k.frame - 1 && ui.rect_contains(seen.rect, ctx.input.mouse) {
		seen.faded = true
		k.panels_faded += 1
	}
	return ui.tween(ctx, ui.salt(ui.hash_under(0, panel_name(seen.ref)), 0x6a6465), PANEL_FADED if seen.faded else 1, ctx.theme.hover_time)
}

// How opaque a panel a stroke passes under is (the mockups' quarter).
PANEL_FADED :: 0.25

// Ends what panel_begin opened, and remembers where it went and how tall it wanted to be.
panel_end :: proc(app: ^App, p: ^Panel_Frame) {
	k := &app.kit
	ctx := &k.ctx
	seen := panel_seen(k, p.ref)
	seen.frame = k.frame
	defer if p.fade < 1 do ui.transform_since(ctx, p.mark, p.fade)
	if !p.docked {
		ui.window_end(ctx)
		seen.rect = ui.last_ended(ctx)
		return
	}
	kit_scroll_end(ctx, p.scroll)
	body := p.want if p.want > 0 else p.scroll.natural
	ui.end(ctx)
	seen.docked, seen.rect = true, ui.last_ended(ctx)
	seen.want = 2 * p.padding + body
}

// Opens Panel options for `ref`, beside `at` (its header when empty).
panel_menu_open :: proc(app: ^App, ref: Panel_Ref, at := ui.Rect{}) {
	k := &app.kit
	kit_floats_close(k)
	at := at
	if at.w <= 0 {
		r := panel_rect(app, ref)
		t := k.ctx.theme
		at = {r.x + r.w - 3 * t.target - 12, r.y + 12, t.target, t.target}
	}
	k.panels.menu, k.panels.menu_of, k.panels.menu_at = true, ref, at
}

// The side `side` stands on as the user sees it, which the left-handed layout swaps.
@(private = "file")
side_word :: proc(app: ^App, side: Column_Side) -> string {
	on_left := (side == .Left) != app.kit.ctx.mirror
	return "left" if on_left else "right"
}

// Panel options: for the stack, where it goes (docked on either side, or floating);
// folding a floating panel; and closing it.
kit_panel_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	m := &k.panels
	if !ui.popover_begin(ctx, "panel menu", &m.menu, m.menu_at, .Below, {direction = .Column, padding = 6, width = 248}) do return
	defer ui.popover_end(ctx)
	ref := m.menu_of
	w := panel_window(k, ref)
	picked := false
	ui.caption(ctx, fmt.tprintf("  %s", strings.to_upper(panel_title(app, ref), context.temp_allocator)))
	is_stack := ref == Panel_Ref(Kit_Window.Inspector)
	_, docked := stack_docked(k)
	if is_stack {
		for place in ([?]Stack_Place{.Left, .Right}) {
			if k.stack.place == place do continue
			side := Column_Side.Left if place == .Left else .Right
			if ui.menu_item(ctx, fmt.tprintf("Dock on the %s##%v", side_word(app, side), place), glyph = ui.ICON_PANEL) {
				stack_place_set(app, place)
				picked = true
			}
		}
		if docked && ui.menu_item(ctx, "Float", glyph = ui.ICON_MOVE) {
			stack_place_set(app, .Float)
			picked = true
		}
	}
	if (!is_stack || !docked) && ui.menu_item(ctx, "Unfold" if w.minimized else "Fold to its header", glyph = ui.ICON_RESTORE if w.minimized else ui.ICON_MINIMISE) {
		w.minimized = !w.minimized
		picked = true
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Close", glyph = ui.ICON_CLOSE) {
		panel_set_open(app, ref, false)
		picked = true
	}
	if picked do m.menu = false
}

// What an older file's panel lines said, kept until the whole text is read
// (panels_old_settle): the sections it pinned as panels (`pinned` lines, and `section:`
// words in its columns), in their columns' order and then the rest, and which of them were
// folded, which become cards kept in the stack; and the column the stack (Inspector) stood
// in, and whether a right column line left it out, which say where the stack goes.
Panels_Old :: struct {
	kept:      [dynamic; TRAY_SECTIONS]Kit_Section,
	folded:    bit_set[Kit_Section; u64],
	stack:     Maybe(Column_Side),
	right_out: bool,
}

// Reads one panels line of an older file (`f` split by spaces) into `old`: column
// <left|right> <panel>..., or pinned <Section> <moved> <x anchor> <y anchor> <x offset>
// <y offset> <minimised>. The windows a column held float now, where their window lines
// place them; words that name nothing are skipped.
panels_load_line :: proc(k: ^Kit_State, f: []string, old: ^Panels_Old) {
	switch f[0] {
	case "column":
		if len(f) < 2 || (f[1] != "left" && f[1] != "right") do return
		side := Column_Side.Left if f[1] == "left" else .Right
		named := false
		for word in f[2:] {
			if strings.has_prefix(word, "section:") do panels_old_keep(old, word[len("section:"):], false)
			else if strings.equal_fold(word, "Inspector") do named = true
		}
		if named && old.stack == nil do old.stack = side
		if !named && side == .Right do old.right_out = true
	case "pinned":
		// Where a pin floated is not kept: floating cards last a session, so it comes back
		// docked in the stack.
		if len(f) == 8 do panels_old_keep(old, f[1], f[7] == "1")
	}
}

// Notes tray section `name` (any case) as one an older file pinned; a name that is no
// tray section, or one noted already, is passed over.
@(private = "file")
panels_old_keep :: proc(old: ^Panels_Old, name: string, folded: bool) {
	for sec in Kit_Section {
		if int(sec) >= TRAY_SECTIONS || !strings.equal_fold(name, fmt.tprint(sec)) do continue
		for x in old.kept do if x == sec do return
		if len(old.kept) < cap(old.kept) do append(&old.kept, sec)
		if folded do old.folded += {sec}
	}
}

// Puts the stack where an older file's columns had it: in the column that named it, or
// floating when the right column (where it starts) was written without it; and keeps the
// sections it pinned as cards at the docked stack's foot, in the order they were noted,
// folded where they were.
panels_old_settle :: proc(k: ^Kit_State, old: ^Panels_Old) {
	if side, ok := old.stack.?; ok {
		if !k.stack.set do stack_default(k)
		k.stack.place = .Left if side == .Left else .Right
	} else if old.right_out {
		if !k.stack.set do stack_default(k)
		k.stack.place = .Float
	}
	if len(old.kept) == 0 do return
	if !k.stack.set do stack_default(k)
	for sec in old.kept {
		p, ok := panel_of_section(sec)
		if !ok do continue
		stack_keep(k, p, true)
		if sec in old.folded do k.stack.open -= {p}
	}
}
