package main

import "core:fmt"
import "core:strings"
import "../ui"

// Layouts: each workspace (workspaces.odin) keeps one layout of the interface: which bars
// show, the docks and their buttons, the cards pinned and floating, the view grid, the pass
// and the shelf's pages. What is changed is kept, and a workspace left keeps its layout as
// it was left. Its tab carries an amber dot while its layout differs from its base (the
// layout it ships with, or the one it was made from), and Reset layout puts that back. A
// layout is kept as text, the lines kit_layout_text writes, so comparing two is comparing
// strings and the settings file stores them as they are.

// A part of the interface a layout can hide. The top bar never hides: when a bar
// holding Undo and Redo, or Search and the tray's button, is hidden, they move into it.
Zone :: enum u8 {
	Brush_Bar, // down the left edge
	View_Bar, // down the right edge
	Dock, // along the bottom
	Wheel, // the modifier wheel
	Action_Bar, // the next steps over the dock
}

Layouts :: struct {
	shipped:  [Starter]string, // each starter's layout as it ships (heap; None's is empty)
	modified: bool, // the current workspace's layout differs from its base, as of this frame
	menu:     bool, // the workspace menu (the workspaces and Reset layout)
	menu_at:  ui.Rect,
	resets:   int, // Reset layout runs (an exit stat)
}

// The layouts as they start: each starter's as it ships, and the starting workspaces.
layouts_init :: proc(k: ^Kit_State) {
	for s in Starter do if s != .None do layout_text_set(&k.layouts.shipped[s], built_in_layout(s))
	workspaces_init(k)
}

layouts_destroy :: proc(k: ^Kit_State) {
	for &s in k.layouts.shipped {
		delete(s)
		s = ""
	}
	workspaces_destroy(k)
}

// Replaces the heap string `s` with a copy of `text`.
layout_text_set :: proc(s: ^string, text: string) {
	delete(s^)
	s^ = strings.clone(text) if text != "" else ""
}

// Workspace `slot`'s base for class `class` (the class in place when not given): its
// starter's layout as it ships, the same for both classes, or the one it was made from.
workspace_base :: proc(k: ^Kit_State, slot: int, class: Maybe(Layout_Class) = nil) -> string {
	w := &k.workspaces.list[slot]
	c := class.? or_else k.workspaces.class
	return w.base[c] if w.starter == .None else k.layouts.shipped[w.starter]
}

// Once a frame: whether the current workspace's layout differs from its base.
layouts_frame :: proc(k: ^Kit_State) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	l.modified = kit_layout_text(k) != workspace_base(k, k.workspaces.current)
}

// Whether workspace `slot`'s layout differs from its base: the current one's as of this
// frame, another's as it was left.
layout_changed :: proc(k: ^Kit_State, slot: int) -> bool {
	return k.layouts.modified if slot == k.workspaces.current else k.workspaces.list[slot].kept[k.workspaces.class] != ""
}

// Keeps the layout in place as workspace `from`'s and puts workspace `to`'s in its place.
layout_switch :: proc(k: ^Kit_State, from, to: int) {
	l := &k.layouts
	if from == to || l.shipped[.Sculpt] == "" do return
	ws := &k.workspaces
	c := ws.class
	now := kit_layout_text(k)
	layout_text_set(&ws.list[from].kept[c], now if now != workspace_base(k, from) else "")
	kit_layout_put(k, ws.list[to].kept[c] if ws.list[to].kept[c] != "" else workspace_base(k, to))
	layout_text_set(&ws.list[to].kept[c], "")
}

// Keeps the layout in place as the current workspace's for the class it was for, and puts
// its layout for class `to` in place, as a window moved to another kind of screen would want.
layout_class_switch :: proc(k: ^Kit_State, to: Layout_Class) {
	ws := &k.workspaces
	if to == ws.class do return
	if k.layouts.shipped[.Sculpt] == "" {
		ws.class = to
		return
	}
	w := workspace_now(k)
	now := kit_layout_text(k)
	layout_text_set(&w.kept[ws.class], now if now != workspace_base(k, ws.current) else "")
	ws.class = to
	kit_layout_put(k, w.kept[to] if w.kept[to] != "" else workspace_base(k, ws.current))
	layout_text_set(&w.kept[to], "")
}

