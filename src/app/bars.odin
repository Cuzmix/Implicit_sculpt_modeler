package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../sculpt"
import "../ui"

// The bars the user arranges: the right bar's shortcut column under Search, Palettes and
// Objects, the bottom bar's tool strip after All brushes, and the dock's slots (dock.odin),
// which take any command too. The column and the strip are lists of registry commands
// (Bar_Slot, a pie's slot), as Nomad lets any tool be a shortcut; a button whose command
// does more than run (a long press that opens a menu, a lit state of its own) keeps that
// through bar_slot_button wherever it sits. Customise bars is an edit mode, as iPadOS's
// home screen has: every slot it can change is ringed, a tap opens the slot's popover
// (another command from Search, move it, remove it, add one after it), a + ends each bar,
// and Done or Escape ends it. A long press on a dock slot reaches the same popover at any
// time, as ZBrush for iPad's does.

Bar_Slot :: Pie_Slot

Bar_Which :: enum u8 {
	Shortcuts, // the right bar's column
	Tools, // the bottom bar's strip
	Dock,
}

@(rodata)
BAR_NAMES := [Bar_Which]string {
	.Shortcuts = "THE RIGHT BAR",
	.Tools     = "THE BOTTOM BAR",
	.Dock      = "THE DOCK",
}

// Each bar's name in settings.txt: the zone of the screen it holds, so a later layout that
// moves bars about keeps each one's buttons by where they are.
@(rodata)
BAR_ZONES := [Bar_Which]string {
	.Shortcuts = "right_rail",
	.Tools     = "bottom_tools",
	.Dock      = "dock",
}

// The bar a zone name names; the dock's slots keep their own dock lines.
bar_zone :: proc(name: string) -> (Bar_Which, bool) {
	for zone, which in BAR_ZONES do if which != .Dock && zone == name do return which, true
	return {}, false
}

SHORTCUTS_MAX :: 16
TOOLS_MAX :: 8

// A bar's commands, `count` of them in use.
Bar_List :: struct {
	slots: [SHORTCUTS_MAX]Bar_Slot,
	count: int,
}

// What a fresh install has: the view's buttons down the right, the gizmo and the mesh
// tools along the bottom.
SHORTCUTS_DEFAULT :: [?]Bar_Slot {
	{.Shading_Menu, 0}, {.Camera_Menu, 0}, {.Studio_Render, 0}, {.Floor_Grid, 0}, {.Symmetry_X, 0}, {.Local_Symmetry, 0},
	{.Focus_Selected, 0}, {.Wireframe, 0}, {.Transparency, 0}, {.Ghost_Object, 0}, {.Solo_Object, 0},
}
TOOLS_DEFAULT :: [?]Bar_Slot{{.Tool_Move, 0}, {.Remesh, 0}, {.Dyntopo_Toggle, 0}, {.Retopologize, 0}, {.Subdivide, 0}, {.Live_Boolean, 0}}

// A slot the palette is choosing a command for: slot `slot` of bar `which`, or with `add`
// set a new slot put in at `slot`.
Bar_Pick :: struct {
	which: Bar_Which,
	slot:  int,
	add:   bool,
}

// The popover a tap on a shortcut or tool slot opens while customising.
Bar_Slot_Menu :: struct {
	open:  bool,
	which: Bar_Which,
	slot:  int,
	at:    ui.Rect,
}

bar_list_of :: proc(slots: []Bar_Slot) -> (l: Bar_List) {
	copy(l.slots[:], slots)
	l.count = len(slots)
	return
}

// Puts every bar back as a fresh install has it.
bars_reset :: proc(k: ^Kit_State) {
	shortcuts, tools := SHORTCUTS_DEFAULT, TOOLS_DEFAULT
	k.shortcuts, k.tools = bar_list_of(shortcuts[:]), bar_list_of(tools[:])
	dock_reset(k)
}

bar_list :: proc(app: ^App, which: Bar_Which) -> ^Bar_List {
	return &app.kit.shortcuts if which == .Shortcuts else &app.kit.tools
}

// The commands bar `which` (the column or the strip) shows.
bar_used :: proc(app: ^App, which: Bar_Which) -> []Bar_Slot {
	l := bar_list(app, which)
	return l.slots[:clamp(l.count, 0, bar_capacity(which))]
}

