package main

import "core:fmt"
import "core:math/linalg"
import "core:strconv"
import "core:strings"

import "../sculpt"
import "../ui"

// Lens's panels (the Lens UI direction, P0 step 1): one kind of panel, shown three ways.
// A panel is the palette tray, Stats, History, the Objects card, the Colors card, the
// thumbnail, or a section of the tray pinned as a panel of its own. It is docked in one
// of two columns, floats as a window or card, or (a section) opens as a popover from a
// bar button, whose Pin turns it into a docked panel. A column stacks its panels under
// the top bar beside a side bar and shares its height among them; a panel taller than
// its share scrolls. Folded, a panel keeps its header with a line saying what it holds.
// Blender's docked editors and Photoshop's panel groups are the model for docking by
// dragging a header out of a column and back in; the fixed columns (no free splits)
// keep a layout from breaking, as the Lens report argues.

// The two columns: on the brush bar's side (the left, unless the layout is left-handed)
// and on the view bar's.
Column_Side :: enum u8 {
	Left,
	Right,
}

// A panel: one of the windows that can dock, or a pinned tray section.
Panel_Ref :: union {
	Kit_Window,
	Kit_Section,
}

// The windows that are panels; Settings, Help, Macros and Library stay side panels in the
// right column's place, which hides while one is open.
PANEL_WINDOWS :: bit_set[Kit_Window]{.Inspector, .Stats, .History, .Objects, .Colors, .Thumbnail}

// The most panels one column holds: every window that docks and a few pinned sections.
COLUMN_MAX :: 16
// The gap between the panels of a column.
COLUMN_GAP :: 8
// How wide a column's drop zone is while it holds nothing, and how far past a column's
// edges a dragged panel still drops into it.
COLUMN_DROP_W :: 160
COLUMN_DROP_REACH :: 32
// The fewest points a docked panel's body gets, however full its column is.
PANEL_BODY_MIN :: 96

// A tray section pinned as a panel: shown or not, where it floats when it does, and how
// far its body is scrolled.
Pinned :: struct {
	on:     bool,
	window: ui.Window,
	scroll: f32,
}

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
	columns: [Column_Side][dynamic; COLUMN_MAX]Panel_Ref, // top to bottom
	pins:    [Kit_Section]Pinned,
	seen:    [dynamic; len(Kit_Window) + TRAY_SECTIONS]Panel_Seen,
	scroll:  [Kit_Window]f32, // a docked window's body
	width:   [Column_Side]f32, // each column as laid out this frame
	rect:    [Column_Side]ui.Rect, // ...and where it went (last frame's, until it is laid out)
	// While a column is laid out: which, and where its next panel goes (its offset from
	// its edge and its top, in the safe area's points).
	laying:  Maybe(Column_Side),
	at:      [Column_Side][2]f32,
	// The panel menu (Panel options): open, for which panel, beside what.
	menu:    bool,
	menu_of: Panel_Ref,
	menu_at: ui.Rect,
	// A floating panel being dragged, which a column takes when let go over it.
	drag:    Maybe(Panel_Ref),
	drag_at: [2]f32,
	moves:   int, // docks, undocks and moves in a column, for the exit stats
	// On a narrow window (columns_narrow): each column shown over the view now, never
	// kept; the panels in it that were open last frame (panel_bit), so one that opens pops
	// its column; and how many times a column popped, for the exit stats.
	popped:    [Column_Side]bool,
	open_last: [Column_Side]u64,
	open_seen: bool, // open_last holds a frame's panels: the first frame pops nothing
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
	// to the safe area's bottom, or a docked panel's share of its column.
	room:   f32,
	// The content's natural height, when the caller scrolls it itself (the tray): what a
	// docked panel asks its column for. 0 takes the body's own.
	want:   f32,
	scroll: Kit_Scroll, // a docked panel's body
	bare:   bool, // docked without a header (Lens's stack, whose cards have their own)
	padding, gap: f32, // its box's
	// Where its drawing starts and how opaque it ends up: faint while a stroke passes
	// under it (panel_fade).
	mark:   int,
	fade:   f32,
}

// Lays the columns out as a new user finds them: the tray on the right, every other
// panel floating where it starts.
panels_default :: proc(k: ^Kit_State) {
	p := &k.panels
	for &c in p.columns do clear(&c)
	append(&p.columns[.Right], Panel_Ref(Kit_Window.Inspector))
	for &pin in p.pins do pin = {}
	clear(&p.seen)
	p.scroll = {}
	p.menu, p.drag = false, nil
	k.order = {}
	for w in KIT_WINDOW_ORDER do append(&k.order, Float_Ref(w))
}

