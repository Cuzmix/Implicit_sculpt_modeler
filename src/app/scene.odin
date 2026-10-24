package main

import "core:log"
import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../render"
import "../sculpt"

// Where an object sits in the world. Meshes stay in their own local space; the brush
// works in local space too, so moving an object never touches its vertices.
// Rotation is not supported yet: translation plus uniform scale keeps normals exact.
Transform :: struct {
	position: Vec3,
	scale:    f32,
}

Vec3 :: [3]f32

transform_matrix :: proc(t: Transform) -> render.Mat4 {
	s, p := t.scale, t.position
	return render.Mat4{
		s, 0, 0, p.x,
		0, s, 0, p.y,
		0, 0, s, p.z,
		0, 0, 0, 1,
	}
}

to_local :: #force_inline proc(t: Transform, p: Vec3) -> Vec3 {return (p - t.position) / t.scale}
to_world :: #force_inline proc(t: Transform, p: Vec3) -> Vec3 {return p * t.scale + t.position}

// One sculptable mesh in the scene, with its subdivision levels: only the current
// level is shown and sculpted, or while sculpting HD, a window of the HD level over the
// top level (see object_hd_enter).
Object :: struct {
	id:        int, // shown as "Sphere <id>"; never reused
	transform: Transform,
	levels:    sculpt.Levels,
	// Per level, made the first time the level is shown and kept while it exists. A
	// level's buffers catch up with what changed while it was not current when it is
	// shown again (see object_show_level).
	gpu:       [sculpt.MAX_LEVELS]render.Mesh_Buffers,
	hd_gpu:    render.Mesh_Buffers, // the HD window's, while one is open
}

// The level being sculpted: the HD window while one is open.
object_level :: proc(obj: ^Object) -> ^sculpt.Level {return sculpt.levels_active(&obj.levels)}
object_sculptor :: proc(obj: ^Object) -> ^sculpt.Sculptor {return &object_level(obj).sculptor}
object_mesh :: proc(obj: ^Object) -> ^geom.Mesh {return &object_level(obj).mesh}
object_gpu :: proc(obj: ^Object) -> ^render.Mesh_Buffers {
	if object_in_hd(obj) do return &obj.hd_gpu
	return &obj.gpu[obj.levels.current]
}
object_in_hd :: proc(obj: ^Object) -> bool {return obj.levels.hd.window != nil}

Scene :: struct {
	objects:  [dynamic]^Object,
	selected: int, // index into objects, -1 when nothing is selected
	next_id:  int,
}

// Changes to the object list or the selected object's levels requested by the UI,
// applied at the start of the next frame so no panel ever draws an object (or GPU
// buffer) freed during the same frame.
Scene_Command :: struct {
	kind:     enum u8 {None, Add, Remesh, Delete, Subdivide, Set_Level, Delete_Higher, Delete_Lower, Hd_Enter, Hd_Leave, Hd_Steps, Hd_Delete},
	vertices: int,
	level:    int, // Set_Level; HD steps for Hd_Steps
	at:       [2]f32, // Hd_Enter: the viewport point to open the window around
	size:     [2]f32, // ...in a viewport of this size
}

scene_destroy :: proc(app: ^App) {
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	for obj in app.scene.objects do object_free(app, obj)
	delete(app.scene.objects)
	app.scene = {}
}

selected_object :: proc(app: ^App) -> ^Object {
	s := &app.scene
	if s.selected < 0 || s.selected >= len(s.objects) do return nil
	return s.objects[s.selected]
}

// Builds a sphere of about `vertices` vertices (or an icosphere of `subdiv` levels when
// vertices is 0), prepares it for sculpting, uploads it, and adds it to the scene.
scene_add_sphere :: proc(app: ^App, vertices, subdiv: int, t: Transform) -> bool {
	obj := new(Object)
	obj.transform = t
	if !object_build(app, obj, vertices, subdiv) {
		free(obj)
		return false
	}
	app.scene.next_id += 1
	obj.id = app.scene.next_id
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	return true
}

