package bench

import "core:fmt"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// Detail skin (--skin): a sphere of each target size with a skin of 4 and then 16
// segments. Times the HD table's small stroke four ways: on the plain mesh, into the
// skin, split between the two (Detail goes to Auto), and on the levels Apply turns the
// skin into (the same detail as real vertices),
// with the memory of the skin against those levels and the bytes of skin normals a frame
// uploads. Apply runs only while its top level stays under SKIN_BENCH_LEVELS_MAX
// vertices; beyond that the levels' memory is the estimate Apply's panel shows.
SKIN_BENCH_SEGMENTS :: [?]u32{4, 16}
SKIN_BENCH_LEVELS_MAX :: 16_000_000
// A sample's normal on the GPU: octahedral, two signed 16-bit halves.
SKIN_NORMAL_BYTES :: 4

skin_header :: proc() {
	fmt.printfln("Stroke: the HD table's small brush (radius %.2f), %.2f either side of the front; a frame is %d dabs and a flush.", HD_BENCH_RADIUS, HD_BENCH_WIDTH, DABS_PER_FRAME)
	fmt.println("| Mesh vertices | Segments | Looks like vertices | Mesh stroke frame ms | Skin make ms | Skin MB | Skin stroke frame ms | Skin upload KB/frame | Auto stroke frame ms | Levels instead | Levels MB | Apply s | Levels stroke frame ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_skin :: proc(target: int, pool: ^jobs.Pool) {
	for segments in SKIN_BENCH_SEGMENTS {
		l: sculpt.Levels
		sculpt.levels_init(&l, geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool), pool, node_triangles)
		defer sculpt.levels_destroy(&l)
		free_all(context.temp_allocator)
		s := &l.levels[0].sculptor
		vertices := len(l.levels[0].mesh.positions)
		mesh_ms := levels_stroke(&l, HD_BENCH_RADIUS, HD_BENCH_WIDTH)
		free_all(context.temp_allocator)

		t0 := time.tick_now()
		if !sculpt.sculptor_skin_set(s, segments) do panic("no skin")
		make_ms := time.duration_milliseconds(time.tick_since(t0))
		free_all(context.temp_allocator)
		sk := sculpt.sculptor_skin(s)
		samples := sculpt.skin_sample_count(sk)
		skin_mb := f64(sculpt.sculptor_skin_bytes(s)) / (1 << 20)
		upload: int
		skin_ms := levels_stroke(&l, HD_BENCH_RADIUS, HD_BENCH_WIDTH, skin = true, skin_upload = &upload)
		free_all(context.temp_allocator)
		// Detail goes to Auto: each dab split between the vertices and the skin by its size.
		auto_ms := levels_stroke(&l, HD_BENCH_RADIUS, HD_BENCH_WIDTH, skin = true, split = true)
		free_all(context.temp_allocator)

		fmt.printf("| %s | %d | %s | %.2f | %.0f | %.1f | %.2f | %.1f | %.2f |", thousands(vertices), segments, thousands(samples),
			mesh_ms, make_ms, skin_mb, skin_ms, f64(upload) / 1024, auto_ms)
		steps := sculpt.levels_skin_apply_steps(&l)
		top_vertices, _, estimate := sculpt.levels_skin_apply_estimate(&l)
		if top_vertices > SKIN_BENCH_LEVELS_MAX {
			fmt.printfln(" %d levels, %s vertices | %.0f (estimate) | n/a | n/a |", steps, thousands(top_vertices), f64(estimate) / (1 << 20))
			continue
		}
		before := sculpt.levels_bytes(&l)
		t1 := time.tick_now()
		if !sculpt.levels_skin_apply(&l) do panic("apply failed")
		apply_s := time.duration_seconds(time.tick_since(t1))
		free_all(context.temp_allocator)
		// The levels hold what the skin held, so its memory goes from the difference.
		levels_mb := f64(sculpt.levels_bytes(&l) - before) / (1 << 20) + skin_mb
		levels_ms := levels_stroke(&l, HD_BENCH_RADIUS, HD_BENCH_WIDTH)
		free_all(context.temp_allocator)
		fmt.printfln(" %d levels, %s vertices | %.0f | %.2f | %.2f |", steps, thousands(len(l.levels[len(l.levels) - 1].mesh.positions)), levels_mb, apply_s, levels_ms)
	}
}
