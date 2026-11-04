package quadmesh

import "core:log"
import "core:math"
import "core:testing"

import "../geom"
import "../jobs"

// The Odin driver against qm_remesh on the same input: while every stage is the C++'s,
// the two give the same polygons bit for bit.
@(private = "file")
same_polygons :: proc(a, b: Polygon_Mesh) -> bool {
	if len(a.positions) != len(b.positions) || len(a.first) != len(b.first) || len(a.corners) != len(b.corners) do return false
	for p, i in a.positions do if transmute([3]u32)p != transmute([3]u32)b.positions[i] do return false
	for c, i in a.corners do if c != b.corners[i] do return false
	for f, i in a.first do if f != b.first[i] do return false
	return true
}

@(private = "file")
both_cores :: proc(t: ^testing.T, name: string, positions: []geom.Vec3, indices: []u32, params: Params, loc := #caller_location) {
	p := params
	p.core = .Cpp
	cpp, cpp_report, cpp_err, cpp_reason := remesh(positions, indices, p)
	defer polygon_mesh_destroy(&cpp)
	p.core = .Driver
	odin, odin_report, odin_err, odin_reason := remesh(positions, indices, p)
	defer polygon_mesh_destroy(&odin)
	if !testing.expectf(t, cpp_err == .None && odin_err == .None, "%s: cpp %v %s, odin %v %s", name, cpp_err, cpp_reason, odin_err, odin_reason, loc = loc) do return
	log.infof("%s: %d faces, cpp %.0f ms, odin %.0f ms; %s", name, odin_report.faces, cpp_report.ms, odin_report.ms, checks_line(odin_report.checks))
	testing.expectf(t, same_polygons(cpp, odin), "%s: the driver's %d faces differ from qm_remesh's %d", name, odin_report.faces, cpp_report.faces, loc = loc)
	testing.expectf(t, cpp_report.covers == odin_report.covers && cpp_report.isotropic_triangles == odin_report.isotropic_triangles, "%s: covers %d and %d, isotropic triangles %d and %d", name, cpp_report.covers, odin_report.covers, cpp_report.isotropic_triangles, odin_report.isotropic_triangles, loc = loc)
	c := odin_report.checks
	testing.expectf(t, c.quad_faces == odin_report.faces && c.quad_quads == odin_report.quads && c.covers == odin_report.covers && c.iso_triangles == odin_report.isotropic_triangles, "%s: the checks disagree with the report: %v", name, c, loc = loc)
	// Every fixture here is closed and sound, so each stage must hand on a closed manifold
	// mesh and an unfolded cover with no sliver (the smallest sphere of the three, a few
	// quads round, has a corner of about 7 degrees).
	testing.expectf(t, c.thin_open_edges == 0 && c.thin_nonmanifold == 0 && c.iso_open_edges == 0 && c.iso_nonmanifold == 0 && c.quad_open_edges == 0 && c.quad_nonmanifold == 0, "%s: a stage opened the surface: %s", name, checks_line(c), loc = loc)
	testing.expectf(t, c.cover_flipped == 0 && c.iso_min_angle > 5, "%s: a fold or a sliver: %s", name, checks_line(c), loc = loc)
}

// One sphere, on one thread and on four: one island, its stages' loops threaded.
@(test)
driver_matches_qm_remesh_on_a_sphere :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	params := DEFAULT_PARAMS
	params.quads = 1500
	for threads in ([]int{1, 4}) {
		params.threads = threads
		both_cores(t, "sphere", source.positions[:], source.indices[:], params)
	}
	params.adaptivity = 1
	both_cores(t, "sphere at full adaptivity", source.positions[:], source.indices[:], params)
}

// Three spheres of three sizes in one mesh: three islands, on their own threads with four.
@(test)
driver_matches_qm_remesh_over_islands :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	source := geom.icosphere(3)
	defer geom.mesh_destroy(&source)
	n := len(source.positions)
	positions := make([]geom.Vec3, 3 * n, context.temp_allocator)
	indices := make([]u32, 3 * len(source.indices), context.temp_allocator)
	for p, i in source.positions {
		positions[i] = p + {-1.5, 0, 0}
		positions[n + i] = 0.6 * p + {1.5, 0, 0}
		positions[2 * n + i] = 0.3 * p + {0, 1.5, 0}
	}
	for k in 0 ..< 3 do for v, i in source.indices do indices[k * len(source.indices) + i] = v + u32(k * n)
	params := DEFAULT_PARAMS
	params.quads = 1200
	for threads in ([]int{1, 4}) {
		params.threads = threads
		both_cores(t, "three spheres", positions, indices, params)
	}
}

// Feature edges round the equator, a density asking four times the quads on one side, a
// refinement on the other and a guide curve: every value the driver gives out to the
// islands, through the stages that take them.
@(test)
driver_matches_qm_remesh_with_every_input :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	features := make([dynamic]u32, context.temp_allocator)
	for i := 0; i < len(source.indices); i += 3 {
		for k in 0 ..< 3 {
			a, b := source.indices[i + k], source.indices[i + (k + 1) % 3]
			pa, pb := source.positions[a], source.positions[b]
			// The edges that cross or touch the equator from above, once each.
			if a < b && pa.z >= 0 && pb.z >= 0 && (pa.z < 0.03 || pb.z < 0.03) do append(&features, a, b)
		}
	}
	density := make([]f32, len(source.positions), context.temp_allocator)
	refine := make([]f32, len(source.positions), context.temp_allocator)
	for p, v in source.positions {
		density[v] = 1 + 3 * max(p.x, 0)
		refine[v] = 0.5 if p.x < -0.5 else 1
	}
	guides := make([dynamic]geom.Vec3, context.temp_allocator)
	for k in 0 ..< 32 {
		a, b := 2 * math.PI * f32(k) / 32, 2 * math.PI * f32(k + 1) / 32
		append(&guides, geom.Vec3{0.95 * math.cos(a), 0.3, 0.95 * math.sin(a)}, geom.Vec3{0.95 * math.cos(b), 0.3, 0.95 * math.sin(b)})
	}
	params := DEFAULT_PARAMS
	params.quads, params.threads = 2000, 4
	params.features = features[:]
	both_cores(t, "features", source.positions[:], source.indices[:], params)
	params.density = density
	both_cores(t, "features and density", source.positions[:], source.indices[:], params)
	params.refine = refine
	params.guides, params.guide_strength = guides[:], 0.5
	both_cores(t, "every input", source.positions[:], source.indices[:], params)
}

// A cancel stops the driver as it stops qm_remesh, with nothing left over.
@(test)
driver_cancel_stops_the_remesh :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	params := DEFAULT_PARAMS
	params.quads, params.threads, params.core = 1500, 4, .Odin
	progress: jobs.Progress
	jobs.progress_cancel(&progress)
	out, _, err, _ := remesh(source.positions[:], source.indices[:], params, &progress)
	defer polygon_mesh_destroy(&out)
	testing.expect_value(t, err, Error.Cancelled)
	testing.expect_value(t, len(out.positions), 0)
}
