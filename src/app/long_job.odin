package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"
import "../ui"
import "../voxel"
import "../retopo"

// Long jobs (the overhaul's round 3, PR 12): Remesh, Decimate, Quad Remesh, Subdivide,
// Convert to mesh, Convert to voxels and Res+/Res− of a big object, and every Import, run
// on a thread of their own, so the frame goes on (the camera turns, the panels
// answer, motion plays) while a pill under the top bar, and the button that started it,
// show a ring filling as the work goes, and Escape or the pill's Cancel stops it. Blender
// keeps drawing through its long operators the same way; ZBrush and Nomad freeze.
//
// The job works on its own copy of the object's triangles (Subdivide and the voxel jobs
// only read the object's levels or clay, which the scene holding still keeps as they are),
// with its own worker pool, and changes no object, history or interface: those stay the
// frame thread's. A job that makes a new mesh also prepares it for sculpting there
// (long_job_prepare), so only the upload is left for the frame. While it runs the scene is
// held still, so the object it applies to is as it was when it started:
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
	object:     ^Object, // that object, which Subdivide and the voxel jobs read from the thread
	// What scene_run knew when it started, for the report once it is done (scene_run_finish).
	label:      string, // owned
	named:      bool,
	source:     int,
	start:      time.Tick,
	before:     ^Object_Snapshot, // the object before, for the swap undo step (none for Retopo, nor for a Subdivide without layers)
	thread:     ^thread.Thread,
	pool:       jobs.Pool, // its own, so the frame thread keeps the app's
	progress:   jobs.Progress,
	done:       bool, // atomic: the thread finished, built or not
	// The thread's input (its own copy, for the jobs that read a mesh) and output.
	input:      geom.Mesh,
	area:       f64,
	bounds:     geom.Aabb,
	mesh:       geom.Mesh,
	levels:     sculpt.Levels, // made from `mesh` when `prepared`
	prepared:   bool,
	error:      f32,
	unmirrored: string, // Decimate: why the symmetry asked was not kept (a literal)
	retopo:     retopo.Result,
	// Remesh and Decimate: the old polypaint and polygroups copied with the input when
	// their options carry them (Decimate: and the mask that steers it), what the remesh
	// reported and the surface the new mesh takes from them.
	color:      []sculpt.Color,
	groups:     []u16,
	mask:       []u8,
	remesh:     geom.Remesh_Report,
	surface:    Surface,
	level:      ^sculpt.Level, // Subdivide's new level
	layers:     int, // Subdivide: the top level's sculpt layers, which move up with it
	voxels:     ^Voxel_Part, // Convert to voxels' clay
	clay:       voxel.Clay, // Res+ and Res−' clay
	masked:     bool, // Convert to mesh: the clay has a mask, whose `values` come with the mesh
	values:     []u8,
	built:      bool,
	computed:   time.Tick,
	// An interactive run, or --async-jobs; `forced` (--async-jobs) any size of object.
	allowed:    bool,
	forced:     bool,
	refused_at: f64, // the interface's clock when the last "wait" note showed
	// Import (cmd.kind .None): the file, and what reading and preparing it made.
	importing:  bool,
	path:       string, // owned
	imported:   Mesh_Import,
	note:       string, // owned: the import's note
	warning:    bool,
	// For the exit stats.
	runs:       int,
	cancels:    int,
	ms:         f64,
}

