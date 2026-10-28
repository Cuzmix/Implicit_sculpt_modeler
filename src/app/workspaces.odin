package main

import "core:fmt"
import "core:strings"
import "../ui"

// Workspaces (Lens): named layouts of the interface. A layout is which bars show, which
// panels are open, the two columns, the pinned sections, where each floating panel sits,
// the bars' buttons and the viewport's pass; the scene, the brush and the view's toggles
// are no part of it. Four come with the
// app and up to WORKSPACE_OWN more are the user's own. Each keeps the layout as saved and,
// while another is current, the layout as it was left, so switching loses nothing; the
// top bar's switcher shows an amber dot while the current layout differs from its saved
// one. A layout is kept as text, the lines kit_layout_text writes, so comparing two is
// comparing strings and the settings file stores them as they are.

// A part of the interface a workspace can hide. The top bar never hides: when a bar
// holding Undo and Redo, or Search and the tray's button, is hidden, they move into it.
Zone :: enum u8 {
	Brush_Bar, // down the left edge
	View_Bar, // down the right edge
	Dock, // along the bottom
	Wheel, // the modifier wheel
	Action_Bar, // the next steps over the dock
}

// The workspaces that come with the app, in the slots they always have.
Built_In :: enum u8 {
	Sculpt, // the layout as it has always been
	Focus, // the model, the dock and the wheel: nothing else in the way
	Inspect, // the statistics, the camera and the look, with four panes: curvature, normals and a front silhouette
	Studio, // the lights, the material and the environment, with a thumbnail view
}

WORKSPACE_OWN :: 8
WORKSPACE_SLOTS :: len(Built_In) + WORKSPACE_OWN
WORKSPACE_NAME :: 32
// The room the top bar's middle needs for the switcher to show (the file name shows in
// what is left, where it fits).
WORKSPACE_CHIP_ROOM :: 160

// The panels a layout opens and closes. Settings, Help, Macros and Library are opened
// from the menu and History by a long press on Undo, so none of them changes a layout.
LAYOUT_PANELS :: [?]Kit_Window{.Inspector, .Stats, .Objects, .Colors, .Thumbnail}
// The windows whose place and fold a layout keeps.
LAYOUT_WINDOWS :: [?]Kit_Window{.Inspector, .Stats, .History, .Objects, .Colors, .Thumbnail}

Workspace :: struct {
	used:  bool,
	name:  [WORKSPACE_NAME]u8, // an own workspace's; a built-in is named by its Built_In
	saved: string, // the layout as saved (heap)
	live:  string, // the layout as it was left while another is current (heap), or ""
}

Workspaces :: struct {
	list:     []Workspace, // WORKSPACE_SLOTS of them once kit_init made them (heap), slot by slot
	current:  int,
	modified: bool, // the current layout differs from its saved one, as of this frame
	menu:     bool, // the switcher's menu
	menu_at:  ui.Rect,
	deleting: bool, // the menu asks to confirm deleting the current workspace
	switches: int, // how many times the workspace changed (an exit stat)
	loaded:   bool, // the settings named workspaces (an older file names none)
	// Workspace files written and read (workspace_file.odin), for the exit stats.
	exports:  int,
	imports:  int,
}

// The workspaces as they start: the four built-ins, Sculpt current.
workspaces_init :: proc(k: ^Kit_State) {
	w := &k.workspaces
	w.list = make([]Workspace, WORKSPACE_SLOTS)
	for b in Built_In {
		ws := &w.list[int(b)]
		ws.used = true
		workspace_text_set(&ws.saved, built_in_layout(b))
	}
	w.current = int(Built_In.Sculpt)
}

workspaces_destroy :: proc(k: ^Kit_State) {
	for &ws in k.workspaces.list {
		delete(ws.saved)
		delete(ws.live)
		ws.saved, ws.live = "", ""
	}
	delete(k.workspaces.list)
	k.workspaces.list = nil
}

// Replaces the heap string `s` with a copy of `text`.
@(private = "file")
workspace_text_set :: proc(s: ^string, text: string) {
	delete(s^)
	s^ = strings.clone(text) if text != "" else ""
}

