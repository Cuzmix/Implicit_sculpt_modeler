package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// Two icospheres of `level` side by side in one mesh, `gap` apart at their nearest: near
// each other in space, never joined by a triangle. The first is turned so the middle of a
// triangle faces the second, and the second so one of its vertices does: the first's
// vertices there are all further from the second than that one is.
@(private = "file")
two_spheres :: proc(gap: f32, level := 4) -> (m: geom.Mesh) {
	a := geom.icosphere(level)
	defer geom.mesh_destroy(&a)
	n := u32(len(a.positions))
	turn := linalg.quaternion_between_two_vector3(a.positions[0], Vec3{-1, 0, 0})
	t0 := a.positions[a.indices[0]] + a.positions[a.indices[1]] + a.positions[a.indices[2]]
	face := linalg.quaternion_between_two_vector3(linalg.normalize(t0), Vec3{1, 0, 0})
	for p in a.positions do append(&m.positions, linalg.quaternion128_mul_vector3(face, p))
	for p in a.positions do append(&m.positions, linalg.quaternion128_mul_vector3(turn, p) + {2 + gap, 0, 0})
	append(&m.indices, ..a.indices[:])
	for i in a.indices do append(&m.indices, i + n)
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	return
}

// How many vertices lie within `r` of `c`: fewer than all a dab's hit leaves own, so at
// least PARALLEL_MIN_VERTS of them means the dab runs on the pool.
@(private = "file")
within :: proc(m: geom.Mesh, c: Vec3, r: f32) -> (n: int) {
	for p in m.positions do n += int(linalg.length(p - c) < r)
	return
}

// A Draw dab on the first sphere where it faces the second moves the second too, unless
// Connected is on, when only the first moves; on worker threads it lays the same.
@(test)
connected_leaves_what_is_only_near_in_space :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool, connected: bool) -> (moved_a, moved_b: int, after: []Vec3) {
		m := two_spheres(0.04, 6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		_ = apply_dab(&s, {kind = .Draw, radius = 0.4, strength = 1, connected = connected}, {1, 0, 0})
		for p, v in m.positions {
			if p == before[v] do continue
			if before[v].x < 1.01 do moved_a += 1
			else do moved_b += 1
		}
		after = slice.clone(m.positions[:], context.temp_allocator)
		return
	}
	m := two_spheres(0.04, 6)
	testing.expect(t, within(m, {1, 0, 0}, 0.4) >= PARALLEL_MIN_VERTS)
	geom.mesh_destroy(&m)
	a, b, plain := run(nil, false)
	testing.expect(t, a > 0 && b > 0)
	a, b, plain = run(nil, true)
	testing.expect(t, a > 0)
	testing.expect_value(t, b, 0)
	_, _, threaded := run(&pool, true)
	testing.expect(t, slice.equal(plain, threaded))
}

// Pressed on the first sphere a hair from a vertex of the second, much nearer than any of
// its own, Connected still works on the first: it starts from the triangle the press
// lies on, not the nearest vertex.
@(test)
connected_starts_on_the_surface_pressed :: proc(t: ^testing.T) {
	m := two_spheres(0.004)
	defer geom.mesh_destroy(&m)
	half := len(m.positions) / 2
	// The point of the first sphere's triangles nearest the second, where a ray along +x
	// would have hit it.
	center, best := Vec3{}, max(f32)
	for f in 0 ..< len(m.indices) / 6 {
		a, b, c := m.positions[m.indices[3 * f]], m.positions[m.indices[3 * f + 1]], m.positions[m.indices[3 * f + 2]]
		q := triangle_closest({1.004, 0, 0}, a, b, c)
		if d := linalg.length(q - Vec3{1.004, 0, 0}); d < best do center, best = q, d
	}
	nearest, nearest_d := 0, max(f32)
	for p, v in m.positions do if d := linalg.length(p - center); d < nearest_d do nearest, nearest_d = v, d
	testing.expectf(t, nearest >= half, "the nearest vertex should be the second sphere's, is %d", nearest)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.2, strength = 1, connected = true}, center)
	moved_a, moved_b := 0, 0
	for p, v in m.positions {
		if p == before[v] do continue
		if before[v].x < 1.002 do moved_a += 1
		else do moved_b += 1
	}
	testing.expect(t, moved_a > 0)
	testing.expect_value(t, moved_b, 0)
}