// How many slots bar `which` may have, and how many it has.
bar_capacity :: proc(which: Bar_Which) -> int {
	switch which {
	case .Shortcuts: return SHORTCUTS_MAX
	case .Tools:     return TOOLS_MAX
	case .Dock:      return DOCK_SLOTS
	}
	return 0
}

bar_count :: proc(app: ^App, which: Bar_Which) -> ^int {
	if which == .Dock do app.kit.dock_count = len(dock_used(app))
	return &app.kit.dock_count if which == .Dock else &bar_list(app, which).count
}

// Whether bar `which` differs from a fresh install's.
bar_changed :: proc(app: ^App, which: Bar_Which) -> bool {
	if which == .Dock do return dock_changed(app)
	return bar_list_changed(&app.kit, which)
}

// Whether the column's or the strip's list differs from a fresh install's.
@(private = "file")
bar_list_changed :: proc(k: ^Kit_State, which: Bar_Which) -> bool {
	fresh: Bar_List
	if which == .Shortcuts {
		d := SHORTCUTS_DEFAULT
		fresh = bar_list_of(d[:])
	} else {
		d := TOOLS_DEFAULT
		fresh = bar_list_of(d[:])
	}
	l := &k.shortcuts if which == .Shortcuts else &k.tools
	return l.count != fresh.count || l.slots != fresh.slots
}

// The lines of the column and the strip, each written whole where it differs from a fresh
// install's (`bar_count <zone> N`, then `bar <zone> <slot> <command>`): the settings
// file's and a workspace's layout's.
bars_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	for which in ([2]Bar_Which{.Shortcuts, .Tools}) {
		if !bar_list_changed(k, which) do continue
		l := &k.shortcuts if which == .Shortcuts else &k.tools
		used := l.slots[:clamp(l.count, 0, bar_capacity(which))]
		fmt.sbprintfln(out, "bar_count %s %d", BAR_ZONES[which], len(used))
		for s, i in used do fmt.sbprintfln(out, "bar %s %d %s", BAR_ZONES[which], i, command_name(s.id, s.arg))
	}
}

// Reads a bar_count or bar line (`f` split by spaces), as bars_save writes them; a zone,
// slot or command that names nothing is passed over.
bars_load_line :: proc(k: ^Kit_State, f: []string) {
	switch f[0] {
	case "bar_count":
		if len(f) != 3 do return
		which, zone_ok := bar_zone(f[1])
		l := &k.shortcuts if which == .Shortcuts else &k.tools
		if n, ok := strconv.parse_int(f[2]); ok && zone_ok do l.count = clamp(n, 0, bar_capacity(which))
	case "bar":
		if len(f) != 4 do return
		which, zone_ok := bar_zone(f[1])
		slot, slot_ok := strconv.parse_int(f[2])
		if !zone_ok || !slot_ok || slot < 0 || slot >= bar_capacity(which) do return
		l := &k.shortcuts if which == .Shortcuts else &k.tools
		if id, arg, ok := command_from_name(f[3]); ok && bar_lists(id) do l.slots[slot] = {id, arg}
	}
}

// Whether a command can sit on a bar: whatever Search runs, and Search itself. Not one
// that acts at the pointer over the model, which is on the bar when the button is pressed.
bar_lists :: proc(id: Command_Id) -> bool {
	return palette_lists(id) || id == .Command_Palette
}

// Opens Search to choose the command for `pick`.
bar_choose :: proc(app: ^App, pick: Bar_Pick) {
	palette_open(app)
	app.kit.palette_for = pick
}

// Puts command `s` where `pick` says: in its slot, or in a new slot there.
bar_put :: proc(app: ^App, pick: Bar_Pick, s: Bar_Slot) {
	count := bar_count(app, pick.which)
	if pick.add {
		if !bar_insert(app, pick.which, pick.slot) do return
	} else if pick.slot < 0 || pick.slot >= count^ {
		return
	}
	at := clamp(pick.slot, 0, count^ - 1)
	if pick.which == .Dock do app.kit.dock[at] = {command = s}
	else do bar_list(app, pick.which).slots[at] = s
	report(app, nil, {}, "%s now has %s", bar_title(pick.which), bar_label(s))
}

// "The right bar", for notes.
bar_title :: proc(which: Bar_Which) -> string {
	switch which {
	case .Shortcuts: return "The right bar"
	case .Tools:     return "The bottom bar"
	case .Dock:      return "The dock"
	}
	return ""
}

