package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../ui"

// Layouts: each space (Sculpt, Model, Render) keeps one layout of the interface: which
// bars show, the docks and their buttons, the cards pinned and floating, the view grid and
// the pass. What is changed is kept, and a space left keeps its layout as it was left. The
// space's tab carries an amber dot while its layout differs from how it ships, and Reset
// layout puts it back so. A layout is kept as text, the lines kit_layout_text writes, so
// comparing two is comparing strings and the settings file stores them as they are.
//
// The person's own layouts are stamps of that text under a name: loading one puts it in
// place in the space in front, which then goes on changing as before. Nothing remembers
// which was loaded, so a space still has one layout and no "current workspace"; the menu
// ticks a saved layout only while the space's layout is exactly it.

// A part of the interface a layout can hide. The top bar never hides: when a bar
// holding Undo and Redo, or Search and the tray's button, is hidden, they move into it.
Zone :: enum u8 {
	Brush_Bar, // down the left edge
	View_Bar, // down the right edge
	Dock, // along the bottom
	Wheel, // the modifier wheel
	Action_Bar, // the next steps over the dock
}

// How many layouts of the person's own are kept: slots, as macros have, so a key, a pie
// or a gesture given Load layout keeps loading the same one while others come and go.
LAYOUT_SLOTS :: 16

Layouts :: struct {
	shipped:  [Space]string, // each space's layout as it ships (heap)
	kept:     [Space]string, // each space but the current one's layout as it was left, "" when as it ships (heap)
	modified: bool, // the current space's layout differs from how it ships, as of this frame
	menu:     bool, // the tabs' menu (spaces, your layouts, Reset layout)
	menu_at:  ui.Rect,
	resets:   int, // Reset layout runs (an exit stat)
	saved:    [LAYOUT_SLOTS]Saved_Layout, // the person's own layouts by slot; a slot without a name is free
	matching: int, // the saved layout the current space's layout is exactly, its slot + 1; 0 for none, as of this frame
	more:     int, // the saved layout whose actions the menu shows under it, its slot + 1; 0 for none
	naming:   bool, // the menu shows the field Save layout as asks a name in
	typing:   bool, // that field had the keys, which go back when it closes
	name:     [NAME_BYTES]u8,
	undo:     Layout_Undo,
	saves:    int, // layouts saved (exit stats)
	loads:    int, // layouts loaded
}

// A layout of the person's own: its name and its text, both heap.
Saved_Layout :: struct {
	name: string,
	text: string,
}

// What the Undo of the last load's or delete's toast takes back.
Layout_Undo :: struct {
	serial: ui.Id, // the toast; 0 for nothing to take back
	load:   bool, // a load put a layout in place in space `space` over `text`; else slot `slot` was deleted
	space:  Space,
	slot:   int,
	name:   string, // heap
	text:   string, // heap
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
	for &s in k.layouts.saved {
		delete(s.name)
		delete(s.text)
		s = {}
	}
	layout_undo_clear(&k.layouts)
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
	now := kit_layout_text(k)
	l.modified = now != l.shipped[k.spaces.current]
	l.matching = 0
	for s, i in l.saved do if s.name != "" && s.text == now {
		l.matching = i + 1
		break
	}
	// A load's Undo puts back what its space had: once another space is in front, it
	// would put that over this one's.
	if l.undo.serial != 0 && l.undo.load && l.undo.space != k.spaces.current {
		ui.toast_drop_action(&k.ctx, l.undo.serial)
		layout_undo_clear(l)
	}
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
	shading_layout_clear(k)
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
		// The Material card pinned on the pen side, after round 2's studio2 screen, as picking
		// and trying materials is Render's work; Second view splits off a pane to watch the
		// render build up beside it. No brush bar, as in Model: a press in Render turns the
		// view, so Size and Strength would only take room.
		text = "hidden Brush_Bar\ncolumn right Material\n"
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

// The layout menu, from the space tabs' chevron or the space chip: the spaces, the
// person's own layouts (each loads into the space in front; its More shows Update, Rename
// and Delete under it), Save layout as with its name field, then Reset layout.
kit_layout_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	l := &k.layouts
	if !l.menu && l.typing {
		ctx.text_focus = 0
		l.typing = false
	}
	if !l.menu do l.naming, l.more = false, 0
	if !ui.popover_begin(ctx, "layout menu", &l.menu, l.menu_at, .Below, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "  SPACES")
	picked := false
	for s in Space do picked ||= command_menu_item(app, .Space_Switch, int(s), label = fmt.tprintf("%s##layout menu", SPACE_NAMES[s]))
	ui.divider(ctx, across = true)
	ui.caption(ctx, "  YOUR LAYOUTS")
	inner := f32(ui.MENU_W - 2 * ui.MENU_PAD)
	listed := false
	for &saved, slot in l.saved {
		if saved.name == "" do continue
		listed = true
		ui.begin(ctx, fmt.tprintf("layout row %d", slot), {direction = .Row, width = inner, center = true})
		ui.begin(ctx, "load", {direction = .Column, width = inner - t.target})
		picked ||= command_menu_item(app, .Layout_Load, slot, label = fmt.tprintf("%s##layout %d", saved.name, slot))
		ui.end(ctx)
		if ui.icon_button(ctx, "More##layout", ui.ICON_MORE, selected = l.more == slot + 1, size = t.control) {
			l.more = 0 if l.more == slot + 1 else slot + 1
			l.naming = false
		}
		ui.end(ctx)
		row := ctx.last_rect
		if l.more != slot + 1 do continue
		ui.begin(ctx, fmt.tprintf("layout actions %d", slot), {direction = .Column, width = inner})
		if ui.menu_item(ctx, "Update to this layout##layout", glyph = ui.ICON_SAVE, enabled = l.matching != slot + 1, hint = "Saves the space's layout as it is now under this name.") {
			layout_update(app, slot)
			l.more = 0
		}
		if ui.menu_item(ctx, "Rename...##layout", glyph = ui.ICON_PENCIL) {
			k.rename = {open = true, layout = slot + 1, at = row}
			l.menu = false
		}
		if ui.menu_item(ctx, "Delete##layout", glyph = ui.ICON_TRASH, tone = .Danger) {
			layout_delete(app, slot)
			l.more = 0
		}
		ui.end(ctx)
	}
	if !listed do ui.paragraph(ctx, "Save how this space looks, then load it into any space.", t.caption_size, t.text_secondary)
	if l.naming {
		fresh := layout_fresh_name(k)
		_ = ui.text_field(ctx, "name##layout save", l.name[:len(l.name) - 1], hold = l.menu, hint = fresh)
		l.typing = true
		typed := rename_text(l.name[:])
		clash := layout_find(k, typed if typed != "" else fresh) >= 0
		if clash do ui.paragraph(ctx, "A layout has this name: Replace saves over it.", t.caption_size, t.text_secondary)
		save, cancel := kit_button_pair(ctx, "Replace" if clash else "Save", "Cancel", tone_a = .Accent)
		d := &app.device
		save ||= key_pressed(d, KEY_RETURN) || key_pressed(d, KEY_KP_ENTER)
		if save && layout_save(app, typed) do l.naming = false
		if cancel do l.naming = false
		if !l.naming {
			ctx.text_focus = 0
			l.typing = false
		}
	} else {
		picked ||= command_menu_item(app, .Layout_Save_As)
	}
	ui.divider(ctx, across = true)
	picked ||= command_menu_item(app, .Layout_Reset)
	if picked && !l.naming do l.menu = false
}