// The commands that may run while a job does: they change how the scene is seen, the
// brush or the panels, never the scene. Any other command waits for the job (its control
// dims, with the reason in its tooltip), so a new command is held back unless listed here.
JOB_ALLOWED_COMMANDS :: Command_Set{
	.Screenshot, .Screenshot_Transparent,
	.Tool_Move, .Tool_Sculpt, .Tool_Curve, .Tool_Insert, .Tool_Model, .Gizmo, .Gizmo_Snap,
	.Brush, .Symmetry_X, .Local_Symmetry, .Radial_Symmetry, .Brush_Add, .Brush_Subtract, .Paint_Channel, .Paint_Toggle,
	.Swap_Colors, .Colors_Card, .Front_Only, .Lock_Plane, .Connected, .Size_Down, .Size_Up, .Strength_Down, .Strength_Up,
	.Brush_Value, .Brush_Reset,
	.Frame_All, .Objects_Card,
	.View_Axis, .Ortho_Toggle, .Focus_Selected, .Reset_Camera, .View_Back, .View_Forward, .Camera_Menu, .Shading_Menu,
	.Wireframe, .Flat_Shading, .Texture_View, .Polygroups, .Live_Occlusion, .Shading_Mode, .Solid_Lighting, .Floor_Grid, .Thumbnail,
	.Transparency,
	.Stats, .Inspector, .Show_Section, .Pin_Section, .Panels_Reset, .Focus_Mode, .Inspect_Mode, .View_Pass,
	.View_Pass_Last, .View_Grid, .View_Wipe, .View_Guides, .View_Guides_Reset, .View_Window, .View_Windows_Close,
	.Clean_View, .View_Layout_Menu, .Pass_Menu, .Brush_Picker, .Settings, .Reduce_Motion, .Left_Handed,
	.Command_Palette, .Customise_Bars, .Stack_Density, .Help, .Coach_Tips, .Name_Controls, .Take_Tour, .Pie, .Brush_Pie, .Library,
	.Input_Diagnostics, .History_Panel, .Pencil_Preferred, .Pen_As_Empty,
}

// What a job is called while it runs, and what it is, by its command.
@(private = "file")
JOB_VERBS := #partial [Scene_Command_Kind]string {
	.Remesh         = "Remeshing",
	.Decimate       = "Decimating",
	.Retopo         = "Quad remeshing",
	.Subdivide      = "Subdividing",
	.Voxel_To_Mesh  = "Converting to a mesh:",
	.Mesh_To_Voxels = "Converting to voxels:",
	.Voxel_Resample = "Resampling",
}

@(private = "file")
JOB_NOUNS := #partial [Scene_Command_Kind]string {
	.Remesh         = "remesh",
	.Decimate       = "decimation",
	.Retopo         = "quad remesh",
	.Subdivide      = "subdivision",
	.Voxel_To_Mesh  = "conversion",
	.Mesh_To_Voxels = "conversion",
	.Voxel_Resample = "resampling",
}

// What an import is called while it runs, and what it is.
@(private = "file")
IMPORT_VERB :: "Importing"
@(private = "file")
IMPORT_NOUN :: "import"

// The share of an import that reading and parsing the file takes, at a few million
// vertices; preparing its parts for sculpting is the rest.
@(private = "file")
IMPORT_READ_SHARE :: f32(0.45)
// ...of which reading the file's bytes takes this much.
@(private = "file")
IMPORT_FILE_SHARE :: f32(0.03)

@(private = "file")
job_verb :: proc(j: ^Long_Job) -> string {return IMPORT_VERB if j.importing else JOB_VERBS[j.cmd.kind]}

@(private = "file")
job_noun :: proc(j: ^Long_Job) -> string {return IMPORT_NOUN if j.importing else JOB_NOUNS[j.cmd.kind]}

// The commands whose buttons draw the job's ring, by the job's command.
@(private = "file")
JOB_BUTTONS := #partial [Scene_Command_Kind]Command_Set {
	.Remesh         = {.Remesh, .Remesh_To, .Rebuild},
	.Decimate       = {.Decimate_To},
	.Retopo         = {.Retopologize},
	.Subdivide      = {.Subdivide},
	.Voxel_To_Mesh  = {.Convert_To_Mesh},
	.Mesh_To_Voxels = {.Convert_To_Voxels},
	.Voxel_Resample = {.Voxel_Res_Up, .Voxel_Res_Down},
}

// The shares of a mesh-making job that its computing half takes, at 2M to 4M vertices in a
// release build;
// preparing the new mesh for sculpting (long_job_prepare) is the rest.
@(private = "file")
JOB_COMPUTE_SHARE := #partial [Scene_Command_Kind]f32 {
	.Remesh        = 0.60,
	.Decimate      = 0.90,
	.Voxel_To_Mesh = 0.42,
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
	// A Remesh or Quad Remesh of a small object can make a large one: what it makes counts
	// too, since getting that ready to sculpt and drawn is most of the wait.
	return j.forced || max(object_vertex_count(obj), cmd.vertices) >= LONG_JOB_MIN_VERTICES
}

