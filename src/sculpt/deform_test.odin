package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A bar along y from -1 to 1 of radius 0.2: 20 rings of 16 between two poles on the axis.
@(private = "file")
Bar :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

@(private = "file")
bar_make :: proc(pool: ^jobs.Pool = nil) -> ^Bar {
	b := new(Bar)
	profile: [22]geom.Vec2
	profile[0], profile[21] = {0, -1}, {0, 1}
	for k in 1 ..= 20 do profile[k] = {0.2, -1 + 2 * f32(k - 1) / 19}
	b.mesh = geom.lathe(profile[:], 16)
	sculptor_init(&b.sculptor, &b.mesh, pool, 64)
	return b
}

@(private = "file")
bar_free :: proc(b: ^Bar) {
	sculptor_destroy(&b.sculptor)
	geom.mesh_destroy(&b.mesh)
	free(b)
}

// Deforms the whole bar along y by `d` as one pose, returning where it began.
@(private = "file")
bar_deform :: proc(t: ^testing.T, b: ^Bar, d: Deform) -> []Vec3 {
	s := &b.sculptor
	before := slice.clone(b.mesh.positions[:], context.temp_allocator)
	lo, hi, ok := sculptor_free_bounds(s)
	testing.expect(t, ok)
	d := d
	d.lo, d.hi = lo, hi
	testing.expect(t, sculptor_pose_begin(s))
	sculptor_pose_apply(s, {kind = .Deform, deform = d})
	return before
}

// A twist turns the far end by the whole amount about the axis, keeps every vertex's
// distance to it and its height, and leaves the fixed end.
@(test)
deform_twist_turns_the_far_end :: proc(t: ^testing.T) {
	b := bar_make()
	defer bar_free(b)
	before := bar_deform(t, b, {kind = .Twist, along = .Y, amount = math.PI / 2})
	worst: f32
	for a, v in before {
		p := b.mesh.positions[v]
		want := a
		if a.y == 1 do want = {a.z, a.y, -a.x} // a quarter turn about +y
		if a.y == -1 do worst = max(worst, linalg.length(p - a))
		if a.y == 1 do worst = max(worst, linalg.length(p - want))
		worst = max(worst, abs(linalg.length(p.xz) - linalg.length(a.xz)), abs(p.y - a.y))
	}
	testing.expectf(t, worst < 1e-5, "twisted %v off", worst)
	testing.expect(t, sculptor_pose_end(&b.sculptor))
	testing.expect(t, sculptor_undo(&b.sculptor))
	testing.expect(t, slice.equal(b.mesh.positions[:], before))
}

// A taper scales across the axis by 1 + amount at the far end, in proportion between,
// and keeps heights; from the + end it is the - end that changes.
@(test)
deform_taper_scales_toward_the_far_end :: proc(t: ^testing.T) {
	for from_plus in ([2]bool{false, true}) {
		b := bar_make()
		defer bar_free(b)
		before := bar_deform(t, b, {kind = .Taper, along = .Y, from_plus = from_plus, amount = -0.5})
		worst: f32
		for a, v in before {
			p := b.mesh.positions[v]
			along := (1 - a.y) / 2 if from_plus else (a.y + 1) / 2
			worst = max(worst, linalg.length(p - Vec3{a.x * (1 - 0.5 * along), a.y, a.z * (1 - 0.5 * along)}))
		}
		testing.expectf(t, worst < 1e-5, "from the + end %v: tapered %v off", from_plus, worst)
		_ = sculptor_pose_end(&b.sculptor)
	}
}

// A bend keeps the axis's length: its far end goes to the end of an arc turned by the
// amount, each ring stays the same ring (turned, not stretched), and the fixed end stays.
@(test)
deform_bend_keeps_the_length :: proc(t: ^testing.T) {
	theta: f32 = math.PI / 2
	b := bar_make()
	defer bar_free(b)
	before := bar_deform(t, b, {kind = .Bend, along = .Y, toward = .X, amount = theta})
	m := b.mesh.positions[:]
	// The sculptor orders vertices by node, so the poles and the top ring are found by
	// where they began.
	ring := make([dynamic]int, context.temp_allocator)
	for a, v in before {
		switch {
		case a == {0, 1, 0}:
			want := Vec3{2 * (1 - math.cos(theta)) / theta, -1 + 2 * math.sin(theta) / theta, 0}
			testing.expectf(t, linalg.length(m[v] - want) < 1e-5, "the far end went to %v, not %v", m[v], want)
		case a == {0, -1, 0}:
			testing.expect(t, m[v] == a)
		case a.y == 1:
			append(&ring, v)
		}
	}
	testing.expect_value(t, len(ring), 16)
	// The top ring keeps its shape: every pair stays as far apart.
	worst: f32
	for i in ring do for j in ring {
		worst = max(worst, abs(linalg.length(m[i] - m[j]) - linalg.length(before[i] - before[j])))
	}
	testing.expectf(t, worst < 1e-5, "the top ring stretched by %v", worst)
	// And it faces along the arc's end: turned by the amount about z.
	n := linalg.normalize(linalg.cross(m[ring[4]] - m[ring[0]], m[ring[9]] - m[ring[0]]))
	facing := Vec3{math.sin(theta), math.cos(theta), 0}
	testing.expectf(t, abs(abs(linalg.dot(n, facing)) - 1) < 1e-4, "the top ring faces %v", n)
	_ = sculptor_pose_end(&b.sculptor)
}

