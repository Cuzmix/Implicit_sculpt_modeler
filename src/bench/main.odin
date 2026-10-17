// Headless CPU benchmark of the sculpt pipeline at chosen mesh sizes. It needs no
// window or GPU, so results are comparable across machines and CI runs.
//
//   build/bench 500000 1000000 5000000
//
// For each target vertex count it builds a geodesic sphere, prepares it for sculpting,
// then runs the same strokes for a large and a small brush and prints one table row
// per brush. A frame is DABS_PER_FRAME dabs (each with its raycast) plus the flush
// that recomputes normals; GPU upload is the bytes of the dirty vertex ranges per frame
// (16 bytes a vertex: float3 position, octahedral snorm16x2 normal).
// A second table shows view culling of the sculpted mesh from three cameras: what share
// of triangles would be drawn, in how many draw commands, and the CPU time to cull.
// By default the 10M size runs a second time with an idle second sphere in the scene,
// flushed every frame as the app does, to show that idle meshes add no CPU cost.
//
//   --levels     instead, the subdivision levels table (see run_levels)
//   --meshes=N   spheres per size, all sculpt-ready; only the first is sculpted
//   --threads=N  worker count including the caller (default: every core)
//   --node=N     triangles per sculpt node
//   --prefault=MB touch this much memory first (see prefault)
package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../jobs"
import "../sculpt"

Vec3 :: geom.Vec3

DABS :: 77
DABS_PER_FRAME :: 4 // a fast stroke lands several dabs per frame
VERTEX_BYTES :: 16  // per vertex on the GPU, as render.VERTEX_BYTES
INDIRECT_BYTES :: 20 // per indirect draw command

cull_rows: [dynamic]string

node_triangles: u32 = sculpt.NODE_TRIANGLES
threads := 0
prefault_mb := 0
meshes := 0 // 0: the default cases
levels := false

main :: proc() {
	targets := make([dynamic]int)
	defer delete(targets)
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--node=") {
			node_triangles = u32(strconv.parse_int(arg[7:]) or_else int(sculpt.NODE_TRIANGLES))
		} else if strings.has_prefix(arg, "--prefault=") {
			prefault_mb = strconv.parse_int(arg[11:]) or_else 0
		} else if strings.has_prefix(arg, "--meshes=") {
			meshes = max(strconv.parse_int(arg[9:]) or_else 1, 1)
		} else if arg == "--levels" {
			levels = true
		} else if strings.has_prefix(arg, "--threads=") {
			threads = strconv.parse_int(arg[10:]) or_else 0
		} else if v, ok := strconv.parse_int(arg); ok {
			append(&targets, v)
		}
	}
	Case :: struct {
		vertices, meshes: int,
	}
	cases := make([dynamic]Case)
	defer delete(cases)
	if len(targets) == 0 {
		for v in ([]int{500_000, 1_000_000, 5_000_000, 7_000_000, 10_000_000}) do append(&cases, Case{v, max(meshes, 1)})
		if meshes == 0 do append(&cases, Case{10_000_000, 2})
	} else {
		for v in targets do append(&cases, Case{v, max(meshes, 1)})
	}
	if prefault_mb > 0 do prefault(prefault_mb)
	// --threads=1 runs everything on the calling thread; 0 (default) uses every core.
	pool_storage: jobs.Pool
	pool: ^jobs.Pool
	if threads != 1 {
		jobs.pool_init(&pool_storage, threads - 1 if threads > 1 else 0)
		pool = &pool_storage
	}
	defer if pool != nil do jobs.pool_destroy(pool)
	fmt.printfln("threads: %d, node triangles: %d", jobs.pool_size(pool) if pool != nil else 1, node_triangles)
	if levels {
		levels_header()
		for c in cases do if c.meshes == 1 do run_levels(c.vertices, pool)
		if prefault_mb == 0 do fmt.printfln("peak RSS: %.0f MB", peak_rss_mb())
		return
	}

	fmt.println("| Meshes | Vertices | Triangles | Setup s | Mesh MB | RSS MB | Brush | Verts/dab | Raycast ms | Dab ms | Normals ms/frame | Frame ms | Frame ms max | Upload MB/frame | Stroke end ms | Undo MB/stroke | Undo ms | Redo ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for c in cases {
		run(c.vertices, c.meshes, pool)
	}
	fmt.println()
	fmt.println("| Vertices | GPU MB | View | Chunks | Triangles drawn | Draws | Cull ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- |")
	for row in cull_rows do fmt.println(row)
	if prefault_mb == 0 do fmt.printfln("peak RSS: %.0f MB", peak_rss_mb())
}

