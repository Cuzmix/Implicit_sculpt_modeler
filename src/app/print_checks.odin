package main

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"
import "../ui"
import "../voxel"

// The Export sheet's checks before a print (panels P5b), as a slicer's and Blender's 3D
// print toolbox's are, under the preview while the 3D print preset is shown: whether the
// surface is watertight, its holes with Repair (Close holes, one undo step), its
// thinnest wall against the least a printer makes, and whether it fits the printer's bed.
// They look at what the print file holds (the shown level, a dynamic object's packed
// triangles, a voxel object's surface), once for each change of it: the sheet asks every
// frame, and the answer is kept while the object's buffers stay the same version. A big
// surface is checked on a thread of its own, from its own copy, as a long job computes
// (half a second at 1M triangles on four cores), while the rows say it is checking; the
// sheet and the view go on meanwhile.

// The least wall and the bed a fresh install checks against: a 0.4 mm nozzle lays a
// wall of two lines, about a millimetre, and 220 × 220 × 250 mm is the commonest bed of
// a desktop printer.
PRINT_WALL_DEFAULT :: 1
PRINT_BED_DEFAULT :: [3]f32{220, 220, 250}
// What Settings lets them be, in millimetres.
PRINT_WALL_MIN :: 0.1
PRINT_WALL_MAX :: 10
PRINT_BED_MIN :: 20
PRINT_BED_MAX :: 2000
// The triangles the wall is measured from, spread evenly over the surface: enough to find
// a thin ear or finger, few enough to take a few milliseconds.
PRINT_WALL_SAMPLES :: 4096
// The thinnest wall reported is the third thinnest sample's, so that one or two stray
// pinches of the surface do not decide it, while a thin part of any size has more.
PRINT_WALL_RANK :: 3
// Up to this many triangles the checks run at once, in a few tens of milliseconds; a
// bigger surface goes to a thread (and scripted runs' default sphere stays at once).
PRINT_CHECK_AT_ONCE :: 300_000

// What the checks found.
Print_Check_Result :: struct {
	too_big:    bool, // over PRINT_CHECK_MAX indices: not checked
	open_edges: int, // edges with one face
	bad_edges:  int, // edges of more than two faces, or between faces turned opposite ways
	inverted:   bool, // closed but facing inward
	holes:      int,
	wall:       f32, // the thinnest wall in the object's own units; 0 when none was measured
}

Print_Checks :: struct {
	key:    [3]u64, // the object, its buffers' version and its level, when checked
	have:   bool, // `result` is for `key`
	result: Print_Check_Result,
	work:   ^Print_Check_Work, // the thread checking a big surface, while it runs
	ms:     f64, // what the last check took
	runs:   int, // checks begun, for the exit stats
}

// A check on its thread: its own copy of the triangles, its own workers, and what it found.
Print_Check_Work :: struct {
	key:    [3]u64,
	input:  geom.Mesh,
	thread: ^thread.Thread,
	pool:   jobs.Pool,
	done:   bool, // atomic: the thread has finished
	result: Print_Check_Result,
	start:  time.Tick,
}

// The least wall, in millimetres, that Settings set.
print_wall_least :: proc(app: ^App) -> f32 {
	return app.print_wall if app.print_wall > 0 else PRINT_WALL_DEFAULT
}

// The printer's bed, width, depth and height in millimetres, that Settings set.
print_bed :: proc(app: ^App) -> [3]f32 {
	b := PRINT_BED_DEFAULT
	for k in 0 ..< 3 do if app.print_bed[k] > 0 do b[k] = app.print_bed[k]
	return b
}

// What tells one state of the object's surface from another: its id, the version of its
// buffers (which every change of its vertices or triangles bumps) and its level.
print_check_key :: proc(obj: ^Object) -> [3]u64 {
	gpu := &obj.voxel.gpu if obj.voxel != nil else &obj.gpu[obj.levels.current]
	return {u64(obj.id), gpu.version, u64(obj.levels.current)}
}

