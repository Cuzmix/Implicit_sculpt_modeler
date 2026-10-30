package main

import "core:fmt"
import "core:strings"

import "../geom"
import "../poly"
import "../sculpt"
import "../ui"

// Lens's Scene card, the outliner (round 2's scene2 screen, then the panels round's
// Objects outliner): Find and Add at its head, a chip for each kind of thing the scene
// holds with how many, the objects as rows with a picture of each, its name and state
// (L4 for its level, HD), its kind and size with a dot for each space it shows in (a tap
// on them chooses the spaces), its eye, its lock and a ⋯ opening its menu,
// as ZBrush's subtools, Nomad's scene list and Blender's outliner; then the lights, folded
// under one row; then Group, Duplicate and Delete for the selection, and the selected
// object's selection sets. A tap selects (Ctrl, Shift or Select several adds), a drag
// reorders or puts a row in a folder, a long press opens the object's menu. The Scene
// palette keeps its tree too (kit_scene_objects).

// Lucide's lock and lock-open: the row's lock, shut while the object is locked.
ICON_LOCK :: rune(0xe10f)
ICON_LOCK_OPEN :: rune(0xe110)
// Lucide's bookmark, for a selection set's row.
ICON_BOOKMARK :: rune(0xe064)

// What the outliner's chips show: everything, or one kind of thing.
Scene_Kind :: enum u8 {
	All,
	Meshes,
	Voxels,
	Cages,
	Lights,
}

@(rodata)
SCENE_KIND_NAMES := [Scene_Kind]string{.All = "All", .Meshes = "Meshes", .Voxels = "Voxels", .Cages = "Cages", .Lights = "Lights"}

// The outliner's state between frames: the chip picked, the lights' row unfolded, the Add
// menu and its folded groups, and counts for the exit stats.
Outliner :: struct {
	kind:        Scene_Kind,
	lights_open: bool,
	add:         bool,
	add_at:      ui.Rect,
	starters:    bool, // the Add menu's starter shapes are unfolded
	cages:       bool, // and its cages
	adds:        int, // things added from the Add menu
	switches:    int, // lights switched on or off from their rows
	menus:       int, // object menus opened by a row's ⋯
	// The Show in menu a row's spaces dots open: for which object, under what.
	spaces:      bool,
	spaces_id:   int,
	spaces_at:   ui.Rect,
	space_changes: int, // spaces an object was left out of or put back in, for the exit stats
}

// The kind of thing object `obj` is, for the chips.
object_scene_kind :: proc(obj: ^Object) -> Scene_Kind {
	if obj.voxel != nil do return .Voxels
	if obj.cage != nil do return .Cages
	return .Meshes
}

