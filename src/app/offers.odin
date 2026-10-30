package main

import "core:fmt"

import "../ui"

// Offers, not refusals (the overhaul's round 3, PR 7): when the selected object does not
// fit the space at work or the tool held (a cage in Sculpt, a mesh in Model, voxel clay
// under a brush that needs a mesh), the object chip warns in amber and one line over the
// dock, where the action bar is, names what the object is, what the space needs and the
// one tap that makes it fit, as Blender's and Nomad's mode switches offer the conversion
// rather than a greyed-out tool. Commands that cannot act on the selection are dimmed with
// the reason in their tooltip (command_reason), and a press on the view says nothing
// while the line already says it.

Offer :: struct {
	what:  string, // "Cube 2 is a cage"
	needs: string, // "Sculpt needs a mesh"
	fix:   Command_Id,
	arg:   int,
	label: string, // the fix's own name here ("Make sculptable")
}

// Whether the selection fits the space and the tool; when not, the offer that makes it
// fit. Only an offer whose fix can run now stands, so a tap on it never lands on a
// refusal. Nothing selected, Render (which only looks) and the Move tool always fit. In
// temp memory.
space_fit :: proc(app: ^App) -> (fits: bool, offer: Offer) {
	obj := selected_object(app)
	if obj == nil do return true, {}
	name := object_label(obj)
	kind := object_type(obj)
	#partial switch app.kit.spaces.current {
	case .Sculpt:
		if app.tool == .Move do break
		if kind == .Cage {
			offer = {fmt.tprintf("%s is a cage", name), "Sculpt needs a mesh", .Apply_Cage, 0, "Make sculptable"}
		} else if kind == .Voxel_Clay && app.tool == .Brush {
			if _, ok := voxel_brush_of({kind = app.brush.kind}, {}); !ok {
				offer = {fmt.tprintf("%s is voxel clay", name), fmt.tprintf("%s needs a mesh", BRUSHES[app.brush.kind].name), .Convert_To_Mesh, 0, "Convert to mesh"}
			}
		}
	case .Model:
		if app.tool != .Model do break
		switch kind {
		case .Cage:
		case .Voxel_Clay:
			offer = {fmt.tprintf("%s is voxel clay", name), "Model edits a cage", .Convert_To_Mesh, 0, "Make a mesh to edit"}
		case .Sculpt_Mesh:
			// A sculpt that came from a cage turns back into it; any other gets one laid
			// over it.
			if command_enabled(app, .Edit_Cage) do offer = {fmt.tprintf("%s is a sculpt mesh", name), "Model edits a cage", .Edit_Cage, 0, "Make editable"}
			else do offer = {fmt.tprintf("%s is a sculpt mesh", name), "Model edits a cage", .Retopologize, 0, "Quad Remesh"}
		}
	}
	if offer.fix == .None || !command_enabled(app, offer.fix, offer.arg) do return true, {}
	return false, offer
}

// Whether an offer stands: the line shows it, so a press on the view need not say it too.
offer_standing :: proc(app: ^App) -> bool {
	fits, _ := space_fit(app)
	return !fits
}

// Why `id` cannot act on the selection, for a dimmed control's tooltip: "" when it can,
// or when what stops it is not the selection's kind.
command_reason :: proc(app: ^App, id: Command_Id, arg := 0) -> string {
	if long_job_holds(app, id) do return long_job_reason(app)
	obj := selected_object(app)
	if obj == nil do return ""
	if obj.cage != nil && id in CAGE_REFUSED_COMMANDS do return fmt.tprintf("%s is a cage: Make sculptable first, or edit it with the Model tool", object_label(obj))
	if obj.voxel != nil && id in VOXEL_REFUSED_COMMANDS do return fmt.tprintf("%s is voxel clay: Convert to mesh first", object_label(obj))
	return ""
}

// The commands that work on a mesh object's level and so cannot act on voxel clay, which
// has its own resolution, repair and conversion: each issues one of MESH_ONLY_COMMANDS'
// scene commands, which scene_apply still refuses for scripts.
VOXEL_REFUSED_COMMANDS :: bit_set[Command_Id; [4]u64]{
	.Remesh, .Remesh_To, .Decimate_To, .Dyntopo_Toggle, .Subdivide, .Level_Up, .Level_Down, .Hd_Toggle, .Hd_Divide,
	.Hd_Delete, .Hd_Sculpt, .Hd_Leave, .Delete_Lower_Levels, .Delete_Higher_Levels, .Mirror_Weld, .Close_Holes,
	.Delete_Hidden, .Weld_Points, .Fix_Mesh, .Delete_Half, .Retopologize, .Extract_Masked, .Split_Object, .Merge_Down,
	.Merge_Visible, .Remove_Textures,
}

// The offer line, in the action bar's place over the dock (it keeps the bar's name, so
// what keeps clear of the bar keeps clear of it): the object's type icon in amber, what it
// is and what the space needs, and the fix. Returns false when no offer stands, leaving
// the place to the action bar.
kit_offer_line :: proc(app: ^App) -> bool {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	fits, offer := space_fit(app)
	k.offer = .None if fits else offer.fix
	if fits || .Action_Bar in k.hidden || k.history do return false
	room := action_bar_room(app)
	button_w := ui.text_width(ctx, offer.label, t.text_size, .Semibold) + t.icon_small + 6 + 28
	dock := shelf_bottom_size(app)
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "action bar", .Center, .End, {0, t.edge + dock_lift(app) + dock.y + ACTION_BAR_GAP + colour_island_lift(app)}, {direction = .Row, gap = 8, padding = ACTION_BAR_PADDING, radius = t.radius_large + 4, background = .Panel, center = true})
	obj := selected_object(app)
	text := fmt.tprintf("%s · %s", offer.what, offer.needs)
	text_w := min(ui.text_width(ctx, text, t.small_size), max(room - button_w - t.icon_small - 48, 0))
	a := ui.area(ctx, "offer text", {t.icon_small + 8 + text_w + 8, t.target})
	cy := a.rect.y + a.rect.h * 0.5
	ui.icon(ctx, OBJECT_TYPE_ICONS[object_type(obj)], {a.rect.x + 8 + t.icon_small * 0.5, cy}, t.icon_small, t.warning)
	ui.text(ctx, ui.text_fit(ctx, text, t.small_size, text_w), a.rect.x + t.icon_small + 16, cy, t.small_size, t.text)
	ui.tip(ctx, a.id, a.rect, text, "")
	if command_button(app, offer.fix, offer.arg, offer.label, .Solid, .Accent, glyph = COMMANDS[offer.fix].icon) do k.offer_fixes += 1
	ui.end(ctx)
	busy := app.stroke.active || app.drag.owner != .None
	dim := ui.tween(ctx, ui.id_of(ctx, "action bar dim"), 0.35 if busy else 1, t.indicator_time)
	// It rises into place as it appears, as a popover does.
	shown := ui.presence(ctx, ui.id_of(ctx, "offer line shown"), true, t.popover_time, motion_class(.Popovers))
	ui.transform_since(ctx, mark, dim * shown, offset = {0, (1 - shown) * 8})
	return true
}
