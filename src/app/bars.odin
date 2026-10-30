package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../poly"
import "../sculpt"
import "../ui"

// The bars the user arranges: the view rail down the pen side, the shelf's pages and its
// tool strip after All, the brush pie, and the off-hand island. Each is a list of registry commands (Bar_Slot,
// a pie's slot), as Nomad lets any tool be a shortcut; a button whose command does more
// than run (a long press that opens a menu, a lit state of its own) keeps that through
// bar_slot_button wherever it sits. Customise bars is an edit mode, as iPadOS's home
// screen has: every slot it can change is ringed, a tap opens the slot's popover (another
// command from Search, move it, remove it, add one after it), a + ends each bar, and Done
// or Escape ends it.

Bar_Slot :: Pie_Slot

Bar_Which :: enum u8 {
	Tools, // the shelf's tool strip, after All (lens_shelf.odin)
	View_Rail, // the view rail, down the pen side (lens_chrome.odin)
	// The shelf's pages (lens_shelf.odin), in Shelf_Page's order: the six built in, then
	// the pages the person adds.
	Shelf_Sculpt,
	Shelf_Paint,
	Shelf_Move,
	Shelf_Curve,
	Shelf_Model,
	Shelf_Render,
	Shelf_Extra_1,
	Shelf_Extra_2,
	Shelf_Extra_3,
	Shelf_Extra_4,
	Shelf_Extra_5,
	Shelf_Extra_6,
	Brush_Pie, // the brush pie (pie.odin): eight slots, clockwise from the top
	// The off-hand island (lens_chrome.odin): the brush's values and any command, down the
	// off-hand side. Last, as settings name bars by zone and the shelf's pages count from
	// Shelf_Sculpt.
	Offhand,
	// The person's own docks (user_docks.odin), made in Arrange: Dock_1 + i is Kit_State.docks[i]'s.
	Dock_1,
	Dock_2,
	Dock_3,
	Dock_4,
}

// The bars a workspace's layout holds: the shelf's pages and the brush pie hold the
// person's brushes, and the island the person's values, which are no layout's; the
// person's own docks are the screen's, as the rail is.
@(rodata)
BAR_LAYOUT := [?]Bar_Which{.Tools, .View_Rail, .Dock_1, .Dock_2, .Dock_3, .Dock_4}

// Each bar's name in settings.txt: the zone of the screen it holds, so a later layout that
// moves bars about keeps each one's buttons by where they are. The tool strip keeps the
// name it had when it stood on the bottom bar; the earlier right bar's `right_rail` lines
// and the dock's `dock` lines name no bar now and are passed over.
@(rodata)
BAR_ZONES := [Bar_Which]string {
	.Tools        = "bottom_tools",
	.View_Rail    = "view_rail",
	.Shelf_Sculpt = "shelf_sculpt",
	.Shelf_Paint  = "shelf_paint",
	.Shelf_Move   = "shelf_move",
	.Shelf_Curve  = "shelf_curve",
	.Shelf_Model  = "shelf_model",
	.Shelf_Render = "shelf_render",
	.Shelf_Extra_1 = "shelf_extra_1",
	.Shelf_Extra_2 = "shelf_extra_2",
	.Shelf_Extra_3 = "shelf_extra_3",
	.Shelf_Extra_4 = "shelf_extra_4",
	.Shelf_Extra_5 = "shelf_extra_5",
	.Shelf_Extra_6 = "shelf_extra_6",
	.Brush_Pie    = "brush_pie",
	.Offhand      = "offhand_island",
	.Dock_1       = "dock_1",
	.Dock_2       = "dock_2",
	.Dock_3       = "dock_3",
	.Dock_4       = "dock_4",
}

// The bar a zone name names.
bar_zone :: proc(name: string) -> (Bar_Which, bool) {
	for zone, which in BAR_ZONES do if zone == name do return which, true
	return {}, false
}

TOOLS_MAX :: 8
VIEW_RAIL_MAX :: 12
OFFHAND_MAX :: 8
USER_DOCK_MAX :: 12
// The most slots any bar holds: the view rail's, and a shelf page's SHELF_MAX.
BAR_SLOTS_MAX :: 12