// Makes room for a slot at `at` in bar `which` (a copy of the slot before it, until
// bar_put fills it); false when the bar is full.
bar_insert :: proc(app: ^App, which: Bar_Which, at: int) -> bool {
	count := bar_count(app, which)
	if count^ >= bar_capacity(which) {
		report(app, nil, {.Warning}, "%s holds %d buttons at most: remove one first", bar_title(which), bar_capacity(which))
		return false
	}
	i := clamp(at, 0, count^)
	if which == .Dock {
		d := &app.kit.dock
		copy(d[i + 1:count^ + 1], d[i:count^])
	} else {
		l := bar_list(app, which)
		copy(l.slots[i + 1:count^ + 1], l.slots[i:count^])
	}
	count^ += 1
	return true
}

// Takes slot `slot` out of bar `which`; the dock keeps one at least.
bar_remove :: proc(app: ^App, which: Bar_Which, slot: int) {
	count := bar_count(app, which)
	if slot < 0 || slot >= count^ || (which == .Dock && count^ <= 1) do return
	if which == .Dock {
		d := &app.kit.dock
		copy(d[slot:count^ - 1], d[slot + 1:count^])
	} else {
		l := bar_list(app, which)
		copy(l.slots[slot:count^ - 1], l.slots[slot + 1:count^])
	}
	count^ -= 1
}

// Swaps slot `slot` of bar `which` with its neighbour `by` (-1 earlier, +1 later).
// Returns where it is now.
bar_move :: proc(app: ^App, which: Bar_Which, slot, by: int) -> int {
	count := bar_count(app, which)
	to := slot + by
	if slot < 0 || slot >= count^ || to < 0 || to >= count^ do return slot
	if which == .Dock {
		d := &app.kit.dock
		d[slot], d[to] = d[to], d[slot]
	} else {
		l := bar_list(app, which)
		l.slots[slot], l.slots[to] = l.slots[to], l.slots[slot]
	}
	return to
}

// A slot's Move earlier, Move later, Remove and Add after, as icon buttons in a popover's
// head; the dock's run left and right, the column's up and down. True when the popover
// should close (its slot went, or a new one is being chosen).
bar_slot_actions :: proc(app: ^App, which: Bar_Which, slot: int) -> (close: bool) {
	k := &app.kit
	ctx := &k.ctx
	count := bar_count(app, which)^
	across := which != .Shortcuts
	if ui.icon_button(ctx, "Move earlier", ICON_CHEVRON_LEFT if across else ui.ICON_CHEVRON_UP, enabled = slot > 0) do bar_slot_moved(app, which, bar_move(app, which, slot, -1))
	if ui.icon_button(ctx, "Move later", ui.ICON_CHEVRON_RIGHT if across else ui.ICON_CHEVRON_DOWN, enabled = slot < count - 1) do bar_slot_moved(app, which, bar_move(app, which, slot, 1))
	if ui.icon_button(ctx, "Remove from the bar", ui.ICON_TRASH, enabled = which != .Dock || count > 1) {
		bar_remove(app, which, slot)
		return true
	}
	if ui.icon_button(ctx, "Add a button after it", ui.ICON_PLUS, enabled = count < bar_capacity(which)) {
		bar_choose(app, {which = which, slot = slot + 1, add = true})
		return true
	}
	return false
}

// Keeps the open popover on the slot it moved, now at `slot`.
@(private = "file")
bar_slot_moved :: proc(app: ^App, which: Bar_Which, slot: int) {
	k := &app.kit
	if which == .Dock do k.dock_slot = slot
	else do k.bar_slot.slot = slot
}

// What a slot's button is called: the command's label, or the bar's own short name.
bar_label :: proc(s: Bar_Slot) -> string {
	#partial switch s.id {
	case .Tool_Move:    return "Gizmo"
	case .Objects_Card: return "Objects"
	case .Inspector:    return "Palettes"
	}
	return command_label(s.id, s.arg)
}

