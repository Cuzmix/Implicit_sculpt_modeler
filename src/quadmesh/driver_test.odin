package quadmesh

import "core:log"
import "core:math"
import "core:testing"

import "../geom"

// The whole remesh on a closed, sound fixture: each stage hands on a closed manifold mesh
// with no sliver, the checks agree with the report, every polygon is a quad, the surface's
// Euler characteristic is kept and the count lands within 4 % of the ask.
@(private = "file")
sound_remesh :: proc(t: ^testing.T, name: string, positions: []geom.Vec3, indices: []u32, params: Params, euler: int, loc := #caller_location) {
	out, report, err, reason := remesh(positions, indices, params)
	defer polygon_mesh_destroy(&out)
	if !testing.expectf(t, err == .None, "%s: %v %s", name, err, reason, loc = loc) do return
	c := report.checks
	log.infof("%s: %d faces in %.0f ms; %s", name, report.faces, report.ms, checks_line(c))
	testing.expectf(t, c.quad_faces == report.faces && c.quad_quads == report.quads && c.covers == report.covers && c.iso_triangles == report.isotropic_triangles, "%s: the checks disagree with the report: %v", name, c, loc = loc)
	// The smallest sphere of three islands, a few quads round, has a corner of about 7
	// degrees after its thinning.
	testing.expectf(t, c.thin_open_edges == 0 && c.thin_nonmanifold == 0 && c.iso_open_edges == 0 && c.iso_nonmanifold == 0 && c.quad_open_edges == 0 && c.quad_nonmanifold == 0, "%s: a stage opened the surface: %s", name, checks_line(c), loc = loc)
	testing.expectf(t, c.iso_min_angle > 5, "%s: a sliver: %s", name, checks_line(c), loc = loc)
	testing.expectf(t, report.quads == report.faces && c.quad_euler == euler, "%s: %d of %d faces are quads, Euler characteristic %d for the surface's %d", name, report.quads, report.faces, c.quad_euler, euler, loc = loc)
	testing.expectf(t, abs(f64(report.faces - params.quads)) <= 0.04 * f64(params.quads), "%s: %d quads for the %d asked", name, report.faces, params.quads, loc = loc)
}

// Three spheres of three sizes in one mesh: three islands, on their own threads with four,
// their count landing over the three together.
@(test)
driver_lands_over_islands :: proc(t: ^testing.T) {
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
		sound_remesh(t, "three spheres", positions, indices, params, 6)
	}
}

// Feature edges round the equator, a density asking four times the quads on one side, a
// refinement on the other and a guide curve: every value the driver gives out to the
// islands, through the stages that take them.
@(test)
driver_takes_every_input :: proc(t: ^testing.T) {
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
	sound_remesh(t, "features", source.positions[:], source.indices[:], params, 2)
	params.density = density
	sound_remesh(t, "features and density", source.positions[:], source.indices[:], params, 2)
	params.refine = refine
	params.guides, params.guide_strength = guides[:], 0.5
	sound_remesh(t, "every input", source.positions[:], source.indices[:], params, 2)
}
