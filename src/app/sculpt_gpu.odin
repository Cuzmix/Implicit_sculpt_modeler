package main

import "../render"
import "../sculpt"

// Sculpting on the GPU (README "Sculpt on the GPU"): the app's side of sculpt.Stroke_Gpu.
// The sculptor asks here, at a stroke's first dab, whether the GPU takes the stroke's
// normals; each flush of such a stroke hands its vertex ranges here, and the frame
// dispatches the kernel for them once the positions are uploaded (frame_step) and submits
// the frame with a fence for their readback. The switch is Stats > Drawing's Sculpt on the
// GPU (--gpu-sculpt for one run), off until the kernels cover a stroke's whole work.

// Sets the sculptor's callbacks once, at start-up.
sculpt_gpu_install :: proc(app: ^App) {
	sculpt.stroke_gpu = {data = app, begin = sculpt_gpu_begin, normals = sculpt_gpu_normals, sync = sculpt_gpu_sync}
}

// The object and level sculpted by `s`, and the GPU buffers that draw it: the current
// level or the HD window of one of the scene's objects. Nil for a sculptor the scene
// does not draw (a long job's, a test's).
@(private = "file")
sculpt_gpu_level :: proc(app: ^App, s: ^sculpt.Sculptor) -> (obj: ^Object, lv: ^sculpt.Level, gpu: ^render.Mesh_Buffers) {
	for o in app.scene.objects {
		if o.voxel != nil do continue
		if current := sculpt.levels_current(&o.levels); &current.sculptor == s do return o, current, &o.gpu[o.levels.current]
		if window := o.levels.hd.window; window != nil && &window.sculptor == s do return o, window, &o.hd_gpu
	}
	return nil, nil, nil
}

// Whether the GPU takes this stroke's normals: with the switch on, for a brush that moves
// the surface (a mask or paint stroke moves nothing, and its uploads carry the mask), on a
// level with no dynamic topology, detail skin or hidden triangles (which the GPU's
// triangles leave out), whose buffers the kernel can read; and only once the mesh's lookup
// is on the GPU.
@(private = "file")
sculpt_gpu_begin :: proc(data: rawptr, s: ^sculpt.Sculptor, brush: sculpt.Brush) -> bool {
	app := cast(^App)data
	obj, lv, gpu := sculpt_gpu_level(app, s)
	if obj == nil do return false // a brush preview's or a job's sculptor: not drawn, not counted
	taken := sculpt_gpu_wanted(app, obj, lv, gpu, s, brush)
	stats := &app.renderer.sculpt_gpu.stats
	if taken do stats.strokes_gpu += 1
	else do stats.strokes_cpu += 1
	return taken
}

@(private = "file")
sculpt_gpu_wanted :: proc(app: ^App, obj: ^Object, lv: ^sculpt.Level, gpu: ^render.Mesh_Buffers, s: ^sculpt.Sculptor, brush: sculpt.Brush) -> bool {
	if !app.gpu_sculpt || !render.caps(&app.renderer).gpu_sculpt || app.renderer.sculpt_gpu.failed do return false
	if brush.kind == .Mask || brush.channel != .Sculpt do return false
	if object_dynamic(obj) || sculpt.sculptor_skin(s) != nil || sculpt.sculptor_hidden_count(s) > 0 do return false
	if !gpu.storage || gpu.vertex_capacity != u32(len(lv.mesh.positions)) || gpu.index_count != u32(len(lv.mesh.indices)) do return false
	return render.sculpt_gpu_begin(&app.renderer, gpu, s.faces)
}

// Queues a flush's ranges for the frame's dispatch; false where the GPU has refused
// something since the stroke began, which gives the rest of the stroke to the CPU.
@(private = "file")
sculpt_gpu_normals :: proc(data: rawptr, s: ^sculpt.Sculptor, ranges: []sculpt.Vertex_Range, last: bool) -> bool {
	app := cast(^App)data
	_, lv, gpu := sculpt_gpu_level(app, s)
	if gpu == nil || app.renderer.sculpt_gpu.failed || gpu.sculpt.failed do return false
	render.sculpt_gpu_queue(gpu, ranges, lv.mesh.normals[:], last)
	return true
}

@(private = "file")
sculpt_gpu_sync :: proc(data: rawptr, s: ^sculpt.Sculptor) {
	app := cast(^App)data
	if _, _, gpu := sculpt_gpu_level(app, s); gpu != nil do render.sculpt_gpu_sync(&app.renderer, gpu)
}

// Brings every level of the object up to date with the GPU's normals, before anything
// copies or writes the object (a snapshot, a save).
object_gpu_sync :: proc(obj: ^Object) {
	if obj.voxel != nil do return
	for lv in obj.levels.levels do sculpt.sculptor_gpu_sync(&lv.sculptor)
	if window := obj.levels.hd.window; window != nil do sculpt.sculptor_gpu_sync(&window.sculptor)
}
