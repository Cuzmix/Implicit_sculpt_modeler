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

// A ball with a tail about two quads round at a few hundred quads: at the plain isotropic
// size the tail was a tube of two or three triangles round, whose cover folded flat, and a
// fifth to a third of it came back missing (its tip two to three quad edges from the
// quads); on the finer mesh a low count gets (ISOTROPIC_LEAST), the tip is reached within
// half a quad edge, and the ball comes back closed.
@(test)
driver_keeps_thin_parts_at_low_counts :: proc(t: ^testing.T) {
	ball := tailed_ball()
	defer geom.mesh_destroy(&ball)
	tip := geom.Vec3{0, 0, 1 + TAIL_LENGTH + TAIL_RADIUS}
	params := DEFAULT_PARAMS
	for quads in ([]int{150, 200, 250, 300}) {
		params.quads = quads
		out, report, err, reason := remesh(ball.positions[:], ball.indices[:], params)
		defer polygon_mesh_destroy(&out)
		if !testing.expectf(t, err == .None, "%d quads: %v %s", quads, err, reason) do continue
		miss := f32(math.INF_F32)
		for f in 0 ..< len(out.first) - 1 {
			c := out.corners[out.first[f]:out.first[f + 1]]
			for k in 1 ..< len(c) - 1 {
				q, _ := geom.closest_on_triangle(tip, out.positions[c[0]], out.positions[c[k]], out.positions[c[k + 1]])
				d := q - tip
				miss = min(miss, math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
			}
		}
		quad_edge := math.sqrt(mesh_area_of(ball) / f32(quads))
		log.infof("tailed ball at %d quads: %d faces, the tip %.3f from the quads (a quad edge %.3f); %s", quads, report.faces, miss, quad_edge, checks_line(report.checks))
		testing.expectf(t, miss < quad_edge / 2, "%d quads: the tail's tip is %.3f from the quads, a quad edge %.3f", quads, miss, quad_edge)
		testing.expectf(t, report.checks.quad_open_edges == 0 && report.checks.quad_nonmanifold == 0 && report.checks.quad_euler == 2, "%d quads: %s", quads, checks_line(report.checks))
	}
}

// A mesh's area.
@(private = "file")
mesh_area_of :: proc(m: geom.Mesh) -> f32 {
	area := f32(0)
	for i := 0; i + 2 < len(m.indices); i += 3 {
		a, b, c := m.positions[m.indices[i]], m.positions[m.indices[i + 1]], m.positions[m.indices[i + 2]]
		u, v := b - a, c - a
		n := geom.Vec3{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x}
		area += math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z) / 2
	}
	return area
}

// The tail's radius and how far past the ball it reaches.
@(private = "file")
TAIL_RADIUS :: f32(0.08)
@(private = "file")
TAIL_LENGTH :: f32(2.5)

// A unit ball with a round-tipped tail along +z: a surface of revolution whose profile is
// the smooth larger of the ball's and the tail's, in TAIL_RINGS rings of TAIL_AROUND.
@(private = "file")
tailed_ball :: proc() -> (m: geom.Mesh) {
	TAIL_RINGS :: 600
	TAIL_AROUND :: 64
	bottom, top := f32(-1), 1 + TAIL_LENGTH + TAIL_RADIUS
	append(&m.positions, geom.Vec3{0, 0, bottom})
	for i in 1 ..< TAIL_RINGS {
		z := bottom + (top - bottom) * f32(i) / TAIL_RINGS
		ball := math.sqrt(max(0, 1 - z * z))
		end := 1 + TAIL_LENGTH
		tail := f32(0)
		if z >= 0 && z <= end do tail = TAIL_RADIUS
		else if z > end do tail = math.sqrt(max(0, TAIL_RADIUS * TAIL_RADIUS - (z - end) * (z - end)))
		r := math.pow(math.pow(ball, 6) + math.pow(tail, 6), 1.0 / 6)
		for j in 0 ..< TAIL_AROUND {
			a := 2 * math.PI * f32(j) / TAIL_AROUND
			append(&m.positions, geom.Vec3{r * math.cos(a), r * math.sin(a), z})
		}
	}
	append(&m.positions, geom.Vec3{0, 0, top})
	at :: proc(i, j: int) -> u32 {return u32(1 + (i - 1) * TAIL_AROUND + j % TAIL_AROUND)}
	last := u32(len(m.positions) - 1)
	for j in 0 ..< TAIL_AROUND do append(&m.indices, 0, at(1, j + 1), at(1, j))
	for i in 1 ..< TAIL_RINGS - 1 do for j in 0 ..< TAIL_AROUND {
		a, b, c, d := at(i, j), at(i, j + 1), at(i + 1, j + 1), at(i + 1, j)
		append(&m.indices, a, b, c, a, c, d)
	}
	for j in 0 ..< TAIL_AROUND do append(&m.indices, at(TAIL_RINGS - 1, j), at(TAIL_RINGS - 1, j + 1), last)
	return
}
