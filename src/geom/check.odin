package geom

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"

// What one pass over a mesh found, as numbers, so a failing test or a refused tool
// says what broke rather than only that something did. Zero values mean "none found";
// a sculptable surface is closed, not inverted, and has no degenerate or NaN entries
// (mesh_report_ok). Tests expect on the fields; the benchmark and the app's
// --check-mesh print them with mesh_report_print.
Mesh_Report :: struct {
	vertices:             int,
	triangles:            int,
	closed:               bool, // every edge is run once each way by exactly two triangles, and there is at least one
	boundary_edges:       int, // edges with one triangle: a hole or an open patch
	inconsistent_edges:   int, // edges run the same way by both their triangles: one of them is flipped
	non_manifold_edges:   int, // edges with more than two triangles
	degenerate_triangles: int, // a repeated corner, an index past the vertices, or exactly zero area
	nan_count:            int, // positions with a NaN or infinite component
	volume:               f64, // signed, the sum of det(p0, p1, p2) / 6; exact for a closed surface
	inverted:             bool, // volume < 0: the surface faces inward (meaningful only when closed)
	bounds:               Aabb, // of the finite positions; AABB_EMPTY when there are none
}

// Checks a whole mesh. It sorts one u64 per index from the temp allocator (240 MB at
// 10M vertices), so call it per mesh at setup or exit, never per frame.
@(require_results)
mesh_check :: proc(m: Mesh) -> Mesh_Report {
	return mesh_check_indices(m.positions[:], m.indices[:])
}

// Checks any triangle list over a vertex array, so a simplified copy or a cut through
// the LOD tree, which share a mesh's positions, can be checked without copying them.
@(require_results)
mesh_check_indices :: proc(positions: []Vec3, indices: []u32) -> (r: Mesh_Report) {
	r.vertices = len(positions)
	r.triangles = len(indices) / 3
	r.bounds = AABB_EMPTY
	for p in positions {
		if math.is_nan(p.x) || math.is_nan(p.y) || math.is_nan(p.z) || math.is_inf(p.x) || math.is_inf(p.y) || math.is_inf(p.z) {
			r.nan_count += 1
		} else {
			aabb_grow(&r.bounds, p)
		}
	}

	// One key per directed edge, the undirected edge in the high bits and the direction
	// in bit 0, so that sorting puts each edge's triangles side by side. A sort of 8 bytes
	// per index is far cheaper than the map the tests used to build at 10M vertices.
	keys := make([dynamic]u64, 0, len(indices), context.temp_allocator)
	n := u32(len(positions))
	for t := 0; t + 2 < len(indices); t += 3 {
		a, b, c := indices[t], indices[t + 1], indices[t + 2]
		if a >= n || b >= n || c >= n || a == b || b == c || a == c {
			r.degenerate_triangles += 1
			continue
		}
		p0, p1, p2 := positions[a], positions[b], positions[c]
		// Exactly zero, not a tolerance: a tolerance would make the verdict depend on the
		// mesh's scale, and collapsed vertices are exactly equal.
		if linalg.length2(linalg.cross(p1 - p0, p2 - p0)) == 0 {
			r.degenerate_triangles += 1
			continue
		}
		r.volume += f64(linalg.dot(p0, linalg.cross(p1, p2)))
		append(&keys, edge_key(a, b), edge_key(b, c), edge_key(c, a))
	}
	slice.sort(keys[:])
	for i := 0; i < len(keys); {
		edge := keys[i] >> 1
		forward, backward := 0, 0
		for ; i < len(keys) && keys[i] >> 1 == edge; i += 1 {
			if keys[i] & 1 == 0 {
				forward += 1
			} else {
				backward += 1
			}
		}
		switch {
		case forward + backward == 1:
			r.boundary_edges += 1
		case forward + backward > 2:
			r.non_manifold_edges += 1
		case forward != 1:
			r.inconsistent_edges += 1
		}
	}
	r.volume /= 6
	r.inverted = r.volume < 0
	r.closed = r.triangles > 0 && r.boundary_edges == 0 && r.inconsistent_edges == 0 && r.non_manifold_edges == 0
	return
}

// Indices fit in 31 bits since a [dynamic]Vec3 cannot hold 2^31 vertices, so the two
// of an edge and its direction bit fit one u64.
@(private = "file")
edge_key :: #force_inline proc(a, b: u32) -> u64 {
	if a < b do return (u64(a) << 32 | u64(b)) << 1
	return (u64(b) << 32 | u64(a)) << 1 | 1
}

// What every mesh the app sculpts must satisfy.
@(require_results)
mesh_report_ok :: proc(r: Mesh_Report) -> bool {
	return r.closed && !r.inverted && r.degenerate_triangles == 0 && r.nan_count == 0
}

// One line of key=value pairs, the form the app prints its exit stats in, so a run's
// output can be grepped and compared with another run's.
mesh_report_print :: proc(r: Mesh_Report, prefix := "mesh") {
	fmt.printfln(
		"%s_closed=%v %s_boundary_edges=%d %s_inconsistent_edges=%d %s_non_manifold_edges=%d %s_degenerate=%d %s_nan=%d %s_inverted=%v %s_volume=%.6f %s_triangles=%d %s_vertices=%d",
		prefix, r.closed, prefix, r.boundary_edges, prefix, r.inconsistent_edges, prefix, r.non_manifold_edges,
		prefix, r.degenerate_triangles, prefix, r.nan_count, prefix, r.inverted, prefix, r.volume, prefix, r.triangles,
		prefix, r.vertices,
	)
}
