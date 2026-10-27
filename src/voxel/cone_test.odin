package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

// Every node's chunk carries the normal cone of its triangles: each face normal lies in
// the cone, most nodes of a sphere have one narrower than a hemisphere, and from far on
// +z the nodes on the sphere's far side are culled while none on the near side is.
@(test)
node_cones_hold_their_faces_and_cull_the_far_side :: proc(t: ^testing.T) {
	c: Clay
	clay_init(&c, 2.0 / 96, {}, nil)
	defer clay_destroy(&c)
	clay_fill_sphere(&c, {}, 1)
	_ = clay_flush(&c)
	m := &c.surface.mesh
	narrow, culled := 0, 0
	for ch in c.surface.chunks {
		if ch.cone_cutoff < 1 {
			narrow += 1
			cos_half := math.sqrt(1 - ch.cone_cutoff * ch.cone_cutoff)
			idx := m.indices[ch.first_index:][:ch.index_count]
			for k := 0; k < len(idx); k += 3 {
				p0, p1, p2 := m.positions[idx[k]], m.positions[idx[k + 1]], m.positions[idx[k + 2]]
				n := linalg.normalize0(linalg.cross(p1 - p0, p2 - p0))
				if n == {} do continue
				testing.expectf(t, linalg.dot(n, ch.cone_axis) >= cos_half - 1e-3, "a face normal %v outside its node's cone (axis %v, cutoff %.3f)", n, ch.cone_axis, ch.cone_cutoff)
			}
		}
		back := geom.chunk_backfacing(ch, {0, 0, 100})
		if back do culled += 1
		testing.expectf(t, !back || ch.bounds.lo.z < 0, "a node on the near side (bounds %v) culled from +z", ch.bounds)
		if ch.bounds.hi.z < -0.6 do testing.expectf(t, back, "a node on the far side (bounds %v, axis %v, cutoff %.3f) not culled from +z", ch.bounds, ch.cone_axis, ch.cone_cutoff)
	}
	testing.expectf(t, narrow > len(c.surface.chunks) / 2, "%d of %d nodes have a cone narrower than a hemisphere", narrow, len(c.surface.chunks))
	testing.expect(t, culled > 0, "nothing culled from +z")
}
