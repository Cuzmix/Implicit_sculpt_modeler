package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../sculpt"
import "../ui"

// Workspaces: the person's own named layouts, a tab each in the top bar (after Blender's
// workspaces and 3D-Coat's rooms, as the overhaul's spaces were). A workspace decides only
// how the screen is laid out; the tool in hand decides what the hands do (hands.odin). The
// app ships starting workspaces, each an ordinary one the person may change or delete, and
// each tied to the tools that bring it: picking the Model tool brings Model, as the spaces
// did. A workspace the person makes is tied to nothing, so only its tab brings it, unless
// they tie a tool to it. Workspaces are the app's, saved with the settings, never in a
// scene file.

// How many workspaces there can be: fixed slots, so a key, a pie slot or a gesture bound to
// one keeps it while others come and go, as the macros' slots do.
WORKSPACE_SLOTS :: 12

// The layouts the app ships, which a workspace can start from and Reset layout puts back.
Starter :: enum u8 {
	None, // made by the person: its own base layout
	Sculpt,
	Model,
	Render,
}

@(rodata)
STARTER_NAMES := [Starter]string {
	.None   = "",
	.Sculpt = "Sculpt",
	.Model  = "Model",
	.Render = "Render",
}

// The icon a workspace's tab shows: its starter's, or the workspace icon for one of the
// person's own.
@(rodata)
STARTER_ICONS := [Starter]rune {
	.None   = ui.ICON_SPACE,
	.Sculpt = ui.ICON_SCULPT_SPACE,
	.Model  = ui.ICON_SPACE_MODEL,
	.Render = ui.ICON_SPACE_RENDER,
}

// What a tool in hand is, for the ties: picking a tool whose tie another workspace holds
// brings that workspace.
Tie :: enum u8 {
	Brushes, // the Brush tool with any brush but Mask and Smooth, which every kind of work uses
	Curve,
	Insert,
	Model,
	Look,
}

@(rodata)
TIE_NAMES := [Tie]string {
	.Brushes = "Sculpt brushes",
	.Curve   = "Curve tool",
	.Insert  = "Insert tool",
	.Model   = "Model tool",
	.Look    = "Look tool",
}

// Each starter's ties, as the spaces were tied to their tools.
@(rodata)
STARTER_TIES := [Starter]bit_set[Tie] {
	.None   = {},
	.Sculpt = {.Brushes, .Curve, .Insert},
	.Model  = {.Model},
	.Render = {.Look},
}

// The tool a workspace was left with, which its tab gives back when the tool in hand is
// not one of its own: the tool, the brush (a preset is kept too) and the Model action.
Workspace_Tool :: struct {
	kept:   bool, // false until the workspace was left once
	tool:   Tool,
	brush:  sculpt.Brush_Kind,
	preset: int,
	action: Model_Action,
}

// One workspace; a slot whose name is empty is free.
Workspace :: struct {
	name:    string, // heap
	tint:    u8, // its dot's colour, an index into Theme.tints
	starter: Starter,
	ties:    bit_set[Tie],
	kept:    string, // heap: its layout as last left, "" while it is its base
	base:    string, // heap, for one made by the person: what Reset layout puts back
	tool:    Workspace_Tool,
	page:    Shelf_Page, // the shelf's page it was left on (a page turn changes no layout)
}

Workspaces :: struct {
	list:     [WORKSPACE_SLOTS]Workspace,
	order:    [WORKSPACE_SLOTS]i8, // slots in tab order, -1 after the last
	current:  int, // the slot in front
	// The tie of the tool in hand as of the last frame (Move, Mask and Smooth leave it), and
	// whether the first frame has run.
	seen:     Tie,
	seen_set: bool,
	set:      bool,
	switches: int, // for the exit stats
}

// The workspaces as a fresh install has them: the starters, in order, Sculpt in front.
workspaces_init :: proc(k: ^Kit_State) {
	ws := &k.workspaces
	workspaces_clear(k)
	for s, i in ([]Starter{.Sculpt, .Model, .Render}) {
		w := &ws.list[i]
		w.name = strings.clone(STARTER_NAMES[s])
		w.starter, w.ties, w.tint = s, STARTER_TIES[s], u8(i)
		w.page = shelf_first_page(s)
		ws.order[i] = i8(i)
	}
	ws.current = 0
}

