package geom

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"
import "core:testing"

import "../jobs"

// Every edge in exactly two triangles, once each way, and no triangle repeats a vertex.
@(private)
expect_closed_manifold :: proc(t: ^testing.T, m: Mesh, loc := #caller_location) -> (edges: int) {
	directed := make(map[[2]u32]int, len(m.indices), context.temp_allocator)
	for i := 0; i < len(m.indices); i += 3 {
		for c in 0 ..< 3 {
			a, b := m.indices[i + c], m.indices[i + (c + 1) % 3]
			if a == b {
				testing.expect(t, false, "degenerate triangle", loc = loc)
				return
			}
			directed[{a, b}] += 1
		}
	}
	for e, n in directed {
		if n != 1 || directed[{e[1], e[0]}] != 1 {
			testing.expectf(t, false, "edge %v is in %d triangles that way and %d the other", e, n, directed[{e[1], e[0]}], loc = loc)
			return
		}
	}
	return len(directed) / 2
}

@(test)
remesh_sphere_is_closed_and_keeps_its_shape :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	for target in ([?]int{300, 5000, 40_000}) {
		out, ok := remesh_voxel(sphere, target, &pool)
		defer mesh_destroy(&out)
		testing.expect(t, ok, "remesh failed")
		v, f := len(out.positions), len(out.indices) / 3
		testing.expectf(t, v > target * 7 / 10 && v < target * 13 / 10, "asked for %d vertices, got %d", target, v)
		edges := expect_closed_manifold(t, out)
		testing.expectf(t, v - edges + f == 2, "Euler characteristic %d, not a sphere", v - edges + f)
		h := remesh_spacing(sphere, target)
		worst: f32
		for p, i in out.positions {
			worst = max(worst, abs(linalg.length(p) - 1))
			testing.expect(t, linalg.dot(out.normals[i], p) > 0, "normal points inward")
		}
		testing.expectf(t, worst < 0.6 * h, "a vertex is %v off the sphere, h = %v", worst, h)
	}
}

// Two overlapping spheres become one closed surface with nothing left inside.
@(test)
remesh_merges_overlapping_parts :: proc(t: ^testing.T) {
	a := icosphere(4)
	b := icosphere(4)
	defer mesh_destroy(&a)
	defer mesh_destroy(&b)
	CENTER_B :: Vec3{0.8, 0.3, 0}
	both: Mesh
	defer mesh_destroy(&both)
	for p in a.positions do append(&both.positions, p)
	for p in b.positions do append(&both.positions, p + CENTER_B)
	for i in a.indices do append(&both.indices, i)
	for i in b.indices do append(&both.indices, i + u32(len(a.positions)))
	resize(&both.normals, len(both.positions))
	out, ok := remesh_voxel(both, 8000, nil)
	defer mesh_destroy(&out)
	testing.expect(t, ok, "remesh failed")
	edges := expect_closed_manifold(t, out)
	v, f := len(out.positions), len(out.indices) / 3
	testing.expectf(t, v - edges + f == 2, "Euler characteristic %d: not one closed surface", v - edges + f)
	h := remesh_spacing(both, 8000)
	for p in out.positions {
		da, db := linalg.length(p), linalg.length(p - CENTER_B)
		// On one sphere's surface, and not inside the other.
		testing.expect(t, min(abs(da - 1), abs(db - 1)) < 0.6 * h, "vertex off both spheres")
		testing.expect(t, da > 1 - 0.6 * h && db > 1 - 0.6 * h, "vertex inside the merged shape")
	}
}

// A mesh with a twisted (self-intersecting) region still gives a closed surface.
@(test)
remesh_survives_self_intersection :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	// Push a cap through the sphere so it pokes out the other side.
	for &p in m.positions do if p.z > 0.6 do p.z -= 1.9
	out, ok := remesh_voxel(m, 6000, nil)
	defer mesh_destroy(&out)
	testing.expect(t, ok, "remesh failed")
	_ = expect_closed_manifold(t, out)
}