workspace_name :: proc(k: ^Kit_State, slot: int) -> string {
	if slot < len(Built_In) do return fmt.tprint(Built_In(slot))
	return rename_text(k.workspaces.list[slot].name[:])
}

workspace_built_in :: proc(slot: int) -> (Built_In, bool) {
	if slot < len(Built_In) do return Built_In(slot), true
	return {}, false
}

// The flag that says whether a layout panel is open.
@(private = "file")
layout_open :: proc(k: ^Kit_State, w: Kit_Window) -> ^bool {
	#partial switch w {
	case .Stats:     return &k.stats
	case .Objects:   return &k.objects_card
	case .Colors:    return &k.colors_card
	case .Thumbnail: return &k.thumbnail
	}
	return &k.inspector
}

// The layout as text: the lines of the hidden zones, the pass, the open panels, the windows' places,
// the columns and the pins, in that order. Places are written as they are for the
// right-handed layout, so a workspace saved with either hand reads the same with the other.
kit_layout_text :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	if k.hidden != {} {
		strings.write_string(&out, "hidden")
		for z in Zone do if z in k.hidden do fmt.sbprintf(&out, " %v", z)
		strings.write_byte(&out, '\n')
	}
	strings.write_string(&out, pass_layout_line(k))
	strings.write_string(&out, grid_layout_lines(k))
	strings.write_string(&out, "open")
	for w in LAYOUT_PANELS do if layout_open(k, w)^ do fmt.sbprintf(&out, " %v", w)
	strings.write_byte(&out, '\n')
	mirror := k.ctx.mirror
	for w in LAYOUT_WINDOWS {
		win := k.windows[w]
		if mirror do window_mirror(&win)
		window_save_line(&out, w, win)
	}
	if mirror do for &p in k.panels.pins do window_mirror(&p.window)
	panels_save(k, &out)
	if mirror do for &p in k.panels.pins do window_mirror(&p.window)
	// The right bar's column, the bottom bar's strip and the view rail, after a line that
	// says the layout holds them (one saved before it did keeps the bars as they are). The
	// dock holds the user's brushes, which are no layout's: it stays as it is in every
	// workspace.
	stack_layout_save(k, &out)
	stack_sizes_save(k, &out)
	strings.write_string(&out, "bars\n")
	bars_save(k, &out, layout = true)
	return strings.to_string(out)
}

// Puts the layout `text` in place: what it does not name is as it starts (closed,
// unmoved, unfolded, every bar shown), and what it names is read through the same lines
// the settings file uses. Floating menus close, as what they hung from may have gone.
kit_layout_put :: proc(k: ^Kit_State, text: string) {
	for w in LAYOUT_WINDOWS do k.windows[w] = {}
	for w in LAYOUT_PANELS do layout_open(k, w)^ = false
	panels_default(k)
	stack_default(k)
	k.hidden = {}
	// The pass is Shaded unless the layout names another; a peek ends with the layout.
	k.passes.pass, k.passes.chip_held, k.passes.key_held = .Shaded, false, false
	// One view unless the layout names a grid; the layout steps named another layout.
	k.grid.tree, k.grid.maximised = grid_preset_tree(.Single), 0
	k.grid.serial += 1
	k.grid.undo = {}
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		switch f[0] {
		case "hidden":
			for word in f[1:] do for z in Zone do if strings.equal_fold(word, fmt.tprint(z)) do k.hidden += {z}
		case "pass":
			pass_layout_read(k, f)
		case "panes", "grid", "pane":
			grid_layout_read(&k.grid, f)
		case "open":
			for word in f[1:] do for w in LAYOUT_PANELS do if strings.equal_fold(word, fmt.tprint(w)) do layout_open(k, w)^ = true
		case "window":
			for w in LAYOUT_WINDOWS do if len(f) > 1 && strings.equal_fold(f[1], fmt.tprint(w)) do window_load_line(k, f)
		case "column", "pinned":
			panels_load_line(k, f)
		case "stack":
			stack_layout_read(k, f)
		case "stack_size":
			stack_sizes_read(k, f)
		case "bars":
			bar_lists_reset(k)
		case "bar_count", "bar":
			bars_load_line(k, f)
		}
	}
	if k.ctx.mirror {
		for w in LAYOUT_WINDOWS do window_mirror(&k.windows[w])
		for &p in k.panels.pins do window_mirror(&p.window)
	}
	// The tray and the Objects card share a place: the card wins, as opening it does.
	if k.objects_card do k.inspector = false
	kit_floats_close(k)
	k.bar_scrub = {}
}

