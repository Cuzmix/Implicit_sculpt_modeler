package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../render"
import "../sculpt"
import "../ui"
import "../voxel"

// A voxel object: clay sculpted as a volume (the voxel package), the way 3D-Coat's voxel
// room works, beside the mesh objects. The object keeps an empty subdivision level (no
// vertices) so that every panel, command and stat that reads the selected object's
// sculptor sees nothing rather than a nil pointer; the clay is what is drawn, picked and
// sculpted, and anything that would change a level (remesh, levels, HD, booleans, ...)
// refuses a voxel object first (scene_apply) or convert it to a mesh (Voxel_To_Mesh).
Voxel_Part :: struct {
	clay:       voxel.Clay,
	gpu:        render.Mesh_Buffers, // the clay's surface, remade when its arrays grow
	resolution: int, // voxels across the sphere it started as (its voxel size follows)
}

// A voxel sphere's resolution for the vertex count a size preset names: the surface of a
// sphere R voxels across meshes to about VOXEL_VERTICES_PER_VOXEL2 · R² vertices
// (`build/bench --voxel`: 347k at 256, 1.39M at 512, 5.57M at 1024), rounded to whole
// mesh nodes. The field itself is 36 MB at 512 and 146 MB at 1024.
VOXEL_VERTICES_PER_VOXEL2 :: 5.3
VOXELS_MIN :: 32
VOXELS_MAX :: 1024

voxel_resolution_for :: proc(vertices: int) -> int {
	r := int(math.sqrt(f64(vertices) / VOXEL_VERTICES_PER_VOXEL2) + 0.5)
	r = (r + voxel.NODE / 2) / voxel.NODE * voxel.NODE
	return clamp(r, VOXELS_MIN, VOXELS_MAX)
}

// About how many surface vertices a voxel sphere of `resolution` meshes to.
voxel_vertices_for :: proc(resolution: int) -> int {
	return int(VOXEL_VERTICES_PER_VOXEL2 * f64(resolution) * f64(resolution))
}

// Makes the object a voxel sphere: the clay, its first surface, the empty level and the
// GPU copy. Returns false on a GPU failure, with nothing of the object made.
object_build_voxel :: proc(app: ^App, obj: ^Object, resolution: int) -> bool {
	start := time.tick_now()
	vp := new(Voxel_Part)
	vp.resolution = resolution
	voxel.clay_init(&vp.clay, 2 / f32(resolution), {}, &app.pool)
	voxel.clay_fill_sphere(&vp.clay, {}, 1)
	_ = voxel.clay_flush(&vp.clay)
	return voxel_part_attach(app, obj, vp, start)
}

// Gives the object `vp`, whose clay is meshed, with the empty level and the GPU copy of
// the surface; frees `vp` and returns false on a GPU failure.
@(private = "file")
voxel_part_attach :: proc(app: ^App, obj: ^Object, vp: ^Voxel_Part, start: time.Tick) -> bool {
	sculpt.levels_init(&obj.levels, empty_mesh(), &app.pool)
	free_all(context.temp_allocator)
	ready := time.tick_now()
	gpu, ok := render.mesh_buffers_create(&app.renderer, vp.clay.surface.mesh, nil)
	if !ok {
		sculpt.levels_destroy(&obj.levels)
		voxel.clay_destroy(&vp.clay)
		free(vp)
		return false
	}
	vp.gpu = gpu
	obj.voxel = vp
	vertices, triangles := voxel.surface_counts(&vp.clay.surface)
	log.infof("voxels: %d bricks, %d vertices, %d triangles; ready to sculpt in %.0f ms, uploaded in %.0f ms", voxel.volume_brick_count(&vp.clay.volume), vertices, triangles,
		time.duration_milliseconds(time.tick_diff(start, ready)), time.duration_milliseconds(time.tick_since(ready)))
	app.stats = {}
	return true
}

