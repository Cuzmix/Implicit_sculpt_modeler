package bench

import "core:fmt"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// HD detail (--hd): a sphere of each target size as the top level, with an HD level one
// and then two Loop steps above it. Times opening a window of about HD_BENCH_WINDOW
// vertices at the front, a detail stroke in it, storing it on leaving, and opening the
// window again with the stored detail. Then the regular levels the HD level stands in
// for: their memory, and while they stay under HD_BENCH_LEVELS_MAX vertices, the time to
// build them and the same stroke on the top one.
HD_BENCH_WINDOW :: sculpt.HD_WINDOW_VERTICES
HD_BENCH_LEVELS_MAX :: 16_000_000
HD_BENCH_RADIUS :: 0.04 // the main table's small brush
HD_BENCH_WIDTH :: 0.15 // the stroke runs this far either side of the front

hd_header :: proc() {
	fmt.printfln("Window of about %s vertices at the front of the sphere. Stroke: the main table's small brush (radius %.2f), %.2f either side of the front.", thousands(HD_BENCH_WINDOW), HD_BENCH_RADIUS, HD_BENCH_WIDTH)
	fmt.println("| Top vertices | HD steps | HD level vertices | Window vertices | Open ms | Stroke frame ms | Leave ms | Reopen ms | Window MB | Stored MB | Levels instead MB | Levels build s | Levels stroke frame ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_hd :: proc(target: int, pool: ^jobs.Pool) {
	l: sculpt.Levels
	sculpt.levels_init(&l, geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool), pool, node_triangles)
	defer sculpt.levels_destroy(&l)
	free_all(context.temp_allocator)
	top := l.levels[0]
	top_vertices, top_triangles := len(top.mesh.positions), len(top.mesh.indices) / 3

	Row :: struct {
		hd_vertices, window_vertices:      int,
		open_ms, stroke_ms, leave_ms, reopen_ms: f64,
		window_mb, stored_mb:              f64,
	}
	rows: [2]Row
	for &row, i in rows {
		steps := i + 1
		if !sculpt.levels_hd_set_steps(&l, steps) do panic("no HD level")
		row.hd_vertices = sculpt.levels_hd_vertices(&l)
		t0 := time.tick_now()
		if !sculpt.levels_hd_enter(&l, {0, 0, 1}, HD_BENCH_WINDOW) do panic("no window")
		row.open_ms = time.duration_milliseconds(time.tick_since(t0))
		free_all(context.temp_allocator)
		st := sculpt.levels_hd_stats(&l)
		row.window_vertices, row.window_mb = st.window_vertices, f64(st.window_bytes) / (1 << 20)
		row.stroke_ms = levels_stroke(&l, HD_BENCH_RADIUS, HD_BENCH_WIDTH)
		t1 := time.tick_now()
		sculpt.levels_hd_leave(&l)
		row.leave_ms = time.duration_milliseconds(time.tick_since(t1))
		row.stored_mb = f64(sculpt.levels_hd_stats(&l).stored_bytes) / (1 << 20)
		free_all(context.temp_allocator)
		t2 := time.tick_now()
		if !sculpt.levels_hd_enter(&l, {0, 0, 1}, HD_BENCH_WINDOW) do panic("no window")
		row.reopen_ms = time.duration_milliseconds(time.tick_since(t2))
		sculpt.levels_hd_leave(&l)
		sculpt.levels_hd_delete(&l)
		free_all(context.temp_allocator)
	}

	// The regular levels instead, as estimated before subdividing, then built while small
	// enough: levels_bytes counts what they really take.
	v, t := top_vertices, top_triangles
	for &row, i in rows {
		above_v, above_t := v + 3 * t / 2, 4 * t
		estimate := sculpt.level_estimate_bytes(above_v, above_t, v)
		if i > 0 do estimate += sculpt.level_estimate_bytes(v, t, v - 3 * t / 8) // the level below it too
		v, t = above_v, above_t
		fmt.printf("| %s | %d | %s | %s | %.0f | %.2f | %.0f | %.0f | %.0f | %.1f |", thousands(top_vertices), i + 1,
			thousands(row.hd_vertices), thousands(row.window_vertices), row.open_ms, row.stroke_ms, row.leave_ms, row.reopen_ms, row.window_mb, row.stored_mb)
		if v > HD_BENCH_LEVELS_MAX {
			fmt.printfln(" %.0f (estimate) | n/a | n/a |", f64(estimate) / (1 << 20))
			continue
		}
		before := sculpt.levels_bytes(&l)
		t3 := time.tick_now()
		for len(l.levels) < 2 + i {
			if !sculpt.levels_subdivide(&l) do panic("subdivide failed")
			free_all(context.temp_allocator)
		}
		build_s := time.duration_seconds(time.tick_since(t3))
		frame := levels_stroke(&l, HD_BENCH_RADIUS, HD_BENCH_WIDTH)
		fmt.printfln(" %.0f | %.2f | %.2f |", f64(sculpt.levels_bytes(&l) - before) / (1 << 20), build_s, frame)
		free_all(context.temp_allocator)
	}
}
