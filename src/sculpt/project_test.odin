package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A smooth sphere projected onto a bumpy one takes its bumps, but where masked; the
// colours come along; one undo puts it all back.
@(test)
project_takes_the_source_shape_and_undoes :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	// The source: a finer sphere with a bump of 0.05 on the +z side.
	source := geom.icosphere(6)
	defer geom.mesh_destroy(&source)
	bump :: proc(p: [3]f32) -> f32 {return 1 + 0.05 * max(0, p.z)}
	for &p in source.positions do p *= bump(p)
	geom.mesh_recompute_normals(&source)
	bvh := geom.bvh_build(source)
	defer geom.bvh_destroy(&bvh)

	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, &pool, 64)
	defer sculptor_destroy(&s)
	sculptor_recompute_all(&s)
	before := slice.clone(m.positions[:])
	defer delete(before)
	mask_ensure(&s)
	for p, v in m.positions do if p.x < -0.5 do s.mask[v] = 255

	next := make([]Vec3, len(m.positions))
	defer delete(next)
	hits := geom.project_along_normals(m.positions[:], m.normals[:], source, &bvh, 0.2, &pool, next, nil)
	testing.expect_value(t, hits, len(m.positions))
	colors := make([]Color, len(m.positions))
	defer delete(colors)
	for &c in colors do c = {200, 30, 30, 255}

	testing.expect(t, sculptor_project(&s, next, colors, 1))
	_ = sculptor_flush(&s)
	far: f32
	for p, v in m.positions {
		if s.mask[v] == 255 {
			testing.expect(t, p == before[v] && s.color[v] == {}, "a masked vertex changed")
			continue
		}
		far = max(far, abs(linalg.length(p) - bump(p)))
		testing.expect(t, s.color[v] == colors[v], "a colour did not come")
	}
	testing.expectf(t, far < 0.01, "a vertex is %v off the source", far)
	testing.expect(t, sculptor_undo(&s))
	_ = sculptor_flush(&s)
	testing.expect(t, slice.equal(m.positions[:], before), "undo left vertices moved")
	for c in s.color do testing.expect(t, c == {}, "undo left paint")
	// Nothing to do: no change, no step.
	testing.expect(t, !sculptor_project(&s, m.positions[:], nil, 1))
}
