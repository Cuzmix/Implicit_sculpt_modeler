package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../geom"
import "../jobs"
import "../voxel"

// --voxel: at each size (voxels across a unit sphere, 256, 512 and 1024 by default), a
// clay sphere, its first full meshing, then a wavy Add stroke across its front as the
// mesh bench's: the dab, the per-frame flush (remesh of the dirty nodes) and the upload it
// asks for, the stroke's end (band repair), undo and redo, then one Smooth and one Inflate
// dab, and the conversion to a plain mesh. Times are medians over the stroke, in
// milliseconds, with the worst frame beside the flush. Regrows are the frames that had to
// remake the GPU copy because the mesh arrays grew; Mesh MB is the arrays with their slack.
voxel_header :: proc() {
	fmt.println("| Voxels across | Bricks | Field MB | Fill ms | First mesh ms | Vertices | Triangles | Raycast ms | Add dab ms | Bricks/dab | Flush ms | Flush ms max | Upload KB/frame | Regrows | Mesh MB | Stroke end ms | Undo MB | Undo ms | Redo ms | Smooth dab ms | Inflate dab ms | To mesh ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_voxel :: proc(across: int, pool: ^jobs.Pool) {
	c: voxel.Clay
	voxel.clay_init(&c, 2 / f32(across), {}, pool)
	defer voxel.clay_destroy(&c)
	t0 := time.tick_now()
	voxel.clay_fill_sphere(&c, {}, 1)
	fill_ms := time.duration_milliseconds(time.tick_since(t0))
	bricks := voxel.volume_brick_count(&c.volume)
	field_mb := f64(voxel.volume_bytes(&c.volume)) / (1 << 20)
	t1 := time.tick_now()
	_ = voxel.clay_flush(&c)
	first_ms := time.duration_milliseconds(time.tick_since(t1))
	vertices, triangles := voxel.surface_counts(&c.surface)
	free_all(context.temp_allocator)

	// The stroke: DABS dabs along a wave across the front, a frame every DABS_PER_FRAME.
	DABS :: 60
	DABS_PER_FRAME :: 3
	radius := f32(0.1)
	dab_ms := make([dynamic]f64, 0, DABS, context.temp_allocator)
	flush_ms := make([dynamic]f64, 0, DABS, context.temp_allocator)
	ray_ms := make([dynamic]f64, 0, DABS, context.temp_allocator)
	upload_bytes, frames, dab_bricks, regrows := 0, 0, 0, 0
	voxel.clay_stroke_begin(&c)
	for i in 0 ..< DABS {
		x := -0.6 + 1.2 * f32(i) / f32(DABS - 1)
		y := 0.3 * math.sin(f32(i) * 0.4)
		r0 := time.tick_now()
		hit, normal, ok := voxel.clay_raycast(&c, {x, y, 5}, {0, 0, -1})
		append(&ray_ms, time.duration_milliseconds(time.tick_since(r0)))
		if !ok do continue
		d0 := time.tick_now()
		dab_bricks += voxel.clay_dab(&c, {kind = .Add, radius = radius, strength = 1, normal = normal}, hit)
		append(&dab_ms, time.duration_milliseconds(time.tick_since(d0)))
		if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 {
			f0 := time.tick_now()
			f := voxel.clay_flush(&c)
			append(&flush_ms, time.duration_milliseconds(time.tick_since(f0)))
			frames += 1
			if f.regrow {
				regrows += 1
				upload_bytes += len(c.surface.mesh.positions) * 2 * size_of(geom.Vec3) + len(c.surface.mesh.indices) * size_of(u32)
			} else {
				for r in f.ranges do upload_bytes += int(r.count) * 2 * size_of(geom.Vec3)
				for r in f.indices do upload_bytes += int(r.index_count) * size_of(u32)
			}
		}
	}
	e0 := time.tick_now()
	_ = voxel.clay_stroke_end(&c)
	_ = voxel.clay_flush(&c)
	end_ms := time.duration_milliseconds(time.tick_since(e0))
	undo_mb := f64(voxel.clay_undo_bytes(&c)) / (1 << 20)
	u0 := time.tick_now()
	_ = voxel.clay_undo(&c)
	_ = voxel.clay_flush(&c)
	undo_ms := time.duration_milliseconds(time.tick_since(u0))
	r0 := time.tick_now()
	_ = voxel.clay_redo(&c)
	_ = voxel.clay_flush(&c)
	redo_ms := time.duration_milliseconds(time.tick_since(r0))

	smooth_ms := one_dab_ms(&c, .Smooth, radius)
	inflate_ms := one_dab_ms(&c, .Inflate, radius)
	m0 := time.tick_now()
	m := voxel.clay_to_mesh(&c)
	to_mesh_ms := time.duration_milliseconds(time.tick_since(m0))
	geom.mesh_destroy(&m)
	defer free_all(context.temp_allocator)

	fmt.printfln(
		"| %d | %s | %.1f | %.0f | %.0f | %s | %s | %.3f | %.2f | %d | %.2f | %.2f | %.0f | %d | %.0f | %.0f | %.1f | %.1f | %.1f | %.2f | %.2f | %.0f |",
		across,
		thousands(bricks),
		field_mb,
		fill_ms,
		first_ms,
		thousands(vertices),
		thousands(triangles),
		median(ray_ms[:]),
		median(dab_ms[:]),
		dab_bricks / max(len(dab_ms), 1),
		median(flush_ms[:]),
		max_of(flush_ms[:]),
		f64(upload_bytes) / f64(max(frames, 1)) / 1024,
		regrows,
		f64(voxel.surface_bytes(&c.surface)) / (1 << 20),
		end_ms,
		undo_mb,
		undo_ms,
		redo_ms,
		smooth_ms,
		inflate_ms,
		to_mesh_ms,
	)
}

// One stroke of a single dab of `kind` on the sphere's front, its dab time.
@(private = "file")
one_dab_ms :: proc(c: ^voxel.Clay, kind: voxel.Brush_Kind, radius: f32) -> f64 {
	hit, normal, ok := voxel.clay_raycast(c, {0.2, -0.3, 5}, {0, 0, -1})
	if !ok do return math.nan_f64()
	voxel.clay_stroke_begin(c)
	t0 := time.tick_now()
	_ = voxel.clay_dab(c, {kind = kind, radius = radius, strength = 1, normal = linalg.normalize0(normal)}, hit)
	ms := time.duration_milliseconds(time.tick_since(t0))
	_ = voxel.clay_stroke_end(c)
	_ = voxel.clay_flush(c)
	return ms
}

@(private = "file")
max_of :: proc(v: []f64) -> (m: f64) {
	for x in v do m = max(m, x)
	return
}