// Starts command `cmd` on `obj` on the job's thread, after what the command does first on
// the frame thread: the stroke ends, the object leaves HD (after `before`, the snapshot
// scene_apply took, so the undo step puts HD back too), and the triangles are measured and
// copied, the levels synced or the clay flushed. Returns true: only applying can fail.
long_job_start :: proc(app: ^App, cmd: Scene_Command, obj: ^Object, before: ^Object_Snapshot) -> bool {
	j := &app.long_job
	stroke_finish(app)
	object_hd_leave(app, obj)
	j.on, j.cmd, j.id, j.object, j.before, j.named, j.importing = true, cmd, obj.id, obj, before, false, false
	j.start = time.tick_now()
	j.progress = {}
	sync.atomic_store(&j.done, false)
	j.mesh, j.error, j.retopo, j.built, j.computed = {}, 0, {}, false, {}
	j.level, j.layers, j.voxels, j.clay, j.masked, j.values = nil, 0, nil, {}, false, nil
	#partial switch cmd.kind {
	case .Remesh:
		// Measured on the level as it is, before any compacting, as object_remesh does.
		j.area, j.bounds = geom.mesh_area_bounds(sculpt.levels_current(&obj.levels).mesh, &app.pool)
		// The dynamic layout's compacting renumbers the triangles, and it has no groups.
		if s := object_sculptor(obj); !object_dynamic(obj) {
			if cmd.remesh.keep_detail && s.color != nil do j.color = slice.clone(s.color)
			if (cmd.remesh.keep_detail || cmd.remesh.groups) && sculpt.sculptor_has_groups(s) do j.groups = slice.clone(sculpt.sculptor_groups(s))
		}
	case .Decimate:
		src := decimate_source(obj, cmd.decimate)
		j.input, j.color, j.groups, j.mask = src.mesh, src.color, src.groups, src.mask
	case .Retopo:
		sculpt.levels_sync(&obj.levels)
	case .Subdivide:
		sculpt.levels_sync(&obj.levels)
		levels := &obj.levels
		j.layers = len(levels.levels[len(levels.levels) - 1].sculptor.layers.list)
	case .Voxel_To_Mesh:
		// The thread meshes the clay as it is now without flushing it, so it only reads
		// it; what the flush meshed here goes to the GPU whole with the next upload.
		clay := &obj.voxel.clay
		if f := voxel.clay_flush(clay); len(f.ranges) > 0 || len(f.indices) > 0 || f.regrow do clay.surface.regrow = true
		j.masked = voxel.clay_has_mask(clay)
	}
	if cmd.kind == .Remesh || cmd.kind == .Retopo || cmd.kind == .Mesh_To_Voxels do j.input = long_job_copy(obj)
	jobs.pool_init(&j.pool, max(jobs.pool_size(&app.pool) - 2, 1))
	j.thread = thread.create_and_start_with_data(j, long_job_thread, context, .Normal, name = "long job")
	j.runs += 1
	log.infof("long job: %v of %s (%d vertices) on its own thread", cmd.kind, object_label(obj), object_vertex_count(obj))
	return true
}

// Whether an import of the file at `path` goes to the job's thread: in an interactive run
// (or --async-jobs), whatever the file's size, as reading even a small one can wait on a
// slow disk; never when a script, macro, replay or recording compares the scene before and
// after within the frame, or a job already runs.
import_job_async :: proc(app: ^App) -> bool {
	j := &app.long_job
	if !j.allowed || j.on do return false
	if app.macro.recording || app.macro.pending.active || app.script.running do return false
	return !(replay_busy(app) || app.replay.recording || timeline_busy(app) || app.turntable.on)
}

