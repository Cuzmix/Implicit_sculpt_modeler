package geom

import "core:testing"

import "../jobs"

@(test)
symmetrize_makes_a_closed_mirror_image :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for axis in 0 ..< 3 {
		for keep_positive in ([2]bool{true, false}) {
			// Off the origin and bulging on one side, so the cut crosses triangles and
			// the two halves differ.
			m := icosphere(4)
			defer mesh_destroy(&m)
			for &p in m.positions {
				if p.x > 0.3 do p *= 1.3
				p += {0.17, -0.05, 0.11}
			}
			out, ok := mesh_symmetrize(m, axis, keep_positive, &pool)
			defer mesh_destroy(&out)
			testing.expect(t, ok)
			r := mesh_check(out)
			testing.expectf(t, r.closed && r.degenerate_triangles == 0 && r.nan_count == 0 && !r.inverted,
				"axis %d keep+ %v: %v", axis, keep_positive, r)
			// Every vertex has its mirror image among the vertices.
			at := make(map[Vec3]bool, len(out.positions), context.temp_allocator)
			for p in out.positions do at[p] = true
			missing := 0
			for p in out.positions {
				q := p
				q[axis] = -q[axis] if q[axis] != 0 else 0
				if !at[q] do missing += 1
			}
			testing.expectf(t, missing == 0, "axis %d: %d vertices without a mirror image", axis, missing)
			// Along X the kept side decides whether the bulge (at +X) is kept.
			if axis == 0 {
				far: f32
				for p in out.positions do far = max(far, abs(p.x))
				testing.expectf(t, (far > 1.2) == keep_positive, "keep+ %v: farthest x %v", keep_positive, far)
			}
		}
	}
	// A mesh entirely on the dropped side has nothing to keep.
	m := icosphere(2)
	defer mesh_destroy(&m)
	for &p in m.positions do p.x -= 5
	_, ok := mesh_symmetrize(m, 0, true, &pool)
	testing.expect(t, !ok)
}
