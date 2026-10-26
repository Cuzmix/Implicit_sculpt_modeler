package main

import "core:fmt"
import "core:math"

import "../sculpt"
import "../ui"

// The Object tab's pages, by the question an artist asks of the selected object (UX
// research 08 section 3): what shape and topology it has, which part is being worked on,
// what is on its surface, and what is made from it. Each holds at most six sections, so
// the tab is never one long scroll of eighteen.
Object_Page :: enum u8 {
	Shape,
	Select,
	Surface,
	Build,
}

OBJECT_PAGE_NAMES := [Object_Page]string {
	.Shape   = "Shape",
	.Select  = "Select",
	.Surface = "Surface",
	.Build   = "Build",
}

// The inspector's Object tab: the selected object, and on the page picked under its name
// everything that changes it as a whole. Each section folds; the common ones start open.
kit_object_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	obj := selected_object(app)
	if obj == nil {
		ui.spacer(ctx, 12)
		ui.label(ctx, "No object selected", t.title_size, t.text, .Semibold)
		ui.paragraph(ctx, "Click an object in the viewport with Move, or pick one in the Scene tab.")
		return
	}
	ui.label(ctx, object_label(obj), t.heading_size, t.text, .Semibold)
	ui.paragraph(ctx, fmt.tprintf("%s vertices, %s triangles", count_label(object_vertex_count(obj)), count_label(object_triangle_count(obj))))
	names: [len(Object_Page)]string
	for page in Object_Page do names[int(page)] = OBJECT_PAGE_NAMES[page]
	if picked := ui.tabs(ctx, "object pages", names[:], int(k.object_page)); picked >= 0 && Object_Page(picked) != k.object_page {
		// A new page starts from the top and fades in, as a new tab does.
		k.object_page, k.scroll = Object_Page(picked), 0
		k.tab_serial += 1
	}
	ui.spacer(ctx, 4)
	for sec in OBJECT_SECTIONS {
		if sec.page != k.object_page do continue
		if ui.section(ctx, sec.title, &k.open[sec.section]) {
			sec.draw(app, obj)
			ui.section_end(ctx)
		}
	}
}

// One section of the Object tab: the page it is on, its fold state, its title and what
// it draws.
Object_Section :: struct {
	page:    Object_Page,
	section: Kit_Section,
	title:   string,
	draw:    proc(app: ^App, obj: ^Object),
}

// Every Object tab section, page by page in the order shown; each is on one page only
// (object_sections_each_on_one_page).
@(rodata)
OBJECT_SECTIONS := [?]Object_Section {
	{.Shape, .Transform, "Transform", kit_transform},
	{.Shape, .Levels, "Subdivision levels", kit_levels},
	{.Shape, .Hd, "HD detail", kit_hd},
	{.Shape, .Topology, "Dynamic topology", kit_dyntopo},
	{.Shape, .Remesh, "Remesh and decimate", proc(app: ^App, _: ^Object) {kit_remesh(app)}},
	{.Shape, .Mirror, "Mirror and weld", proc(app: ^App, _: ^Object) {kit_mirror(app)}},
	{.Select, .Mask, "Mask", proc(app: ^App, _: ^Object) {kit_mask(app)}},
	{.Select, .Groups, "Polygroups", proc(app: ^App, _: ^Object) {kit_groups(app)}},
	{.Select, .Visibility, "Hide, clip and slice", kit_visibility},
	{.Surface, .Layers, "Layers", proc(app: ^App, _: ^Object) {kit_layers_section(app)}},
	{.Surface, .Paint, "Polypaint", proc(app: ^App, _: ^Object) {kit_paint(app)}},
	{.Surface, .Morph, "Morph target", kit_morph},
	{.Surface, .Deform, "Deformation", kit_deformation},
	{.Build, .Retopo, "Retopology and baking", proc(app: ^App, _: ^Object) {kit_retopo_section(app)}},
	{.Build, .Project, "Project detail", proc(app: ^App, _: ^Object) {kit_project_section(app)}},
	{.Build, .Booleans, "Booleans", proc(app: ^App, _: ^Object) {kit_boolean_section(app)}},
	{.Build, .Extract, "Extract", proc(app: ^App, _: ^Object) {kit_extract_section(app)}},
}

