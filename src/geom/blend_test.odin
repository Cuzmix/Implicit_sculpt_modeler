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
scene_make :: proc(balls: []Ball, f: int, radius, strength: f32, pool: ^jobs.Pool, ids: []u32 = nil, opening := Blend_Opening.Organic) -> Scene {
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
		s.surfaces[i] = {mesh = m, bvh = bvh_build_morton(m, LOOKUP_LEAF, pool), faces = vertex_faces_build(m, pool), edge = blend_surface_edge(m)}
		blend_field_init(&s.fields[i], h, blend_band(h, radius))
		s.instances[i] = {
			surface = &s.surfaces[i],
			field   = &s.fields[i],
			place   = linalg.matrix4_translate(b.center),
			scale   = 1,
			id      = ids[i] if ids != nil else u32(i),
		}
		for j in 0 ..< i do append(&pairs, Blend_Pair{a = j, b = i, radius = radius, strength = strength, opening = opening})
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

// The seam's lift between any two of the scene's balls: their meshes share a frequency,
// but the larger ball's edges are the longer.
@(private = "file")
scene_lift :: proc(s: ^Scene, radius: f32) -> f32 {
	edge: f32
	for sf in s.surfaces do edge = max(edge, sf.edge)
	return blend_seam_lift(radius, edge)
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
reference :: proc(balls: []Ball, p: Vec3, radius, strength: f32, opening := Blend_Opening.Organic) -> (g: f32, amount: f32) {
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
		k := blend_radius_at(radius, linalg.dot(linalg.normalize0(grad), e.n), 1, opening)
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
	worst, lift, stray_most: f32
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
			// The fillet's edge keeps no step: a vertex outside the other ball moves only where
			// the reference blends. (One inside the other ball may cross into the fillet from
			// where the reference's share is just zero: hidden, and covering the seam.)
			outside := linalg.length(x0 - balls[1 - i].center) >= balls[1 - i].radius
			if _, a0 := reference(balls, x0, R, S); outside && a0 == 0 && linalg.length(m.offset) > 1e-4 * R {
				stray += 1
				stray_most = max(stray_most, linalg.length(m.offset))
			}
		}
	}
	fmt.printfln("blend (a): moved %d of %d scanned, %.2f steps, most %d, unconverged %d; worst |G_ref| %.5f (%.3f%% of R), largest lift %.4f",
		stats.moved, stats.scanned, f32(stats.steps) / max(f32(stats.moved), 1), stats.most_steps, stats.unconverged, worst, 100 * worst / R, lift)
	testing.expect(t, stats.moved > 200, "a fillet moves vertices")
	testing.expectf(t, worst < 0.01 * R, "moved vertices on the reference union within 1%% of R: worst %v", worst)
	testing.expectf(t, lift > 0.15 * R, "the fillet lifts the surface: largest move %v", lift)
	if stray > 0 do fmt.printfln("  strays %d, the largest moving %.6f (%.3f%% of R)", stray, stray_most, 100 * stray_most / R)
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
// order the instances are given in (bit for bit); with their ids shuffled the fold is the
// same too (it sorts by value, ids only break exact ties) and only the seams' owners
// change, so every vertex both runs move lands within the seam's lift; and every shown
// moved vertex lies on the one three-way union.
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
	over := 0
	for list, i in moves {
		for m in list {
			x := s.surfaces[i].mesh.positions[m.vertex] + balls[i].center + m.offset
			if g, _ := reference(balls, x, R, S); g > -1e-3 {
				worst = max(worst, abs(g))
				if abs(g) > 0.01 * R do over += 1
			}
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
	same_order := true
	ids_worst: f32
	both := 0
	for k, j in order {
		a, b := moves[k][:], moves2[j][:]
		if len(a) != len(b) || slice.equal(slice.to_bytes(a), slice.to_bytes(b)) == false do same_order = false
	}
	for i in 0 ..< 3 {
		a, b := moves[i][:], moves3[i][:]
		k := 0
		for m in a {
			for k < len(b) && b[k].vertex < m.vertex do k += 1
			if k == len(b) || b[k].vertex != m.vertex do continue
			ids_worst = max(ids_worst, linalg.length(m.offset - b[k].offset))
			both += 1
		}
	}
	fmt.printfln("blend (c): %d of the moved over 1%% of R", over)
	fmt.printfln("blend (c): moved %d, worst |G_ref| %.5f (%.3f%% of R); other order identical %v; other ids: %d vertices both move, largest difference %.2e (the lift %.2e)",
		stats.moved, worst, 100 * worst / R, same_order, both, ids_worst, scene_lift(&s, R))
	testing.expect(t, same_order, "another order gives the same bits")
	testing.expect(t, both > stats.moved / 2, "other ids move most of the same vertices")
	testing.expectf(t, ids_worst <= scene_lift(&s, R) * 1.001 + 1e-6, "other ids move them alike but for the lift: %v", ids_worst)
	// Where all three fillets meet, Gourmel's opening turns the radius steeply with the
	// gradients' angles, so the few vertices at the triple point land up to a few percent of
	// the radius off the analytic fold (6 of about 5,000 in 2026-11; halving the spacing took
	// the worst from 3.6 % to 2.7 %): all but 0.2 % within 1 % of R, every one within 4 %.
	testing.expectf(t, f32(over) <= 0.002 * f32(stats.moved), "all but 0.2%% within 1%% of R: %d over", over)
	testing.expectf(t, worst < 0.04 * R, "every shown moved vertex on the three-way union within 4%% of R: %v", worst)
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
		testing.expect(t, slice.equal(a.fields[i].extras[:], b.fields[i].extras[:]), "the same gradients and weights")
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

// The seam: the lower-id object (the owner) never shows past its cut line, the other's
// sheet reaches past the bisector to under it, so between them nothing is left open, and
// near the seam the owner's vertices stand the lift further out than the same vertices do
// when the other object owns the seam (the ids swapped).
@(test)
blend_seam_has_one_owner :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	balls := []Ball{{{0, 0, 0}, 1}, {{1.2, 0.1, 0}, 0.6}}
	R, S: f32 = 0.2, 1
	s := scene_make(balls, 60, R, S, &pool)
	defer scene_destroy(&s)
	moves, _ := project_all(&s, &pool)
	defer moves_destroy(moves)
	swapped := scene_make(balls, 60, R, S, &pool, ids = []u32{1, 0})
	defer scene_destroy(&swapped)
	moves2, _ := project_all(&swapped, &pool)
	defer moves_destroy(moves2)
	owner_past, under := 0, 0
	for m in moves[0] do if m.own < -BLEND_SEAM_CUT do owner_past += 1
	for m in moves[1] do if m.own < 0 do under += 1
	// Ball 0 owns the seam in the first run and not in the second.
	worst: f32
	seam := 0
	k := 0
	for m in moves[0] {
		for k < len(moves2[0]) && moves2[0][k].vertex < m.vertex do k += 1
		if k == len(moves2[0]) || moves2[0][k].vertex != m.vertex || abs(m.own) > 0.05 do continue
		want := scene_lift(&s, R) * clamp(1 - m.own / BLEND_SEAM_BAND, 0, 1)
		got := linalg.dot(m.offset - moves2[0][k].offset, m.normal)
		worst = max(worst, abs(got - want))
		seam += 1
	}
	fmt.printfln("blend seam: owner past its cut %d; other's vertices past the bisector %d; %d owner vertices at the seam stand out by the lift within %.2e (lift %.2e)",
		owner_past, under, seam, worst, scene_lift(&s, R))
	testing.expect_value(t, owner_past, 0)
	testing.expect(t, under > 0, "the other's sheet reaches past the bisector")
	testing.expect(t, seam > 0, "vertices at the seam")
	testing.expectf(t, worst < 1e-6, "the owner stands the lift out: off by %v", worst)
}

// Gourmel's bulging problem: two equal spheres a hair apart, their surfaces lying along
// each other with aligned gradients over a wide band. A blend that rounds there swells the
// shape by up to a quarter of the radius; Camel is a union there, so nothing shown stands
// outside the plain union by more than 1 % of the radius, and Organic, a third of a blend
// where gradients align, stays within a third of the full swell (plus the seam owner's
// lift). The swell is how far a moved vertex stands outside both spheres (the plain
// union's distance, positive outside).
@(test)
blend_aligned_surfaces_do_not_bulge :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	R, S: f32 = 0.2, 1
	balls := []Ball{{{0, 0, 0}, 1}, {{0.03, 0, 0}, 1}}
	swell :: proc(s: ^Scene, moves: [][dynamic]Blend_Move) -> (most: f32) {
		for list, i in moves {
			for m in list {
				x := s.surfaces[i].mesh.positions[m.vertex] + s.balls[i].center + m.offset
				plain := max(f32)
				for b in s.balls do plain = min(plain, linalg.length(x - b.center) - b.radius)
				most = max(most, plain)
			}
		}
		return
	}
	camel := scene_make(balls, 40, R, S, &pool, opening = .Camel)
	defer scene_destroy(&camel)
	camel_moves, _ := project_all(&camel, &pool)
	defer moves_destroy(camel_moves)
	organic := scene_make(balls, 40, R, S, &pool, opening = .Organic)
	defer scene_destroy(&organic)
	organic_moves, _ := project_all(&organic, &pool)
	defer moves_destroy(organic_moves)
	full := R * S / 4
	camel_swell, organic_swell := swell(&camel, camel_moves), swell(&organic, organic_moves)
	fmt.printfln("blend aligned: largest swell Camel %.5f, Organic %.5f, against a full blend's %.5f (R/4)", camel_swell, organic_swell, full)
	testing.expectf(t, camel_swell < 0.01 * R, "Camel adds nothing where surfaces align: %v", camel_swell)
	testing.expectf(t, organic_swell < full / 3 + scene_lift(&organic, R) + 0.01 * R, "Organic swells a third at most: %v", organic_swell)
	// The opening functions themselves: Camel a union aligned and opposed and a blend at a
	// right angle; Organic a third aligned, full from 60°, a union by 135°.
	testing.expect_value(t, blend_radius_at(1, 1, 1, .Camel), 0)
	testing.expect_value(t, blend_radius_at(1, -1, 1, .Camel), 0)
	testing.expect(t, abs(blend_radius_at(1, 0, 1, .Camel) - 1) < 1e-6)
	testing.expect(t, abs(blend_radius_at(1, 1, 1, .Organic) - 1.0 / 3) < 1e-6)
	testing.expect(t, abs(blend_radius_at(1, 0.5, 1, .Organic) - 1) < 1e-6)
	testing.expect_value(t, blend_radius_at(1, -0.75, 1, .Organic), 0)
}

// The opening functions' table follows Gourmel's curve within 1e-3 of a share at every
// cosine, steps and between them.
@(test)
blend_share_table_follows_the_curve :: proc(t: ^testing.T) {
	worst: f32
	for o in Blend_Opening {
		for i in 0 ..= 16 * BLEND_SHARE_STEPS {
			c := -1 + 2 * f32(i) / (16 * BLEND_SHARE_STEPS)
			exact := 1 - blend_opening_theta(o, math.acos(c)) / (math.PI / 4)
			worst = max(worst, abs(blend_share(o, c) - exact))
		}
	}
	fmt.printfln("blend share table: worst %.2e", worst)
	testing.expectf(t, worst < 1e-3, "within 1e-3 of a share: %v", worst)
}

// A brick sampled apart from the field (as a fill on threads of its own does) holds the
// same samples as one the field filled itself, whatever order the bricks are put in, and a
// brick put twice is refused.
@(test)
blend_brick_put_matches_the_fill :: proc(t: ^testing.T) {
	balls := []Ball{{{0, 0, 0}, 1}, {{1.2, 0.1, 0}, 0.6}}
	s := scene_make(balls, 40, 0.2, 1, nil)
	defer scene_destroy(&s)
	whole := &s.fields[0]
	part: Blend_Field
	blend_field_init(&part, whole.h, whole.band)
	defer blend_field_destroy(&part)
	b := new(Blend_Brick)
	defer free(b)
	#reverse for k in whole.keys {
		blend_brick_sample(part.h, part.band, &s.surfaces[0], k, b)
		revision := part.revision
		testing.expect(t, blend_field_put(&part, b), "put once")
		testing.expect(t, part.revision != revision, "the table moved on")
		testing.expect(t, !blend_field_put(&part, b), "refused twice")
	}
	testing.expect_value(t, len(part.keys), len(whole.keys))
	for k, i in whole.keys {
		j := int(blend_field_slot(&part, k))
		testing.expect(t, j >= 0, "every brick published")
		if j < 0 do continue
		a, c := whole.values[i * BLEND_SAMPLES:][:BLEND_SAMPLES], part.values[j * BLEND_SAMPLES:][:BLEND_SAMPLES]
		testing.expect(t, slice.equal(slice.to_bytes(a), slice.to_bytes(c)), "the same distances")
		testing.expect(t, slice.equal(whole.extras[i * BLEND_SAMPLES:][:BLEND_SAMPLES], part.extras[j * BLEND_SAMPLES:][:BLEND_SAMPLES]), "the same gradients and weights")
	}
}

