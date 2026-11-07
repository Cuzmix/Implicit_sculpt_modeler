package geom

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

// Smooth blend's quality, held to an analytic reference: spheres' exact distances folded by
// the same operator, so any error is the field's sampling and the projection's.

@(private = "file")
Ball :: struct {
	center: Vec3,
	radius: f32,
}

@(private = "file")
Scene :: struct {
	balls:     []Ball,
	surfaces:  []Blend_Surface,
	fields:    []Blend_Field,
	instances: []Blend_Instance,
	pairs:     []Blend_Pair,
}

// A geodesic sphere of frequency `f` round each ball (meshed at the origin and placed by
// its instance, so the fields live in each object's own space), a field each at the
// radius's spacing, and every pair of balls joined at `radius` and `strength`.
@(private = "file")
scene_make :: proc(balls: []Ball, f: int, radius, strength: f32, pool: ^jobs.Pool, ids: []u32 = nil) -> Scene {
	s := Scene{balls = balls}
	n := len(balls)
	s.surfaces = make([]Blend_Surface, n)
	s.fields = make([]Blend_Field, n)
	s.instances = make([]Blend_Instance, n)
	pairs := make([dynamic]Blend_Pair)
	h := blend_spacing(radius)
	for b, i in balls {
		m := geodesic_sphere(f, pool)
		for &p in m.positions do p *= b.radius
		mesh_recompute_normals(&m)
		s.surfaces[i] = {mesh = m, bvh = bvh_build_morton(m, LOOKUP_LEAF, pool), faces = vertex_faces_build(m, pool)}
		blend_field_init(&s.fields[i], h, blend_band(h, radius))
		s.instances[i] = {
			surface = &s.surfaces[i],
			field   = &s.fields[i],
			place   = linalg.matrix4_translate(b.center),
			scale   = 1,
			id      = ids[i] if ids != nil else u32(i),
		}
		for j in 0 ..< i do append(&pairs, Blend_Pair{a = j, b = i, radius = radius, strength = strength})
	}
	s.pairs = pairs[:]
	for p in s.pairs {
		want_a := make([dynamic]u64, context.temp_allocator)
		want_b := make([dynamic]u64, context.temp_allocator)
		blend_pair_bricks(s.instances, p, &want_a, &want_b, pool)
		blend_field_fill(&s.fields[p.a], &s.surfaces[p.a], want_a[:], pool)
		blend_field_fill(&s.fields[p.b], &s.surfaces[p.b], want_b[:], pool)
	}
	return s
}

@(private = "file")
scene_destroy :: proc(s: ^Scene) {
	for &sf in s.surfaces {
		mesh_destroy(&sf.mesh)
		bvh_destroy(&sf.bvh)
		vertex_faces_destroy(&sf.faces)
	}
	for &f in s.fields do blend_field_destroy(&f)
	delete(s.surfaces)
	delete(s.fields)
	delete(s.instances)
	delete(s.pairs)
}

// The reference: the balls' exact distances folded as blend_project folds fields, sorted
// by value, every pair joined, at a world point.
@(private = "file")
reference :: proc(balls: []Ball, p: Vec3, radius, strength: f32) -> (g: f32, amount: f32) {
	Term :: struct {
		d: f32,
		n: Vec3,
	}
	terms := make([]Term, len(balls), context.temp_allocator)
	for b, i in balls do terms[i] = {linalg.length(p - b.center) - b.radius, linalg.normalize0(p - b.center)}
	slice.sort_by(terms, proc(a, b: Term) -> bool {return a.d < b.d})
	grad: Vec3
	g, grad = terms[0].d, terms[0].n
	for e in terms[1:] {
		k := blend_radius_at(radius, linalg.dot(linalg.normalize0(grad), e.n), 1)
		h: f32
		g, grad, h = blend_union(g, e.d, grad, e.n, k, strength)
		amount = max(amount, strength * h)
	}
	return
}

@(private = "file")
project_all :: proc(s: ^Scene, pool: ^jobs.Pool) -> (moves: [][dynamic]Blend_Move, stats: Blend_Stats) {
	moves = make([][dynamic]Blend_Move, len(s.instances))
	for i in 0 ..< len(s.instances) {
		st := blend_project(s.instances, s.pairs, i, &moves[i], pool)
		stats.scanned += st.scanned
		stats.moved += st.moved
		stats.steps += st.steps
		stats.unconverged += st.unconverged
		stats.most_steps = max(stats.most_steps, st.most_steps)
	}
	return
}

