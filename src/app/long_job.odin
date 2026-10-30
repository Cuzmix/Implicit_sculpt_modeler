package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"
import "../ui"

// Long jobs (the overhaul's round 3, PR 12): Remesh, Decimate and Retopologize of a big
// object run on a thread of their own, so the frame goes on (the camera turns, the panels
// answer, motion plays) while a pill under the top bar, and the button that started it,
// show a ring filling as the work goes, and Escape or the pill's Cancel stops it. Blender
// keeps drawing through its long operators the same way; ZBrush and Nomad freeze.
//
// The job works on its own copy of the object's triangles, with its own worker pool, and
// touches no object, history or interface: those stay the frame thread's. While it runs
// the scene is held still, so the object it applies to is as it was when it started:
// strokes and every tool's presses on the view, scene commands, undo and redo, the
// commands that edit (all but JOB_ALLOWED_COMMANDS), scripts and file actions wait or are
// refused with a note. When it is done, the next frame's start rebuilds the object as the
// command does when it runs at once, with the same undo step and report. Scripted runs
// and small objects run at once as before, so their results and timings stay as they were.

// Below this many vertices a job is over too soon for a ring to say anything: it runs at
// once, as before.
LONG_JOB_MIN_VERTICES :: 200_000

Long_Job :: struct {
	on:         bool,
	cmd:        Scene_Command,
	id:         int, // the object it applies to
	// What scene_run knew when it started, for the report once it is done (scene_run_finish).
	label:      string, // owned
	named:      bool,
	source:     int,
	start:      time.Tick,
	before:     ^Object_Snapshot, // Remesh, Decimate: the object before, for the swap undo step
	thread:     ^thread.Thread,
	pool:       jobs.Pool, // its own, so the frame thread keeps the app's
	progress:   jobs.Progress,
	done:       bool, // atomic: the thread finished, built or not
	// The thread's input (its own copy) and output.
	input:      geom.Mesh,
	area:       f64,
	bounds:     geom.Aabb,
	mesh:       geom.Mesh,
	error:      f32,
	retopo:     Retopo_Result,
	built:      bool,
	computed:   time.Tick,
	// An interactive run, or --async-jobs; `forced` (--async-jobs) any size of object.
	allowed:    bool,
	forced:     bool,
	refused_at: f64, // the interface's clock when the last "wait" note showed
	// For the exit stats.
	runs:       int,
	cancels:    int,
	ms:         f64,
}

// The commands that may run while a job does: they change how the scene is seen, the
// brush or the panels, never the scene. Any other command waits for the job (its control
// dims, with the reason in its tooltip), so a new command is held back unless listed here.
JOB_ALLOWED_COMMANDS :: bit_set[Command_Id; [4]u64]{
	.Screenshot, .Screenshot_Transparent,
	.Tool_Move, .Tool_Sculpt, .Tool_Curve, .Tool_Insert, .Tool_Model, .Gizmo, .Gizmo_Snap,
	.Brush, .Symmetry_X, .Local_Symmetry, .Radial_Symmetry, .Brush_Add, .Brush_Subtract, .Paint_Channel, .Paint_Toggle,
	.Swap_Colors, .Colors_Card, .Front_Only, .Lock_Plane, .Connected, .Size_Down, .Size_Up, .Strength_Down, .Strength_Up,
	.Brush_Value, .Brush_Reset,
	.Frame_All, .Objects_Card,
	.View_Axis, .Ortho_Toggle, .Focus_Selected, .Reset_Camera, .View_Back, .View_Forward, .Camera_Menu, .Shading_Menu,
	.Wireframe, .Flat_Shading, .Texture_View, .Polygroups, .Live_Occlusion, .Viewport_Look, .Floor_Grid, .Thumbnail,
	.Transparency,
	.Stats, .Inspector, .Show_Section, .Pin_Section, .Panels_Reset, .Focus_Mode, .Inspect_Mode, .View_Pass,
	.View_Pass_Last, .View_Grid, .View_Wipe, .View_Guides, .View_Guides_Reset, .View_Window, .View_Windows_Close,
	.Clean_View, .View_Layout_Menu, .Pass_Menu, .Brush_Picker, .Settings, .Reduce_Motion, .Left_Handed,
	.Command_Palette, .Customise_Bars, .Stack_Density, .Help, .Coach_Tips, .Pie, .Brush_Pie, .Library,
	.Input_Diagnostics, .History_Panel, .Pencil_Preferred, .Pen_As_Empty,
}

