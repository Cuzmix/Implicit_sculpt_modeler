package main

import "core:fmt"
import "core:strings"
import "../ui"

// Layouts: each space (Sculpt, Model, Render) keeps one layout of the interface: which
// bars show, the docks and their buttons, the cards pinned and floating, the view grid and
// the pass. There is nothing to save or name: what is changed is kept, and a space left
// keeps its layout as it was left. The space's tab carries an amber dot while its layout
// differs from how it ships, and Reset layout puts it back so. A layout is kept as text,
// the lines kit_layout_text writes, so comparing two is comparing strings and the
// settings file stores them as they are.

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
	shipped:  [Space]string, // each space's layout as it ships (heap)
	kept:     [Space]string, // each space but the current one's layout as it was left, "" when as it ships (heap)
	modified: bool, // the current space's layout differs from how it ships, as of this frame
	menu:     bool, // the tabs' menu (Reset layout, Focus, Inspect)
	menu_at:  ui.Rect,
	resets:   int, // Reset layout runs (an exit stat)
}

// The layouts as they start: each space's as it ships.
layouts_init :: proc(k: ^Kit_State) {
	for s in Space do layout_text_set(&k.layouts.shipped[s], built_in_layout(s))
	spaces_init(k)
}

layouts_destroy :: proc(k: ^Kit_State) {
	for s in Space {
		delete(k.layouts.shipped[s])
		delete(k.layouts.kept[s])
		k.layouts.shipped[s], k.layouts.kept[s] = "", ""
	}
	spaces_destroy(k)
}

// Replaces the heap string `s` with a copy of `text`.
@(private = "file")
layout_text_set :: proc(s: ^string, text: string) {
	delete(s^)
	s^ = strings.clone(text) if text != "" else ""
}

// Once a frame: whether the current space's layout differs from how it ships.
layouts_frame :: proc(k: ^Kit_State) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	l.modified = kit_layout_text(k) != l.shipped[k.spaces.current]
}

// Whether space `s`'s layout differs from how it ships: the current one's as of this
// frame, another's as it was left.
layout_changed :: proc(k: ^Kit_State, s: Space) -> bool {
	return k.layouts.modified if s == k.spaces.current else k.layouts.kept[s] != ""
}

// Keeps the layout in place as space `from`'s and puts space `to`'s in its place.
layout_switch :: proc(k: ^Kit_State, from, to: Space) {
	l := &k.layouts
	if from == to || l.shipped[.Sculpt] == "" do return
	now := kit_layout_text(k)
	layout_text_set(&l.kept[from], now if now != l.shipped[from] else "")
	kit_layout_put(k, l.kept[to] if l.kept[to] != "" else l.shipped[to])
	layout_text_set(&l.kept[to], "")
}

// Puts the current space's layout back as it ships.
layout_reset :: proc(k: ^Kit_State) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	kit_layout_put(k, l.shipped[k.spaces.current])
	l.resets += 1
}

