package main

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../sculpt"

// Build levels: a remesh made at a quarter of the count a level and divided back up has
// the count asked at the top, which the fit puts back on the old surface closer than the
// division left it (a twelfth of a cell off a sphere, and within a hundredth fitted); going down to the base and up again keeps the top where it was.
@(test)
remesh_build_levels_fits_the_top_and_keeps_it :: proc(t: ^testing.T) {
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	setup := Remesh_Setup{smooth = geom.REMESH_SMOOTH_DEFAULT, keep_thin = true, quads = true, levels = 2}
	asked := 40_000
	area, bounds := geom.mesh_area_bounds(source)
	report: geom.Remesh_Report
	defer geom.remesh_report_destroy(&report)
	mesh, built := geom.remesh_voxel_measured(source, area, bounds, remesh_base_count(asked, setup), options = remesh_options(setup, nil), report = &report)
	testing.expect(t, built)
	l: sculpt.Levels
	defer sculpt.levels_destroy(&l)
	levels_prepare(&l, mesh, {}, report.quads, nil)
	base := len(l.levels[0].mesh.positions)
	worst :: proc(m: geom.Mesh) -> f32 {
		w: f32
		for p in m.positions do w = max(w, abs(linalg.length(p) - 1))
		return w
	}
	made := remesh_build_levels(&l, source, setup, report.cell, nil)
	testing.expect_value(t, made, 2)
	testing.expect_value(t, len(l.levels), 3)
	top := sculpt.levels_current(&l)
	testing.expect(t, l.current == 2)
	n := len(top.mesh.positions)
	testing.expectf(t, n > asked * 8 / 10 && n < asked * 12 / 10, "the top has %d vertices for %d asked (base %d)", n, asked, base)
	fitted := worst(top.mesh)
	testing.expectf(t, fitted < 0.01 * report.cell, "the fitted top is %f off the sphere (cell %f)", fitted, report.cell)
	kept := make([]geom.Vec3, n, context.temp_allocator)
	copy(kept, top.mesh.positions[:])
	sculpt.levels_set_current(&l, 0)
	sculpt.levels_set_current(&l, 2)
	moved: f32
	for p, i in sculpt.levels_current(&l).mesh.positions do moved = max(moved, linalg.length(p - kept[i]))
	testing.expectf(t, moved < 1e-4, "the top moved %f down to the base and back", moved)
}