// Where the object is, how it is turned and how big it is: values to drag.
@(private = "file")
kit_transform :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	tr := &obj.transform
	axes := [3]string{"X", "Y", "Z"}
	for axis, i in axes {
		_ = ui.drag_value(ctx, fmt.tprintf("Position %s", axis), &tr.position[i], 0.005, -1e4, 1e4, fmt.tprintf("%.3f", tr.position[i]))
	}
	for axis, i in axes {
		if ui.drag_value(ctx, fmt.tprintf("Turn about %s", axis), &tr.rotation[i], 0.5, -1e6, 1e6, fmt.tprintf("%.1f°", tr.rotation[i])) {
			tr.rotation[i] = math.mod(tr.rotation[i] + 540, 360) - 180
		}
	}
	_ = ui.drag_value(ctx, "Scale", &tr.scale, 0.005, 0.01, 100, fmt.tprintf("%.3f", tr.scale))
	ui.paragraph(ctx, "Drag sideways on a value to change it. Turns are degrees about X, then Y, then Z.")
}

// Subdivision levels, numbered from 1 as in ZBrush.
@(private = "file")
kit_levels :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	levels := &obj.levels
	count := len(levels.levels)
	dyntopo := object_dynamic(obj)
	ui.label(ctx, fmt.tprintf("Level %d of %d", levels.current + 1, count), t.text_size, t.text, .Semibold)
	kit_command_pair(app, .Level_Down, .Level_Up, label_a = "Lower##level", label_b = "Higher##level", enabled_a = levels.current > 0, enabled_b = levels.current < count - 1)
	vertices, _, bytes := sculpt.levels_subdivide_estimate(levels)
	can := command_enabled(app, .Subdivide)
	_ = command_button(app, .Subdivide, variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS)
	switch {
	case dyntopo:
		ui.paragraph(ctx, "Turn dynamic topology off to subdivide.")
	case levels.hd.steps > 0:
		ui.paragraph(ctx, "Delete the HD level to subdivide.")
	case can:
		ui.paragraph(ctx, fmt.tprintf("Adds a level of %s vertices, about %s. %s", count_label(vertices), bytes_label(bytes), command_keys(.Subdivide)))
	}
	kit_command_pair(app, .Delete_Lower_Levels, .Delete_Higher_Levels, label_a = "Delete lower", label_b = "Delete higher", tone_a = .Danger, tone_b = .Danger)
	ui.paragraph(ctx, fmt.tprintf("%s and %s go up and down. All levels use %s of memory; %s undoes a deletion.", command_keys(.Level_Up), command_keys(.Level_Down), bytes_label(sculpt.levels_bytes(levels)), command_keys(.Undo)))
	if s := app.stats; s.level_sync_ms + s.level_show_ms > 0 {
		ui.paragraph(ctx, fmt.tprintf("Last change: %.0f ms to update the levels, %.0f ms to show.", s.level_sync_ms, s.level_show_ms))
	}
}