// The panel's container name at the root, as its window or card is named when it floats.
panel_name :: proc(ref: Panel_Ref) -> string {
	switch r in ref {
	case Kit_Window:
		names := [Kit_Window]string{.Inspector = "inspector", .Stats = "stats", .History = "history panel", .Settings = "settings", .Help = "help", .Macros = "macros", .Library = "library", .Objects = "objects card", .Colors = "colors card", .Thumbnail = "thumbnail"}
		return names[r]
	case Kit_Section:
		return fmt.tprintf("pinned %v", r)
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
	case Kit_Section: return &k.panels.pins[r].window
	}
	return nil
}

// Whether the panel is shown (open), wherever it is.
panel_open :: proc(app: ^App, ref: Panel_Ref) -> bool {
	k := &app.kit
	switch r in ref {
	case Kit_Section: return k.panels.pins[r].on
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
	case Kit_Section: k.panels.pins[r].on = open
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

// The column holding the panel and its place there, if it is docked.
panel_docked :: proc(k: ^Kit_State, ref: Panel_Ref) -> (side: Column_Side, index: int, ok: bool) {
	for c, s in k.panels.columns {
		for r, i in c do if r == ref do return s, i, true
	}
	return
}

// Takes the panel out of its column, if it is in one.
@(private = "file")
panel_take :: proc(k: ^Kit_State, ref: Panel_Ref) {
	if side, i, ok := panel_docked(k, ref); ok do ordered_remove(&k.panels.columns[side], i)
}

// Docks the panel in column `side` at `index` (clamped; past the end appends), out of
// wherever it was, unfolded.
panel_dock :: proc(app: ^App, ref: Panel_Ref, side: Column_Side, index: int) {
	k := &app.kit
	index := index
	if from, i, ok := panel_docked(k, ref); ok && from == side && i < index do index -= 1
	panel_take(k, ref)
	c := &k.panels.columns[side]
	if len(c) >= COLUMN_MAX do return
	inject_at(c, clamp(index, 0, len(c)), ref)
	panel_window(k, ref).minimized = false
	k.panels.moves += 1
}

// Floats the panel where it was docked, a little down and in so it is seen to lift out.
panel_float :: proc(app: ^App, ref: Panel_Ref) {
	k := &app.kit
	if _, _, ok := panel_docked(k, ref); !ok do return
	panel_take(k, ref)
	r := panel_rect(app, ref)
	if r.w > 0 do ui.window_move(&k.ctx, panel_window(k, ref), {r.x + 24, r.y + 24}, {r.w, r.h}, 12)
	window_raise(k, ref)
	k.panels.moves += 1
}

// Moves a docked panel `by` places up (negative) or down its column.
panel_shift :: proc(app: ^App, ref: Panel_Ref, by: int) {
	k := &app.kit
	side, i, ok := panel_docked(k, ref)
	if !ok do return
	c := &k.panels.columns[side]
	j := clamp(i + by, 0, len(c) - 1)
	if j == i do return
	c[i], c[j] = c[j], c[i]
	k.panels.moves += 1
}

// Pins tray section `sec` as a panel of its own, docked at the bottom of the right
// column, or puts a pinned one away.
panel_pin_toggle :: proc(app: ^App, sec: Kit_Section) {
	k := &app.kit
	pin := &k.panels.pins[sec]
	if pin.on {
		pin.on = false
		return
	}
	pin^ = {on = true, window = pin.window}
	if _, _, ok := panel_docked(k, sec); !ok && !pin.window.moved do panel_dock(app, sec, .Right, COLUMN_MAX)
	window_raise(k, sec)
}

// Whether section `sec` can be pinned: any of the tray's but Objects, whose panel is the
// Objects card.
panel_pinnable :: proc(sec: Kit_Section) -> bool {
	return int(sec) < TRAY_SECTIONS && sec != .Objects
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

// Whether the panel was drawn in a column this frame, so the floating windows pass it.
panel_drawn_docked :: proc(k: ^Kit_State, ref: Panel_Ref) -> bool {
	for s in k.panels.seen do if s.ref == ref do return s.docked && s.frame == k.frame
	return false
}

// The panel's name in its header and menus.
panel_title :: proc(app: ^App, ref: Panel_Ref) -> string {
	switch r in ref {
	case Kit_Section: return tray_section_title(r)
	case Kit_Window:
		#partial switch r {
		case .Inspector: return palette_title(app, app.kit.tab)
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
			if len(tray_sections(app, k.tab)) == 0 do return ""
			return tray_section_title(tray_section(app, k.tab))
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
			return fmt.tprintf("%s · %s", SECOND_CAMERA_NAMES[k.second.camera], SECOND_PASS_NAMES[k.second.pass])
		}
	case Kit_Section:
		obj := selected_object(app)
		#partial switch r {
		case .Camera:
			return "Orthographic" if app.camera.ortho else "Perspective"
		case .Lights:
			n := int(app.scene.lights.count)
			return fmt.tprintf("%d light%s", n, "" if n == 1 else "s")
		case .Layers:
			if obj == nil || obj.voxel != nil do return ""
			n := sculpt.levels_layer_count(&obj.levels)
			return fmt.tprintf("%d layer%s", n, "" if n == 1 else "s")
		case .Stroke, .Falloff, .Alpha, .Pen, .Options, .Preset:
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

// The width a panel asks its column for: what it is as a window.
panel_width :: proc(app: ^App, ref: Panel_Ref) -> f32 {
	switch r in ref {
	case Kit_Section: return KIT_INSPECTOR_W
	case Kit_Window:
		#partial switch r {
		case .Inspector:
			if app.kit.chrome != .Lens do return tray_width(app)
			return STACK_STRIP_W if stack_strip_shown(app) else stack_width(&app.kit)
		case .Stats:     return KIT_STATS_W
		case .History:   return KIT_HISTORY_MIN_W
		case .Objects:   return KIT_INSPECTOR_W
		case .Colors:    return COLORS_CARD_W
		case .Thumbnail: return THUMBNAIL_W + 20
		}
	}
	return KIT_INSPECTOR_W
}

// Shares `room` among panels that want `want` each: each gets what it wants, or an equal
// share of what is left once the smaller wants are met, so a short panel takes only what
// it needs and the tall ones split the rest (water-filling). Writes the shares to `out`.
panel_water_fill :: proc(want: []f32, room: f32, out: []f32) {
	n := len(want)
	order: [COLUMN_MAX]int
	for i in 0 ..< n do order[i] = i
	// The smallest wants first: few enough for an insertion sort, which keeps ties in
	// their column order.
	for i in 1 ..< max(n, 1) {
		for j := i; j > 0 && want[order[j]] < want[order[j - 1]]; j -= 1 do order[j], order[j - 1] = order[j - 1], order[j]
	}
	left := max(room, 0)
	for k in 0 ..< n {
		i := order[k]
		share := left / f32(n - k)
		out[i] = min(want[i], share)
		left -= out[i]
	}
}

// Where column `side` stands this frame: its offset from its edge, its top and the room
// it has down to what sits under it (the dock where they would meet, the modifier wheel
// on its side), in the safe area's points.
@(private = "file")
column_place :: proc(app: ^App, side: Column_Side, width: f32) -> (offset, top, room: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	dock_size, _ := ui.prev_layout(ctx, "dock")
	stack_h := dock_stack(app)
	below: f32 = 0
	if side == .Right {
		offset, top = kit_right(app), kit_top()
		if area.w * 0.5 + dock_size.x * 0.5 + 8 > area.w - offset - width do below = stack_h + 8
		if reach := rail_reach(app, .Right); reach > 0 do below = max(below, reach - t.edge + 8)
		// Lens's mini view sits under the panels on this side.
		if reach := lens_mini_reach(app); reach > 0 do below = max(below, reach - t.edge + 8)
	} else {
		offset, top = kit_left(app), points_bottom(app)
		if area.w * 0.5 - dock_size.x * 0.5 - 8 < offset + width do below = stack_h + 8
		if reach := rail_reach(app, .Left); reach > 0 do below = max(below, reach - t.edge + 8)
	}
	room = area.h - top - t.edge - below
	return
}

// The panels column `side` shows now: the open ones, none on the right while a side
// panel (Settings, Help...) has its place, and none while the column waits to be popped.
@(private = "file")
column_shown :: proc(app: ^App, side: Column_Side) -> []Panel_Ref {
	k := &app.kit
	out := make([dynamic]Panel_Ref, 0, COLUMN_MAX, context.temp_allocator)
	if side == .Right && side_panel_open(k) do return out[:]
	if !column_visible(app, side) do return out[:]
	for r in k.panels.columns[side] do if panel_open(app, r) do append(&out, r)
	return out[:]
}

// Whether the columns pop over the view rather than stand beside it: a window narrower
// than the tray's own breakpoint, where a column would cover a third of the view for
// good (the Lens report's "below 1180 pt columns become popovers from the rails").
columns_narrow :: proc(app: ^App) -> bool {
	return app.kit.column_popovers && ui.safe_area(&app.kit.ctx).w < TRAY_NAV_MIN_W
}

// Whether column `side` is drawn now: always on a wide window; on a narrow one while it is
// popped, and while arranging or dragging a panel, so its outline and drop zone are there.
column_visible :: proc(app: ^App, side: Column_Side) -> bool {
	k := &app.kit
	return !columns_narrow(app) || k.panels.popped[side] || k.bars_edit || k.panels.drag != nil
}

// A bit for each panel, for a set of panels in a u64: the windows, then the sections.
panel_bit :: proc(ref: Panel_Ref) -> u64 {
	#assert(len(Kit_Window) + TRAY_SECTIONS <= 64)
	switch r in ref {
	case Kit_Window:  return 1 << u64(r)
	case Kit_Section: return 1 << u64(len(Kit_Window) + int(r))
	}
	return 0
}

// Whether the tray is on screen, which lights Palettes: open, not giving its place to a
// side panel, and not docked in a column put away on a narrow window.
tray_shown :: proc(app: ^App) -> bool {
	k := &app.kit
	if !k.inspector || side_panel_open(k) do return false
	if side, _, docked := panel_docked(k, Kit_Window.Inspector); docked do return column_visible(app, side)
	return true
}

// Pops column `side` over the view, or puts it away.
column_pop :: proc(app: ^App, side: Column_Side, on: bool) {
	p := &app.kit.panels
	if on && !p.popped[side] do p.pops += 1
	p.popped[side] = on
}

// On a narrow window, before the columns are laid out: a press on the view puts a popped
// column away (and goes no further, as a popover's dismissing press does, so it never
// sculpts), and a panel that opened since last frame pops the column holding it. On a
// wide window nothing is popped, so narrowing it starts with the columns away.
@(private = "file")
columns_pop_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.panels
	narrow := columns_narrow(app)
	for side in Column_Side {
		open: u64
		for r in p.columns[side] do if panel_open(app, r) do open |= panel_bit(r)
		if !narrow {
			p.popped[side] = false
		} else {
			if p.open_seen && open & ~p.open_last[side] != 0 do column_pop(app, side, true)
			if open == 0 do p.popped[side] = false
			if p.popped[side] && ctx.input.pressed != {} && ctx.input.mouse_valid && (ctx.pointer_root == 0 || ctx.viewport_drag) {
				p.popped[side] = false
				ctx.swallow = true
				ctx.viewport_drag = false
				ctx.pointer_root = 0
			}
		}
		p.open_last[side] = open
	}
	p.open_seen = true
}

// On a narrow window, a column put away that holds open panels: a tab at its top beside its
// bar, the column's icon with how many panels it holds when more than one, which pops it.
@(private = "file")
kit_column_tab :: proc(app: ^App, side: Column_Side) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	n := 0
	for r in k.panels.columns[side] do if panel_open(app, r) do n += 1
	if n == 0 || column_visible(app, side) || (side == .Right && side_panel_open(k)) do return
	area := ui.safe_area(ctx)
	offset, top, _ := column_place(app, side, 0)
	on_left := (side == .Left) != ctx.mirror
	w := t.target + (14 if n > 1 else 0)
	x := area.x + offset if on_left else area.x + area.w - offset - w
	ui.begin_at(ctx, fmt.tprintf("column tab %v", side), {x, area.y + top}, {direction = .Row, center = true, width = w, height = t.target, radius = t.radius_large, background = .Panel})
	a := ui.area(ctx, "tab", {w, t.target})
	icon := rune(0xe21d) if on_left else rune(0xe439) // panel-left-open, panel-right-open
	c := [2]f32{a.rect.x + t.target * 0.5, a.rect.y + a.rect.h * 0.5}
	ui.icon(ctx, icon, c, t.icon_size, t.accent if a.hovered else t.text)
	if n > 1 do ui.text(ctx, fmt.tprintf("%d", n), a.rect.x + t.target - 2, c.y, t.small_size, t.text_secondary, .Semibold)
	ui.tip(ctx, a.id, a.rect, fmt.tprintf("Show the %s column's panels", column_word(app, side)))
	if a.clicked do column_pop(app, side, true)
	ui.end(ctx)
}

// Lays out both columns, each panel by `draw` (kit_layout's, which knows every panel's
// proc). Before the floating panels, which stay over them.
kit_columns :: proc(app: ^App, draw: proc(app: ^App, ref: Panel_Ref) -> bool) {
	k := &app.kit
	columns_pop_update(app)
	for side in Column_Side {
		shown := column_shown(app, side)
		k.panels.width[side] = 0
		if len(shown) == 0 {
			k.panels.rect[side] = {}
			// A thumbnail put away with its column shows no picture, so none is drawn for it.
			if s, _, ok := panel_docked(k, Kit_Window.Thumbnail); ok && s == side do k.thumbnail_px = {}
			kit_column_tab(app, side)
			continue
		}
		width: f32 = 0
		for r in shown do width = max(width, panel_width(app, r))
		k.panels.width[side] = width
		offset, top, room := column_place(app, side, width)
		// Each panel's share of the room, by what it wanted last frame; one never laid
		// out yet asks for all of it until it has been.
		want: [COLUMN_MAX]f32
		allot: [COLUMN_MAX]f32
		for r, i in shown {
			s := panel_seen(k, r)
			want[i] = s.want if s.want > 0 else room
		}
		panel_water_fill(want[:len(shown)], room - COLUMN_GAP * f32(len(shown) - 1), allot[:len(shown)])
		for r, i in shown do panel_seen(k, r).allot = allot[i]
		// Each panel is a root container of its own, under the one before it: the column
		// is where they stand, not a container, so a panel keeps its ids (and its
		// animations, its scroll) whether docked or floating, and its proc reads the bars'
		// places at the root as it does floating.
		k.panels.laying = side
		k.panels.at[side] = {offset, top}
		for r in shown do _ = draw(app, r)
		k.panels.laying = nil
		lo, hi: [2]f32
		first := true
		for r in shown {
			pr := panel_rect(app, r)
			if pr.w <= 0 || !panel_drawn_docked(k, r) do continue
			a, b := [2]f32{pr.x, pr.y}, [2]f32{pr.x + pr.w, pr.y + pr.h}
			lo, hi = (a if first else linalg.min(lo, a)), (b if first else linalg.max(hi, b))
			first = false
		}
		k.panels.rect[side] = {} if first else {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
	}
}

// The column a panel let go of at `p` drops into, and where in it: over a column's
// panels (or past its edges by a little), or over the strip an empty column would take.
column_drop_at :: proc(app: ^App, p: [2]f32) -> (side: Column_Side, index: int, ok: bool) {
	k := &app.kit
	for s in Column_Side {
		zone := column_zone(app, s)
		if !ui.rect_contains(zone, p) do continue
		index = 0
		for r in k.panels.columns[s] {
			if !panel_drawn_docked(k, r) && !panel_open(app, r) do continue
			pr := panel_rect(app, r)
			if pr.w > 0 && p.y > pr.y + pr.h * 0.5 do index += 1
		}
		return s, index, true
	}
	return
}

// Where column `side` takes a dropped panel, in points: its panels as last laid out,
// reaching a little past them, or the strip it would take while empty.
column_zone :: proc(app: ^App, side: Column_Side) -> ui.Rect {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	r := k.panels.rect[side]
	if r.w > 0 && k.panels.width[side] > 0 {
		R :: COLUMN_DROP_REACH
		return {r.x - R, r.y - R, r.w + 2 * R, max(r.h, 200) + 2 * R}
	}
	offset, top, room := column_place(app, side, COLUMN_DROP_W)
	// On the brush bar's side unless mirrored: the left column's strip is at the screen's
	// left in the right-handed layout.
	on_left := (side == .Left) != ctx.mirror
	x := area.x + offset if on_left else area.x + area.w - offset - COLUMN_DROP_W
	return {x, area.y + top, COLUMN_DROP_W, room}
}

// While a floating panel is dragged: each column's drop zone, the one under the pointer
// lit with a line where the panel would go. Drawn over the panels. While arranging, with
// nothing dragged, each column's outline, an empty one saying what it is for.
kit_column_drop :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if k.panels.drag == nil && k.bars_edit && !side_panel_open(k) {
		for side in Column_Side {
			zone := column_zone(app, side)
			ui.stroke_rect(ctx, zone, t.radius_large, ui.color_fade(t.accent, 0.35), 1)
			if k.panels.rect[side].w > 0 do continue
			c := [2]f32{zone.x + zone.w * 0.5, zone.y + zone.h * 0.5}
			ui.text(ctx, "Drop a panel", c.x, c.y - 9, t.small_size, t.text_secondary, align = .Center)
			ui.text(ctx, "here", c.x, c.y + 9, t.small_size, t.text_secondary, align = .Center)
		}
		return
	}
	if k.panels.drag == nil do return
	p := k.panels.drag_at
	hit_side, index, hit := column_drop_at(app, p)
	for side in Column_Side {
		zone := column_zone(app, side)
		on := hit && hit_side == side
		ui.fill_rect(ctx, zone, t.radius_large, ui.color_fade(t.accent, 0.16 if on else 0.05))
		ui.stroke_rect(ctx, zone, t.radius_large, ui.color_fade(t.accent, 0.9 if on else 0.35), 2 if on else 1)
		if !on do continue
		// The line between the panels the drop goes between.
		y := zone.y + 16
		n := 0
		for r in k.panels.columns[side] {
			pr := panel_rect(app, r)
			if pr.w <= 0 do continue
			if n == index {
				y = pr.y - COLUMN_GAP * 0.5
				break
			}
			y = pr.y + pr.h + COLUMN_GAP * 0.5
			n += 1
		}
		ui.fill_rect(ctx, {zone.x + 12, y - 1.5, zone.w - 24, 3}, 1.5, t.accent)
	}
}

// Opens panel `ref` as it is placed: a floating window (or, with `card`, a card titled
// `title`, "" for none) where it floats, with `x`, `y` and `offset` its default anchors
// as window_begin takes them; or, docked, a part of its column with a header to drag it
// out by. `box` is its look; a docked panel takes its column's width. End it with
// panel_end, whatever body says.
panel_begin :: proc(app: ^App, ref: Panel_Ref, title: string, x, y: ui.Anchor, offset: [2]f32, box: ui.Box, close_keys := "", card := false, bare := false) -> (p: Panel_Frame) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p.ref, p.padding, p.gap = ref, box.padding, box.gap
	p.mark, p.fade = ui.vertex_mark(ctx), panel_fade(app, panel_seen(k, ref))
	w := panel_window(k, ref)
	name := panel_name(ref)
	box := box
	side, _, docked := panel_docked(k, ref)
	// Only while its column is laid out is a docked panel drawn docked.
	laying, in_column := k.panels.laying.?
	docked = docked && in_column && laying == side
	seen := panel_seen(k, ref)
	if !docked {
		// Where it was dragged from, before window_begin forgets the drag on the release.
		dragged := w.dragging
		options := false
		head: f32
		p.owner = ui.hash_under(0, name)
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
		panel_drag_follow(app, ref, w, dragged)
		seen.docked = false
		return
	}
	p.docked = true
	p.owner = ui.hash_under(0, name)
	width := k.panels.width[side]
	inner := width - 2 * box.padding
	box.width, box.height = width, 0
	ui.begin_anchored(ctx, name, .Start if side == .Left else .End, .Start, k.panels.at[side], box)
	value: ^f32
	switch r in ref {
	case Kit_Window:  value = &k.panels.scroll[r]
	case Kit_Section: value = &k.panels.pins[r].scroll
	}
	if bare {
		p.body, p.bare = true, true
		p.room = max(seen.allot - 2 * box.padding, PANEL_BODY_MIN)
		p.scroll = kit_scroll_begin(ctx, "panel body", value, p.owner, inner, p.room, box.gap)
		return
	}
	ui.begin(ctx, "panel head", {direction = .Row, width = inner, center = true})
	head := ui.area(ctx, "panel title", {max(inner - 3 * t.target, t.target), t.target})
	if head.hovered || head.held do ui.fill_rect(ctx, head.rect, t.radius_medium, t.fill_pressed if head.held else t.fill_hover)
	ty := head.rect.y + head.rect.h * 0.5
	// A card with no title of its own (the Thumbnail) still names itself in a column.
	title := title if title != "" else panel_title(app, ref)
	ui.text(ctx, ui.label_text(title), head.rect.x + 6, ty, t.text_size, t.text, .Semibold)
	if w.minimized {
		used := ui.text_width(ctx, ui.label_text(title), t.text_size, .Semibold) + 14
		if line := panel_summary(app, ref); line != "" && head.rect.w - used > 24 {
			ui.text(ctx, ui.text_fit(ctx, line, t.small_size, head.rect.w - used - 6), head.rect.x + used, ty, t.small_size, t.text_tertiary)
		}
	}
	// A long press (or a right click) on the title is Panel options too; a drag past the
	// slop lifts the panel out, and it goes on following the pointer as a window.
	if ui.secondary(ctx) do panel_menu_open(app, ref, head.rect)
	ui.tip(ctx, head.id, head.rect, "Drag out to float; hold for where it can go")
	if head.held && linalg.length(ctx.input.mouse - ctx.press_mouse) > t.slop {
		panel_undock(app, ref, head.rect, card)
	} else if head.clicked && w.minimized {
		w.minimized = false
	}
	if ui.icon_button(ctx, "Panel options", ui.ICON_MORE) do panel_menu_open(app, ref, ctx.last_rect)
	if ui.icon_button(ctx, "Restore" if w.minimized else "Minimise", ui.ICON_RESTORE if w.minimized else ui.ICON_MINIMISE) do w.minimized = !w.minimized
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = close_keys) do p.closed = true
	ui.end(ctx)
	if !w.minimized {
		p.body = true
		p.room = max(seen.allot - (2 * box.padding + t.target + box.gap), PANEL_BODY_MIN)
		p.scroll = kit_scroll_begin(ctx, "panel body", value, p.owner, inner, p.room, box.gap)
	}
	return
}

