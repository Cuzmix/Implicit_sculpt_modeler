package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// Lens's Scene card (round 2 of the mockups, screen scene2): the objects as rows with a
// picture of each, its name and triangles, its eye and its lock, as ZBrush's subtools
// and Nomad's scene list; a filter once there are more than ten; then the selected
// object's selection sets. A tap selects (Ctrl, Shift or Select several adds), a drag
// reorders or puts a row in a folder, a long press opens the object's menu. The
// Scene palette keeps its tree too (kit_scene_objects).

// How many objects the card lists before it offers a filter.
SCENE_FILTER_AFTER :: 10

// Lucide's lock and lock-open: the row's lock, shut while the object is locked.
ICON_LOCK :: rune(0xe10f)
ICON_LOCK_OPEN :: rune(0xe110)
// Lucide's bookmark, for a selection set's row.
ICON_BOOKMARK :: rune(0xe064)

// The card's content, as the stack draws it.
kit_lens_scene :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	objects := app.scene.objects[:]
	query := ""
	if len(objects) > SCENE_FILTER_AFTER {
		_ = ui.text_field(ctx, "Filter objects##scene", k.scene_filter[:], hint = "Filter objects")
		query = strings.to_lower(strings.trim_space(string(cstring(&k.scene_filter[0]))), context.temp_allocator)
	}
	k.scene_query = query != ""
	// A filtered list is not the scene's order, so its rows do not move.
	drags := query == ""
	k.scene_rows = 0
	spots := make([dynamic]Tree_Spot, 0, len(objects) + len(app.scene.folders), context.temp_allocator)
	for i := 0; i < len(objects); {
		obj := objects[i]
		f := folder_by_id(app, obj.folder)
		if f == nil {
			if scene_matches(obj, query) do lens_object_row(app, &spots, i, drags)
			i += 1
			continue
		}
		first, end := folder_span(app, f.id)
		// A folder shows while any object in it matches, open so they show.
		shown := query == ""
		for o in objects[first:end] do if scene_matches(o, query) do shown = true
		if shown {
			card_folder_row(app, &spots, f, first, end, &k.scene_rows, drags)
			if f.open || query != "" {
				for j in first ..< end do if scene_matches(objects[j], query) do lens_object_row(app, &spots, j, drags)
			}
		}
		i = end
	}
	if query == "" {
		for &f in app.scene.folders {
			if first, end := folder_span(app, f.id); end > first do continue
			card_folder_row(app, &spots, &f, 0, 0, &k.scene_rows)
		}
	}
	kit_tree_drags(app, spots[:], {k.inspector_body, &k.scroll, k.inspector_limit})
	switch {
	case len(objects) == 0:
		ui.paragraph(ctx, "The scene is empty. Add a shape from the Scene palette or open a scene from the menu.")
	case query != "" && k.scene_rows == 0:
		ui.paragraph(ctx, fmt.tprintf("No object's name has \"%s\" in it.", query))
	}
	lens_scene_sets(app)
}

// Whether object `obj`'s name has `query` (lower case) in it; everything matches "".
scene_matches :: proc(obj: ^Object, query: string) -> bool {
	if query == "" do return true
	return strings.contains(strings.to_lower(object_label(obj), context.temp_allocator), query)
}

// Object `i`'s row: its picture, name and triangles, its eye and its lock. Ctrl and a tap
// on the lock locks every other object instead, as ZBrush's Freeze others; a tap on a
// locked, hidden or ghosted object's row brings it back and selects it.
@(private = "file")
lens_object_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, i: int, drags: bool) {
	k := &app.kit
	ctx := &k.ctx
	objects := app.scene.objects[:]
	obj := objects[i]
	label := object_label(obj)
	parts := ui.Thumb_Row{glyph = ui.ICON_FRAME, count = -1, compact = true, detail = fmt.tprintf("%s tris", count_label(object_triangle_count(obj)))}
	if lo, hi, ok := thumb_for(app, obj); ok do parts.image, parts.lo, parts.hi = KIT_THUMBS_IMAGE, lo, hi
	toggles := [2]ui.Row_Toggle{
		{name = fmt.tprintf("Show %s", label) if obj.off else fmt.tprintf("Hide %s", label), glyph = ui.ICON_EYE_OFF if obj.off else ui.ICON_EYE, faint = obj.off},
		{name = fmt.tprintf("Unlock %s", label) if obj.locked else fmt.tprintf("Lock %s", label), glyph = ICON_LOCK if obj.locked else ICON_LOCK_OPEN, lit = obj.locked, faint = !obj.locked, keys = "Ctrl: lock the others"},
	}
	dragged := k.tree_drag.active && k.tree_drag.key == obj.id
	row := ui.thumb_row(ctx, fmt.tprintf("%s##lens scene %d", label, obj.id), parts, object_in_selection(app, obj), dim = dragged || !object_shown(app, obj), all_toggles = toggles[:], drags = drags)
	append(spots, Tree_Spot{rect = row.rect, id = obj.id, folder = obj.folder, next = objects[i + 1].id if i + 1 < len(objects) else 0, off = obj.off, ghost = obj.ghost})
	// Only the eye's column sweeps down the rows (the tree's column 1).
	kit_row_drags(app, row.dragged, 1 if row.held_toggle == 0 else -1, row.rect, obj.id, obj.ghost, obj.off)
	if !k.tree_column.active {
		switch row.toggled {
		case 0:
			app.ui.scene_command = {kind = .View, view = .Show if obj.off else .Hide, id = obj.id}
		case 1:
			view := View_Change.Unlock if obj.locked else .Lock
			if ctx.input.ctrl do view = .Lock_Others
			app.ui.scene_command = {kind = .View, view = view, id = obj.id}
		}
	}
	several := k.select_several || ctx.input.ctrl || ctx.input.shift
	if !object_pickable(app, obj) {
		if row.clicked || row.menu do app.ui.scene_command = {kind = .View, view = .Select, id = obj.id}
	} else if row.clicked && several {
		selection_toggle(app, i)
	} else if row.clicked {
		select_only(app, i)
	} else if row.menu {
		selection_make_primary(app, i)
	}
	if row.menu do object_menu_open(app, obj.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, .Pointer)
	k.scene_rows += 1
}

// The selected object's selection sets (stored masks), each with how much it masks: a
// tap restores it as the mask, a long press opens the Sets section, where the rest is.
@(private = "file")
lens_scene_sets :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	if obj == nil do return
	ui.caption(ctx, "SELECTION SETS")
	sets := sculpt.levels_sets(&obj.levels)
	for &set, i in sets {
		row := ui.list_row(ctx, fmt.tprintf("%s##lens set %d %d", sculpt.selection_set_name(&set), obj.id, set.id), set_percent(set.masked), glyph = ICON_BOOKMARK)
		if row.clicked {
			app.ui.set_selected = i
			set_restore(app, set.id, .Replace)
		}
		if row.menu {
			app.ui.set_selected = i
			tray_open(app, .Sets)
		}
	}
	_ = command_button(app, .Store_Selection_Set, glyph = ui.ICON_PLUS, width = ui.fill_width(ctx), variant = .Light)
}
