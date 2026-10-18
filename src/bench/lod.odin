package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../jobs"
import "../sculpt"

// Simplified drawing while the view moves (--lod): building every group's copy as the
// app does, a batch a frame, then the triangles drawn and the CPU time to choose them,
// at full detail and with copies allowed to stray LOD_BENCH_PX pixels, from the app's
// default camera and two closer ones, on a LOD_BENCH_HEIGHT pixel tall viewport.
// Finally the time to rebuild the copies a stroke made stale.
LOD_BENCH_PX :: 1
LOD_BENCH_HEIGHT :: 1000

lod_header :: proc() {
	fmt.printfln("Viewport %d px tall, 16:9, copies at most %d px off. Views as in the culling table; whole is averaged over 8 turns of the camera.", LOD_BENCH_HEIGHT, LOD_BENCH_PX)
	fmt.println("| Vertices | Triangles | Groups | Build s | Frames to build | Copies MB | View | Triangles full | Triangles simplified | Groups drawn | Select ms full | Select ms simplified | Stroke rebuild ms | Groups rebuilt |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_lod :: proc(target: int, pool: ^jobs.Pool) {
	sp := new(Sphere)
	defer free(sp)
	sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	defer geom.mesh_destroy(&sp.mesh)
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	defer sculpt.sculptor_destroy(&sp.sculptor)
	free_all(context.temp_allocator)
	s := &sp.sculptor
	groups := sculpt.sculptor_lod_pending(s)

	// As the app builds them: one budgeted update a frame.
	t0 := time.tick_now()
	frames := 0
	for sculpt.sculptor_lod_pending(s) > 0 {
		_, _ = sculpt.sculptor_lod_update(s)
		free_all(context.temp_allocator)
		frames += 1
	}
	build_s := time.duration_seconds(time.tick_since(t0))
	copies_mb := f64(len(s.lod.indices) * 4) / (1 << 20)

	// A stroke, then the copies it made stale, rebuilt in full.
	sculpt.sculptor_stroke_begin(s)
	eye := Vec3{0, 0, 3.5}
	for i in 0 ..< DABS {
		k := f32(i) / (DABS - 1)
		p := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
		hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(p - eye))
		_ = sculpt.apply_dab(s, {kind = .Draw, radius = 0.13, strength = 0.3}, hit if ok else p)
		if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 do _ = sculpt.sculptor_flush(s)
	}
	_ = sculpt.sculptor_stroke_end(s)
	for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
	rebuilt := sculpt.sculptor_lod_pending(s)
	t1 := time.tick_now()
	_, _ = sculpt.sculptor_lod_update(s, finish = true)
	rebuild_ms := time.duration_milliseconds(time.tick_since(t1))
	sculpt.sculptor_clear_history(s)
	free_all(context.temp_allocator)

	Lod_View :: struct {
		name:     string,
		distance: f32,
		turns:    int,
	}
	views := [3]Lod_View{{"whole (3.5)", 3.5, 8}, {"close (1.6)", 1.6, 1}, {"detail (1.15)", 1.15, 1}}
	plain, fine, coarse: [dynamic]geom.Index_Range
	defer delete(plain)
	defer delete(fine)
	defer delete(coarse)
	for v, row in views {
		full, simple, drawn_groups: int
		full_ms, simple_ms: f64
		for turn in 0 ..< v.turns {
			c := camera.orbit_default()
			c.yaw, c.pitch, c.distance = 2 * math.PI * f32(turn) / f32(v.turns), 0.1, v.distance
			proj := camera.orbit_proj(c, 16.0 / 9.0)
			clip := proj * camera.orbit_view(c)
			at := camera.orbit_eye(c)
			px_per_unit := proj[1, 1] * LOD_BENCH_HEIGHT / 2
			best_full, best_simple := max(f64), max(f64)
			stats: geom.Lod_Stats
			for _ in 0 ..< 5 {
				clear(&plain)
				ta := time.tick_now()
				_ = geom.cull_chunks(s.chunks, clip, at, &plain)
				best_full = min(best_full, time.duration_milliseconds(time.tick_since(ta)))
				clear(&fine)
				clear(&coarse)
				tb := time.tick_now()
				stats = geom.cull_lod(s.chunks, s.lod.tree, clip, at, px_per_unit, LOD_BENCH_PX, &fine, &coarse)
				best_simple = min(best_simple, time.duration_milliseconds(time.tick_since(tb)))
			}
			full += lod_triangles(plain[:])
			simple += lod_triangles(fine[:]) + lod_triangles(coarse[:])
			drawn_groups += stats.groups
			full_ms += best_full
			simple_ms += best_simple
		}
		n := v.turns
		if row == 0 {
			fmt.printf("| %s | %s | %d | %.2f | %d | %.0f |", thousands(len(sp.mesh.positions)), thousands(len(sp.mesh.indices) / 3), groups, build_s, frames, copies_mb)
		} else {
			fmt.printf("| | | | | | |")
		}
		fmt.printf(" %s | %s | %s (%.1fx fewer) | %d | %.3f | %.3f |", v.name, thousands(full / n), thousands(simple / n), f64(full) / f64(max(simple, 1)), drawn_groups / n, full_ms / f64(n), simple_ms / f64(n))
		if row == 0 {
			fmt.printfln(" %.1f | %d |", rebuild_ms, rebuilt)
		} else {
			fmt.println(" | |")
		}
	}
}

@(private = "file")
lod_triangles :: proc(ranges: []geom.Index_Range) -> (n: int) {
	for r in ranges do n += int(r.index_count / 3)
	return
}