@(private = "file")
moves_destroy :: proc(moves: [][dynamic]Blend_Move) {
	for m in moves do delete(m)
	delete(moves)
}

// (a) Two spheres crossing: every moved vertex lies on the analytic smooth union within
// 1 % of the radius, a fillet forms (vertices lift by most of the full lift R/4), and
// nothing moves where the reference blends nothing.
@(test)
blend_fillet_follows_the_analytic_union :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	balls := []Ball{{{0, 0, 0}, 1}, {{1.2, 0.1, 0}, 0.6}}
	R, S: f32 = 0.2, 1
	s := scene_make(balls, 60, R, S, &pool)
	defer scene_destroy(&s)
	moves, stats := project_all(&s, &pool)
	defer moves_destroy(moves)
	worst, lift: f32
	stray := 0
	for list, i in moves {
		for m in list {
			x0 := s.surfaces[i].mesh.positions[m.vertex] + balls[i].center
			x := x0 + m.offset
			g, _ := reference(balls, x, R, S)
			// A vertex hidden inside the other ball may sit on the union's inside; only the
			// ones the union shows are held to it.
			if g > -1e-3 do worst = max(worst, abs(g))
			lift = max(lift, linalg.length(m.offset))
			if _, a0 := reference(balls, x0, R, S); a0 == 0 && linalg.length(m.offset) > 1e-4 * R do stray += 1
		}
	}
	fmt.printfln("blend (a): moved %d of %d scanned, %.2f steps, most %d, unconverged %d; worst |G_ref| %.5f (%.3f%% of R), largest lift %.4f",
		stats.moved, stats.scanned, f32(stats.steps) / max(f32(stats.moved), 1), stats.most_steps, stats.unconverged, worst, 100 * worst / R, lift)
	testing.expect(t, stats.moved > 200, "a fillet moves vertices")
	testing.expectf(t, worst < 0.01 * R, "moved vertices on the reference union within 1%% of R: worst %v", worst)
	testing.expectf(t, lift > 0.15 * R, "the fillet lifts the surface: largest move %v", lift)
	testing.expect_value(t, stray, 0)
	testing.expect_value(t, stats.unconverged, 0)
}

// (b) Two spheres a gap of half the radius apart, facing each other: the controller turns
// the blend off, so no vertex moves toward the other by more than a hundredth of the
// radius (no bridge, no bulge).
@(test)
blend_does_not_bridge_a_gap :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	R, S: f32 = 0.2, 1
	balls := []Ball{{{0, 0, 0}, 1}, {{1.5 + 0.5 * R, 0, 0}, 0.5}}
	s := scene_make(balls, 60, R, S, &pool)
	defer scene_destroy(&s)
	moves, stats := project_all(&s, &pool)
	defer moves_destroy(moves)
	toward: f32
	for list, i in moves {
		other := balls[1 - i].center - balls[i].center
		for m in list do toward = max(toward, linalg.dot(m.offset, linalg.normalize(other)))
	}
	fmt.printfln("blend (b): %d scanned near the other, %d moved, largest move toward the other %.6f (%.3f%% of R)", stats.scanned, stats.moved, toward, 100 * toward / R)
	testing.expect(t, stats.scanned > 0, "the gap is within reach, so vertices are looked at")
	testing.expectf(t, toward < 0.01 * R, "no move toward the other past 1%% of R: %v", toward)
}