// A slot's icon: the bars' own for the commands they always had, the command's, or a wand.
bar_icon :: proc(s: Bar_Slot) -> rune {
	#partial switch s.id {
	case .Tool_Move:       return ICON_GIZMO
	case .Remesh:          return ICON_REMESH
	case .Dyntopo_Toggle:  return ICON_DYNTOPO
	case .Retopologize:    return ICON_RETOPO
	case .Subdivide:       return ICON_SUBDIVIDE
	case .Live_Boolean:    return ICON_BOOLEAN
	case .Studio_Render:   return ui.ICON_SUN
	case .Ortho_Toggle:    return ICON_ORTHO
	case .Floor_Grid:      return ICON_FLOOR
	case .Symmetry_X:      return ICON_SYMMETRY
	case .Local_Symmetry:  return ICON_LOCAL_SYMMETRY
	case .Focus_Selected:  return ui.ICON_FRAME
	case .Wireframe:       return ICON_WIREFRAME
	case .Transparency:    return ICON_TRANSPARENCY
	case .Ghost_Object:    return ui.ICON_GHOST
	case .Solo_Object:     return ICON_SOLO
	case .Inspector:       return ui.ICON_PANEL
	case .Objects_Card:    return ICON_OBJECTS
	case .Command_Palette: return ui.ICON_SEARCH
	case .Brush:           return BRUSHES[sculpt.Brush_Kind(s.arg)].icon
	}
	return palette_icon({.Command, s.id, s.arg})
}

// The section a slot's long press opens, for the commands that have one.
@(private = "file")
bar_more_section :: proc(id: Command_Id) -> (Kit_Section, bool) {
	#partial switch id {
	case .Studio_Render:  return .Studio, true
	case .Floor_Grid:     return .Floor, true
	case .Dyntopo_Toggle: return .Topology, true
	case .Retopologize:   return .Retopo, true
	case .Subdivide:      return .Levels, true
	case .Live_Boolean:   return .Booleans, true
	}
	return {}, false
}

// Whether a slot's button does more on a long press (the triangle in its corner).
bar_has_more :: proc(id: Command_Id) -> bool {
	if _, ok := bar_more_section(id); ok do return true
	#partial switch id {
	case .Symmetry_X, .Wireframe, .Ortho_Toggle, .Tool_Move, .Remesh: return true
	}
	return false
}

// Whether a slot's button is lit: its command is on, or what it opens is showing.
bar_lit :: proc(app: ^App, s: Bar_Slot) -> bool {
	k := &app.kit
	p := &k.bar_pop
	if sec, ok := bar_more_section(s.id); ok && p.open && p.kind == .Section && p.section == sec do return true
	#partial switch s.id {
	case .Symmetry_X:      return app.brush.symmetry != {} || app.brush.radial_on
	case .Tool_Move:       return app.tool == .Move
	case .Remesh:          return bar_pop_showing(app, .Remesh_Quick)
	case .Shading_Menu:    return bar_pop_showing(app, .Shading)
	case .Camera_Menu:     return bar_pop_showing(app, .Camera)
	case .Inspector:       return k.inspector && !side_panel_open(k)
	case .Command_Palette: return k.palette
	}
	return command_checked(app, s.id, s.arg)
}

// Whether a slot's button takes a tap: Retopologize opens its section whatever the object.
bar_enabled :: proc(app: ^App, s: Bar_Slot) -> bool {
	return s.id == .Retopologize || command_enabled(app, s.id, s.arg)
}

// What a tap on a slot's button does, the button at `at`, its popovers opening `side` of
// it: Shading and Camera open their menu beside it, Retopologize its section; the rest run.
bar_slot_run :: proc(app: ^App, s: Bar_Slot, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	#partial switch s.id {
	case .Shading_Menu, .Camera_Menu:
		kind := Bar_Pop_Kind.Shading if s.id == .Shading_Menu else .Camera
		k.bar_at[kind], k.bar_side[kind] = at, side
	case .Retopologize:
		bar_pop_toggle(app, .Section, at, side, .Retopo)
		return
	case .Command_Palette:
		if k.palette {
			palette_close(app)
			return
		}
	}
	command_run(app, s.id, s.arg)
}

// What a long press (or a right-click) on a slot's button does, for one that has more.
bar_slot_more :: proc(app: ^App, s: Bar_Slot, at: ui.Rect, side: ui.Side) {
	if sec, ok := bar_more_section(s.id); ok {
		bar_pop_toggle(app, .Section, at, side, sec)
		return
	}
	#partial switch s.id {
	case .Symmetry_X:   bar_pop_toggle(app, .Symmetry, at, side)
	case .Wireframe:    bar_pop_toggle(app, .Polyframe, at, side)
	case .Ortho_Toggle: bar_pop_toggle(app, .Camera, at, side)
	case .Tool_Move:    tool_settings_open(app, .Move)
	case .Remesh:       remesh_quick_open(app, at, side)
	}
}

