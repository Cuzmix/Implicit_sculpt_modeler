package main

import "../gizmo"
import "../sculpt"
import "../ui"

// The contextual action bar: above the brush dock, the next steps for what is active on
// the selected object, so a tablet user masks, then inverts or blurs without opening the
// inspector, its Object tab and the Select page. It shows only while something applies: the
// Move tool's gizmo, an HD window open, a mask, hidden parts, or an operation that can
// still be adjusted (adjust_last.odin). HD refuses hidden parts and hiding is refused in HD, so at most three
// groups show. Each button runs its
// command through the registry, as the menus and the palette do. Where the groups do not
// fit beside the panels, each folds to one button that opens its actions above it.

Action_Group :: enum u8 {
	Gizmo,
	Hd,
	Mask,
	Hidden,
	Adjust,
}

Action :: struct {
	id:    Command_Id,
	arg:   int,
	label: string,
}

Action_Group_Info :: struct {
	caption: string,
	actions: []Action,
}

@(rodata)
ACTION_GROUPS := [Action_Group]Action_Group_Info {
	// What the Move tool's handles do, and the Snap and Pivot latches.
	.Gizmo = {"Gizmo", {
		{.Gizmo, int(gizmo.Mode.Move), "Move"},
		{.Gizmo, int(gizmo.Mode.Turn), "Turn"},
		{.Gizmo, int(gizmo.Mode.Scale), "Scale"},
		{.Gizmo_Snap, 0, "Snap"},
		{.Gizmo_Pivot, 0, "Pivot"},
	}},
	.Hd = {"HD", {{.Hd_Leave, 0, "Leave HD"}}},
	// Invert and Clear first, the commonest; the step operations use the Mask section's
	// Steps (Select page).
	.Mask = {"Mask", {
		{.Mask, int(sculpt.Mask_Command.Invert), "Invert"},
		{.Mask, int(sculpt.Mask_Command.Clear), "Clear"},
		{.Mask, int(sculpt.Mask_Command.Blur), "Blur"},
		{.Mask, int(sculpt.Mask_Command.Sharpen), "Sharpen"},
		{.Mask, int(sculpt.Mask_Command.Grow), "Grow"},
		{.Mask, int(sculpt.Mask_Command.Shrink), "Shrink"},
		{.Group_Shortcut, 0, "Make group"},
	}},
	// Mask hidden turns what is hidden into a mask that outlasts Show all.
	.Hidden = {"Hidden", {{.Show_All, 0, "Show all"}, {.Invert_Hidden, 0, "Invert##hidden"}, {.Mask, int(sculpt.Mask_Command.Hidden), "Mask it"}}},
	// Captioned by the operation (action_caption).
	.Adjust = {"Adjust", {{.Adjust_Last, 0, "Adjust..."}}},
}

// A group's caption: the Adjust group's names the operation it adjusts.
action_caption :: proc(app: ^App, g: Action_Group) -> string {
	if g == .Adjust do if name := ADJUST_NAMES[app.adjustable.op]; name != "" do return name
	// The handles pose the mesh while a mask leaves part of it free (pose.odin).
	if g == .Gizmo && pose_mode(app) do return "Pose"
	return ACTION_GROUPS[g].caption
}

// The groups that apply to the selected object now, in the order shown.
action_groups_now :: proc(app: ^App) -> (groups: bit_set[Action_Group]) {
	obj := selected_object(app)
	if obj == nil do return
	if app.tool == .Move do groups += {.Gizmo}
	if object_in_hd(obj) do groups += {.Hd}
	if object_has_mask(app, obj) do groups += {.Mask}
	if sculpt.sculptor_hidden_count(object_sculptor(obj)) > 0 do groups += {.Hidden}
	// Not for a stroke, which would bring the group after every one (adjust_last.odin).
	if adjust_live(app) && app.adjustable.op != .Stroke do groups += {.Adjust}
	return
}

// Whether the bar is laid out at all: on in Settings, with the History panel (which
// takes the same place over the dock) closed, and something to show.
action_bar_shown :: proc(app: ^App) -> bool {
	return app.kit.action_bar && !app.kit.history && action_groups_now(app) != {}
}

// The height of the dock and, when it is shown, the action bar above it, from last frame's
// layout: what the toasts and the inspector keep clear of at the bottom middle.
dock_stack :: proc(app: ^App) -> (h: f32) {
	ctx := &app.kit.ctx
	dock, _ := ui.prev_layout(ctx, "dock")
	h = dock.y
	if bar, _ := ui.prev_layout(ctx, "action bar"); bar.y > 0 do h += bar.y + ACTION_BAR_GAP
	return
}

ACTION_BAR_GAP :: 8
ACTION_BAR_PADDING :: 4

// How wide the bar may be: centred, it stays clear of the left column on either side (the
// sliders always, which on a short window reach down to the bar, and the modifier rail
// when shown) and of the panel on the right while that sits beside the dock rather than
// above it.
action_bar_room :: proc(app: ^App) -> f32 {
	k := &app.kit
	t := k.ctx.theme
	area := ui.safe_area(&k.ctx)
	sliders, _ := ui.prev_layout(&k.ctx, "sliders")
	side := t.edge + sliders.x + 8
	if k.rail_side != .Off do side = max(side, t.edge + rail_size(t).x + 8)
	panel: f32 = KIT_SETTINGS_W if side_panel_open(k) else KIT_INSPECTOR_W if k.inspector else 0
	dock, _ := ui.prev_layout(&k.ctx, "dock")
	// The inspector moves up above the dock and bar where the dock reaches it (kit_inspector).
	beside := area.w * 0.5 + dock.x * 0.5 + 8 <= area.w - t.edge - panel
	if panel > 0 && (beside || side_panel_open(k)) do side = max(side, t.edge + panel + 8)
	return area.w - 2 * side
}