// The card's content, as the stack draws it.
kit_lens_scene :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ol := &k.outliner
	objects := app.scene.objects[:]
	lights := int(app.scene.lights.count)
	// Find and Add, the field taking what Add leaves.
	add_w: f32 = 84
	ui.begin(ctx, "scene head", {direction = .Row, gap = 8, width = ui.fill_width(ctx), center = true})
	_ = ui.text_field(ctx, "Find an object##scene", k.scene_filter[:], width = ui.row_room(ctx) - add_w - 8, hint = "Find an object")
	if ui.button(ctx, "Add##scene add", .Bordered, width = add_w, glyph = ui.ICON_PLUS) {
		ol.add, ol.add_at = !ol.add, ctx.last_rect
	}
	ui.end(ctx)
	query := strings.to_lower(strings.trim_space(string(cstring(&k.scene_filter[0]))), context.temp_allocator)
	k.scene_query = query != ""
	scene_kind_chips(app, lights)
	kind := ol.kind
	// A filtered list is not the scene's order, so its rows do not move.
	drags := query == "" && kind == .All
	k.scene_rows = 0
	spots := make([dynamic]Tree_Spot, 0, len(objects) + len(app.scene.folders), context.temp_allocator)
	if kind != .Lights {
		for i := 0; i < len(objects); {
			obj := objects[i]
			f := folder_by_id(app, obj.folder)
			if f == nil {
				if scene_matches(obj, query, kind) do lens_object_row(app, &spots, i, drags)
				i += 1
				continue
			}
			first, end := folder_span(app, f.id)
			// A folder shows while any object in it matches, open so they show.
			filtered := query != "" || kind != .All
			shown := !filtered
			for o in objects[first:end] do if scene_matches(o, query, kind) do shown = true
			if shown {
				card_folder_row(app, &spots, f, first, end, &k.scene_rows, drags)
				if f.open || filtered {
					for j in first ..< end do if scene_matches(objects[j], query, kind) do lens_object_row(app, &spots, j, drags)
				}
			}
			i = end
		}
		if query == "" && kind == .All {
			for &f in app.scene.folders {
				if first, end := folder_span(app, f.id); end > first do continue
				card_folder_row(app, &spots, &f, 0, 0, &k.scene_rows)
			}
		}
		kit_tree_drags(app, spots[:], {k.inspector_body, &k.scroll, k.inspector_limit})
	}
	if kind == .All || kind == .Lights do scene_light_rows(app, query, kind == .Lights)
	switch {
	case len(objects) == 0 && kind != .Lights:
		ui.paragraph(ctx, "The scene is empty. Add a shape with Add, or open a scene from the menu.")
	case query != "" && k.scene_rows == 0:
		ui.paragraph(ctx, fmt.tprintf("Nothing's name has \"%s\" in it.", query))
	}
	scene_foot(app)
	lens_scene_sets(app)
}

// The chips, one per kind the scene holds with how many, only once its objects are of two
// kinds or more (the lights, always there, alone do not bring them); a chip whose kind
// has gone gives way to All.
@(private = "file")
scene_kind_chips :: proc(app: ^App, lights: int) {
	k := &app.kit
	ctx := &k.ctx
	ol := &k.outliner
	counts: [Scene_Kind]int
	for obj in app.scene.objects do counts[object_scene_kind(obj)] += 1
	kinds := 0
	for c in counts do if c > 0 do kinds += 1
	counts[.Lights] = lights
	if counts[ol.kind] == 0 && ol.kind != .All do ol.kind = .All
	if kinds < 2 {
		ol.kind = .All
		return
	}
	counts[.All] = len(app.scene.objects) + lights
	width := ui.fill_width(ctx)
	ui.begin(ctx, "scene kinds", {direction = .Column, gap = 0, width = width})
	defer ui.end(ctx)
	row := 0
	ui.begin(ctx, "scene kinds 0", {direction = .Row, gap = 6, width = width})
	for c, kind in counts {
		if c == 0 do continue
		name, sub := SCENE_KIND_NAMES[kind], fmt.tprint(c)
		if ui.row_room(ctx) < lens_chip_width(ctx, name, sub) {
			ui.end(ctx)
			row += 1
			ui.begin(ctx, fmt.tprintf("scene kinds %d", row), {direction = .Row, gap = 6, width = width})
		}
		if lens_chip(ctx, fmt.tprintf("Show %s##scene kind", strings.to_lower(name, context.temp_allocator)), name, sub, lit = ol.kind == kind).clicked {
			ol.kind = kind
			if kind == .Lights do ol.lights_open = true
		}
	}
	ui.end(ctx)
}

// Whether object `obj` is of `kind` and its name has `query` (lower case) in it;
// everything matches "" and All.
scene_matches :: proc(obj: ^Object, query: string, kind := Scene_Kind.All) -> bool {
	if kind != .All && object_scene_kind(obj) != kind do return false
	if query == "" do return true
	return strings.contains(strings.to_lower(object_label(obj), context.temp_allocator), query)
}

// What a row says under object `obj`'s name: its size, and its kind when it is not a mesh.
object_row_detail :: proc(obj: ^Object) -> string {
	switch {
	case obj.voxel != nil:
		return fmt.tprintf("Voxels · %d³", obj.voxel.resolution)
	case obj.cage != nil:
		return fmt.tprintf("Cage · %d faces", poly.face_count(&obj.cage.mesh))
	}
	// A mesh, the usual kind, says only its triangles' count: the row is narrow beside the
	// spaces dots and three toggles, and the object menu's head spells it out.
	return count_label(object_triangle_count(obj))
}