// What a job is called while it runs, by its command.
@(private = "file")
JOB_VERBS := #partial [Scene_Command_Kind]string {
	.Remesh   = "Remeshing",
	.Decimate = "Decimating",
	.Retopo   = "Retopologizing",
}

// The commands whose buttons draw the job's ring, by the job's command.
@(private = "file")
JOB_BUTTONS := #partial [Scene_Command_Kind]bit_set[Command_Id; [4]u64] {
	.Remesh   = {.Remesh, .Remesh_To, .Rebuild},
	.Decimate = {.Decimate_To},
	.Retopo   = {.Retopologize},
}

// Whether a job runs, holding the scene still.
long_job_busy :: proc(app: ^App) -> bool {
	return app.long_job.on
}

// Whether command `cmd` on object `obj` goes to a thread of its own rather than running at
// once: in an interactive run (or --async-jobs), on a big object (or any, with
// --async-jobs), and never when what runs it compares the scene before and after within
// the frame (Adjust last, a macro being recorded, a script, a replay, the time-lapse or the
// turntable) or a job already runs.
long_job_async :: proc(app: ^App, obj: ^Object, cmd: Scene_Command) -> bool {
	j := &app.long_job
	if !j.allowed || j.on || cmd.adjust do return false
	if app.macro.recording || app.macro.pending.active || app.script.running do return false
	if replay_busy(app) || app.replay.recording || timeline_busy(app) || app.turntable.on do return false
	return j.forced || object_vertex_count(obj) >= LONG_JOB_MIN_VERTICES
}

// Starts command `cmd` on `obj` on the job's thread, after what the command does first on
// the frame thread: the stroke ends, the object leaves HD (after `before`, the snapshot
// scene_apply took, so the undo step puts HD back too), and the triangles are measured and
// copied. Returns true: only applying can fail.
long_job_start :: proc(app: ^App, cmd: Scene_Command, obj: ^Object, before: ^Object_Snapshot) -> bool {
	j := &app.long_job
	stroke_finish(app)
	object_hd_leave(app, obj)
	j.on, j.cmd, j.id, j.before, j.named = true, cmd, obj.id, before, false
	j.start = time.tick_now()
	j.progress = {}
	sync.atomic_store(&j.done, false)
	j.mesh, j.error, j.retopo, j.built, j.computed = {}, 0, {}, false, {}
	if cmd.kind == .Remesh {
		// Measured on the level as it is, before any compacting, as object_remesh does.
		j.area, j.bounds = geom.mesh_area_bounds(sculpt.levels_current(&obj.levels).mesh, &app.pool)
	}
	if cmd.kind == .Retopo do sculpt.levels_sync(&obj.levels)
	j.input = long_job_copy(obj)
	jobs.pool_init(&j.pool, max(jobs.pool_size(&app.pool) - 2, 1))
	j.thread = thread.create_and_start_with_data(j, long_job_thread, context, .Normal, name = "long job")
	j.runs += 1
	log.infof("long job: %v of %s (%d vertices) on its own thread", cmd.kind, object_label(obj), len(j.input.positions))
	return true
}

// A copy of the triangles of the level `obj` is on, its own: compacted from a dynamic
// layout (as the commands read it), else the level's positions and indices.
@(private = "file")
long_job_copy :: proc(obj: ^Object) -> geom.Mesh {
	if object_dynamic(obj) {
		packed, mask := sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		return packed
	}
	m := object_mesh(obj)
	out: geom.Mesh
	out.positions = make([dynamic]geom.Vec3, len(m.positions))
	out.indices = make([dynamic]u32, len(m.indices))
	copy(out.positions[:], m.positions[:])
	copy(out.indices[:], m.indices[:])
	return out
}

