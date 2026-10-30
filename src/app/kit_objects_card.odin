package main

import "core:fmt"
import "core:strings"

import "../geom"
import "../sculpt"
import "../ui"

// The Objects card: the Objects card command opens it beside the view rail, as ZBrush for
// iPad's quick-access Subtools card. A strip of dots on top drags it (holding them puts it
// back in the Scene palette), a big title, four buttons (Add, Duplicate, New folder and
// More), then the objects as tall rows with a picture of each (object_thumbs.odin), its
// name, its boolean switch, its polypaint and its eye, and a bar under the list that sets
// how tall the list is. A tap selects a row; a long press opens its menu, and a drag
// after that moves the row (a mouse drags it at once). The Scene palette's Objects
// section stays as the other place to reach the same objects, as ZBrush keeps Tool >
// Subtool. The card and the palette tray share their place, so one opening closes the other.

// The list's height to start with, and the least the bar under it sets.
CARD_LIST_H :: 5 * ui.THUMB_ROW_H
CARD_LIST_MIN :: 2 * ui.THUMB_ROW_H

// The card's state between frames.
Objects_Card :: struct {
	scroll:   f32, // the list's, where it is heading
	list_h:   f32, // the list's height as the bar set it; 0 until then (CARD_LIST_H)
	from_h:   f32, // the height and the pointer's y when the bar was pressed
	from_y:   f32,
	// The Add menu (Insert below the selection, or Append at the end), and More.
	add:      bool,
	add_at:   ui.Rect,
	append:   bool,
	more:     bool,
	more_at:  ui.Rect,
	// A row's menu: on which object, where, and whether that object was selected when it
	// opened (the full menu) or not (its boolean only, as ZBrush has it).
	menu:     bool,
	menu_id:  int,
	menu_at:  ui.Rect,
	menu_all: bool,
	booleans: bool, // the menu's Boolean process rows are unfolded
	// The Actions under the list: unfolded or not, where they are scrolled, and which of
	// their sections are open.
	actions:  bool,
	actions_scroll: f32,
	open:     [Card_Action]bool,
	tray_was: bool, // the tray or a side panel was open last frame
	rows:     int, // rows drawn last frame, for the exit stats
}

// The sections of the card's Actions, in ZBrush's order.
Card_Action :: enum u8 {
	Split,
	Merge,
	Transpose,
	Boolean,
	Align,
	Distribute,
	Project,
	Extract,
}

@(rodata)
CARD_ACTION_NAMES := [Card_Action]string {
	.Split      = "Split",
	.Merge      = "Merge",
	.Transpose  = "Transpose",
	.Boolean    = "Boolean",
	.Align      = "Align",
	.Distribute = "Distribute",
	.Project    = "Project",
	.Extract    = "Extract",
}

// The least height the Actions get when open: the list gives up the rest of its room.
CARD_ACTIONS_MIN :: 3 * ui.THUMB_ROW_H

// The icons of Align's and Distribute's tiles, by axis (the rows) and edge (low side,
// middle, high side): lines and blocks as ZBrush's card draws them. Z, the depth, takes
// X's, as seen from above.
@(rodata)
ALIGN_GLYPHS := [3][3]rune {
	{0xe271, 0xe26d, 0xe26f}, // align-start-, -center- and -end-vertical
	{0xe26e, 0xe26c, 0xe270}, // align-end-, -center- and -start-horizontal: bottom, middle, top
	{0xe271, 0xe26d, 0xe26f},
}
@(rodata)
DISTRIBUTE_GLYPHS := [3][3]rune {
	{0xe03f, 0xe03d, 0xe03e}, // align-horizontal-distribute-start, -center, -end
	{0xe27f, 0xe27e, 0xe280}, // align-vertical-distribute-end, -center, -start: bottom, middle, top
	{0xe03f, 0xe03d, 0xe03e},
}