// HD detail above the top level, sculpted a window at a time, as in ZBrush.
@(private = "file")
kit_hd :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	levels := &obj.levels
	hd := sculpt.levels_hd_stats(levels)
	steps := levels.hd.steps
	kit_command_pair(app, .Hd_Divide, .Hd_Delete, tone_b = .Danger)
	if steps == 0 {
		ui.paragraph(ctx, "Sculpt finer than the top level, a window of it at a time.")
		return
	}
	ui.paragraph(ctx, fmt.tprintf("%d step%s up: %s vertices.", steps, "" if steps == 1 else "s", count_label(sculpt.levels_hd_vertices(levels))))
	if object_in_hd(obj) {
		_ = command_button(app, .Hd_Leave, tone = .Accent)
		ui.paragraph(ctx, fmt.tprintf("A window of %s vertices, opened in %.0f + %.0f ms. %s leaves it too.", count_label(hd.window_vertices), app.stats.hd_open_ms, app.stats.hd_upload_ms, command_keys(.Hd_Toggle)))
	} else {
		// From the button, the window opens around the middle of the viewport.
		_ = command_button(app, .Hd_Sculpt, variant = .Solid, tone = .Accent)
		ui.paragraph(ctx, fmt.tprintf("%s opens a window where the pointer is.", command_keys(.Hd_Toggle)))
	}
	millions := f32(app.hd_window_vertices / 1_000_000)
	if ui.slider(ctx, "Window", &millions, 1, 16, .Linear, fmt.tprintf("%dM vertices", app.hd_window_vertices / 1_000_000)) {
		app.hd_window_vertices = int(millions + 0.5) * 1_000_000
	}
	ui.paragraph(ctx, fmt.tprintf("Stored: %d of %d top-level nodes, %s. Leaving a window stores it.", hd.stored_nodes, len(levels.levels[len(levels.levels) - 1].sculptor.nodes), bytes_label(hd.stored_bytes)))
	if hd.stored_nodes > 0 do ui.paragraph(ctx, "Saving the scene keeps the HD steps but not this detail.")
	if app.stats.hd_leave_ms > 0 do ui.paragraph(ctx, fmt.tprintf("Last window stored in %.0f ms.", app.stats.hd_leave_ms))
}

@(private = "file")
kit_dyntopo :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	on := object_dynamic(obj)
	can := command_enabled(app, .Dyntopo_Toggle)
	if ui.switch_row(ctx, "Dynamic topology", &on, enabled = can, keys = command_hint(app, .Dyntopo_Toggle)) do command_run(app, .Dyntopo_Toggle)
	if !can do ui.paragraph(ctx, "Needs a single subdivision level and no HD level.")
	_ = ui.slider(ctx, "Detail", &app.brush.detail_px, 2, 40, .Logarithmic, fmt.tprintf("%.1f px", app.brush.detail_px))
	_ = ui.switch_row(ctx, "Collapse short edges", &app.brush.collapse)
	ui.paragraph(ctx, fmt.tprintf("Brushes add triangles where they go: edges under the brush longer than Detail on screen split and, with collapse, much shorter ones merge. Turning it on or off is an undo step of its own. %s", command_keys(.Dyntopo_Toggle)))
	if !object_dynamic(obj) do return
	splits, collapses := sculpt.sculptor_dyn_edits(object_sculptor(obj))
	ui.paragraph(ctx, fmt.tprintf("%s splits, %s collapses so far; %d GPU regrows.", count_label(splits), count_label(collapses), app.stats.gpu_regrows))
	if s := app.stats; s.dyntopo_ms > 0 do ui.paragraph(ctx, fmt.tprintf("Turned on in %.0f ms, uploaded in %.0f ms.", s.dyntopo_ms, s.dyntopo_upload_ms))
}