// The tags after object `obj`'s name: the level shown when it has levels, and HD while a
// window is open.
object_row_badges :: proc(obj: ^Object) -> []string {
	tags := make([dynamic]string, 0, 2, context.temp_allocator)
	if obj.voxel == nil && obj.cage == nil && len(obj.levels.levels) > 1 do append(&tags, fmt.tprintf("L%d", obj.levels.current + 1))
	if object_in_hd(obj) do append(&tags, "HD")
	return tags[:]
}

// The rect of toggle `i` of `n` at the right end of a thumbnail row in `row`, as
// ui.thumb_row lays them out, for a menu opened from one.
row_toggle_rect :: proc(ctx: ^ui.Context, row: ui.Rect, i, n: int) -> ui.Rect {
	t := ctx.theme
	first := row.x + row.w - 4 - f32(n) * t.target
	return {first + f32(i) * t.target, row.y + row.h * 0.5 - t.target * 0.5, t.target, t.target}
}

// Object `i`'s row: its picture, name, tags and what it is, its eye, its lock and its ⋯.
// Ctrl and a tap on the lock locks every other object instead, as ZBrush's Freeze others;
// a tap on a locked, hidden or ghosted object's row brings it back and selects it.
@(private = "file")
lens_object_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, i: int, drags: bool) {
	k := &app.kit
	ctx := &k.ctx
	objects := app.scene.objects[:]
	obj := objects[i]
	label := object_label(obj)
	parts := ui.Thumb_Row{glyph = ui.ICON_FRAME, count = -1, compact = true, detail = object_row_detail(obj), badges = object_row_badges(obj)}
	if lo, hi, ok := thumb_for(app, obj); ok do parts.image, parts.lo, parts.hi = KIT_THUMBS_IMAGE, lo, hi
	// A dot per space in the space's colour, faint where the object is left out.
	dots: [len(Space)]ui.Color
	for s in Space do dots[int(s)] = ui.color_fade(ctx.theme.text_secondary, 0.3) if s in obj.spaces_off else ctx.theme.tints[int(s)]
	parts.dots, parts.dots_name = dots[:], "Spaces it shows in"
	toggles := [3]ui.Row_Toggle{
		{name = fmt.tprintf("Show %s", label) if obj.off else fmt.tprintf("Hide %s", label), glyph = ui.ICON_EYE_OFF if obj.off else ui.ICON_EYE, faint = obj.off},
		{name = fmt.tprintf("Unlock %s", label) if obj.locked else fmt.tprintf("Lock %s", label), glyph = ICON_LOCK if obj.locked else ICON_LOCK_OPEN, lit = obj.locked, faint = !obj.locked, keys = "Ctrl: lock the others"},
		{name = fmt.tprintf("%s's menu", label), glyph = ui.ICON_MORE},
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
		case 2:
			// The same menu as a long press, under the dots; the object becomes the primary
			// so the menu acts on it, keeping the rest of the selection.
			if object_pickable(app, obj) do selection_make_primary(app, i)
			object_menu_open(app, obj.id, row_toggle_rect(ctx, row.rect, 2, len(toggles)), .Below, .List)
			k.outliner.menus += 1
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
	if row.menu do object_menu_open(app, obj.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, .Pointer, .List)
	if row.dotted do k.outliner.spaces, k.outliner.spaces_id, k.outliner.spaces_at = true, obj.id, row.rect
	k.scene_rows += 1
}

// The lights, after the objects: one row holding how many there are, folded at first as
// a rig of studio lights seldom needs a look, then a row per light: its kind, name and
// colour, and its eye switching it on or off (an undo step); a tap picks it and opens the
// Lights section on it, where the rest of it is set. `only` is the Lights chip, which
// shows them unfolded with nothing else.
@(private = "file")
scene_light_rows :: proc(app: ^App, query: string, only: bool) {
	k := &app.kit
	ctx := &k.ctx
	ol := &k.outliner
	set := &app.scene.lights
	if set.count <= 0 do return
	matched := 0
	for i in 0 ..< int(set.count) do if query == "" || strings.contains(strings.to_lower(light_name(set, i), context.temp_allocator), query) do matched += 1
	if matched == 0 do return
	if !only {
		open := ol.lights_open || query != ""
		was := open
		parts := ui.Thumb_Row{glyph = ui.ICON_SUN, count = -1, compact = true, open = &open, detail = fmt.tprintf("%d on", lights_on_count(set))}
		row := ui.thumb_row(ctx, fmt.tprintf("Lights · %d##scene lights", set.count), parts)
		if row.clicked do open = !open
		if open != was && query == "" do ol.lights_open = open
		k.scene_rows += 1
		if !open do return
	}
	for &l, i in set.lights[:set.count] {
		name := light_name(set, i)
		if query != "" && !strings.contains(strings.to_lower(name, context.temp_allocator), query) do continue
		parts := ui.Thumb_Row{glyph = LIGHT_KIND_ICONS[l.kind], count = -1, compact = true, detail = light_row_detail(&l)}
		toggles := [1]ui.Row_Toggle{{name = fmt.tprintf("Switch %s %s", name, "off" if l.on else "on"), glyph = ui.ICON_EYE if l.on else ui.ICON_EYE_OFF, faint = !l.on}}
		// Never outlined: the outline is the objects' selection, which a light is not part of.
		row := ui.thumb_row(ctx, fmt.tprintf("%s##scene light %d", name, i), parts, dim = !l.on, all_toggles = toggles[:])
		if row.toggled == 0 {
			light_drag_changed(app, set^, "Switch light on" if !l.on else "Switch light off")
			l.on = !l.on
			ol.switches += 1
		}
		if row.clicked || row.menu {
			app.light_pick = i
			tray_open(app, .Lights)
		}
		k.scene_rows += 1
	}
}

// How many of the set's lights are on.
@(private = "file")
lights_on_count :: proc(set: ^Light_Set) -> (on: int) {
	for l in set.lights[:set.count] do if l.on do on += 1
	return
}

// What a light's row says under its name: its kind, its colour temperature when it has
// one, and what it keeps its place in.
@(private = "file")
light_row_detail :: proc(l: ^Light) -> string {
	warmth := fmt.tprintf(" · %.0f K", l.kelvin) if l.kelvin > 0 else ""
	return fmt.tprintf("%s%s · %s", LIGHT_KIND_LABELS[l.kind], warmth, "in the scene" if l.space == .Scene else "with the camera")
}

// Group, Duplicate and Delete, each acting on every selected object.
@(private = "file")
scene_foot :: proc(app: ^App) {
	ctx := &app.kit.ctx
	if len(app.scene.objects) == 0 do return
	width := ui.fill_width(ctx)
	each := (width - 2 * 6) / 3
	ui.begin(ctx, "scene foot", {direction = .Row, gap = 6, width = width})
	_ = command_button(app, .New_Folder, label = "Group", glyph = ui.ICON_FOLDER_PLUS, width = each, variant = .Light)
	_ = command_button(app, .Duplicate_Object, width = each, variant = .Light)
	_ = command_button(app, .Delete_Object, width = each, variant = .Light, tone = .Danger)
	ui.end(ctx)
}

// The Add menu, over every panel: the mesh shapes at the Add object section's size, the
// starters folded under one row, a voxel sphere, the cages folded under one row, and a
// light of each kind; each added at once as one undo step, selected.
kit_scene_add_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ol := &k.outliner
	if !ol.add do return
	if !ui.popover_begin(ctx, "scene add menu", &ol.add, ol.add_at, .Below, {direction = .Column, gap = 0, padding = 6, width = 260}) do return
	defer ui.popover_end(ctx)
	picked := false
	vertices := int(SPHERE_PRESETS[k.add_size].vertices)
	ui.label(ctx, fmt.tprintf("MESH · %s VERTICES", count_label(vertices)), t.caption_size, t.text_tertiary, .Semibold)
	for shape in geom.Primitive {
		if geom.is_starter(shape) do continue
		if ui.menu_item(ctx, fmt.tprintf("%v##scene add", shape), glyph = ui.ICON_SHAPES) {
			app.ui.scene_command = {kind = .Add, vertices = vertices, shape = shape}
			picked = true
		}
	}
	if ui.menu_item(ctx, "Starters##scene add", glyph = ui.ICON_CHEVRON_DOWN if ol.starters else ui.ICON_CHEVRON_RIGHT, trailing = true) do ol.starters = !ol.starters
	if ol.starters {
		for shape in geom.Primitive {
			if !geom.is_starter(shape) do continue
			if ui.menu_item(ctx, fmt.tprintf("%v##scene add", shape), glyph = ui.ICON_SHAPES) {
				app.ui.scene_command = {kind = .Add, vertices = vertices, shape = shape}
				picked = true
			}
		}
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Voxel sphere##scene add", glyph = ui.ICON_SHAPES, hint = fmt.tprintf("Clay %d voxels across, sculpted as a volume", voxel_resolution_for(vertices))) {
		app.ui.scene_command = {kind = .Add, vertices = vertices, shape = .Sphere, voxels = voxel_resolution_for(vertices)}
		picked = true
	}
	if ui.menu_item(ctx, "Cage##scene add", glyph = ui.ICON_CHEVRON_DOWN if ol.cages else ui.ICON_CHEVRON_RIGHT, trailing = true) do ol.cages = !ol.cages
	if ol.cages {
		for p in poly.Primitive {
			if ui.menu_item(ctx, fmt.tprintf("%s cage##scene add", poly.PRIMITIVE_NAMES[p]), glyph = ui.ICON_GRID, hint = command_hint(app, .Add_Cage, int(p))) {
				_ = command_run(app, .Add_Cage, int(p))
				picked = true
			}
		}
	}
	ui.divider(ctx, across = true)
	for kind in Light_Kind {
		if ui.menu_item(ctx, fmt.tprintf("%s light##scene add", LIGHT_KIND_LABELS[kind]), glyph = LIGHT_KIND_ICONS[kind], enabled = app.scene.lights.count < LIGHT_COUNT) {
			before := app.scene.lights
			if light_add(app, kind) >= 0 do light_drag_changed(app, before, "Add light")
			ol.lights_open = true
			picked = true
		}
	}
	if picked {
		ol.add = false
		ol.adds += 1
	}
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

// The Show in menu, over every panel: a check for each space, which leaves the object out
// of that space or puts it back. Left out of the current space, it leaves view and reach
// at once, as its eye would; the menu stays open, so all three can be set in one visit.
kit_scene_spaces_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ol := &k.outliner
	if !ol.spaces do return
	obj := object_by_id(app, ol.spaces_id)
	if obj == nil {
		ol.spaces = false
		return
	}
	if !ui.popover_begin(ctx, "scene spaces menu", &ol.spaces, ol.spaces_at, .Below, {direction = .Column, gap = 0, padding = 6, width = 260}) do return
	defer ui.popover_end(ctx)
	ui.label(ctx, fmt.tprintf("SHOW %s IN", strings.to_upper(object_label(obj), context.temp_allocator)), t.caption_size, t.text_tertiary, .Semibold)
	for s in Space {
		on := s not_in obj.spaces_off
		if ui.menu_item(ctx, fmt.tprintf("%s##scene spaces", SPACE_NAMES[s]), glyph = SPACE_ICONS[s], checked = on) {
			app.ui.scene_command = {kind = .View, view = .Space_Hide if on else .Space_Show, id = obj.id, space = s}
			ol.space_changes += 1
		}
	}
	ui.paragraph(ctx, "Left out of a space, it is out of view and reach while that space is current, and back when you return to another.")
}