// Opens the card, closing the tray and the side panels, which share its place while it
// floats, or closes it.
objects_card_toggle :: proc(app: ^App) {
	k := &app.kit
	k.objects_card = !k.objects_card
	if k.objects_card {
		side_panel_close(app)
		k.inspector = false
	}
}

// Draws the card; returns true when a press landed on it, to bring it to the front.
kit_objects_card :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	c := &k.card
	// The tray or a side panel opening takes the floating card's place.
	tray := k.inspector || side_panel_open(k)
	if tray && !c.tray_was do k.objects_card = false
	c.tray_was = tray
	if !k.objects_card do c.add, c.more, c.menu = false, false, false
	shown := ui.presence(ctx, panel_id(Kit_Window.Objects), k.objects_card, t.panel_time)
	c.rows = 0
	if shown <= 0 do return
	win := &k.windows[.Objects]
	PADDING :: 12
	GAP :: 6
	inner := f32(KIT_INSPECTOR_W - 2 * PADDING)
	top := kit_top()
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, Kit_Window.Objects, "Objects", .End, .Start, {kit_right(app), top}, {direction = .Column, gap = GAP, padding = PADDING, width = KIT_INSPECTOR_W, radius = t.radius_large, background = .Panel, inert = !k.objects_card}, card = true)
	raised = p.raised
	id := p.owner
	if p.closed do k.objects_card = false
	if p.dock && k.objects_card {
		k.objects_card = false
		tray_open(app, .Objects)
		c.tray_was = true
	}
	if !p.body {
		panel_end(app, &p)
		ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
		return
	}

	// The four buttons, spread across the card as ZBrush has them.
	ui.begin(ctx, "objects card buttons", {direction = .Row, width = inner, gap = (inner - 4 * t.target) / 3})
	if ui.icon_button(ctx, "Add", ui.ICON_CIRCLE_PLUS, selected = c.add) {
		c.add, c.more = !c.add, false
		c.add_at = ctx.last_rect
	}
	if ui.icon_button(ctx, command_label(.Duplicate_Object), ui.ICON_COPY, enabled = command_enabled(app, .Duplicate_Object), keys = command_hint(app, .Duplicate_Object)) do command_run(app, .Duplicate_Object)
	if ui.icon_button(ctx, command_label(.New_Folder), ui.ICON_FOLDER_PLUS, enabled = command_enabled(app, .New_Folder), keys = command_hint(app, .New_Folder)) do command_run(app, .New_Folder)
	if ui.icon_button(ctx, "More", ui.ICON_MORE, selected = c.more) {
		c.more, c.add = !c.more, false
		c.more_at = ctx.last_rect
	}
	ui.end(ctx)

	// The list, as tall as the bar under it says and no taller than the window has room for
	// beside the Actions' header, and with the Actions open, beside some of them too.
	header := t.target - 8 + GAP
	room := p.room - (t.target + t.target + 2 * GAP) - header
	list_room := room - CARD_ACTIONS_MIN - GAP if c.actions else room
	list_h := clamp(c.list_h if c.list_h > 0 else CARD_LIST_H, CARD_LIST_MIN, max(list_room, CARD_LIST_MIN))
	scroll := kit_scroll_begin(ctx, "objects card list", &c.scroll, id, inner, list_h, 0)
	objects := app.scene.objects[:]
	spots := make([dynamic]Tree_Spot, 0, len(objects) + len(app.scene.folders), context.temp_allocator)
	for i := 0; i < len(objects); {
		obj := objects[i]
		f := folder_by_id(app, obj.folder)
		if f == nil {
			card_object_row(app, &spots, i)
			i += 1
			continue
		}
		first, end := folder_span(app, f.id)
		card_folder_row(app, &spots, f, first, end, &c.rows)
		if f.open do for j in first ..< end do card_object_row(app, &spots, j)
		i = end
	}
	for &f in app.scene.folders {
		if first, end := folder_span(app, f.id); end > first do continue
		card_folder_row(app, &spots, &f, 0, 0, &c.rows)
	}
	if len(objects) == 0 do ui.paragraph(ctx, "No objects yet: Add puts a shape in the scene.")
	kit_tree_drags(app, spots[:], {scroll.at, &c.scroll, scroll.limit})
	kit_scroll_end(ctx, scroll)

	// The bar under the list: dragging it makes the list taller or shorter.
	bar := ui.area(ctx, "objects card size", {inner, t.target * 0.6})
	if bar.pressed {
		c.from_h, c.from_y = list_h, bar.mouse.y
		_ = ui.claim_drag(ctx, -1)
	}
	if bar.held do c.list_h = clamp(c.from_h + bar.mouse.y - c.from_y, CARD_LIST_MIN, max(list_room, CARD_LIST_MIN))
	pill := t.accent if bar.held else (t.text if bar.hovered else t.text_tertiary)
	ui.fill_rect(ctx, {bar.rect.x + bar.rect.w * 0.5 - 20, bar.rect.y + bar.rect.h * 0.5 - 2, 40, 4}, 2, pill)

	// The Actions, folded under the list at first, as ZBrush's card has them; open, they
	// scroll in the room the list leaves.
	if ui.section(ctx, "Actions##objects card", &c.actions) {
		// The list takes no more than its rows need, so the rest goes to the Actions.
		shown_h := min(list_h, scroll.natural) if scroll.natural > 0 else list_h
		body := kit_scroll_begin(ctx, "objects card actions", &c.actions_scroll, id, inner, max(room - shown_h - GAP, CARD_ACTIONS_MIN), GAP)
		card_actions(app, inner)
		kit_scroll_end(ctx, body)
		ui.section_end(ctx)
	}
	panel_end(app, &p)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
	return
}