// Frees every workspace and leaves none.
workspaces_clear :: proc(k: ^Kit_State) {
	ws := &k.workspaces
	for &w in ws.list {
		delete(w.name)
		delete(w.kept)
		delete(w.base)
		w = {}
	}
	for &o in ws.order do o = -1
	ws.current, ws.set = 0, false
}

workspaces_destroy :: proc(k: ^Kit_State) {
	workspaces_clear(k)
	views_destroy(k)
}

// The workspaces' slots in tab order, in temp memory.
workspace_tabs :: proc(k: ^Kit_State) -> []int {
	out := make([dynamic]int, 0, WORKSPACE_SLOTS, context.temp_allocator)
	for o in k.workspaces.order {
		if o < 0 do break
		append(&out, int(o))
	}
	return out[:]
}

// Whether slot `slot` holds a workspace.
workspace_used :: proc(k: ^Kit_State, slot: int) -> bool {
	return slot >= 0 && slot < WORKSPACE_SLOTS && k.workspaces.list[slot].name != ""
}

// The workspace in front.
workspace_now :: proc(k: ^Kit_State) -> ^Workspace {
	return &k.workspaces.list[k.workspaces.current]
}

// The workspace that holds tie `t`, or -1.
workspace_holding :: proc(k: ^Kit_State, t: Tie) -> int {
	for w, slot in k.workspaces.list do if w.name != "" && t in w.ties do return slot
	return -1
}

// The tie of the tool in hand; `ok` false for Move, Mask and Smooth, which keep the tie
// they found.
tie_of :: proc(app: ^App) -> (t: Tie, ok: bool) {
	switch app.tool {
	case .Brush:
		if app.brush.kind == .Mask || app.brush.kind == .Smooth do return
		return .Brushes, true
	case .Curve:  return .Curve, true
	case .Insert: return .Insert, true
	case .Model:  return .Model, true
	case .Look:   return .Look, true
	case .Move:
	}
	return
}

// The tool tie `t` puts in hand.
@(private = "file")
tie_tool_put :: proc(app: ^App, t: Tie) {
	switch t {
	case .Brushes:
		if app.tool != .Brush || app.brush.kind == .Mask || app.brush.kind == .Smooth {
			preset_leave(app)
			app.tool, app.brush.kind = .Brush, .Clay
		}
	case .Curve:  app.tool = .Curve
	case .Insert: app.tool = .Insert
	case .Model:  app.tool = .Model
	case .Look:   app.tool = .Look
	}
}

workspace_tool_now :: proc(app: ^App) -> Workspace_Tool {
	return {kept = true, tool = app.tool, brush = app.brush.kind, preset = app.brush.preset, action = app.model.action}
}

// Gives workspace `slot` a tool of its own when it is tied and the tool in hand is not one
// of its ties: the tool it was left with when that is tied to it (with its brush or preset,
// and the Model action), else its first tie's. An untied workspace keeps the tool in hand.
@(private = "file")
workspace_tool_put :: proc(app: ^App, slot: int) {
	w := &app.kit.workspaces.list[slot]
	if w.ties == {} do return
	if t, ok := tie_of(app); ok && t in w.ties do return
	last := w.tool
	if last.kept {
		saved := app.tool
		app.tool = last.tool
		if t, ok := tie_of_tool(last); ok && t in w.ties {
			if last.tool == .Brush {
				if _, has := preset_at(app, last.preset); last.preset != 0 && has {
					preset_use(app, last.preset)
				} else {
					preset_leave(app)
					app.brush.kind = last.brush
				}
			}
			if last.tool == .Model do app.model.action = last.action
			return
		}
		app.tool = saved
	}
	for t in Tie do if t in w.ties {
		tie_tool_put(app, t)
		return
	}
}

// The tie a kept tool has, as tie_of reads the tool in hand.
@(private = "file")
tie_of_tool :: proc(last: Workspace_Tool) -> (t: Tie, ok: bool) {
	switch last.tool {
	case .Brush:
		if last.brush == .Mask || last.brush == .Smooth do return
		return .Brushes, true
	case .Curve:  return .Curve, true
	case .Insert: return .Insert, true
	case .Model:  return .Model, true
	case .Look:   return .Look, true
	case .Move:
	}
	return
}