// Where everything under the brush is one piece of surface, across many leaves (8
// triangles each), a Connected dab lays exactly what a plain one does.
@(test)
connected_reaches_all_of_one_piece :: proc(t: ^testing.T) {
	run :: proc(connected: bool) -> (after: []Vec3, moved: int) {
		m := two_spheres(0.04)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, nil, 8)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		for k in 0 ..< 4 {
			a := 0.3 * f32(k)
			_ = apply_dab(&s, {kind = .Clay, radius = 0.5, strength = 1, connected = connected}, {-linalg.cos(a), linalg.sin(a), 0})
			_ = sculptor_flush(&s)
		}
		for p, v in m.positions do moved += int(p != before[v])
		return slice.clone(m.positions[:], context.temp_allocator), moved
	}
	plain, moved := run(false)
	connected, _ := run(true)
	testing.expect(t, moved > 200)
	testing.expect(t, slice.equal(plain, connected))
}

// With dynamic topology splitting edges under the brush, Connected still leaves the
// other sphere alone: the flood runs on the triangles the split left.
@(test)
connected_works_with_dynamic_topology :: proc(t: ^testing.T) {
	m := two_spheres(0.04)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, sculptor_dyn_enable(&s))
	defer sculptor_dyn_disable(&s)
	count := sculptor_triangle_count(&s)
	before := make(map[u32]Vec3, context.temp_allocator)
	for n in s.nodes do for v in n.vert_first ..< n.vert_first + n.vert_count do before[v] = m.positions[v]
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1, detail = 0.2, connected = true}, {1, 0, 0})
	testing.expect(t, sculptor_stroke_end(&s))
	testing.expect(t, sculptor_triangle_count(&s) > count)
	moved := 0
	for v, p in before {
		if p.x < 1.02 do moved += int(m.positions[v] != p)
		else do testing.expectf(t, m.positions[v] == p, "vertex %d of the other sphere moved", v)
	}
	testing.expect(t, moved > 0)
}

// With Lock plane, every dab of a Draw stroke over the curve of a sphere pushes along
// the normal its first dab found, so each vertex moves along that one line, and mirror
// images along the mirrored line; without, the push turns with the surface. Worker
// threads lay the same stroke.
@(test)
lock_plane_keeps_the_first_dabs_plane :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool, lock: bool) -> (worst: f32, after: []Vec3) {
		m := geom.icosphere(6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		sculptor_stroke_begin(&s)
		for k in 0 ..< 8 {
			a := 0.08 * f32(k)
			center := Vec3{0, linalg.sin(a), linalg.cos(a)}
			_ = apply_dab(&s, {kind = .Draw, radius = 0.5, strength = 1, lock_plane = lock, symmetry = {.Z}}, center)
			_ = sculptor_flush(&s)
		}
		testing.expect(t, sculptor_stroke_end(&s))
		testing.expect(t, s.locked.set == lock)
		// The first dab, straight over the pole, finds the normal +Z or near it.
		n := s.locked.normal if lock else Vec3{0, 0, 1}
		for p, v in m.positions {
			d := p - before[v]
			if linalg.length(d) < 1e-6 do continue
			along := n if before[v].z > 0 else n * Vec3{1, 1, -1}
			worst = max(worst, linalg.length(linalg.cross(linalg.normalize(d), along)))
		}
		after = slice.clone(m.positions[:], context.temp_allocator)
		return
	}
	m := geom.icosphere(6)
	testing.expect(t, within(m, {0, 0, 1}, 0.5) >= PARALLEL_MIN_VERTS)
	geom.mesh_destroy(&m)
	locked, serial := run(t, nil, true)
	testing.expect(t, locked < 1e-3)
	_, threaded := run(t, &pool, true)
	testing.expect(t, slice.equal(serial, threaded))
	// Without it the later dabs push along the slope they are on, well off the first line.
	free, _ := run(t, nil, false)
	testing.expect(t, free > 0.05)
}

// Grab with Connected moves only the sphere it was pressed on, however near the other is,
// and lays the same on worker threads; without it, both move.
@(test)
grab_connected_leaves_what_is_only_near :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool, connected: bool) -> (moved_a, moved_b: int, after: []Vec3) {
		m := two_spheres(0.04, 6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		sculptor_stroke_begin(&s)
		testing.expect(nil, sculptor_grab_begin(&s, {kind = .Grab, radius = 0.4, strength = 1, connected = connected, symmetry = {.Y}}, {1, 0, 0}) > 0)
		_ = sculptor_grab_move(&s, {0, 0, 0.2})
		sculptor_grab_end(&s)
		_ = sculptor_stroke_end(&s)
		for p, v in m.positions {
			if p == before[v] do continue
			if before[v].x < 1.01 do moved_a += 1
			else do moved_b += 1
		}
		after = slice.clone(m.positions[:], context.temp_allocator)
		return
	}
	a, b, _ := run(nil, false)
	testing.expect(t, a > 0 && b > 0)
	ca, cb, serial := run(nil, true)
	testing.expect(t, ca > 0)
	testing.expect_value(t, cb, 0)
	_, _, threaded := run(&pool, true)
	testing.expect(t, slice.equal(serial, threaded))
}