// The Actions' content: Store visibility's V1 to V8, then a section for each action.
@(private = "file")
card_actions :: proc(app: ^App, inner: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.card
	ui.label(ctx, "Store visibility", t.small_size, t.text_secondary)
	ui.begin(ctx, "objects card slots", {direction = .Row, width = inner, gap = 4})
	slot_w := (inner - 4 * (VIS_SLOTS - 1)) / VIS_SLOTS
	// Outlined tiles, the one chosen in the accent, as ZBrush's.
	for k in 0 ..< VIS_SLOTS {
		chosen := app.scene.vis_slot == k + 1
		_ = command_button(app, .Visibility_Slot, k, fmt.tprintf("V%d##visibility slot", k + 1), .Flat if chosen else .Bordered, .Accent if chosen else .Neutral, slot_w)
	}
	ui.end(ctx)
	half := (inner - 6) / 2
	for action in Card_Action {
		if !ui.section(ctx, fmt.tprintf("%s##card action", CARD_ACTION_NAMES[action]), &c.open[action]) do continue
		defer ui.section_end(ctx)
		switch action {
		case .Split:
			for row in 0 ..< 2 {
				ui.begin(ctx, fmt.tprintf("card split %d", row), {direction = .Row, width = inner, gap = 6})
				for col in 0 ..< 2 do _ = command_button(app, .Split_Object, 2 * row + col, width = half)
				ui.end(ctx)
			}
			ui.paragraph(ctx, "The object keeps the first part and each other part becomes an object below it. The levels go; the polypaint and polygroups stay.")
		case .Merge:
			_ = command_button(app, .Merge_Down, width = inner)
			_ = command_button(app, .Merge_Visible, width = inner)
			ui.paragraph(ctx, "Each object merged in keeps polygroups of its own, so Groups split takes them apart again. Merge down drops the levels and layers of the selected object.")
		case .Transpose:
			ui.paragraph(ctx, fmt.tprintf("Select several objects (Ctrl or Shift and a tap, or Select several) and the Move tool's gizmo (%s) moves, turns and scales them together; to pose part of one object, mask the rest and use the gizmo.", command_keys(app, .Tool_Move)))
		case .Boolean:
			kit_boolean_section(app)
		case .Align, .Distribute:
			id := Command_Id.Align_Objects if action == .Align else .Distribute_Objects
			glyphs := ALIGN_GLYPHS if action == .Align else DISTRIBUTE_GLYPHS
			LABEL :: 22
			tile := (inner - LABEL - 3 * 6) / 3
			for axis in 0 ..< 3 {
				ui.begin(ctx, fmt.tprintf("card %v %d", action, axis), {direction = .Row, width = inner, gap = 6, center = true})
				ui.begin(ctx, fmt.tprintf("card %v %d label", action, axis), {width = LABEL})
				ui.label(ctx, AXIS_NAMES[axis], t.small_size, t.text_secondary, .Semibold)
				ui.end(ctx)
				for edge in 0 ..< 3 do _ = command_button(app, id, 3 * axis + edge, width = tile, glyph = glyphs[axis][edge], icon_only = true)
				ui.end(ctx)
			}
			if action == .Align {
				ui.paragraph(ctx, "Several selected line up with the first selected; one alone lines up with everything shown.")
			} else {
				ui.paragraph(ctx, "Spaces the selected objects evenly, or every shown object when fewer than three are selected; the outermost two stay.")
			}
		case .Project:
			kit_project_section(app)
		case .Extract:
			kit_extract_section(app)
		}
	}
}

