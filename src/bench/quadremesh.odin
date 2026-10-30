package bench

import "core:fmt"
import "core:time"

import "../geom"
import "../jobs"
import "../quadmesh"
import "../sculpt"

// --quadremesh: at each size, the stretched sphere --remesh uses, cut down to Quad
// Remesh's input cap (as the app does before the engine sees it) and quad remeshed to
// QUAD_BENCH_QUADS at adaptivity 0 by AutoRemesher's core: the decimation's time, the
// engine's, what it gave (faces, the quads' share, the share of vertices with four
// quads) and the peak memory. On a platform without the engine one line says so.

// The app's cap on what the engine is handed (retopo.odin's QUAD_REMESH_MAX_TRIANGLES).
QUAD_BENCH_INPUT_TRIANGLES :: 1_000_000
QUAD_BENCH_QUADS :: 20_000

quadremesh_header :: proc() {
	fmt.println("| Vertices | Engine input triangles | Decimate ms | Quad remesh ms | Faces | Quads | Four-valent | Peak RSS MB |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_quadremesh :: proc(target: int, pool: ^jobs.Pool) {
	when !quadmesh.AVAILABLE {
		fmt.printfln("| %s | the engine is not built on this platform | | | | | | |", thousands(target))
		return
	} else {
		sp := new(Sphere)
		defer free(sp)
		sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
		sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
		free_all(context.temp_allocator)
		s := &sp.sculptor
		_ = sculpt.sculptor_grab_begin(s, {kind = .Grab, radius = 0.5, strength = 1}, {0, 0, 1})
		_ = sculpt.sculptor_grab_move(s, {0.2, 0, 1.2})
		_ = sculpt.sculptor_flush(s)
		sculpt.sculptor_destroy(&sp.sculptor)

		// The engine's input: the mesh itself under the cap, else a decimation to it.
		input := sp.mesh
		capped: geom.Mesh
		decimate_ms := f64(0)
		if len(sp.mesh.indices) / 3 > QUAD_BENCH_INPUT_TRIANGLES {
			t0 := time.tick_now()
			ok: bool
			capped, _, ok = geom.mesh_decimate(sp.mesh, QUAD_BENCH_INPUT_TRIANGLES, pool)
			decimate_ms = time.duration_milliseconds(time.tick_since(t0))
			free_all(context.temp_allocator)
			if !ok {
				fmt.printfln("| %s | decimation failed | | | | | | |", thousands(target))
				geom.mesh_destroy(&sp.mesh)
				return
			}
			input = capped
		}
		params := quadmesh.DEFAULT_PARAMS
		params.quads = QUAD_BENCH_QUADS
		params.threads = clamp(jobs.pool_size(pool) if pool != nil else 1, 1, quadmesh.MAX_THREADS)
		input_triangles := len(input.indices) / 3
		t1 := time.tick_now()
		out, report, err, reason := quadmesh.remesh(input.positions[:], input.indices[:], params)
		remesh_ms := time.duration_milliseconds(time.tick_since(t1))
		geom.mesh_destroy(&capped)
		geom.mesh_destroy(&sp.mesh)
		free_all(context.temp_allocator)
		if err != .None {
			fmt.printfln("| %s | %s | %.0f | %.0f | failed: %s | | | |", thousands(target), thousands(input_triangles), decimate_ms, remesh_ms, reason)
			return
		}
		defer quadmesh.polygon_mesh_destroy(&out)
		four := four_valent_share(out)
		fmt.printfln("| %s | %s | %.0f | %.0f | %s | %.1f%% | %.1f%% | %.0f |", thousands(target), thousands(input_triangles), decimate_ms, remesh_ms,
			thousands(report.faces), 100 * f64(report.quads) / f64(max(report.faces, 1)), 100 * four, peak_rss_mb())
	}
}

// The share of a polygon mesh's vertices with exactly four polygons.
@(private = "file")
four_valent_share :: proc(m: quadmesh.Polygon_Mesh) -> f64 {
	if len(m.positions) == 0 do return 0
	count := make([]int, len(m.positions), context.temp_allocator)
	for c in m.corners do count[c] += 1
	four := 0
	for n in count do if n == 4 do four += 1
	return f64(four) / f64(len(m.positions))
}
