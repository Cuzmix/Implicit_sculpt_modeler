package main

import "core:fmt"
import "core:strings"

import "../camera"
import "../geom"
import "../ui"

// The inspector's Scene tab: the objects, adding one, and how the whole scene is shown.
kit_scene_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	total := 0
	for obj in app.scene.objects do total += object_vertex_count(obj)
	ui.caption(ctx, fmt.tprintf("OBJECTS  %d  ·  %s VERTICES", len(app.scene.objects), count_label(total)))
	k.tree_rows = 0
	base := boolean_base(app)
	// The list's order is the tree's: a folder's objects are next to each other, so one
	// walk draws each folder's row before its objects.
	objects := app.scene.objects[:]
	for i := 0; i < len(objects); {
		obj := objects[i]
		f := folder_by_id(app, obj.folder)
		if f == nil {
			kit_object_row(app, obj, i, base, 0)
			i += 1
			continue
		}
		first, end := folder_span(app, f.id)
		kit_folder_row(app, f, objects[first:end])
		if f.open do for j in first ..< end do kit_object_row(app, objects[j], j, base, 1)
		i = end
	}
	// Folders with nothing in them yet come last.
	for &f in app.scene.folders {
		if first, end := folder_span(app, f.id); end > first do continue
		kit_folder_row(app, &f, nil)
	}
	off, ghosts := scene_view_counts(app)
	if off > 0 || app.scene.solo {
		_ = command_button(app, .Show_All_Objects, width = ui.fill_width(ctx), glyph = ui.ICON_EYE)
	}
	if app.scene.solo {
		ui.paragraph(ctx, fmt.tprintf("Solo shows only the selected object. %s turns it off.", command_keys(app, .Solo_Object)))
	} else if ghosts > 0 {
		ui.paragraph(ctx, "Ghosts are dimmed and let presses through; their ghost icon makes them solid.")
	}
	if len(app.scene.objects) == 0 do ui.paragraph(ctx, "The scene is empty. Add a shape below or open a scene from the menu.")
	half := (ui.fill_width(ctx) - 8) * 0.5
	ui.begin(ctx, "object actions", {direction = .Row, gap = 8})
	_ = command_button(app, .Duplicate_Object, width = half, glyph = ui.ICON_COPY)
	_ = command_button(app, .Delete_Object, tone = .Danger, width = half, glyph = ui.ICON_TRASH)
	ui.end(ctx)
	ui.spacer(ctx, 4)

	for sec in SCENE_SECTIONS {
		if ui.section(ctx, sec.title, &k.open[sec.section]) {
			sec.draw(app)
			ui.section_end(ctx)
		}
	}
	// Opening a scene counts building it as reading; importing parses apart.
	if s := app.stats; s.file_read_ms > 0 || s.file_write_ms > 0 {
		parts := make([dynamic]string, context.temp_allocator)
		if s.file_read_ms > 0 do append(&parts, fmt.tprintf("read in %.0f ms", s.file_read_ms))
		if s.file_parse_ms > 0 do append(&parts, fmt.tprintf("parsed in %.0f ms", s.file_parse_ms))
		if s.file_write_ms > 0 do append(&parts, fmt.tprintf("written in %.0f ms", s.file_write_ms))
		ui.paragraph(ctx, fmt.tprintf("Last file %s.", strings.join(parts[:], ", ", context.temp_allocator)))
	}
}