// Reaching through the depth, a grab on the front of a sphere moves its back too, which
// the round reach leaves; on worker threads it lays the same.
@(test)
grab_through_reaches_the_far_side :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool, through: Vec3) -> (front, back: int, after: []Vec3) {
		m := geom.icosphere(6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		before := slice.clone(m.positions[:], context.temp_allocator)
		_ = sculptor_grab_begin(&s, {kind = .Grab, radius = 0.3, strength = 1, through = through}, {0, 0, 1})
		_ = sculptor_grab_move(&s, {0.2, 0, 0})
		for p, v in m.positions {
			if p == before[v] do continue
			if before[v].z > 0 do front += 1
			else do back += 1
		}
		after = slice.clone(m.positions[:], context.temp_allocator)
		return
	}
	front, back, _ := run(nil, {})
	testing.expect(t, front > 0)
	testing.expect_value(t, back, 0)
	deep_front, deep_back, serial := run(nil, {0, 0, -3})
	testing.expect(t, deep_front > 0 && deep_back > 0)
	_, _, threaded := run(&pool, {0, 0, -3})
	testing.expect(t, slice.equal(serial, threaded))
}

// Smooth valleys raises the bottom of a dent and leaves a bump's top; Smooth peaks
// lowers the top and leaves the bottom; on worker threads each lays the same.
@(test)
smooth_valleys_and_peaks :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool, only: Smooth_Only) -> (dent_moved, bump_moved: bool, after: []Vec3) {
		m := geom.icosphere(6)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		dent, bump := Vec3{0, 0, 1}, Vec3{1, 0, 0}
		_ = apply_dab(&s, {kind = .Draw, radius = 0.15, strength = 1, invert = true}, dent)
		_ = apply_dab(&s, {kind = .Draw, radius = 0.15, strength = 1}, bump)
		_ = sculptor_flush(&s)
		// The vertices nearest each middle: the bottom of the dent and the top of the bump.
		bottom, top := 0, 0
		for p, v in m.positions {
			if linalg.length(p - dent) < linalg.length(m.positions[bottom] - dent) do bottom = v
			if linalg.length(p - bump) < linalg.length(m.positions[top] - bump) do top = v
		}
		before := slice.clone(m.positions[:], context.temp_allocator)
		_ = apply_dab(&s, {kind = .Smooth, radius = 0.1, strength = 1, smooth_only = only}, m.positions[bottom])
		_ = apply_dab(&s, {kind = .Smooth, radius = 0.1, strength = 1, smooth_only = only}, m.positions[top])
		dent_moved, bump_moved = m.positions[bottom] != before[bottom], m.positions[top] != before[top]
		after = slice.clone(m.positions[:], context.temp_allocator)
		return
	}
	for only in Smooth_Only {
		dent, bump, serial := run(nil, only)
		testing.expectf(t, dent == (only != .Peaks), "%v: the dent moved %v", only, dent)
		testing.expectf(t, bump == (only != .Valleys), "%v: the bump moved %v", only, bump)
		_, _, threaded := run(&pool, only)
		testing.expect(t, slice.equal(serial, threaded))
	}
}

// With both Connected and a reach through the depth, the depth wins: the grab moves the
// back of a sphere as it does without Connected.
@(test)
grab_through_wins_over_connected :: proc(t: ^testing.T) {
	run :: proc(connected: bool) -> []Vec3 {
		m := geom.icosphere(5)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, nil, 64)
		defer sculptor_destroy(&s)
		_ = sculptor_grab_begin(&s, {kind = .Grab, radius = 0.3, strength = 1, through = {0, 0, -1}, connected = connected}, {0, 0, 1})
		_ = sculptor_grab_move(&s, {0.2, 0, 0})
		return slice.clone(m.positions[:], context.temp_allocator)
	}
	testing.expect(t, slice.equal(run(false), run(true)))
}