// A bar's commands, `count` of them in use, and how each value item among them shows
// (brush_values.odin; nothing for any other command).
Bar_List :: struct {
	slots: [BAR_SLOTS_MAX]Bar_Slot,
	looks: [BAR_SLOTS_MAX]Value_Look,
	count: int,
}

// What a fresh install has: the gizmo and the mesh tools after All.
TOOLS_DEFAULT :: [?]Bar_Slot{{.Tool_Move, 0}, {.Remesh, 0}, {.Dyntopo_Toggle, 0}, {.Retopologize, 0}, {.Subdivide, 0}, {.Live_Boolean, 0}}
// The view rail's eight one-tap view tools, as the mockups have them: the view
// layout, the passes, the camera, framing, symmetry, the wireframe, the lights and the
// mini view.
VIEW_RAIL_DEFAULT :: [?]Bar_Slot {
	{.View_Layout_Menu, 0}, {.Pass_Menu, 0}, {.Camera_Menu, 0}, {.Focus_Selected, 0}, {.Symmetry_X, 0}, {.Wireframe, 0},
	{.Show_Section, int(Kit_Section.Lights)}, {.Thumbnail, 0},
}

// The island a fresh install has: Size and Strength as tall sliders.
OFFHAND_DEFAULT :: [?]Bar_Slot{{.Brush_Value, int(Brush_Value.Size)}, {.Brush_Value, int(Brush_Value.Strength)}}

// A slot the palette is choosing a command for: slot `slot` of bar `which`, or with `add`
// set a new slot put in at `slot`.
Bar_Pick :: struct {
	which: Bar_Which,
	slot:  int,
	add:   bool,
}

// The popover a tap on a slot opens while customising.
Bar_Slot_Menu :: struct {
	open:  bool,
	which: Bar_Which,
	slot:  int,
	at:    ui.Rect,
}

bar_list_of :: proc(slots: []Bar_Slot, look := Value_Look.Slider) -> (l: Bar_List) {
	copy(l.slots[:], slots)
	l.count = len(slots)
	for &x in l.looks do x = look
	return
}

// Puts every bar back as a fresh install has it.
bars_reset :: proc(k: ^Kit_State) {
	bar_lists_reset(k)
	shelf_reset(k)
	k.brush_pie = bar_fresh(.Brush_Pie)
	k.offhand = bar_fresh(.Offhand)
	user_docks_clear(k)
}

// Puts the strip and the view rail (the bars a layout holds) back as a fresh install has
// them.
bar_lists_reset :: proc(k: ^Kit_State) {
	for which in BAR_LAYOUT do bar_list_k(k, which)^ = bar_fresh(which)
}

// A fresh install's list for the strip, the view rail, a shelf page or the brush pie.
bar_fresh :: proc(which: Bar_Which) -> Bar_List {
	switch which {
	case .Shelf_Sculpt, .Shelf_Paint, .Shelf_Move, .Shelf_Curve, .Shelf_Model, .Shelf_Render, .Shelf_Extra_1, .Shelf_Extra_2, .Shelf_Extra_3, .Shelf_Extra_4, .Shelf_Extra_5, .Shelf_Extra_6:
		page, _ := shelf_page_of(which)
		return shelf_fresh(page)
	case .View_Rail:
		d := VIEW_RAIL_DEFAULT
		return bar_list_of(d[:], bar_default_look(which))
	case .Brush_Pie:
		d := BRUSH_PIE_DEFAULT
		return bar_list_of(d[:], bar_default_look(which))
	case .Offhand:
		d := OFFHAND_DEFAULT
		return bar_list_of(d[:], bar_default_look(which))
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		// A new dock is empty but for its +.
		return bar_list_of({}, bar_default_look(which))
	case .Tools:
	}
	d := TOOLS_DEFAULT
	return bar_list_of(d[:], bar_default_look(which))
}

bar_list :: proc(app: ^App, which: Bar_Which) -> ^Bar_List {
	return bar_list_k(&app.kit, which)
}

