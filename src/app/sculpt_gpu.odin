package main

import "core:slice"

import "../geom"
import "../render"
import "../sculpt"

// Sculpting on the GPU (README "Sculpt on the GPU"): the app's side of sculpt.Stroke_Gpu.
// The sculptor asks here, at a stroke's first dab, how much of the stroke the GPU takes:
// its dabs and normals, or its normals alone. Each flush of such a stroke hands its dab
// records and its vertex ranges here, and the frame dispatches the kernels for them once
// the positions the CPU moved are uploaded (frame_step) and submits the frame, whose
// ticket says when their readback is in, whose landing refits the sculptor's bounds. The switch is
// Stats > Drawing's Sculpt on the GPU (--gpu-sculpt for one run), off until the kernels
// cover a stroke's whole work.

// Sets the sculptor's callbacks once, at start-up.
sculpt_gpu_install :: proc(app: ^App) {
	sculpt.stroke_gpu = {data = app, begin = sculpt_gpu_begin, dabs = sculpt_gpu_dabs, normals = sculpt_gpu_normals, sync = sculpt_gpu_sync, pending = sculpt_gpu_pending, normals_back = sculpt_gpu_normals_back, normals_now = sculpt_gpu_normals_now}
}

// The object and level sculpted by `s`, and the GPU buffers that draw it: the current
// level or the HD window of one of the scene's objects. Nil for a sculptor the scene
// does not draw (a long job's, a test's).
@(private = "file")
sculpt_gpu_level :: proc(app: ^App, s: ^sculpt.Sculptor) -> (obj: ^Object, lv: ^sculpt.Level, gpu: ^render.Mesh_Buffers) {
	for o in app.scene.objects {
		// An object freed before this one in scene_destroy has no levels left, and each
		// level's sculptor syncs here as it is freed.
		if o.voxel != nil || len(o.levels.levels) == 0 do continue
		if current := sculpt.levels_current(&o.levels); &current.sculptor == s do return o, current, &o.gpu[o.levels.current]
		if window := o.levels.hd.window; window != nil && &window.sculptor == s do return o, window, &o.hd_gpu
	}
	return nil, nil, nil
}

// The sculptor a readback landed for, by its GPU buffers.
@(private = "file")
sculpt_gpu_sculptor :: proc(app: ^App, gpu: ^render.Mesh_Buffers) -> ^sculpt.Sculptor {
	for o in app.scene.objects {
		if o.voxel != nil || len(o.levels.levels) == 0 do continue
		if &o.gpu[o.levels.current] == gpu do return &sculpt.levels_current(&o.levels).sculptor
		if window := o.levels.hd.window; window != nil && &o.hd_gpu == gpu do return &window.sculptor
	}
	return nil
}

// Uploads the next slice of the lookup the kernels read for a level of the selected
// object (render.sculpt_gpu_prepare), so the first stroke on it finds the lookup on the
// GPU rather than waiting seconds for 700 MB at 25M; whether more is to come. Nothing
// goes up with the switch off, nor for a level whose strokes all stay on the CPU (the
// conditions sculpt_gpu_wanted reads before the brush), nor for the level around an HD
// window, which brushes do not reach while it is open (its lookup is given back unless a
// stroke took it, sculpt_gpu_unselected); the frame calls it only while no stroke is
// under way.
sculpt_gpu_prepare_level :: proc(app: ^App, cmd: render.Cmd, obj: ^Object, lv: ^sculpt.Level, gpu: ^render.Mesh_Buffers) -> (waiting: bool) {
	if !app.gpu_sculpt || !render.caps(&app.renderer).gpu_sculpt || app.renderer.sculpt_gpu.failed do return false
	if window := obj.levels.hd.window; window != nil && lv != window {
		render.sculpt_gpu_unselected(&app.renderer, gpu)
		return false
	}
	s := &lv.sculptor
	if object_dynamic(obj) || sculpt.sculptor_skin(s) != nil || sculpt.sculptor_hidden_count(s) > 0 do return false
	if !gpu.storage || gpu.vertex_capacity != u32(len(lv.mesh.positions)) || gpu.index_count != u32(len(lv.mesh.indices)) do return false
	return render.sculpt_gpu_prepare(&app.renderer, cmd, gpu, s.faces, sculpt.sculptor_gpu_shared(s)) == .Uploading
}

// How much of this stroke the GPU takes: with the switch on, for a brush that moves the
// surface (a mask or paint stroke moves nothing, and its uploads carry the mask), on a
// level with no dynamic topology, detail skin or hidden triangles (which the GPU's
// triangles leave out), whose buffers the kernels can read, and only once the mesh's
// lookup is on the GPU: its normals; and its dabs too for a stroke that lays dabs along
// its path (Drag rectangle, Drag dot and a straight line put the stroke back every
// frame, which the GPU's copy would not follow), on the current level or an HD window
// (whose fade toward its border the kernels read as they read the mask). The sculptor
// narrows Dabs to Normals for a brush its kernels do not lay.
@(private = "file")
sculpt_gpu_begin :: proc(data: rawptr, s: ^sculpt.Sculptor, brush: sculpt.Brush) -> sculpt.Gpu_Take {
	app := cast(^App)data
	obj, lv, gpu := sculpt_gpu_level(app, s)
	if obj == nil do return .None // a brush preview's or a job's sculptor: not drawn, not counted
	take := sculpt_gpu_wanted(app, obj, lv, gpu, s, brush)
	stats := &app.renderer.sculpt_gpu.stats
	if take != .None do stats.strokes_gpu += 1
	else do stats.strokes_cpu += 1
	if take == .Dabs do stats.strokes_dabs += 1
	return take
}

