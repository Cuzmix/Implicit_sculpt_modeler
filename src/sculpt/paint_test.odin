package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
paint_sphere :: proc(s: ^Sculptor, m: ^geom.Mesh, subdiv: int, pool: ^jobs.Pool) {
	m^ = geom.icosphere(subdiv)
	sculptor_init(s, m, pool, 64)
}

@(private = "file")
UP :: Vec3{0, 0, 1}

// A Paint dab colours what lies inside its radius toward the brush colour, moves
// nothing, and its stroke undoes and redoes as one step.
@(test)
paint_colours_inside_the_radius_and_undoes :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	paint_sphere(&s, &m, 4, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	before := slice.clone(m.positions[:], context.temp_allocator)
	sculptor_stroke_begin(&s)
	painted := apply_dab(&s, {kind = .Paint, radius = 0.3, strength = 1, color = {200, 20, 10}}, UP)
	testing.expect(t, sculptor_stroke_end(&s), "the stroke was not a step")
	testing.expect(t, painted > 0, "nothing was painted")
	testing.expect(t, slice.equal(m.positions[:], before), "painting moved vertices")
	for p, v in m.positions {
		c := s.color[v]
		if linalg.length(p - UP) >= 0.3 {
			testing.expectf(t, c == {}, "vertex %d outside the radius is painted %v", v, c)
		} else if linalg.length(p - UP) < 0.05 {
			testing.expectf(t, c == {200, 20, 10, 255}, "vertex %d at the middle is %v", v, c)
		}
	}
	after := slice.clone(s.color, context.temp_allocator)
	testing.expect(t, sculptor_undo(&s))
	for c in s.color do testing.expect(t, c == {}, "undo left paint")
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, slice.equal(s.color, after), "redo did not bring the paint back")
	// The inverted brush takes coverage off and keeps the colour.
	_ = apply_dab(&s, {kind = .Paint, radius = 0.3, strength = 1, invert = true}, UP)
	for c, v in s.color {
		if linalg.length(m.positions[v] - UP) < 0.05 do testing.expectf(t, c.a == 0 && c.r == 200, "erased middle is %v", c)
	}
}

// Fill paints every vertex except the masked ones, as one undo step.
@(test)
paint_fill_skips_the_mask :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	paint_sphere(&s, &m, 3, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	mask_ensure(&s)
	for p, v in m.positions do if p.z > 0.5 do s.mask[v] = 255
	testing.expect(t, sculptor_paint_command(&s, .Fill, {1, 2, 3}))
	for p, v in m.positions {
		want := Color{} if p.z > 0.5 else Color{1, 2, 3, 255}
		testing.expectf(t, s.color[v] == want, "vertex at z %v is %v", p.z, s.color[v])
	}
	testing.expect(t, sculptor_undo(&s))
	for c in s.color do testing.expect(t, c == {})
}

// Painting in parallel gives the same colours, bit for bit, as on one thread.
@(test)
paint_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	result: [2][]Color
	for p, i in ([2]^jobs.Pool{nil, &pool}) {
		m: geom.Mesh
		s: Sculptor
		paint_sphere(&s, &m, 5, p)
		for k in 0 ..< 20 {
			center := linalg.normalize(Vec3{f32(k) * 0.05 - 0.5, 0.2, 1})
			_ = apply_dab(&s, {kind = .Paint, radius = 0.4, strength = 0.3, color = {u8(k * 10), 90, 200}}, center)
		}
		result[i] = slice.clone(s.color, context.temp_allocator)
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
	testing.expect(t, slice.equal(result[0], result[1]), "parallel painting differs from serial")
}

