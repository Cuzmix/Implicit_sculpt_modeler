package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"
import "../poly"

// A single-level object made from `cage` as Apply to sculpt makes one: the cage cut into
// triangles over its own points, its polygons and creases in the level's numbering. Also
// returns, per cage point, the level's vertex.
@(private = "file")
cc_levels :: proc(cage: ^poly.Mesh, rule: Subdivision_Rule, pool: ^jobs.Pool = nil) -> (l: Levels, vert_of: []u32) {
	mesh := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	tri_face := make([dynamic]u32, context.temp_allocator)
	poly.triangulate(cage, &mesh, &tri_face)
	resize(&mesh.normals, len(mesh.positions))
	vert_of = make([]u32, len(mesh.positions))
	tri_from := make([]u32, len(tri_face), context.temp_allocator)
	levels_init(&l, mesh, pool, 64, vert_of, tri_from)
	p: Polys
	p.first = make([]u32, len(cage.face_he) + 1)
	corners := make([dynamic]u32)
	verts := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< u32(len(cage.face_he)) {
		poly.face_verts(cage, f, &verts)
		for v in verts do append(&corners, vert_of[v])
		p.first[f + 1] = u32(len(corners))
	}
	p.corners = corners[:]
	p.tri_poly = make([]u32, len(tri_from))
	for old, t in tri_from do p.tri_poly[t] = tri_face[old]
	s := cc_sharp(cage, vert_of)
	ok := levels_set_polys(&l, p, s, rule)
	assert(ok)
	return
}

// The cage's creases and corners in the level's numbering, sorted.
@(private = "file")
cc_sharp :: proc(cage: ^poly.Mesh, vert_of: []u32) -> (s: Sharp) {
	Edge :: struct {
		key: u64,
		c:   f32,
	}
	edges := make([dynamic]Edge, context.temp_allocator)
	for c, e in cage.crease {
		if c <= 0 do continue
		a, b := poly.edge_verts(cage, u32(e))
		append(&edges, Edge{sharp_key(vert_of[a], vert_of[b]), c})
	}
	slice.sort_by(edges[:], proc(x, y: Edge) -> bool {return x.key < y.key})
	s.edges, s.edge = make([]u64, len(edges)), make([]f32, len(edges))
	for e, i in edges do s.edges[i], s.edge[i] = e.key, e.c
	Vert :: struct {
		v: u32,
		c: f32,
	}
	verts := make([dynamic]Vert, context.temp_allocator)
	for c, v in cage.corner do if c > 0 do append(&verts, Vert{vert_of[v], c})
	slice.sort_by(verts[:], proc(x, y: Vert) -> bool {return x.v < y.v})
	s.verts, s.vert = make([]u32, len(verts)), make([]f32, len(verts))
	for v, i in verts do s.verts[i], s.vert[i] = v.v, v.c
	return
}

// The level's frames at every point of one Catmull-Clark step of `cage` (vertex, edge and
// face points, given their parents by hand) against poly's own step.
@(private = "file")
expect_cc_frames :: proc(t: ^testing.T, cage: ^poly.Mesh, rule: Subdivision_Rule, loc := #caller_location) {
	l, vert_of := cc_levels(cage, rule)
	defer levels_destroy(&l)
	defer delete(vert_of)
	nv, ne, nf := len(cage.positions), len(cage.crease), len(cage.face_he)
	want := make([]Vec3, nv + ne + nf, context.temp_allocator)
	poly.subdivide_positions(cage, want, rule == .Flat)
	base := level_base(l.levels[0], l.rule)
	worst: f32
	for v in 0 ..< u32(nv) {
		nb := poly.he_tip(cage, cage.vert_he[v])
		f := frame_at(&base, {vert_of[v], vert_of[nb], EVEN, 0})
		worst = max(worst, linalg.length(f.origin - want[v]))
		testing.expect(t, abs(linalg.length(f.n) - 1) < 1e-5, loc = loc)
	}
	for e in 0 ..< u32(ne) {
		a, b := poly.edge_verts(cage, e)
		f := frame_at(&base, {vert_of[a], vert_of[b], cage.he_face[2 * e], cage.he_face[2 * e + 1]})
		worst = max(worst, linalg.length(f.origin - want[nv + int(e)]))
	}
	corners := make([dynamic]u32, context.temp_allocator)
	for face in 0 ..< u32(nf) {
		poly.face_verts(cage, face, &corners)
		f := frame_at(&base, {vert_of[corners[0]], vert_of[corners[2]], FACE, face})
		worst = max(worst, linalg.length(f.origin - want[nv + ne + int(face)]))
		// The face point's normal points out of the face, as the face's own does.
		testing.expect(t, linalg.dot(f.n, poly.face_normal(cage, face)) > 0.9, loc = loc)
	}
	testing.expectf(t, worst < 1e-6, "%v off poly's step", worst, loc = loc)
}

