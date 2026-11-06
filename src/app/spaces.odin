package main

import "core:strings"

import "../sculpt"
import "../ui"

// Working spaces (the overhaul's round 3, after Maxon Forger's two contexts and Blender's
// workspaces): Sculpt, Model and Render. The space is what the hands are doing, so the tool
// decides it: a brush, Curve or Insert is Sculpt, the Model tool is Model, and the look's
// tiles are Render; Move belongs to whichever space it was picked in. A tab in the top bar
// shows the space and a tap on another tab picks that space's last tool, so the two never
// disagree. Selecting an object never switches the space: a mesh selected in Model is
// offered a conversion instead. Each space keeps its own layout (layouts.odin), so the
// docks and cards that suit modelling come back with the Model tool.

Space :: enum u8 {
	Sculpt,
	Model,
	Render,
}

@(rodata)
SPACE_NAMES := [Space]string {
	.Sculpt = "Sculpt",
	.Model  = "Model",
	.Render = "Render",
}

@(rodata)
SPACE_ICONS := [Space]rune {
	.Sculpt = ui.ICON_BRUSH,
	.Model  = ICON_OBJECT_BOX,
	.Render = ICON_PASSES,
}

// The tool a space was left with, which a tap on its tab gives back: the tool, and for
// Sculpt the brush (a preset is left as it is) and for Model the action.
Space_Tool :: struct {
	kept:   bool, // false until the space was left once
	tool:   Tool,
	brush:  sculpt.Brush_Kind,
	preset: int,
	action: Model_Action,
}

Spaces :: struct {
	current:  Space,
	last:     [Space]Space_Tool,
	// The tool as of the last frame, to see it change, and whether a command picked a
	// tool this frame even when it was the one in hand (a brush tile tapped in Render).
	seen:     Space_Tool,
	picked:   bool,
	page:     [Space]Shelf_Page, // the shelf's page each space was left on
	set:      bool, // `seen` holds this run's tool (the first frame records it)
	switches: int, // for the exit stats
}

// The view toggles Focus and Inspect: they change what shows, never the layout, so the
// tab's dot stays as it was.
FOCUS_ZONES :: bit_set[Zone]{.Brush_Bar, .View_Bar, .Action_Bar}
INSPECT_ZONES :: bit_set[Zone]{.Brush_Bar, .Dock}
// Inspect's panes, as round 2's Inspect view had them (its inspect2 screen): the
// main view shaded, then curvature, normals and a front silhouette.
INSPECT_PANES :: "panes h500 v500 0 1 v500 2 3\npane 1 Follow Curvature\npane 2 Follow Normals\npane 3 Front Silhouette\n"

Inspect_View :: struct {
	on:     bool,
	before: string, // the grid's layout lines as Inspect found them (heap), put back after
}

// The spaces as a fresh install has them: Sculpt, each space on its first shelf page.
spaces_init :: proc(k: ^Kit_State) {
	k.spaces = {}
	for s in Space do k.spaces.page[s] = shelf_first_page(s)
}

// The tool in hand as a space keeps it.
space_tool_now :: proc(app: ^App) -> Space_Tool {
	return {kept = true, tool = app.tool, brush = app.brush.kind, preset = app.brush.preset, action = app.model.action}
}

// The space the tool in hand belongs to; `ok` false for one that keeps the space it is
// in (Move).
space_of_tool :: proc(tool: Tool) -> (s: Space, ok: bool) {
	switch tool {
	case .Brush, .Curve, .Insert: return .Sculpt, true
	case .Model:                  return .Model, true
	case .Move:
	}
	return
}


// Notes that a command picked a tool, so the space follows even when it was the tool in
// hand already.
space_picked :: proc(app: ^App) {
	app.kit.spaces.picked = true
}

// Gives space `s` its last tool back: Sculpt the brush (or Curve, Insert, Move) it was
// left with, the Brush tool the first time; Model the Model tool and its action. Render
// keeps the tool in hand, since a press there turns the view.
@(private = "file")
space_tool_put :: proc(app: ^App, s: Space) {
	last := app.kit.spaces.last[s]
	switch s {
	case .Sculpt:
		if !last.kept {
			if app.tool == .Model do app.tool = .Brush
			return
		}
		app.tool = last.tool if last.tool != .Model else .Brush
		if app.tool == .Brush && last.preset == 0 && app.brush.preset == 0 do app.brush.kind = last.brush
	case .Model:
		app.tool = .Model
		if last.kept do app.model.action = last.action
	case .Render:
	}
}