@(private = "file")
kit_mask :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	commands := [?]sculpt.Mask_Command{.Clear, .Invert, .Fill, .Cavity, .Blur, .Sharpen, .Grow, .Shrink}
	labels := [?]string{"Clear", "Invert", "Mask all", "Cavities", "Blur", "Sharpen", "Grow", "Shrink"}
	for i := 0; i < len(commands); i += 2 {
		kit_command_pair(app, .Mask, .Mask, int(commands[i]), int(commands[i + 1]), labels[i], labels[i + 1])
	}
	steps := f32(app.ui.mask_steps)
	if ui.slider(ctx, "Steps", &steps, 1, 50, .Linear, fmt.tprintf("%d", app.ui.mask_steps)) do app.ui.mask_steps = i32(steps + 0.5)
	ui.label(ctx, "Ctrl + drag on empty space draws", t.small_size)
	shapes := [2]string{"Rectangle", "Lasso"}
	if picked := ui.tabs(ctx, "mask shape", shapes[:], int(app.ui.mask_shape_kind)); picked >= 0 do app.ui.mask_shape_kind = Mask_Shape_Kind(picked)
	ui.paragraph(ctx, fmt.tprintf("Paint the mask with the Mask brush, or Ctrl + drag a shape from empty space (with Alt: unmask). Masked parts show darker and no brush moves them. Blur, Sharpen, Grow and Shrink move its edge a ring of triangles a step. %s clears, %s inverts. With Mask on and the Sculpt tool, a tap off the model inverts, one on the mask blurs it and one on an unmasked part sharpens it.", command_keys(.Mask, int(sculpt.Mask_Command.Clear)), command_keys(.Mask, int(sculpt.Mask_Command.Invert))))
	kit_last_result(app, .Mask)
}

@(private = "file")
kit_visibility :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.label(ctx, "Ctrl + Shift + drag", t.small_size)
	names: [len(Gesture_Tool)]string
	for g, i in Gesture_Tool do names[i] = string(GESTURE_NAMES[g])
	if picked := ui.select(ctx, "gesture", names[:], int(app.gesture)); picked >= 0 do app.gesture = Gesture_Tool(picked)
	switch app.gesture {
	case .Hide_Rectangle, .Hide_Lasso:
		ui.paragraph(ctx, "Letting go keeps only what is inside the shape shown, through to the back (Alt: hides what is inside). Hidden parts are not drawn and no brush, mask or clip touches them. A Ctrl + Shift click shows everything. Not in HD or with dynamic topology.")
	case .Clip:
		ui.paragraph(ctx, "Letting go flattens the selected object on the shaded side (Alt: the other side) onto the line, through to the back. It follows symmetry and leaves masked and hidden parts. Not with dynamic topology.")
	case .Slice:
		ui.paragraph(ctx, "Letting go cuts the selected object in two along the line, through to the back, and closes each cut: the part on the right of the drag becomes an object of its own. Levels, mask and hiding are dropped.")
	}
	kit_command_pair(app, .Show_All, .Invert_Hidden, label_b = "Invert hiding")
	ui.paragraph(ctx, fmt.tprintf("%s shows all; %s inverts.", command_keys(.Show_All), command_keys(.Invert_Hidden)))
	kit_last_result(app, .Visibility)
	if app.stats.slice_ms > 0 do ui.paragraph(ctx, fmt.tprintf("Last slice: %.0f ms, ready in %.0f ms more.", app.stats.slice_ms, app.stats.slice_setup_ms))
}

@(private = "file")
kit_paint :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = kit_color(ctx, "paint colour", &app.brush.color)
	kit_command_pair(app, .Paint, .Paint, int(sculpt.Paint_Command.Fill), int(sculpt.Paint_Command.Clear), tone_b = .Danger)
	ui.paragraph(ctx, "The Paint brush paints this colour over the clay, Ctrl takes it off. Fill and Clear skip what is masked or hidden. Each level keeps its own paint.")
}

// Polygroups: making them, and showing them.
@(private = "file")
kit_groups :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_command_pair(app, .Group, .Group, int(sculpt.Group_Command.Visible), int(sculpt.Group_Command.Masked), "Group visible", "Group masked")
	_ = ui.slider(ctx, "Crease angle", &app.ui.crease_degrees, 1, 90, .Linear, fmt.tprintf("%.0f°", app.ui.crease_degrees))
	kit_command_pair(app, .Group, .Group, int(sculpt.Group_Command.Creases), int(sculpt.Group_Command.Clear), "Groups by creases", "Clear groups", tone_b = .Danger)
	_ = ui.switch_row(ctx, "Show polygroups", &app.show_groups, keys = command_hint(app, .Polygroups))
	ui.paragraph(ctx, fmt.tprintf("%s groups the masked part (clearing the mask), or with nothing masked what is shown. Ctrl + Shift click a group to show only it (again: everything but it); with Alt, to mask it. %s shows the groups. Not in HD or with dynamic topology.", command_keys(.Group_Shortcut), command_keys(.Polygroups)))
}