// In Lens, a panel the pointer passes over during a stroke that began on the viewport
// fades to PANEL_FADED until the stroke ends, so the work under it shows; the stroke
// stays the viewport's all the while. Returns how opaque the panel is now.
panel_fade :: proc(app: ^App, seen: ^Panel_Seen) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	if k.chrome != .Lens || !ui.viewport_dragging(ctx) || !app.ui.viewport_stroke {
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
	t := ctx.theme
	seen := panel_seen(k, p.ref)
	seen.frame = k.frame
	defer if p.fade < 1 do ui.transform_since(ctx, p.mark, p.fade)
	if !p.docked {
		ui.window_end(ctx)
		seen.rect = ui.last_ended(ctx)
		return
	}
	body: f32 = 0
	if p.body {
		kit_scroll_end(ctx, p.scroll)
		body = (p.want if p.want > 0 else p.scroll.natural) + p.gap
	}
	ui.end(ctx)
	seen.docked, seen.rect = true, ui.last_ended(ctx)
	if side, laying := k.panels.laying.?; laying do k.panels.at[side].y += seen.rect.h + COLUMN_GAP
	seen.want = 2 * p.padding + (body - p.gap if p.bare else t.target + body)
}

// Lifts docked panel `ref` out of its column under the pointer, which holds its header
// at `head`: from the next frame it floats, its title bar (or grip) held as if pressed,
// so the drag goes on.
@(private = "file")
panel_undock :: proc(app: ^App, ref: Panel_Ref, head: ui.Rect, card: bool) {
	k := &app.kit
	ctx := &k.ctx
	w := panel_window(k, ref)
	r := panel_rect(app, ref)
	panel_take(k, ref)
	// The pointer keeps its place on the header: where it pressed, from the panel's corner.
	grab := ctx.press_mouse - [2]f32{r.x, r.y}
	if r.w <= 0 do grab = ctx.press_mouse - [2]f32{head.x, head.y}
	ui.window_move(ctx, w, ctx.input.mouse - grab, {r.w, r.h}, 12)
	ui.window_grab(ctx, w, panel_name(ref), grab, card)
	window_raise(k, ref)
	k.panels.drag, k.panels.drag_at = ref, ctx.input.mouse
	k.panels.moves += 1
}