// Switches to workspace `slot`: the one left keeps its tool, its shelf page and its layout;
// `slot` gets its layout and, with `restore` (a tab or a key, not a tie), a tool of its own
// (workspace_tool_put); the views end.
workspace_switch :: proc(app: ^App, slot: int, restore := true) {
	k := &app.kit
	ws := &k.workspaces
	if slot == ws.current || !workspace_used(k, slot) do return
	from := &ws.list[ws.current]
	from.tool = workspace_tool_now(app)
	from.page = k.shelf.page
	if restore do workspace_tool_put(app, slot)
	view_toggles_off(k)
	layout_switch(k, ws.current, slot)
	ws.current = slot
	k.shelf.page = ws.list[slot].page
	k.shelf.quick = false
	hands_update(app)
	if t, ok := tie_of(app); ok do ws.seen, ws.seen_set = t, true
	ws.switches += 1
}

// Once a frame, before the layout. The first frame gives the workspace in front a tool of
// its own, since start-up hands the Brush over after the settings put a workspace in front
// (main.odin), so a run that starts in Render holds the Look tool. Later, when the tool's tie
// changes to one another workspace holds, that workspace comes in front; a tie that stays the
// same (another brush picked) moves nothing, so a workspace of the person's own keeps its
// brushes. Nothing switches while a stroke is going on (a curve brush's path starts one).
workspace_follow :: proc(app: ^App) {
	ws := &app.kit.workspaces
	if !ws.set {
		ws.set = true
		workspace_tool_put(app, ws.current)
		hands_update(app)
		if t, ok := tie_of(app); ok do ws.seen, ws.seen_set = t, true
		return
	}
	hands_update(app)
	if app.stroke.active do return
	t, ok := tie_of(app)
	if !ok || (ws.seen_set && t == ws.seen) do return
	ws.seen, ws.seen_set = t, true
	if to := workspace_holding(&app.kit, t); to >= 0 && to != ws.current do workspace_switch(app, to, restore = false)
}

// The next tab's workspace after the one in front (the last wraps to the first).
workspace_next :: proc(k: ^Kit_State) -> int {
	tabs := workspace_tabs(k)
	for slot, i in tabs do if slot == k.workspaces.current do return tabs[(i + 1) % len(tabs)]
	return tabs[0]
}

// What the palette, Settings > Keys and scripts call slot `slot`'s workspace.
workspace_label :: proc(k: ^Kit_State, slot: int) -> string {
	if !workspace_used(k, slot) do return fmt.tprintf("Workspace %d", slot + 1)
	return k.workspaces.list[slot].name
}

// The workspace tabs, in the top bar's middle: a tap on another switches to it (Ctrl+1 to 9
// by place); a tap on the lit one, or on the chevron after them, opens the workspace menu.
// The chosen tab has the one selected look, with its own colour as a dot at its top left;
// every tab whose layout differs from where it started carries the amber dot. Returns the
// width laid out.
top_workspace_tabs :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	l := &k.layouts
	tabs := workspace_tabs(k)
	names := make([]string, len(tabs), context.temp_allocator)
	glyphs := make([]rune, len(tabs), context.temp_allocator)
	keys := make([]string, len(tabs), context.temp_allocator)
	chosen := -1
	for slot, i in tabs {
		w := &k.workspaces.list[slot]
		names[i] = fmt.tprintf("%s##slot %d", w.name, slot)
		glyphs[i] = STARTER_ICONS[w.starter]
		keys[i] = command_hint(app, .Workspace_Switch, slot)
		if slot == k.workspaces.current do chosen = i
	}
	ui.begin(ctx, "workspace tabs", {direction = .Row, center = true, background = .Track, radius = t.radius_medium + 1.5})
	start := ctx.last_rect.x
	picked := ui.tabs(ctx, "Workspaces", names, chosen, glyphs = glyphs, keys = keys)
	seg := ctx.last_rect
	if picked >= 0 {
		if picked == chosen {
			was := l.menu
			kit_floats_close(k)
			l.menu = !was
		} else {
			command_run(app, .Workspace_Switch, tabs[picked])
		}
	}
	x := start + 3
	for slot, i in tabs {
		w := &k.workspaces.list[slot]
		sw := workspace_tab_width(ctx, w.name)
		if i == chosen {
			l.menu_at = {x, seg.y, sw, seg.h}
			ui.fill_circle(ctx, {x + 7, seg.y + 7}, 2.5, t.tints[int(w.tint) % len(t.tints)])
		}
		if layout_changed(k, slot) do ui.fill_circle(ctx, {x + sw - 9, seg.y + seg.h * 0.5}, 3, t.warning)
		x += sw
	}
	if ui.icon_button(ctx, "Workspace menu", ui.ICON_CHEVRON_DOWN, selected = l.menu, size = t.control) {
		was := l.menu
		kit_floats_close(k)
		l.menu = !was
		l.menu_at = ctx.last_rect
	}
	end := ctx.last_rect
	ui.end(ctx)
	return end.x + end.w - start
}