// The checks of `obj` as it stands, begun unless they are done or under way; nil while
// they are under way. The sheet calls it every frame the checks show.
print_checks_update :: proc(app: ^App, obj: ^Object) -> ^Print_Check_Result {
	c := &app.print_checks
	print_checks_collect(c)
	key := print_check_key(obj)
	if c.have && c.key == key do return &c.result
	// One thread at a time: a change made while it ran is checked once it is done.
	if c.work != nil do return nil
	c.runs += 1
	start := time.tick_now()
	lv := sculpt.levels_current(&obj.levels)
	if obj.voxel == nil && !object_dynamic(obj) && len(lv.mesh.indices) <= 3 * PRINT_CHECK_AT_ONCE {
		// The sculptor's own BVH, which picking keeps up to date, answers the rays.
		c.result = print_check_compute(lv.sculptor.mesh^, &lv.sculptor.bvh, &app.pool)
		c.key, c.have = key, true
		c.ms = time.duration_milliseconds(time.tick_since(start))
		return &c.result
	}
	w := new(Print_Check_Work)
	w.key, w.start = key, start
	if vp := obj.voxel; vp != nil {
		w.input = voxel.clay_to_mesh(&vp.clay)
	} else if object_dynamic(obj) {
		mask: []u8
		w.input, mask = sculpt.sculptor_compact_mesh(&lv.sculptor)
		delete(mask)
	} else {
		w.input.positions = make([dynamic]geom.Vec3, len(lv.mesh.positions))
		w.input.indices = make([dynamic]u32, len(lv.mesh.indices))
		copy(w.input.positions[:], lv.mesh.positions[:])
		copy(w.input.indices[:], lv.mesh.indices[:])
	}
	if len(w.input.indices) <= 3 * PRINT_CHECK_AT_ONCE {
		// A small voxel or dynamic surface: its copy is checked at once.
		c.result = print_check_compute(w.input, nil, &app.pool)
		c.key, c.have = key, true
		c.ms = time.duration_milliseconds(time.tick_since(start))
		geom.mesh_destroy(&w.input)
		free(w)
		return &c.result
	}
	jobs.pool_init(&w.pool, max(jobs.pool_size(&app.pool) - 2, 1))
	w.thread = thread.create_and_start_with_data(w, print_check_thread, context, .Low, name = "print checks")
	c.work = w
	return nil
}

// Takes what a finished thread found, when it is for the key asked.
@(private = "file")
print_checks_collect :: proc(c: ^Print_Checks) {
	w := c.work
	if w == nil || !sync.atomic_load(&w.done) do return
	print_check_join(w)
	c.result, c.key, c.have = w.result, w.key, true
	c.ms = time.duration_milliseconds(time.tick_since(w.start))
	free(w)
	c.work = nil
}

// Waits for a check's thread and frees what it held.
@(private = "file")
print_check_join :: proc(w: ^Print_Check_Work) {
	thread.join(w.thread)
	thread.destroy(w.thread)
	jobs.pool_destroy(&w.pool)
	geom.mesh_destroy(&w.input)
}

// When the app ends: waits for a check still running and keeps what it found, for the
// exit stats.
print_checks_stop :: proc(app: ^App) {
	c := &app.print_checks
	if c.work == nil do return
	// Once joined the thread has finished, so the collect takes its result (joining
	// again returns at once).
	thread.join(c.work.thread)
	print_checks_collect(c)
}

// The check's thread: the checks on the copy, then done.
@(private = "file")
print_check_thread :: proc(data: rawptr) {
	w := cast(^Print_Check_Work)data
	// Temp memory of its own: the context came from the frame loop, whose temp allocator
	// is that thread's.
	arena: runtime.Arena
	context.temp_allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)
	// What it makes and frees, the BVH and the checks' own arrays, goes to the heap, as
	// every job's allocations do.
	context.allocator = runtime.heap_allocator()
	w.result = print_check_compute(w.input, nil, &w.pool)
	sync.atomic_store(&w.done, true)
}

// The checks of surface `m`, its rays answered by `bvh` or, without one, by one built here.
print_check_compute :: proc(m: geom.Mesh, bvh: ^geom.Bvh, pool: ^jobs.Pool) -> (r: Print_Check_Result) {
	if len(m.indices) > PRINT_CHECK_MAX {
		r.too_big = true
		return
	}
	in_ := geom.mesh_integrity(m, pool)
	r.open_edges = in_.check.boundary_edges
	r.bad_edges = in_.check.non_manifold_edges + in_.check.inconsistent_edges
	r.inverted = in_.check.closed && in_.check.inverted
	r.holes = in_.holes
	// A wall has an inside only on a surface closed all round.
	if !in_.check.closed || r.bad_edges > 0 do return
	if bvh != nil {
		r.wall = print_thinnest_wall(m, bvh, in_.check.inverted)
		return
	}
	own := geom.bvh_build_morton(m, pool = pool)
	defer geom.bvh_destroy(&own)
	r.wall = print_thinnest_wall(m, &own, in_.check.inverted)
	return
}