// The name of slot `slot`'s layout, the way the palette, Settings > Keys and scripts
// tell one slot from another.
layout_slot_label :: proc(k: ^Kit_State, slot: int) -> string {
	if slot < 0 || slot >= LAYOUT_SLOTS || k.layouts.saved[slot].name == "" do return fmt.tprintf("Layout %d", slot + 1)
	return k.layouts.saved[slot].name
}

// The slot of the saved layout called `name` (letter case aside), or -1.
layout_find :: proc(k: ^Kit_State, name: string) -> int {
	if name == "" do return -1
	for s, i in k.layouts.saved do if s.name != "" && strings.equal_fold(s.name, name) do return i
	return -1
}

// What Save layout as calls a layout left unnamed: the space and the first number free.
layout_fresh_name :: proc(k: ^Kit_State) -> string {
	for n := 1; ; n += 1 {
		name := fmt.tprintf("%s layout %d", SPACE_NAMES[k.spaces.current], n)
		if layout_find(k, name) < 0 do return name
	}
}

// Opens the layout menu on its name field (Save layout as).
layout_save_open :: proc(k: ^Kit_State) {
	kit_floats_close(k)
	l := &k.layouts
	l.menu, l.naming, l.more = true, true, 0
	l.name = {}
}

// Saves the space's layout as it is now under `name` (the next "<Space> layout N" when
// empty), over the saved layout of that name if there is one. False when every slot holds
// a layout and none has the name.
layout_save :: proc(app: ^App, typed: string) -> bool {
	k := &app.kit
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return false
	name := strings.trim_space(typed)
	if name == "" do name = layout_fresh_name(k)
	slot := layout_find(k, name)
	replaced := slot >= 0
	if !replaced {
		for s, i in l.saved do if s.name == "" {
			slot = i
			break
		}
	}
	if slot < 0 {
		report(app, nil, {.Warning}, "All %d layouts are taken: delete one first", LAYOUT_SLOTS)
		return false
	}
	s := &l.saved[slot]
	layout_text_set(&s.name, name)
	layout_text_set(&s.text, kit_layout_text(k))
	l.saves += 1
	layouts_store(app)
	report(app, nil, {}, "%s layout %s", "Replaced" if replaced else "Saved", name)
	return true
}