// Follows a floating panel's drag by its title bar: where the pointer is, for the drop
// zones, and on the release over a column, docks it there.
@(private = "file")
panel_drag_follow :: proc(app: ^App, ref: Panel_Ref, w: ^ui.Window, was_dragging: bool) {
	k := &app.kit
	ctx := &k.ctx
	if w.dragging {
		k.panels.drag, k.panels.drag_at = ref, ctx.input.mouse
		return
	}
	held, ok := k.panels.drag.?
	if !ok || held != ref do return
	k.panels.drag = nil
	if !was_dragging || ctx.input.cancel || .Left not_in ctx.input.released do return
	if side, index, hit := column_drop_at(app, ctx.input.mouse); hit do panel_dock(app, ref, side, index)
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

// The side a column stands on as the user sees it, which the left-handed layout swaps.
@(private = "file")
column_word :: proc(app: ^App, side: Column_Side) -> string {
	on_left := (side == .Left) != app.kit.ctx.mirror
	return "left" if on_left else "right"
}

// Panel options: where the panel can go (either column, floating, up or down its
// column), folding it, pinning the tray's section or putting a pinned one back, and
// closing it.
kit_panel_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	m := &k.panels
	if !ui.popover_begin(ctx, "panel menu", &m.menu, m.menu_at, .Below, {direction = .Column, padding = 6, width = 248}) do return
	defer ui.popover_end(ctx)
	ref := m.menu_of
	side, index, docked := panel_docked(k, ref)
	w := panel_window(k, ref)
	picked := false
	ui.caption(ctx, fmt.tprintf("  %s", strings.to_upper(panel_title(app, ref), context.temp_allocator)))
	for s in Column_Side {
		if docked && s == side do continue
		if ui.menu_item(ctx, fmt.tprintf("Dock on the %s##%v", column_word(app, s), s), glyph = ui.ICON_PANEL) {
			panel_dock(app, ref, s, COLUMN_MAX)
			picked = true
		}
	}
	if docked {
		if ui.menu_item(ctx, "Float", glyph = ui.ICON_MOVE) {
			panel_float(app, ref)
			picked = true
		}
		if index > 0 && ui.menu_item(ctx, "Move up", glyph = ui.ICON_CHEVRON_UP) do panel_shift(app, ref, -1)
		if index < len(m.columns[side]) - 1 && ui.menu_item(ctx, "Move down", glyph = ui.ICON_CHEVRON_DOWN) do panel_shift(app, ref, 1)
	}
	if ui.menu_item(ctx, "Unfold" if w.minimized else "Fold to its header", glyph = ui.ICON_RESTORE if w.minimized else ui.ICON_MINIMISE) {
		w.minimized = !w.minimized
		picked = true
	}
	switch r in ref {
	case Kit_Window:
		if r == .Inspector {
			sec := tray_section(app, k.tab)
			if len(tray_sections(app, k.tab)) > 0 && panel_pinnable(sec) && !m.pins[sec].on {
				if ui.menu_item(ctx, fmt.tprintf("Pin %s as a panel", tray_section_title(sec)), command_hint(app, .Pin_Section, int(sec)), ui.ICON_PANEL) {
					command_run(app, .Pin_Section, int(sec))
					picked = true
				}
			}
		}
	case Kit_Section:
		if ui.menu_item(ctx, "Show in the palette tray", command_hint(app, .Show_Section, int(r)), ui.ICON_PANEL) {
			command_run(app, .Show_Section, int(r))
			picked = true
		}
	}
	ui.divider(ctx, across = true)
	_, pinned := ref.(Kit_Section)
	if ui.menu_item(ctx, "Unpin" if pinned else "Close", glyph = ui.ICON_CLOSE) {
		panel_set_open(app, ref, false)
		picked = true
	}
	if picked do m.menu = false
}

