package main

import "core:fmt"
import "core:math"
import "core:time"

import "../geom"
import "../quadmesh"
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
	.Even  = "Remesh",
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
		p.cell, p.origin, ok = geom.remesh_lattice(p.area, p.bounds, int(app.ui.rebuild_even))
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

// Runs the goal the panel is set to on the selected object, at its density.
rebuild_command :: proc(app: ^App) {
	switch app.ui.rebuild_goal {
	case .Even:  app.ui.scene_command = {kind = .Remesh, vertices = int(app.ui.rebuild_even), remesh = remesh_setup(app)}
	case .Fewer: app.ui.scene_command = {kind = .Decimate, vertices = int(app.ui.rebuild_fewer)}
	case .Quads: app.ui.scene_command = {kind = .Retopo, vertices = int(app.ui.retopo_quads), quad = quad_options(app)}
	}
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
		_ = kit_count(ctx, label, &app.ui.rebuild_even, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
		// Smooth, Keep detail, Groups and Quads under More options, which keeps the section
		// to its five controls and the button where the finger left it whichever goal is up.
		if kit_more(app, .Remesh) {
			kit_remesh_options(app, obj)
			kit_more_end(app)
		}
	case .Fewer: _ = kit_count(ctx, label, &app.ui.rebuild_fewer, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
	case .Quads:
		_ = kit_count(ctx, label, &app.ui.retopo_quads, 100, 1_000_000)
		// The engine, Adaptivity, Mirror and Close first under the same fold, for the same
		// reasons.
		if kit_more(app, .Remesh) {
			// Where only the built-in engine is compiled there is nothing to choose.
			when quadmesh.AVAILABLE {
				engines: [len(Quad_Engine)]string
				for e in Quad_Engine do engines[int(e)] = QUAD_ENGINE_NAMES[e]
				if picked := ui.tabs(ctx, "quad engine", engines[:], int(app.ui.retopo_engine)); picked >= 0 do app.ui.retopo_engine = Quad_Engine(picked)
				if app.ui.retopo_engine == .Auto {
					a := app.ui.retopo_adaptivity
					_ = ui.slider(ctx, "Adaptivity", &app.ui.retopo_adaptivity, 0, 1, .Linear, "Even" if a == 0 else fmt.tprintf("%.0f%%", 100 * a))
					axes: [len(Quad_Symmetry)]string
					for x in Quad_Symmetry do axes[int(x)] = QUAD_SYMMETRY_NAMES[x]
					if picked := ui.tabs(ctx, "quad symmetry", axes[:], int(app.ui.retopo_symmetry)); picked >= 0 do app.ui.retopo_symmetry = Quad_Symmetry(picked)
				}
			}
			_ = ui.switch_row(ctx, "Close first", &app.ui.retopo_close_first)
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
		ui.paragraph(ctx, "An even mesh of about this many vertices that keeps the shape; overlaps merge, holes close.")
		if measured && p.shown {
			// A surface of area A crosses about 1.5 A / h² lattice edges, one vertex each;
			// fewer than asked when the lattice limit made the cells bigger.
			about := int(1.5 * p.area / f64(p.cell * p.cell))
			if about < int(app.ui.rebuild_even) * 9 / 10 {
				ui.paragraph(ctx, fmt.tprintf("Cells %s wide: %s vertices at most.", length_label(p.cell * scale), count_label(about)))
			} else {
				ui.paragraph(ctx, fmt.tprintf("Cells %s wide: about one vertex each.", length_label(p.cell * scale)))
			}
		} else {
			ui.paragraph(ctx, "Measuring the surface..." if p.measuring else "Hold Density to see its cells on the object.")
		}
	case .Fewer:
		ui.paragraph(ctx, "About this many vertices, dense where the detail is and sparse where the surface is flat, so there is no one size to preview.")
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
	if goal^ != .Quads do ui.paragraph(ctx, fmt.tprintf("Levels, mask and strokes go; Ctrl+Z brings them back. %s remeshes at the object's own count.", command_keys(app, .Remesh)))
}

// The Remesh button's quick menu, its long press on the bottom bar, after Nomad's voxel
// popup and the reference app's long press on its remesh: the density with the object's
// own count a tap away, the checkerboard on the object while Density is held (as in the
// Rebuild section, whose even goal it sets), and one big Remesh. Fewer polygons and quads
// are under More options, the Rebuild section itself.
REMESH_QUICK_W :: 300

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
	inner := f32(REMESH_QUICK_W - 24)
	ui.begin(ctx, "remesh quick head", {direction = .Row, center = true})
	ui.begin(ctx, "remesh quick title", {direction = .Column, width = inner - t.target})
	ui.label(ctx, "Remesh", t.title_size, t.text, .Semibold)
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
	_ = kit_count(ctx, label, even, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
	id := ui.id_of(ctx, label)
	if ctx.active == id || (ctx.hot == id && app.device.pointer == .Mouse) do rebuild_preview_hold(app)
	// The object's own count, and half and twice it: the steps taken most.
	now := object_vertex_count(obj)
	third := (inner - 16) / 3
	ui.begin(ctx, "remesh quick steps", {direction = .Row, gap = 8})
	if ui.button(ctx, "Half", .Bordered, width = third) do even^ = rebuild_count(now / 2)
	if ui.button(ctx, "Same", .Bordered, width = third) do even^ = rebuild_count(now)
	if ui.button(ctx, "Double", .Bordered, width = third) do even^ = rebuild_count(now * 2)
	ui.end(ctx)
	p := &app.rebuild
	measured := p.measured && p.version == obj.gpu[obj.levels.current].version
	if measured && p.shown {
		ui.paragraph(ctx, fmt.tprintf("Now %s vertices; cells %s wide.", count_label(now), length_label(p.cell * obj.transform.scale)))
	} else {
		ui.paragraph(ctx, fmt.tprintf("Now %s vertices. Hold Density to see its cells.", count_label(now)))
	}
	if ui.button(ctx, "Remesh##quick", .Flat, .Accent, inner, ICON_REMESH, enabled = command_enabled(app, .Remesh), keys = command_hint(app, .Rebuild)) {
		app.ui.rebuild_goal = .Even
		rebuild_command(app)
	}
	kit_last_result(app, .Remesh)
	if ui.menu_item(ctx, "More options", glyph = ui.ICON_SETTINGS) do bar_pop_toggle(app, .Section, k.bar_pop.at, k.bar_pop.side, .Remesh)
}

// A length in scene units with three significant figures.
@(private = "file")
length_label :: proc(x: f32) -> string {
	if x >= 100 do return fmt.tprintf("%.0f", x)
	if x >= 10 do return fmt.tprintf("%.1f", x)
	if x >= 1 do return fmt.tprintf("%.2f", x)
	return fmt.tprintf("%.3g", x)
}
