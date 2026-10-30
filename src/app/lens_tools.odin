package main

import "core:fmt"

import "../sculpt"
import "../ui"

// Lens's Tools card (round 2 of the mockups, screens tools2 and geo2): what is done to the
// selected object's surface rather than with a brush, in four tabs. Mask and Visibility
// are grids of big labelled buttons with their keys under them, as Nomad's and ZBrush for
// iPad's tool palettes have; Geometry holds Remesh, the subdivision levels and Modify
// topology; Deform is the Deformation section. Every button is a command of the registry,
// so its key, gesture and whether it can run now come from there. The full sections (Mask
// by, Steps' help, Grow all and the rest) are cards of their own, which Show section opens.

Tools_Tab :: enum u8 {
	Mask,
	Visibility,
	Geometry,
	Deform,
}

@(rodata)
TOOLS_TAB_NAMES := [Tools_Tab]string {
	.Mask       = "Mask",
	.Visibility = "Visibility",
	.Geometry   = "Geometry",
	.Deform     = "Deform",
}

// A button of a tool grid: its command and argument, its label and its icon.
Tool_Tile :: struct {
	id:    Command_Id,
	arg:   int,
	label: string,
	glyph: rune,
}

// Lucide's icons for the grids that the kit does not name already.
ICON_CONTRAST :: rune(0xe0a1) // half filled: inverting
ICON_SPARKLES :: rune(0xe417)
ICON_MINUS :: rune(0xe120)
ICON_SCAN_EYE :: rune(0xe53b) // facing the eye: masking by angle
ICON_CIRCLE_DASHED :: rune(0xe4b5) // a hole's open border
ICON_SQUARE_DASHED :: rune(0xe1cb) // the Tools card: a selection's dashed outline

@(rodata)
MASK_TILES := [?]Tool_Tile {
	{.Mask, int(sculpt.Mask_Command.Invert), "Invert", ICON_CONTRAST},
	{.Mask, int(sculpt.Mask_Command.Clear), "Clear", ui.ICON_CLOSE},
	{.Mask, int(sculpt.Mask_Command.Blur), "Blur", ICON_CHANNEL_COLOR},
	{.Mask, int(sculpt.Mask_Command.Sharpen), "Sharpen", ICON_SPARKLES},
	{.Mask, int(sculpt.Mask_Command.Grow), "Grow", ui.ICON_PLUS},
	{.Mask, int(sculpt.Mask_Command.Shrink), "Shrink", ICON_MINUS},
	{.Mask, int(sculpt.Mask_Command.Cavity), "By cavity", ICON_CHANNEL_SCULPT},
	{.Mask_By, int(sculpt.Mask_By.Facing_Away), "By angle", ICON_SCAN_EYE},
	{.Extract_Masked, 0, "Extract", ICON_OBJECT_BOX},
}

@(rodata)
VISIBILITY_TILES := [?]Tool_Tile {
	{.Show_All, 0, "Show all", ui.ICON_EYE},
	{.Invert_Hidden, 0, "Invert visible", ICON_CONTRAST},
	{.Hide_Masked, 0, "Hide masked", ui.ICON_EYE_OFF},
	{.Delete_Hidden, 0, "Delete hidden", ui.ICON_TRASH},
	{.Grow_Visible, 0, "Grow", ui.ICON_PLUS},
	{.Shrink_Visible, 0, "Shrink", ICON_MINUS},
}

@(rodata)
REPAIR_TILES := [?]Tool_Tile {
	{.Close_Holes, 0, "Close holes", ICON_CIRCLE_DASHED},
	{.Delete_Hidden, 0, "Delete hidden", ui.ICON_EYE_OFF},
	{.Weld_Points, 0, "Weld points", ICON_LINK},
	{.Check_Mesh, 0, "Check mesh", ui.ICON_CHECK},
	{.Fix_Mesh, 0, "Fix mesh", ui.ICON_WAND},
	{.Delete_Half, 0, "Delete half", ICON_SYMMETRY},
}

// A grid button's height, in points: room for the icon, the label and a key under it.
TOOL_TILE_H :: 56
TOOL_TILE_GAP :: 6

// The card's content, as the stack draws it.
kit_lens_tools :: proc(app: ^App, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	names: [len(Tools_Tab)]string
	for tab, i in Tools_Tab do names[i] = TOOLS_TAB_NAMES[tab]
	if picked := ui.tabs(ctx, "tools tab", names[:], int(k.tools_tab)); picked >= 0 do k.tools_tab = Tools_Tab(picked)
	obj := selected_object(app)
	if obj == nil {
		ui.paragraph(ctx, "Add or select an object first.")
		return
	}
	switch k.tools_tab {
	case .Mask:       lens_tools_mask(app, inner)
	case .Visibility: lens_tools_visibility(app, inner)
	case .Geometry:   lens_tools_geometry(app, obj, inner)
	case .Deform:
		if _, _, draw, ok := bar_section(app, .Deform); ok do draw(app, obj)
	}
}

// The mask's commands, then Steps (how far Blur, Grow and their kin reach, the Mask
// section's) and whether the view shows the mask at all.
@(private = "file")
lens_tools_mask :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	tool_grid(app, "mask", MASK_TILES[:], inner)
	steps := f32(app.ui.mask_steps)
	if ui.slider(ctx, "Steps##tools", &steps, 1, 50, .Linear, fmt.tprintf("%d", app.ui.mask_steps)) do app.ui.mask_steps = i32(steps + 0.5)
	shown := !app.ui.mask_hidden
	if ui.switch_row(ctx, "Show the mask", &shown) do app.ui.mask_hidden = !shown
}