// The level a voxel object keeps: a mesh with no vertices and no triangles.
@(private = "file")
empty_mesh :: proc() -> geom.Mesh {
	return {positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
}

// Frees the object's clay and its GPU copy, if it has them. The caller waits for the GPU
// first.
voxel_part_free :: proc(app: ^App, obj: ^Object) {
	vp := obj.voxel
	if vp == nil do return
	render.mesh_buffers_destroy(&app.renderer, &vp.gpu)
	voxel.clay_destroy(&vp.clay)
	free(vp)
	obj.voxel = nil
}

// Reads the clay object_put wrote in the levels' place into a new part on `obj`, with its
// empty level, and uploads its surface. `read` is false when the bytes are damaged (nothing is made); `made` is
// false on a GPU failure, with the object's part left for object_discard.
voxel_part_get :: proc(app: ^App, r: ^geom.Byte_Reader, obj: ^Object) -> (read, made: bool) {
	start := time.tick_now()
	resolution := int(geom.byte_get(r, i32))
	if !r.ok || resolution < VOXELS_MIN || resolution > VOXELS_MAX do return false, false
	vp := new(Voxel_Part)
	vp.resolution = resolution
	if !voxel.clay_read(&vp.clay, r, &app.pool) {
		free(vp)
		return false, false
	}
	_ = voxel.clay_flush(&vp.clay)
	return true, voxel_part_attach(app, obj, vp, start)
}

// Remeshes what the frame's strokes changed and records the upload: the vertex and index
// slots that changed, or a new GPU copy of the whole surface when its arrays grew or were
// laid out again. Returns the bytes sent and the damage, and false on a GPU failure.
voxel_upload :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, vp: ^Voxel_Part) -> (bytes: int, damage: geom.Aabb, ok: bool) {
	f := voxel.clay_flush(&vp.clay)
	m := vp.clay.surface.mesh
	if f.regrow || u32(len(m.positions)) > vp.gpu.vertex_capacity || u32(len(m.indices)) > vp.gpu.index_count {
		_ = sdl.WaitForGPUIdle(app.renderer.device)
		render.mesh_buffers_destroy(&app.renderer, &vp.gpu)
		vp.gpu = render.mesh_buffers_create(&app.renderer, m, nil) or_return
		render.viewport_invalidate(&app.target)
		app.stats.gpu_regrows += 1
		return len(m.positions) * render.VERTEX_BYTES + len(m.indices) * size_of(u32), f.damage, true
	}
	render.mesh_buffers_upload_ranges(&app.renderer, cmd, &vp.gpu, m, f.ranges, nil)
	render.mesh_buffers_upload_indices(&app.renderer, cmd, &vp.gpu, m.indices[:], f.indices)
	for r in f.ranges do bytes += int(r.count) * render.VERTEX_BYTES
	for r in f.indices do bytes += int(r.index_count) * size_of(u32)
	return bytes, f.damage, true
}

// Where a ray (in the object's space) meets the object: the clay's surface for a voxel
// object, the mesh for the rest, with the surface normal there.
object_raycast_local :: proc(obj: ^Object, origin, dir: Vec3) -> (hit, normal: Vec3, ok: bool) {
	if vp := obj.voxel; vp != nil do return voxel.clay_raycast(&vp.clay, origin, dir)
	hit, ok = sculpt.sculptor_raycast(object_sculptor(obj), origin, dir)
	return
}

// The voxel brush a mesh brush stands for: Draw, Clay and Layer add clay (take it away
// inverted), Smooth, Flatten and Inflate do what they do on a mesh; the rest have no
// meaning on a volume (false). `normal` is the surface normal under the dab.
voxel_brush_of :: proc(b: sculpt.Brush, normal: Vec3) -> (vb: voxel.Brush, ok: bool) {
	vb = {radius = b.radius, strength = b.strength, invert = b.invert, normal = normal}
	#partial switch b.kind {
	case .Draw, .Clay, .Layer: vb.kind = .Add
	case .Smooth:  vb.kind = .Smooth
	case .Flatten: vb.kind = .Flatten
	case .Inflate: vb.kind = .Inflate
	case: return vb, false
	}
	return vb, true
}