// One tab's width, as ui.tabs sizes a tab with a glyph.
workspace_tab_width :: proc(ctx: ^ui.Context, name: string) -> f32 {
	t := ctx.theme
	return ui.text_width(ctx, name, t.text_size, .Semibold) + 28 + t.icon_small + 6
}

// The tabs' width: the tabs in their well, then the chevron.
workspace_tabs_width :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	w: f32 = 2 * 3 + ctx.theme.control
	for slot in workspace_tabs(k) do w += workspace_tab_width(ctx, k.workspaces.list[slot].name)
	return w
}

// The settings lines of the workspaces:
//   workspace <slot from 1> <name> <tint> <starter> <ties joined by commas, or ->
//   workspace_layout <slot> <layout>   its layout, where it differs from its base
//   workspace_base <slot> <layout>     a workspace of the person's own: its base
//   workspace_order <slot> ...
//   workspace_current <slot>
// with names and layouts escaped.
workspaces_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	ws := &k.workspaces
	if k.layouts.shipped[.Sculpt] == "" do return
	for w, slot in ws.list {
		if w.name == "" do continue
		ties := strings.builder_make(context.temp_allocator)
		for t in Tie do if t in w.ties do fmt.sbprintf(&ties, "%s%v", "," if strings.builder_len(ties) > 0 else "", t)
		fmt.sbprintfln(out, "workspace %d %s %d %v %s", slot + 1, preset_escape(w.name), w.tint, w.starter, strings.to_string(ties) if strings.builder_len(ties) > 0 else "-")
		text := kit_layout_text(k) if slot == ws.current else w.kept
		if text != "" && text != workspace_base(k, slot) do fmt.sbprintfln(out, "workspace_layout %d %s", slot + 1, preset_escape(text))
		if w.starter == .None do fmt.sbprintfln(out, "workspace_base %d %s", slot + 1, preset_escape(w.base))
	}
	strings.write_string(out, "workspace_order")
	for slot in workspace_tabs(k) do fmt.sbprintf(out, " %d", slot + 1)
	strings.write_byte(out, '\n')
	fmt.sbprintfln(out, "workspace_current %d", ws.current + 1)
}

// What workspaces_load_line has read so far: the first workspace line read drops the
// starters, so a file's list is exactly the workspaces it names.
Workspaces_Read :: struct {
	any:     bool, // a workspace line was taken
	current: int, // the slot named in front, -1 for none
	order:   [dynamic]int,
}