@(private = "file")
sculpt_gpu_wanted :: proc(app: ^App, obj: ^Object, lv: ^sculpt.Level, gpu: ^render.Mesh_Buffers, s: ^sculpt.Sculptor, brush: sculpt.Brush) -> sculpt.Gpu_Take {
	if !app.gpu_sculpt || !render.caps(&app.renderer).gpu_sculpt || app.renderer.sculpt_gpu.failed do return .None
	if brush.kind == .Mask || brush.channel != .Sculpt do return .None
	if object_dynamic(obj) || sculpt.sculptor_skin(s) != nil || sculpt.sculptor_hidden_count(s) > 0 do return .None
	if !gpu.storage || gpu.vertex_capacity != u32(len(lv.mesh.positions)) || gpu.index_count != u32(len(lv.mesh.indices)) do return .None
	if !render.sculpt_gpu_begin(&app.renderer, gpu, s.faces, sculpt.sculptor_gpu_shared(s)) do return .None
	st := &app.stroke
	// Physics writes the positions on the CPU after the dabs, so the GPU takes only normals.
	if st.physics do return .Normals
	if st.mode == .Drag_Rect || st.mode == .Drag_Dot || st.line do return .Normals
	return .Dabs
}

// Queues a flush's dab records for the frame's dispatch, translated for the renderer;
// false where the GPU has refused something since the stroke began, which gives them and
// the rest of the stroke to the CPU.
@(private = "file")
sculpt_gpu_dabs :: proc(data: rawptr, s: ^sculpt.Sculptor, dabs: []sculpt.Gpu_Dab) -> bool {
	app := cast(^App)data
	_, _, gpu := sculpt_gpu_level(app, s)
	if gpu == nil || app.renderer.sculpt_gpu.failed || gpu.sculpt.failed do return false
	out, ok := sculpt_gpu_translate(dabs)
	if !ok do return false
	render.sculpt_gpu_queue_dabs(gpu, out)
	return true
}

// The sculptor's dab records as the renderer takes them, in temp memory; false for a kind
// the kernels do not lay.
sculpt_gpu_translate :: proc(dabs: []sculpt.Gpu_Dab) -> (out: []render.Sculpt_Dab, ok: bool) {
	out = make([]render.Sculpt_Dab, len(dabs), context.temp_allocator)
	for d, i in dabs {
		kind: render.Sculpt_Dab_Kind
		#partial switch d.kind {
		case .Draw:    kind = .Draw
		case .Inflate: kind = .Inflate
		case .Clay:    kind = .Clay
		case .Flatten: kind = .Flatten
		case .Pinch:   kind = .Pinch
		case .Crease:  kind = .Crease
		case .Smooth:  kind = .Smooth
		case:          return nil, false
		}
		out[i] = {
			kind         = kind,
			center       = d.center,
			r2           = d.r2,
			inv_r2       = d.inv_r2,
			inv_sample2  = d.inv_sample2,
			amount       = d.amount,
			strength     = d.strength,
			radius       = d.radius,
			plane_offset = d.plane_offset,
			tilt         = d.tilt,
			view         = d.view,
			facing       = d.facing,
			plane_short  = d.plane_short,
			rates        = d.rates,
			passes       = d.passes,
			relax        = d.smooth_mode == .Relax,
			valleys      = d.smooth_only == .Valleys,
			peaks        = d.smooth_only == .Peaks,
			once         = d.once,
			stroke       = d.stroke,
			masked       = d.masked,
			faded        = d.faded,
			alpha        = d.alpha,
			alpha_size   = d.alpha_size,
			alpha_up     = d.alpha_up,
			alpha_mirror = d.alpha_mirror,
			falloff      = d.falloff,
			ranges       = d.ranges,
		}
	}
	return out, true
}

// Queues a flush's ranges for the frame's dispatch, their positions (and the stroke
// heights the dabs keep) read back too where the stroke's dabs run on the GPU; false
// where the GPU has refused something since the stroke began, which gives the rest of the
// stroke to the CPU.
@(private = "file")
sculpt_gpu_normals :: proc(data: rawptr, s: ^sculpt.Sculptor, ranges: []sculpt.Vertex_Range, last: bool) -> bool {
	app := cast(^App)data
	_, lv, gpu := sculpt_gpu_level(app, s)
	if gpu == nil || app.renderer.sculpt_gpu.failed || gpu.sculpt.failed do return false
	positions: []geom.Vec3
	heights: []render.Sculpt_Height
	if sculpt.sculptor_positions_on_gpu(s) {
		positions = lv.mesh.positions[:]
		// The same bytes: the stroke's number, then the height.
		heights = slice.reinterpret([]render.Sculpt_Height, sculpt.sculptor_gpu_heights(s))
	}
	// The same bytes: a node's own vertices and its shared ones.
	nodes: []render.Sculpt_Node
	if positions != nil do nodes = slice.reinterpret([]render.Sculpt_Node, sculpt.sculptor_range_gpu_nodes(s, ranges))
	render.sculpt_gpu_queue(gpu, ranges, nodes, lv.mesh.normals[:], positions, heights, last)
	return true
}