// An object's row, the list's `i`th: its picture, name, boolean switch, polypaint and eye.
@(private = "file")
card_object_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, i: int) {
	k := &app.kit
	ctx := &k.ctx
	c := &k.card
	objects := app.scene.objects[:]
	obj := objects[i]
	label := object_label(obj)
	parts := ui.Thumb_Row{glyph = ui.ICON_FRAME, count = -1}
	if lo, hi, ok := thumb_for(app, obj); ok do parts.image, parts.lo, parts.hi = KIT_THUMBS_IMAGE, lo, hi
	// The switch under the name: whether the object takes part in booleans, as a subtract
	// when it is turned on (the menu's Boolean process picks another way).
	parts.under = {name = "Leave out of booleans" if obj.boolean != .None else "Subtract in booleans"}
	parts.under_on = obj.boolean != .None
	painted := object_has_paint(obj)
	toggles := [2]ui.Row_Toggle{
		{name = fmt.tprintf("Show %s's polypaint", label) if obj.paint_off else fmt.tprintf("Hide %s's polypaint", label), glyph = ui.ICON_PAINTBRUSH, lit = painted && !obj.paint_off, faint = !painted || obj.paint_off},
		{name = fmt.tprintf("Show %s", label) if obj.off else fmt.tprintf("Hide %s", label), glyph = ui.ICON_EYE_OFF if obj.off else ui.ICON_EYE, faint = obj.off},
	}
	dragged := k.tree_drag.active && k.tree_drag.key == obj.id
	selected := object_in_selection(app, obj)
	row := ui.thumb_row(ctx, fmt.tprintf("%s##card %d", label, obj.id), parts, selected, dim = dragged || !object_shown(app, obj), all_toggles = toggles[:], drags = true)
	append(spots, Tree_Spot{rect = row.rect, id = obj.id, folder = obj.folder, next = objects[i + 1].id if i + 1 < len(objects) else 0, off = obj.off, ghost = obj.ghost})
	// Only the eye's column sweeps down the rows (the tree's column 1).
	kit_row_drags(app, row.dragged, 1 if row.held_toggle == 1 else -1, row.rect, obj.id, obj.ghost, obj.off)
	if row.dragged do c.menu = false
	if !k.tree_column.active {
		switch row.toggled {
		case 0: app.ui.scene_command = {kind = .View, view = .Paint_Show if obj.paint_off else .Paint_Hide, id = obj.id}
		case 1: app.ui.scene_command = {kind = .View, view = .Show if obj.off else .Hide, id = obj.id}
		}
	}
	// The boolean mode is the object's own flag, as the Booleans section sets it.
	if row.under do obj.boolean = .None if obj.boolean != .None else .Subtract
	several := k.select_several || ctx.input.ctrl || ctx.input.shift
	if !object_pickable(app, obj) {
		if row.clicked do app.ui.scene_command = {kind = .View, view = .Select, id = obj.id}
	} else if row.clicked && several {
		selection_toggle(app, i)
	} else if row.clicked {
		select_only(app, i)
	}
	if row.menu {
		c.menu, c.menu_id, c.menu_at, c.menu_all, c.booleans = true, obj.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, i == app.scene.selected, false
		c.add, c.more = false, false
	}
	c.rows += 1
}