// Slot `slot` of bar `which` as its button, `size` points (0 for the kit's): a tap runs
// it (bar_slot_run) and a long press does its more (bar_slot_more), or while customising a
// tap opens the slot's popover and the button is ringed.
bar_slot_button :: proc(app: ^App, which: Bar_Which, slot: int, s: Bar_Slot, size: f32 = 0) {
	k := &app.kit
	ctx := &k.ctx
	side := bar_side(which)
	more := bar_has_more(s.id)
	name := fmt.tprintf("%s##%v %d", bar_label(s), which, slot)
	if ui.icon_button(ctx, name, bar_icon(s), bar_lit(app, s), k.bars_edit || bar_enabled(app, s), command_hint(app, s.id, s.arg), size, more && !k.bars_edit) {
		if k.bars_edit do bar_slot_open(app, which, slot, ctx.last_rect)
		else do bar_slot_run(app, s, ctx.last_rect, side)
	}
	if k.bars_edit {
		bar_edit_ring(app, ctx.last_rect)
		return
	}
	// A disabled button takes no press, so it has no long press either.
	if more && ctx.last_id != 0 && ui.secondary(ctx) do bar_slot_more(app, s, ctx.last_rect, side)
}

// Which side of a bar's buttons its popovers open.
bar_side :: proc(which: Bar_Which) -> ui.Side {
	return .Left if which == .Shortcuts else .Above_Center
}

// The ring round a slot while customising.
bar_edit_ring :: proc(app: ^App, r: ui.Rect) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.stroke_rect(ctx, {r.x + 2, r.y + 2, r.w - 4, r.h - 4}, t.radius_medium, ui.color_fade(t.accent, 0.8), 1.5)
}

// The + that ends a bar while customising: adds a slot at the end, its command chosen in
// Search.
bar_add_button :: proc(app: ^App, which: Bar_Which, at: int, size: f32 = 0) {
	ctx := &app.kit.ctx
	full := bar_count(app, which)^ >= bar_capacity(which)
	if ui.icon_button(ctx, fmt.tprintf("Add a button##%v", which), ui.ICON_PLUS, enabled = !full, size = size) do bar_choose(app, {which = which, slot = at, add = true})
}

// Opens the slot popover on slot `slot` of the column or the strip, over its button.
bar_slot_open :: proc(app: ^App, which: Bar_Which, slot: int, at: ui.Rect) {
	k := &app.kit
	if which == .Dock {
		dock_menu_open(app, slot, at)
		return
	}
	kit_floats_close(k)
	k.bar_slot = {open = true, which = which, slot = slot, at = at}
}

// The slot popover of the column or the strip: the command's name, its moves, and
// Another command..., which chooses one in Search.
kit_bar_slot_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	m := &k.bar_slot
	used := bar_used(app, m.which)
	if m.slot >= len(used) do m.open = false
	if !ui.popover_begin(ctx, "bar slot", &m.open, m.at, bar_side(m.which), {direction = .Column, gap = 4, padding = 10, width = 268}) do return
	defer ui.popover_end(ctx)
	s := used[m.slot]
	ui.begin(ctx, "bar slot head", {direction = .Row, center = true})
	ui.begin(ctx, "bar slot title", {direction = .Column, width = 248 - t.target})
	ui.label(ctx, ui.text_fit(ctx, bar_label(s), t.title_size, 248 - t.target, .Semibold), t.title_size, t.text, .Semibold)
	ui.end(ctx)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do m.open = false
	ui.end(ctx)
	ui.begin(ctx, "bar slot moves", {direction = .Row, gap = 4})
	if bar_slot_actions(app, m.which, m.slot) do m.open = false
	ui.end(ctx)
	ui.paragraph(ctx, COMMANDS[s.id].help)
	if ui.menu_item(ctx, "Another command...", glyph = ui.ICON_SEARCH) {
		m.open = false
		bar_choose(app, {which = m.which, slot = m.slot})
	}
}

// Bar `which`'s commands by name, comma separated, for the exit stats ("none" for none).
bar_names :: proc(app: ^App, which: Bar_Which) -> string {
	used := bar_used(app, which)
	if len(used) == 0 do return "none"
	b := strings.builder_make(context.temp_allocator)
	for s, i in used {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, command_name(s.id, s.arg))
	}
	return strings.to_string(b)
}