// The layout as text: the lines of the hidden zones, the pass, the view grid, the cards
// pinned in the columns, the floating cards, the docks and the bars, in that order. Places
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
	// in every space.
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
	k.passes.shading = {}
	// One view unless the layout names a grid; the layout steps named another layout.
	k.grid.tree, k.grid.maximised = grid_preset_tree(.Single), 0
	k.grid.serial += 1
	grid_undo_clear(&k.grid)
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		switch f[0] {
		case "hidden":
			for word in f[1:] do for z in Zone do if strings.equal_fold(word, fmt.tprint(z)) do k.hidden += {z}
		case "pass":
			pass_layout_read(k, f)
		case "shading":
			shading_layout_read(k, f)
		case "dock":
			dock_read(k, f)
		case "panes", "pane", "pane_tab":
			grid_layout_read(&k.grid, f)
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

// A space's layout as it ships, as kit_layout_text writes it.
built_in_layout :: proc(s: Space) -> string {
	text: string
	switch s {
	case .Sculpt:
		// The view clear: every card opens from its dock button when it is wanted.
		text = ""
	case .Model:
		// As Sculpt, without the brush bar: its Size and Strength move no cage, so in Model
		// they would only take room from the view.
		text = "hidden Brush_Bar\n"
	case .Render:
		// The Look card pinned on the pen side, after round 2's studio2 screen; Second view
		// splits off a pane to watch the render build up beside the work.
		text = "column right Look\n"
	}
	// Read and written again, so it is exactly what the layout writes when it is in place;
	// every space ships with the bars a fresh install has.
	st := new(Kit_State, context.temp_allocator)
	kit_layout_put(st, strings.concatenate({text, "bars\n"}, context.temp_allocator))
	return kit_layout_text(st)
}

// Whether the layout, or Focus or Inspect, hides zone `z`.
zone_hidden :: proc(k: ^Kit_State, z: Zone) -> bool {
	return z in k.hidden || (k.focus_mode && z in FOCUS_ZONES) || (k.inspect.on && z in INSPECT_ZONES)
}

// Where the modifier wheel is, if anywhere: Off while the layout hides it.
rail_shown :: proc(k: ^Kit_State) -> Rail_Side {
	return .Off if .Wheel in k.hidden else k.rail_side
}

// The room the top bar's middle needs for the space chip, which stands in for the tabs on
// a narrow window and in Focus.
SPACE_CHIP_ROOM :: 160

// The space chip: the space's name, with the amber dot while its layout differs from how
// it ships. A tap opens the layout menu under it, which also switches spaces.
kit_space_chip :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	l := &k.layouts
	parts := []ui.Chip_Part{{text = SPACE_NAMES[k.spaces.current], strong = true}, {text = "   " if l.modified else ""}}
	if ui.chip(ctx, "Space##chip", parts, command_hint(app, .Space_Switch, int(k.spaces.current))) {
		was := l.menu
		kit_floats_close(k)
		l.menu = !was
	}
	r := ctx.last_rect
	l.menu_at = r
	if l.modified do ui.fill_circle(ctx, {r.x + r.w - 18, r.y + r.h * 0.5}, 4, t.warning)
}

// The layout menu, from the space tabs' chevron or the space chip: the spaces, Reset
// layout, then the views that change what shows rather than the layout, Focus and Inspect.
kit_layout_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	l := &k.layouts
	if !ui.popover_begin(ctx, "layout menu", &l.menu, l.menu_at, .Below, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "  SPACES")
	picked := false
	for s in Space do picked ||= command_menu_item(app, .Space_Switch, int(s), label = fmt.tprintf("%s##layout menu", SPACE_NAMES[s]))
	ui.divider(ctx, across = true)
	picked ||= command_menu_item(app, .Layout_Reset)
	if picked do l.menu = false
}

// The settings lines of the layouts: `space_layout <Space> <text>` for each space whose
// layout differs from how it ships, the current one's as it is now.
layouts_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	for s in Space {
		text := kit_layout_text(k) if s == k.spaces.current else l.kept[s]
		if text != "" && text != l.shipped[s] do fmt.sbprintfln(out, "space_layout %v %s", s, preset_escape(text))
	}
	fmt.sbprintfln(out, "space_current %v", k.spaces.current)
}

// Reads a `space_layout` or `space_current` line (`f` split by spaces); a space this build
// does not name is passed over.
layouts_load_line :: proc(k: ^Kit_State, f: []string) {
	if len(f) < 2 || k.layouts.shipped[.Sculpt] == "" do return
	s: Space
	found := false
	for each in Space do if strings.equal_fold(f[1], fmt.tprint(each)) do s, found = each, true
	if !found do return
	switch f[0] {
	case "space_layout":
		if len(f) == 3 do layout_text_set(&k.layouts.kept[s], preset_unescape(f[2]))
	case "space_current":
		k.spaces.current = s
	}
}

// After the settings are read: the current space's layout is put in place.
layouts_loaded :: proc(k: ^Kit_State) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	s := k.spaces.current
	// Sculpt as it ships is how the interface starts, with any bar the settings named
	// (a scenario's view rail), so it is put in place only when the file kept another.
	if l.kept[s] != "" do kit_layout_put(k, l.kept[s])
	else if s != .Sculpt do kit_layout_put(k, l.shipped[s])
	layout_text_set(&l.kept[s], "")
}