// How thin the closed surface `m` gets, in its own units: from evenly spread triangles a
// ray goes inward, against the face's normal (along it when the surface is `inverted`),
// to the first face it meets from behind, the far side of the wall; faces met from the
// front are where the surface runs into itself and are passed over. The third thinnest
// of those walls is the answer (PRINT_WALL_RANK); 0 when no ray met one. Reads `bvh`
// only, so a thread may share it.
print_thinnest_wall :: proc(m: geom.Mesh, bvh: ^geom.Bvh, inverted: bool) -> f32 {
	tris := len(m.indices) / 3
	if tris == 0 do return 0
	b := geom.AABB_EMPTY
	for p in m.positions do geom.aabb_grow(&b, p)
	// The ray starts this far inside its face, so that its own face is behind it.
	lift := max(linalg.length(b.hi - b.lo) * 1e-6, 1e-9)
	samples := min(tris, PRINT_WALL_SAMPLES)
	walls := make([dynamic]f32, 0, samples)
	defer delete(walls)
	stack := make([dynamic]u32, 0, 64)
	defer delete(stack)
	for k in 0 ..< samples {
		// Spread over the triangles in their order, which follows the surface.
		tri := u32(k * tris / samples)
		n, centre, ok := face_normal_centre(m, tri)
		if !ok do continue
		dir := n if inverted else -n
		t, hit, met := geom.bvh_raycast_with(bvh^, m, centre + dir * lift, dir, max(f32), &stack)
		if !met || hit == tri do continue
		far, _, far_ok := face_normal_centre(m, hit)
		if !far_ok || linalg.dot(far, dir) * (-1 if inverted else 1) <= 0 do continue
		append(&walls, t + lift)
	}
	if len(walls) == 0 do return 0
	slice.sort(walls[:])
	return walls[min(PRINT_WALL_RANK, len(walls)) - 1]
}

// Triangle `tri`'s unit normal and centre; false for one with no area.
@(private = "file")
face_normal_centre :: proc(m: geom.Mesh, tri: u32) -> (n, centre: Vec3, ok: bool) {
	a := m.positions[m.indices[3 * tri]]
	b := m.positions[m.indices[3 * tri + 1]]
	c := m.positions[m.indices[3 * tri + 2]]
	cr := linalg.cross(b - a, c - a)
	l := linalg.length(cr)
	if !(l > 0) do return
	return cr / l, (a + b + c) / 3, true
}

// Whether a print `size` millimetres (width, height up, depth, as print_size_mm gives
// it) fits on bed `bed` (width, depth, height): turned a quarter round on the bed too.
print_fits_bed :: proc(size: Vec3, bed: [3]f32) -> bool {
	w, h, d := size.x, size.y, size.z
	return h <= bed[2] && ((w <= bed[0] && d <= bed[1]) || (w <= bed[1] && d <= bed[0]))
}

