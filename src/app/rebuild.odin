package main

import "core:fmt"
import "core:math"
import "core:time"

import "../geom"
import "../retopo"
import "../sculpt"
import "../ui"

// Rebuild (Object > Shape): one section for the three ways to replace an object's
// topology, by the goal rather than the algorithm (UX research 08): an Even mesh (voxel
// remesh, ZBrush's DynaMesh), Fewer polygons (decimate) or Quads (Quad Remesh). Its
// Density slider sets how many, and while it is held the selected object shows the cells
// that density gives as a checkerboard (Nomad's resolution preview), so the size is seen
// before anything is rebuilt rather than guessed from a vertex count.

Rebuild_Goal :: enum u8 {
	Even,
	Fewer,
	Quads,
}

REBUILD_GOAL_NAMES := [Rebuild_Goal]string {
	.Even  = "Even",
	.Fewer = "Fewer",
	.Quads = "Quads",
}

// What Apply is called for each goal: the operation it runs. Quads says it makes a new
// object, where the other two replace this one.
REBUILD_VERBS := [Rebuild_Goal]string {
	.Even  = "Voxel remesh",
	.Fewer = "Decimate",
	.Quads = "Quad Remesh (new object)",
}

// How long the checkerboard stays after the slider is let go: long enough to look at it
// with the finger off the screen.
REBUILD_PREVIEW_HOLD :: 1.5

REBUILD_MIN_VERTICES :: 1_000
REBUILD_MAX_VERTICES :: 25_000_000

// How long the preview may spend measuring in one frame: a 10M mesh takes tens of
// milliseconds, so it is measured a few ranges a frame and the checker shows once done.
REBUILD_MEASURE_MS :: 1.0
// Ranges measured between looks at the clock: one per worker on a small machine, so a
// frame overshoots the budget by about one batch.
REBUILD_MEASURE_BATCH :: 4

// The density preview: when it shows, and the selected object's area and box, measured
// once for each mesh it is shown on (the only part that costs more than a few floats).
Rebuild_Preview :: struct {
	until:     f64, // shown until this time on the interface's clock
	pinned:    bool, // shown whatever the slider does (--density-preview)
	// The mesh buffers' version `area` and `bounds` were measured on: a counter across
	// all buffers, so it names the contents alone.
	version:   u64,
	measured:  bool,
	area:      f64,
	bounds:    geom.Aabb,
	// A measurement under way: its version, its ranges so far and the next to measure.
	measuring: bool,
	pending:   u64,
	parts:     [dynamic]geom.Area_Part,
	next:      int,
	area_ms:   f64, // the time the last measurement took in all, for the exit stats...
	step_ms:   f64, // ...and in its longest frame
	// The cells drawn this frame, for the panel's line and the exit stats.
	cell:     f32,
	origin:   Vec3,
	shown:    bool,
}

// Keeps the preview showing a while longer: called while the Density slider is held.
rebuild_preview_hold :: proc(app: ^App) {
	app.rebuild.until = app.kit.ctx.time + REBUILD_PREVIEW_HOLD
}

// A count kept to what the Density slider offers.
rebuild_count :: proc(vertices: int) -> i32 {
	return i32(clamp(vertices, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES))
}

// Measures the area of the object's current level and the box around it, a few ranges
// a frame (geom.mesh_area_parts), again whenever its mesh changes; true once `area` and
// `bounds` are this mesh's. The sums are those geom.mesh_area_bounds gives, which
// object_remesh takes, so a remesh builds on the very lattice the preview showed. The
// level, not an HD window: a remesh leaves HD and remeshes the level.
rebuild_measure_step :: proc(app: ^App, obj: ^Object) -> bool {
	p := &app.rebuild
	version := obj.gpu[obj.levels.current].version
	if p.measured && p.version == version do return true
	m := sculpt.levels_current(&obj.levels).mesh
	if !p.measuring || p.pending != version {
		p.measured, p.measuring, p.pending, p.next, p.area_ms, p.step_ms = false, true, version, 0, 0, 0
		resize(&p.parts, geom.mesh_area_part_count(m))
	}
	start := time.tick_now()
	for p.next < len(p.parts) {
		to := min(p.next + REBUILD_MEASURE_BATCH, len(p.parts))
		geom.mesh_area_parts(m, p.parts[:], p.next, to, &app.pool)
		p.next = to
		if time.duration_milliseconds(time.tick_since(start)) >= REBUILD_MEASURE_MS do break
	}
	took := time.duration_milliseconds(time.tick_since(start))
	p.area_ms += took
	p.step_ms = max(p.step_ms, took)
	if p.next < len(p.parts) do return false
	p.area, p.bounds = geom.mesh_area_total(p.parts[:])
	p.version, p.measured, p.measuring = version, true, false
	return true
}

