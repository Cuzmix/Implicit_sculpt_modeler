package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// Two icospheres side by side in one mesh, never joined by a triangle, under a sculptor.
@(private = "file")
pair_init :: proc(s: ^Sculptor, m: ^geom.Mesh, pool: ^jobs.Pool = nil) {
	a := geom.icosphere(3)
	defer geom.mesh_destroy(&a)
	n := u32(len(a.positions))
	for p in a.positions do append(&m.positions, p - {1.5, 0, 0})
	for p in a.positions do append(&m.positions, p + {1.5, 0, 0})
	append(&m.indices, ..a.indices[:])
	for i in a.indices do append(&m.indices, i + n)
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(m)
	sculptor_init(s, m, pool, 64)
}

// How many different groups the shown triangles have.
@(private = "file")
group_count :: proc(s: ^Sculptor) -> int {
	seen := make(map[u16]bool, 16, context.temp_allocator)
	for g in s.groups.tris do seen[g] = true
	return len(seen)
}

// Groups by pieces gives each sphere of a pair its own group; Groups by normals splits a
// cube into its six faces, which Merge similar makes one again.
@(test)
groups_by_pieces_normals_and_merge_similar :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	pair_init(&s, &m)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	testing.expect(t, sculptor_group_command(&s, .Pieces))
	testing.expect_value(t, group_count(&s), 2)
	testing.expect(t, !sculptor_group_command(&s, .Pieces), "grouping by pieces again changed something")

	c, ok := geom.primitive(.Cube, 5000, nil)
	testing.expect(t, ok)
	cs: Sculptor
	sculptor_init(&cs, &c, nil, 64)
	defer {sculptor_destroy(&cs); geom.mesh_destroy(&c)}
	testing.expect(t, !sculptor_group_command(&cs, .Merge_Similar), "merged groups there are none of")
	testing.expect(t, sculptor_group_command(&cs, .Normals, 20))
	testing.expect_value(t, group_count(&cs), 6)
	testing.expect(t, sculptor_group_command(&cs, .Merge_Similar))
	testing.expect_value(t, group_count(&cs), 1)
	testing.expect(t, sculptor_undo(&cs))
	testing.expect_value(t, group_count(&cs), 6)
}

// UV groups give a retopologized object a group per chart, on its base level and on the
// level above, where each triangle takes the chart it was cut from.
@(test)
groups_by_uv_charts :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	bvh := geom.bvh_build(source)
	defer geom.bvh_destroy(&bvh)
	q, _, ok := geom.mesh_retopo(source, &bvh, 600, nil)
	if !testing.expect(t, ok) do return
	uv := geom.quad_uv_unwrap(q, 0.01)
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	l: Levels
	levels_init(&l, geom.quad_mesh_triangulate(q), nil, 64, old_to_new)
	defer levels_destroy(&l)
	delete(q.positions)
	testing.expect(t, !levels_group_uv_charts(&l), "grouped by UVs with none")
	for &f in q.quads do for &v in f do v = old_to_new[v]
	levels_set_quads(&l, q.quads)
	levels_set_uvs(&l, uv)
	// Each chart's group holds two triangles a quad, and four times that a level up.
	quads := make([]int, l.faces.uv.charts + 1, context.temp_allocator)
	for c in l.faces.uv.chart do quads[c + 1] += 1
	per_group :: proc(s: ^Sculptor) -> []int {
		n := make([]int, int(max(u16)) + 1, context.temp_allocator)
		for g in s.groups.tris do n[g] += 1
		return n
	}
	testing.expect(t, levels_group_uv_charts(&l))
	s := &levels_current(&l).sculptor
	testing.expect_value(t, group_count(s), l.faces.uv.charts)
	n := per_group(s)
	for q, g in quads do testing.expectf(t, n[g] == 2 * q, "group %d: %d triangles for %d quads", g, n[g], q)
	testing.expect(t, levels_subdivide(&l))
	s = &levels_current(&l).sculptor
	testing.expect(t, sculptor_group_command(s, .Clear))
	// A hidden triangle keeps its group.
	_ = sculptor_hide_shape(s, flat_clip(), {{0, -10}, {10, -10}, {10, 10}, {0, 10}}, .Show_Only)
	kept := -1
	for h, f in s.hide.tris do if h {kept = f; break}
	testing.expect(t, kept >= 0)
	testing.expect(t, levels_group_uv_charts(&l))
	if kept >= 0 do testing.expect_value(t, s.groups.tris[kept], 0)
	n = per_group(s)
	testing.expect(t, sculptor_hide_command(s, .Show_All))
	shown := 0
	for c, g in n do if g > 0 do shown += c
	testing.expect(t, shown > 0 && shown < len(s.groups.tris))
}

// A clip matrix that keeps the mesh's own x and y as normalized device coordinates.
@(private = "file")
flat_clip :: proc() -> (clip: matrix[4, 4]f32) {
	clip[0, 0], clip[1, 1], clip[2, 2], clip[3, 3] = 1, 1, 0.1, 1
	return
}