// The area and box come out the same with and without the pool, skip zeroed triangle
// slots, and give the lattice the remesh builds on: remeshing at its spacing is, bit for
// bit, remeshing to the count.
@(test)
remesh_lattice_is_the_one_remesh_uses :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(7) // more triangles than one range
	defer mesh_destroy(&sphere)
	area, bounds := mesh_area_bounds(sphere, &pool)
	serial_area, serial_bounds := mesh_area_bounds(sphere, nil)
	testing.expect_value(t, area, serial_area)
	testing.expect_value(t, bounds, serial_bounds)
	testing.expectf(t, abs(area - 4 * math.PI) < 0.01, "a unit sphere's area is %v", area)
	// A few parts at a time, as the preview spreads a big mesh over frames.
	parts := make([]Area_Part, mesh_area_part_count(sphere))
	defer delete(parts)
	testing.expect(t, len(parts) > 2)
	for from := 0; from < len(parts); from += 2 do mesh_area_parts(sphere, parts, from, min(from + 2, len(parts)), &pool)
	piece_area, piece_bounds := mesh_area_total(parts)
	testing.expect_value(t, piece_area, area)
	testing.expect_value(t, piece_bounds, bounds)
	// A zeroed slot, as dynamic topology leaves, adds nothing.
	append(&sphere.indices, 0, 0, 0)
	with_slot, slot_bounds := mesh_area_bounds(sphere, &pool)
	testing.expect_value(t, with_slot, area)
	testing.expect_value(t, slot_bounds, bounds)
	resize(&sphere.indices, len(sphere.indices) - 3)
	h, origin, ok := remesh_lattice(area, bounds, 5000)
	testing.expect(t, ok)
	testing.expect_value(t, origin, bounds.lo - 1.5 * h)
	a, ok_a := remesh_voxel(sphere, 5000, &pool)
	b, ok_b := remesh_voxel_spacing(sphere, h, &pool)
	defer mesh_destroy(&a)
	defer mesh_destroy(&b)
	testing.expect(t, ok_a && ok_b)
	testing.expect(t, slice.equal(a.positions[:], b.positions[:]))
	// A vertex no triangle uses, as a dynamic topology layout keeps, moves nothing.
	append(&sphere.positions, Vec3{3, 0, 0})
	append(&sphere.normals, Vec3{1, 0, 0})
	c, ok_c := remesh_voxel_measured(sphere, area, bounds, 5000, &pool)
	defer mesh_destroy(&c)
	testing.expect(t, ok_c)
	testing.expect(t, slice.equal(a.positions[:], c.positions[:]))
	// A thin, long box is held to REMESH_MAX_LATTICE points along its length.
	long := Aabb{{0, 0, 0}, {1000, 0.01, 0.01}}
	h_long, _, _ := remesh_lattice(1, long, 10_000_000)
	testing.expect_value(t, h_long, f32(1000) / (REMESH_MAX_LATTICE - 4))
	_, _, ok_empty := remesh_lattice(0, AABB_EMPTY, 1000)
	testing.expect(t, !ok_empty)
}

// The volume the closed mesh encloses.
@(private = "file")
remesh_volume :: proc(m: Mesh) -> (v: f32) {
	for i := 0; i < len(m.indices); i += 3 {
		v += linalg.dot(m.positions[m.indices[i]], linalg.cross(m.positions[m.indices[i + 1]], m.positions[m.indices[i + 2]])) / 6
	}
	return
}