@(test)
catmull_clark_frames_follow_the_rules :: proc(t: ^testing.T) {
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	expect_cc_frames(t, &cube, .Smooth)
	expect_cc_frames(t, &cube, .Flat)
	// A prism with n-gon caps, and semi-sharp, fully sharp and corner creases.
	prism := poly.primitive(.Cylinder, {across = 1, around = 6, along = 2, tube = 3})
	defer poly.mesh_destroy(&prism)
	expect_cc_frames(t, &prism, .Smooth)
	_ = poly.crease_by_angle(&prism, 30)
	expect_cc_frames(t, &prism, .Smooth)
	poly.crease_edges(&prism, {0, 1}, 0.5)
	poly.crease_points(&prism, {3}, 2)
	expect_cc_frames(t, &prism, .Smooth)
}

@(test)
polys_that_do_not_fit_are_refused :: proc(t: ^testing.T) {
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	l, vert_of := cc_levels(&cube, .Smooth)
	defer levels_destroy(&l)
	defer delete(vert_of)
	testing.expect_value(t, l.rule, Subdivision_Rule.Smooth)
	// A triangle list one short.
	bad := Polys{first = slice.clone([]u32{0, 3}), corners = slice.clone([]u32{0, 1, 2}), tri_poly = make([]u32, 1)}
	testing.expect(t, !levels_set_polys(&l, bad, {}, .Smooth))
	testing.expect(t, l.levels[0].polys.first != nil)
}

// Every point of `got` is within `tolerance` of a point of `want`, and they are as many.
@(private = "file")
same_points :: proc(got, want: []Vec3, tolerance: f32) -> (worst: f32, ok: bool) {
	if len(got) != len(want) do return max(f32), false
	for p in got {
		best := max(f32)
		for q in want do best = min(best, linalg.length(p - q))
		worst = max(worst, best)
	}
	return worst, worst <= tolerance
}

// Every vertex above the base is where its parents and detail put it.
@(private = "file")
expect_cc_decoded :: proc(t: ^testing.T, l: ^Levels, loc := #caller_location) {
	for j in 1 ..< len(l.levels) {
		lv, below := l.levels[j], level_base(l.levels[j - 1], l.rule)
		worst: f32
		for p, u in lv.mesh.positions do worst = max(worst, linalg.length(p - frame_point(frame_at(&below, lv.parents[u]), lv.detail[u])))
		testing.expectf(t, worst < 1e-5, "level %d is %v off its decoded positions", j, worst, loc = loc)
	}
}