// Grouping what is shown makes one new group of it; creases split a cube into its six
// faces; and nearly every triangle is drawn from a corner carrying its own group.
@(test)
groups_from_visible_and_creases :: proc(t: ^testing.T) {
	m, ok := geom.primitive(.Cube, 5000, nil)
	testing.expect(t, ok)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	sculptor_recompute_all(&s)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	testing.expect(t, sculptor_group_command(&s, .Creases))
	seen := make(map[u16]int, 8, context.temp_allocator)
	for g in s.groups.tris do seen[g] += 1
	testing.expect_value(t, len(seen), 6)
	expect_drawn_groups(t, &s)
	testing.expect(t, sculptor_undo(&s))
	for g in s.groups.tris do testing.expect_value(t, g, 0)
	testing.expect(t, sculptor_redo(&s))

	// Hide the +x half, then group what is shown: one new group past the six.
	hidden := 0
	hide_x(&s)
	testing.expect(t, sculptor_group_command(&s, .Visible))
	for g, tri in s.groups.tris {
		if s.hide.tris[tri] {
			hidden += 1
			testing.expect(t, g < 6, "a hidden triangle changed group")
		} else {
			testing.expect_value(t, g, 6)
		}
	}
	testing.expect(t, hidden > 0)
	expect_drawn_groups(t, &s)
}

// Hides the triangles of `s` whose middle has x > 0.
@(private = "file")
hide_x :: proc(s: ^Sculptor) {
	clip: matrix[4, 4]f32
	clip[0, 0], clip[1, 1], clip[2, 2], clip[3, 3] = 1, 1, 0.1, 1
	_ = sculptor_hide_shape(s, clip, {{0, -10}, {10, -10}, {10, 10}, {0, 10}}, .Hide)
}

// Every triangle's lead corner carries its group, but for at most one in a thousand.
@(private = "file")
expect_drawn_groups :: proc(t: ^testing.T, s: ^Sculptor, loc := #caller_location) {
	wrong := 0
	tcount := len(s.groups.tris)
	for tri in 0 ..< tcount {
		c := drawn_triangle(s, tri)
		if s.groups.vertex[c[0]] != s.groups.tris[tri] do wrong += 1
		// Turned, never flipped: the same corners in the same cyclic order.
		i := s.mesh.indices[3 * tri:][:3]
		k := int(s.groups.lead[tri])
		testing.expect(t, c == [3]u32{i[k], i[(k + 1) % 3], i[(k + 2) % 3]}, loc = loc)
	}
	testing.expectf(t, wrong * 1000 <= tcount, "%d of %d triangles show another group", wrong, tcount, loc = loc)
}

// A Ctrl + Shift click on a group shows only it, a second one shows everything but it;
// masking a group masks exactly its corners.
@(test)
groups_isolate_and_mask :: proc(t: ^testing.T) {
	m, ok := geom.primitive(.Cube, 3000, nil)
	testing.expect(t, ok)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	sculptor_recompute_all(&s)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	testing.expect(t, sculptor_group_command(&s, .Creases))
	g := s.groups.tris[0]
	testing.expect(t, sculptor_hide_group(&s, g))
	for x, tri in s.groups.tris do testing.expect_value(t, s.hide.tris[tri], x != g)
	testing.expect(t, sculptor_hide_group(&s, g))
	for x, tri in s.groups.tris do testing.expect_value(t, s.hide.tris[tri], x == g)
	testing.expect(t, sculptor_hide_command(&s, .Show_All))
	testing.expect(t, sculptor_mask_group(&s, g))
	in_group := make([]bool, len(m.positions), context.temp_allocator)
	for x, tri in s.groups.tris do if x == g do for k in 0 ..< 3 do in_group[m.indices[3 * tri + k]] = true
	for k, v in s.mask do testing.expect_value(t, k, 255 if in_group[v] else 0)
}