rebuild_preview_destroy :: proc(p: ^Rebuild_Preview) {
	delete(p.parts)
}

// The checker to draw the selected object with this frame: the first lattice point and the
// cell size in its mesh space, or zero when the preview is not showing. Measures the
// object's area and box when its mesh is not the one measured last.
rebuild_preview_frame :: proc(app: ^App) -> [4]f32 {
	p := &app.rebuild
	p.shown = false
	obj := selected_object(app)
	goal := app.ui.rebuild_goal
	// A stroke ends it: every dab would change the mesh to measure.
	if app.stroke.active do p.until = 0
	if obj == nil || goal == .Fewer || (app.kit.ctx.time >= p.until && !p.pinned) do return {}
	// Not in a time-lapse or turntable, which are pictures of the sculpt; nor on a live boolean, whose
	// preview stands in for the object. The studio render starts over while it shows, as
	// for any other change.
	if timelapse_capturing(app) || turntable_recording(app) || app.ui.boolean.shown do return {}
	if !rebuild_measure_step(app, obj) do return {}
	ok: bool
	switch goal {
	case .Even:
		p.cell, p.origin, ok = geom.remesh_lattice(p.area, p.bounds, int(app.ui.rebuild_even), remesh_mirror(app, obj), remesh_setup(app).cell)
	case .Quads:
		// The side of a quad of the mean size the retopology aims for.
		p.cell = f32(math.sqrt(p.area / f64(max(app.ui.retopo_quads, 1))))
		p.origin, ok = p.bounds.lo, p.cell > 0 && p.bounds.lo.x <= p.bounds.hi.x
	case .Fewer:
	}
	if !ok do return {}
	p.shown = true
	return {p.origin.x, p.origin.y, p.origin.z, p.cell}
}

// How many polygroups the object's shown level has and how many creased edges its base
// level has (the ones Keep groups and Keep creases keep), so the switches can say when
// there is nothing to keep.
quad_source_counts :: proc(obj: ^Object) -> (groups, creases: int) {
	if obj == nil || obj.voxel != nil do return
	s := object_sculptor(obj)
	if sculpt.sculptor_has_groups(s) {
		seen := make(map[u16]bool, 16, context.temp_allocator)
		for g in sculpt.sculptor_groups(s) do seen[g] = true
		groups = len(seen)
	}
	if !object_dynamic(obj) && obj.levels.current == 0 do creases = len(obj.levels.levels[0].sharp.edges)
	return
}

// The faces the selected object is made of, as Half, Same and Double count them: the
// base level's polygons where it keeps them, else its quads, else its triangles.
object_face_count :: proc(obj: ^Object) -> int {
	if obj == nil do return 0
	if obj.voxel == nil && len(obj.levels.levels) > 0 {
		base := obj.levels.levels[0]
		if len(base.polys.first) > 1 do return len(base.polys.first) - 1
		if len(obj.levels.faces.quads) > 0 do return len(obj.levels.faces.quads)
	}
	return object_triangle_count(obj)
}