// Three Catmull-Clark levels of `cage` against poly's three steps: as many points, each
// where poly puts one, triangles twice poly's quads, and every level closed.
@(private = "file")
expect_cc_levels :: proc(t: ^testing.T, cage: ^poly.Mesh, rule: Subdivision_Rule, loc := #caller_location) {
	l, vert_of := cc_levels(cage, rule)
	defer levels_destroy(&l)
	defer delete(vert_of)
	for _ in 0 ..< 3 do testing.expect(t, levels_subdivide(&l), loc = loc)
	s, err := poly.subdivide(cage, 3, rule == .Flat, context.temp_allocator)
	testing.expect_value(t, err, poly.Build_Error.None, loc = loc)
	for j in 1 ..= 3 {
		lv, step := l.levels[j], &s.steps[j - 1]
		worst, ok := same_points(lv.mesh.positions[:], step.positions[:], 1e-5)
		testing.expectf(t, ok, "level %d: %d points, poly %d, %v off", j, len(lv.mesh.positions), len(step.positions), worst, loc = loc)
		testing.expect_value(t, len(lv.mesh.indices) / 3, 2 * len(step.face_he), loc = loc)
		r := geom.mesh_check(lv.mesh)
		testing.expectf(t, r.closed && r.degenerate_triangles == 0 && !r.inverted, "level %d: %v", j, r, loc = loc)
		testing.expect_value(t, len(lv.polys.first) - 1, len(step.face_he), loc = loc)
	}
	expect_cc_decoded(t, &l, loc)
}

@(test)
catmull_clark_levels_match_the_cage_smoothing :: proc(t: ^testing.T) {
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	expect_cc_levels(t, &cube, .Smooth)
	expect_cc_levels(t, &cube, .Flat)
	prism := poly.primitive(.Cylinder, {across = 1, around = 5, along = 2, tube = 3})
	defer poly.mesh_destroy(&prism)
	expect_cc_levels(t, &prism, .Smooth)
	// Creases of 2 (sharp for two steps, then rounding), fully sharp ones and a corner.
	_ = poly.crease_by_angle(&prism, 30)
	poly.crease_edges(&prism, {0, 1, 2}, 2)
	poly.crease_points(&prism, {4}, poly.INFINITE_SHARP)
	expect_cc_levels(t, &prism, .Smooth)
	// A cage with triangles among its quads.
	cone := poly.primitive(.Cone)
	defer poly.mesh_destroy(&cone)
	expect_cc_levels(t, &cone, .Smooth)
}

@(test)
catmull_clark_levels_are_the_same_with_threads :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> [][]Vec3 {
		cage := poly.primitive(.Sphere, {across = 3, around = 8, along = 4, tube = 3})
		defer poly.mesh_destroy(&cage)
		_ = poly.crease_by_angle(&cage, 20)
		l, vert_of := cc_levels(&cage, .Smooth, pool)
		defer levels_destroy(&l)
		defer delete(vert_of)
		for _ in 0 ..< 3 do assert(levels_subdivide(&l))
		for i in 0 ..< 6 {
			a := f32(i) * 0.9
			levels_set_current(&l, (i * 2) % 4)
			_ = sculptor_flush(&levels_current(&l).sculptor)
			for k in 0 ..< 3 do _ = apply_dab(&levels_current(&l).sculptor, {kind = .Draw, radius = 0.35, strength = 1}, linalg.normalize(Vec3{math.cos(a + 0.05 * f32(k)), 0.2, math.sin(a)}))
			_ = sculptor_flush(&levels_current(&l).sculptor)
		}
		levels_set_current(&l, 1)
		out := make([][]Vec3, len(l.levels), context.temp_allocator)
		for lv, j in l.levels do out[j] = slice.clone(lv.mesh.positions[:], context.temp_allocator)
		return out
	}
	serial := run(nil)
	parallel := run(&pool)
	for level, j in serial do testing.expectf(t, slice.equal(level, parallel[j]), "level %d differs with threads", j)
}

