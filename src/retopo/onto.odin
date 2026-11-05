package retopo

import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"
import "../quadmesh"

// The extraction puts each corner of the quads on the isotropic mesh, whose triangles are
// chords of the surface, a few to a quad: where the surface bends tightly (a spike's foot,
// the webbing between fingers, a mouth's lips) a chord, and the corners on it, lie a
// fifth of a quad's edge inside or outside it. So, last, each corner goes onto the nearest
// point of the mesh that went in, the way ZRemesher's lie on the sculpt. A corner stays
// where it is on an open or non-manifold edge (a border already lies on the mesh's own,
// a kept one exactly), on a symmetry seam (it stays on its plane, and its image across it
// is made from it), when the nearest point is farther than `reach` (on a part thinner
// than that, the far side may be the nearer), and when the move would turn one of its
// faces over. Returns how many corners moved.
quad_onto_surface :: proc(m: ^quadmesh.Polygon_Mesh, surface: geom.Mesh, bvh: ^geom.Bvh, planes: []u8, reach: f32, pool: ^jobs.Pool) -> (moved: int) {
	n := len(m.positions)
	faces := len(m.first) - 1
	if n == 0 || faces <= 0 || len(surface.indices) == 0 do return
	// The corners that stay: on a seam, or on an edge that is not between two faces.
	stays := make([]bool, n, context.temp_allocator)
	if len(planes) == n do for p, v in planes do stays[v] = p != 0
	edges := make([dynamic][2]u32, 0, len(m.corners), context.temp_allocator)
	for f in 0 ..< faces {
		c := m.corners[m.first[f]:m.first[f + 1]]
		for a, k in c {
			b := c[(k + 1) % len(c)]
			append(&edges, [2]u32{min(a, b), max(a, b)})
		}
	}
	slice.sort_by(edges[:], proc(a, b: [2]u32) -> bool {return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])})
	for i := 0; i < len(edges); {
		j := i + 1
		for j < len(edges) && edges[j] == edges[i] do j += 1
		if j - i != 2 do stays[edges[i][0]], stays[edges[i][1]] = true, true
		i = j
	}
	// Each corner's nearest point within reach, on the pool: each corner alone, the ranges
	// fixed, so the hint each search starts from is the same on any number of threads.
	to := make([]geom.Vec3, n, context.temp_allocator)
	Job :: struct {
		surface: geom.Mesh,
		bvh:     ^geom.Bvh,
		from:    []geom.Vec3,
		stays:   []bool,
		to:      []geom.Vec3,
		reach:   f32,
	}
	job := Job{surface, bvh, m.positions, stays, to, reach}
	jobs.parallel_ranges(pool, n, &job, proc(data: rawptr, lo, hi: int) {
		j := (^Job)(data)
		hint := geom.BVH_NONE
		for v in lo ..< hi {
			j.to[v] = j.from[v]
			if j.stays[v] do continue
			tri, bary, _, ok := geom.bvh_closest(j.bvh^, j.surface, j.from[v], j.reach, hint)
			if !ok do continue
			hint = tri
			i := j.surface.indices[3 * tri:][:3]
			j.to[v] = bary[0] * j.surface.positions[i[0]] + bary[1] * j.surface.positions[i[1]] + bary[2] * j.surface.positions[i[2]]
		}
	}, 4096)
	// A face the moves would turn over keeps its corners where they were; the check runs
	// again, as putting one corner back can turn a face beside it, until none turns. Each
	// round that goes on puts at least one corner back, so it ends.
	for {
		turned := false
		for f in 0 ..< faces {
			c := m.corners[m.first[f]:m.first[f + 1]]
			if linalg.dot(polygon_normal(m.positions, c), polygon_normal(to, c)) > 0 do continue
			for v in c {
				if to[v] == m.positions[v] do continue
				to[v] = m.positions[v]
				turned = true
			}
		}
		if !turned do break
	}
	for v in 0 ..< n {
		if to[v] == m.positions[v] do continue
		m.positions[v] = to[v]
		moved += 1
	}
	return
}

// The polygon's normal by Newell's sum (its length twice its area), which holds for a
// quad that is not flat.
@(private = "file")
polygon_normal :: proc(positions: []geom.Vec3, corners: []u32) -> geom.Vec3 {
	s: geom.Vec3
	for a, k in corners {
		s += linalg.cross(positions[a], positions[corners[(k + 1) % len(corners)]])
	}
	return s
}