// A bend by almost nothing moves almost nothing, with no rounding to a coarse grid.
@(test)
deform_bend_by_a_hair_is_smooth :: proc(t: ^testing.T) {
	for amount in ([3]f32{1e-6, 2e-5, -3e-4}) {
		b := bar_make()
		defer bar_free(b)
		before := bar_deform(t, b, {kind = .Bend, along = .Y, toward = .X, amount = amount})
		worst: f32
		for a, v in before do worst = max(worst, linalg.length(b.mesh.positions[v] - a))
		testing.expectf(t, worst <= 2 * abs(amount) + 1e-6, "a bend of %v moved a vertex %v", amount, worst)
		_ = sculptor_pose_end(&b.sculptor)
	}
}

// Masked vertices stay; the bounds are the free part's; half-masked ones take part of it.
@(test)
deform_keeps_to_the_mask :: proc(t: ^testing.T) {
	b := bar_make()
	defer bar_free(b)
	s := &b.sculptor
	values := make([]u8, len(b.mesh.positions), context.temp_allocator)
	for p, v in b.mesh.positions do values[v] = 255 if p.y < 0 else 0
	testing.expect(t, sculptor_mask_values(s, values, .Replace))
	lo, hi, ok := sculptor_free_bounds(s)
	testing.expect(t, ok && lo.y >= 0 && hi.y == 1)
	before := bar_deform(t, b, {kind = .Twist, along = .Y, amount = 1})
	moved := 0
	for a, v in before {
		if values[v] == 255 do testing.expect(t, b.mesh.positions[v] == a)
		else do moved += int(b.mesh.positions[v] != a)
	}
	testing.expect(t, moved > 0)
	_ = sculptor_pose_end(s)
	// Nothing free: no bounds.
	for &k in values do k = 255
	testing.expect(t, sculptor_mask_values(s, values, .Replace))
	_, _, ok = sculptor_free_bounds(s)
	testing.expect(t, !ok)
}

// An amount of 0 changes nothing, bit for bit; a bend toward its own axis neither.
@(test)
deform_nothing_is_nothing :: proc(t: ^testing.T) {
	for d in ([3]Deform{{kind = .Bend, along = .Y, toward = .X}, {kind = .Twist, along = .Z}, {kind = .Bend, along = .Y, toward = .Y, amount = 1}}) {
		b := bar_make()
		defer bar_free(b)
		before := bar_deform(t, b, d)
		testing.expect(t, slice.equal(b.mesh.positions[:], before))
		sculptor_pose_cancel(&b.sculptor)
	}
}

// Threads give the same bounds and the same deformed surface, bit for bit, as one thread.
@(test)
deform_by_threads_matches_one :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	runs: [2][]Vec3
	for &run, k in runs {
		b := bar_make(&pool if k == 1 else nil)
		defer bar_free(b)
		_ = bar_deform(t, b, {kind = .Bend, along = .Y, toward = .Z, amount = -2})
		run = slice.clone(b.mesh.positions[:], context.temp_allocator)
		_ = sculptor_pose_end(&b.sculptor)
	}
	testing.expect(t, slice.equal(runs[0], runs[1]))
}

// The bend limit keeps a thick part from folding, and is a whole turn for a thin one.
@(test)
deform_bend_limit_stops_a_fold :: proc(t: ^testing.T) {
	thick := Deform{along = .Y, toward = .X, lo = {-1, -1, -1}, hi = {1, 1, 1}}
	testing.expect(t, abs(deform_bend_limit(thick) - 0.95 * 2) < 1e-6)
	thin := Deform{along = .Y, toward = .X, lo = {-0.01, -1, -0.01}, hi = {0.01, 1, 0.01}}
	testing.expect_value(t, deform_bend_limit(thin), f32(2 * math.PI))
}
