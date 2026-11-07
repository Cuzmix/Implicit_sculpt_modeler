package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"

// --blend: Smooth blend's field and projection (the Live stack row; design in
// .claude/project-memory/notes/smooth-blend/design.md) on an arm pushed into a torso: two
// spheres, the torso holding three quarters of the vertices, joined at radius
// BLEND_RADIUS. Each size runs four ways: the field at the spacing the row uses (a power
// of two between R/6 and R/3) and at half of it, each filled from the meshes themselves
// and from stand-ins of BLEND_STAND_IN vertices (as the simplified copies could serve).
// Columns: the bricks the pair needs and their samples, the field's bytes, the marking and
// the fill on the pool and on one thread, a single query's time (p50 and p99 over random
// samples of the field, one thread), the vertices near the partner and those moved, the
// 1024-vertex pages the moves touch and their bytes at 16 a vertex, Newton's mean and
// largest steps and the unconverged, the projection on the pool, the worst distance of a
// moved vertex from the analytic union in radii, and the worst angle between a moved
// vertex's normal and the analytic union's.
BLEND_RADIUS :: 0.12
BLEND_STAND_IN :: 100_000
BLEND_QUERY_SAMPLES :: 4000

blend_header :: proc() {
	fmt.println("| Vertices | h | Source | Bricks | Samples | Field MB | Mark ms | Fill ms | Fill ms 1 thread | Query µs p50 | Query µs p99 | Scanned | Moved | Pages | Pages MB | Steps | Steps max | Unconverged | Project ms | Worst \\|G\\| / R | Normal error ° |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

@(private = "file")
Ball :: struct {
	center: Vec3,
	radius: f32,
}

@(private = "file")
BALLS :: [2]Ball{{{0, 0, 0}, 1}, {{1.1, 0.1, 0}, 0.35}}

@(private = "file")
surface_make :: proc(vertices: int, radius: f32, pool: ^jobs.Pool) -> geom.Blend_Surface {
	m := geom.geodesic_sphere(geom.geodesic_frequency_for(vertices), pool)
	for &p in m.positions do p *= radius
	geom.mesh_recompute_normals(&m)
	return {mesh = m, bvh = geom.bvh_build_morton(m, geom.LOOKUP_LEAF, pool), faces = geom.vertex_faces_build(m, pool)}
}

@(private = "file")
surface_destroy :: proc(s: ^geom.Blend_Surface) {
	geom.mesh_destroy(&s.mesh)
	geom.bvh_destroy(&s.bvh)
	geom.vertex_faces_destroy(&s.faces)
}

run_blend :: proc(vertices: int, pool: ^jobs.Pool) {
	balls := BALLS
	full := [2]geom.Blend_Surface{surface_make(vertices * 3 / 4, balls[0].radius, pool), surface_make(vertices / 4, balls[1].radius, pool)}
	defer for &s in full do surface_destroy(&s)
	stand := [2]geom.Blend_Surface{surface_make(BLEND_STAND_IN * 3 / 4, balls[0].radius, pool), surface_make(BLEND_STAND_IN / 4, balls[1].radius, pool)}
	defer for &s in stand do surface_destroy(&s)
	total := len(full[0].mesh.positions) + len(full[1].mesh.positions)
	free_all(context.temp_allocator)
	for fine in ([]bool{false, true}) {
		for from_stand in ([]bool{false, true}) {
			h := geom.blend_spacing(BLEND_RADIUS)
			if fine do h *= 0.5
			blend_row(total, h, &full, &stand if from_stand else nil, pool)
			free_all(context.temp_allocator)
		}
	}
}

@(private = "file")
blend_row :: proc(total: int, h: f32, full: ^[2]geom.Blend_Surface, stand: ^[2]geom.Blend_Surface, pool: ^jobs.Pool) {
	balls := BALLS
	fields: [2]geom.Blend_Field
	instances: [2]geom.Blend_Instance
	for i in 0 ..< 2 {
		geom.blend_field_init(&fields[i], h, geom.blend_band(h, BLEND_RADIUS))
		instances[i] = {surface = &full[i], field = &fields[i], place = linalg.matrix4_translate(balls[i].center), scale = 1, id = u32(i)}
	}
	defer for &f in fields do geom.blend_field_destroy(&f)
	pairs := []geom.Blend_Pair{{a = 0, b = 1, radius = BLEND_RADIUS, strength = 1}}
	want: [2][dynamic]u64
	for &w in want do w = make([dynamic]u64, context.temp_allocator)
	t0 := time.tick_now()
	geom.blend_pair_bricks(instances[:], pairs[0], &want[0], &want[1], pool)
	mark_ms := time.duration_milliseconds(time.tick_since(t0))
	source := stand if stand != nil else full
	t1 := time.tick_now()
	for i in 0 ..< 2 do geom.blend_field_fill(&fields[i], &source[i], want[i][:], pool)
	fill_ms := time.duration_milliseconds(time.tick_since(t1))
	// The same fill on the calling thread, into fresh fields.
	serial: [2]geom.Blend_Field
	for i in 0 ..< 2 do geom.blend_field_init(&serial[i], h, geom.blend_band(h, BLEND_RADIUS))
	defer for &f in serial do geom.blend_field_destroy(&f)
	t2 := time.tick_now()
	for i in 0 ..< 2 do geom.blend_field_fill(&serial[i], &source[i], want[i][:], nil)
	fill1_ms := time.duration_milliseconds(time.tick_since(t2))
	bricks := len(fields[0].keys) + len(fields[1].keys)
	field_mb := f64(geom.blend_field_bytes(&fields[0]) + geom.blend_field_bytes(&fields[1])) / (1 << 20)
	p50, p99 := query_times(&fields[0], &source[0])

	moves: [2][dynamic]geom.Blend_Move
	for &m in moves do m = make([dynamic]geom.Blend_Move, context.temp_allocator)
	stats: [2]geom.Blend_Stats
	t3 := time.tick_now()
	for i in 0 ..< 2 do stats[i] = geom.blend_project(instances[:], pairs, i, &moves[i], pool)
	project_ms := time.duration_milliseconds(time.tick_since(t3))
	pages := 0
	worst, worst_angle: f32
	steps, most, unconverged, scanned, moved := 0, 0, 0, 0, 0
	for i in 0 ..< 2 {
		last := -1
		for m in moves[i] {
			if p := int(m.vertex >> 10); p != last {
				pages += 1
				last = p
			}
			x := full[i].mesh.positions[m.vertex] + balls[i].center + m.offset
			g, grad := reference(x)
			if g > -1e-3 {
				worst = max(worst, abs(g) / BLEND_RADIUS)
				if linalg.length(grad) > 0 {
					c := clamp(linalg.dot(linalg.normalize(grad), m.normal), -1, 1)
					worst_angle = max(worst_angle, math.acos(c) * 180 / math.PI)
				}
			}
		}
		steps += stats[i].steps
		most = max(most, stats[i].most_steps)
		unconverged += stats[i].unconverged
		scanned += stats[i].scanned
		moved += stats[i].moved
	}
	fmt.printfln("| %d | %.4f | %s | %d | %d | %.2f | %.1f | %.1f | %.1f | %.2f | %.2f | %d | %d | %d | %.1f | %.2f | %d | %d | %.2f | %.4f | %.2f |",
		total, h, "stand-in" if stand != nil else "mesh", bricks, bricks * geom.BLEND_SAMPLES, field_mb, mark_ms, fill_ms, fill1_ms, p50, p99,
		scanned, moved, pages, f64(pages * 1024 * 16) / (1 << 20), f64(steps) / max(f64(moved), 1), most, unconverged, project_ms, worst, worst_angle)
}

// A single closest-point query's time, one thread, at random samples of a field's bricks:
// the p50 and p99 in microseconds.
@(private = "file")
query_times :: proc(f: ^geom.Blend_Field, s: ^geom.Blend_Surface) -> (p50, p99: f64) {
	if len(f.keys) == 0 do return
	r := rand.create(7)
	times := make([]f64, BLEND_QUERY_SAMPLES, context.temp_allocator)
	for &t in times {
		b := geom.blend_unkey(f.keys[rand.int_max(len(f.keys), rand.default_random_generator(&r))])
		u := Vec3{rand.float32(rand.default_random_generator(&r)), rand.float32(rand.default_random_generator(&r)), rand.float32(rand.default_random_generator(&r))}
		p := (Vec3{f32(b.x), f32(b.y), f32(b.z)} + u) * (f.h * geom.BLEND_BRICK)
		t0 := time.tick_now()
		_, _, _, _ = geom.surface_distance(s, p, f.band)
		t = time.duration_microseconds(time.tick_since(t0))
	}
	slice.sort(times)
	return times[len(times) / 2], times[len(times) * 99 / 100]
}

// The analytic union of the two balls at a world point, folded as the projection folds
// (by value, the pair joined at the bench's radius, full strength), and its gradient by
// central differences.
@(private = "file")
reference :: proc(x: Vec3) -> (g: f32, grad: Vec3) {
	value :: proc(x: Vec3) -> f32 {
		balls := BALLS
		a := linalg.length(x - balls[0].center) - balls[0].radius
		b := linalg.length(x - balls[1].center) - balls[1].radius
		na, nb := linalg.normalize0(x - balls[0].center), linalg.normalize0(x - balls[1].center)
		if b < a do a, b, na, nb = b, a, nb, na
		k := geom.blend_radius_at(BLEND_RADIUS, linalg.dot(na, nb), 1)
		g, _, _ := geom.blend_union(a, b, na, nb, k, 1)
		return g
	}
	g = value(x)
	e: f32 = 1e-4
	grad = {value(x + {e, 0, 0}) - value(x - {e, 0, 0}), value(x + {0, e, 0}) - value(x - {0, e, 0}), value(x + {0, 0, e}) - value(x - {0, 0, e})} / (2 * e)
	return
}