// Starts importing the file at `path` on the job's thread: reading, parsing, cleaning and
// preparing its parts for sculpting there, so the frame goes on and the pill shows how far
// it came; the frame then uploads the parts and adds them as scene_import does.
import_job_start :: proc(app: ^App, path: string) {
	j := &app.long_job
	stroke_finish(app)
	j.on, j.cmd, j.id, j.object, j.before, j.importing = true, {}, 0, nil, nil, true
	j.path = strings.clone(path)
	j.label, j.named, j.source = strings.clone(filepath.base(path)), true, 0
	j.start = time.tick_now()
	j.progress = {}
	sync.atomic_store(&j.done, false)
	j.built, j.computed, j.imported, j.note, j.warning = false, {}, {}, "", false
	jobs.pool_init(&j.pool, max(jobs.pool_size(&app.pool) - 2, 1))
	j.thread = thread.create_and_start_with_data(j, long_job_thread, context, .Normal, name = "import")
	j.runs += 1
	log.infof("long job: import of %s on its own thread", j.label)
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
	share := JOB_COMPUTE_SHARE[j.cmd.kind]
	jobs.progress_set(&j.progress, 0, 1, 0)
	if j.importing {
		j.imported, j.note, j.warning, j.built = mesh_import_load(j.path, fmt.tprintf("Imported %s", j.label), &j.pool, &j.progress, IMPORT_FILE_SHARE)
		jobs.progress_set(&j.progress, 0, 1, IMPORT_READ_SHARE)
		if j.built do mesh_import_prepare(&j.imported, &j.pool, &j.progress, {IMPORT_READ_SHARE, 1})
	}
	#partial switch j.cmd.kind {
	case .Remesh:
		j.mesh, j.built = geom.remesh_voxel_measured(j.input, j.area, j.bounds, j.cmd.vertices, &j.pool, progress = &j.progress, share = {0, share}, options = remesh_options(j.cmd.remesh, j.groups), report = &j.remesh)
		if j.built do j.surface = remesh_surface(j.remesh, j.mesh, j.input, j.color, j.groups)
		long_job_prepare(j, normals = false)
	case .Decimate:
		src := Decimate_Source{mesh = j.input, color = j.color, groups = j.groups, mask = j.mask}
		j.mesh, j.error, j.surface, j.built, j.unmirrored = decimate_compute(src, j.cmd.vertices, j.cmd.decimate, &j.pool, &j.progress, {0, share})
		long_job_prepare(j, normals = true)
	case .Retopo:
		resize(&j.input.normals, len(j.input.positions))
		geom.mesh_recompute_normals(&j.input)
		j.retopo = retopo.compute(j.input, j.cmd.vertices, j.cmd.quad, &j.pool, &j.progress)
		j.built = j.retopo.built
	case .Subdivide:
		j.level, j.built = sculpt.levels_subdivide_build(&j.object.levels, &j.pool, &j.progress)
	case .Mesh_To_Voxels:
		j.voxels = voxels_compute(j.input, j.cmd.voxels, &j.pool, &j.progress)
		j.built = j.voxels != nil
	case .Voxel_Resample:
		j.clay, j.built = resample_compute(j.object.voxel, j.cmd.voxels, &j.pool, &j.progress)
	case .Voxel_To_Mesh:
		j.mesh = voxel.clay_to_mesh(&j.object.voxel.clay, mask = &j.values if j.masked else nil, flush = false, pool = &j.pool)
		jobs.progress_set(&j.progress, 0, 1, share)
		j.built = true
		long_job_prepare(j, normals = true)
	}
	free_all(context.temp_allocator)
	j.computed = time.tick_now()
	sync.atomic_store(&j.done, true)
}