// Keeps shown only the triangles whose middle lies right of x.
@(private = "file")
show_right_of :: proc(s: ^Sculptor, x: f32) -> bool {
	return sculptor_hide_shape(s, flat_clip(), {{x, -10}, {10, -10}, {10, 10}, {x, 10}}, .Show_Only)
}

@(private = "file")
shown_count :: proc(s: ^Sculptor) -> int {return len(s.mesh.indices) / 3 - s.hide.count}

// Grow shows a ring more and Shrink then takes one off without hiding anything first
// shown; Outer ring keeps only triangles on the edge; none of them change anything, or
// hide everything, with nothing hidden on a closed mesh.
@(test)
hide_grow_shrink_and_outer_ring :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	pair_init(&s, &m)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	testing.expect(t, !sculptor_hide_command(&s, .Grow), "grew with nothing hidden")
	testing.expect(t, !sculptor_hide_command(&s, .Shrink), "shrank a closed mesh with nothing hidden")
	testing.expect(t, !sculptor_hide_command(&s, .Outer_Ring))
	testing.expect(t, sculptor_hide_refused_all(&s), "outer ring of everything was not refused")
	testing.expect(t, show_right_of(&s, 1.5))
	first := slice.clone(s.hide.tris, context.temp_allocator)
	shown := shown_count(&s)
	testing.expect(t, sculptor_hide_command(&s, .Grow))
	grown := shown_count(&s)
	testing.expect(t, grown > shown)
	testing.expect(t, sculptor_hide_command(&s, .Shrink))
	testing.expect(t, shown_count(&s) < grown)
	for h, i in first do if !h do testing.expect(t, !s.hide.tris[i], "shrink hid a triangle first shown")
	testing.expect(t, sculptor_hide_command(&s, .Outer_Ring))
	ring := shown_count(&s)
	testing.expect(t, ring > 0 && ring < shown)
	// Every triangle left touches a hidden one.
	for h, f in s.hide.tris {
		if h do continue
		touches := false
		for k in 0 ..< 3 do for g in faces_of(&s, s.mesh.indices[3 * f + k]) do if s.hide.tris[g] do touches = true
		testing.expect(t, touches, "outer ring kept a triangle off the edge")
	}
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, shown_count(&s) > ring, "undo kept the outer ring")
}

// Grow all shows the whole sphere a part of which shows, and not the other; Grow to
// groups does the same by polygroup; Show masked shows the masked hidden part.
@(test)
hide_grow_all_groups_and_show_masked :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	pair_init(&s, &m)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	right :: proc(s: ^Sculptor, f: int) -> bool {return s.mesh.positions[s.mesh.indices[3 * f]].x > 0}
	testing.expect(t, show_right_of(&s, 2))
	testing.expect(t, !sculptor_hide_command(&s, .Grow_Groups), "grew to groups with none")
	testing.expect(t, sculptor_hide_command(&s, .Grow_All))
	for h, f in s.hide.tris do testing.expect(t, h != right(&s, f), "grow all showed the wrong sphere")
	// Groups by pieces groups what is shown, so with everything shown.
	testing.expect(t, sculptor_hide_command(&s, .Show_All))
	testing.expect(t, sculptor_group_command(&s, .Pieces))
	testing.expect(t, show_right_of(&s, 2))
	testing.expect(t, sculptor_hide_command(&s, .Grow_Groups))
	for h, f in s.hide.tris do testing.expect(t, h != right(&s, f), "grow to groups showed the wrong sphere")
	testing.expect(t, !sculptor_hide_command(&s, .Show_Masked), "showed by a mask there is none of")
	testing.expect(t, show_right_of(&s, 2))
	mask_ensure(&s)
	for p, v in s.mesh.positions do if p.x < 0 do s.mask[v] = 255
	testing.expect(t, sculptor_hide_command(&s, .Show_Masked))
	for h, f in s.hide.tris {
		c := s.mesh.positions[s.mesh.indices[3 * f]]
		if c.x < 0 do testing.expect(t, !h, "a masked triangle stayed hidden")
	}
}

// Shrink, Outer ring and Grow all hide the same triangles in parallel as on one thread.
@(test)
hide_pack_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for command in ([?]Hide_Command{.Shrink, .Outer_Ring, .Grow_All, .Grow}) {
		result: [2][]bool
		for p, i in ([2]^jobs.Pool{nil, &pool}) {
			m: geom.Mesh
			s: Sculptor
			pair_init(&s, &m, p)
			_ = show_right_of(&s, 1.2)
			_ = sculptor_hide_command(&s, command)
			result[i] = slice.clone(s.hide.tris, context.temp_allocator)
			sculptor_destroy(&s)
			geom.mesh_destroy(&m)
		}
		testing.expectf(t, slice.equal(result[0], result[1]), "%v in parallel differs from serial", command)
	}
}