// The guard's soft start: nothing of the march past a turn at the guard, all of it before
// its start, and more the gentler the turn, so a vertex's place follows the angle without a jump.
@(test)
blend_turn_weight_is_smooth :: proc(t: ^testing.T) {
	testing.expect_value(t, blend_turn_weight(BLEND_TURN_COS), 0)
	testing.expect_value(t, blend_turn_weight(BLEND_TURN_COS_SOFT), 1)
	testing.expect_value(t, blend_turn_weight(0), 0)
	testing.expect_value(t, blend_turn_weight(1), 1)
	last: f32 = 0
	for i in 0 ..= 100 {
		c := BLEND_TURN_COS + (BLEND_TURN_COS_SOFT - BLEND_TURN_COS) * f32(i) / 100
		w := blend_turn_weight(c)
		testing.expectf(t, w >= last && w - last < 0.02, "step %d: %v after %v", i, w, last)
		last = w
	}
}

// Dropping the bricks a box meets takes out those and only those, and the rest still read
// the same distances by key.
@(test)
blend_field_drop_takes_what_the_box_meets :: proc(t: ^testing.T) {
	balls := []Ball{{{0, 0, 0}, 1}, {{1.2, 0.1, 0}, 0.6}}
	s := scene_make(balls, 40, 0.2, 1, nil)
	defer scene_destroy(&s)
	f := &s.fields[0]
	before := make([]u64, len(f.keys))
	defer delete(before)
	copy(before, f.keys[:])
	values := make([]f32, len(f.values))
	defer delete(values)
	copy(values, f.values[:])
	box := Aabb{{0.8, -0.2, -0.2}, {1.0, 0.2, 0.2}}
	size := f.h * BLEND_BRICK
	meets :: proc(k: u64, box: Aabb, size: f32) -> bool {
		b := blend_unkey(k)
		lo := Vec3{f32(b.x), f32(b.y), f32(b.z)} * size
		hi := lo + size
		return box.lo.x <= hi.x && box.hi.x >= lo.x && box.lo.y <= hi.y && box.hi.y >= lo.y && box.lo.z <= hi.z && box.hi.z >= lo.z
	}
	want := 0
	for k in before do if meets(k, box, size) do want += 1
	testing.expect(t, want > 0 && want < len(before), "the box meets some bricks and not all")
	revision := f.revision
	testing.expect_value(t, blend_field_drop(f, {box}, 0), want)
	testing.expect(t, f.revision != revision, "the table moved on")
	testing.expect_value(t, len(f.keys), len(before) - want)
	for k, i in before {
		slot := blend_field_slot(f, k)
		if meets(k, box, size) {
			testing.expectf(t, slot < 0, "brick %d dropped", i)
			continue
		}
		testing.expectf(t, slot >= 0, "brick %d kept", i)
		if slot < 0 do continue
		a, c := values[i * BLEND_SAMPLES:][:BLEND_SAMPLES], f.values[int(slot) * BLEND_SAMPLES:][:BLEND_SAMPLES]
		testing.expectf(t, slice.equal(slice.to_bytes(a), slice.to_bytes(c)), "brick %d reads the same", i)
	}
}