// A built-in workspace's layout, as kit_layout_text writes it.
built_in_layout :: proc(b: Built_In) -> string {
	text: string
	switch b {
	case .Sculpt:
		text = "open Inspector\n"
	case .Focus:
		text = "hidden Brush_Bar View_Bar Action_Bar\nopen\n"
	case .Inspect:
		text = "hidden Brush_Bar Dock\npanes h500 v500 0 1 v500 2 3\npane 1 Follow Curvature\npane 2 Follow Normals\npane 3 Front Silhouette\nopen Stats\ncolumn left Stats\ncolumn right Inspector section:Camera section:Look\n" +
			"pinned Camera 0 Start Start 0 0 0\npinned Look 0 Start Start 0 0 0\n"
	case .Studio:
		text = "open Thumbnail\ncolumn right Inspector section:Lights section:Material section:Environment\n" +
			"pinned Lights 0 Start Start 0 0 0\npinned Material 0 Start Start 0 0 0\npinned Environment 0 Start Start 0 0 0\n"
	}
	// Read and written again, so it is exactly what the layout writes when it is in place;
	// every built-in has the bars a fresh install has.
	s := new(Kit_State, context.temp_allocator)
	kit_layout_put(s, strings.concatenate({text, "bars\n"}, context.temp_allocator))
	return kit_layout_text(s)
}

// Once a frame: whether the current layout differs from its saved one.
workspaces_frame :: proc(k: ^Kit_State) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	w.modified = kit_layout_text(k) != w.list[w.current].saved
	if !w.menu do w.deleting = false
}

// Makes `slot` the current workspace, keeping the one left as it was left.
workspace_switch :: proc(k: ^Kit_State, slot: int) {
	w := &k.workspaces
	if slot < 0 || slot >= len(w.list) || !w.list[slot].used || slot == w.current do return
	from := &w.list[w.current]
	now := kit_layout_text(k)
	workspace_text_set(&from.live, now if now != from.saved else "")
	to := &w.list[slot]
	kit_layout_put(k, to.live if to.live != "" else to.saved)
	workspace_text_set(&to.live, "")
	w.current = slot
	w.switches += 1
}

// Saves the current layout as the current workspace's.
workspace_save :: proc(k: ^Kit_State) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	workspace_text_set(&w.list[w.current].saved, kit_layout_text(k))
}

// Saves the current layout as a new workspace of the user's own and makes it current;
// the one it came from goes back to its saved layout. False when all are in use.
workspace_save_as :: proc(k: ^Kit_State) -> bool {
	w := &k.workspaces
	if len(w.list) == 0 do return false
	slot := -1
	for i in len(Built_In) ..< WORKSPACE_SLOTS {
		if !w.list[i].used {
			slot = i
			break
		}
	}
	if slot < 0 do return false
	ws := &w.list[slot]
	ws^ = {used = true}
	// "Workspace 1", or the next number no own workspace is named with.
	for n := 1; ; n += 1 {
		name := fmt.tprintf("Workspace %d", n)
		taken := false
		for i in len(Built_In) ..< WORKSPACE_SLOTS do taken ||= w.list[i].used && i != slot && workspace_name(k, i) == name
		if taken do continue
		copy(ws.name[:len(ws.name) - 1], name)
		break
	}
	workspace_text_set(&ws.saved, kit_layout_text(k))
	workspace_text_set(&w.list[w.current].live, "")
	w.current = slot
	w.switches += 1
	return true
}