// Whether a stroke with `kind` can start on a voxel object; said once a press (`say`) when
// not, so the press does nothing in silence.
voxel_brush_allowed :: proc(app: ^App, kind: sculpt.Brush_Kind, say: bool) -> bool {
	if _, ok := voxel_brush_of({kind = kind}, {}); ok do return true
	if say do report(app, Kit_Section.Voxels, {.Warning}, "%s is not a voxel brush: voxels take Draw, Clay, Layer, Smooth, Flatten and Inflate; convert the object to a mesh for the rest", BRUSHES[kind].name)
	return false
}

// One dab on the object at `at` (its space): the sculptor's for a mesh, the clay's for a
// voxel object, mirrored and turned as the brush's symmetry says. `normal` is the surface normal at
// the hit, which the voxel brushes need and the mesh brushes work out themselves.
object_dab :: proc(app: ^App, obj: ^Object, brush: sculpt.Brush, at, normal: Vec3) {
	vp := obj.voxel
	if vp == nil {
		sculpt.apply_dab(object_sculptor(obj), brush, at)
		return
	}
	vb, ok := voxel_brush_of(brush, normal)
	if !ok do return
	for img in sculpt.symmetry_images(brush) {
		vb.normal = img.turn * normal
		_ = voxel.clay_dab(&vp.clay, vb, sculpt.sym_point(img, brush.sym_center, at))
	}
}

// Rebuilds the voxel object as a mesh object of its surface (voxel.clay_to_mesh: the
// nodes' border vertices welded): its clay and strokes go, and the mesh is ready for every
// mesh tool. The caller records the swap. Returns false only when the mesh could not be
// uploaded.
object_voxel_to_mesh :: proc(app: ^App, obj: ^Object) -> bool {
	stroke_finish(app)
	start := time.tick_now()
	mesh := voxel.clay_to_mesh(&obj.voxel.clay)
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	object_release_mesh(app, obj)
	return object_build_from(app, obj, mesh, start, normals = true)
}

// The Object palette's Voxels section: what the clay is, and Convert to mesh.
kit_voxels :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	vp := obj.voxel
	if vp == nil {
		ui.paragraph(ctx, "A mesh object. Voxel objects come from the Scene palette's Add object with As voxels on: clay sculpted as a volume, with no topology to stretch or tear.")
		_ = command_button(app, .Convert_To_Mesh, variant = .Solid, tone = .Accent, enabled = false)
		return
	}
	bricks := voxel.volume_brick_count(&vp.clay.volume)
	ui.paragraph(ctx, fmt.tprintf("%d voxels across at the start (%.4f a voxel), %s bricks, %s of field, %s of surface, %s of undo.", vp.resolution, vp.clay.volume.voxel,
		count_label(bricks), bytes_label(voxel.volume_bytes(&vp.clay.volume)), bytes_label(voxel.surface_bytes(&vp.clay.surface)), bytes_label(voxel.clay_undo_bytes(&vp.clay))))
	_ = command_button(app, .Convert_To_Mesh, variant = .Solid, tone = .Accent)
	ui.paragraph(ctx, "Draw, Clay and Layer add clay (Ctrl takes it away), Smooth, Flatten and Inflate work as on a mesh; the other brushes, masks, levels and the rebuild tools need a mesh. Convert to mesh keeps the shape as triangles and is an undo step.")
	kit_last_result(app, .Voxels)
}

// Whether the Object palette offers section `sec` for the selected object: a voxel object
// has its placement and its Voxels section, and a mesh every section (Voxels then says
// what voxel objects are).
object_section_offered :: proc(app: ^App, sec: Kit_Section) -> bool {
	obj := selected_object(app)
	if obj != nil && obj.voxel != nil do return sec == .Transform || sec == .Voxels
	return true
}