// A sphere with a square sheet beside it facing along `axis`, either way round
// (`flip`), or with the triangles beyond 0.6 along the axis cut away so it is a bowl
// opening that way (`bowl`).
@(private = "file")
open_fixture :: proc(axis: int, flip, bowl: bool) -> (m: Mesh) {
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	m.positions = make([dynamic]Vec3, len(sphere.positions))
	m.normals = make([dynamic]Vec3, len(sphere.positions))
	copy(m.positions[:], sphere.positions[:])
	for i := 0; i < len(sphere.indices); i += 3 {
		if bowl {
			mid := (sphere.positions[sphere.indices[i]] + sphere.positions[sphere.indices[i + 1]] + sphere.positions[sphere.indices[i + 2]]) / 3
			if (mid[axis] if !flip else -mid[axis]) > 0.6 do continue
		}
		append(&m.indices, sphere.indices[i], sphere.indices[i + 1], sphere.indices[i + 2])
	}
	if bowl do return
	base := u32(len(m.positions))
	a, b := (axis + 1) % 3, (axis + 2) % 3
	for s in 0 ..< 4 {
		p: Vec3
		p[axis] = 1.5
		p[a] = -0.7 if s == 0 || s == 3 else 0.7
		p[b] = -0.7 if s < 2 else 0.7
		append(&m.positions, p)
		append(&m.normals, Vec3{})
	}
	if flip {
		append(&m.indices, base, base + 2, base + 1, base, base + 3, base + 2)
	} else {
		append(&m.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
	return
}

// An open part is capped before the rays, so the remesh is closed whichever way the
// opening faces: a bowl becomes a solid of nearly the ball's volume, and a flat sheet,
// capped to nothing, goes while the sphere beside it stays whole. Without the cap a
// sheet facing -x or a bowl opening to +x left boundary and non-manifold edges.
@(test)
remesh_caps_open_parts_first :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	ball := f32(4 * math.PI / 3)
	for axis in 0 ..< 3 do for flip in ([2]bool{false, true}) do for bowl in ([2]bool{false, true}) {
		m := open_fixture(axis, flip, bowl)
		defer mesh_destroy(&m)
		testing.expect(t, !mesh_edges_paired(m, &pool), "the fixture should be open")
		report: Remesh_Report
		defer remesh_report_destroy(&report)
		area, bounds := mesh_area_bounds(m, &pool)
		out, ok := remesh_voxel_measured(m, area, bounds, 4000, &pool, report = &report)
		defer mesh_destroy(&out)
		testing.expectf(t, ok, "axis %d flip %v bowl %v: remesh failed", axis, flip, bowl)
		expect_closed_manifold(t, out)
		testing.expectf(t, report.holes_closed >= 1, "axis %d flip %v bowl %v: %d holes closed", axis, flip, bowl, report.holes_closed)
		v := remesh_volume(out)
		if bowl {
			testing.expectf(t, v > 0.85 * ball && v < 1.02 * ball, "axis %d flip %v: the capped bowl has volume %.3f of the ball's %.3f", axis, flip, v, ball)
		} else {
			testing.expectf(t, v > 0.95 * ball && v < 1.02 * ball, "axis %d flip %v: the sphere beside a sheet has volume %.3f of %.3f", axis, flip, v, ball)
		}
	}
	// A closed mesh is paired and capped nowhere.
	sphere := icosphere(3)
	defer mesh_destroy(&sphere)
	testing.expect(t, mesh_edges_paired(sphere, &pool) && mesh_edges_paired(sphere), "a sphere pairs its edges")
}

// How uneven the edges are: their standard deviation over their mean.
@(private = "file")
edge_spread :: proc(m: Mesh) -> (deviation_over_mean: f32) {
	lengths := make([dynamic]f32, 0, len(m.indices), context.temp_allocator)
	for i := 0; i < len(m.indices); i += 3 {
		for c in 0 ..< 3 {
			a, b := m.indices[i + c], m.indices[i + (c + 1) % 3]
			if a < b do append(&lengths, linalg.length(m.positions[a] - m.positions[b]))
		}
	}
	mean, sq: f64
	for l in lengths do mean += f64(l)
	mean /= f64(len(lengths))
	for l in lengths do sq += (f64(l) - mean) * (f64(l) - mean)
	return f32(math.sqrt(sq / f64(len(lengths))) / mean)
}

// Smooth is the relax rounds: none leaves the raw marching cubes, closed all the same,
// and more rounds even the edges out further, the shape kept.
@(test)
remesh_smooth_rounds_even_the_edges :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	area, bounds := mesh_area_bounds(sphere, &pool)
	spread: [3]f32
	for rounds, i in ([3]int{0, REMESH_SMOOTH_DEFAULT, REMESH_SMOOTH_MAX}) {
		out, ok := remesh_voxel_measured(sphere, area, bounds, 5000, &pool, options = {smooth = rounds})
		defer mesh_destroy(&out)
		testing.expect(t, ok, "remesh failed")
		expect_closed_manifold(t, out)
		spread[i] = edge_spread(out)
		worst: f32
		for p in out.positions do worst = max(worst, abs(linalg.length(p) - 1))
		testing.expectf(t, worst < 0.05, "%d rounds: a vertex is %.4f off the sphere", rounds, worst)
	}
	testing.expectf(t, spread[0] > spread[1] && spread[1] > spread[2], "edge spread %.3f, %.3f, %.3f should fall with the rounds", spread[0], spread[1], spread[2])
	// The default rounds are what remesh_voxel does.
	plain, _ := remesh_voxel(sphere, 5000, &pool)
	defer mesh_destroy(&plain)
	same, _ := remesh_voxel_measured(sphere, area, bounds, 5000, &pool, options = REMESH_OPTIONS_DEFAULT)
	defer mesh_destroy(&same)
	testing.expect(t, slice.equal(plain.positions[:], same.positions[:]) && slice.equal(plain.indices[:], same.indices[:]), "the default options are the plain remesh")
}

