package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

// Split dabs (Brush.skin_split): the vertices take the share of a dab the mesh can show
// and the skin the rest, so the surface ends where a skin-only dab leaves it.

// The mean edge of a skinned sphere's nodes, which split dabs measure their radius by.
@(private = "file")
split_edge :: proc(s: ^Sculptor) -> f32 {
	sum: f32
	for e in s.skin.node_edge do sum += e
	return sum / f32(len(s.skin.node_edge))
}

// Each sample's flat point and unit interpolated normal, in skin_sample order.
@(private = "file")
split_bases :: proc(s: ^Sculptor) -> (points, normals: []Vec3) {
	sk := s.skin
	points = make([]Vec3, len(sk.heights), context.temp_allocator)
	normals = make([]Vec3, len(sk.heights), context.temp_allocator)
	I := s.mesh.indices[:]
	S := sk.segments
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		x := skin_sample(sk, I, t, i, j)
		p, n := skin_base(s, sk, t, i, j)
		points[x], normals[x] = p, linalg.normalize0(n)
	}
	return
}

// How far each sample's point on the skin moved along its normal from where `points`
// and `normals` had it.
@(private = "file")
split_rise :: proc(s: ^Sculptor, points, normals: []Vec3) -> []f32 {
	sk := s.skin
	rise := make([]f32, len(sk.heights), context.temp_allocator)
	I := s.mesh.indices[:]
	S := sk.segments
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		x := skin_sample(sk, I, t, i, j)
		rise[x] = linalg.dot(skin_point(s, sk, t, i, j) - points[x], normals[x])
	}
	return rise
}

@(test)
skin_split_small_dab_is_skin_only :: proc(t: ^testing.T) {
	a := skin_sphere_with(3, 4)
	b := skin_sphere_with(3, 4)
	defer skin_sphere_free(a)
	defer skin_sphere_free(b)
	radius := 0.5 * split_edge(&a.sculptor)
	at := linalg.normalize(Vec3{0.1, 0.2, 1})
	before := slice.clone(a.mesh.positions[:], context.temp_allocator)
	_ = apply_dab(&a.sculptor, {kind = .Draw, radius = radius, strength = 1, skin = true, skin_split = true}, at)
	_ = apply_dab(&b.sculptor, {kind = .Draw, radius = radius, strength = 1, skin = true}, at)
	testing.expect(t, slice.equal(a.mesh.positions[:], before), "a dab under one edge moved a vertex")
	testing.expect(t, slice.equal(a.sculptor.skin.heights, b.sculptor.skin.heights), "a dab under one edge differs from a skin-only one")
}

@(test)
skin_split_lands_where_the_skin_alone_does :: proc(t: ^testing.T) {
	for kind in ([3]Brush_Kind{.Draw, .Inflate, .Crease}) {
		a := skin_sphere_with(3, 8)
		b := skin_sphere_with(3, 8)
		defer skin_sphere_free(a)
		defer skin_sphere_free(b)
		edge := split_edge(&a.sculptor)
		radius := 2.5 * edge
		at := linalg.normalize(Vec3{0.1, 0.2, 1})
		points, normals := split_bases(&a.sculptor)
		before := slice.clone(a.mesh.positions[:], context.temp_allocator)
		_ = apply_dab(&a.sculptor, {kind = kind, radius = radius, strength = 0.5, skin = true, skin_split = true}, at)
		_ = apply_dab(&b.sculptor, {kind = kind, radius = radius, strength = 0.5, skin = true}, at)
		_ = sculptor_flush(&a.sculptor)
		_ = sculptor_flush(&b.sculptor)
		testing.expectf(t, !slice.equal(a.mesh.positions[:], before), "%v: a dab of 2.5 edges moved no vertex", kind)
		ra := split_rise(&a.sculptor, points, normals)
		rb := split_rise(&b.sculptor, points, normals)
		top, worst: f32
		for x in 0 ..< len(ra) {
			top = max(top, abs(rb[x]))
			worst = max(worst, abs(ra[x] - rb[x]))
		}
		testing.expectf(t, top > 0, "%v: the skin-only dab moved nothing", kind)
		// Crease's vertices also pinch sideways, which a height cannot follow.
		allowed: f32 = 0.08 if kind == .Crease else 0.03
		testing.expectf(t, worst <= allowed * top, "%v: the split surface is %v from the skin-only one, the dab %v high", kind, worst, top)
	}
}

@(test)
skin_split_keeps_every_normal_current :: proc(t: ^testing.T) {
	sp := skin_sphere_with(3, 4)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	edge := split_edge(s)
	for kind in SKIN_KINDS {
		for size in ([3]f32{0.5, 2.5, 6}) {
			_ = apply_dab(s, {kind = kind, radius = size * edge, strength = 0.6, skin = true, skin_split = true}, linalg.normalize(Vec3{0.2 * size, 0.1, 1}))
			_ = sculptor_flush(s)
		}
	}
	live := slice.clone(s.skin.normals, context.temp_allocator)
	skin_normals_all(s, s.skin)
	testing.expect(t, slice.equal(live, s.skin.normals), "a flush after split dabs left a stale normal")
}

@(test)
skin_split_matches_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a := skin_sphere_with(4, 4)
	b := skin_sphere_with(4, 4, &pool)
	defer skin_sphere_free(a)
	defer skin_sphere_free(b)
	edge := split_edge(&a.sculptor)
	for sp in ([2]^Skin_Sphere{a, b}) {
		sculptor_stroke_begin(&sp.sculptor)
		for k in 0 ..< 6 {
			at := linalg.normalize(Vec3{0.1 * f32(k), 0.05, 1})
			_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 2 * edge, strength = 1, skin = true, skin_split = true, symmetry = {.X}}, at)
			_ = apply_dab(&sp.sculptor, {kind = .Clay, radius = 3 * edge, strength = 0.7, skin = true, skin_split = true}, at)
			_ = sculptor_flush(&sp.sculptor)
		}
		_ = sculptor_stroke_end(&sp.sculptor)
	}
	same := slice.equal(a.mesh.positions[:], b.mesh.positions[:]) && slice.equal(a.sculptor.skin.heights, b.sculptor.skin.heights) && slice.equal(a.sculptor.skin.normals, b.sculptor.skin.normals)
	testing.expect(t, same, "the parallel split differs from the serial one")
}
