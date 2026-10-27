package main

import "core:fmt"
import "core:math"
import "core:time"

import "../geom"
import "../sculpt"
import "../ui"

// Rebuild (Object > Shape): one section for the three ways to replace an object's
// topology, by the goal rather than the algorithm (UX research 08): an Even mesh (voxel
// remesh, ZBrush's DynaMesh), Fewer polygons (decimate) or Quads (retopologize). Its
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
	.Quads = "Retopologize (new object)",
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
	case .Even:  app.ui.scene_command = {kind = .Remesh, vertices = int(app.ui.rebuild_even)}
	case .Fewer: app.ui.scene_command = {kind = .Decimate, vertices = int(app.ui.rebuild_fewer)}
	case .Quads: app.ui.scene_command = {kind = .Retopo, vertices = int(app.ui.retopo_quads)}
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
	case .Even:  _ = kit_count(ctx, label, &app.ui.rebuild_even, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
	case .Fewer: _ = kit_count(ctx, label, &app.ui.rebuild_fewer, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
	case .Quads: _ = kit_count(ctx, label, &app.ui.retopo_quads, 100, 1_000_000)
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
		ui.paragraph(ctx, "An even mesh of about this many vertices that keeps the shape; overlapping parts merge.")
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
		ui.paragraph(ctx, "A new object of about this many quads lying on this one, with UVs, for baking (Build > UVs and baking).")
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

// A length in scene units with three significant figures.
@(private = "file")
length_label :: proc(x: f32) -> string {
	if x >= 100 do return fmt.tprintf("%.0f", x)
	if x >= 10 do return fmt.tprintf("%.1f", x)
	if x >= 1 do return fmt.tprintf("%.2f", x)
	return fmt.tprintf("%.3g", x)
}