@(test)
moving_a_quads_far_corner_moves_the_level_above :: proc(t: ^testing.T) {
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	l, vert_of := cc_levels(&cube, .Smooth)
	defer levels_destroy(&l)
	defer delete(vert_of)
	for _ in 0 ..< 2 do assert(levels_subdivide(&l))
	// A dab on the base at one corner, then up: every point above reads the corners of
	// whole quads, so the face points of quads whose far corner moved follow it too.
	levels_set_current(&l, 0)
	_ = sculptor_flush(&levels_current(&l).sculptor)
	corner := l.levels[0].mesh.positions[vert_of[0]]
	_ = apply_dab(&levels_current(&l).sculptor, {kind = .Draw, radius = 0.3, strength = 1}, corner)
	_ = sculptor_flush(&levels_current(&l).sculptor)
	levels_set_current(&l, 2)
	expect_cc_decoded(t, &l)
	// With no detail anywhere, the top is the smoothing of the moved base.
	moved := poly.primitive(.Cube)
	defer poly.mesh_destroy(&moved)
	for v in 0 ..< len(moved.positions) do moved.positions[v] = l.levels[0].mesh.positions[vert_of[v]]
	s, _ := poly.subdivide(&moved, 2, false, context.temp_allocator)
	worst, ok := same_points(l.levels[2].mesh.positions[:], s.steps[1].positions[:], 1e-4)
	testing.expectf(t, ok, "%v off", worst)
}

@(test)
catmull_clark_levels_carry_groups_by_polygon :: proc(t: ^testing.T) {
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	l, vert_of := cc_levels(&cube, .Smooth)
	defer levels_destroy(&l)
	defer delete(vert_of)
	base := &l.levels[0].sculptor
	base.groups.tris = make([]u16, len(base.mesh.indices) / 3, base.history.allocator)
	for f, tri in l.levels[0].polys.tri_poly do base.groups.tris[tri] = u16(f + 1)
	groups_refresh(base)
	for _ in 0 ..< 2 do testing.expect(t, levels_subdivide(&l))
	// Going up, every triangle has the group of the polygon below it was cut from.
	for j in 1 ..= 2 {
		below := &l.levels[j - 1]
		for f, tri in cc_tri_polys(&l, j) {
			want: u16
			for g, u in below^.polys.tri_poly do if g == f do want = below^.sculptor.groups.tris[u]
			testing.expect_value(t, l.levels[j].sculptor.groups.tris[tri], want)
		}
	}
	// Going down, each polygon takes its children's group, all of a face of the cube
	// alike, so the base's six faces come back as they were set.
	top := &l.levels[2].sculptor
	for &g in top.groups.tris do g += 10
	levels_carry_groups(&l, 2, 0)
	for f, tri in l.levels[0].polys.tri_poly do testing.expect_value(t, base.groups.tris[tri], u16(f + 11))
}

@(test)
catmull_clark_levels_carry_layers_up :: proc(t: ^testing.T) {
	// A layer on level 1 of a cube's levels, moved up by Subdivide: set to 0 on the new
	// level it gives what subdividing without it gives, as Loop's carry does.
	two_levels :: proc(cube: ^poly.Mesh, layer: bool) -> (l: Levels, vert_of: []u32) {
		l, vert_of = cc_levels(cube, .Smooth)
		assert(levels_subdivide(&l))
		s := &levels_current(&l).sculptor
		_ = sculptor_layer_add(s)
		sculptor_stroke_begin(s)
		_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, l.levels[0].mesh.positions[vert_of[0]])
		_ = sculptor_stroke_end(s)
		if !layer {
			assert(sculptor_layer_set(s, 0, 0, true))
			_ = sculptor_stroke_end(s)
		}
		return
	}
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	a, a_of := two_levels(&cube, false)
	defer levels_destroy(&a)
	defer delete(a_of)
	testing.expect(t, levels_subdivide(&a))
	want := levels_current(&a).mesh.positions[:]
	l, l_of := two_levels(&cube, true)
	defer levels_destroy(&l)
	defer delete(l_of)
	testing.expect(t, levels_subdivide(&l, carry_layers = true))
	top := &levels_current(&l).sculptor
	testing.expect_value(t, len(top.layers.list), 1)
	moved, _ := same_points(top.mesh.positions[:], want, 0)
	testing.expect(t, sculptor_layer_set(top, 0, 0, true))
	_ = sculptor_stroke_end(top)
	worst, ok := same_points(top.mesh.positions[:], want, 1e-5)
	testing.expectf(t, moved > 1e-4 && ok, "%v off without the layer (%v with it)", worst, moved)
	// The mask carries up too: masked at the base, masked all the way up.
	levels_set_current(&l, 0)
	s := &levels_current(&l).sculptor
	for &m in s.mask do m = 255
	levels_carry_mask(&l, 0, 2)
	for m in l.levels[2].sculptor.mask do testing.expect_value(t, m, 255)
}