// The job's thread: the command's computing half on the copy, then done.
@(private = "file")
long_job_thread :: proc(data: rawptr) {
	j := cast(^Long_Job)data
	// Temp memory of its own: the context came from the frame loop, whose temp allocator
	// is that thread's.
	arena: runtime.Arena
	context.temp_allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)
	#partial switch j.cmd.kind {
	case .Remesh:
		j.mesh, j.built = geom.remesh_voxel_measured(j.input, j.area, j.bounds, j.cmd.vertices, &j.pool, progress = &j.progress)
	case .Decimate:
		// A closed surface has about two triangles a vertex.
		j.mesh, j.error, j.built = geom.mesh_decimate(j.input, 2 * j.cmd.vertices, &j.pool, progress = &j.progress)
	case .Retopo:
		resize(&j.input.normals, len(j.input.positions))
		geom.mesh_recompute_normals(&j.input)
		j.retopo = retopo_compute(j.input, j.cmd.vertices, &j.pool, &j.progress)
		j.built = j.retopo.built
	}
	free_all(context.temp_allocator)
	j.computed = time.tick_now()
	sync.atomic_store(&j.done, true)
}

// Once a frame, at its start beside the scene commands: a job its thread finished is
// applied (or dropped, when cancelled or nothing came of it). Returns false only on a GPU
// failure, as scene_run does.
long_job_frame :: proc(app: ^App) -> bool {
	j := &app.long_job
	if !j.on || !sync.atomic_load(&j.done) do return true
	long_job_join(j)
	cancelled := jobs.progress_cancelled(&j.progress)
	j.ms = time.duration_milliseconds(time.tick_diff(j.start, j.computed))
	obj := object_by_id(app, j.id)
	cmd, before := j.cmd, j.before
	j.before = nil
	label := j.label
	j.label = ""
	defer delete(label)
	j.on = false
	verb := strings.to_lower(fmt.tprint(cmd.kind), context.temp_allocator)
	if cancelled || !j.built || obj == nil {
		history_snapshot_drop(before)
		geom.mesh_destroy(&j.input)
		geom.mesh_destroy(&j.mesh)
		retopo_result_destroy(&j.retopo)
		switch {
		case cancelled:
			j.cancels += 1
			report(app, nil, {}, "%s cancelled: %s is as it was", strings.to_upper(verb[:1], context.temp_allocator), label if label != "" else "the object")
			log.infof("long job: %s cancelled after %.0f ms", verb, j.ms)
		case obj == nil:
		case cmd.kind == .Remesh:
			log.warn("remesh: the mesh has no volume to remesh")
		case cmd.kind == .Decimate:
			log.warnf("decimate: the object already has %d vertices, no more than %d", object_vertex_count(obj), cmd.vertices)
		case:
			log.warnf("retopologize: %s has too few triangles for %d quads", object_label(obj), cmd.vertices)
		}
		return true
	}
	autosave_settle(app)
	app.sets_lost, app.layers_kept, app.layers_lost = 0, 0, 0
	defer app.sets_lost, app.layers_kept, app.layers_lost = 0, 0, 0
	ok := true
	#partial switch cmd.kind {
	case .Remesh, .Decimate:
		mesh := j.mesh
		j.mesh = {}
		applied := remesh_apply(app, obj, mesh, j.start, j.computed) if cmd.kind == .Remesh else decimate_apply(app, obj, mesh, j.error, len(j.input.positions), j.start, j.computed)
		if !applied {
			// The old mesh is gone; drop the empty object rather than draw nothing.
			history_snapshot_drop(before)
			object_select_id(app, j.id)
			scene_delete_selected(app, undoable = false)
			ok = false
		} else {
			history_record_swap(app, obj.id, before)
		}
	case .Retopo:
		made, built := retopo_apply(app, obj, &j.retopo, j.start)
		if made do history_record_added(app)
		ok = built
	}
	geom.mesh_destroy(&j.input)
	return scene_run_finish(app, cmd, label, j.source, j.start, ok, obj if cmd.kind != .Retopo else selected_object(app))
}

// Whether a job started this frame and scene_run has not yet told it what to report.
long_job_unnamed :: proc(app: ^App) -> bool {
	return app.long_job.on && !app.long_job.named
}

// What scene_run knew of the command a job started for: the object's name (copied),
// its id and when the command began.
long_job_name :: proc(app: ^App, label: string, source: int, start: time.Tick) {
	j := &app.long_job
	j.label, j.source, j.start, j.named = strings.clone(label), source, start, true
}

// Asks the job to stop; it does at its next check, and the next frame drops it.
long_job_cancel :: proc(app: ^App) {
	if app.long_job.on do jobs.progress_cancel(&app.long_job.progress)
}

