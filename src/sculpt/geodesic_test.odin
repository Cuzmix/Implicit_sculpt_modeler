package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A flat U in the z = 0 plane: the unit square in a grid of 0.02 with a slot 0.1 wide cut
// from the top down to y = 0.2, so its two prongs stand 0.1 apart but join only at the
// bottom. Only the vertices a triangle uses are kept.
@(private = "file")
u_strip :: proc() -> geom.Mesh {
	N :: 51
	H :: f32(0.02)
	at :: proc(x, y: int) -> int {return y * N + x}
	used: [N * N]bool
	tris := make([dynamic][3]int, context.temp_allocator)
	for y in 0 ..< N - 1 {
		for x in 0 ..< N - 1 {
			cx, cy := (f32(x) + 0.5) * H, (f32(y) + 0.5) * H
			if cx > 0.45 && cx < 0.55 && cy > 0.2 do continue
			a, b, c, d := at(x, y), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1)
			append(&tris, [3]int{a, b, c}, [3]int{a, c, d})
			used[a], used[b], used[c], used[d] = true, true, true, true
		}
	}
	m: geom.Mesh
	remap: [N * N]u32
	for i in 0 ..< N * N {
		if !used[i] do continue
		remap[i] = u32(len(m.positions))
		append(&m.positions, Vec3{f32(i % N) * H, f32(i / N) * H, 0})
	}
	for tri in tris do append(&m.indices, remap[tri[0]], remap[tri[1]], remap[tri[2]])
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	return m
}

// Topological Grab pressed near the tip of the U's left prong moves none of the right
// prong a straight 0.1 away (which a plain Grab drags along), and never more than a plain
// Grab does: along the surface no vertex is nearer than in a straight line.
@(test)
grab_topological_keeps_to_the_surface :: proc(t: ^testing.T) {
	grab :: proc(topological: bool) -> []Vec3 {
		m := u_strip()
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, nil, 64)
		defer sculptor_destroy(&s)
		sculptor_stroke_begin(&s)
		_ = sculptor_grab_begin(&s, {kind = .Grab, radius = 0.3, strength = 1, topological = topological}, {0.44, 0.9, 0})
		_ = sculptor_grab_move(&s, {0, 0, 1})
		sculptor_grab_end(&s)
		_ = sculptor_stroke_end(&s)
		return slice.clone(m.positions[:], context.temp_allocator)
	}
	plain, topo := grab(false), grab(true)
	right_plain, right_topo, left_topo, higher: int
	for p, v in topo {
		if p.x > 0.55 && plain[v].z > 0 do right_plain += 1
		if p.x > 0.55 && p.z > 0 do right_topo += 1
		if p.x < 0.45 && p.z > 0 do left_topo += 1
		if p.z > plain[v].z + 1e-6 do higher += 1
	}
	testing.expectf(t, right_plain > 0 && right_topo == 0 && left_topo > 0 && higher == 0, "right prong: plain %d, topological %d; left %d; higher %d", right_plain, right_topo, left_topo, higher)
	// Straight down the prong, the path along the grid's edges is the straight line, so the
	// weight is the falloff's at that distance.
	for p, v in topo {
		if abs(p.x - 0.44) < 1e-4 && abs(p.y - 0.8) < 1e-4 do testing.expectf(t, abs(p.z - plain[v].z) < 1e-5, "0.1 below: %v against %v", p.z, plain[v].z)
	}
}

// Topological Grab gives the same mesh on worker threads as on one, with symmetry.
@(test)
grab_topological_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> []Vec3 {
		m := geom.icosphere(5)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		sculptor_stroke_begin(&s)
		center := linalg.normalize(Vec3{0.3, 0.2, 1})
		_ = sculptor_grab_begin(&s, {kind = .Grab, radius = 0.8, strength = 1, topological = true, symmetry = {.X}}, center)
		_ = sculptor_grab_move(&s, {0.1, 0.2, 0.3})
		sculptor_grab_end(&s)
		_ = sculptor_stroke_end(&s)
		return slice.clone(m.positions[:], context.temp_allocator)
	}
	testing.expect(t, slice.equal(run(nil), run(&pool)), "parallel topological grab differs from serial")
}