// Runs the goal the panel is set to on the selected object, at its density.
rebuild_command :: proc(app: ^App) {
	switch app.ui.rebuild_goal {
	case .Even:
		setup := remesh_setup(app)
		vertices := int(app.ui.rebuild_even) if setup.cell == 0 else remesh_cell_vertices(app, selected_object(app), setup.cell)
		app.ui.scene_command = {kind = .Remesh, vertices = vertices, remesh = setup}
	case .Fewer: app.ui.scene_command = {kind = .Decimate, vertices = int(app.ui.rebuild_fewer), decimate = decimate_setup(app)}
	case .Quads: app.ui.scene_command = {kind = .Retopo, vertices = int(app.ui.retopo_quads), quad = quad_options(app)}
	}
}

// Keep symmetry, the same switch under each goal's More options and on by default: the
// result keeps the brush's symmetry (symmetry_planes), as ZBrush's ZRemesher keeps the
// active symmetry. With no symmetry on there is nothing to keep, so it greys out and says so.
kit_keep_symmetry :: proc(app: ^App, value: ^bool) {
	ctx := &app.kit.ctx
	planes := symmetry_planes(app, selected_object(app))
	label := fmt.tprintf("Keep symmetry %s", planes_label(planes)) if planes.axes != {} else "Keep symmetry (none on)"
	_ = ui.switch_row(ctx, label, value, enabled = planes.axes != {})
}

