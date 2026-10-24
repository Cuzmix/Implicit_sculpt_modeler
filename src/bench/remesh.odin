package bench

import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// --remesh: at each size, a sphere with a Grab stroke that pulls a wide spike out of
// it (the stretched triangles DynaMesh is for), then a voxel remesh back to the same
// vertex count: its time, the time to prepare the result for sculpting, and how even
// the triangles are before and after (longest edge over the median edge).
remesh_header :: proc() {
	fmt.println("| Vertices | Remeshed vertices | Remesh ms | Sculpt-ready ms | Edge p99 / median before | after | Max / median before | after |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_remesh :: proc(target: int, pool: ^jobs.Pool) {
	sp := new(Sphere)
	defer free(sp)
	sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	free_all(context.temp_allocator)
	s := &sp.sculptor
	_ = sculpt.sculptor_grab_begin(s, {kind = .Grab, radius = 0.5, strength = 1}, {0, 0, 1})
	_ = sculpt.sculptor_grab_move(s, {0.2, 0, 1.2})
	_ = sculpt.sculptor_flush(s)
	before_p99, before_max := edge_spread(sp.mesh)

	t0 := time.tick_now()
	out, ok := geom.remesh_voxel(sp.mesh, len(sp.mesh.positions), pool)
	remesh_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	sculpt.sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	if !ok {
		fmt.printfln("| %s | remesh failed | | | | | | |", thousands(target))
		return
	}
	after_p99, after_max := edge_spread(out)
	vcount := len(out.positions)
	t1 := time.tick_now()
	sp.mesh = out
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	setup_ms := time.duration_milliseconds(time.tick_since(t1))
	free_all(context.temp_allocator)
	sculpt.sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	fmt.printfln("| %s | %s | %.0f | %.0f | %.2f | %.2f | %.1f | %.1f |", thousands(target), thousands(vcount), remesh_ms, setup_ms, before_p99, after_p99, before_max, after_max)
}

// The 99th percentile and the longest edge length, over the median, sampling edges.
@(private = "file")
edge_spread :: proc(m: geom.Mesh) -> (p99, worst: f64) {
	STEP :: 7
	lengths := make([dynamic]f64, 0, len(m.indices) / STEP + 1, context.temp_allocator)
	for i := 0; i + 1 < len(m.indices); i += STEP {
		t := i / 3 * 3
		a, b := m.indices[t + i % 3], m.indices[t + (i + 1) % 3]
		append(&lengths, f64(linalg.length(m.positions[a] - m.positions[b])))
	}
	longest: f64
	for t := 0; t < len(m.indices); t += 3 {
		for c in 0 ..< 3 {
			a, b := m.indices[t + c], m.indices[t + (c + 1) % 3]
			longest = max(longest, f64(linalg.length(m.positions[a] - m.positions[b])))
		}
	}
	slice.sort(lengths[:])
	median := lengths[len(lengths) / 2]
	return lengths[len(lengths) * 99 / 100] / median, longest / median
}