// The settings lines of the panels: each column that is not as it starts, then each
// pinned section with where it floats.
panels_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	def: Kit_State
	panels_default(&def)
	for c, side in k.panels.columns {
		same := len(c) == len(def.panels.columns[side])
		if same do for r, i in c do same &&= r == def.panels.columns[side][i]
		if same do continue
		fmt.sbprintf(out, "column %s", "left" if side == .Left else "right")
		for r in c {
			switch v in r {
			case Kit_Window:  fmt.sbprintf(out, " %v", v)
			case Kit_Section: fmt.sbprintf(out, " section:%v", v)
			}
		}
		strings.write_byte(out, '\n')
	}
	for pin, sec in k.panels.pins {
		if !pin.on do continue
		w := pin.window
		fmt.sbprintfln(out, "pinned %v %d %v %v %g %g %d", sec, int(w.moved), w.x, w.y, w.offset.x, w.offset.y, int(w.minimized))
	}
}

// Reads one panels line (`f` split by spaces): column <left|right> <ref>... or pinned
// <Section> <moved> <x anchor> <y anchor> <x offset> <y offset> <minimised>. Words that
// name nothing are skipped; a panel named twice keeps its first place.
panels_load_line :: proc(k: ^Kit_State, f: []string) {
	switch f[0] {
	case "column":
		if len(f) < 2 do return
		side := Column_Side.Left if f[1] == "left" else .Right
		if f[1] != "left" && f[1] != "right" do return
		clear(&k.panels.columns[side])
		for word in f[2:] {
			ref: Panel_Ref
			if strings.has_prefix(word, "section:") {
				for s in Kit_Section do if panel_pinnable(s) && strings.equal_fold(word[len("section:"):], fmt.tprint(s)) do ref = s
			} else {
				for w in PANEL_WINDOWS do if strings.equal_fold(word, fmt.tprint(w)) do ref = w
			}
			if ref == nil do continue
			if _, _, there := panel_docked(k, ref); there do continue
			if len(k.panels.columns[side]) < COLUMN_MAX do append(&k.panels.columns[side], ref)
		}
	case "pinned":
		if len(f) != 8 do return
		for s in Kit_Section {
			if !panel_pinnable(s) || !strings.equal_fold(f[1], fmt.tprint(s)) do continue
			pin := &k.panels.pins[s]
			pin.on = true
			w := &pin.window
			w.moved, w.minimized = f[2] == "1", f[7] == "1"
			for a in ui.Anchor {
				if strings.equal_fold(f[3], fmt.tprint(a)) do w.x = a
				if strings.equal_fold(f[4], fmt.tprint(a)) do w.y = a
			}
			w.offset = {clamp(panels_number(f[5]), -WINDOW_OFFSET_MAX, WINDOW_OFFSET_MAX), clamp(panels_number(f[6]), -WINDOW_OFFSET_MAX, WINDOW_OFFSET_MAX)}
			window_raise(k, s)
		}
	}
}

