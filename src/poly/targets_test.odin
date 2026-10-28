package poly

import "core:math"
import "core:slice"
import "core:testing"

import "../geom"

// The edge of the cube between the two given lattice-free corners nearest a and b.
@(private = "file")
edge_near :: proc(m: ^Mesh, a, b: Vec3) -> u32 {
	best := NONE
	best_d := math.INF_F32
	for e in 0 ..< u32(len(m.crease)) {
		x, y := edge_verts(m, e)
		mid := (m.positions[x] + m.positions[y]) / 2
		d := geom.Vec3(mid - (a + b) / 2)
		dd := d.x * d.x + d.y * d.y + d.z * d.z
		if dd < best_d {
			best_d = dd
			best = e
		}
	}
	return best
}

@(test)
a_loop_round_a_cube_closes_and_stops_at_corners :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 4})
	defer mesh_destroy(&m)
	loop := make([dynamic]u32)
	defer delete(loop)
	// An edge in the middle of the +X side, running along Y, two segments from the edges.
	h := f32(math.sqrt(f32(1) / 3))
	e := edge_near(&m, {h, -h / 4, 0}, {h, h / 4, 0})
	closed := edge_loop(&m, e, &loop)
	testing.expect(t, closed)
	testing.expect_value(t, len(loop), 16) // four sides of four edges
	testing.expect_value(t, loop[0], e)
	// No edge twice, and every edge in the loop at x, y or z = 0 plane round the cube.
	sorted := slice.clone(loop[:], context.temp_allocator)
	slice.sort(sorted)
	testing.expect_value(t, len(slice.unique(sorted)), 16)
	// On a plain cube every corner is a pole: the loop is the edge alone.
	c := primitive(.Cube)
	defer mesh_destroy(&c)
	testing.expect(t, !edge_loop(&c, 0, &loop))
	testing.expect_value(t, len(loop), 1)
}

@(test)
rings_and_face_loops_go_across_quads :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 3})
	defer mesh_destroy(&m)
	ring := make([dynamic]u32)
	faces := make([dynamic]u32)
	defer delete(ring)
	defer delete(faces)
	h := f32(math.sqrt(f32(1) / 3))
	side := edge_near(&m, {h, -h / 3, -h / 3}, {h, h / 3, -h / 3})
	testing.expect(t, edge_ring(&m, side, &ring))
	testing.expect_value(t, len(ring), 12) // three across each of four sides
	testing.expect(t, face_loop(&m, side, &faces))
	testing.expect_value(t, len(faces), 12)
	// A cylinder's ring along its side stops at the caps, which are not quads.
	cyl := primitive(.Cylinder, {around = 6, along = 3})
	defer mesh_destroy(&cyl)
	for e in 0 ..< u32(len(cyl.crease)) {
		a, b := edge_verts(&cyl, e)
		if math.abs(cyl.positions[a].y - cyl.positions[b].y) > 0.01 do continue // a ring edge runs round
		if edge_border(&cyl, e) do continue
		closed := edge_ring(&cyl, e, &ring)
		if math.abs(cyl.positions[a].y) < 0.6 {
			testing.expect(t, !closed)
			testing.expect_value(t, len(ring), 4) // the three rows meet four rings, caps excluded
		}
	}
}

@(test)
islands_groups_and_flat_regions :: proc(t: ^testing.T) {
	m := primitive(.Cube, {across = 2})
	defer mesh_destroy(&m)
	out := make([dynamic]u32)
	defer delete(out)
	island(&m, 0, &out)
	testing.expect_value(t, len(out), 24)
	flat_island(&m, 0, 15, &out)
	testing.expect_value(t, len(out), 4) // one side of the cube
	// Three groups of two opposite sides: a group's island is one side, all of it two.
	for f in 0 ..< u32(24) do m.group[f] = u16(f / 8)
	group_island(&m, 0, &out)
	testing.expect_value(t, len(out), 4)
	group_all(&m, 2, &out)
	testing.expect_value(t, len(out), 8)
	testing.expect(t, slice.is_sorted(out[:]))
}

@(test)
a_plane_has_one_border_loop :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 3})
	defer mesh_destroy(&m)
	loop := make([dynamic]u32)
	defer delete(loop)
	for e in 0 ..< u32(len(m.crease)) {
		if !edge_border(&m, e) do continue
		testing.expect(t, edge_loop(&m, e, &loop))
		testing.expect_value(t, len(loop), 12)
		break
	}
}

@(test)
shortest_paths_follow_edges_and_faces :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 4})
	defer mesh_destroy(&m)
	// Opposite corners of the grid: eight edges of length 0.45 whichever staircase.
	corner_a, corner_b := NONE, NONE
	for p, v in m.positions {
		if p.x < -0.89 && p.z < -0.89 do corner_a = u32(v)
		if p.x > 0.89 && p.z > 0.89 do corner_b = u32(v)
	}
	verts := make([dynamic]u32)
	edges := make([dynamic]u32)
	faces := make([dynamic]u32)
	defer delete(verts)
	defer delete(edges)
	defer delete(faces)
	testing.expect(t, shortest_vertex_path(&m, corner_a, corner_b, &verts, &edges))
	testing.expect_value(t, len(edges), 8)
	testing.expect_value(t, verts[0], corner_a)
	testing.expect_value(t, verts[len(verts) - 1], corner_b)
	length: f32
	for e in edges do length += edge_length(&m, e)
	testing.expectf(t, math.abs(length - 3.6) < 1e-4, "length %v", length)
	// The same path twice: ties broken by id, not by chance.
	again := make([dynamic]u32)
	defer delete(again)
	_ = shortest_vertex_path(&m, corner_a, corner_b, &again, &edges)
	testing.expect(t, slice.equal(verts[:], again[:]))
	testing.expect(t, shortest_face_path(&m, 0, 15, &faces))
	testing.expect_value(t, faces[0], u32(0))
	testing.expect_value(t, faces[len(faces) - 1], u32(15))
	testing.expect_value(t, len(faces), 7) // six steps across a 4 by 4 grid
}

@(test)
a_cage_reads_back_as_written :: proc(t: ^testing.T) {
	m := primitive(.Cylinder, {around = 5, along = 2})
	defer mesh_destroy(&m)
	m.crease[3] = INFINITE_SHARP
	m.corner[2] = 1.5
	for f in 0 ..< len(m.group) do m.group[f] = u16(f % 3)
	out := make([dynamic]u8)
	defer delete(out)
	mesh_write(&m, &out)
	r := geom.byte_reader(out[:])
	back, ok := mesh_read(&r)
	defer mesh_destroy(&back)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(back.he_vert[:], m.he_vert[:]))
	testing.expect(t, slice.equal(back.he_next[:], m.he_next[:]))
	testing.expect(t, slice.equal(back.crease[:], m.crease[:]))
	testing.expect(t, slice.equal(back.corner[:], m.corner[:]))
	testing.expect(t, slice.equal(back.group[:], m.group[:]))
	testing.expect(t, slice.equal(back.positions[:], m.positions[:]))
	// Every truncation and a flipped byte in the counts are refused, never asserted on.
	for n in 0 ..< len(out) {
		cut := geom.byte_reader(out[:n])
		bad, bad_ok := mesh_read(&cut)
		testing.expectf(t, !bad_ok, "a cut at %d read", n)
		mesh_destroy(&bad)
	}
	out[10] ~= 0x40
	r2 := geom.byte_reader(out[:])
	bad, bad_ok := mesh_read(&r2)
	mesh_destroy(&bad)
	testing.expect(t, !bad_ok)
}