// The checks' rows, `w` points wide, under BEFORE IT PRINTS.
print_checks_rows :: proc(app: ^App, obj: ^Object, w: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	// With more than one object going out, the checks are of the selected one, which the
	// caption names; the bed holds them all.
	objs := print_objects(app)
	ui.caption(ctx, "BEFORE IT PRINTS" if len(objs) < 2 else fmt.tprintf("BEFORE IT PRINTS · %s", object_label(obj)))
	c := print_checks_update(app, obj)
	if c == nil {
		_ = print_check_row(ctx, true, "Checking the print...", w, waiting = true)
		ui.paragraph(ctx, "A big model takes a moment to check; you can keep working meanwhile.", w, t.text_tertiary)
		return
	}
	if c.too_big {
		_ = print_check_row(ctx, false, fmt.tprintf("Too big to check here: over %dM triangles", PRINT_CHECK_MAX / 3_000_000), w)
		return
	}
	ui.begin(ctx, "print checks", {direction = .Column, gap = 2, width = w})
	switch {
	case c.bad_edges > 0:
		_ = print_check_row(ctx, false, fmt.tprintf("%d edge%s of more than two faces, or flipped", c.bad_edges, "" if c.bad_edges == 1 else "s"), w)
	case c.inverted:
		_ = print_check_row(ctx, false, "Inside out: the faces point inward", w)
	case c.open_edges > 0:
		_ = print_check_row(ctx, false, fmt.tprintf("Not watertight: %d open edge%s", c.open_edges, "" if c.open_edges == 1 else "s"), w)
	case:
		_ = print_check_row(ctx, true, "Watertight: every edge has two faces", w)
	}
	if c.holes == 0 {
		_ = print_check_row(ctx, true, "No holes", w)
	} else if print_check_row(ctx, false, fmt.tprintf("%d hole%s to close", c.holes, "" if c.holes == 1 else "s"), w, "Repair", command_enabled(app, .Close_Holes, 0)) {
		// Every hole, whatever Close holes leaves open in the Topology section, since a
		// print needs them all shut.
		app.ui.scene_command = {kind = .Repair, repair = .Close_Holes, on = false}
	}
	least := print_wall_least(app)
	mm := c.wall * obj.transform.scale * print_scale(app)
	switch {
	case c.wall <= 0:
		_ = print_check_row(ctx, false, "Thinnest wall: measured once it is watertight", w)
	case mm >= least:
		_ = print_check_row(ctx, true, fmt.tprintf("Thinnest wall %s mm, above %s mm", print_number(mm), print_number(least)), w)
	case:
		_ = print_check_row(ctx, false, fmt.tprintf("Thinnest wall %s mm, under %s mm", print_number(mm), print_number(least)), w)
	}
	bed := print_bed(app)
	bed_text := fmt.tprintf("%s × %s × %s mm", print_number(bed[0]), print_number(bed[1]), print_number(bed[2]))
	if print_fits_bed(print_size_of(app, objs) if len(objs) > 0 else print_size_mm(app, obj), bed) {
		_ = print_check_row(ctx, true, fmt.tprintf("Fits a %s bed", bed_text), w)
	} else {
		_ = print_check_row(ctx, false, fmt.tprintf("Too big for a %s bed", bed_text), w)
	}
	ui.end(ctx)
	ui.paragraph(ctx, "The bed and the least wall are in Settings > Files > 3D printer.", w, t.text_tertiary)
}

// One check: a tick or a warning, its text, and a button when it has one. True when the
// button is tapped.
@(private = "file")
print_check_row :: proc(ctx: ^ui.Context, ok: bool, text: string, w: f32, button := "", enabled := true, waiting := false) -> bool {
	t := ctx.theme
	ui.begin(ctx, fmt.tprintf("print check %s", text), {direction = .Row, center = true, gap = 8, width = w})
	ROW_H :: 30
	mark := ui.place(ctx, {t.icon_small, ROW_H})
	glyph, tint := (ICON_CHECK_OK if ok else ICON_CHECK_WARN), (t.success if ok else t.warning)
	if waiting do glyph, tint = ICON_CHECK_WAIT, t.text_tertiary
	ui.icon(ctx, glyph, {mark.x + mark.w * 0.5, mark.y + mark.h * 0.5}, t.icon_small, tint)
	BUTTON_W :: 76
	room := w - mark.w - 8 - (BUTTON_W + 8 if button != "" else 0)
	r := ui.place(ctx, {room, ROW_H})
	ui.text(ctx, ui.text_fit(ctx, text, t.small_size, r.w), r.x, r.y + r.h * 0.5, t.small_size, t.text if ok else t.text_secondary)
	pressed := false
	if button != "" do pressed = ui.button(ctx, fmt.tprintf("%s##%s", button, text), .Bordered, width = BUTTON_W, enabled = enabled)
	ui.end(ctx)
	return pressed
}

// Lucide's circle-check, triangle-alert and hourglass.
@(private = "file")
ICON_CHECK_OK :: rune(0xe226)
@(private = "file")
ICON_CHECK_WAIT :: rune(0xe296)
@(private = "file")
ICON_CHECK_WARN :: rune(0xe193)