// Rebuilds the object as an even mesh of about `vertices` vertices that keeps the shape
// of the level it is on, as ZBrush's DynaMesh does (geom.remesh_voxel), keeping its
// transform. Its levels, HD detail, mask and undo history go. Returns false only when
// the old mesh is gone and the new one could not be uploaded.
object_remesh :: proc(app: ^App, obj: ^Object, vertices: int) -> bool {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	mesh, ok := geom.remesh_voxel(object_mesh(obj)^, vertices, &app.pool)
	free_all(context.temp_allocator)
	if !ok {
		log.warn("remesh: the mesh has no volume to remesh")
		return true
	}
	remeshed := time.tick_now()
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	object_release_mesh(app, obj)
	if !object_build_from(app, obj, mesh, remeshed) do return false
	app.stats.remesh_ms = time.duration_milliseconds(time.tick_diff(start, remeshed))
	app.stats.remesh_setup_ms = time.duration_milliseconds(time.tick_since(remeshed))
	log.infof("remesh: %d vertices in %.0f ms, ready in %.0f ms more", geom.mesh_vertex_count(object_mesh(obj)^), app.stats.remesh_ms, app.stats.remesh_setup_ms)
	return true
}

scene_delete_selected :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	ordered_remove(&app.scene.objects, app.scene.selected)
	object_free(app, obj)
	app.scene.selected = min(app.scene.selected, len(app.scene.objects) - 1)
}

// Applies a pending UI command. Returns false only on a fatal GPU failure.
scene_apply :: proc(app: ^App, cmd: Scene_Command) -> bool {
	switch cmd.kind {
	case .None:
	case .Add:
		return scene_add_sphere(app, cmd.vertices, 0, {position = next_free_position(app), scale = 1})
	case .Remesh:
		if obj := selected_object(app); obj != nil {
			if !object_remesh(app, obj, cmd.vertices) {
				// The old mesh is gone; drop the empty object rather than draw nothing.
				scene_delete_selected(app)
				return false
			}
		}
	case .Delete:
		scene_delete_selected(app)
	case .Hd_Enter:
		origin, dir := mouse_ray(app.camera, cmd.at, cmd.size)
		index, hit, ok := scene_raycast(app, origin, dir)
		if !ok {
			log.info("HD: point at an object to sculpt HD around that point")
			return true
		}
		app.scene.selected = index
		return object_hd_enter(app, selected_object(app), to_local(selected_object(app).transform, hit))
	case .Hd_Leave:
		if obj := selected_object(app); obj != nil do object_hd_leave(app, obj)
	case .Hd_Steps, .Hd_Delete:
		obj := selected_object(app)
		if obj == nil do return true
		object_hd_leave(app, obj)
		if cmd.kind == .Hd_Delete {
			sculpt.levels_hd_delete(&obj.levels)
		} else if !sculpt.levels_hd_set_steps(&obj.levels, cmd.level) {
			log.warn("HD: steps change only while no HD detail is stored, on a closed mesh with every edge between two triangles")
		}
	case .Subdivide, .Set_Level, .Delete_Higher, .Delete_Lower:
		obj := selected_object(app)
		if obj == nil do return true
		if cmd.kind == .Delete_Lower && obj.levels.current == 0 do return true
		if cmd.kind == .Delete_Higher && obj.levels.current == len(obj.levels.levels) - 1 do return true
		stroke_finish(app)
		if cmd.kind != .Set_Level do object_hd_leave(app, obj)
		start := time.tick_now()
		levels := &obj.levels
		#partial switch cmd.kind {
		case .Subdivide:
			if _, _, bytes := sculpt.levels_subdivide_estimate(levels); bytes > MAX_SUBDIVIDE_BYTES {
				log.warnf("subdivide: the new level would need about %d MB; the limit is %d MB", bytes >> 20, MAX_SUBDIVIDE_BYTES >> 20)
				return true
			}
			if levels.hd.steps > 0 {
				log.warn("subdivide: delete the HD level first; its detail is tied to the top level as it is")
				return true
			}
			if !sculpt.levels_subdivide(levels) {
				log.warn("subdivide: needs a closed mesh with every edge between two triangles")
				return true
			}
			log.infof("subdivide: level %d has %d vertices, %d triangles", levels.current + 1,
				geom.mesh_vertex_count(object_mesh(obj)^), geom.mesh_triangle_count(object_mesh(obj)^))
		case .Set_Level:
			return object_set_level(app, obj, cmd.level)
		case .Delete_Higher:
			_ = sdl.WaitForGPUIdle(app.renderer.device)
			for i in levels.current + 1 ..< len(levels.levels) do render.mesh_buffers_destroy(&app.renderer, &obj.gpu[i])
			sculpt.levels_delete_higher(levels)
			object_forget_history(app, obj)
		case .Delete_Lower:
			k := levels.current
			_ = sdl.WaitForGPUIdle(app.renderer.device)
			for i in 0 ..< k do render.mesh_buffers_destroy(&app.renderer, &obj.gpu[i])
			sculpt.levels_delete_lower(levels)
			copy(obj.gpu[:], obj.gpu[k:])
			for i in sculpt.MAX_LEVELS - k ..< sculpt.MAX_LEVELS do obj.gpu[i] = {}
			object_forget_history(app, obj)
		}
		return object_show_level(app, obj, start)
	}
	return true
}