// Puts the current workspace's layout back as its base.
layout_reset :: proc(k: ^Kit_State) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	kit_layout_put(k, workspace_base(k, k.workspaces.current))
	l.resets += 1
}

// The layout as text: the lines of the hidden zones, the pass, the view grid, the cards
// pinned in the columns, the floating cards, the shelf's pages, the docks and the bars, in
// that order. Places
// are written as they are for the right-handed layout, so a layout kept with either hand
// reads the same with the other.
kit_layout_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	if k.hidden != {} {
		strings.write_string(&out, "hidden")
		for z in Zone do if z in k.hidden do fmt.sbprintf(&out, " %v", z)
		strings.write_byte(&out, '\n')
	}
	strings.write_string(&out, pass_layout_line(k))
	// Inspect's panes are a view, not the layout: the grid it found is what the layout holds.
	strings.write_string(&out, k.inspect.before if k.inspect.on else grid_layout_lines(k))
	columns_save(k, &out)
	cards_float_save(k, &out)
	cards_size_save(k, &out)
	strings.write_string(&out, shelf_layout_line(k))
	// The docks, then the bars after a line that says the layout holds them.
	docks_save(k, &out)
	strings.write_string(&out, "bars\n")
	bars_save(k, &out, layout = true)
	return strings.to_string(out)
}

// Puts the layout `text` in place: what it does not name is as it starts (closed,
// unmoved, unfolded, every bar shown), and what it names is read through the same lines
// the settings file uses. Floating menus close, as what they hung from may have gone.
kit_layout_put :: proc(k: ^Kit_State, text: string) {
	view_toggles_off(k)
	panels_default(k)
	// No card open but those the layout pins; which sections are folded is the person's,
	// in every workspace.
	if !k.cards.set do cards_default(k)
	k.cards.columns = {}
	k.cards.floats = {}
	k.cards.sizes = {}
	k.hidden = {}
	// Every dock as it comes, and none of the person's but those the layout names, with
	// only the buttons it names.
	docks_clear(k)
	// The pass is Shaded unless the layout names another; a peek ends with the layout.
	k.passes.pass, k.passes.chip_held, k.passes.key_held = .Shaded, false, false
	shading_layout_clear(k)
	// One view unless the layout names a grid; the layout steps named another layout.
	k.grid.tree, k.grid.maximised = grid_preset_tree(.Single), 0
	k.grid.serial += 1
	grid_undo_clear(&k.grid)
	// The shelf's default pages unless the layout names others.
	k.shelf.ordered = 0
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		switch f[0] {
		case "shelf":
			shelf_layout_read(k, f)
		case "hidden":
			for word in f[1:] do for z in Zone do if strings.equal_fold(word, fmt.tprint(z)) do k.hidden += {z}
		case "pass":
			pass_layout_read(k, f)
		case "shading":
			shading_layout_read(k, f)
		case "dock":
			dock_read(k, f)
		case "panes", "pane", "pane_tab":
			grid_layout_read(k, f)
		case "column":
			columns_read(k, f)
		case "card_float":
			cards_float_read(k, f)
		case "card_size":
			cards_size_read(k, f)
		case "bars":
			bar_lists_reset(k)
		case "bar_count", "bar", "bar_look":
			bars_load_line(k, f)
		}
	}
	kit_floats_close(k)
}