// Catmull-Clark levels of a creased prism, sculpted on two levels and left on the top.
@(private = "file")
cc_file_levels :: proc(pool: ^jobs.Pool) -> (l: Levels, vert_of: []u32) {
	prism := poly.primitive(.Cylinder, {across = 1, around = 5, along = 2, tube = 3})
	defer poly.mesh_destroy(&prism)
	_ = poly.crease_by_angle(&prism, 30)
	poly.crease_edges(&prism, {0, 1}, 2)
	poly.crease_points(&prism, {4}, poly.INFINITE_SHARP)
	l, vert_of = cc_levels(&prism, .Smooth, pool)
	for _ in 0 ..< 3 do assert(levels_subdivide(&l))
	s := &levels_current(&l).sculptor
	_ = apply_dab(s, {kind = .Draw, radius = 0.4, strength = 1}, l.levels[0].mesh.positions[vert_of[0]])
	levels_set_current(&l, 1)
	s = &levels_current(&l).sculptor
	_ = apply_dab(s, {kind = .Inflate, radius = 0.5, strength = 1}, l.levels[0].mesh.positions[vert_of[3]])
	levels_set_current(&l, 3)
	for lv in l.levels do _ = sculptor_flush(&lv.sculptor)
	return
}

@(test)
catmull_clark_levels_file_round_trip :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l, vert_of := cc_file_levels(&pool)
	defer levels_destroy(&l)
	defer delete(vert_of)
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	testing.expect_value(t, r.at, len(out))
	testing.expect_value(t, back.rule, Subdivision_Rule.Smooth)
	testing.expect_value(t, len(back.levels), 4)
	// Read with one thread, built by three: every level's points the same, bit for bit,
	// compared in an order of the points alone.
	for j in 0 ..< 4 {
		a := slice.clone(l.levels[j].mesh.positions[:], context.temp_allocator)
		b := slice.clone(back.levels[j].mesh.positions[:], context.temp_allocator)
		less :: proc(x, y: Vec3) -> bool {
			p, q := transmute([3]u32)x, transmute([3]u32)y
			return p[0] < q[0] || (p[0] == q[0] && (p[1] < q[1] || (p[1] == q[1] && p[2] < q[2])))
		}
		slice.sort_by(a, less)
		slice.sort_by(b, less)
		testing.expectf(t, slice.equal(a, b), "level %d differs", j)
		testing.expect_value(t, len(back.levels[j].sharp.edges), len(l.levels[j].sharp.edges))
	}
	// Written again, the same bytes.
	again := make([dynamic]u8)
	defer delete(again)
	levels_write(&back, &again)
	testing.expect(t, slice.equal(out[:], again[:]), "written again, the file differs")
}

