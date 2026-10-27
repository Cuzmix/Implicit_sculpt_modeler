package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The brush dock at the bottom bar's left: three pages of seven slots, each holding a brush
// or a preset made from one, which a long press (or a right-click) on the slot changes; the
// rest are a tap away in the brush browser beside it. The dock is the interface's, so it
// lives in Kit_State and settings.txt remembers it.

DOCK_PAGE :: 7
DOCK_PAGES :: 3
DOCK_SLOTS :: DOCK_PAGE * DOCK_PAGES

Dock_Slot :: struct {
	kind:   sculpt.Brush_Kind, // the brush, or the preset's own brush
	preset: int, // the preset, numbered as PACK_PRESET says; 0 for the plain brush
}

// The dock a fresh install has: the brushes most reached for, then the finer and
// surface-moving ones, then painting and masking.
DOCK_DEFAULT :: [DOCK_SLOTS]Dock_Slot {
	{kind = .Draw}, {kind = .Smooth}, {kind = .Clay}, {kind = .Flatten}, {kind = .Inflate}, {kind = .Grab}, {kind = .Mask},
	{kind = .Pinch}, {kind = .Crease}, {kind = .Layer}, {kind = .Snake_Hook}, {kind = .Cloth}, {kind = .Morph}, {kind = .History},
	{kind = .Paint}, {kind = .Mask}, {kind = .Smooth}, {kind = .Draw}, {kind = .Clay}, {kind = .Inflate}, {kind = .Flatten},
}

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
	if p, ok := preset_at(app, s.preset); ok do return preset_name(p)
	return BRUSHES[s.kind].name
}

// Picks what `s` holds.
dock_slot_pick :: proc(app: ^App, s: Dock_Slot) {
	if s.preset > 0 do preset_use(app, s.preset)
	else do command_run(app, .Brush, int(s.kind))
}

// Picks what `s` holds and shows its settings.
dock_slot_settings :: proc(app: ^App, s: Dock_Slot) {
	if s.preset > 0 do preset_settings_open(app, s.preset)
	else do brush_settings_open(app, s.kind)
}

// Puts brush `kind`, or the preset numbered `preset` (PACK_PRESET) when there is one, in
// slot `slot`.
dock_put :: proc(app: ^App, slot: int, kind: sculpt.Brush_Kind, preset := 0) {
	if slot < 0 || slot >= DOCK_SLOTS do return
	s := Dock_Slot{kind = kind}
	if p, ok := preset_at(app, preset); ok do s = {kind = p.values.kind, preset = preset}
	app.kit.dock[slot] = s
}

// How many slots a page of the dock shows: all seven where the window has the room, fewer
// (down to three, on more pages) where the bottom bar would otherwise reach the modifier
// wheel. Measured on last frame's bar, less the slots it showed.
dock_per_page :: proc(app: ^App) -> int {
	k := &app.kit
	ctx := &k.ctx
	bar, _ := ui.prev_layout(ctx, "dock")
	if bar.x <= 0 || k.dock_shown[1] == 0 do return DOCK_PAGE
	rest := bar.x - f32(k.dock_shown[1]) * ui.BRUSH_TILE.x
	room := ui.safe_area(ctx).w - 2 * (max(rail_reach_across(app), ctx.theme.edge) + 8)
	return clamp(int((room - rest) / ui.BRUSH_TILE.x), 3, DOCK_PAGE)
}

// How many pages the dock has at this window's width.
dock_pages :: proc(app: ^App) -> int {
	n := dock_per_page(app)
	return (DOCK_SLOTS + n - 1) / n
}

// Which slots the bottom bar shows: the dock's page as its first slot and how many. A
// brush picked some other way (a key, the browser, a pie) brings the page that holds it,
// unless the page shown holds it too.
dock_page_slots :: proc(app: ^App) -> (first, count: int) {
	k := &app.kit
	n := dock_per_page(app)
	pages := (DOCK_SLOTS + n - 1) / n
	if now, ok := brush_as_slot(app); ok {
		if !dock_slot_same(now, k.dock_seen) && !dock_page_holds(app, k.dock_page, n, now) {
			for s, i in k.dock do if dock_slot_same(s, now) {
				k.dock_page = i / n
				break
			}
		}
		k.dock_seen = now
	}
	k.dock_page = clamp(k.dock_page, 0, pages - 1)
	first = k.dock_page * n
	count = min(n, DOCK_SLOTS - first)
	k.dock_shown = {first, count}
	return
}