// Puts saved layout `slot` in place in the space in front, as its layout from now on;
// the toast's Undo puts back what was there.
layout_load :: proc(app: ^App, slot: int) {
	k := &app.kit
	l := &k.layouts
	if slot < 0 || slot >= LAYOUT_SLOTS || l.saved[slot].name == "" || l.shipped[.Sculpt] == "" do return
	before := strings.clone(kit_layout_text(k))
	kit_layout_put(k, l.saved[slot].text)
	l.loads += 1
	msg := fmt.tprintf("Loaded %s into %s", l.saved[slot].name, SPACE_NAMES[k.spaces.current])
	layout_undo_set(k, {load = true, space = k.spaces.current, text = before}, msg)
}

// Saves the space's layout as it is now over saved layout `slot`, keeping its name.
layout_update :: proc(app: ^App, slot: int) {
	k := &app.kit
	s := &k.layouts.saved[slot]
	if s.name == "" do return
	layout_text_set(&s.text, kit_layout_text(k))
	k.layouts.saves += 1
	layouts_store(app)
	report(app, nil, {}, "Updated layout %s", s.name)
}

// Renames saved layout `slot`; false when another has the name.
layout_rename :: proc(app: ^App, slot: int, typed: string) -> bool {
	k := &app.kit
	s := &k.layouts.saved[slot]
	name := strings.trim_space(typed)
	if s.name == "" || name == "" do return false
	if other := layout_find(k, name); other >= 0 && other != slot {
		report(app, nil, {.Warning}, "A layout is called %s already", name)
		return false
	}
	layout_text_set(&s.name, name)
	layouts_store(app)
	return true
}

// Deletes saved layout `slot`, and the keys, pie slots and gestures that loaded it; the
// toast's Undo brings the layout back.
layout_delete :: proc(app: ^App, slot: int) {
	k := &app.kit
	s := &k.layouts.saved[slot]
	if s.name == "" do return
	msg := fmt.tprintf("Deleted layout %s", s.name)
	gone := s^
	s^ = {}
	_ = command_slot_forget(app, .Layout_Load, slot)
	layout_undo_set(k, {slot = slot, name = gone.name, text = gone.text}, msg)
	layouts_store(app)
}

// Keeps `u` (its strings now the undo's) for the toast saying `msg` to take back.
@(private = "file")
layout_undo_set :: proc(k: ^Kit_State, u: Layout_Undo, msg: string) {
	l := &k.layouts
	if l.undo.serial != 0 do ui.toast_drop_action(&k.ctx, l.undo.serial)
	layout_undo_clear(l)
	l.undo = u
	l.undo.serial = ui.toast(&k.ctx, msg, .Info, "Undo")
}

@(private = "file")
layout_undo_clear :: proc(l: ^Layouts) {
	delete(l.undo.name)
	delete(l.undo.text)
	l.undo = {}
}

// The toast's Undo: the layout a load replaced goes back in place, or a deleted layout
// back in its slot (unless the slot or its name was taken since).
layout_undo :: proc(app: ^App) {
	k := &app.kit
	l := &k.layouts
	u := l.undo
	if u.serial == 0 do return
	if u.load {
		if u.space == k.spaces.current do kit_layout_put(k, u.text)
	} else if l.saved[u.slot].name == "" && layout_find(k, u.name) < 0 {
		l.saved[u.slot] = {u.name, u.text}
		l.undo.name, l.undo.text = "", ""
		layouts_store(app)
	}
	layout_undo_clear(l)
}

// A change to the saved layouts is written to the settings file at once, as a deleted
// macro's is, so a key that loaded one never outlives it on disk.
@(private = "file")
layouts_store :: proc(app: ^App) {
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// The settings lines of the layouts: `space_layout <Space> <text>` for each space whose
// layout differs from how it ships, the current one's as it is now, and
// `layout_saved <slot from 1> <name> <text>` for each of the person's own.
layouts_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	l := &k.layouts
	if l.shipped[.Sculpt] == "" do return
	for s in Space {
		text := kit_layout_text(k) if s == k.spaces.current else l.kept[s]
		if text != "" && text != l.shipped[s] do fmt.sbprintfln(out, "space_layout %v %s", s, preset_escape(text))
	}
	fmt.sbprintfln(out, "space_current %v", k.spaces.current)
	for s, i in l.saved do if s.name != "" do fmt.sbprintfln(out, "layout_saved %d %s %s", i + 1, preset_escape(s.name), preset_escape(s.text))
}

// Reads a `space_layout`, `space_current` or `layout_saved` line (`f` split by spaces); a
// space this build does not name, a slot out of range or one read already is passed over.
layouts_load_line :: proc(k: ^Kit_State, f: []string) {
	if len(f) < 2 || k.layouts.shipped[.Sculpt] == "" do return
	if f[0] == "layout_saved" {
		slot, ok := strconv.parse_int(f[1])
		if !ok || len(f) != 4 || slot < 1 || slot > LAYOUT_SLOTS do return
		s := &k.layouts.saved[slot - 1]
		name := strings.trim_space(preset_unescape(f[2]))
		if s.name != "" || name == "" || layout_find(k, name) >= 0 do return
		layout_text_set(&s.name, name)
		layout_text_set(&s.text, preset_unescape(f[3]))
		return
	}
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