// Keep detail puts the vertices back on the surface they came from, with the old
// triangle each landed on, so a bumpy sphere keeps its bumps where the lattice alone
// rounded them off.
@(test)
remesh_keep_detail_projects_back :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	bumpy := icosphere(5)
	defer mesh_destroy(&bumpy)
	radius :: proc(p: Vec3) -> f32 {
		d := linalg.normalize(p)
		return 1 + 0.04 * math.sin(9 * d.x) * math.cos(9 * d.y) * math.sin(7 * d.z)
	}
	for &p in bumpy.positions do p = linalg.normalize(p) * radius(p)
	area, bounds := mesh_area_bounds(bumpy, &pool)
	deviation :: proc(m: Mesh, radius: proc(p: Vec3) -> f32) -> (mean: f32) {
		for p in m.positions do mean += abs(linalg.length(p) - radius(p))
		return mean / f32(len(m.positions))
	}
	plain, ok := remesh_voxel_measured(bumpy, area, bounds, 3000, &pool)
	defer mesh_destroy(&plain)
	testing.expect(t, ok, "remesh failed")
	report: Remesh_Report
	defer remesh_report_destroy(&report)
	kept, ok2 := remesh_voxel_measured(bumpy, area, bounds, 3000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, keep_detail = true}, report = &report)
	defer mesh_destroy(&kept)
	testing.expect(t, ok2, "remesh with Keep detail failed")
	expect_closed_manifold(t, kept)
	testing.expect_value(t, len(report.source_tris), len(kept.positions))
	found := 0
	for tri in report.source_tris do if tri != max(u32) do found += 1
	testing.expectf(t, found > len(kept.positions) * 95 / 100, "%d of %d vertices found the old surface", found, len(kept.positions))
	before, after := deviation(plain, radius), deviation(kept, radius)
	testing.expectf(t, after < before / 2, "mean deviation %.5f without Keep detail, %.5f with", before, after)
}

// Groups remeshes each polygroup as a closed piece of its own on the one lattice, and
// says which group each triangle of the result is in.
@(test)
remesh_groups_make_a_closed_piece_each :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	tcount := len(sphere.indices) / 3
	groups := make([]u16, tcount)
	defer delete(groups)
	// The upper half group 7, the lower group 3: the numbering need not be dense.
	for t in 0 ..< tcount {
		mid := (sphere.positions[sphere.indices[3 * t]] + sphere.positions[sphere.indices[3 * t + 1]] + sphere.positions[sphere.indices[3 * t + 2]]) / 3
		groups[t] = 7 if mid.y > 0 else 3
	}
	area, bounds := mesh_area_bounds(sphere, &pool)
	report: Remesh_Report
	defer remesh_report_destroy(&report)
	out, ok := remesh_voxel_measured(sphere, area, bounds, 4000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, groups = groups}, report = &report)
	defer mesh_destroy(&out)
	testing.expect(t, ok, "remesh failed")
	expect_closed_manifold(t, out)
	testing.expect_value(t, report.pieces, 2)
	testing.expect_value(t, report.dropped, 0)
	// The seams the pieces are capped along are not holes the mesh had.
	testing.expect_value(t, report.holes_closed, 0)
	testing.expect_value(t, len(report.groups), len(out.indices) / 3)
	part, count := mesh_components(out)
	defer delete(part)
	testing.expect_value(t, count, 2)
	// Every triangle's group agrees with its piece, and the upper piece is group 7.
	for g, tri in report.groups {
		mid := (out.positions[out.indices[3 * tri]] + out.positions[out.indices[3 * tri + 1]] + out.positions[out.indices[3 * tri + 2]]) / 3
		// The caps of the two pieces lie within a cell of the plane between them.
		want: u16 = 7 if mid.y > 0.07 else (3 if mid.y < -0.07 else g)
		if g != want {
			testing.expectf(t, false, "triangle %d at y %.3f is in group %d", tri, mid.y, g)
			break
		}
	}
	// Each half ball's volume, together nearly the ball.
	v := remesh_volume(out)
	ball := f32(4 * math.PI / 3)
	testing.expectf(t, v > 0.9 * ball && v < 1.02 * ball, "the two pieces have volume %.3f of %.3f", v, ball)
}

// Remeshing again at the same density stays put: ten rounds keep the count and the
// volume within a percent, since the lattice is placed from the bounds each time.
@(test)
remesh_repeats_stably :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := icosphere(4)
	first_count, first_volume := 0, f32(0)
	for round in 0 ..< 10 {
		out, ok := remesh_voxel(m, 5000, &pool)
		testing.expect(t, ok, "remesh failed")
		mesh_destroy(&m)
		m = out
		count, volume := len(m.positions), remesh_volume(m)
		if round == 0 {
			first_count, first_volume = count, volume
			continue
		}
		testing.expectf(t, abs(count - first_count) * 100 <= first_count, "round %d: %d vertices, the first gave %d", round, count, first_count)
		testing.expectf(t, abs(volume - first_volume) <= 0.01 * first_volume, "round %d: volume %.4f, the first gave %.4f", round, volume, first_volume)
	}
	mesh_destroy(&m)
}