// Whether page `page`, `n` slots to a page, holds what `s` holds.
@(private = "file")
dock_page_holds :: proc(app: ^App, page, n: int, s: Dock_Slot) -> bool {
	first := clamp(page * n, 0, DOCK_SLOTS)
	for slot in app.kit.dock[first:min(first + n, DOCK_SLOTS)] do if dock_slot_same(slot, s) do return true
	return false
}

// Whether the brush is in a slot of the dock.
dock_has_brush :: proc(app: ^App) -> bool {
	for s in app.kit.dock do if dock_slot_on(app, s) do return true
	return false
}

// Keeps the dock's slots on their presets once the person's preset `i` (from 0) is
// deleted: its own slots fall back to its brush, and later presets' move down one. A
// pack's presets are numbered apart and stay.
dock_preset_deleted :: proc(app: ^App, i: int) {
	for &s in app.kit.dock {
		if preset_read_only(s.preset) do continue
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

// Slots `first` on, `count` of them, for the exit stats: each slot's name, spaces as
// underscores, comma separated.
dock_names :: proc(app: ^App, first, count: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in app.kit.dock[first:][:count] {
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

// Picks the preset numbered `n` (PACK_PRESET) and shows its settings: the tray, on the
// brush's Preset section, to rename it or save its changes.
preset_settings_open :: proc(app: ^App, n: int) {
	preset_use(app, n)
	tray_open(app, .Preset)
}

// What a tap or a long press on the brush grid chose.
Grid_Pick :: struct {
	slot:            Dock_Slot,
	tapped, pressed: bool, // tapped picks; pressed is the long press (or right-click)
}

// Every brush, then the built-in presets, the person's, then each content pack's under its name, as
// tiles GRID_PER_ROW to a row in a body that scrolls when taller than `height`: the
// brush browser's and the slot popover's. `chosen` is lit when `lit` is set.
// `owner` is the popover the body is in. The browser's (`browser`) also lists the mask,
// hide and cut tools after the library; those are not brushes, so no slot holds them.
kit_brush_grid :: proc(app: ^App, owner: ui.Id, chosen: Dock_Slot, lit: bool, height: f32, browser := false) -> (pick: Grid_Pick) {
	k := &app.kit
	ctx := &k.ctx
	width := ui.BRUSH_TILE.x * GRID_PER_ROW
	scroll := kit_scroll_begin(ctx, "brush grid", &k.grid_scroll, owner, width, height, 2)
	tiles := make([dynamic]Dock_Slot, context.temp_allocator)
	for kind in sculpt.Brush_Kind do append(&tiles, Dock_Slot{kind = kind})
	kit_grid_rows(app, "brush row", tiles[:], chosen, lit, height, &scroll, &pick)
	ui.caption(ctx, "LIBRARY")
	clear(&tiles)
	for r, j in BUILT_IN_PRESETS do append(&tiles, Dock_Slot{kind = r.kind, preset = BUILT_IN_PRESET + j})
	kit_grid_rows(app, "built-in row", tiles[:], chosen, lit, height, &scroll, &pick)
	if browser do kit_shape_tools(app)
	ui.caption(ctx, "PRESETS")
	clear(&tiles)
	for p, i in app.presets[:app.preset_count] do append(&tiles, Dock_Slot{kind = p.values.kind, preset = i + 1})
	kit_grid_rows(app, "preset row", tiles[:], chosen, lit, height, &scroll, &pick)
	if app.preset_count == 0 do ui.paragraph(ctx, "Save a brush as a preset (Brush palette, Preset) to find it here.", width)
	for pack, i in app.library.packs {
		clear(&tiles)
		for p, j in app.library.presets do if !p.gone && p.pack == pack.id do append(&tiles, Dock_Slot{kind = p.preset.values.kind, preset = PACK_PRESET + j})
		if len(tiles) == 0 do continue
		ui.caption(ctx, ui.text_fit(ctx, strings.to_upper(pack.name, context.temp_allocator), ctx.theme.caption_size, width - 4, .Semibold))
		kit_grid_rows(app, fmt.tprintf("pack %d row", i), tiles[:], chosen, lit, height, &scroll, &pick)
	}
	kit_scroll_end(ctx, scroll)
	if scroll.natural > 0 do k.grid_reveal = false
	return
}

GRID_PER_ROW :: 5

// The mask, hide and cut tools as tiles, as the reference app lists its MaskRect,
// SelectLasso, ClipCurve and KnifeCurve brushes: a tap makes it what Ctrl + drag on empty
// space (a mask shape) or Ctrl + Shift + drag (the rest) draws, as the Mask section's and
// Hide, clip and slice's choices do, leaving the brush held as it is. Each choice's tile
// is lit, so two are lit at once.
@(private = "file")
kit_shape_tools :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.caption(ctx, "MASK, HIDE AND CUT")
	// A row lights one tile (its container's indicator), so the mask shapes have a row of
	// their own and the gesture tools, five, the next.
	ui.begin(ctx, "mask shape tools", {direction = .Row, gap = 0})
	for m in Mask_Shape_Kind {
		name := fmt.tprintf("Mask %s##shape tool", MASK_SHAPE_NAMES[m])
		if ui.brush_tile(ctx, name, SHAPE_TOOL_ICONS[m], app.ui.mask_shape_kind == m, "Ctrl + drag on empty space, or Mask on the wheel") do shape_tool_pick(app, m)
	}
	ui.end(ctx)
	ui.begin(ctx, "gesture tools", {direction = .Row, gap = 0})
	for g in Gesture_Tool {
		name := fmt.tprintf("%s##shape tool", GESTURE_NAMES[g])
		if ui.brush_tile(ctx, name, GESTURE_ICONS[g], app.gesture == g, "Ctrl + Shift + drag, or Hide on the wheel") do shape_tool_pick(app, g)
	}
	ui.end(ctx)
}

// Makes the mask shape or gesture `tool` the one the modifiers draw, closes the browser
// and says how to draw it.
shape_tool_pick :: proc(app: ^App, tool: union {
		Mask_Shape_Kind,
		Gesture_Tool,
	}) {
	switch t in tool {
	case Mask_Shape_Kind:
		app.ui.mask_shape_kind = t
		report(app, Kit_Section.Mask, {}, "Ctrl + drag on empty space (or Mask on the wheel) now masks a %s", strings.to_lower(MASK_SHAPE_NAMES[t], context.temp_allocator))
	case Gesture_Tool:
		app.gesture = t
		report(app, Kit_Section.Visibility, {}, "Ctrl + Shift + drag (or Hide on the wheel) now runs %s", GESTURE_NAMES[t])
	}
	app.kit.browser = false
}

@(rodata)
MASK_SHAPE_NAMES := [Mask_Shape_Kind]string {
	.Rectangle = "rectangle",
	.Lasso     = "lasso",
}

// Lucide's square-dashed and lasso for the mask shapes; square-dashed-mouse-pointer and
// lasso-select for hiding (a selection); crop, scissors-line-dashed and slice (a knife)
// for the cuts.
@(rodata, private = "file")
SHAPE_TOOL_ICONS := [Mask_Shape_Kind]rune {
	.Rectangle = 0xe1cb,
	.Lasso     = 0xe1ce,
}

@(rodata, private = "file")
GESTURE_ICONS := [Gesture_Tool]rune {
	.Hide_Rectangle = 0xe50e,
	.Hide_Lasso     = 0xe1cf,
	.Clip           = 0xe0af,
	.Slice          = 0xe4ee,
	.Knife          = 0xe2f0,
}

// `slots` as tiles GRID_PER_ROW to a row, rows named `row` and their number.
@(private = "file")
kit_grid_rows :: proc(app: ^App, row: string, slots: []Dock_Slot, chosen: Dock_Slot, lit: bool, height: f32, scroll: ^Kit_Scroll, pick: ^Grid_Pick) {
	k := &app.kit
	ctx := &k.ctx
	for s, i in slots {
		if i % GRID_PER_ROW == 0 do ui.begin(ctx, fmt.tprintf("%s %d", row, i / GRID_PER_ROW), {direction = .Row, gap = 0})
		label, hint: string
		switch {
		case s.preset == 0:
			label, hint = BRUSHES[s.kind].name, command_hint(app, .Brush, int(s.kind))
		case preset_of_pack(s.preset):
			p, _ := preset_at(app, s.preset)
			label = fmt.tprintf("%s##pack preset %d", preset_name(p), s.preset - PACK_PRESET)
		case preset_built_in(s.preset):
			p, _ := preset_at(app, s.preset)
			label = fmt.tprintf("%s##built-in preset %d", preset_name(p), s.preset - BUILT_IN_PRESET)
		case:
			label = fmt.tprintf("%s##preset %d", preset_name(&app.presets[s.preset - 1]), s.preset - 1)
		}
		on := lit && dock_slot_same(s, chosen)
		if ui.brush_tile(ctx, label, BRUSHES[s.kind].icon, on, hint) do pick^ = {slot = s, tapped = true}
		// Opening, the grid scrolls to the lit tile, once the body's height is known.
		if on && k.grid_reveal && scroll.natural > 0 {
			at := ctx.last_rect.y - scroll.at.y + scroll.shown
			k.grid_scroll = clamp(at - (height - ui.BRUSH_TILE.y) * 0.5, 0, scroll.limit)
		}
		if ui.secondary(ctx) do pick^ = {slot = s, pressed = true}
		if i % GRID_PER_ROW == GRID_PER_ROW - 1 || i == len(slots) - 1 do ui.end(ctx)
	}
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

// A tool's tile in the brush browser: a tap picks the tool, a long press (or a
// right-click) picks it and shows its settings in the inspector's first tab.
tool_tile :: proc(app: ^App, tool: Tool) {
	ctx := &app.kit.ctx
	id := TOOL_COMMANDS[tool]
	if ui.brush_tile(ctx, fmt.tprintf("%s##tool", kit_tool_name(tool)), TOOL_ICONS[tool], app.tool == tool, command_hint(app, id)) do command_run(app, id)
	if ui.secondary(ctx) do tool_settings_open(app, tool)
}

// Picks `tool` and shows its settings: the tray, on the tool's palette.
tool_settings_open :: proc(app: ^App, tool: Tool) {
	command_run(app, TOOL_COMMANDS[tool])
	side_panel_close(app)
	app.kit.inspector, app.kit.tab, app.kit.scroll = true, .Tool, 0
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

// The brush browser, over its button on the dock or beside the brush bar: the Curve and
// Insert tools, then every brush and preset. A tap picks one; a long press (or a
// right-click) shows its settings.
kit_brush_browser :: proc(app: ^App, anchor: ui.Rect, side: ui.Side) {
	k := &app.kit
	ctx := &k.ctx
	size, _ := ui.prev_layout(ctx, "brush browser")
	owner := ui.id_of(ctx, "brush browser")
	if !ui.popover_begin(ctx, "brush browser", &k.browser, anchor, side, {direction = .Column, gap = 2, padding = 10}) do return
	defer ui.popover_end(ctx)
	kit_grid_head(app, "TOOLS", &k.browser)
	ui.begin(ctx, "tool row", {direction = .Row, gap = 0})
	for tool in ([?]Tool{.Curve, .Insert}) {
		was := app.tool
		tool_tile(app, tool)
		if app.tool != was do k.browser = false
	}
	ui.end(ctx)
	ui.caption(ctx, "BRUSHES")
	chosen, lit := brush_as_slot(app)
	room := grid_room(ctx, size.y, anchor) if side == .Above_Center else grid_room_beside(ctx, size.y)
	pick := kit_brush_grid(app, owner, chosen, lit, room, browser = true)
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