// A folder's row: a folder with the count of its objects in it, its name, a chevron that
// folds it, and its eye. A tap selects its first object and a long press opens the
// folder's menu. `rows` counts the rows drawn (the card's, or Lens's Scene card's); with
// `drags` false (a filtered list) it does not move.
card_folder_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, f: ^Folder, first, end: int, rows: ^int, drags := true) {
	k := &app.kit
	ctx := &k.ctx
	objects := app.scene.objects[:]
	members := objects[first:end]
	open := f.open
	parts := ui.Thumb_Row{glyph = ui.ICON_FOLDER, count = len(members), open = &open}
	toggles := [1]ui.Row_Toggle{{name = fmt.tprintf("Show %s", folder_label(f)) if f.off else fmt.tprintf("Hide %s", folder_label(f)), glyph = ui.ICON_EYE_OFF if f.off else ui.ICON_EYE, faint = f.off}}
	selected := false
	if sel := selected_object(app); sel != nil && !f.open do selected = sel.folder == f.id
	dragged := k.tree_drag.active && k.tree_drag.key == -f.id
	row := ui.thumb_row(ctx, fmt.tprintf("%s##card folder %d", folder_label(f), f.id), parts, selected, dim = dragged || f.off, all_toggles = toggles[:], drags = drags && len(members) > 0)
	spot := Tree_Spot{rect = row.rect, id = f.id, is_folder = true, folder = f.id, off = f.off, ghost = f.ghost}
	if len(members) > 0 do spot.first = members[0].id
	if end < len(objects) && len(members) > 0 do spot.next = objects[end].id
	append(spots, spot)
	kit_row_drags(app, row.dragged, -1, row.rect, -f.id, f.ghost, f.off)
	if row.dragged do k.folder_menu = false
	if row.folded do app.ui.scene_command = {kind = .View, view = .Folder_Fold, id = f.id}
	if !k.tree_column.active && row.toggled == 0 do app.ui.scene_command = {kind = .View, view = .Folder_Show if f.off else .Folder_Hide, id = f.id}
	if row.clicked && len(members) > 0 do app.ui.scene_command = {kind = .View, view = .Select, id = members[0].id}
	if row.menu do folder_menu_open(app, f.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0})
	rows^ += 1
}

// Whether the object's shown level carries polypaint.
@(private = "file")
object_has_paint :: proc(obj: ^Object) -> bool {
	return sculpt.sculptor_has_color(&sculpt.levels_current(&obj.levels).sculptor)
}