// Every option gives the same mesh, bit for bit, with the pool and without: the edge
// pairing is a wrapping sum, the pieces are split and joined in order, and the projection
// is per vertex.
@(test)
remesh_options_agree_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	bowl := open_fixture(0, false, true)
	defer mesh_destroy(&bowl)
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	groups := make([]u16, len(sphere.indices) / 3)
	defer delete(groups)
	for t in 0 ..< len(groups) {
		mid := (sphere.positions[sphere.indices[3 * t]] + sphere.positions[sphere.indices[3 * t + 1]] + sphere.positions[sphere.indices[3 * t + 2]]) / 3
		groups[t] = 1 if mid.x > 0.2 else (2 if mid.x < -0.2 else 0)
	}
	Case :: struct {
		name:    string,
		mesh:    ^Mesh,
		options: Remesh_Options,
	}
	cases := [?]Case {
		{"bowl, no smoothing", &bowl, {smooth = 0}},
		{"bowl, eight rounds, detail kept", &bowl, {smooth = REMESH_SMOOTH_MAX, keep_detail = true}},
		{"three groups, detail kept", &sphere, {smooth = REMESH_SMOOTH_DEFAULT, keep_detail = true, groups = groups}},
		{"bowl, quads, no smoothing", &bowl, {smooth = 0, quads = true}},
		{"three groups, quads, detail kept", &sphere, {smooth = REMESH_SMOOTH_MAX, keep_detail = true, groups = groups, quads = true}},
	}
	for c in cases {
		area, bounds := mesh_area_bounds(c.mesh^, &pool)
		serial_report, parallel_report: Remesh_Report
		defer remesh_report_destroy(&serial_report)
		defer remesh_report_destroy(&parallel_report)
		serial, ok1 := remesh_voxel_measured(c.mesh^, area, bounds, 3000, nil, options = c.options, report = &serial_report)
		defer mesh_destroy(&serial)
		parallel, ok2 := remesh_voxel_measured(c.mesh^, area, bounds, 3000, &pool, options = c.options, report = &parallel_report)
		defer mesh_destroy(&parallel)
		testing.expectf(t, ok1 && ok2, "%s: a remesh failed", c.name)
		testing.expectf(t, slice.equal(serial.positions[:], parallel.positions[:]) && slice.equal(serial.indices[:], parallel.indices[:]), "%s: serial and parallel differ", c.name)
		testing.expectf(t, slice.equal(serial_report.groups, parallel_report.groups) && slice.equal(serial_report.source_tris, parallel_report.source_tris) && slice.equal(serial_report.quads, parallel_report.quads), "%s: the reports differ", c.name)
		testing.expectf(t, serial_report.holes_closed == parallel_report.holes_closed && serial_report.pieces == parallel_report.pieces, "%s: the counts differ", c.name)
		if c.options.groups != nil do testing.expectf(t, serial_report.holes_closed == 0, "%s: seams counted as %d holes", c.name, serial_report.holes_closed)
	}
	// A doubled triangle pairs its edges, as the check promises.
	fin := icosphere(2)
	defer mesh_destroy(&fin)
	append(&fin.indices, fin.indices[0], fin.indices[2], fin.indices[1])
	append(&fin.indices, fin.indices[0], fin.indices[1], fin.indices[2])
	testing.expect(t, mesh_edges_paired(fin, &pool), "a sphere with a doubled triangle pairs its edges")
}

// A mesh inside out as a whole is turned outward first, so it remeshes as the same solid;
// a hollow one (an outer shell with a cavity) keeps its cavity, since only the whole's
// sign is read.
@(test)
remesh_turns_an_inside_out_mesh :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	inverted := icosphere(4)
	defer mesh_destroy(&inverted)
	for i := 0; i < len(inverted.indices); i += 3 do inverted.indices[i + 1], inverted.indices[i + 2] = inverted.indices[i + 2], inverted.indices[i + 1]
	testing.expect(t, mesh_signed_volume(inverted, &pool) < 0 && mesh_signed_volume(inverted) == mesh_signed_volume(inverted, &pool), "the fixture is inside out, serial and parallel alike")
	area, bounds := mesh_area_bounds(inverted, &pool)
	report: Remesh_Report
	out, ok := remesh_voxel_measured(inverted, area, bounds, 4000, &pool, report = &report)
	defer mesh_destroy(&out)
	testing.expect(t, ok && report.turned, "the inside-out sphere remeshes, turned")
	expect_closed_manifold(t, out)
	ball := f32(4 * math.PI / 3)
	testing.expectf(t, remesh_volume(out) > 0.95 * ball, "volume %.3f of %.3f", remesh_volume(out), ball)
	// Hollow: a sphere with an inverted half-size sphere inside it.
	hollow := icosphere(4)
	defer mesh_destroy(&hollow)
	base := u32(len(hollow.positions))
	for p in inverted.positions {
		append(&hollow.positions, 0.5 * p)
		append(&hollow.normals, Vec3{})
	}
	for i in inverted.indices do append(&hollow.indices, base + i)
	hollow_report: Remesh_Report
	shell, ok2 := remesh_voxel_measured(hollow, area, bounds, 4000, &pool, report = &hollow_report)
	defer mesh_destroy(&shell)
	testing.expect(t, ok2 && !hollow_report.turned && hollow_report.holes_closed == 0, "the hollow sphere remeshes as it is")
	expect_closed_manifold(t, shell)
	testing.expectf(t, abs(remesh_volume(shell) - 0.875 * ball) < 0.05 * ball, "the cavity should stay: volume %.3f, a hollow ball's %.3f", remesh_volume(shell), 0.875 * ball)
}

