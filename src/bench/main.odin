// Headless CPU benchmark of the sculpt pipeline at chosen mesh sizes. It needs no
// window or GPU, so results are comparable across machines and CI runs.
//
//   build/bench 500000 1000000 5000000
//
// For each target vertex count it builds a geodesic sphere, prepares it for sculpting,
// then runs the same strokes for a large and a small brush and prints one table row
// per brush. A frame is DABS_PER_FRAME dabs (each with its raycast) plus the flush
// that recomputes normals; GPU upload is the bytes of the dirty vertex ranges per frame.
//
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

import "../geom"
import "../jobs"
import "../sculpt"

Vec3 :: geom.Vec3

DABS :: 77
DABS_PER_FRAME :: 4 // a fast stroke lands several dabs per frame

node_triangles: u32 = sculpt.NODE_TRIANGLES
threads := 0
prefault_mb := 0

main :: proc() {
	targets := make([dynamic]int)
	defer delete(targets)
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--node=") {
			node_triangles = u32(strconv.parse_int(arg[7:]) or_else int(sculpt.NODE_TRIANGLES))
		} else if strings.has_prefix(arg, "--prefault=") {
			prefault_mb = strconv.parse_int(arg[11:]) or_else 0
		} else if strings.has_prefix(arg, "--threads=") {
			threads = strconv.parse_int(arg[10:]) or_else 0
		} else if v, ok := strconv.parse_int(arg); ok {
			append(&targets, v)
		}
	}
	if len(targets) == 0 do append(&targets, 500_000, 1_000_000, 5_000_000, 7_000_000, 10_000_000)
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

	fmt.println("| Vertices | Triangles | Setup s | Mesh MB | RSS MB | Brush | Verts/dab | Raycast ms | Dab ms | Normals ms/frame | Frame ms | Frame ms max | Upload MB/frame |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for target in targets {
		run(target, pool)
	}
	if prefault_mb == 0 do fmt.printfln("peak RSS: %.0f MB", peak_rss_mb())
}

run :: proc(target: int, pool: ^jobs.Pool) {
	t0 := time.tick_now()
	m := geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	defer geom.mesh_destroy(&m)
	s: sculpt.Sculptor
	sculpt.sculptor_init(&s, &m, pool, node_triangles)
	defer sculpt.sculptor_destroy(&s)
	free_all(context.temp_allocator)
	setup_s := time.duration_seconds(time.tick_since(t0))
	rss := rss_mb()

	vcount, tcount := len(m.positions), len(m.indices) / 3
	cpu_bytes := vcount * (2 * size_of(Vec3) + 4) + // positions, normals, vertex-face offsets
		tcount * (3 * 4 + 3 * 4 + 4 + 4) + // indices, face lists, bvh order/leaf
		len(s.bvh.nodes) * (size_of(geom.Bvh_Node) + 4) + len(s.nodes) * size_of(sculpt.Node) +
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
		for i in 0 ..< DABS {
			// Wavy stroke across the front of the sphere, as in the app's --bench-stroke.
			k := f32(i) / (DABS - 1)
			target_point := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
			ta := time.tick_now()
			hit, ok := sculpt.sculptor_raycast(&s, eye, linalg.normalize(target_point - eye))
			raycast[i] = time.duration_milliseconds(time.tick_since(ta))
			if !ok do hit = target_point
			tb := time.tick_now()
			touched_total += sculpt.apply_dab(&s, {kind = .Draw, radius = radius, strength = 0.3}, hit)
			dab[i] = time.duration_milliseconds(time.tick_since(tb))
			f := i / DABS_PER_FRAME
			frame[f] += raycast[i] + dab[i]
			if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
				tc := time.tick_now()
				for r in sculpt.sculptor_flush(&s) do upload_bytes += int(r.count) * 2 * size_of(Vec3)
				flush[f] = time.duration_milliseconds(time.tick_since(tc))
				frame[f] += flush[f]
			}
		}
		fmt.printfln("| %s | %s | %.1f | %.0f | %.0f | r=%.2f | %d | %.3f | %.3f | %.3f | %.2f | %.2f | %.2f |",
			thousands(vcount), thousands(tcount), setup_s, f64(cpu_bytes) / (1 << 20), rss, radius,
			touched_total / DABS, median(raycast), median(dab), median(flush), median(frame), slice.max(frame),
			f64(upload_bytes) / f64(frames) / (1 << 20))
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