// Colours and groups painted on the top level reach a new level and the levels below,
// and a look at a coarser level and back leaves the top level's own as they were.
@(test)
paint_follows_levels :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	top := &levels_current(&l).sculptor
	_ = apply_dab(top, {kind = .Paint, radius = 0.5, strength = 1, color = {9, 99, 199}}, UP)
	mask_ensure(top)
	for p, v in top.mesh.positions do if p.z > 0.3 do top.mask[v] = 255
	testing.expect(t, sculptor_group_command(top, .Masked))
	_ = sculptor_mask_command(top, .Clear)
	top_colors := slice.clone(top.color, context.temp_allocator)
	top_groups := slice.clone(top.groups.tris, context.temp_allocator)

	levels_set_current(&l, 0)
	base := &levels_current(&l).sculptor
	testing.expect(t, base.color != nil && base.groups.tris != nil, "the base level got nothing")
	painted, grouped := 0, 0
	for c in base.color do painted += int(c.a > 0)
	for g in base.groups.tris do grouped += int(g != 0)
	testing.expect(t, painted > 0 && grouped > 0, "the base level got no paint or groups")

	levels_set_current(&l, 1)
	top = &levels_current(&l).sculptor
	testing.expect(t, slice.equal(top.color, top_colors), "the top level's paint changed on a look below")
	testing.expect(t, slice.equal(top.groups.tris, top_groups), "the top level's groups changed on a look below")

	// A new level takes them from the one below.
	testing.expect(t, levels_subdivide(&l))
	fine := &levels_current(&l).sculptor
	painted, grouped = 0, 0
	for c in fine.color do painted += int(c.a > 0 && c.b > c.r)
	for g in fine.groups.tris do grouped += int(g != 0)
	testing.expect(t, painted > 0 && grouped > 0, "the new level got no paint or groups")
	expect_drawn_groups(t, fine)
}

// Colours and groups on a level above the base come back from the scene file as they
// were, vertex for vertex and triangle for triangle (matched by position).
@(test)
paint_and_groups_round_trip_the_file :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	s := &levels_current(&l).sculptor
	_ = apply_dab(s, {kind = .Paint, radius = 0.6, strength = 0.7, color = {250, 120, 3}}, UP)
	testing.expect(t, sculptor_group_command(s, .Creases, 5))
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	b := &levels_current(&back).sculptor
	testing.expect(t, b.color != nil && b.groups.tris != nil, "paint or groups were lost")
	if b.color == nil || b.groups.tris == nil do return
	at := make(map[Vec3]int, len(s.mesh.positions), context.temp_allocator)
	for p, v in s.mesh.positions do at[p] = v
	for p, v in b.mesh.positions do testing.expect(t, b.color[v] == s.color[at[p]])
	tri_at := make(map[[3]Vec3]int, len(s.groups.tris), context.temp_allocator)
	key :: proc(m: ^geom.Mesh, tri: int) -> [3]Vec3 {
		k := [3]Vec3{m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]}
		// Turned so the lowest x leads, since the file need not keep the first corner.
		for k[0].x > k[1].x || k[0].x > k[2].x do k = {k[1], k[2], k[0]}
		return k
	}
	for _, tri in s.groups.tris do tri_at[key(s.mesh, tri)] = tri
	for g, tri in b.groups.tris {
		other, found := tri_at[key(b.mesh, tri)]
		testing.expect(t, found && s.groups.tris[other] == g)
	}
}

// Levels made from a mesh take its colours per vertex and groups per triangle through
// the renumbering levels_init reports: each triangle keeps the corners and group it had.
@(test)
levels_take_the_surface_of_the_mesh_they_are_made_from :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	source := geom.Mesh{positions = slice.clone_to_dynamic(m.positions[:]), indices = slice.clone_to_dynamic(m.indices[:])}
	defer geom.mesh_destroy(&source)
	tcount := len(m.indices) / 3
	color := make([]Color, len(m.positions))
	defer delete(color)
	for &c, v in color do c = {u8(v), u8(v >> 8), 7, 255}
	groups := make([]u16, tcount)
	defer delete(groups)
	for &g, tri in groups do g = u16(tri % 5)
	old_to_new := make([]u32, len(m.positions))
	defer delete(old_to_new)
	tri_from := make([]u32, tcount)
	defer delete(tri_from)
	l: Levels
	levels_init(&l, m, nil, 64, old_to_new = old_to_new, tri_from = tri_from)
	defer levels_destroy(&l)
	levels_take_surface(&l, color, groups, old_to_new, tri_from)
	s := &l.levels[0].sculptor
	for old, tri in tri_from {
		for c in 0 ..< 3 do testing.expect_value(t, s.mesh.indices[3 * tri + c], old_to_new[source.indices[3 * int(old) + c]])
		testing.expect_value(t, s.groups.tris[tri], groups[old])
	}
	for c, old in color do testing.expect_value(t, s.color[old_to_new[old]], c)
	testing.expect(t, s.color_edited && s.groups.edited)
}