// Every quad has four distinct corners, every quad edge is in exactly two quads once each
// way (a closed manifold of quads), each quad's two triangles use only its corners, and
// the quads face the same way as the triangles do.
@(private = "file")
expect_quads_closed_manifold :: proc(t: ^testing.T, m: Mesh, quads: [][4]u32, loc := #caller_location) -> (edges: int) {
	testing.expectf(t, len(m.indices) == 6 * len(quads), "%d triangles for %d quads", len(m.indices) / 3, len(quads), loc = loc)
	directed := make(map[[2]u32]int, 4 * len(quads), context.temp_allocator)
	for &f, q in quads {
		for c in 0 ..< 4 do for d in c + 1 ..< 4 {
			if f[c] == f[d] {
				testing.expectf(t, false, "quad %d repeats a corner: %v", q, f, loc = loc)
				return
			}
		}
		for c in 0 ..< 4 do directed[{f[c], f[(c + 1) % 4]}] += 1
		if 6 * q + 6 > len(m.indices) do continue
		for i in m.indices[6 * q:][:6] {
			if !slice.contains(f[:], i) {
				testing.expectf(t, false, "quad %d's triangles use vertex %d, not a corner of %v", q, i, f, loc = loc)
				return
			}
		}
	}
	for e, n in directed {
		if n != 1 || directed[{e[1], e[0]}] != 1 {
			testing.expectf(t, false, "quad edge %v is in %d quads that way and %d the other", e, n, directed[{e[1], e[0]}], loc = loc)
			return
		}
	}
	return len(directed) / 2
}

// With Quads the remesh is a closed manifold of quads only, as many as the vertices
// asked, on the sphere (V = Q + 2), facing outward, as close to it as the triangles are.
@(test)
remesh_quads_are_a_closed_manifold :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	ball := f32(4 * math.PI / 3)
	for target in ([?]int{300, 5000, 40_000}) {
		for smooth in ([?]int{0, REMESH_SMOOTH_DEFAULT, REMESH_SMOOTH_MAX}) {
			if smooth != REMESH_SMOOTH_DEFAULT && target != 5000 do continue
			area, bounds := mesh_area_bounds(sphere, &pool)
			report: Remesh_Report
			defer remesh_report_destroy(&report)
			out, ok := remesh_voxel_measured(sphere, area, bounds, target, &pool, options = {smooth = smooth, quads = true}, report = &report)
			defer mesh_destroy(&out)
			testing.expectf(t, ok, "target %d smooth %d: remesh failed", target, smooth)
			v, q := len(out.positions), len(report.quads)
			testing.expectf(t, v > target * 7 / 10 && v < target * 13 / 10, "asked for %d vertices, got %d", target, v)
			edges := expect_quads_closed_manifold(t, out, report.quads)
			testing.expectf(t, v - edges + q == 2, "target %d: Euler characteristic %d, not a sphere", target, v - edges + q)
			expect_closed_manifold(t, out)
			h := remesh_spacing(sphere, target)
			worst: f32
			for p, i in out.positions {
				worst = max(worst, abs(linalg.length(p) - 1))
				testing.expect(t, linalg.dot(out.normals[i], p) > 0, "normal points inward")
			}
			testing.expectf(t, worst < 0.6 * h, "target %d smooth %d: a vertex is %v off the sphere, h = %v", target, smooth, worst, h)
			vol := remesh_volume(out)
			testing.expectf(t, vol > 0.9 * ball && vol < 1.02 * ball, "target %d: volume %.3f of %.3f", target, vol, ball)
			// Valence: a lattice dual is mostly four-sided vertices, with the poles the
			// lattice forces (logged, not pinned).
			valence := make([]int, v, context.temp_allocator)
			for f in report.quads do for c in f do valence[c] += 1
			four := 0
			for n in valence do if n == 4 do four += 1
			log.infof("quads at %d, smooth %d: %d vertices, %d quads, %.0f%% four-valent", target, smooth, v, q, 100 * f32(four) / f32(v))
		}
	}
}

