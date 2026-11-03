package main

import "core:testing"

import "../geom"
import "../sculpt"

// A remesh without Keep detail carries the polypaint, polygroups and mask from the old
// triangle nearest each vertex: a sphere masked, painted red and grouped on its -x half
// comes out the same on the new vertices, away from the seam between the halves.
@(test)
remesh_carries_paint_groups_and_mask :: proc(t: ^testing.T) {
	sphere := geom.icosphere(4)
	defer geom.mesh_destroy(&sphere)
	n := len(sphere.positions)
	color := make([]sculpt.Color, n)
	defer delete(color)
	mask := make([]u8, n)
	defer delete(mask)
	for p, v in sphere.positions {
		color[v] = {255, 0, 0, 255} if p.x < 0 else {0, 0, 255, 255}
		mask[v] = 255 if p.x < 0 else 0
	}
	groups := make([]u16, len(sphere.indices) / 3)
	defer delete(groups)
	for &g, f in groups do g = 2 if sphere.positions[sphere.indices[3 * f]].x < 0 else 1
	area, bounds := geom.mesh_area_bounds(sphere, nil)
	report: geom.Remesh_Report
	defer geom.remesh_report_destroy(&report)
	setup := Remesh_Setup{smooth = geom.REMESH_SMOOTH_DEFAULT, keep_thin = true, keep_paint = true}
	out, ok := geom.remesh_voxel_measured(sphere, area, bounds, 5000, nil, options = remesh_options(setup, groups, true), report = &report)
	defer geom.mesh_destroy(&out)
	testing.expect(t, ok, "the remesh failed")
	testing.expect(t, report.source_tris != nil, "no old triangles were reported")
	surface := remesh_surface(report, out, sphere, color, groups, mask)
	defer surface_free(&surface)
	testing.expect(t, surface.color != nil && surface.mask != nil && surface.groups != nil, "something was dropped")
	if surface.color == nil || surface.mask == nil || surface.groups == nil do return
	wrong := 0
	for p, v in out.positions {
		if abs(p.x) < 0.15 do continue
		left := p.x < 0
		want_mask: u8 = 255 if left else 0
		want_red: u8 = 255 if left else 0
		if surface.mask[v] != want_mask || surface.color[v][0] != want_red do wrong += 1
	}
	for g, f in surface.groups {
		x := out.positions[out.indices[3 * f]].x
		if abs(x) < 0.15 do continue
		if g != (2 if x < 0 else 1) do wrong += 1
	}
	testing.expectf(t, wrong == 0, "%d vertices or triangles away from the seam took the other half's", wrong)
	// Without anything to carry, or with the switch off, nothing is looked up.
	plain: geom.Remesh_Report
	defer geom.remesh_report_destroy(&plain)
	again, _ := geom.remesh_voxel_measured(sphere, area, bounds, 5000, nil, options = remesh_options(setup, nil), report = &plain)
	defer geom.mesh_destroy(&again)
	testing.expect(t, plain.source_tris == nil, "old triangles looked up with nothing to carry")
	off := setup
	off.keep_paint = false
	testing.expect(t, !remesh_options(off, groups, true).sources, "old triangles looked up with Keep paint and mask off")
}