// A settings word as a number, 0 when it is none.
@(private = "file")
panels_number :: proc(s: string) -> f32 {
	v, ok := strconv.parse_f32(s)
	return v if ok else 0
}

// A pinned section's panel: its title in the header, its controls under it, as the
// tray and the bar's popover draw them. Returns true when a press landed on it while it
// floats, to bring it to the front.
kit_pinned :: proc(app: ^App, sec: Kit_Section) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	pin := &k.panels.pins[sec]
	shown := ui.presence(ctx, panel_id(sec), pin.on, t.panel_time)
	if shown <= 0 do return
	PADDING :: 12
	title, draw, obj_draw, found := bar_section(app, sec)
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, sec, title, .End, .Start, {kit_right(app), kit_top()}, {direction = .Column, gap = 6, padding = PADDING, width = KIT_INSPECTOR_W, radius = t.radius_large, background = .Panel, inert = !pin.on})
	raised = p.raised
	if p.closed do pin.on = false
	if p.body {
		// Floating, it scrolls in its own body; docked, its column's share does.
		s: Kit_Scroll
		if !p.docked do s = kit_scroll_begin(ctx, "pinned body", &pin.scroll, p.owner, KIT_INSPECTOR_W - 2 * PADDING, max(p.room, PANEL_BODY_MIN), 6)
		obj := selected_object(app)
		switch {
		case !found:
			ui.paragraph(ctx, "Nothing to show here.")
		case obj_draw != nil && obj == nil:
			ui.paragraph(ctx, "Add or select an object first.")
		case obj_draw != nil:
			obj_draw(app, obj)
		case:
			draw(app)
		}
		if !p.docked do kit_scroll_end(ctx, s)
	}
	panel_end(app, &p)
	slide := window_slide(ctx, pin.window, .End) if !p.docked else 1
	ui.transform_since(ctx, mark, shown, 1, {}, {slide * (1 - shown) * 16, 0})
	return
}
