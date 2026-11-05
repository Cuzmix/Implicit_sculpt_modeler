package main

import "core:fmt"

import "../gizmo"
import "../ui"

// The pivot row: a row of icons floating just over the Move tool's gizmo, as ZBrush's
// Gizmo 3D has its icons over it, for what is done to the pivot rather than the object:
// Edit pivot (the move handles move the pivot, Nomad's Edit pivot), to the middle, to the
// unmasked middle while a mask is on (ZBrush's Go to unmasked center), on a surface (the
// next tap places it), back to the origin, Snap, and the gizmo's orientation (a tap steps
// World, Object, Surface, View). Each is a registry command, as the
// Move tab's buttons are, so the row, the Move tab, Search and keys run the same ones.
// It steps out of the way while a drag goes and goes below the gizmo when there is no
// room above; the Move tab's switch hides it.

// The commands on the row, in order; Unmasked middle only while it can run.
@(rodata)
PIVOT_ROW := [?]Command_Id{.Gizmo_Pivot_Edit, .Gizmo_Pivot_Center, .Gizmo_Pivot_Unmasked, .Gizmo_Pivot, .Gizmo_Pivot_Reset, .Gizmo_Snap}

// How far the gizmo reaches from its middle at most (the All mode's arrow tips), in
// points, which the row keeps clear of.
PIVOT_ROW_CLEAR :: gizmo.ARM_PX * gizmo.ALL_ARM + 10

// Whether the row shows this frame.
pivot_row_shown :: proc(app: ^App) -> bool {
	m := &app.move
	if app.tool != .Move || m.pivot_row_off || selected_object(app) == nil || lattice_shown(app) != nil do return false
	// Out of the way while a handle, the object or a topological mask is being dragged.
	return m.drag.handle == .None && m.topo.phase == .None && !app.kit.clean
}

// The row, over the gizmo where the view showed it last.
kit_pivot_row :: proc(app: ^App) {
	if !pivot_row_shown(app) do return
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sc := gizmo_screen(app, app.ui.viewport_size)
	if !sc.ok do return
	scale := k.scale if k.scale > 0 else 1
	mid := (sc.center + app.ui.viewport_origin) / scale
	cell := t.target if app.device.pointer == .Finger else t.control + 6
	shown := 0
	for id in PIVOT_ROW do if id != .Gizmo_Pivot_Unmasked || command_enabled(app, id, 0) do shown += 1
	shown += 1 // the orientation
	pad: f32 = 3
	size := [2]f32{f32(shown) * cell + 2 * pad, cell + 2 * pad}
	area := ui.safe_area(ctx)
	pos := [2]f32{mid.x - size.x * 0.5, mid.y - PIVOT_ROW_CLEAR - size.y}
	// Below the gizmo when the top of the view leaves no room above it.
	if pos.y < area.y + t.target do pos.y = mid.y + PIVOT_ROW_CLEAR
	pos.x = clamp(pos.x, area.x, max(area.x, area.x + area.w - size.x))
	ui.begin_at(ctx, "pivot row", pos, {direction = .Row, padding = pad, radius = t.radius_large, background = .Panel, center = true})
	defer ui.end(ctx)
	for id in PIVOT_ROW {
		if id == .Gizmo_Pivot_Unmasked && !command_enabled(app, id, 0) do continue
		glyph := COMMANDS[id].icon
		// The lock shows what a drag of a handle does now: locked moves the object.
		if id == .Gizmo_Pivot_Edit && !app.move.pivot_edit do glyph = ICON_LOCK
		if ui.icon_button(ctx, command_label(id, 0), glyph, selected = command_checked(app, id, 0), enabled = command_enabled(app, id, 0), keys = command_hint(app, id, 0), size = cell) {
			command_run(app, id, 0)
		}
	}
	// The orientation shows its own icon, and a tap steps to the next one.
	now := app.move.orient
	next := int(now) + 1 if now != max(Gizmo_Orient) else 0
	if ui.icon_button(ctx, fmt.tprintf("%s##orientation", command_label(.Gizmo_Orient, int(now))), GIZMO_ORIENT_ICONS[now], keys = command_hint(app, .Gizmo_Orient, next), size = cell) {
		command_run(app, .Gizmo_Orient, next)
	}
}