// Reads one of the lines workspaces_save writes (`f` split by spaces). A slot out of range
// or read already, an empty name or one taken, a tint, starter or tie this build does not
// know, a tie another holds: the line is passed over. Layout lines for a slot no workspace
// line took are passed over in workspaces_loaded.
workspaces_load_line :: proc(k: ^Kit_State, r: ^Workspaces_Read, f: []string) {
	ws := &k.workspaces
	if len(f) < 2 || k.layouts.shipped[.Sculpt] == "" do return
	slot_of :: proc(word: string) -> (int, bool) {
		n, ok := strconv.parse_int(word)
		if !ok || n < 1 || n > WORKSPACE_SLOTS do return 0, false
		return n - 1, true
	}
	switch f[0] {
	case "workspace":
		if len(f) != 6 do return
		slot, ok := slot_of(f[1])
		tint, tint_ok := strconv.parse_int(f[3])
		if !ok || !tint_ok || tint < 0 || tint > 255 do return
		starter: Starter
		found := false
		for s in Starter do if strings.equal_fold(f[4], fmt.tprint(s)) do starter, found = s, true
		if !found do return
		ties: bit_set[Tie]
		if f[5] != "-" {
			for word in strings.split(f[5], ",", context.temp_allocator) {
				known := false
				for t in Tie do if strings.equal_fold(word, fmt.tprint(t)) do ties, known = ties + {t}, true
				if !known do return
			}
		}
		if !r.any {
			workspaces_clear(k)
			r.any = true
		}
		name := strings.trim_space(preset_unescape(f[2]))
		if ws.list[slot].name != "" || !workspace_name_free(k, name, -1) do return
		for t in ties do if workspace_holding(k, t) >= 0 do return
		w := &ws.list[slot]
		w.name = strings.clone(name)
		w.tint, w.starter, w.ties = u8(tint), starter, ties
		w.page = shelf_first_page(starter)
	case "workspace_layout", "workspace_base":
		if len(f) != 3 do return
		slot, ok := slot_of(f[1])
		if !ok || !workspace_used(k, slot) do return
		w := &ws.list[slot]
		text := &w.kept if f[0] == "workspace_layout" else &w.base
		delete(text^)
		text^ = strings.clone(preset_unescape(f[2]))
	case "workspace_order":
		clear(&r.order)
		for word in f[1:] do if slot, ok := slot_of(word); ok do append(&r.order, slot)
	case "workspace_current":
		if slot, ok := slot_of(f[1]); ok do r.current = slot
	}
}

// Whether `name` is a workspace name no workspace but `slot` has (letter case aside), and one
// the kit can show: not empty, and without the "##" its ids keep for themselves.
workspace_name_free :: proc(k: ^Kit_State, name: string, slot: int) -> bool {
	if name == "" || strings.contains(name, "##") do return false
	for w, i in k.workspaces.list do if i != slot && w.name != "" && strings.equal_fold(w.name, name) do return false
	return true
}

// After the settings are read: a file that named no workspace keeps the starters; one that
// did has its order and its workspace in front made sound (a slot named twice or free cut,
// a workspace left out put at the end, a free slot in front becoming the first tab), a
// workspace of the person's own with no base takes its layout as its base, and the layout of
// the workspace in front goes in place.
workspaces_loaded :: proc(k: ^Kit_State, r: ^Workspaces_Read) {
	ws := &k.workspaces
	if k.layouts.shipped[.Sculpt] == "" do return
	if r.any {
		seen: [WORKSPACE_SLOTS]bool
		n := 0
		for &o in ws.order do o = -1
		for slot in r.order do if workspace_used(k, slot) && !seen[slot] {
			seen[slot] = true
			ws.order[n] = i8(slot)
			n += 1
		}
		for slot in 0 ..< WORKSPACE_SLOTS do if workspace_used(k, slot) && !seen[slot] {
			ws.order[n] = i8(slot)
			n += 1
		}
		if n == 0 do workspaces_init(k)
		for &w in ws.list do if w.name != "" && w.starter == .None && w.base == "" {
			w.base = strings.clone(w.kept if w.kept != "" else k.layouts.shipped[.Sculpt])
		}
	}
	if workspace_used(k, r.current) do ws.current = r.current
	if !workspace_used(k, ws.current) do ws.current = workspace_tabs(k)[0]
	w := workspace_now(k)
	// Sculpt as it ships is how the interface starts, with any bar the settings named (a
	// scenario's view rail), so it is put in place only when the workspace in front has
	// another layout.
	text := w.kept if w.kept != "" else workspace_base(k, ws.current)
	if text != k.layouts.shipped[.Sculpt] do kit_layout_put(k, text)
	delete(w.kept)
	w.kept = ""
	k.shelf.page = w.page
}