// Quads compose with closed first (a bowl is capped, then dualised) and with Groups (each
// piece's quads are numbered after the pieces before it).
@(test)
remesh_quads_compose_with_caps_and_groups :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	ball := f32(4 * math.PI / 3)
	bowl := open_fixture(1, true, true)
	defer mesh_destroy(&bowl)
	{
		area, bounds := mesh_area_bounds(bowl, &pool)
		report: Remesh_Report
		defer remesh_report_destroy(&report)
		out, ok := remesh_voxel_measured(bowl, area, bounds, 4000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, quads = true}, report = &report)
		defer mesh_destroy(&out)
		testing.expect(t, ok, "the bowl's remesh failed")
		testing.expect(t, report.holes_closed == 1, "the bowl was capped")
		expect_quads_closed_manifold(t, out, report.quads)
		v := remesh_volume(out)
		testing.expectf(t, v > 0.85 * ball && v < 1.02 * ball, "the capped bowl has volume %.3f of %.3f", v, ball)
	}
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	groups := make([]u16, len(sphere.indices) / 3)
	defer delete(groups)
	for t in 0 ..< len(groups) {
		mid := (sphere.positions[sphere.indices[3 * t]] + sphere.positions[sphere.indices[3 * t + 1]] + sphere.positions[sphere.indices[3 * t + 2]]) / 3
		groups[t] = 7 if mid.y > 0 else 3
	}
	area, bounds := mesh_area_bounds(sphere, &pool)
	report: Remesh_Report
	defer remesh_report_destroy(&report)
	out, ok := remesh_voxel_measured(sphere, area, bounds, 4000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, groups = groups, quads = true, keep_detail = true}, report = &report)
	defer mesh_destroy(&out)
	testing.expect(t, ok, "the grouped remesh failed")
	testing.expect_value(t, report.pieces, 2)
	expect_quads_closed_manifold(t, out, report.quads)
	testing.expect_value(t, len(report.groups), len(out.indices) / 3)
	testing.expect_value(t, len(report.source_tris), len(out.positions))
	part, count := mesh_components(out)
	defer delete(part)
	testing.expect_value(t, count, 2)
	// Both halves of a quad are in one piece, so a quad's group is well defined.
	for q in 0 ..< len(report.quads) {
		if report.groups[2 * q] != report.groups[2 * q + 1] {
			testing.expectf(t, false, "quad %d's halves are in groups %d and %d", q, report.groups[2 * q], report.groups[2 * q + 1])
			break
		}
	}
	v := remesh_volume(out)
	testing.expectf(t, v > 0.9 * ball && v < 1.02 * ball, "the two pieces have volume %.3f of %.3f", v, ball)
}

// Where the surface runs through a gap thinner than a cell slipping diagonally between
// lattice points, a patch crosses a cell face twice on both sides of it: under the plain
// face rule the two cells' triangles shared a diagonal four at a time (the pinched tube
// of air), and the dual's quads would share an edge the same way. The rule turns on such a
// face (cell_flips), so two spheres a fraction of a cell apart remesh closed and manifold
// as triangles and as quads at every gap, the gap closing as any gap narrower than a cell
// does. The table lists 36 of the 256 cases with such a patch (checked against an
// independent derivation); the dual keeps its refusal for the case the turn cannot reach.
@(test)
remesh_closes_a_gap_thinner_than_a_cell :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sync.once_do(&mc_once, mc_build_table)
	doubled := 0
	for cl in mc_cells do if cl.faces != 0 do doubled += 1
	testing.expect_value(t, doubled, 36)
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	refused := 0
	// Along a direction oblique to the lattice: a gap on a lattice plane never slips
	// between the points diagonally.
	along := linalg.normalize(Vec3{1, 0.7, 0.4})
	for gap in ([?]f32{0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08}) {
		pair: Mesh
		defer mesh_destroy(&pair)
		for side in ([?]f32{-1, 1}) {
			base := u32(len(pair.positions))
			for p in sphere.positions {
				append(&pair.positions, p + side * (1 + gap / 2) * along)
				append(&pair.normals, Vec3{})
			}
			for i in sphere.indices do append(&pair.indices, base + i)
		}
		area, bounds := mesh_area_bounds(pair, &pool)
		report: Remesh_Report
		defer remesh_report_destroy(&report)
		out, ok := remesh_voxel_measured(pair, area, bounds, 4000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, quads = true}, report = &report)
		defer mesh_destroy(&out)
		testing.expectf(t, ok, "gap %.2f: remesh failed", gap)
		expect_closed_manifold(t, out)
		{
			plain_report: Remesh_Report
			defer remesh_report_destroy(&plain_report)
			plain, plain_ok := remesh_voxel_measured(pair, area, bounds, 4000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT}, report = &plain_report)
			defer mesh_destroy(&plain)
			testing.expectf(t, plain_ok, "gap %.2f: the triangle remesh failed", gap)
			expect_closed_manifold(t, plain)
		}
		if report.quads_thin {
			refused += 1
			testing.expectf(t, report.quads == nil, "gap %.2f: refused, yet quads", gap)
		} else {
			testing.expectf(t, report.quads != nil, "gap %.2f: no quads and no refusal", gap)
			expect_quads_closed_manifold(t, out, report.quads)
		}
		log.infof("two spheres %.2f apart (h %.3f): %s", gap, remesh_spacing(pair, 4000), "quads refused, triangles made" if report.quads_thin else "quads")
	}
	testing.expectf(t, refused == 0, "%d gaps refused their quads", refused)
}