// Adds a workspace of the user's own named `name` (made unique among all the workspaces
// by a number after it) whose saved layout is `layout`, and switches to it, the one left
// kept as it was left. False when every own slot is in use.
workspace_add :: proc(k: ^Kit_State, name, layout: string) -> (slot: int, ok: bool) {
	w := &k.workspaces
	slot = -1
	for i in len(Built_In) ..< len(w.list) {
		if !w.list[i].used {
			slot = i
			break
		}
	}
	if slot < 0 do return
	unique := name
	for n := 2; ; n += 1 {
		taken := false
		for ws, i in w.list do taken ||= ws.used && workspace_name(k, i) == unique
		if !taken do break
		unique = fmt.tprintf("%s %d", name, n)
	}
	from := &w.list[w.current]
	now := kit_layout_text(k)
	workspace_text_set(&from.live, now if now != from.saved else "")
	ws := &w.list[slot]
	ws^ = {used = true}
	copy(ws.name[:len(ws.name) - 1], unique)
	workspace_text_set(&ws.saved, layout)
	kit_layout_put(k, layout)
	w.current = slot
	w.switches += 1
	return slot, true
}

// Puts the current workspace's saved layout back.
workspace_revert :: proc(k: ^Kit_State) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	kit_layout_put(k, w.list[w.current].saved)
}

// Puts a built-in workspace back as it comes with the app, saved and in place.
workspace_reset :: proc(k: ^Kit_State) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	b, ok := workspace_built_in(w.current)
	if !ok do return
	workspace_text_set(&w.list[w.current].saved, built_in_layout(b))
	workspace_revert(k)
}

// Deletes the current workspace, an own one, and goes to Sculpt as it was left.
workspace_delete :: proc(k: ^Kit_State) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	if _, built_in := workspace_built_in(w.current); built_in do return
	gone := w.current
	ws := &w.list[gone]
	workspace_text_set(&ws.live, "")
	sculpt := &w.list[int(Built_In.Sculpt)]
	kit_layout_put(k, sculpt.live if sculpt.live != "" else sculpt.saved)
	workspace_text_set(&sculpt.live, "")
	w.current = int(Built_In.Sculpt)
	workspace_text_set(&ws.saved, "")
	ws^ = {}
	w.switches += 1
}

// Renames own workspace `slot`; an empty name leaves it as it is.
workspace_rename :: proc(k: ^Kit_State, slot: int, name: string) {
	if _, built_in := workspace_built_in(slot); built_in || name == "" || slot >= len(k.workspaces.list) do return
	ws := &k.workspaces.list[slot]
	ws.name = {}
	copy(ws.name[:len(ws.name) - 1], name)
}

// Whether the workspace hides zone `z`.
zone_hidden :: proc(k: ^Kit_State, z: Zone) -> bool {
	return z in k.hidden
}

// Where the modifier wheel is, if anywhere: Off while the workspace hides it.
rail_shown :: proc(k: ^Kit_State) -> Rail_Side {
	return .Off if .Wheel in k.hidden else k.rail_side
}

// The workspace switcher in the top bar: the workspace's name, and an amber dot while its
// layout has changes not saved. A tap opens the menu under it.
kit_workspace_chip :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	w := &k.workspaces
	name := workspace_name(k, w.current)
	parts := []ui.Chip_Part{{text = name, strong = true}, {text = "   " if w.modified else ""}}
	keys := command_hint(app, .Workspace, w.current)
	if ui.chip(ctx, "Workspace", parts, keys) {
		was := w.menu
		kit_floats_close(k)
		w.menu = !was
	}
	r := ctx.last_rect
	w.menu_at = r
	if w.modified do ui.fill_circle(ctx, {r.x + r.w - 18, r.y + r.h * 0.5}, 4, t.warning)
}