// Mesh and sculptor of one bench sphere, heap allocated because the sculptor keeps a
// pointer to the mesh.
Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: sculpt.Sculptor,
}

run :: proc(target, mesh_count: int, pool: ^jobs.Pool) {
	t0 := time.tick_now()
	spheres := make([]^Sphere, mesh_count)
	for &sp in spheres {
		sp = new(Sphere)
		sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
		sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
		free_all(context.temp_allocator)
	}
	defer {
		for sp in spheres {
			sculpt.sculptor_destroy(&sp.sculptor)
			geom.mesh_destroy(&sp.mesh)
			free(sp)
		}
		delete(spheres)
	}
	m, s := &spheres[0].mesh, &spheres[0].sculptor
	setup_s := time.duration_seconds(time.tick_since(t0)) / f64(mesh_count)
	rss := rss_mb()

	vcount, tcount := len(m.positions), len(m.indices) / 3
	cpu_bytes := vcount * (2 * size_of(Vec3) + 4) + // positions, normals, vertex-face offsets
		tcount * (3 * 4 + 3 * 4 + 4 + 4) + // indices, face lists, bvh order/leaf
		len(s.bvh.nodes) * (size_of(geom.Bvh_Node) + 4) + len(s.nodes) * (size_of(sculpt.Node) + size_of(geom.Chunk)) +
		(len(s.shared) + len(s.owners)) * 4

	// Large brush ~ a 60 px brush on a full-screen head; small ~ a 20 px detail brush.
	for radius in ([2]f32{0.13, 0.04}) {
		frames := (DABS + DABS_PER_FRAME - 1) / DABS_PER_FRAME
		raycast, dab := make([]f64, DABS), make([]f64, DABS)
		flush, frame := make([]f64, frames), make([]f64, frames)
		defer delete(raycast)
		defer delete(dab)
		defer delete(flush)
		defer delete(frame)
		touched_total := 0
		upload_bytes := 0
		eye := Vec3{0, 0, 3.5}
		// One stroke, recorded for undo as the app does.
		sculpt.sculptor_stroke_begin(s)
		for i in 0 ..< DABS {
			// Wavy stroke across the front of the sphere, as in the app's --bench-stroke.
			k := f32(i) / (DABS - 1)
			target_point := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
			ta := time.tick_now()
			hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(target_point - eye))
			raycast[i] = time.duration_milliseconds(time.tick_since(ta))
			if !ok do hit = target_point
			tb := time.tick_now()
			touched_total += sculpt.apply_dab(s, {kind = .Draw, radius = radius, strength = 0.3}, hit)
			dab[i] = time.duration_milliseconds(time.tick_since(tb))
			f := i / DABS_PER_FRAME
			frame[f] += raycast[i] + dab[i]
			if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
				tc := time.tick_now()
				// Every sphere is flushed, as the app does each frame; idle ones have nothing to do.
				for sp in spheres {
					for r in sculpt.sculptor_flush(&sp.sculptor) do upload_bytes += int(r.count) * VERTEX_BYTES
				}
				flush[f] = time.duration_milliseconds(time.tick_since(tc))
				frame[f] += flush[f]
			}
		}
		_ = sculpt.sculptor_stroke_end(s)
		// The app flushes again in the frame the stroke ends, which starts on the normal
		// cones held back during the stroke; later frames finish them.
		te := time.tick_now()
		for sp in spheres do _ = sculpt.sculptor_flush(&sp.sculptor)
		end_ms := time.duration_milliseconds(time.tick_since(te))
		for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
		undo_mb := f64(sculpt.sculptor_undo_bytes(s)) / (1 << 20)
		// Undo and redo the stroke, each with the normal update that follows it.
		tu := time.tick_now()
		_ = sculpt.sculptor_undo(s)
		_ = sculpt.sculptor_flush(s)
		undo_ms := time.duration_milliseconds(time.tick_since(tu))
		tr := time.tick_now()
		_ = sculpt.sculptor_redo(s)
		_ = sculpt.sculptor_flush(s)
		redo_ms := time.duration_milliseconds(time.tick_since(tr))
		sculpt.sculptor_clear_history(s) // so the next brush measures its own stroke
		fmt.printfln("| %d | %s | %s | %.1f | %.0f | %.0f | r=%.2f | %d | %.3f | %.3f | %.3f | %.2f | %.2f | %.2f | %.2f | %.1f | %.2f | %.2f |",
			mesh_count, thousands(vcount), thousands(tcount), setup_s, f64(cpu_bytes) / (1 << 20), rss, radius,
			touched_total / DABS, median(raycast), median(dab), median(flush), median(frame), slice.max(frame),
			f64(upload_bytes) / f64(frames) / (1 << 20), end_ms, undo_mb, undo_ms, redo_ms)
	}
	if mesh_count == 1 do bench_culling(s, vcount, tcount)
}