// The list behind the strip, the view rail, a shelf page or the brush pie.
bar_list_k :: proc(k: ^Kit_State, which: Bar_Which) -> ^Bar_List {
	switch which {
	case .Shelf_Sculpt, .Shelf_Paint, .Shelf_Move, .Shelf_Curve, .Shelf_Model, .Shelf_Render, .Shelf_Extra_1, .Shelf_Extra_2, .Shelf_Extra_3, .Shelf_Extra_4, .Shelf_Extra_5, .Shelf_Extra_6:
		page, _ := shelf_page_of(which)
		return &k.shelf.lists[page]
	case .View_Rail: return &k.view_rail
	case .Brush_Pie: return &k.brush_pie
	case .Offhand:   return &k.offhand
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		i, _ := user_dock_of(which)
		return &k.docks[i].list
	case .Tools:
	}
	return &k.tools
}

// The commands bar `which` shows.
bar_used :: proc(app: ^App, which: Bar_Which) -> []Bar_Slot {
	l := bar_list(app, which)
	return l.slots[:clamp(l.count, 0, bar_capacity(which))]
}

// How many slots bar `which` may have, and how many it has.
bar_capacity :: proc(which: Bar_Which) -> int {
	switch which {
	case .Tools:     return TOOLS_MAX
	case .View_Rail: return VIEW_RAIL_MAX
	case .Shelf_Sculpt, .Shelf_Paint, .Shelf_Move, .Shelf_Curve, .Shelf_Model, .Shelf_Render, .Shelf_Extra_1, .Shelf_Extra_2, .Shelf_Extra_3, .Shelf_Extra_4, .Shelf_Extra_5, .Shelf_Extra_6: return SHELF_MAX
	case .Brush_Pie: return PIE_SLOTS
	case .Offhand:   return OFFHAND_MAX
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4: return USER_DOCK_MAX
	}
	return 0
}

bar_count :: proc(app: ^App, which: Bar_Which) -> ^int {
	return &bar_list(app, which).count
}

// Whether bar `which` differs from a fresh install's.
bar_changed :: proc(app: ^App, which: Bar_Which) -> bool {
	return bar_list_changed(&app.kit, which)
}

// Whether bar `which`'s list differs from a fresh install's.
@(private = "file")
bar_list_changed :: proc(k: ^Kit_State, which: Bar_Which) -> bool {
	fresh := bar_fresh(which)
	l := bar_list_k(k, which)
	if l.count != fresh.count || l.slots != fresh.slots do return true
	for i in 0 ..< clamp(l.count, 0, bar_capacity(which)) {
		if _, value := value_of(l.slots[i]); value && bar_look(k, which, i) != bar_default_look(which) do return true
	}
	return false
}

// Whether a workspace's layout holds bar `which`.
bar_in_layout :: proc(which: Bar_Which) -> bool {
	for w in BAR_LAYOUT do if w == which do return true
	return false
}

// The lines of every bar, each written whole where it differs from a fresh install's
// (`bar_count <zone> N`, then `bar <zone> <slot> <command>`, and `bar_look <zone> <slot>
// <look>` after a value item that does not show as the bar's values do at first): the
// settings file's, and with `layout` a workspace's layout's, which holds only BAR_LAYOUT's
// bars. An older build passes over the bar_look lines and keeps the values.
bars_save :: proc(k: ^Kit_State, out: ^strings.Builder, layout := false) {
	for which in Bar_Which {
		if layout && !bar_in_layout(which) do continue
		// A dock is the layout's alone, and only while it is in use.
		if i, dock := user_dock_of(which); dock && (!layout || !k.docks[i].used) do continue
		if !bar_list_changed(k, which) do continue
		l := bar_list_k(k, which)
		used := l.slots[:clamp(l.count, 0, bar_capacity(which))]
		fmt.sbprintfln(out, "bar_count %s %d", BAR_ZONES[which], len(used))
		for s, i in used {
			fmt.sbprintfln(out, "bar %s %d %s", BAR_ZONES[which], i, command_name(s.id, s.arg))
			if _, value := value_of(s); value && bar_look(k, which, i) != bar_default_look(which) {
				fmt.sbprintfln(out, "bar_look %s %d %v", BAR_ZONES[which], i, bar_look(k, which, i))
			}
		}
	}
}