// The switcher's menu: every workspace, then what can be done with the current one.
kit_workspace_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	w := &k.workspaces
	if !ui.popover_begin(ctx, "workspace menu", &w.menu, w.menu_at, .Below, {direction = .Column, gap = 0, padding = 6, width = 280}) do return
	defer ui.popover_end(ctx)
	picked := false
	if w.deleting {
		ui.caption(ctx, fmt.tprintf("  DELETE %s?", strings.to_upper(workspace_name(k, w.current), context.temp_allocator)))
		ui.paragraph(ctx, "Its layout goes for good; Sculpt takes its place.")
		yes, no := kit_button_pair(ctx, "Delete", "Keep it", tone_a = .Danger)
		if yes {
			workspace_delete(k)
			picked = true
		}
		if no do w.deleting = false
	} else {
		ui.caption(ctx, "  WORKSPACES")
		for ws, slot in w.list {
			if !ws.used do continue
			if command_menu_item(app, .Workspace, slot, label = workspace_name(k, slot)) do picked = true
		}
		ui.divider(ctx, across = true)
		picked ||= command_menu_item(app, .Workspace_Save)
		picked ||= command_menu_item(app, .Workspace_Save_As)
		picked ||= command_menu_item(app, .Workspace_Export)
		picked ||= command_menu_item(app, .Workspace_Import)
		picked ||= command_menu_item(app, .Workspace_Revert)
		if _, built_in := workspace_built_in(w.current); built_in {
			picked ||= command_menu_item(app, .Workspace_Reset)
		} else {
			if command_menu_item(app, .Workspace_Rename) do picked = true
			// Delete asks first: it is no step in the History, so nothing undoes it.
			if command_menu_item(app, .Workspace_Delete, tone = .Danger) do w.menu = true
		}
	}
	if picked do w.menu = false
}

// The settings lines of the workspaces: each own one's name, each layout that is not as
// it comes with the app, and which is current. The current one's live layout is the
// layout itself, which the window, column and pinned lines also hold for older versions.
workspaces_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	for &ws, slot in w.list {
		if !ws.used do continue
		b, built_in := workspace_built_in(slot)
		if !built_in do fmt.sbprintfln(out, "workspace %d %s", slot, preset_escape(workspace_name(k, slot)))
		if !built_in || ws.saved != built_in_layout(b) do fmt.sbprintfln(out, "workspace_saved %d %s", slot, preset_escape(ws.saved))
		live := kit_layout_text(k) if slot == w.current else ws.live
		if live != "" && live != ws.saved do fmt.sbprintfln(out, "workspace_live %d %s", slot, preset_escape(live))
	}
	fmt.sbprintfln(out, "workspace_current %d", w.current)
}

// Reads one workspace line (`f` split by spaces). A slot out of range, or a layout for a
// slot no line named, is passed over.
workspaces_load_line :: proc(k: ^Kit_State, f: []string) {
	w := &k.workspaces
	if len(f) < 2 || len(w.list) == 0 do return
	slot := -1
	for i in 0 ..< WORKSPACE_SLOTS do if f[1] == fmt.tprint(i) do slot = i
	if slot < 0 do return
	ws := &w.list[slot]
	w.loaded = true
	switch f[0] {
	case "workspace":
		if _, built_in := workspace_built_in(slot); built_in || len(f) != 3 do return
		ws.used = true
		ws.name = {}
		copy(ws.name[:len(ws.name) - 1], preset_unescape(f[2]))
	case "workspace_saved":
		if len(f) == 3 && ws.used do workspace_text_set(&ws.saved, preset_unescape(f[2]))
	case "workspace_live":
		if len(f) == 3 && ws.used do workspace_text_set(&ws.live, preset_unescape(f[2]))
	case "workspace_current":
		if ws.used do w.current = slot
	}
}

// After the settings are read: the current workspace's live layout is put in place. A
// file from before workspaces holds a layout and no workspace: that layout becomes
// Sculpt's, saved, so nothing moves and no dot shows.
workspaces_loaded :: proc(k: ^Kit_State) {
	w := &k.workspaces
	if len(w.list) == 0 do return
	if !w.loaded {
		workspace_text_set(&w.list[int(Built_In.Sculpt)].saved, kit_layout_text(k))
		return
	}
	// A layout saved before the grid was a tree names it with a grid line: written as the
	// tree once, so it reads as unchanged.
	for &each in w.list do if each.used {
		if up := grid_layout_upgrade(each.saved); up != each.saved do workspace_text_set(&each.saved, up)
		if up := grid_layout_upgrade(each.live); up != each.live do workspace_text_set(&each.live, up)
	}
	ws := &w.list[w.current]
	kit_layout_put(k, ws.live if ws.live != "" else ws.saved)
	workspace_text_set(&ws.live, "")
}