// The new mesh made ready to sculpt on the job's thread, as object_build_from would make it
// on the frame's (with `normals` worked out), moving the progress over the rest of the
// job; the levels then own the mesh. Not when nothing was built or the job was cancelled.
@(private = "file")
long_job_prepare :: proc(j: ^Long_Job, normals: bool) {
	if !j.built || jobs.progress_cancelled(&j.progress) do return
	share := [2]f32{JOB_COMPUTE_SHARE[j.cmd.kind], 1}
	if j.surface.color != nil || j.surface.groups != nil || j.remesh.quads != nil {
		// The surface's parts and the quads follow the renumbering onto the level, as
		// object_build_from and remesh_apply take them on the frame thread.
		old_to_new := make([]u32, len(j.mesh.positions))
		defer delete(old_to_new)
		tri_from := make([]u32, len(j.mesh.indices) / 3)
		defer delete(tri_from)
		sculpt.levels_init(&j.levels, j.mesh, &j.pool, old_to_new = old_to_new, tri_from = tri_from, progress = &j.progress, share = share)
		sculpt.levels_take_surface(&j.levels, j.surface.color, j.surface.groups, old_to_new, tri_from)
		if j.remesh.quads != nil do remesh_take_quads(&j.levels, j.remesh.quads, old_to_new, tri_from)
	} else {
		sculpt.levels_init(&j.levels, j.mesh, &j.pool, progress = &j.progress, share = share)
	}
	j.mesh = {}
	if normals do sculpt.sculptor_recompute_all(&sculpt.levels_current(&j.levels).sculptor)
	// The simplified copies too, so the result orbits at full speed from its first frame
	// instead of drawing everything while the frames build them.
	if !jobs.progress_cancelled(&j.progress) do _, _ = sculpt.sculptor_lod_update(&sculpt.levels_current(&j.levels).sculptor, finish = true)
	j.prepared = true
}

// The levels the job prepared, for object_build_from, which takes them; nil when it made
// none.
@(private = "file")
long_job_levels :: proc(j: ^Long_Job) -> ^sculpt.Levels {
	if !j.prepared do return nil
	j.prepared = false
	return &j.levels
}

// Frees whatever the job made or copied that nothing took.
@(private = "file")
long_job_drop :: proc(j: ^Long_Job) {
	geom.mesh_destroy(&j.input)
	geom.mesh_destroy(&j.mesh)
	if j.prepared do sculpt.levels_destroy(&j.levels)
	j.prepared = false
	retopo.result_destroy(&j.retopo)
	delete(j.color)
	delete(j.groups)
	delete(j.mask)
	j.color, j.groups, j.mask = nil, nil, nil
	geom.remesh_report_destroy(&j.remesh)
	surface_free(&j.surface)
	if j.level != nil do sculpt.levels_subdivide_discard(&j.object.levels, j.level)
	j.level = nil
	if j.voxels != nil {
		voxel.clay_destroy(&j.voxels.clay)
		free(j.voxels)
		j.voxels = nil
	}
	if j.cmd.kind == .Voxel_Resample && j.built do voxel.clay_destroy(&j.clay)
	j.clay = {}
	delete(j.values)
	j.values = nil
	mesh_import_free(&j.imported)
	delete(j.path)
	delete(j.note)
	j.path, j.note, j.importing = "", "", false
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
	defer j.object = nil
	noun := job_noun(j)
	if j.importing do return import_job_finish(app, cancelled, label)
	if cancelled || !j.built || obj == nil {
		history_snapshot_drop(before)
		long_job_drop(j)
		switch {
		case cancelled:
			j.cancels += 1
			report(app, nil, {}, "%s%s cancelled: %s is as it was", strings.to_upper(noun[:1], context.temp_allocator), noun[1:], label if label != "" else "the object")
			log.infof("long job: %s cancelled after %.0f ms", noun, j.ms)
		case obj == nil:
		case cmd.kind == .Remesh:
			log.warn("remesh: the mesh has no volume to remesh")
		case cmd.kind == .Decimate:
			log.warnf("decimate: the object already has %d vertices, no more than %d", object_vertex_count(obj), cmd.vertices)
		case cmd.kind == .Subdivide:
			log.warn("subdivide: needs a closed mesh with every edge between two triangles")
		case cmd.kind == .Mesh_To_Voxels:
			log.warn("convert to voxels: the mesh has no volume to voxelise")
		case cmd.kind == .Voxel_Resample:
			log.warn("voxel resolution: the clay reaches too far from the object's middle for the finer lattice")
		case:
			log.warnf("quad remesh: %s has too few triangles for %d quads", object_label(obj), cmd.vertices)
		}
		return true
	}
	autosave_settle(app)
	app.sets_lost, app.layers_kept, app.layers_lost = 0, 0, 0
	defer app.sets_lost, app.layers_kept, app.layers_lost = 0, 0, 0
	ok, applied := true, true
	#partial switch cmd.kind {
	case .Remesh, .Decimate:
		mesh := j.mesh
		j.mesh = {}
		prepared := long_job_levels(j)
		if cmd.kind == .Remesh {
			// Prepared levels already carry the surface.
			applied = remesh_apply(app, obj, mesh, j.start, j.computed, prepared, surface = j.surface if prepared == nil else {}, remeshed = j.remesh, setup = cmd.remesh)
		} else {
			applied = decimate_apply(app, obj, mesh, j.error, len(j.input.positions), j.start, j.computed, prepared, surface = j.surface if prepared == nil else {}, setup = cmd.decimate, unmirrored = j.unmirrored)
		}
	case .Retopo:
		made, built := retopo_apply(app, obj, &j.retopo, j.start)
		if made do history_record_added(app)
		ok = built
	case .Subdivide:
		sculpt.levels_subdivide_add(&obj.levels, j.level, carry_layers = j.layers > 0)
		j.level = nil
		subdivide_record(app, obj, before, j.layers)
		ok = object_show_level(app, obj, j.start)
	case .Mesh_To_Voxels:
		vp := j.voxels
		j.voxels = nil
		applied = voxels_apply(app, obj, vp, j.start)
	case .Voxel_Resample:
		resample_apply(app, obj, j.clay, j.cmd.voxels, j.start)
		j.clay, j.built = {}, false
		history_record_swap(app, obj.id, before)
	case .Voxel_To_Mesh:
		mesh := j.mesh
		j.mesh = {}
		applied = voxel_mesh_apply(app, obj, mesh, j.values, j.start, long_job_levels(j))
	}
	#partial switch cmd.kind {
	case .Remesh, .Decimate, .Mesh_To_Voxels, .Voxel_To_Mesh:
		if !applied {
			// The old mesh or clay is gone; drop the empty object rather than draw nothing.
			history_snapshot_drop(before)
			object_select_id(app, j.id)
			scene_delete_selected(app, undoable = false)
			ok = false
		} else {
			history_record_swap(app, obj.id, before)
		}
	}
	long_job_drop(j)
	// The old mesh's picture, still in the viewport, fades into the new one.
	if ok do cross_fade_start(app, .Mesh_Fade)
	return scene_run_finish(app, cmd, label, j.source, j.start, ok, obj if cmd.kind != .Retopo else selected_object(app))
}

