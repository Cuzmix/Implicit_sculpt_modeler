package main

import "core:strings"

import "../sculpt"
import "../ui"

// What the brush browser and the brush picker (kit_brushes.odin) offer as one tile: a
// brush, a preset made from one, or a command; and the tools' and shapes' picks they share.

Dock_Slot :: struct {
	kind:    sculpt.Brush_Kind, // the brush, or the preset's own brush
	preset:  int, // the preset, numbered as PACK_PRESET says; 0 for the plain brush
	command: Bar_Slot, // a command in place of a brush, when its id is not .None
}

// Whether two slots hold the same thing: the same preset, or the same plain brush.
dock_slot_same :: proc(a, b: Dock_Slot) -> bool {
	if a.command.id != .None || b.command.id != .None do return a.command == b.command
	return a.preset == b.preset && (a.preset != 0 || a.kind == b.kind)
}

// What the brush is, as a slot; false while another tool is picked.
brush_as_slot :: proc(app: ^App) -> (Dock_Slot, bool) {
	return {kind = app.brush.kind, preset = app.brush.preset}, app.tool == .Brush
}

// Whether the brush is what `s` holds, or for a command, whether it is on.
dock_slot_on :: proc(app: ^App, s: Dock_Slot) -> bool {
	if s.command.id != .None do return bar_lit(app, s.command)
	now, ok := brush_as_slot(app)
	return ok && dock_slot_same(now, s)
}

// What a slot's tile shows: the preset's name or the brush's, over the brush's icon.
dock_slot_label :: proc(app: ^App, s: Dock_Slot) -> string {
	if s.command.id != .None do return bar_label(app, s.command)
	if p, ok := preset_at(app, s.preset); ok do return preset_name(p)
	return BRUSHES[s.kind].name
}

// Picks what `s` holds, or runs its command.
dock_slot_pick :: proc(app: ^App, s: Dock_Slot) {
	if s.command.id != .None do command_run(app, s.command.id, s.command.arg)
	else if s.preset > 0 do preset_use(app, s.preset)
	else do command_run(app, .Brush, int(s.kind))
}

// Picks what `s` holds and shows its settings.
dock_slot_settings :: proc(app: ^App, s: Dock_Slot) {
	if s.command.id != .None do return
	if s.preset > 0 do preset_settings_open(app, s.preset)
	else do brush_settings_open(app, s.kind)
}

// Picks the preset numbered `n` (PACK_PRESET) and shows its settings: the tray, on the
// brush's Preset section, to rename it or save its changes.
preset_settings_open :: proc(app: ^App, n: int) {
	preset_use(app, n)
	tray_open(app, .Preset)
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
@(rodata)
SHAPE_TOOL_ICONS := [Mask_Shape_Kind]rune {
	.Rectangle = 0xe1cb,
	.Lasso     = 0xe1ce,
}

@(rodata)
GESTURE_ICONS := [Gesture_Tool]rune {
	.Hide_Rectangle = 0xe50e,
	.Hide_Lasso     = 0xe1cf,
	.Clip           = 0xe0af,
	.Slice          = 0xe4ee,
	.Knife          = 0xe2f0,
}

// Where the brushes open: the brush picker over the shelf (All, or B), or with the shelf
// hidden the brush browser under the menu.
Browser_At :: enum u8 {
	Dock,
	Bar,
}

// Picks `tool` and shows its settings: the tray, on the tool's palette.
tool_settings_open :: proc(app: ^App, tool: Tool) {
	command_run(app, TOOL_COMMANDS[tool])
	side_panel_close(app)
	app.kit.inspector, app.kit.stack.revealed = true, nil
	stack_reveal_card(app, .Brush)
}

@(rodata)
TOOL_COMMANDS := [Tool]Command_Id {
	.Move   = .Tool_Move,
	.Brush  = .Tool_Sculpt,
	.Curve  = .Tool_Curve,
	.Insert = .Tool_Insert,
	.Model  = .Tool_Model,
}

@(rodata)
TOOL_ICONS := [Tool]rune {
	.Move   = ui.ICON_MOVE,
	.Brush  = ui.ICON_BRUSH,
	.Curve  = ui.ICON_SPLINE,
	.Insert = ui.ICON_SHAPES,
	.Model  = ui.ICON_GRID,
}