// A mesh whose edges do not pair off is mended before the rays: a doubled triangle (the
// winding behind it two, so a ray through it never comes back out) and one turned against
// its neighbours each remesh as the plain sphere does, the report counting what was mended,
// with Quads too.
@(test)
remesh_mends_a_doubled_or_turned_triangle :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	ball := f32(4 * math.PI / 3)
	for turned in ([2]bool{false, true}) {
		m := icosphere(3)
		defer mesh_destroy(&m)
		if turned {
			m.indices[1], m.indices[2] = m.indices[2], m.indices[1]
		} else {
			append(&m.indices, m.indices[0], m.indices[1], m.indices[2])
		}
		testing.expect(t, !mesh_edges_paired(m, &pool), "the fixture's edges should not pair")
		area, bounds := mesh_area_bounds(m, &pool)
		for quads in ([2]bool{false, true}) {
			report: Remesh_Report
			defer remesh_report_destroy(&report)
			out, ok := remesh_voxel_measured(m, area, bounds, 4000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, quads = quads}, report = &report)
			defer mesh_destroy(&out)
			testing.expectf(t, ok, "turned %v quads %v: remesh failed", turned, quads)
			testing.expectf(t, report.mended == 1 && report.holes_closed == 0, "turned %v quads %v: %d mended, %d holes closed", turned, quads, report.mended, report.holes_closed)
			expect_closed_manifold(t, out)
			if quads do expect_quads_closed_manifold(t, out, report.quads)
			h := remesh_spacing(m, 4000)
			worst: f32
			for p in out.positions do worst = max(worst, abs(linalg.length(p) - 1))
			testing.expectf(t, worst < 0.6 * h, "turned %v quads %v: a vertex is %v off the sphere, h = %v", turned, quads, worst, h)
			v := remesh_volume(out)
			testing.expectf(t, v > 0.95 * ball && v < 1.02 * ball, "turned %v quads %v: volume %.3f of %.3f", turned, quads, v, ball)
		}
	}
}

// A sculpt symmetric across x = 0.21, remeshed with that plane given, comes out its own
// mirror image: every vertex's mirror is a vertex, triangles and quads alike. Without the
// plane the lattice's points fall where the box puts them and the halves differ, which is
// what a remesh with symmetry on showed.
@(test)
remesh_with_a_mirror_stays_symmetric :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	shape := icosphere(4)
	defer mesh_destroy(&shape)
	CENTER :: f32(0.21)
	// Squashed, bent and moved off the origin, but still the same either side of the plane.
	for &p in shape.positions do p = {p.x * 1.37 + CENTER, p.y + 0.3 * p.x * p.x, p.z * 0.8}
	mesh_recompute_normals(&shape)
	// The farthest any vertex's mirror image is from the nearest vertex, in cells.
	asymmetry :: proc(out: Mesh, h: f32) -> f32 {
		worst: f32
		for p in out.positions {
			image := Vec3{2 * CENTER - p.x, p.y, p.z}
			nearest := max(f32)
			for q in out.positions do nearest = min(nearest, linalg.length2(q - image))
			worst = max(worst, math.sqrt(nearest))
		}
		return worst / h
	}
	area, bounds := mesh_area_bounds(shape, &pool)
	for quads in ([2]bool{false, true}) {
		mirror := Remesh_Mirror{axes = {true, false, false}, center = {CENTER, 0, 0}}
		h, _, _ := remesh_lattice(area, bounds, 2000, mirror)
		report: Remesh_Report
		defer remesh_report_destroy(&report)
		out, ok := remesh_voxel_measured(shape, area, bounds, 2000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, quads = quads, mirror = mirror}, report = &report)
		defer mesh_destroy(&out)
		if !testing.expectf(t, ok, "quads %v: remesh failed", quads) do continue
		expect_closed_manifold(t, out)
		testing.expectf(t, asymmetry(out, h) < 1e-3, "quads %v: a vertex's mirror is %.4f cells from any vertex", quads, asymmetry(out, h))

		plain_report: Remesh_Report
		defer remesh_report_destroy(&plain_report)
		plain, plain_ok := remesh_voxel_measured(shape, area, bounds, 2000, &pool, options = {smooth = REMESH_SMOOTH_DEFAULT, quads = quads}, report = &plain_report)
		defer mesh_destroy(&plain)
		testing.expect(t, plain_ok)
		testing.expectf(t, asymmetry(plain, h) > 0.05, "quads %v: without the plane the halves already match (%.4f cells)", quads, asymmetry(plain, h))
	}
}