@(test)
catmull_clark_levels_file_refuses_damage :: proc(t: ^testing.T) {
	l, vert_of := cc_file_levels(nil)
	defer levels_destroy(&l)
	defer delete(vert_of)
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	for cut := 0; cut < len(out); cut += max(len(out) / 47, 1) {
		back: Levels
		r := geom.byte_reader(out[:cut])
		testing.expectf(t, !levels_read(&back, &r, nil, 64), "a file cut at %d of %d was read", cut, len(out))
		testing.expect(t, len(back.levels) == 0)
	}
	// Every byte of the Catmull-Clark block turned to 0xff in turn: refused or read, never
	// a crash or a leak (the runner checks).
	base := l.levels[0]
	at := 5 * 4 + 8 + len(base.mesh.positions) * size_of(Vec3) + len(base.mesh.indices) * 4
	for k in 0 ..< 200 {
		bad := slice.clone(out[:], context.temp_allocator)
		if at + k * 7 >= len(bad) do break
		bad[at + k * 7] = 0xff
		back: Levels
		r := geom.byte_reader(bad)
		if levels_read(&back, &r, nil, 64) do levels_destroy(&back)
	}
}

@(test)
detail_rides_on_an_edited_base :: proc(t: ^testing.T) {
	// A sculpt on Catmull-Clark levels of a cube; the cage's points moved and levels made
	// again from it take the sculpt's detail, so the top is the moved base's smoothing
	// plus the same detail: with the base unmoved, exactly the sculpt.
	cube := poly.primitive(.Cube)
	defer poly.mesh_destroy(&cube)
	src, src_of := cc_levels(&cube, .Smooth)
	defer levels_destroy(&src)
	defer delete(src_of)
	for _ in 0 ..< 2 do assert(levels_subdivide(&src))
	s := &levels_current(&src).sculptor
	sculptor_stroke_begin(s)
	testing.expect(t, apply_dab(s, {kind = .Draw, radius = 0.3, strength = 1}, s.mesh.positions[0]) > 0)
	_ = sculptor_stroke_end(s)
	_ = sculptor_flush(s)
	// The sync carries part of the dab down to the base: the cage is that base.
	levels_sync(&src)
	for &p, i in cube.positions do p = src.levels[0].mesh.positions[src_of[i]]
	run :: proc(t: ^testing.T, cube: ^poly.Mesh, src: ^Levels, src_of: []u32) -> (dst: Levels, dst_of: []u32) {
		dst, dst_of = cc_levels(cube, .Smooth)
		for _ in 0 ..< 2 do assert(levels_subdivide(&dst))
		base_map := make([]u32, len(dst_of), context.temp_allocator)
		for d, i in dst_of do base_map[d] = src_of[i]
		testing.expect(t, levels_take_detail(&dst, src, base_map))
		return
	}
	same, same_of := run(t, &cube, &src, src_of)
	defer levels_destroy(&same)
	defer delete(same_of)
	worst, ok := same_points(same.levels[2].mesh.positions[:], src.levels[2].mesh.positions[:], 1e-5)
	testing.expectf(t, ok, "the unmoved base gives the sculpt back %v off", worst)
	// Stretched along x: the detail follows, and the top is no longer the plain smoothing.
	for &p in cube.positions do p.x *= 1.5
	moved, moved_of := run(t, &cube, &src, src_of)
	defer levels_destroy(&moved)
	defer delete(moved_of)
	plain, plain_of := cc_levels(&cube, .Smooth)
	defer levels_destroy(&plain)
	defer delete(plain_of)
	for _ in 0 ..< 2 do assert(levels_subdivide(&plain))
	off, _ := same_points(moved.levels[2].mesh.positions[:], plain.levels[2].mesh.positions[:], 0)
	testing.expectf(t, off > 0.01, "the detail did not come across (%v)", off)
	expect_cc_decoded(t, &moved)
	// Levels that do not match (one level fewer) are refused.
	short, short_of := cc_levels(&cube, .Smooth)
	defer levels_destroy(&short)
	defer delete(short_of)
	assert(levels_subdivide(&short))
	testing.expect(t, !levels_take_detail(&short, &src, make([]u32, len(short_of), context.temp_allocator)))
}
