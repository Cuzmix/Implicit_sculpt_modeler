package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// Subdivision levels at each target size (--levels): a base of at most 40k vertices
// with as few levels above it as reach the target. Times building each level, a stroke
// on the top level, carrying it down to the base (as stepping down does), a stroke on
// the base, and carrying that up to the top. "Normals" is the flush the app does when
// it shows the new level: normals of everything the change moved.
LEVELS_BASE_MAX :: 40_000

levels_header :: proc() {
	fmt.println("| Top vertices | Levels | Base vertices | Subdivide s | Last level s | RSS MB | Top stroke frame ms | Top->base sync ms | Base normals ms | Base stroke frame ms | Base->top sync ms | Top normals ms | Top upload MB |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_levels :: proc(target: int, pool: ^jobs.Pool) {
	// Geodesic spheres have 10 f^2 + 2 vertices, and a level above has twice the frequency.
	f := math.sqrt(f64(target - 2) / 10)
	steps := 0
	for 10 * (f / f64(int(1) << uint(steps))) * (f / f64(int(1) << uint(steps))) + 2 > LEVELS_BASE_MAX do steps += 1
	base_frequency := max(int(math.round(f / f64(int(1) << uint(steps)))), 1)

	l: sculpt.Levels
	sculpt.levels_init(&l, geom.geodesic_sphere(base_frequency, pool), pool, node_triangles)
	defer sculpt.levels_destroy(&l)
	free_all(context.temp_allocator)
	base_vertices := len(l.levels[0].mesh.positions)
	t0 := time.tick_now()
	last_s: f64
	for _ in 0 ..< steps {
		ts := time.tick_now()
		if !sculpt.levels_subdivide(&l) do panic("subdivide failed")
		last_s = time.duration_seconds(time.tick_since(ts))
		free_all(context.temp_allocator)
	}
	subdivide_s := time.duration_seconds(time.tick_since(t0))
	rss := rss_mb()
	top := len(l.levels) - 1
	top_vertices := len(l.levels[top].mesh.positions)

	top_frame := levels_stroke(&l, 0.13)
	t1 := time.tick_now()
	sculpt.levels_set_current(&l, 0)
	down_ms := time.duration_milliseconds(time.tick_since(t1))
	t2 := time.tick_now()
	_ = sculpt.sculptor_flush(&l.levels[0].sculptor)
	base_normals_ms := time.duration_milliseconds(time.tick_since(t2))
	free_all(context.temp_allocator)

	base_frame := levels_stroke(&l, 0.13)
	t3 := time.tick_now()
	sculpt.levels_set_current(&l, top)
	up_ms := time.duration_milliseconds(time.tick_since(t3))
	t4 := time.tick_now()
	upload := 0
	for r in sculpt.sculptor_flush(&l.levels[top].sculptor) do upload += int(r.count) * VERTEX_BYTES
	top_normals_ms := time.duration_milliseconds(time.tick_since(t4))
	free_all(context.temp_allocator)

	fmt.printfln("| %s | %d | %s | %.2f | %.2f | %.0f | %.2f | %.1f | %.1f | %.2f | %.1f | %.1f | %.1f |",
		thousands(top_vertices), len(l.levels), thousands(base_vertices), subdivide_s, last_s, rss,
		top_frame, down_ms, base_normals_ms, base_frame, up_ms, top_normals_ms, f64(upload) / (1 << 20))
}

// The bench's wavy stroke on the active level (an HD window while one is open), across
// `width` either side of the front of the sphere, DABS_PER_FRAME dabs and a flush per
// frame. Returns the median frame time.
levels_stroke :: proc(l: ^sculpt.Levels, radius: f32, width: f32 = 0.6) -> f64 {
	s := &sculpt.levels_active(l).sculptor
	frames := make([dynamic]f64, 0, DABS / DABS_PER_FRAME + 1, context.temp_allocator)
	eye := Vec3{0, 0, 3.5}
	sculpt.sculptor_stroke_begin(s)
	frame_start := time.tick_now()
	for i in 0 ..< DABS {
		k := f32(i) / (DABS - 1)
		target := linalg.normalize(Vec3{width * (2 * k - 1), 0.5 * width * math.sin(k * 4 * math.PI), 1})
		hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(target - eye))
		if !ok do hit = target
		_ = sculpt.apply_dab(s, {kind = .Draw, radius = radius, strength = 0.3}, hit)
		if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
			_ = sculpt.sculptor_flush(s)
			append(&frames, time.duration_milliseconds(time.tick_since(frame_start)))
			frame_start = time.tick_now()
		}
	}
	_ = sculpt.sculptor_stroke_end(s)
	for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
	slice.sort(frames[:])
	return frames[len(frames) / 2]
}
