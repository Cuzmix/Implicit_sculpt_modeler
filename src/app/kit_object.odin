package main

import "core:fmt"
import "core:math"

import "../sculpt"
import "../ui"

// The inspector's Object tab: the selected object, where it is, and everything that
// changes it as a whole. Each section folds; the common ones start open.
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
	ui.spacer(ctx, 4)

	if ui.section(ctx, "Transform", &k.open[.Transform]) {
		kit_transform(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Subdivision levels", &k.open[.Levels]) {
		kit_levels(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "HD detail", &k.open[.Hd]) {
		kit_hd(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Dynamic topology", &k.open[.Topology]) {
		kit_dyntopo(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Mask", &k.open[.Mask]) {
		kit_mask(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Hide, clip and slice", &k.open[.Visibility]) {
		kit_visibility(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Polypaint and polygroups", &k.open[.Paint]) {
		kit_paint(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Morph target", &k.open[.Morph]) {
		kit_morph(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Layers", &k.open[.Layers]) {
		kit_layers_section(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Deformation", &k.open[.Deform]) {
		kit_deformation(app, obj)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Remesh", &k.open[.Remesh]) {
		kit_remesh(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Mirror and weld", &k.open[.Mirror]) {
		kit_mirror(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Retopology and baking", &k.open[.Retopo]) {
		kit_retopo_section(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Project detail", &k.open[.Project]) {
		kit_project_section(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Booleans", &k.open[.Booleans]) {
		kit_boolean_section(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Extract", &k.open[.Extract]) {
		kit_extract_section(app)
		ui.section_end(ctx)
	}
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
	lower, higher := kit_button_pair(ctx, "Lower##level", "Higher##level", levels.current > 0, levels.current < count - 1)
	if lower do command_run(app, .Level_Down)
	if higher do command_run(app, .Level_Up)
	vertices, _, bytes := sculpt.levels_subdivide_estimate(levels)
	can := command_enabled(app, .Subdivide)
	if ui.button(ctx, "Subdivide", .Solid, .Accent, glyph = ui.ICON_PLUS, enabled = can) do command_run(app, .Subdivide)
	switch {
	case dyntopo:
		ui.paragraph(ctx, "Turn dynamic topology off to subdivide.")
	case levels.hd.steps > 0:
		ui.paragraph(ctx, "Delete the HD level to subdivide.")
	case can:
		ui.paragraph(ctx, fmt.tprintf("Adds a level of %s vertices, about %s. %s", count_label(vertices), bytes_label(bytes), command_keys(.Subdivide)))
	}
	below, above := kit_button_pair(ctx, "Delete lower", "Delete higher", command_enabled(app, .Delete_Lower_Levels), command_enabled(app, .Delete_Higher_Levels), .Danger, .Danger)
	if below do command_run(app, .Delete_Lower_Levels)
	if above do command_run(app, .Delete_Higher_Levels)
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
	divide, remove := kit_button_pair(ctx, "Divide HD", "Delete HD", command_enabled(app, .Hd_Divide), command_enabled(app, .Hd_Delete), .Neutral, .Danger)
	if divide do command_run(app, .Hd_Divide)
	if remove do command_run(app, .Hd_Delete)
	if steps == 0 {
		ui.paragraph(ctx, "Sculpt finer than the top level, a window of it at a time.")
		return
	}
	ui.paragraph(ctx, fmt.tprintf("%d step%s up: %s vertices.", steps, "" if steps == 1 else "s", count_label(sculpt.levels_hd_vertices(levels))))
	if object_in_hd(obj) {
		if ui.button(ctx, "Leave HD", .Flat, .Accent) do command_run(app, .Hd_Leave)
		ui.paragraph(ctx, fmt.tprintf("A window of %s vertices, opened in %.0f + %.0f ms. %s leaves it too.", count_label(hd.window_vertices), app.stats.hd_open_ms, app.stats.hd_upload_ms, command_keys(.Hd_Toggle)))
	} else {
		// From the button, the window opens around the middle of the viewport.
		if ui.button(ctx, "Sculpt HD", .Solid, .Accent) do command_run(app, .Hd_Sculpt)
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
	if ui.switch_row(ctx, "Dynamic topology", &on, enabled = can) do command_run(app, .Dyntopo_Toggle)
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
		a, b := kit_button_pair(ctx, labels[i], labels[i + 1])
		if a do command_run(app, .Mask, int(commands[i]))
		if b do command_run(app, .Mask, int(commands[i + 1]))
	}
	steps := f32(app.ui.mask_steps)
	if ui.slider(ctx, "Steps", &steps, 1, 50, .Linear, fmt.tprintf("%d", app.ui.mask_steps)) do app.ui.mask_steps = i32(steps + 0.5)
	ui.label(ctx, "Ctrl + drag on empty space draws", t.small_size)
	shapes := [2]string{"Rectangle", "Lasso"}
	if picked := ui.tabs(ctx, "mask shape", shapes[:], int(app.ui.mask_shape_kind)); picked >= 0 do app.ui.mask_shape_kind = Mask_Shape_Kind(picked)
	ui.paragraph(ctx, fmt.tprintf("Paint the mask with the Mask brush, or Ctrl + drag a shape from empty space (with Alt: unmask). Masked parts show darker and no brush moves them. Blur, Sharpen, Grow and Shrink move its edge a ring of triangles a step. %s clears, %s inverts.", command_keys(.Mask, int(sculpt.Mask_Command.Clear)), command_keys(.Mask, int(sculpt.Mask_Command.Invert))))
	if last := app.ui.mask_last; last.set {
		steps := fmt.tprintf(", %d steps", last.steps) if last.command >= .Blur else ""
		name := MASK_COMMAND_NAMES[last.command]
		if last.shape do name = "Unmask shape" if last.command == .Clear else "Mask shape"
		ui.paragraph(ctx, fmt.tprintf("Last: %s%s in %.0f ms%s.", name, steps, last.ms, "" if last.changed else ", nothing changed"))
	}
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
	show, invert := kit_button_pair(ctx, "Show all", "Invert hiding")
	if show do command_run(app, .Show_All)
	if invert do command_run(app, .Invert_Hidden)
	ui.paragraph(ctx, fmt.tprintf("%s shows all; %s inverts.", command_keys(.Show_All), command_keys(.Invert_Hidden)))
	if last := app.ui.hide_last; last.set {
		hidden := sculpt.sculptor_hidden_count(object_sculptor(obj))
		ui.paragraph(ctx, fmt.tprintf("Last hide: %.0f ms%s; %d triangles hidden.", last.ms, "" if last.changed else ", nothing changed", hidden))
	}
	if last := app.ui.clip_last; last.set do ui.paragraph(ctx, fmt.tprintf("Last clip: %.0f ms%s.", last.ms, "" if last.changed else ", nothing changed"))
	if app.stats.slice_ms > 0 do ui.paragraph(ctx, fmt.tprintf("Last slice: %.0f ms, ready in %.0f ms more.", app.stats.slice_ms, app.stats.slice_setup_ms))
}

@(private = "file")
kit_paint :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = kit_color(ctx, "paint colour", &app.brush.color)
	fill, wipe := kit_button_pair(ctx, "Fill with colour", "Clear paint", tone_b = .Danger)
	if fill do command_run(app, .Paint, int(sculpt.Paint_Command.Fill))
	if wipe do command_run(app, .Paint, int(sculpt.Paint_Command.Clear))
	ui.paragraph(ctx, "The Paint brush paints this colour over the clay, Ctrl takes it off. Fill and Clear skip what is masked or hidden. Each level keeps its own paint.")
	visible, masked := kit_button_pair(ctx, "Group visible", "Group masked")
	if visible do command_run(app, .Group, int(sculpt.Group_Command.Visible))
	if masked do command_run(app, .Group, int(sculpt.Group_Command.Masked))
	_ = ui.slider(ctx, "Crease angle", &app.ui.crease_degrees, 1, 90, .Linear, fmt.tprintf("%.0f°", app.ui.crease_degrees))
	creases, none := kit_button_pair(ctx, "Groups by creases", "Clear groups", tone_b = .Danger)
	if creases do command_run(app, .Group, int(sculpt.Group_Command.Creases))
	if none do command_run(app, .Group, int(sculpt.Group_Command.Clear))
	_ = ui.switch_row(ctx, "Show polygroups", &app.show_groups)
	ui.paragraph(ctx, fmt.tprintf("%s groups the masked part (clearing the mask), or with nothing masked what is shown. Ctrl + Shift click a group to show only it (again: everything but it); with Alt, to mask it. %s shows the groups. Not in HD or with dynamic topology.", command_keys(.Group_Shortcut), command_keys(.Polygroups)))
}

@(private = "file")
kit_morph :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	s := object_sculptor(obj)
	has := sculpt.sculptor_has_morph(s)
	store, remove := kit_button_pair(ctx, "Store", "Delete", command_enabled(app, .Morph_Store), command_enabled(app, .Morph_Delete), .Accent, .Danger)
	if store do command_run(app, .Morph_Store)
	if remove do command_run(app, .Morph_Delete)
	ui.paragraph(ctx, "Stored for this level." if has else "None stored.")
	ui.paragraph(ctx, "Store keeps the surface as it is now; the Morph brush then brings any part back to it. One per level, not saved with the scene; not with dynamic topology.")
}

// Whole-object smoothing, and the switch that runs it on the GPU instead.
@(private = "file")
kit_deformation :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	can := !object_dynamic(obj)
	if ui.button(ctx, "Smooth all", .Flat, .Accent, enabled = can) do command_run(app, .Smooth_All)
	_ = ui.switch_row(ctx, "On the GPU", &app.ui.smooth_on_gpu, enabled = can)
	steps := f32(app.ui.smooth_steps)
	if ui.slider(ctx, "Steps", &steps, 1, 100, .Logarithmic, fmt.tprintf("%d", app.ui.smooth_steps), enabled = can) do app.ui.smooth_steps = i32(steps + 0.5)
	_ = ui.slider(ctx, "Strength", &app.ui.smooth_strength, 0.05, 1, .Linear, fmt.tprintf("%.2f", app.ui.smooth_strength), enabled = can)
	ui.paragraph(ctx, "Smooths the whole object, each step moving every vertex toward its neighbours' average. Masked parts stay. One undo step; not with dynamic topology. On the GPU runs the steps as a compute shader, a trial of GPU sculpting.")
	if last := app.ui.smooth_last; last.set {
		ui.paragraph(ctx, fmt.tprintf("Last: %d steps on the %s in %.0f ms%s.", last.steps, "GPU" if last.on_gpu else "CPU", last.ms, "" if last.changed else ", nothing changed"))
		if g := last.gpu; last.on_gpu {
			ui.paragraph(ctx, fmt.tprintf("GPU: upload %.1f ms (%.0f MB), compute %.1f ms, readback %.1f ms.", g.upload_ms, g.upload_mb, g.compute_ms, g.readback_ms))
		}
	}
}

@(private = "file")
kit_remesh :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if picked := ui.select(ctx, "remesh size", kit_size_names(), k.add_size); picked >= 0 do k.add_size = picked
	remesh, decimate := kit_button_pair(ctx, "Remesh", "Decimate", tone_a = .Accent)
	if remesh do command_run(app, .Remesh_To, k.add_size)
	if decimate do command_run(app, .Decimate_To, k.add_size)
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
	if ui.button(ctx, "Mirror and weld", .Flat, .Accent) do command_run(app, .Mirror_Weld)
	ui.paragraph(ctx, "Replaces one half of the object with a mirror image of the other, across its own plane (the one symmetry uses), welded along the cut. Levels and mask go; Ctrl+Z brings them back.")
}