@(private = "file")
kit_morph :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	s := object_sculptor(obj)
	has := sculpt.sculptor_has_morph(s)
	kit_command_pair(app, .Morph_Store, .Morph_Delete, label_a = "Store", label_b = "Delete", tone_a = .Accent, tone_b = .Danger)
	ui.paragraph(ctx, "Stored for this level." if has else "None stored.")
	ui.paragraph(ctx, "Store keeps the surface as it is now; the Morph brush then brings any part back to it. One per level, not saved with the scene; not with dynamic topology.")
}

// Whole-object smoothing, and the switch that runs it on the GPU instead.
@(private = "file")
kit_deformation :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	can := !object_dynamic(obj)
	_ = command_button(app, .Smooth_All, tone = .Accent)
	_ = ui.switch_row(ctx, "On the GPU", &app.ui.smooth_on_gpu, enabled = can)
	steps := f32(app.ui.smooth_steps)
	if ui.slider(ctx, "Steps", &steps, 1, 100, .Logarithmic, fmt.tprintf("%d", app.ui.smooth_steps), enabled = can) do app.ui.smooth_steps = i32(steps + 0.5)
	_ = ui.slider(ctx, "Strength", &app.ui.smooth_strength, 0.05, 1, .Linear, fmt.tprintf("%.2f", app.ui.smooth_strength), enabled = can)
	ui.paragraph(ctx, "Smooths the whole object, each step moving every vertex toward its neighbours' average. Masked parts stay. One undo step; not with dynamic topology. On the GPU runs the steps as a compute shader, a trial of GPU sculpting.")
	kit_last_result(app, .Deform)
}

@(private = "file")
kit_remesh :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if picked := ui.select(ctx, "remesh size", kit_size_names(), k.add_size); picked >= 0 do k.add_size = picked
	kit_command_pair(app, .Remesh_To, .Decimate_To, k.add_size, k.add_size, "Remesh", "Decimate", tone_a = .Accent)
	ui.paragraph(ctx, fmt.tprintf("Remesh rebuilds the object as an even mesh of this many vertices that keeps its shape (%s: at its own count). Decimate keeps the shape with about this many: dense where the detail is, sparse where it is flat. Ctrl+Z brings levels and mask back.", command_keys(.Remesh)))
	if s := app.stats; s.remesh_ms > 0 do ui.paragraph(ctx, fmt.tprintf("Last remesh: %.0f ms, then %.0f ms to sculpt-ready.", s.remesh_ms, s.remesh_setup_ms))
	if s := app.stats; s.decimate_ms > 0 do ui.paragraph(ctx, fmt.tprintf("Last decimate: %.0f ms, strays at most %.4f.", s.decimate_ms, s.decimate_error))
}

@(private = "file")
kit_mirror :: proc(app: ^App) {
	ctx := &app.kit.ctx
	axes := [3]string{"X", "Y", "Z"}
	if picked := ui.tabs(ctx, "mirror axis", axes[:], int(app.ui.mirror_axis)); picked >= 0 do app.ui.mirror_axis = i32(picked)
	_ = ui.switch_row(ctx, "Keep the - side", &app.ui.mirror_negative)
	_ = command_button(app, .Mirror_Weld, tone = .Accent)
	ui.paragraph(ctx, "Replaces one half of the object with a mirror image of the other, across its own plane (the one symmetry uses), welded along the cut. Levels and mask go; Ctrl+Z brings them back.")
}
