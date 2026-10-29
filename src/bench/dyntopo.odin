package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// --dyntopo: at each size, the main table's stroke with the large brush on the fixed
// layout, then dynamic topology turned on and the same path stroked three times: with
// detail 0, which leaves the triangles be (what the paged layout costs a plain stroke);
// with a detail that splits every edge under the brush once (each triangle into four);
// and that again over what is now fine enough (what checking costs). Then undo and redo
// of the refining stroke, Remove stretching over the whole object (which finds nothing
// longer than twice the median edge there: the cost of looking), and turning dynamic
// topology off again, which packs the mesh.
// Upload counts the vertex ranges and the index pages the flush reports.
dyntopo_header :: proc() {
	fmt.println("| Vertices | Fixed frame ms | Enable ms | Plain frame ms | Refine frame ms | Refine max | Splits | Collapses | Triangles after | Upload MB/frame | Again frame ms | Undo MB | Undo ms | Redo ms | Remove stretching ms | Disable ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_dyntopo :: proc(target: int, pool: ^jobs.Pool) {
	sp := new(Sphere)
	defer free(sp)
	sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	defer geom.mesh_destroy(&sp.mesh)
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	defer sculpt.sculptor_destroy(&sp.sculptor)
	free_all(context.temp_allocator)
	s := &sp.sculptor
	vcount := len(sp.mesh.positions)
	radius: f32 = 0.13
	// Splitting edges longer than 0.7 of the typical edge splits each one once.
	detail := 0.7 * mean_edge(sp.mesh) / radius

	fixed, _, _ := dyn_stroke(s, {kind = .Draw, radius = radius, strength = 0.3})
	_ = sculpt.sculptor_undo(s)
	_ = sculpt.sculptor_flush(s)

	t0 := time.tick_now()
	if !sculpt.sculptor_dyn_enable(s) {
		fmt.printfln("| %s | %.2f | refused | | | | | | | | | | | | | |", thousands(vcount), fixed)
		return
	}
	enable_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)

	plain, _, _ := dyn_stroke(s, {kind = .Draw, radius = radius, strength = 0.3})
	_ = sculpt.sculptor_undo(s)
	_ = sculpt.sculptor_flush(s)

	brush := sculpt.Brush{kind = .Draw, radius = radius, strength = 0.3, detail = detail, collapse = true}
	splits0, collapses0 := sculpt.sculptor_dyn_edits(s)
	refine, refine_max, upload := dyn_stroke(s, brush)
	splits1, collapses1 := sculpt.sculptor_dyn_edits(s)
	triangles := sculpt.sculptor_triangle_count(s)
	again, _, _ := dyn_stroke(s, brush)
	_ = sculpt.sculptor_undo(s) // the second stroke, then time the first
	_ = sculpt.sculptor_flush(s)
	undo_mb := f64(sculpt.sculptor_undo_bytes(s)) / (1 << 20)
	tu := time.tick_now()
	_ = sculpt.sculptor_undo(s)
	_ = sculpt.sculptor_flush(s)
	undo_ms := time.duration_milliseconds(time.tick_since(tu))
	tr := time.tick_now()
	_ = sculpt.sculptor_redo(s)
	_ = sculpt.sculptor_flush(s)
	redo_ms := time.duration_milliseconds(time.tick_since(tr))
	free_all(context.temp_allocator)
	ts := time.tick_now()
	sculpt.sculptor_stroke_begin(s)
	_, _ = sculpt.sculptor_remove_stretching(s)
	if sculpt.sculptor_stroke_end(s) do _ = sculpt.sculptor_undo(s)
	stretch_ms := time.duration_milliseconds(time.tick_since(ts))
	_ = sculpt.sculptor_flush(s)
	free_all(context.temp_allocator)

	td := time.tick_now()
	sculpt.sculptor_dyn_disable(s)
	disable_ms := time.duration_milliseconds(time.tick_since(td))
	free_all(context.temp_allocator)
	fmt.printfln("| %s | %.2f | %.0f | %.2f | %.2f | %.2f | %s | %s | %s | %.2f | %.2f | %.1f | %.1f | %.1f | %.0f | %.0f |",
		thousands(vcount), fixed, enable_ms, plain, refine, refine_max, thousands(splits1 - splits0), thousands(collapses1 - collapses0),
		thousands(triangles), upload, again, undo_mb, undo_ms, redo_ms, stretch_ms, disable_ms)
}

// The main table's stroke, recorded for undo: DABS dabs with their raycasts,
// DABS_PER_FRAME to a frame, each frame ending with the flush. Returns the median and
// the longest frame, and the upload per frame.
@(private = "file")
dyn_stroke :: proc(s: ^sculpt.Sculptor, brush: sculpt.Brush) -> (frame_ms, max_ms, upload_mb: f64) {
	frames := (DABS + DABS_PER_FRAME - 1) / DABS_PER_FRAME
	frame := make([]f64, frames, context.temp_allocator)
	eye := Vec3{0, 0, 3.5}
	upload := 0
	sculpt.sculptor_stroke_begin(s)
	for i in 0 ..< DABS {
		k := f32(i) / (DABS - 1)
		target_point := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
		t := time.tick_now()
		hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(target_point - eye))
		if !ok do hit = target_point
		_ = sculpt.apply_dab(s, brush, hit)
		if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
			for r in sculpt.sculptor_flush(s) do upload += int(r.count) * VERTEX_BYTES
			for r in sculpt.sculptor_index_ranges(s) do upload += int(r.index_count) * size_of(u32)
		}
		frame[i / DABS_PER_FRAME] += time.duration_milliseconds(time.tick_since(t))
	}
	_ = sculpt.sculptor_stroke_end(s)
	for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
	return median(frame), slice.max(frame), f64(upload) / f64(frames) / (1 << 20)
}

// Mean edge length over a sample of the triangles.
@(private = "file")
mean_edge :: proc(m: geom.Mesh) -> f32 {
	total: f64
	count := 0
	for t := 0; t < len(m.indices); t += 3 * 97 {
		for c in 0 ..< 3 {
			total += f64(linalg.length(m.positions[m.indices[t + c]] - m.positions[m.indices[t + (c + 1) % 3]]))
			count += 1
		}
	}
	return f32(total / f64(count))
}