// A starter's layout as it ships, as kit_layout_text writes it.
built_in_layout :: proc(s: Starter) -> string {
	text: string
	switch s {
	case .None:
	case .Sculpt:
		// The view clear: every card opens from its dock button when it is wanted; the
		// shelf's brushes, Move and Curve pages (painting has a workspace of its own).
		text = "shelf Sculpt Move Curve\n"
	case .Model:
		// As Sculpt, without the brush bar: its Size and Strength move no cage, so in Model
		// they would only take room from the view. The shelf's Model page.
		text = "hidden Brush_Bar\nshelf Model\n"
	case .Render:
		// The Material card pinned on the pen side, after round 2's studio2 screen, as picking
		// and trying materials is Render's work; Second view splits off a pane to watch the
		// render build up beside it. No brush bar, as in Model: a press in Render turns the
		// view, so Size and Strength would only take room. The shelf's Render page.
		text = "hidden Brush_Bar\ncolumn right Material\nshelf Render\n"
	case .Paint:
		// The brush bar for Size and Strength, the colour island over the shelf, and the
		// shelf's Paint page (its Colours tile opens the Colours card), then the brushes. No
		// card is pinned, so a card opened by a finger is the only one in its column.
		text = "shelf Paint Sculpt\n"
	}
	// Read and written again, so it is exactly what the layout writes when it is in place;
	// every starter ships with the bars a fresh install has.
	st := new(Kit_State, context.temp_allocator)
	kit_layout_put(st, strings.concatenate({text, "bars\n"}, context.temp_allocator))
	return kit_layout_text(st)
}

// Takes added shelf page `p`, deleted, out of every workspace's kept layout and base, so a
// page added later in its slot never shows where this one did.
layouts_forget_page :: proc(k: ^Kit_State, p: Shelf_Page) {
	word := fmt.tprint(p)
	forget :: proc(text: ^string, word: string) {
		if text^ == "" do return
		out := strings.builder_make(context.temp_allocator)
		for line in strings.split_lines(text^, context.temp_allocator) {
			if line == "" do continue
			f := strings.fields(line, context.temp_allocator)
			if f[0] != "shelf" {
				fmt.sbprintln(&out, line)
				continue
			}
			strings.write_string(&out, "shelf")
			for w in f[1:] do if w != word do fmt.sbprintf(&out, " %s", w)
			strings.write_byte(&out, '\n')
		}
		layout_text_set(text, strings.to_string(out))
	}
	for &w in k.workspaces.list do for c in Layout_Class {
		forget(&w.kept[c], word)
		forget(&w.base[c], word)
	}
}

// Whether the layout, or Focus or Inspect, hides zone `z`.
zone_hidden :: proc(k: ^Kit_State, z: Zone) -> bool {
	return z in k.hidden || (k.focus_mode && z in FOCUS_ZONES) || (k.inspect.on && z in INSPECT_ZONES)
}

// Where the modifier wheel is, if anywhere: Off while the layout hides it.
rail_shown :: proc(k: ^Kit_State) -> Rail_Side {
	return .Off if .Wheel in k.hidden else k.rail_side
}

// The room the top bar's middle needs for the workspace chip, which stands in for the tabs
// on a narrow window and in Focus.
WORKSPACE_CHIP_ROOM :: 160

// The workspace chip: the name of the workspace in front, with the amber dot while its
// layout differs from its base. A tap opens the workspace menu under it.
kit_workspace_chip :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	l := &k.layouts
	w := workspace_now(k)
	name := ui.text_fit(ctx, w.name, t.text_size, WORKSPACE_CHIP_ROOM - 40, .Semibold)
	parts := []ui.Chip_Part{{text = name, strong = true}, {text = "   " if l.modified else ""}}
	if ui.chip(ctx, "Workspace##chip", parts, command_hint(app, .Workspace_Switch, k.workspaces.current)) {
		was := l.menu
		kit_floats_close(k)
		l.menu = !was
	}
	r := ctx.last_rect
	l.menu_at = r
	if l.modified do ui.fill_circle(ctx, {r.x + r.w - 18, r.y + r.h * 0.5}, 4, t.warning)
}

// The workspace menu, from the tabs' chevron, the lit tab or the workspace chip: the
// workspaces, then Reset layout.
kit_layout_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	l := &k.layouts
	if !ui.popover_begin(ctx, "layout menu", &l.menu, l.menu_at, .Below, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "  WORKSPACES")
	picked := false
	for slot in workspace_tabs(k) do picked ||= command_menu_item(app, .Workspace_Switch, slot, label = fmt.tprintf("%s##layout menu %d", k.workspaces.list[slot].name, slot))
	ui.divider(ctx, across = true)
	picked ||= command_menu_item(app, .Layout_Reset)
	if picked do l.menu = false
}
