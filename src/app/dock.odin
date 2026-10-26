package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The brush dock at the bottom middle: seven slots, each holding a brush or a preset made
// from one, which a long press (or a right-click) on the slot changes; the rest are a tap
// away in the brush browser beside it. The dock is the interface's, so it lives in
// Kit_State and settings.txt remembers it.

DOCK_SLOTS :: 7

Dock_Slot :: struct {
	kind:   sculpt.Brush_Kind, // the brush, or the preset's own brush
	preset: int, // the preset, counted from 1; 0 for the plain brush
}

// The dock a fresh install has: the brushes most reached for.
DOCK_DEFAULT :: [DOCK_SLOTS]Dock_Slot{{kind = .Draw}, {kind = .Smooth}, {kind = .Clay}, {kind = .Flatten}, {kind = .Inflate}, {kind = .Grab}, {kind = .Mask}}

// Whether two slots hold the same thing: the same preset, or the same plain brush.
dock_slot_same :: proc(a, b: Dock_Slot) -> bool {
	return a.preset == b.preset && (a.preset != 0 || a.kind == b.kind)
}

// What the brush is, as a slot; false while another tool is picked.
brush_as_slot :: proc(app: ^App) -> (Dock_Slot, bool) {
	return {kind = app.brush.kind, preset = app.brush.preset}, app.tool == .Brush
}

// Whether the brush is what `s` holds.
dock_slot_on :: proc(app: ^App, s: Dock_Slot) -> bool {
	now, ok := brush_as_slot(app)
	return ok && dock_slot_same(now, s)
}

// What a slot's tile shows: the preset's name or the brush's, over the brush's icon.
dock_slot_label :: proc(app: ^App, s: Dock_Slot) -> string {
	if s.preset > 0 && s.preset <= app.preset_count do return preset_name(&app.presets[s.preset - 1])
	return BRUSHES[s.kind].name
}

// Picks what `s` holds.
dock_slot_pick :: proc(app: ^App, s: Dock_Slot) {
	if s.preset > 0 do preset_pick(app, s.preset - 1)
	else do command_run(app, .Brush, int(s.kind))
}

// Picks what `s` holds and shows its settings.
dock_slot_settings :: proc(app: ^App, s: Dock_Slot) {
	if s.preset > 0 do preset_settings_open(app, s.preset - 1)
	else do brush_settings_open(app, s.kind)
}

// Puts brush `kind`, or preset `preset` (from 1) when above 0, in slot `slot`.
dock_put :: proc(app: ^App, slot: int, kind: sculpt.Brush_Kind, preset := 0) {
	if slot < 0 || slot >= DOCK_SLOTS do return
	s := Dock_Slot{kind = kind}
	if preset > 0 && preset <= app.preset_count do s = {kind = app.presets[preset - 1].values.kind, preset = preset}
	app.kit.dock[slot] = s
}

// Whether the brush is in a slot of the dock.
dock_has_brush :: proc(app: ^App) -> bool {
	for s in app.kit.dock do if dock_slot_on(app, s) do return true
	return false
}

// Keeps the dock's slots on their presets once preset `i` (from 0) is deleted: its own
// slots fall back to its brush, and later presets' move down one.
dock_preset_deleted :: proc(app: ^App, i: int) {
	for &s in app.kit.dock {
		if s.preset == i + 1 do s.preset = 0
		else if s.preset > i + 1 do s.preset -= 1
	}
}

// Whether the dock differs from a fresh install's.
dock_changed :: proc(app: ^App) -> bool {
	fresh := DOCK_DEFAULT
	for s, i in app.kit.dock do if !dock_slot_same(s, fresh[i]) do return true
	return false
}

// The dock for the exit stats: each slot's name, spaces as underscores, comma separated.
dock_names :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in app.kit.dock {
		if i > 0 do strings.write_byte(&b, ',')
		name, _ := strings.replace_all(dock_slot_label(app, s), " ", "_", context.temp_allocator)
		strings.write_string(&b, name)
	}
	return strings.to_string(b)
}

// Opens the slot popover on slot `slot`, over its tile `at`.
dock_menu_open :: proc(app: ^App, slot: int, at: ui.Rect) {
	k := &app.kit
	k.browser = false
	k.dock_menu, k.dock_slot, k.dock_at, k.grid_scroll, k.grid_reveal = true, slot, at, 0, true
}

