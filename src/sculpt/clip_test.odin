package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(test)
clip_flattens_past_the_plane :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 4)
	defer jobs.pool_destroy(&pool)
	// Large enough that the clip's saves share one allocation (RECORD_PARALLEL_VERTS).
	m := geom.icosphere(8)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, &pool, 64)
	defer sculptor_destroy(&s)
	sculptor_recompute_all(&s)
	before := slice.clone(m.positions[:])
	defer delete(before)
	// Mask one vertex near the top: it stays where it is.
	mask_ensure(&s)
	kept := -1
	for p, v in m.positions do if p.z > 0.9 {kept = v; break}
	s.mask[kept] = 255

	planes := []Clip_Plane{{point = {0, 0, 0.5}, normal = {0, 0, 1}}}
	testing.expect(t, sculptor_clip(&s, planes))
	_ = sculptor_flush(&s)
	for p, v in m.positions {
		if v == kept {
			testing.expect(t, p == before[v])
		} else if before[v].z > 0.5 {
			testing.expectf(t, abs(p.z - 0.5) < 1e-5 && p.xy == before[v].xy, "vertex %d at %v", v, p)
		} else {
			testing.expect(t, p == before[v])
		}
	}
	// The BVH follows: a ray down off the masked spike meets the cut face.
	hit, ok := sculptor_raycast(&s, {0.3, 0, 2}, {0, 0, -1})
	testing.expectf(t, ok && abs(hit.z - 0.5) < 1e-4, "hit %v %v", hit, ok)
	// Nothing past the plane any more: a second clip does nothing new.
	s.mask[kept] = 0
	testing.expect(t, sculptor_clip(&s, planes)) // the masked vertex now goes
	testing.expect(t, !sculptor_clip(&s, planes))
	// Two undos put every vertex back exactly.
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, sculptor_undo(&s))
	for p, v in m.positions do testing.expect(t, p == before[v])
	testing.expect(t, sculptor_redo(&s))
	for p, v in m.positions do if v != kept && before[v].z > 0.5 do testing.expect(t, abs(p.z - 0.5) < 1e-5)
}