// Makes `level` the object's current level, carrying the edits on the one it leaves to
// all the others, after leaving any HD window. Returns false on a GPU failure.
object_set_level :: proc(app: ^App, obj: ^Object, level: int) -> bool {
	object_hd_leave(app, obj)
	if clamp(level, 0, len(obj.levels.levels) - 1) == obj.levels.current do return true
	start := time.tick_now()
	sculpt.levels_set_current(&obj.levels, level)
	return object_show_level(app, obj, start)
}

// Largest new level Subdivide makes, in CPU memory.
MAX_SUBDIVIDE_BYTES :: 12 << 30

// Brings the current level's normals and GPU buffers up to date after it became
// current: uploads what changed while it was not, or everything the first time it is
// shown. `start` is when the level change began, for the stats. Returns false on a GPU
// failure.
object_show_level :: proc(app: ^App, obj: ^Object, start: time.Tick) -> bool {
	synced := time.tick_now()
	defer {
		app.stats.level_sync_ms = time.duration_milliseconds(time.tick_diff(start, synced))
		app.stats.level_show_ms = time.duration_milliseconds(time.tick_since(synced))
	}
	lv := object_level(obj)
	ranges := sculpt.sculptor_flush(&lv.sculptor)
	gpu := object_gpu(obj)
	if gpu.positions == nil {
		ok: bool
		gpu^, ok = render.mesh_buffers_create(&app.renderer, lv.mesh, lv.sculptor.mask)
		return ok
	}
	if len(ranges) == 0 do return true
	cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
	if cmd == nil {
		log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
		return false
	}
	render.mesh_buffers_upload_ranges(&app.renderer, cmd, gpu, lv.mesh, ranges, lv.sculptor.mask)
	return sdl.SubmitGPUCommandBuffer(cmd)
}

// Starts sculpting the object's HD level in a window around `at` (in the object's
// space), on its top level: the window is what brushes reach, and what is drawn there.
// Does nothing without an HD level. Returns false on a GPU failure.
object_hd_enter :: proc(app: ^App, obj: ^Object, at: Vec3) -> bool {
	if obj.levels.hd.steps == 0 {
		log.info("HD: add an HD level first (Divide HD)")
		return true
	}
	stroke_finish(app)
	// One window at a time, since each can hold millions of vertices.
	for other in app.scene.objects do if other != obj do object_hd_leave(app, other)
	if !object_set_level(app, obj, len(obj.levels.levels) - 1) do return false
	start := time.tick_now()
	if !sculpt.levels_hd_enter(&obj.levels, at, app.hd_window_vertices) do return true
	built := time.tick_now()
	ok: bool
	obj.hd_gpu, ok = render.mesh_buffers_create(&app.renderer, object_mesh(obj)^, object_sculptor(obj).mask)
	if !ok {
		sculpt.levels_hd_leave(&obj.levels)
		return false
	}
	render.viewport_invalidate(&app.target)
	app.stats.hd_open_ms = time.duration_milliseconds(time.tick_diff(start, built))
	app.stats.hd_upload_ms = time.duration_milliseconds(time.tick_since(built))
	log.infof("HD: window of %d vertices built in %.0f ms, uploaded in %.0f ms", geom.mesh_vertex_count(object_mesh(obj)^), app.stats.hd_open_ms, app.stats.hd_upload_ms)
	return true
}