// Picks preset `i` (from 0) and shows its settings: the inspector, on the tool's tab, from
// the top, with the Preset section open to rename it or save its changes.
preset_settings_open :: proc(app: ^App, i: int) {
	k := &app.kit
	preset_pick(app, i)
	side_panel_close(app)
	k.inspector, k.tab, k.scroll = true, .Tool, 0
	k.open[.Preset] = true
}

// What a tap or a long press on the brush grid chose.
Grid_Pick :: struct {
	slot:            Dock_Slot,
	tapped, pressed: bool, // tapped picks; pressed is the long press (or right-click)
}

// Every brush, then every preset, as tiles PER_ROW to a row in a body that scrolls when
// taller than `height`: the brush browser's and the slot popover's. `chosen` is lit when
// `lit` is set.
// `owner` is the popover the body is in.
kit_brush_grid :: proc(app: ^App, owner: ui.Id, chosen: Dock_Slot, lit: bool, height: f32) -> (pick: Grid_Pick) {
	PER_ROW :: 5
	k := &app.kit
	ctx := &k.ctx
	width := ui.BRUSH_TILE.x * PER_ROW
	scroll := kit_scroll_begin(ctx, "brush grid", &k.grid_scroll, owner, width, height, 2)
	tiles := len(sculpt.Brush_Kind) + app.preset_count
	for i in 0 ..< tiles {
		if i == len(sculpt.Brush_Kind) do ui.caption(ctx, "PRESETS")
		first := i if i < len(sculpt.Brush_Kind) else i - len(sculpt.Brush_Kind)
		if first % PER_ROW == 0 {
			ui.begin(ctx, fmt.tprintf("%s %d", "brush row" if i < len(sculpt.Brush_Kind) else "preset row", first / PER_ROW), {direction = .Row, gap = 0})
		}
		s: Dock_Slot
		label, hint: string
		if i < len(sculpt.Brush_Kind) {
			s.kind = sculpt.Brush_Kind(i)
			label, hint = BRUSHES[s.kind].name, command_hint(app, .Brush, i)
		} else {
			p := &app.presets[first]
			s = {kind = p.values.kind, preset = first + 1}
			label = fmt.tprintf("%s##preset %d", preset_name(p), first)
		}
		on := lit && dock_slot_same(s, chosen)
		if ui.brush_tile(ctx, label, BRUSHES[s.kind].icon, on, hint) do pick = {slot = s, tapped = true}
		// Opening, the grid scrolls to the lit tile, once the body's height is known.
		if on && k.grid_reveal && scroll.natural > 0 {
			at := ctx.last_rect.y - scroll.at.y + scroll.shown
			k.grid_scroll = clamp(at - (height - ui.BRUSH_TILE.y) * 0.5, 0, scroll.limit)
		}
		if ui.secondary(ctx) do pick = {slot = s, pressed = true}
		last := len(sculpt.Brush_Kind) - 1 if i < len(sculpt.Brush_Kind) else tiles - 1
		if first % PER_ROW == PER_ROW - 1 || i == last do ui.end(ctx)
	}
	if app.preset_count == 0 {
		ui.caption(ctx, "PRESETS")
		ui.paragraph(ctx, "Save a brush as a preset (Brush tab, Preset) to find it here.", width)
	}
	kit_scroll_end(ctx, scroll)
	if scroll.natural > 0 do k.grid_reveal = false
	return
}

// The room the grid has in a popover opening above `anchor` (`popover_h` tall last
// frame): up to the window's top, less what the popover holds besides the grid. Called
// inside the popover.
grid_room :: proc(ctx: ^ui.Context, popover_h: f32, anchor: ui.Rect) -> f32 {
	body, _ := ui.prev_layout(ctx, "brush grid")
	besides := popover_h - body.y if popover_h > 0 else 120
	return max(anchor.y - 16 - besides, ui.BRUSH_TILE.y * 2)
}

// The room the grid has in a popover beside the brush bar (`popover_h` tall last frame):
// the safe area's height, less what the popover holds besides the grid and a margin.
grid_room_beside :: proc(ctx: ^ui.Context, popover_h: f32) -> f32 {
	body, _ := ui.prev_layout(ctx, "brush grid")
	besides := popover_h - body.y if popover_h > 0 else 120
	return max(ui.safe_area(ctx).h - kit_top() - 16 - besides, ui.BRUSH_TILE.y * 2)
}

