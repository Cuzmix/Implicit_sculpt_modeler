package quadmesh

import "core:log"
import "core:math"
import "core:testing"

import "../geom"

// The extraction through the whole remesh: every cell of the cover a quad, nothing open,
// the surface's Euler characteristic kept, nothing gone round, filled or dropped, and the
// count asked within 4 %.
@(private = "file")
every_cell_a_quad :: proc(t: ^testing.T, name: string, positions: []geom.Vec3, indices: []u32, params: Params, euler: int, loc := #caller_location) {
	out, report, err, reason := remesh(positions, indices, params)
	defer polygon_mesh_destroy(&out)
	if !testing.expectf(t, err == .None, "%s: %v %s", name, err, reason, loc = loc) do return
	c := report.checks
	log.infof("%s: %d faces (%d quads) in %.0f ms (extraction %.0f ms); %s", name, report.faces, report.quads, report.ms, report.extract_ms, checks_line(c))
	testing.expectf(t, report.quads == report.faces, "%s: %d of %d faces are quads", name, report.quads, report.faces, loc = loc)
	testing.expectf(t, c.quad_open_edges == 0 && c.quad_nonmanifold == 0, "%s: %d open and %d non-manifold edges", name, c.quad_open_edges, c.quad_nonmanifold, loc = loc)
	testing.expectf(t, c.quad_euler == euler, "%s: Euler characteristic %d, the surface's %d", name, c.quad_euler, euler, loc = loc)
	testing.expectf(t, c.extract_unmatched == 0 && c.extract_holes == 0 && c.extract_filled == 0 && c.extract_dropped == 0, "%s: %s", name, checks_line(c), loc = loc)
	testing.expectf(t, f64(report.faces) == math.round(c.cover_cells_abs), "%s: %d quads for the cover's %.1f cells", name, report.faces, c.cover_cells_abs, loc = loc)
	testing.expectf(t, abs(f64(report.faces - params.quads)) <= 0.04 * f64(params.quads), "%s: %d quads for the %d asked", name, report.faces, params.quads, loc = loc)
}

// A sphere: every cell of a fold-free cover becomes a quad, about the count asked.
@(test)
extraction_makes_every_cell_a_quad :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	params := DEFAULT_PARAMS
	params.quads = 1500
	for threads in ([]int{1, 4}) {
		params.threads = threads
		every_cell_a_quad(t, "sphere", source.positions[:], source.indices[:], params, 2)
	}
	params.adaptivity = 1
	every_cell_a_quad(t, "sphere at full adaptivity", source.positions[:], source.indices[:], params, 2)
}

// A torus (Euler characteristic 0) and three spheres in one mesh (6).
@(test)
extraction_keeps_the_topology :: proc(t: ^testing.T) {
	torus := torus_mesh(96, 48, 1, 0.4)
	defer geom.mesh_destroy(&torus)
	params := DEFAULT_PARAMS
	params.quads = 1500
	every_cell_a_quad(t, "torus", torus.positions[:], torus.indices[:], params, 0)

	source := geom.icosphere(3)
	defer geom.mesh_destroy(&source)
	n := len(source.positions)
	positions := make([]geom.Vec3, 3 * n, context.temp_allocator)
	indices := make([]u32, 3 * len(source.indices), context.temp_allocator)
	for p, i in source.positions {
		positions[i] = p + {-1.5, 0, 0}
		positions[n + i] = 0.6 * p + {1.5, 0, 0}
		positions[2 * n + i] = 0.5 * p + {0, 1.5, 0}
	}
	for k in 0 ..< 3 do for v, i in source.indices do indices[k * len(source.indices) + i] = v + u32(k * n)
	params.quads = 1200
	every_cell_a_quad(t, "three spheres", positions, indices, params, 6)
}

// A torus of nu by nv quads cut in two triangles each, wound outward.
@(private = "file")
torus_mesh :: proc(nu, nv: int, big, small: f32) -> (m: geom.Mesh) {
	for i in 0 ..< nu do for j in 0 ..< nv {
		u := 2 * math.PI * f32(i) / f32(nu)
		v := 2 * math.PI * f32(j) / f32(nv)
		r := big + small * math.cos(v)
		append(&m.positions, geom.Vec3{r * math.cos(u), r * math.sin(u), small * math.sin(v)})
	}
	at :: proc(i, j, nu, nv: int) -> u32 {
		return u32((i % nu) * nv + j % nv)
	}
	for i in 0 ..< nu do for j in 0 ..< nv {
		a, b, c, d := at(i, j, nu, nv), at(i + 1, j, nu, nv), at(i + 1, j + 1, nu, nv), at(i, j + 1, nu, nv)
		append(&m.indices, a, b, c, a, c, d)
	}
	return
}