kit_rebuild :: proc(app: ^App, obj: ^Object) {
	k := &app.kit
	ctx := &k.ctx
	goal := &app.ui.rebuild_goal
	names: [len(Rebuild_Goal)]string
	for g in Rebuild_Goal do names[int(g)] = REBUILD_GOAL_NAMES[g]
	if picked := ui.tabs(ctx, "rebuild goal", names[:], int(goal^)); picked >= 0 do goal^ = Rebuild_Goal(picked)
	label := "Density"
	switch goal^ {
	case .Even:
		kit_remesh_density(app, obj, label)
		// Smooth, Keep detail, Keep thin parts, Keep paint and mask, Groups and Quads under More options, which keeps the section
		// to its five controls and the button where the finger left it whichever goal is up.
		if kit_more(app, .Remesh) {
			kit_remesh_options(app, obj)
			kit_more_end(app)
		}
	case .Fewer:
		// A share by default, as Blender's Ratio and Decimation Master's percent; a count
		// under More options, for a budget such as a game engine's.
		if app.ui.decimate_by == .Percent {
			p := app.ui.decimate_percent
			_ = ui.slider(ctx, "Keep", &app.ui.decimate_percent, DECIMATE_PERCENT_MIN, DECIMATE_PERCENT_MAX, .Logarithmic, fmt.tprintf("%.0f%%", p))
			app.ui.decimate_percent = math.round(app.ui.decimate_percent)
		} else {
			_ = kit_count(ctx, label, &app.ui.rebuild_fewer, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
		}
		if kit_more(app, .Remesh) {
			kit_decimate_options(app, obj)
			kit_more_end(app)
		}
	case .Quads:
		_ = kit_count(ctx, label, &app.ui.retopo_quads, 100, 1_000_000)
		// Half, Same and Double set the count from the object's faces, as ZRemesher's
		// buttons do: the base level's polygons where it keeps them, else its quads, else its
		// triangles (a triangle sculpt has about twice the faces of the quads that cover it).
		{
			faces := object_face_count(obj)
			third := (ui.fill_width(ctx) - 16) / 3
			ui.begin(ctx, "half same double", {direction = .Row, gap = 8})
			if ui.button(ctx, "Half", .Flat, .Neutral, width = third, enabled = faces > 0) do app.ui.retopo_quads = i32(clamp(faces / 2, 100, 1_000_000))
			if ui.button(ctx, "Same", .Flat, .Neutral, width = third, enabled = faces > 0) do app.ui.retopo_quads = i32(clamp(faces, 100, 1_000_000))
			if ui.button(ctx, "Double", .Flat, .Neutral, width = third, enabled = faces > 0) do app.ui.retopo_quads = i32(clamp(faces * 2, 100, 1_000_000))
			ui.end(ctx)
		}
		// The engine, Adaptive size, Close first and Keep symmetry under the same fold, for the
		// same reasons.
		if kit_more(app, .Remesh) {
			engines: [len(retopo.Engine)]string
			for e in retopo.Engine do engines[int(e)] = retopo.ENGINE_NAMES[e]
			if picked := ui.tabs(ctx, "quad engine", engines[:], int(app.ui.retopo_engine)); picked >= 0 do app.ui.retopo_engine = retopo.Engine(picked)
			if app.ui.retopo_engine == .Auto {
				a := app.ui.retopo_adaptivity
				_ = ui.slider(ctx, "Adaptive size", &app.ui.retopo_adaptivity, 0, 1, .Linear, "Even" if a == 0 else fmt.tprintf("%.0f%%", 100 * a))
				// Keep groups, Keep creases and Edge angle, as ZRemesher's KeepGroups,
				// KeepCreases and its hard-edge detection: the quads' edges run along
				// them. The object's own groups and creases decide what there is to keep.
				groups, creases := quad_source_counts(obj)
				_ = ui.switch_row(ctx, "Keep groups" if groups > 1 else "Keep groups (none)", &app.ui.retopo_keep_groups, enabled = groups > 1)
				_ = ui.switch_row(ctx, "Keep creases" if creases > 0 else "Keep creases (none)", &app.ui.retopo_keep_creases, enabled = creases > 0)
				d := app.ui.retopo_edge_degrees
				_ = ui.slider(ctx, "Edge angle", &app.ui.retopo_edge_degrees, RETOPO_EDGE_DEGREES_MIN, 90, .Linear, "90° and sharper" if d >= 90 else fmt.tprintf("%.0f°", d))
				app.ui.retopo_edge_degrees = math.round(app.ui.retopo_edge_degrees)
				// Use paint and Use mask, as ZRemesher's Use PolyPaint: red asks more quads,
				// blue fewer, a mask more. A dynamic layout's packing keeps no paint.
				s := object_sculptor(obj)
				painted := obj.voxel == nil && sculpt.sculptor_paint_shows(s)
				masked := obj.voxel == nil && s.mask != nil
				_ = ui.switch_row(ctx, "Use paint" if painted else "Use paint (none)", &app.ui.retopo_use_paint, enabled = painted && !object_dynamic(obj))
				_ = ui.switch_row(ctx, "Use mask" if masked else "Use mask (none)", &app.ui.retopo_use_mask, enabled = masked)
				// Guide strength, as ZRemesher's Curves Strength: how hard the Guide
				// curves (a curve's use) pull the loops along them.
				guides := quad_guide_count(app)
				g := app.ui.retopo_guide_strength
				_ = ui.slider(ctx, "Guide strength" if guides > 0 else "Guide strength (no guides)", &app.ui.retopo_guide_strength, 0, 1, .Linear, "Off" if g == 0 else fmt.tprintf("%.0f%%", 100 * g), enabled = guides > 0)
			}
			_ = ui.switch_row(ctx, "Close first", &app.ui.retopo_close_first)
			// Keep borders, as ZRemesher's FreezeBorder: an open mesh's border comes back
			// as it was, so the result welds onto what it was cut from. Close first leaves
			// no border to keep.
			if app.ui.retopo_engine == .Auto do _ = ui.switch_row(ctx, "Keep borders", &app.ui.retopo_keep_borders, enabled = !app.ui.retopo_close_first)
			kit_keep_symmetry(app, &app.ui.retopo_keep_symmetry)
			kit_more_end(app)
		}
	}
	// Held, or under a mouse: the checkerboard shows (Fewer has none to show).
	id := ui.id_of(ctx, label)
	if goal^ != .Fewer && (ctx.active == id || (ctx.hot == id && app.device.pointer == .Mouse)) do rebuild_preview_hold(app)
	p := &app.rebuild
	measured := p.measured && p.version == obj.gpu[obj.levels.current].version
	scale := obj.transform.scale
	// What the goal makes, then one short line on the preview that changes as it shows,
	// so the button under them stays where the finger left it.
	switch goal^ {
	case .Even:
		// Two lines: what the options do is in their rows and README, and a longer text
		// here moved the button down past where the other goals keep it.
		by_cell := app.ui.remesh_by == .Cell
		ui.paragraph(ctx, "An even mesh at this cell size that keeps the shape; overlaps merge, holes close." if by_cell else "An even mesh of about this many vertices that keeps the shape; overlaps merge, holes close.")
		if measured && p.shown {
			// A surface of area A crosses about 1.5 A / h² lattice edges, one vertex each;
			// fewer than asked when the lattice limit made the cells bigger.
			about := int(1.5 * p.area / f64(p.cell * p.cell))
			if by_cell {
				ui.paragraph(ctx, fmt.tprintf("Cells %s wide: about %s vertices.", length_label(p.cell * scale), count_label(about)))
			} else if about < int(app.ui.rebuild_even) * 9 / 10 {
				ui.paragraph(ctx, fmt.tprintf("Cells %s wide: %s vertices at most.", length_label(p.cell * scale), count_label(about)))
			} else {
				ui.paragraph(ctx, fmt.tprintf("Cells %s wide: about one vertex each.", length_label(p.cell * scale)))
			}
		} else {
			ui.paragraph(ctx, "Measuring the surface..." if p.measuring else "Hold Density to see its cells on the object.")
		}
	case .Fewer:
		ui.paragraph(ctx, "Keeps the shape with fewer vertices: dense where the detail is, sparse where it is flat.")
		now := object_vertex_count(obj)
		after := decimate_target(now, int(app.ui.rebuild_fewer), decimate_setup(app))
		if after < now {
			ui.paragraph(ctx, fmt.tprintf("Now %s vertices; about %s after.", count_label(now), count_label(after)))
		} else {
			ui.paragraph(ctx, fmt.tprintf("Now %s vertices: already no more than that.", count_label(now)))
		}
	case .Quads:
		ui.paragraph(ctx, "A new object of about this many quads lying on this one, with UVs for baking.")
		if measured && p.shown {
			ui.paragraph(ctx, fmt.tprintf("Quads about %s wide.", length_label(p.cell * scale)))
		} else {
			ui.paragraph(ctx, "Measuring the surface..." if p.measuring else "Hold Density to see their size.")
		}
	}
	_ = command_button(app, .Rebuild, label = REBUILD_VERBS[goal^], tone = .Accent)
	kit_last_result(app, .Retopo if goal^ == .Quads else .Remesh)
	if goal^ != .Quads do ui.paragraph(ctx, fmt.tprintf("Levels, mask and strokes go; Ctrl+Z brings them back. %s remeshes again at the object's own cell.", command_keys(app, .Remesh)))
}

// Rebuild's Even density, the same row in the Rebuild section and the Remesh quick menu: a
// vertex count, or with Density set by Cell size (under More options) the cells' width in
// millimetres at the scene's print scale, as Blender's voxel size.
kit_remesh_density :: proc(app: ^App, obj: ^Object, label: string) {
	ctx := &app.kit.ctx
	if app.ui.remesh_by == .Vertices {
		// The slider stops at Largest remesh (Settings > Performance > Mesh size).
		_ = kit_count(ctx, label, &app.ui.rebuild_even, REBUILD_MIN_VERTICES, i32(mesh_remesh_most(app)))
		return
	}
	mm := &app.ui.remesh_cell_mm
	_ = ui.slider(ctx, label, mm, REMESH_CELL_MM_MIN, REMESH_CELL_MM_MAX, .Logarithmic, fmt.tprintf("%s mm", length_label(mm^)))
}

// About how many vertices a remesh of `obj` at `cell` makes, from the area the density
// preview measured when it is the object's mesh now, else the object's own count: what
// decides whether it runs as a long job.
remesh_cell_vertices :: proc(app: ^App, obj: ^Object, cell: f32) -> int {
	if obj == nil do return 0
	p := &app.rebuild
	if p.measured && p.version == obj.gpu[obj.levels.current].version && cell > 0 do return int(1.5 * p.area / f64(cell * cell))
	return object_vertex_count(obj)
}

remesh_quick_open :: proc(app: ^App, at: ui.Rect, side := ui.Side.Above_Center) {
	if bar_pop_showing(app, .Remesh_Quick) {
		app.kit.bar_pop.open = false
		return
	}
	app.ui.rebuild_goal = .Even
	bar_pop_toggle(app, .Remesh_Quick, at, side)
}

kit_remesh_quick :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	inner := f32(ui.POPOVER_W - 24)
	ui.begin(ctx, "remesh quick head", {direction = .Row, center = true})
	ui.begin(ctx, "remesh quick title", {direction = .Column, width = inner - t.target})
	ui.label(ctx, "Voxel remesh", t.title_size, t.text, .Semibold)
	ui.end(ctx)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do k.bar_pop.open = false
	ui.end(ctx)
	obj := selected_object(app)
	if obj == nil {
		ui.paragraph(ctx, "Add or select an object first.")
		return
	}
	even := &app.ui.rebuild_even
	label := "Density"
	kit_remesh_density(app, obj, label)
	id := ui.id_of(ctx, label)
	if ctx.active == id || (ctx.hot == id && app.device.pointer == .Mouse) do rebuild_preview_hold(app)
	// The object's own count (or cell), and half and twice its vertices: the steps taken
	// most. Half the vertices is a cell √2 wider.
	now := object_vertex_count(obj)
	third := (inner - 16) / 3
	own_mm := remesh_cell_mm(app, obj, obj.remesh_cell) if obj.remesh_cell > 0 else app.ui.remesh_cell_mm
	cell_mm := &app.ui.remesh_cell_mm
	by_cell := app.ui.remesh_by == .Cell
	ui.begin(ctx, "remesh quick steps", {direction = .Row, gap = 8})
	if ui.button(ctx, "Half", .Bordered, width = third) {
		if by_cell do cell_mm^ = clamp(own_mm * math.SQRT_TWO, REMESH_CELL_MM_MIN, REMESH_CELL_MM_MAX)
		else do even^ = rebuild_count(now / 2)
	}
	if ui.button(ctx, "Same", .Bordered, width = third) {
		if by_cell do cell_mm^ = clamp(own_mm, REMESH_CELL_MM_MIN, REMESH_CELL_MM_MAX)
		else do even^ = rebuild_count(now)
	}
	if ui.button(ctx, "Double", .Bordered, width = third) {
		if by_cell do cell_mm^ = clamp(own_mm / math.SQRT_TWO, REMESH_CELL_MM_MIN, REMESH_CELL_MM_MAX)
		else do even^ = rebuild_count(now * 2)
	}
	ui.end(ctx)
	p := &app.rebuild
	measured := p.measured && p.version == obj.gpu[obj.levels.current].version
	if measured && p.shown {
		ui.paragraph(ctx, fmt.tprintf("Now %s vertices; cells %s wide.", count_label(now), length_label(p.cell * obj.transform.scale)))
	} else {
		ui.paragraph(ctx, fmt.tprintf("Now %s vertices. Hold Density to see its cells.", count_label(now)))
	}
	if ui.button(ctx, "Voxel remesh##quick", .Flat, .Accent, inner, ICON_REMESH, enabled = command_enabled(app, .Remesh), keys = command_hint(app, .Rebuild)) {
		app.ui.rebuild_goal = .Even
		rebuild_command(app)
	}
	kit_last_result(app, .Remesh)
	if ui.menu_item(ctx, "More options", glyph = ui.ICON_SETTINGS) {
		at, side := k.bar_pop.at, k.bar_pop.side
		k.bar_pop.open = false
		bar_section_toggle(app, .Remesh, at, side)
	}
}

// A length in scene units with three significant figures.
@(private = "file")
length_label :: proc(x: f32) -> string {
	if x >= 100 do return fmt.tprintf("%.0f", x)
	if x >= 10 do return fmt.tprintf("%.1f", x)
	if x >= 1 do return fmt.tprintf("%.2f", x)
	return fmt.tprintf("%.3g", x)
}
