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

// One sculptable mesh in the scene. Heap allocated and never moved, because the
// sculptor keeps a pointer to the mesh.
Object :: struct {
	id:        int, // shown as "Sphere <id>"; never reused
	transform: Transform,
	mesh:      geom.Mesh,
	mesh_gpu:  render.Mesh_Buffers,
	sculptor:  sculpt.Sculptor,
}

Scene :: struct {
	objects:  [dynamic]^Object,
	selected: int, // index into objects, -1 when nothing is selected
	next_id:  int,
}

// Changes to the object list requested by the UI, applied at the start of the next
// frame so no panel ever draws an object (or GPU buffer) freed during the same frame.
Scene_Command :: struct {
	kind:     enum u8 {None, Add, Remesh, Delete},
	vertices: int,
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

// Replaces the object's mesh with a fresh sphere of about `vertices` vertices, keeping
// its transform. Sculpted detail is not carried over.
object_remesh :: proc(app: ^App, obj: ^Object, vertices: int) -> bool {
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	object_release_mesh(app, obj)
	return object_build(app, obj, vertices, 0)
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
	}
	return true
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
		local_hit, local_ok := sculpt.sculptor_raycast(&obj.sculptor, to_local(t, origin), dir)
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
	if vertices > 0 {
		obj.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(vertices), &app.pool)
	} else {
		obj.mesh = geom.icosphere(subdiv)
	}
	sculpt.sculptor_init(&obj.sculptor, &obj.mesh, &app.pool)
	free_all(context.temp_allocator)
	ready := time.tick_now()
	mesh_gpu, ok := render.mesh_buffers_create(&app.renderer, obj.mesh)
	if !ok {
		sculpt.sculptor_destroy(&obj.sculptor)
		geom.mesh_destroy(&obj.mesh)
		return false
	}
	obj.mesh_gpu = mesh_gpu
	log.infof("mesh: %d vertices, %d triangles; ready to sculpt in %.0f ms, uploaded in %.0f ms",
		geom.mesh_vertex_count(obj.mesh), geom.mesh_triangle_count(obj.mesh),
		time.duration_milliseconds(time.tick_diff(start, ready)), time.duration_milliseconds(time.tick_since(ready)))
	app.stats = {}
	return true
}

// Frees the mesh, sculptor and GPU buffers. The caller waits for the GPU first.
@(private = "file")
object_release_mesh :: proc(app: ^App, obj: ^Object) {
	render.mesh_buffers_destroy(&app.renderer, &obj.mesh_gpu)
	sculpt.sculptor_destroy(&obj.sculptor)
	geom.mesh_destroy(&obj.mesh)
}

@(private = "file")
object_free :: proc(app: ^App, obj: ^Object) {
	object_release_mesh(app, obj)
	free(obj)
}