// (c) Three spheres meeting at one place: each object's result is the same whatever the
// order the instances are given in (bit for bit), and with their ids shuffled too (the
// fold sorts by value, ids only break exact ties), and every shown moved vertex lies on
// the one three-way union.
@(test)
blend_three_way_junction_ignores_the_order :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	R, S: f32 = 0.15, 1
	balls := []Ball{{{0, 0, 0}, 0.6}, {{0.9, 0, 0}, 0.5}, {{0.45, 0.75, 0}, 0.5}}
	s := scene_make(balls, 50, R, S, &pool)
	defer scene_destroy(&s)
	moves, stats := project_all(&s, &pool)
	defer moves_destroy(moves)
	worst: f32
	for list, i in moves {
		for m in list {
			x := s.surfaces[i].mesh.positions[m.vertex] + balls[i].center + m.offset
			if g, _ := reference(balls, x, R, S); g > -1e-3 do worst = max(worst, abs(g))
		}
	}
	// The same balls given in another order, and with other ids.
	order := []int{2, 0, 1}
	shuffled := []Ball{balls[2], balls[0], balls[1]}
	s2 := scene_make(shuffled, 50, R, S, &pool, ids = []u32{2, 0, 1})
	defer scene_destroy(&s2)
	moves2, _ := project_all(&s2, &pool)
	defer moves_destroy(moves2)
	s3 := scene_make(balls, 50, R, S, &pool, ids = []u32{7, 3, 5})
	defer scene_destroy(&s3)
	moves3, _ := project_all(&s3, &pool)
	defer moves_destroy(moves3)
	same_order, same_ids := true, true
	ids_worst: f32
	for k, j in order {
		a, b := moves[k][:], moves2[j][:]
		if len(a) != len(b) || slice.equal(slice.to_bytes(a), slice.to_bytes(b)) == false do same_order = false
	}
	for i in 0 ..< 3 {
		a, b := moves[i][:], moves3[i][:]
		if len(a) != len(b) {
			same_ids = false
			continue
		}
		for m, k in a do ids_worst = max(ids_worst, linalg.length(m.offset - b[k].offset))
	}
	fmt.printfln("blend (c): moved %d, worst |G_ref| %.5f (%.3f%% of R); other order identical %v; other ids: same vertices %v, largest difference %.2e",
		stats.moved, worst, 100 * worst / R, same_order, same_ids, ids_worst)
	testing.expect(t, same_order, "another order gives the same bits")
	testing.expect(t, same_ids, "other ids move the same vertices")
	testing.expectf(t, ids_worst < 1e-6, "other ids move them the same: %v", ids_worst)
	testing.expectf(t, worst < 0.01 * R, "every shown moved vertex on the three-way union within 1%% of R: %v", worst)
}

// (d) The fields and the moves are the same bits on one thread and on several.
@(test)
blend_serial_matches_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	balls := []Ball{{{0, 0, 0}, 1}, {{1.2, 0.1, 0}, 0.6}}
	a := scene_make(balls, 40, 0.2, 0.8, nil)
	defer scene_destroy(&a)
	b := scene_make(balls, 40, 0.2, 0.8, &pool)
	defer scene_destroy(&b)
	for i in 0 ..< 2 {
		testing.expect(t, slice.equal(a.fields[i].keys[:], b.fields[i].keys[:]), "the same bricks")
		testing.expect(t, slice.equal(slice.to_bytes(a.fields[i].values[:]), slice.to_bytes(b.fields[i].values[:])), "the same distances")
		testing.expect(t, slice.equal(a.fields[i].weights[:], b.fields[i].weights[:]), "the same weights")
	}
	ma, _ := project_all(&a, nil)
	defer moves_destroy(ma)
	mb, _ := project_all(&b, &pool)
	defer moves_destroy(mb)
	for i in 0 ..< 2 {
		testing.expect(t, len(ma[i]) > 0 && slice.equal(slice.to_bytes(ma[i][:]), slice.to_bytes(mb[i][:])), "the same moves")
	}
}

// The field's values match the sphere's exact distance within the mesh's sagitta and the
// sign is right inside and out, from the pseudo-normals alone.
@(test)
blend_field_matches_the_distance :: proc(t: ^testing.T) {
	balls := []Ball{{{0, 0, 0}, 1}, {{1.2, 0.1, 0}, 0.6}}
	s := scene_make(balls, 60, 0.2, 1, nil)
	defer scene_destroy(&s)
	f := &s.fields[0]
	worst: f32
	signs := 0
	for k, slot in f.keys {
		b := blend_unkey(k)
		lo := Vec3{f32(b.x), f32(b.y), f32(b.z)} * (f.h * BLEND_BRICK)
		for i in 0 ..< BLEND_SAMPLES {
			p := lo + Vec3{f32(i % BLEND_SIDE), f32((i / BLEND_SIDE) % BLEND_SIDE), f32(i / (BLEND_SIDE * BLEND_SIDE))} * f.h
			exact := linalg.length(p) - 1
			v := f.values[slot * BLEND_SAMPLES + i]
			if abs(exact) < f.band * 0.9 do worst = max(worst, abs(v - exact))
			if (v < 0) != (exact < 0) && abs(exact) > 1e-3 do signs += 1
		}
	}
	fmt.printfln("blend field: %d bricks, worst error %.6f, wrong signs %d", len(f.keys), worst, signs)
	testing.expect(t, len(f.keys) > 0)
	testing.expectf(t, worst < 1e-3, "within the mesh's sagitta: %v", worst)
	testing.expect_value(t, signs, 0)
	_ = math.PI
}