// Culls the sculpted sphere from the app's default camera, a close-up of the stroked
// area, and a detail view almost touching the surface, as the renderer would.
bench_culling :: proc(s: ^sculpt.Sculptor, vcount, tcount: int) {
	gpu_mb := f64(vcount * VERTEX_BYTES + tcount * 3 * 4 + len(s.chunks) * INDIRECT_BYTES) / (1 << 20)
	views := [3]struct {
		name:     string,
		distance: f32,
	}{{"whole (3.5)", 3.5}, {"close (1.6)", 1.6}, {"detail (1.15)", 1.15}}
	out: [dynamic]geom.Index_Range
	defer delete(out)
	for v in views {
		c := camera.orbit_default()
		c.yaw, c.pitch, c.distance = 0, 0.1, v.distance
		view := camera.orbit_view(c)
		proj := camera.orbit_proj(c, 16.0 / 9.0)
		best := max(f64)
		stats: geom.Cull_Stats
		for _ in 0 ..< 5 {
			clear(&out)
			t := time.tick_now()
			stats = geom.cull_chunks(s.chunks, proj * view, camera.orbit_eye(c), &out)
			best = min(best, time.duration_milliseconds(time.tick_since(t)))
		}
		drawn := 0
		for r in out do drawn += int(r.index_count / 3)
		append(&cull_rows, fmt.aprintf("| %s | %.0f | %s | %d | %.0f%% (%s) | %d | %.3f |",
			thousands(vcount), gpu_mb, v.name, stats.chunks, 100 * f64(drawn) / f64(tcount), thousands(drawn), len(out), best))
	}
}

// Touches and frees `mb` megabytes so later allocations reuse pages the OS has already
// backed. Cloud VMs back guest memory lazily, which makes the first touch of each page
// several times slower than on a desktop and would otherwise dominate setup times.
prefault :: proc(mb: int) {
	block := make([]u8, mb << 20)
	for i := 0; i < len(block); i += 4096 do block[i] = 1
	delete(block)
}

median :: proc(v: []f64) -> f64 {
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	return s[len(s) / 2]
}

thousands :: proc(n: int) -> string {
	if n >= 1_000_000 do return fmt.tprintf("%.2fM", f64(n) / 1e6)
	return fmt.tprintf("%dk", n / 1000)
}

peak_rss_mb :: proc() -> f64 {return status_mb("VmHWM:")}
rss_mb :: proc() -> f64 {return status_mb("VmRSS:")}

// A memory figure from /proc/self/status, in MB (0 where unavailable).
status_mb :: proc(key: string) -> f64 {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil do return 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, key) {
			fields := strings.fields(line, context.temp_allocator)
			if kb, ok2 := strconv.parse_f64(fields[1]); ok2 do return kb / 1024
		}
	}
	return 0
}