// Switches to space `to`: the space left keeps its tool and its layout, `to` gets its
// tool back (unless `restore` is false: the tool in hand chose the space) and its layout,
// and the view toggles end.
space_switch :: proc(app: ^App, to: Space, restore := true) {
	k := &app.kit
	s := &k.spaces
	if to == s.current do return
	s.last[s.current] = space_tool_now(app)
	if restore do space_tool_put(app, to)
	s.page[s.current] = k.shelf.page
	k.shelf.page, k.shelf.quick = s.page[to], false
	view_toggles_off(k)
	layout_switch(k, s.current, to)
	s.current = to
	// The dial is the space's too.
	dial_latches_keep(app)
	s.seen, s.picked = space_tool_now(app), false
	s.switches += 1
}

// Once a frame, before the layout: when the tool changed (or a command picked one), the
// space follows it.
space_follow :: proc(app: ^App) {
	s := &app.kit.spaces
	now := space_tool_now(app)
	if !s.set {
		s.seen, s.set, s.picked = now, true, false
		return
	}
	if now == s.seen && !s.picked do return
	s.seen, s.picked = now, false
	if to, ok := space_of_tool(app.tool); ok && to != s.current do space_switch(app, to, restore = false)
}

// Turns Focus and Inspect off, as a space switch or a layout put in place does.
view_toggles_off :: proc(k: ^Kit_State) {
	k.focus_mode = false
	inspect_set(k, false)
}

// Turns Inspect on or off: on, the panes show the form four ways and the brush bar and
// dock stand aside; off, the grid goes back to what it was.
inspect_set :: proc(k: ^Kit_State, on: bool) {
	iv := &k.inspect
	if on == iv.on do return
	if on {
		delete(iv.before)
		iv.before = strings.clone(grid_layout_lines(k))
		grid_lines_put(k, INSPECT_PANES)
	} else {
		grid_lines_put(k, iv.before)
		delete(iv.before)
		iv.before = ""
	}
	iv.on = on
}

// Puts the grid that `text`'s panes, grid and pane lines describe in place (one view for
// none), as a layout does.
@(private = "file")
grid_lines_put :: proc(k: ^Kit_State, text: string) {
	k.grid.tree, k.grid.maximised = grid_preset_tree(.Single), 0
	k.grid.serial += 1
	grid_undo_clear(&k.grid)
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) > 0 do grid_layout_read(k, f)
	}
}

spaces_destroy :: proc(k: ^Kit_State) {
	delete(k.inspect.before)
	k.inspect = {}
}

// The space tabs, in the top bar's middle: a tap on another space switches to it (Ctrl+1
// to 3 do too); a tap on the lit one, or on the chevron after them, opens the layout menu.
// The chosen tab has the one selected look, with the space's own colour as a dot at its
// top left; every tab whose layout differs from how it ships carries the amber dot.
// Returns the width laid out.
top_space_tabs :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	w := &k.layouts
	names: [len(Space)]string
	glyphs: [len(Space)]rune
	keys: [len(Space)]string
	for s in Space {
		names[s] = SPACE_NAMES[s]
		glyphs[s] = SPACE_ICONS[s]
		keys[s] = command_hint(app, .Space_Switch, int(s))
	}
	ui.begin(ctx, "space tabs", {direction = .Row, center = true, background = .Track, radius = t.radius_medium + 1.5})
	start := ctx.last_rect.x
	chosen := int(k.spaces.current)
	picked := ui.tabs(ctx, "Spaces", names[:], chosen, glyphs = glyphs[:], keys = keys[:])
	seg := ctx.last_rect
	if picked >= 0 {
		if picked == chosen {
			was := w.menu
			kit_floats_close(k)
			w.menu = !was
		} else {
			command_run(app, .Space_Switch, picked)
		}
	}
	x := start + 3
	for name, i in names {
		sw := space_tab_width(ctx, name)
		if i == chosen {
			w.menu_at = {x, seg.y, sw, seg.h}
			ui.fill_circle(ctx, {x + 7, seg.y + 7}, 2.5, t.tints[i])
		}
		if layout_changed(k, Space(i)) do ui.fill_circle(ctx, {x + sw - 9, seg.y + seg.h * 0.5}, 3, t.warning)
		x += sw
	}
	if ui.icon_button(ctx, "Layouts", ui.ICON_CHEVRON_DOWN, selected = w.menu, size = t.control) {
		was := w.menu
		kit_floats_close(k)
		w.menu = !was
		w.menu_at = ctx.last_rect
	}
	end := ctx.last_rect
	ui.end(ctx)
	return end.x + end.w - start
}

// One tab's width, as ui.tabs sizes a tab with a glyph.
space_tab_width :: proc(ctx: ^ui.Context, name: string) -> f32 {
	t := ctx.theme
	return ui.text_width(ctx, name, t.text_size, .Semibold) + 28 + t.icon_small + 6
}

// The tabs' width: the tabs in their well, then the chevron.
space_tabs_width :: proc(app: ^App) -> f32 {
	ctx := &app.kit.ctx
	w: f32 = 2 * 3 + ctx.theme.control
	for s in Space do w += space_tab_width(ctx, SPACE_NAMES[s])
	return w
}