// The bar's width with every action showing: the buttons as ui.button fits them, the
// captions, and the dividers between groups.
action_bar_full_width :: proc(app: ^App, groups: bit_set[Action_Group]) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	w: f32 = 2 * ACTION_BAR_PADDING
	n := 0
	for g in groups {
		if n > 0 do w += 1 + 2 * 4 // a divider and the gaps round it
		info := ACTION_GROUPS[g]
		w += ui.text_width(ctx, action_caption(app, g), t.small_size) + 4 + 2 * 4
		for a in info.actions do w += ui.text_width(ctx, ui.label_text(a.label), t.text_size, .Semibold) + 28 + 4
		n += 1
	}
	return w
}

// Its width with each group folded to one button.
action_bar_compact_width :: proc(app: ^App, groups: bit_set[Action_Group]) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	w: f32 = 2 * ACTION_BAR_PADDING
	n := 0
	for g in groups {
		if n > 0 do w += 1 + 2 * 4
		w += ui.text_width(ctx, action_caption(app, g), t.text_size, .Semibold) + t.icon_small + 6 + 28
		n += 1
	}
	return w
}

kit_action_bar :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	// Set again below while the bar shows the Adjust group; without it the adjust popover
	// sits above the dock.
	k.adjust_anchor = {}
	if !action_bar_shown(app) {
		k.action_pop = false
		return
	}
	groups := action_groups_now(app)
	// A folded group that went (an undo took the mask) takes its popover with it, so the
	// popover never runs actions for a state that no longer holds.
	if k.action_group not_in groups do k.action_pop = false
	room := action_bar_room(app)
	compact := action_bar_full_width(app, groups) > room
	// With no room even folded (Settings open on a narrow window), it waits.
	if compact && action_bar_compact_width(app, groups) > room {
		k.action_pop = false
		return
	}
	dock, _ := ui.prev_layout(ctx, "dock")
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "action bar", .Center, .End, {0, t.edge + dock.y + ACTION_BAR_GAP}, {direction = .Row, gap = 4, padding = ACTION_BAR_PADDING, radius = t.radius_large + 4, background = .Panel, center = true})
	n := 0
	for g in groups {
		info := ACTION_GROUPS[g]
		if n > 0 do ui.divider(ctx, 28)
		n += 1
		caption := action_caption(app, g)
		if compact {
			// One button for the group, which opens its actions above the bar; Adjust's
			// opens its settings straight away, since it has one action.
			if ui.button(ctx, caption, .Light, glyph = ui.ICON_CHEVRON_UP) {
				if g == .Adjust {
					if k.adjust_pop do k.adjust_pop = false
					else do adjust_open(app)
				} else {
					k.action_pop = !(k.action_pop && k.action_group == g)
					k.action_group = g
				}
			}
			if k.action_group == g do k.action_anchor = ctx.last_rect
			continue
		}
		ui.spacer(ctx, 4)
		ui.label(ctx, caption, t.small_size)
		for a in info.actions do _ = action_button(app, a)
	}
	ui.end(ctx)
	// The adjust popover sits over the middle of the bar, folded or not, as wide as the
	// bar's room allows; last frame's place is close enough for an anchor.
	if .Adjust in groups do k.adjust_anchor = ui.prev_rect(ctx, "action bar")
	// Over a stroke or a turn of the view, the bar dims so the model shows through.
	busy := app.stroke.active || app.drag.owner != .None
	dim := ui.tween(ctx, ui.id_of(ctx, "action bar dim"), 0.35 if busy else 1, t.indicator_time)
	ui.transform_since(ctx, mark, dim)
	if !compact do k.action_pop = false
}

// An action's button: one that is on or off (a gizmo mode, Snap) shows which, as the
// toolbar's symmetry buttons do. Runs it when clicked and returns true then.
@(private = "file")
action_button :: proc(app: ^App, a: Action, width: f32 = 0) -> bool {
	if COMMANDS[a.id].checked == nil do return command_button(app, a.id, a.arg, a.label, width = width)
	ctx := &app.kit.ctx
	w := width if width > 0 else ui.text_width(ctx, ui.label_text(a.label), ctx.theme.text_size, .Semibold) + 28
	if !ui.toggle_button(ctx, a.label, command_checked(app, a.id, a.arg), w, command_hint(app, a.id, a.arg), command_label(a.id, a.arg)) do return false
	return command_run(app, a.id, a.arg)
}

// A folded group's actions, above its button; drawn with what floats over the panels.
kit_action_popover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if !k.action_pop do return
	if ui.popover_begin(ctx, "action group", &k.action_pop, k.action_anchor, .Above_Center, {direction = .Column, gap = 2, padding = 6, width = 200}) {
		for a in ACTION_GROUPS[k.action_group].actions {
			if action_button(app, a, ui.fill_width(ctx)) do k.action_pop = false
		}
		ui.popover_end(ctx)
	}
}