// Which button opened the brush browser: All brushes on the dock, or Brushes on the bar.
Browser_At :: enum u8 {
	Dock,
	Bar,
}

// A tool's tile on the dock: a tap picks the tool, a long press (or a right-click) picks
// it and shows its settings in the inspector's first tab.
dock_tool :: proc(app: ^App, tool: Tool) {
	ctx := &app.kit.ctx
	id := TOOL_COMMANDS[tool]
	if ui.brush_tile(ctx, fmt.tprintf("%s##tool", kit_tool_name(tool)), TOOL_ICONS[tool], app.tool == tool, command_hint(app, id)) do command_run(app, id)
	if ui.secondary(ctx) {
		command_run(app, id)
		side_panel_close(app)
		app.kit.inspector, app.kit.tab, app.kit.scroll = true, .Tool, 0
	}
}

@(rodata)
TOOL_COMMANDS := [Tool]Command_Id {
	.Move   = .Tool_Move,
	.Brush  = .Tool_Sculpt,
	.Curve  = .Tool_Curve,
	.Insert = .Tool_Insert,
}

@(rodata)
TOOL_ICONS := [Tool]rune {
	.Move   = ui.ICON_MOVE,
	.Brush  = ui.ICON_BRUSH,
	.Curve  = ui.ICON_SPLINE,
	.Insert = ui.ICON_SHAPES,
}

// The brush browser, over its button on the dock: every brush and preset. A tap picks one;
// a long press (or a right-click) shows its settings.
kit_brush_browser :: proc(app: ^App, anchor: ui.Rect, side: ui.Side) {
	k := &app.kit
	ctx := &k.ctx
	size, _ := ui.prev_layout(ctx, "brush browser")
	owner := ui.id_of(ctx, "brush browser")
	if !ui.popover_begin(ctx, "brush browser", &k.browser, anchor, side, {direction = .Column, gap = 2, padding = 10}) do return
	defer ui.popover_end(ctx)
	kit_grid_head(app, "BRUSHES", &k.browser)
	chosen, lit := brush_as_slot(app)
	room := grid_room(ctx, size.y, anchor) if side == .Above_Center else grid_room_beside(ctx, size.y)
	pick := kit_brush_grid(app, owner, chosen, lit, room)
	if pick.tapped do dock_slot_pick(app, pick.slot)
	if pick.pressed do dock_slot_settings(app, pick.slot)
	if pick.tapped || pick.pressed do k.browser = false
}

// The slot popover, over the dock tile a long press (or a right-click) was on: that
// brush's or preset's settings, what to put in the slot instead, and Reset dock.
kit_dock_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	slot := clamp(k.dock_slot, 0, DOCK_SLOTS - 1)
	s := k.dock[slot]
	size, _ := ui.prev_layout(ctx, "dock slot")
	owner := ui.id_of(ctx, "dock slot")
	if !ui.popover_begin(ctx, "dock slot", &k.dock_menu, k.dock_at, .Above_Center, {direction = .Column, gap = 2, padding = 10}) do return
	defer ui.popover_end(ctx)
	kit_grid_head(app, "PUT IN THIS SLOT", &k.dock_menu)
	if ui.menu_item(ctx, fmt.tprintf("%s settings", "Preset" if s.preset > 0 else "Brush"), glyph = ui.ICON_SETTINGS) {
		dock_slot_settings(app, s)
		k.dock_menu = false
	}
	pick := kit_brush_grid(app, owner, s, true, grid_room(ctx, size.y, k.dock_at))
	if pick.tapped {
		dock_put(app, slot, pick.slot.kind, pick.slot.preset)
		k.dock_menu = false
	}
	if pick.pressed {
		dock_slot_settings(app, pick.slot)
		k.dock_menu = false
	}
	if ui.menu_item(ctx, "Reset dock", glyph = ui.ICON_UNDO, enabled = dock_changed(app)) {
		k.dock = DOCK_DEFAULT
		k.dock_menu = false
	}
}

// A grid popover's caption with Close at its end.
@(private = "file")
kit_grid_head :: proc(app: ^App, caption: string, open: ^bool) {
	ctx := &app.kit.ctx
	ui.begin(ctx, "grid head", {direction = .Row, center = true})
	ui.begin(ctx, "grid title", {direction = .Column, width = ui.BRUSH_TILE.x * 5 - ctx.theme.target})
	ui.caption(ctx, caption)
	ui.end(ctx)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do open^ = false
	ui.end(ctx)
}