// Reads a bar_count or bar line (`f` split by spaces), as bars_save writes them; a zone,
// slot or command that names nothing is passed over.
bars_load_line :: proc(k: ^Kit_State, f: []string) {
	switch f[0] {
	case "bar_count":
		if len(f) != 3 do return
		which, zone_ok := bar_zone(f[1])
		l := bar_list_k(k, which)
		if n, ok := strconv.parse_int(f[2]); ok && zone_ok do l.count = clamp(n, 0, bar_capacity(which))
	case "bar":
		if len(f) != 4 do return
		which, zone_ok := bar_zone(f[1])
		slot, slot_ok := strconv.parse_int(f[2])
		if !zone_ok || !slot_ok || slot < 0 || slot >= bar_capacity(which) do return
		l := bar_list_k(k, which)
		if id, arg, ok := command_from_name(f[3]); ok && bar_lists(id) {
			l.slots[slot] = {id, arg}
			l.looks[slot] = bar_default_look(which)
		}
	case "bar_look":
		if len(f) != 4 do return
		which, zone_ok := bar_zone(f[1])
		slot, slot_ok := strconv.parse_int(f[2])
		if !zone_ok || !slot_ok || slot < 0 || slot >= bar_capacity(which) do return
		for look in Value_Look do if fmt.tprint(look) == f[3] do bar_list_k(k, which).looks[slot] = look
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
	bar_list(app, pick.which).slots[at] = s
	bar_list(app, pick.which).looks[at] = bar_default_look(pick.which)
	report(app, nil, {}, "%s now has %s", bar_title(app, pick.which), bar_label(s))
}

// "The view rail", for notes.
bar_title :: proc(app: ^App, which: Bar_Which) -> string {
	switch which {
	case .Tools:     return "The shelf's tools"
	case .View_Rail: return "The view rail"
	case .Shelf_Sculpt, .Shelf_Paint, .Shelf_Move, .Shelf_Curve, .Shelf_Model, .Shelf_Render, .Shelf_Extra_1, .Shelf_Extra_2, .Shelf_Extra_3, .Shelf_Extra_4, .Shelf_Extra_5, .Shelf_Extra_6:
		page, _ := shelf_page_of(which)
		return fmt.tprintf("The shelf's %s page", shelf_page_name(&app.kit, page))
	case .Brush_Pie:    return "The brush pie"
	case .Offhand:      return "The off-hand island"
	case .Dock_1, .Dock_2, .Dock_3, .Dock_4:
		i, _ := user_dock_of(which)
		return USER_DOCK_NAMES[i]
	}
	return ""
}

// Makes room for a slot at `at` in bar `which` (a copy of the slot before it, until
// bar_put fills it); false when the bar is full.
bar_insert :: proc(app: ^App, which: Bar_Which, at: int) -> bool {
	count := bar_count(app, which)
	if count^ >= bar_capacity(which) {
		report(app, nil, {.Warning}, "%s holds %d buttons at most: remove one first", bar_title(app, which), bar_capacity(which))
		return false
	}
	// A shelf page takes no tile it has no room to show on this screen, even at its
	// narrowest, rather than add it out of sight.
	if page, ok := shelf_page_of(which); ok {
		sh := &app.kit.shelf
		if page == sh.page && sh.fits > 0 && count^ >= sh.fits {
			report(app, nil, {.Warning}, "%s has room for %d tiles on this screen: remove one first, or put it on another page", bar_title(app, which), sh.fits)
			return false
		}
	}
	i := clamp(at, 0, count^)
	l := bar_list(app, which)
	copy(l.slots[i + 1:count^ + 1], l.slots[i:count^])
	copy(l.looks[i + 1:count^ + 1], l.looks[i:count^])
	count^ += 1
	return true
}

// Takes slot `slot` out of bar `which`.
bar_remove :: proc(app: ^App, which: Bar_Which, slot: int) {
	count := bar_count(app, which)
	if slot < 0 || slot >= count^ do return
	l := bar_list(app, which)
	copy(l.slots[slot:count^ - 1], l.slots[slot + 1:count^])
	copy(l.looks[slot:count^ - 1], l.looks[slot + 1:count^])
	count^ -= 1
}

// Swaps slot `slot` of bar `which` with its neighbour `by` (-1 earlier, +1 later).
// Returns where it is now.
bar_move :: proc(app: ^App, which: Bar_Which, slot, by: int) -> int {
	count := bar_count(app, which)
	to := slot + by
	if slot < 0 || slot >= count^ || to < 0 || to >= count^ do return slot
	l := bar_list(app, which)
	l.slots[slot], l.slots[to] = l.slots[to], l.slots[slot]
	l.looks[slot], l.looks[to] = l.looks[to], l.looks[slot]
	return to
}

// A slot's Move earlier, Move later, Remove and Add after, as icon buttons in a popover's
// head; a row's run left and right, the rail's up and down. True when the popover
// should close (its slot went, or a new one is being chosen).
bar_slot_actions :: proc(app: ^App, which: Bar_Which, slot: int) -> (close: bool) {
	k := &app.kit
	ctx := &k.ctx
	count := bar_count(app, which)^
	across := !bar_column(which)
	if ui.icon_button(ctx, "Move earlier", ICON_CHEVRON_LEFT if across else ui.ICON_CHEVRON_UP, enabled = slot > 0) do bar_slot_moved(app, bar_move(app, which, slot, -1))
	if ui.icon_button(ctx, "Move later", ui.ICON_CHEVRON_RIGHT if across else ui.ICON_CHEVRON_DOWN, enabled = slot < count - 1) do bar_slot_moved(app, bar_move(app, which, slot, 1))
	if ui.icon_button(ctx, "Remove from the bar", ui.ICON_TRASH) {
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
bar_slot_moved :: proc(app: ^App, slot: int) {
	app.kit.bar_slot.slot = slot
}

// What a slot's button is called: the command's label, or the bar's own short name.
bar_label :: proc(s: Bar_Slot) -> string {
	#partial switch s.id {
	case .Tool_Move:    return "Gizmo"
	case .Objects_Card: return "Objects"
	case .Inspector:    return "Palettes"
	case .Show_Section: return tray_section_title(Kit_Section(s.arg))
	case .Add_Cage:     return poly.PRIMITIVE_NAMES[poly.Primitive(s.arg)]
	case .Apply_Cage:   return "To sculpt"
	case .Model_Action: return MODEL_ACTION_NAMES[Model_Action(s.arg)]
	// A tile has room for one word of a mode's name.
	case .Shading_Mode: return "Preview" if Shading_Mode(s.arg) == .Material_Preview else SHADING_MODE_NAMES[Shading_Mode(s.arg)]
	case .Solid_Lighting: return SOLID_LIGHTING_NAMES[Solid_Lighting(s.arg)]
	case .Brush_Value:  if v, ok := value_of(s); ok do return BRUSH_VALUE_NAMES[v]
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
	case .Camera_Menu:     return ICON_CAMERA
	case .Shading_Menu:    return ICON_SHADING
	case .Thumbnail:       return ICON_MINI_VIEW
	case .View_Layout_Menu: return ICON_VIEW_LAYOUT
	case .Pass_Menu:       return ICON_PASSES
	case .Show_Section:    if Kit_Section(s.arg) == .Lights do return ui.ICON_SUN
	case .Brush_Value:     if v, ok := value_of(s); ok do return BRUSH_VALUE_ICONS[v]
	}
	return palette_icon({.Command, s.id, s.arg})
}

// The section a slot's long press opens, for the commands that have one.
@(private = "file")
bar_more_section :: proc(id: Command_Id) -> (Kit_Section, bool) {
	#partial switch id {
	case .Studio_Render:  return .Render, true
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
	case .View_Layout_Menu: return bar_pop_showing(app, .View_Layout)
	case .Pass_Menu:       return k.passes.menu
	case .Show_Section:    return p.open && p.kind == .Section && p.section == Kit_Section(s.arg)
	case .Brush_Value:     return p.open && p.kind == .Value && int(p.value) == s.arg
	case .Inspector:       return tray_shown(app)
	case .Command_Palette: return k.palette
	}
	return command_checked(app, s.id, s.arg)
}

// Whether a slot's button takes a tap: whether its command can run now.
bar_enabled :: proc(app: ^App, s: Bar_Slot) -> bool {
	return command_enabled(app, s.id, s.arg)
}

// What a tap on a slot's button does, the button at `at`, its popovers opening `side` of
// it: Shading, Camera, View layout and Passes open their menu beside it, a shown section
// its section; the rest run (Retopologize too, its section being its long press's).
bar_slot_run :: proc(app: ^App, s: Bar_Slot, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	#partial switch s.id {
	case .Shading_Menu, .Camera_Menu, .View_Layout_Menu:
		kind := Bar_Pop_Kind.Shading if s.id == .Shading_Menu else .Camera if s.id == .Camera_Menu else .View_Layout
		k.bar_at[kind], k.bar_side[kind] = at, side
	case .Pass_Menu:
		k.passes.menu_at, k.passes.menu_side = at, side
	case .Show_Section:
		// A section on a bar opens beside its button rather than in the tray across the
		// window.
		bar_pop_toggle(app, .Section, at, side, Kit_Section(s.arg))
		return
	case .Brush_Value:
		if v, ok := value_of(s); ok do value_pop_toggle(app, v, at, side)
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
bar_slot_button :: proc(app: ^App, which: Bar_Which, slot: int, s: Bar_Slot, size: f32 = 0, tile := false) {
	k := &app.kit
	ctx := &k.ctx
	if v, ok := value_of(s); ok {
		cell: [2]f32 = {size, ui.BRUSH_TILE.y - 2} if size > 0 else {}
		if size <= 0 && which != .Offhand && bar_column(which) do cell = {ui.BRUSH_TILE.x if tile else ctx.theme.target, VALUE_CHIP.y - 4}
		value_item(app, which, slot, v, cell, column = bar_column(which))
		return
	}
	side := bar_side(app, which)
	more := bar_has_more(s.id)
	name := fmt.tprintf("%s##%v %d", bar_label(s), which, slot)
	// A dock of Tiles shows each command's name under its icon, as the shelf's brushes do.
	enabled := k.bars_edit || bar_enabled(app, s)
	pressed := ui.brush_tile(ctx, name, bar_icon(s), bar_lit(app, s), command_hint(app, s.id, s.arg), enabled, more && !k.bars_edit) if tile else ui.icon_button(ctx, name, bar_icon(s), bar_lit(app, s), enabled, command_hint(app, s.id, s.arg), size, more && !k.bars_edit)
	if pressed {
		if k.bars_edit do bar_slot_open(app, which, slot, ctx.last_rect)
		else do bar_slot_run(app, s, ctx.last_rect, side)
	}
	if k.bars_edit {
		bar_edit_ring(app, ctx.last_rect)
		return
	}
	job_ring(app, s.id, ctx.last_rect)
	// A disabled button takes no press, so it has no long press either.
	if more && ctx.last_id != 0 && ui.secondary(ctx) do bar_slot_more(app, s, ctx.last_rect, side)
}

// Which side of a bar's buttons its popovers open: away from the edge the rail and the
// island stand on (bar_place_side), and above the rows.
bar_side :: proc(app: ^App, which: Bar_Which) -> ui.Side {
	#partial switch which {
	case .View_Rail: return bar_place_side(app, .Rail)
	case .Offhand:   return bar_place_side(app, .Offhand)
	}
	if i, dock := user_dock_of(which); dock do return bar_place_side(app, user_dock_place(i))
	return .Above_Center
}

// Whether bar `which` runs down the window, a column of buttons.
bar_column :: proc(which: Bar_Which) -> bool {
	_, dock := user_dock_of(which)
	return which == .View_Rail || which == .Offhand || dock
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

// Opens the slot popover on slot `slot` of bar `which`, over its button.
bar_slot_open :: proc(app: ^App, which: Bar_Which, slot: int, at: ui.Rect) {
	k := &app.kit
	kit_floats_close(k)
	k.bar_slot = {open = true, which = which, slot = slot, at = at}
}

// The slot popover: the command's name, its moves, and
// Another command..., which chooses one in Search.
kit_bar_slot_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	m := &k.bar_slot
	used := bar_used(app, m.which)
	if m.slot >= len(used) do m.open = false
	if !ui.popover_begin(ctx, "bar slot", &m.open, m.at, bar_side(app, m.which), {direction = .Column, gap = 4, padding = 10, width = 268}) do return
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