// An object's row in the Scene tab, under its folder's when `depth` is 1.
@(private = "file")
kit_object_row :: proc(app: ^App, obj: ^Object, i: int, base: ^Object, depth: int) {
	ctx := &app.kit.ctx
	detail := count_label(object_vertex_count(obj))
	if n := len(obj.levels.levels); n > 1 do detail = fmt.tprintf("%s, level %d/%d", detail, obj.levels.current + 1, n)
	if object_dynamic(obj) do detail = fmt.tprintf("%s, dynamic", detail)
	// The boolean's base is the first object not marked, so the list's order decides it.
	if obj == base do detail = fmt.tprintf("base, %s", detail)
	toggles := row_toggles(object_label(obj), obj.off, obj.ghost)
	row := ui.tree_row(ctx, fmt.tprintf("%s##%d", object_label(obj), obj.id), detail, i == app.scene.selected, depth, all_toggles = toggles[:], glyph = ui.ICON_FRAME, dim = !object_shown(app, obj))
	switch row.toggled {
	case 0: app.ui.scene_command = {kind = .View, view = .Unghost if obj.ghost else .Ghost, id = obj.id}
	case 1: app.ui.scene_command = {kind = .View, view = .Show if obj.off else .Hide, id = obj.id}
	}
	// Picking an object out of view or reach brings it back, as ZBrush's SubTool list does.
	if row.clicked || row.menu {
		if object_pickable(app, obj) do app.scene.selected = i
		else do app.ui.scene_command = {kind = .View, view = .Select, id = obj.id}
	}
	if row.menu do object_menu_open(app, obj.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, .Pointer)
	app.kit.tree_rows += 1
}

// A folder's row: its chevron folds it, its eye and ghost apply to everything in it, a
// tap selects its first object and a long press or right-click opens its menu.
@(private = "file")
kit_folder_row :: proc(app: ^App, f: ^Folder, members: []^Object) {
	k := &app.kit
	ctx := &k.ctx
	vertices := 0
	for obj in members do vertices += object_vertex_count(obj)
	detail := "empty" if len(members) == 0 else fmt.tprintf("%d · %s", len(members), count_label(vertices))
	selected := false
	if sel := selected_object(app); sel != nil && !f.open do selected = sel.folder == f.id
	toggles := row_toggles(folder_label(f), f.off, f.ghost)
	// The panel only reads the folder: folding it is a view command like its eye.
	open := f.open
	row := ui.tree_row(ctx, fmt.tprintf("%s##folder %d", folder_label(f), f.id), detail, selected, open = &open, all_toggles = toggles[:], glyph = ui.ICON_FOLDER, dim = f.off)
	if row.folded do app.ui.scene_command = {kind = .View, view = .Folder_Fold, id = f.id}
	switch row.toggled {
	case 0: app.ui.scene_command = {kind = .View, view = .Folder_Unghost if f.ghost else .Folder_Ghost, id = f.id}
	case 1: app.ui.scene_command = {kind = .View, view = .Folder_Show if f.off else .Folder_Hide, id = f.id}
	}
	if row.clicked && len(members) > 0 {
		app.ui.scene_command = {kind = .View, view = .Select, id = members[0].id}
	}
	if row.menu do folder_menu_open(app, f.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0})
	k.tree_rows += 1
}

// The Scene tab's sections in the order shown, under the objects.
@(rodata)
SCENE_SECTIONS := [?]Kit_Tab_Section {
	{.Add, "Add object", kit_add, nil},
	{.Material, "Material", kit_material, nil},
	{.Studio, "Studio render", kit_studio, nil},
	{.Camera, "Camera", kit_camera, nil},
}

@(private = "file")
kit_add :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	shapes: [len(geom.Primitive)]string
	for s, i in geom.Primitive do shapes[i] = fmt.tprint(s)
	if picked := ui.select(ctx, "add shape", shapes[:], int(k.add_shape)); picked >= 0 do k.add_shape = geom.Primitive(picked)
	if picked := ui.select(ctx, "add size", kit_size_names(), k.add_size); picked >= 0 do k.add_size = picked
	vertices := int(SPHERE_PRESETS[k.add_size].vertices)
	_ = command_button(app, .Add_Object, label = fmt.tprintf("Add %v", k.add_shape), variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS)
	// Geodesic spheres come in steps of 10f² + 2 vertices; say what will be built.
	f := geom.geodesic_frequency_for(vertices)
	built := 10 * f * f + 2 if k.add_shape == .Sphere else vertices
	// A starter comes with subdivision levels, the ones below holding about a third more.
	levels := starter_levels(vertices) if geom.is_starter(k.add_shape) else 0
	memory := built + built / 3 if levels > 0 else built
	on := fmt.tprintf(" on %d subdivision levels", levels + 1) if levels > 0 else ""
	ui.paragraph(ctx, fmt.tprintf("Builds %s%s vertices%s, about %s of memory.", "" if k.add_shape == .Sphere else "about ", count_label(built), on, bytes_label(memory * BYTES_PER_VERTEX)))
}