// Hiding parts, then which objects show: the stored visibilities V1 to V8.
@(private = "file")
lens_tools_visibility :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	tool_grid(app, "visibility", VISIBILITY_TILES[:], inner)
	ui.caption(ctx, "OBJECTS SHOWN")
	ui.begin(ctx, "tools slots", {direction = .Row, gap = 4})
	side := (inner - 7 * 4) / VIS_SLOTS
	for slot in 0 ..< VIS_SLOTS {
		if ui.toggle_button(ctx, fmt.tprintf("V%d##tools", slot + 1), command_checked(app, .Visibility_Slot, slot), side, command_hint(app, .Visibility_Slot, slot), COMMANDS[.Visibility_Slot].help) {
			_ = command_run(app, .Visibility_Slot, slot)
		}
	}
	ui.end(ctx)
}

// Remesh at a density (with Half, Same and Double of the object's own count), the levels
// as numbered chips with Divide, Dynamic topology, and the mesh repairs.
@(private = "file")
lens_tools_geometry :: proc(app: ^App, obj: ^Object, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.caption(ctx, "REMESH")
	even := &app.ui.rebuild_even
	now := object_vertex_count(obj)
	steps := [3]i32{rebuild_count(now / 2), rebuild_count(now), rebuild_count(now * 2)}
	step_names := [3]string{"Half", "Same", "Double"}
	chosen := -1
	for v, i in steps do if even^ == v do chosen = i
	if picked := ui.tabs(ctx, "tools remesh steps", step_names[:], chosen); picked >= 0 do even^ = steps[picked]
	label := "Density##tools"
	_ = kit_count(ctx, label, even, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
	id := ui.id_of(ctx, label)
	if ctx.active == id || (ctx.hot == id && app.device.pointer == .Mouse) do rebuild_preview_hold(app)
	if ui.button(ctx, "Remesh##tools", .Bordered, .Accent, inner, ICON_REMESH, enabled = command_enabled(app, .Remesh), keys = command_hint(app, .Rebuild)) {
		app.ui.scene_command = {kind = .Remesh, vertices = int(even^), remesh = remesh_setup(app)}
	}
	ui.caption(ctx, "SUBDIVISION")
	levels := &obj.levels
	count := len(levels.levels)
	ui.begin(ctx, "tools levels", {direction = .Row, gap = 4, center = true})
	divide := ui.text_width(ctx, "Divide", t.text_size, .Semibold) + 28 + t.icon_small
	chip := min(t.target, (inner - divide - 4 * f32(count)) / f32(max(count, 1)))
	for i in 0 ..< count {
		if ui.toggle_button(ctx, fmt.tprintf("%d##tools level", i + 1), i == levels.current, chip, tooltip = fmt.tprintf("Level %d of %d", i + 1, count)) && i != levels.current {
			app.ui.scene_command = {kind = .Set_Level, level = i}
		}
	}
	ui.spacer(ctx, max(inner - divide - f32(count) * (chip + 4), 0))
	_ = command_button(app, .Subdivide, label = "Divide", variant = .Bordered, glyph = ui.ICON_PLUS, width = divide)
	ui.end(ctx)
	dyn_on := command_checked(app, .Dyntopo_Toggle)
	if ui.switch_row(ctx, "Dynamic topology##tools", &dyn_on, enabled = command_enabled(app, .Dyntopo_Toggle), keys = command_hint(app, .Dyntopo_Toggle)) {
		_ = command_run(app, .Dyntopo_Toggle)
	}
	ui.caption(ctx, "MODIFY TOPOLOGY")
	tool_grid(app, "repair", REPAIR_TILES[:], inner)
	kit_last_result(app, .Mirror)
}

// `tiles` three across, `width` wide.
@(private = "file")
tool_grid :: proc(app: ^App, name: string, tiles: []Tool_Tile, width: f32) {
	ctx := &app.kit.ctx
	w := (width - 2 * TOOL_TILE_GAP) / 3
	for first := 0; first < len(tiles); first += 3 {
		ui.begin(ctx, fmt.tprintf("tools %s %d", name, first), {direction = .Row, gap = TOOL_TILE_GAP})
		for tile in tiles[first:min(first + 3, len(tiles))] do tool_tile(app, tile, w)
		ui.end(ctx)
	}
}

// One grid button: the icon, the label and the key under it; dimmed while its command
// cannot run, as command_button is.
@(private = "file")
tool_tile :: proc(app: ^App, tile: Tool_Tile, w: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	can := command_enabled(app, tile.id, tile.arg)
	a := ui.area(ctx, fmt.tprintf("%s##tool tile %v %d", tile.label, tile.id, tile.arg), {w, TOOL_TILE_H})
	r := a.rect
	fill := t.fill_pressed if a.held && can else (t.fill_hover if a.hovered && can else t.fill)
	ui.fill_rect(ctx, r, t.radius_medium, fill)
	ui.stroke_rect(ctx, r, t.radius_medium, t.border, 1)
	keys := command_keys(app, tile.id, tile.arg)
	fg := t.text if can else t.text_tertiary
	cx := r.x + r.w * 0.5
	top := r.y + (14 if keys != "" else 18)
	ui.icon(ctx, tile.glyph, {cx, top}, t.icon_small, fg)
	ui.text(ctx, ui.text_fit(ctx, tile.label, t.small_size, r.w - 8), cx, top + 18, t.small_size, fg, .Regular, .Center)
	if keys != "" do ui.text(ctx, ui.text_fit(ctx, keys, t.caption_size, r.w - 8), cx, top + 32, t.caption_size, t.text_tertiary, .Regular, .Center)
	ui.tip(ctx, a.id, r, COMMANDS[tile.id].help, command_hint(app, tile.id, tile.arg))
	if a.clicked && can do _ = command_run(app, tile.id, tile.arg)
}