// Reads the GPU's normals of `ranges` back with this frame's readbacks.
@(private = "file")
sculpt_gpu_normals_back :: proc(data: rawptr, s: ^sculpt.Sculptor, ranges: []sculpt.Vertex_Range) -> bool {
	app := cast(^App)data
	_, lv, gpu := sculpt_gpu_level(app, s)
	if gpu == nil || app.renderer.sculpt_gpu.failed do return false
	render.sculpt_gpu_queue_back(gpu, ranges, lv.mesh.normals[:])
	return true
}

// Reads them back now, waiting for the GPU.
@(private = "file")
sculpt_gpu_normals_now :: proc(data: rawptr, s: ^sculpt.Sculptor, ranges: []sculpt.Vertex_Range) -> bool {
	app := cast(^App)data
	_, lv, gpu := sculpt_gpu_level(app, s)
	if gpu == nil || app.renderer.sculpt_gpu.failed do return false
	return render.sculpt_gpu_read_normals(&app.renderer, gpu, ranges, lv.mesh.normals[:])
}

// Waits for the mesh's submitted readbacks and lands them, and refits the bounds of
// whatever positions landed (this mesh's or another's, since the slots land in order).
@(private = "file")
sculpt_gpu_sync :: proc(data: rawptr, s: ^sculpt.Sculptor) -> bool {
	app := cast(^App)data
	_, _, gpu := sculpt_gpu_level(app, s)
	if gpu == nil do return true
	exact := render.sculpt_gpu_sync(&app.renderer, gpu)
	sculpt_gpu_landed(app)
	return exact
}

// Whether a readback of the mesh is on its way, not yet landed (render.sculpt_gpu_pending).
@(private = "file")
sculpt_gpu_pending :: proc(data: rawptr, s: ^sculpt.Sculptor) -> bool {
	app := cast(^App)data
	_, _, gpu := sculpt_gpu_level(app, s)
	return gpu != nil && render.sculpt_gpu_pending(&app.renderer, gpu)
}

// Refits the sculptors' bounds for every readback of positions that landed since the
// last call (sculpt.sculptor_positions_landed): after the frame's start and after a sync.
sculpt_gpu_landed :: proc(app: ^App) {
	for l in render.sculpt_gpu_landed(&app.renderer) {
		if s := sculpt_gpu_sculptor(app, l.mesh); s != nil do sculpt.sculptor_positions_landed(s, l.ranges, slice.reinterpret([]sculpt.Gpu_Node, l.nodes), l.bounds)
	}
	render.sculpt_gpu_landed_clear(&app.renderer)
}

// Brings every level of the object up to date with the GPU's positions and normals,
// before anything copies or writes the object (a snapshot, a save, a command).
object_gpu_sync :: proc(obj: ^Object) {
	if obj.voxel != nil do return
	for lv in obj.levels.levels do _ = sculpt.sculptor_gpu_sync(&lv.sculptor)
	if window := obj.levels.hd.window; window != nil do _ = sculpt.sculptor_gpu_sync(&window.sculptor)
}

// The sculptor the hover preview lays its trial dabs on for `obj`, with the level's mesh
// and the GPU buffers that draw it: the current level, or the HD window while one is
// open, as a stroke would reach. Nil where the GPU would not take the stroke's dabs there
// whatever the brush (sculpt_gpu_wanted's conditions before the brush), or its lookup is
// not up yet.
sculpt_gpu_trial_target :: proc(app: ^App, obj: ^Object) -> (s: ^sculpt.Sculptor, gpu: ^render.Mesh_Buffers) {
	if obj == nil || obj.voxel != nil || len(obj.levels.levels) == 0 do return
	if !app.gpu_sculpt || !render.caps(&app.renderer).gpu_sculpt || app.renderer.sculpt_gpu.failed do return
	lv := sculpt.levels_current(&obj.levels)
	buffers := &obj.gpu[obj.levels.current]
	if window := obj.levels.hd.window; window != nil do lv, buffers = window, &obj.hd_gpu
	ls := &lv.sculptor
	if object_dynamic(obj) || sculpt.sculptor_skin(ls) != nil || sculpt.sculptor_hidden_count(ls) > 0 do return
	if !buffers.storage || buffers.vertex_capacity != u32(len(lv.mesh.positions)) || buffers.index_count != u32(len(lv.mesh.indices)) do return
	if !render.sculpt_gpu_trial_ready(&app.renderer, buffers, ls.faces, sculpt.sculptor_gpu_shared(ls)) do return
	return ls, buffers
}
