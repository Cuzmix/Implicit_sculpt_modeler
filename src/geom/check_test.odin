package geom

import "core:math"
import "core:testing"

@(test)
check_accepts_a_closed_sphere :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	r := mesh_check(m)
	testing.expectf(t, mesh_report_ok(r), "%v", r)
	testing.expect_value(t, r.triangles, 1280)
	testing.expect_value(t, r.vertices, 642)
	testing.expect_value(t, r.boundary_edges, 0)
	testing.expect_value(t, r.inconsistent_edges, 0)
	testing.expect_value(t, r.non_manifold_edges, 0)
	// An inscribed polyhedron: a little under the unit sphere's 4π/3.
	testing.expectf(t, r.volume > 0.95 * 4.18879 && r.volume < 4.18879, "volume %v", r.volume)
	testing.expectf(t, r.bounds.hi.x > 0.9 && r.bounds.hi.x <= 1 + 1e-5 && r.bounds.lo.x < -0.9, "bounds %v", r.bounds)
}

@(test)
check_counts_a_hole :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	remove_range(&m.indices, 0, 3) // three edges with one triangle each
	r := mesh_check(m)
	testing.expectf(t, !r.closed && r.boundary_edges == 3 && r.inconsistent_edges == 0 && r.non_manifold_edges == 0, "%v", r)
}

@(test)
check_sees_a_flipped_triangle :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	m.indices[1], m.indices[2] = m.indices[2], m.indices[1]
	r := mesh_check(m)
	testing.expectf(t, !r.closed && r.inconsistent_edges == 3 && r.boundary_edges == 0 && r.volume > 0, "%v", r)
}

@(test)
check_sees_a_degenerate_triangle :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	m.indices[2] = m.indices[0] // the triangle loses a corner, and its three edges lose their twin
	r := mesh_check(m)
	testing.expectf(t, !mesh_report_ok(r) && r.degenerate_triangles == 1 && r.boundary_edges == 3, "%v", r)
}

@(test)
check_counts_nan_positions :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	m.positions[0].x = math.nan_f32()
	r := mesh_check(m)
	testing.expectf(t, !mesh_report_ok(r) && r.nan_count == 1 && !math.is_nan(r.bounds.lo.x), "%v", r)
}

@(test)
check_reports_inward_winding :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	for tri := 0; tri < len(m.indices); tri += 3 {
		m.indices[tri + 1], m.indices[tri + 2] = m.indices[tri + 2], m.indices[tri + 1]
	}
	r := mesh_check(m)
	testing.expectf(t, r.closed && r.inverted && r.volume < 0 && !mesh_report_ok(r), "%v", r)
}

@(test)
check_rejects_an_empty_mesh :: proc(t: ^testing.T) {
	r := mesh_check(Mesh{})
	testing.expectf(t, !r.closed && r.triangles == 0 && r.vertices == 0, "%v", r)
}