// The classic presets, the physically based ones, and sliders that edit whichever is in
// use into the Custom material.
@(private = "file")
kit_material :: proc(app: ^App) {
	ctx := &app.kit.ctx
	names: [len(MATERIALS) + 1]string
	for m, i in MATERIALS do names[i] = string(m.label) if i < FIRST_PBR else fmt.tprintf("%s (physically based)", m.label)
	names[CUSTOM_MATERIAL] = "Custom"
	if picked := ui.select(ctx, "material", names[:], app.material); picked >= 0 do app.material = picked
	// The sliders show the material in use; moving one copies it into Custom first, so a
	// preset is never changed. A classic preset has no roughness yet, so it starts rough.
	m := current_material(app)
	if m.roughness == 0 do m.roughness = CUSTOM_ROUGHNESS
	changed := kit_color(ctx, "material colour", (^[3]f32)(&m.selected))
	if kit_more(app, .Material) {
		changed |= ui.slider(ctx, "Metallic", &m.metallic, 0, 1, .Linear, fmt.tprintf("%.2f", m.metallic))
		changed |= ui.slider(ctx, "Roughness", &m.roughness, 0.04, 1, .Linear, fmt.tprintf("%.2f", m.roughness))
		kit_more_end(app)
	}
	if changed {
		m.label = "Custom"
		app.custom = m
		app.material = CUSTOM_MATERIAL
	}
	ui.paragraph(ctx, "Moving a slider makes a Custom material from the one in use; the presets stay as they are.")
}

@(private = "file")
kit_studio :: proc(app: ^App) {
	ctx := &app.kit.ctx
	on := app.studio_on
	if ui.switch_row(ctx, "Studio render", &on, keys = command_hint(app, .Studio_Render)) do command_run(app, .Studio_Render)
	_ = ui.slider(ctx, "Occlusion", &app.studio_ao, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_ao))
	_ = ui.slider(ctx, "Shadow", &app.studio_shadow, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_shadow))
	samples := f32(app.studio_samples)
	if ui.slider(ctx, "Samples", &samples, 16, STUDIO_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.studio_samples)) do app.studio_samples = i32(samples + 0.5)
	if app.studio_on && app.studio.samples > 0 && app.studio.samples < int(app.studio_samples) {
		ui.paragraph(ctx, fmt.tprintf("Built up %d of %d samples.", app.studio.samples, app.studio_samples))
	}
	ui.paragraph(ctx, fmt.tprintf("Ambient occlusion and soft shadows build up while the view stays still; any change starts them over. %s", command_keys(app, .Studio_Render)))
}

@(private = "file")
kit_camera :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.paragraph(ctx, "Orbit: right drag, or Alt + left drag. Pan: middle drag, or Shift + right drag. Zoom: the wheel. On a touch screen two fingers pan and pinch.")
	_ = ui.switch_row(ctx, "Orthographic", &app.camera.ortho, keys = command_hint(app, .Ortho_Toggle))
	// Two rows of three, each view beside its opposite's row: the keypad's 1, 3 and 7,
	// and with Ctrl the other side.
	views := [2][3]camera.Axis_View{{.Front, .Right, .Top}, {.Back, .Left, .Bottom}}
	for row, r in views {
		names, hints: [3]string
		for v, i in row do names[i], hints[i] = fmt.tprint(v), command_hint(app, .View_Axis, int(v))
		if picked := ui.tabs(ctx, fmt.tprintf("look from %d", r), names[:], -1, keys = hints[:]); picked >= 0 do command_run(app, .View_Axis, int(row[picked]))
	}
	kit_command_pair(app, .Reset_Camera, .Focus_Selected)
	if kit_more(app, .Camera) {
		_ = ui.slider(ctx, "Distance", &app.camera.distance, camera.MIN_DISTANCE, 20, .Logarithmic, fmt.tprintf("%.2f", app.camera.distance))
		kit_more_end(app)
	}
}
