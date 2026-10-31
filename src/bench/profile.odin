package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// --profile: steady strokes for a profiler, at the sizes a remeshed sculpt reaches (12.5M and
// 25M vertices by default: 25M polygons as triangles, and as Remesh's quads). Each case
// strokes the main table's wavy path again and again for --seconds (5 by default), undoing
// every stroke so the sphere stays the same, and prints the mean of every phase over all its
// frames, which a short stroke's median hides: a profiler attached to the process
// (`perf record -e cpu-clock -g build/bench --profile`) then sees mostly the stroke rather
// than the setup. Stroke end includes the normal cones held back during the stroke; Undo
// is the undo and the flush that follows it, as an app frame pays them.
profile_seconds: f64 = 5

profile_header :: proc() {
	fmt.println("| Vertices | Triangles | Brush | Strokes | Verts/dab | Raycast ms/dab | Dab ms | Normals ms/frame | Frame ms | Frame ms p99 | Upload MB/frame | Stroke end ms | Undo ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_profile :: proc(target: int, pool: ^jobs.Pool) {
	sp := new(Sphere)
	defer free(sp)
	sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	defer geom.mesh_destroy(&sp.mesh)
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	defer sculpt.sculptor_destroy(&sp.sculptor)
	free_all(context.temp_allocator)
	s := &sp.sculptor
	vcount, tcount := len(sp.mesh.positions), len(sp.mesh.indices) / 3

	Case :: struct {
		name:   string,
		kind:   sculpt.Brush_Kind,
		radius: f32,
	}
	cases := [?]Case{{"Draw", .Draw, 0.13}, {"Clay", .Clay, 0.13}, {"Smooth", .Smooth, 0.13}, {"Draw, small", .Draw, 0.04}}
	eye := Vec3{0, 0, 3.5}
	for c in cases {
		frames := make([dynamic]f64)
		defer delete(frames)
		raycast_ms, dab_ms, flush_ms, end_ms, undo_ms: f64
		dabs, touched, strokes, upload := 0, 0, 0, 0
		start := time.tick_now()
		for strokes == 0 || time.duration_seconds(time.tick_since(start)) < profile_seconds {
			sculpt.sculptor_stroke_begin(s)
			frame: f64
			for i in 0 ..< DABS {
				// The main table's path, run back the other way every other stroke.
				k := f32(i) / (DABS - 1)
				if strokes % 2 == 1 do k = 1 - k
				p := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
				ta := time.tick_now()
				hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(p - eye))
				ray := time.duration_milliseconds(time.tick_since(ta))
				if !ok do hit = p
				tb := time.tick_now()
				touched += sculpt.apply_dab(s, {kind = c.kind, radius = c.radius, strength = 0.3}, hit)
				dab := time.duration_milliseconds(time.tick_since(tb))
				raycast_ms += ray
				dab_ms += dab
				frame += ray + dab
				dabs += 1
				if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
					tc := time.tick_now()
					for r in sculpt.sculptor_flush(s) do upload += int(r.count) * VERTEX_BYTES
					flush := time.duration_milliseconds(time.tick_since(tc))
					flush_ms += flush
					append(&frames, frame + flush)
					frame = 0
				}
			}
			te := time.tick_now()
			_ = sculpt.sculptor_stroke_end(s)
			for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
			end_ms += time.duration_milliseconds(time.tick_since(te))
			tu := time.tick_now()
			_ = sculpt.sculptor_undo(s)
			_ = sculpt.sculptor_flush(s)
			undo_ms += time.duration_milliseconds(time.tick_since(tu))
			for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
			sculpt.sculptor_clear_history(s)
			strokes += 1
		}
		n := f64(len(frames))
		slice.sort(frames[:])
		p99 := frames[min(int(0.99 * n), len(frames) - 1)]
		fmt.printfln("| %s | %s | %s r=%.2f | %d | %d | %.4f | %.3f | %.3f | %.2f | %.2f | %.2f | %.2f | %.2f |",
			thousands(vcount), thousands(tcount), c.name, c.radius, strokes, touched / dabs,
			raycast_ms / f64(dabs), dab_ms / f64(dabs), flush_ms / n, (raycast_ms + dab_ms + flush_ms) / n, p99,
			f64(upload) / n / (1 << 20), end_ms / f64(strokes), undo_ms / f64(strokes))
	}
}