// Stores what the HD window changed and closes it, dropping its strokes from the undo
// history. Does nothing outside HD.
object_hd_leave :: proc(app: ^App, obj: ^Object) {
	if !object_in_hd(obj) do return
	if app.stroke.object == obj.id do stroke_finish(app)
	start := time.tick_now()
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	render.mesh_buffers_destroy(&app.renderer, &obj.hd_gpu)
	sculpt.levels_hd_leave(&obj.levels)
	history_forget_level(app, obj.id, HD_LEVEL)
	render.viewport_invalidate(&app.target)
	app.stats.hd_leave_ms = time.duration_milliseconds(time.tick_since(start))
}

// Just to the right of everything already in the scene, so a new sphere never lands
// inside another one.
next_free_position :: proc(app: ^App) -> Vec3 {
	if len(app.scene.objects) == 0 do return {}
	right := min(f32)
	for obj in app.scene.objects {
		right = max(right, obj.transform.position.x + obj.transform.scale)
	}
	return {right + 1.25, 0, 0}
}

// Nearest object hit by a world-space ray (dir normalised). The hit is in world space.
scene_raycast :: proc(app: ^App, origin, dir: Vec3) -> (index: int, hit: Vec3, ok: bool) {
	best := max(f32)
	for obj, i in app.scene.objects {
		t := obj.transform
		local_hit, local_ok := sculpt.sculptor_raycast(object_sculptor(obj), to_local(t, origin), dir)
		if !local_ok do continue
		world_hit := to_world(t, local_hit)
		if d := linalg.length(world_hit - origin); d < best {
			best, index, hit, ok = d, i, world_hit, true
		}
	}
	return
}

@(private = "file")
object_build :: proc(app: ^App, obj: ^Object, vertices, subdiv: int) -> bool {
	start := time.tick_now()
	mesh: geom.Mesh
	if vertices > 0 {
		mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(vertices), &app.pool)
	} else {
		mesh = geom.icosphere(subdiv)
	}
	return object_build_from(app, obj, mesh, start)
}

// Makes `mesh` the object's only level, prepares it for sculpting and uploads it.
// `start` is when building the mesh began, for the log.
@(private = "file")
object_build_from :: proc(app: ^App, obj: ^Object, mesh: geom.Mesh, start: time.Tick) -> bool {
	sculpt.levels_init(&obj.levels, mesh, &app.pool)
	free_all(context.temp_allocator)
	ready := time.tick_now()
	mesh_gpu, ok := render.mesh_buffers_create(&app.renderer, object_mesh(obj)^, object_sculptor(obj).mask)
	if !ok {
		sculpt.levels_destroy(&obj.levels)
		return false
	}
	obj.gpu[0] = mesh_gpu
	log.infof("mesh: %d vertices, %d triangles; ready to sculpt in %.0f ms, uploaded in %.0f ms",
		geom.mesh_vertex_count(object_mesh(obj)^), geom.mesh_triangle_count(object_mesh(obj)^),
		time.duration_milliseconds(time.tick_diff(start, ready)), time.duration_milliseconds(time.tick_since(ready)))
	app.stats = {}
	return true
}

// Frees the levels and GPU buffers. The caller waits for the GPU first.
@(private = "file")
object_release_mesh :: proc(app: ^App, obj: ^Object) {
	if app.stroke.object == obj.id do app.stroke.active = false
	history_forget(app, obj.id)
	for &gpu in obj.gpu do render.mesh_buffers_destroy(&app.renderer, &gpu)
	render.mesh_buffers_destroy(&app.renderer, &obj.hd_gpu)
	sculpt.levels_destroy(&obj.levels)
}

@(private = "file")
object_free :: proc(app: ^App, obj: ^Object) {
	object_release_mesh(app, obj)
	free(obj)
}