// The card's menus, drawn over everything with the other popovers: Add, More and a row's.
kit_objects_card_menus :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	c := &k.card
	if ui.popover_begin(ctx, "objects card add", &c.add, c.add_at, .Below, {direction = .Column, padding = 6, width = 248}) {
		places := [2]string{"Insert", "Append"}
		if picked := ui.tabs(ctx, "objects card add where", places[:], 1 if c.append else 0); picked >= 0 do c.append = picked == 1
		ui.caption(ctx, "  BELOW THE SELECTED OBJECT" if !c.append else "  AT THE END OF THE LIST")
		vertices := int(SPHERE_PRESETS[k.add_size].vertices)
		for shape in geom.Primitive {
			if ui.menu_item(ctx, fmt.tprintf("%v##objects card add", shape), glyph = ui.ICON_PLUS, trailing = true) {
				app.ui.scene_command = {kind = .Add, shape = shape, vertices = vertices, on = !c.append}
				c.add = false
			}
		}
		if ui.menu_item(ctx, "Voxel sphere##objects card add", glyph = ui.ICON_PLUS, trailing = true) {
			app.ui.scene_command = {kind = .Add, vertices = vertices, voxels = voxel_resolution_for(vertices), on = !c.append}
			c.add = false
		}
		// Each content pack's meshes, under its name.
		for pack in app.library.packs {
			if pack.meshes == 0 do continue
			ui.caption(ctx, fmt.tprintf("  %s", strings.to_upper(pack.name, context.temp_allocator)))
			for m, j in app.library.meshes {
				if m.gone || m.pack != pack.id do continue
				if ui.menu_item(ctx, fmt.tprintf("%s##objects card mesh %d", m.stem, j), glyph = ui.ICON_PLUS, trailing = true) {
					app.ui.scene_command = {kind = .Add, mesh = j + 1, on = !c.append}
					c.add = false
				}
			}
		}
		ui.divider(ctx, across = true)
		if command_menu_item(app, .Import_Mesh, trailing = true) do c.add = false
		ui.popover_end(ctx)
	}
	if ui.popover_begin(ctx, "objects card more", &c.more, c.more_at, .Below, {direction = .Column, padding = 6, width = 248}) {
		picked := false
		for id in ([?]Command_Id{.Rename_Object, .All_Lowest_Level, .All_Highest_Level, .Copy_Object, .Paste_Object, .Duplicate_Object, .Convert_To_Voxels, .Convert_To_Mesh}) {
			if command_menu_item(app, id, trailing = true) do picked = true
		}
		ui.divider(ctx, across = true)
		if command_menu_item(app, .Delete_Object, tone = .Danger, trailing = true) do picked = true
		if command_menu_item(app, .Delete_Other_Objects, tone = .Danger, trailing = true) do picked = true
		if command_menu_item(app, .Delete_All_Objects, tone = .Danger, trailing = true) do picked = true
		if picked do c.more = false
		ui.popover_end(ctx)
	}
	obj := object_by_id(app, c.menu_id)
	if obj == nil do c.menu = false
	if !ui.popover_begin(ctx, "objects card row menu", &c.menu, c.menu_at, .Pointer, {direction = .Column, padding = 6, width = 248}) do return
	defer ui.popover_end(ctx)
	picked := false
	if c.menu_all {
		for id in ([?]Command_Id{.Rename_Object, .Copy_Object, .Paste_Object, .Duplicate_Object, .Object_To_Top, .Object_To_Bottom, .New_Folder, .Ghost_Object}) {
			if command_menu_item(app, id, trailing = true) do picked = true
		}
		if ui.menu_item(ctx, "Boolean process", glyph = ui.ICON_CHEVRON_DOWN if c.booleans else ui.ICON_CHEVRON_RIGHT, trailing = true) do c.booleans = !c.booleans
	}
	// An object not selected offers only how it takes part in booleans.
	if obj != nil && (c.booleans || !c.menu_all) {
		for mode in Boolean_Mode {
			name := "Off" if mode == .None else fmt.tprint(mode)
			if ui.menu_item(ctx, fmt.tprintf("%s##boolean %v", name, mode), checked = obj.boolean == mode) {
				obj.boolean = mode
				picked = true
			}
		}
	}
	if c.menu_all {
		ui.divider(ctx, across = true)
		if command_menu_item(app, .Delete_Object, tone = .Danger, trailing = true) do picked = true
		if command_menu_item(app, .Delete_Other_Objects, tone = .Danger, trailing = true) do picked = true
	}
	if picked do c.menu = false
}
