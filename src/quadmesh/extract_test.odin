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

// A ball with fins far thinner than a quad at a low count: across a fin the cover's grid
// closes after two edges or folds over a stretch of it, which left an edge of four faces
// (two traced edges between one pair of vertices) or a fin's tip a piece of its own, the
// hole round the fin capped at both ends. Every count comes back one closed manifold piece
// with the ball's Euler characteristic, on one thread or four alike.
@(test)
extraction_keeps_thin_parts_whole :: proc(t: ^testing.T) {
	ball := finned_ball()
	defer geom.mesh_destroy(&ball)
	params := DEFAULT_PARAMS
	twins, bridges := 0, 0
	for quads in ([]int{60, 100, 150, 200, 300}) {
		faces: [2]int
		for threads, k in ([]int{1, 4}) {
			params.quads, params.threads = quads, threads
			out, report, err, reason := remesh(ball.positions[:], ball.indices[:], params)
			defer polygon_mesh_destroy(&out)
			if !testing.expectf(t, err == .None, "%d quads: %v %s", quads, err, reason) do continue
			c := report.checks
			log.infof("finned ball at %d quads, %d threads: %d faces; %s", quads, threads, report.faces, checks_line(c))
			testing.expectf(t, c.quad_open_edges == 0 && c.quad_nonmanifold == 0, "%d quads: %d open and %d non-manifold edges", quads, c.quad_open_edges, c.quad_nonmanifold)
			testing.expectf(t, c.quad_euler == 2, "%d quads: Euler characteristic %d", quads, c.quad_euler)
			pieces := polygon_pieces(out)
			testing.expectf(t, pieces == 1, "%d quads: %d pieces", quads, pieces)
			faces[k] = report.faces
			if threads == 1 {
				twins += c.extract_twins
				bridges += c.extract_bridges
			}
		}
		testing.expectf(t, faces[0] == faces[1], "%d quads: %d faces on one thread, %d on four", quads, faces[0], faces[1])
	}
	log.infof("finned ball: %d twin edges parted, %d pieces bridged", twins, bridges)
	testing.expectf(t, twins > 0 && bridges > 0, "the fins no longer reach either: %d twin edges, %d bridges", twins, bridges)
}

// The pieces a polygon mesh falls into through its polygons' corners.
@(private = "file")
polygon_pieces :: proc(m: Polygon_Mesh) -> int {
	set := make([]int, len(m.positions), context.temp_allocator)
	for &v, i in set do v = i
	root :: proc(set: []int, v: int) -> int {
		r := v
		for set[r] != r do r = set[r]
		return r
	}
	used := make([]bool, len(m.positions), context.temp_allocator)
	for f in 0 ..< len(m.first) - 1 {
		c := m.corners[m.first[f]:m.first[f + 1]]
		for v in c {
			used[v] = true
			a, b := root(set, int(v)), root(set, int(c[0]))
			if a != b do set[max(a, b)] = min(a, b)
		}
	}
	pieces := 0
	for v in 0 ..< len(set) do if used[v] && root(set, v) == v do pieces += 1
	return pieces
}

// A unit ball with six fins grown smoothly out of it, each reaching three times the ball's
// radius past it, FIN_WIDTH radians wide at its root one way and a fifth of that the other.
@(private = "file")
finned_ball :: proc() -> geom.Mesh {
	m := geom.icosphere(5)
	directions := [6]geom.Vec3{{1, 0, 0}, {-0.6, 0.8, 0}, {-0.6, -0.8, 0}, {0, 0.3, 0.95}, {0.2, -0.4, -0.9}, {0.7, 0.7, 0.1}}
	for &p in m.positions {
		r := f32(1)
		for d in directions {
			axis := d / math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			along := p.x * axis.x + p.y * axis.y + p.z * axis.z
			if along <= 0 do continue
			// Across the fin: its width one way, and five times as steep the other.
			wide := geom.Vec3{axis.y, -axis.x, 0} if abs(axis.z) < 0.9 else geom.Vec3{1, 0, 0}
			wide /= math.sqrt(wide.x * wide.x + wide.y * wide.y + wide.z * wide.z)
			off := p - along * axis
			a := off.x * wide.x + off.y * wide.y + off.z * wide.z
			rest := off - a * wide
			b := math.sqrt(rest.x * rest.x + rest.y * rest.y + rest.z * rest.z) / FIN_FLAT
			angle := math.atan2(math.sqrt(a * a + b * b), along)
			if angle < FIN_WIDTH do r = max(r, 1 + FIN_LENGTH * (1 - angle / FIN_WIDTH) * (1 - angle / FIN_WIDTH))
		}
		p *= r
	}
	return m
}

// A fin's width at its root in radians, how much thinner it is the other way, and how far
// past the ball it reaches.
@(private = "file")
FIN_WIDTH :: f32(0.1)
@(private = "file")
FIN_FLAT :: f32(0.2)
@(private = "file")
FIN_LENGTH :: f32(3)