// Waits for the job's thread and frees its pool.
@(private = "file")
long_job_join :: proc(j: ^Long_Job) {
	if j.thread == nil do return
	thread.join(j.thread)
	thread.destroy(j.thread)
	j.thread = nil
	jobs.pool_destroy(&j.pool)
}

// When the app ends: a job still running stops and everything it held goes.
long_job_stop :: proc(app: ^App) {
	j := &app.long_job
	long_job_cancel(app)
	long_job_join(j)
	history_snapshot_drop(j.before)
	geom.mesh_destroy(&j.input)
	geom.mesh_destroy(&j.mesh)
	retopo_result_destroy(&j.retopo)
	delete(j.label)
	j.on, j.before, j.label = false, nil, ""
}

// Says, at most once a second, that what was tried waits for the job.
long_job_refuse :: proc(app: ^App) {
	j := &app.long_job
	now := app.kit.ctx.time
	if j.refused_at != 0 && now - j.refused_at < 1 do return
	j.refused_at = now
	report(app, nil, {.Warning}, "%s", long_job_reason(app))
}

// Why a command cannot run while the job does, for a note or a dimmed control's tooltip.
long_job_reason :: proc(app: ^App) -> string {
	verb := strings.to_lower(fmt.tprint(app.long_job.cmd.kind), context.temp_allocator)
	return fmt.tprintf("Wait for the %s to finish, or cancel it (Esc)", verb)
}

// Whether command `id` waits for the job.
long_job_holds :: proc(app: ^App, id: Command_Id) -> bool {
	return app.long_job.on && id not_in JOB_ALLOWED_COMMANDS
}

// How far the job has come, 0 to 1.
long_job_progress :: proc(app: ^App) -> f32 {
	return jobs.progress_get(&app.long_job.progress) if app.long_job.on else 0
}

// A ring round `r` filling with the job's progress, when command `id` started one of its
// kind: a button that started the job keeps showing what it does.
job_ring :: proc(app: ^App, id: Command_Id, r: ui.Rect) {
	j := &app.long_job
	if !j.on || id not_in JOB_BUTTONS[j.cmd.kind] do return
	center := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	draw_progress_ring(&app.kit.ctx, center, min(r.w, r.h) * 0.5 - 2, long_job_progress(app), 2.5)
}

// A ring at `center` of `radius` (points) filled clockwise from the top by `share`, over
// its track.
draw_progress_ring :: proc(ctx: ^ui.Context, center: [2]f32, radius, share, width: f32) {
	t := ctx.theme
	ui.stroke_circle(ctx, center, radius, t.track, width)
	n := max(int(clamp(share, 0, 1) * 64), 1)
	if share <= 0 do return
	points := make([][2]f32, n + 1, context.temp_allocator)
	for &q, i in points {
		a := -math.PI / 2 + 2 * math.PI * clamp(share, 0, 1) * f32(i) / f32(n)
		q = center + radius * [2]f32{math.cos(a), math.sin(a)}
	}
	ui.polyline(ctx, points, t.accent, width)
}

// The pill under the top bar while a job runs: its ring, what runs, how far, and Cancel.
kit_job_pill :: proc(app: ^App) {
	j := &app.long_job
	if !j.on do return
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	size, _ := ui.prev_layout(ctx, "job pill")
	if size == {} do size = {320, t.target + 8}
	area := ui.safe_area(ctx)
	pos := [2]f32{area.x + (area.w - size.x) * 0.5, area.y + kit_top() + 12}
	ui.begin_at(ctx, "job pill", pos, {direction = .Row, gap = 10, padding = 6, radius = t.radius_large + 4, background = .Panel, center = true})
	r := ui.place(ctx, {28, 28})
	share := long_job_progress(app)
	draw_progress_ring(ctx, {r.x + 14, r.y + 14}, 11, share, 3)
	name := j.label if j.label != "" else "the object"
	ui.label(ctx, fmt.tprintf("%s %s", JOB_VERBS[j.cmd.kind], name), t.small_size, t.text, .Semibold)
	ui.label(ctx, fmt.tprintf("%d%%", int(share * 100)), t.small_size, t.text_secondary)
	if ui.button(ctx, "Cancel", .Light, glyph = ui.ICON_CLOSE, keys = "Escape") do long_job_cancel(app)
	ui.end(ctx)
}