// An import whose thread is done: cancelled, it is dropped with a note; else its note
// shows and its parts become objects, one undo step, as scene_import makes them.
@(private = "file")
import_job_finish :: proc(app: ^App, cancelled: bool, label: string) -> bool {
	j := &app.long_job
	defer long_job_drop(j)
	if cancelled {
		j.cancels += 1
		report(app, nil, {}, "Import of %s cancelled: the scene is as it was", label)
		log.infof("long job: import cancelled after %.0f ms", j.ms)
		return true
	}
	file_note(app, j.warning, "%s", j.note)
	if !j.built do return true
	stem := filepath.stem(j.path)
	if !import_add_parts(app, &j.imported, stem if stem != "" else "Import", next_free_position(app), record = true) do return false
	// After the new objects' stats reset.
	app.stats.file_read_ms, app.stats.file_parse_ms = j.imported.read_ms, j.imported.parse_ms
	cross_fade_start(app, .Mesh_Fade)
	return true
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
	long_job_drop(j)
	delete(j.label)
	j.on, j.before, j.label, j.object = false, nil, "", nil
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
	return fmt.tprintf("Wait for the %s to finish, or cancel it (Esc)", job_noun(&app.long_job))
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
	if !j.on || j.importing || id not_in JOB_BUTTONS[j.cmd.kind] do return
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
	ui.label(ctx, fmt.tprintf("%s %s", job_verb(j), name), t.small_size, t.text, .Semibold)
	ui.label(ctx, fmt.tprintf("%d%%", int(share * 100)), t.small_size, t.text_secondary)
	if ui.button(ctx, "Cancel", .Light, glyph = ui.ICON_CLOSE, keys = "Escape") do long_job_cancel(app)
	ui.end(ctx)
}
