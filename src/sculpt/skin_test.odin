package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sculptor over an icosphere with its normals worked out, for the skin's tests; free
// with skin_sphere_free.
@(private = "file")
Skin_Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

@(private = "file")
skin_sphere_make :: proc(subdiv: int, pool: ^jobs.Pool = nil) -> ^Skin_Sphere {
	sp := new(Skin_Sphere)
	sp.mesh = geom.icosphere(subdiv)
	sculptor_init(&sp.sculptor, &sp.mesh, pool, 64)
	for id in 0 ..< len(sp.sculptor.nodes) do mark_stale(&sp.sculptor, u32(id), .Shape)
	_ = sculptor_flush(&sp.sculptor)
	return sp
}

@(private = "file")
skin_sphere_free :: proc(sp: ^Skin_Sphere) {
	sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	free(sp)
}

// Heights that differ from sample to sample and repeat run to run.
@(private = "file")
skin_bumpy :: proc(sk: ^Skin) {
	x := u32(12345)
	for &h in sk.heights {
		x = x * 1664525 + 1013904223
		h = f16((f32(x >> 8) / f32(1 << 24) - 0.5) * 0.02)
	}
}

@(test)
skin_refuses_odd_segments_and_open_meshes :: proc(t: ^testing.T) {
	sp := skin_sphere_make(1)
	defer skin_sphere_free(sp)
	for bad in ([]u32{0, 1, 3, 6, 32}) {
		sk, ok := skin_make(&sp.sculptor, bad)
		testing.expectf(t, !ok, "%d segments made a skin", bad)
		skin_destroy(&sk)
	}
	open := geom.icosphere(1)
	resize(&open.indices, len(open.indices) - 3)
	defer geom.mesh_destroy(&open)
	s: Sculptor
	sculptor_init(&s, &open, nil, 64)
	defer sculptor_destroy(&s)
	sk, ok := skin_make(&s, 4)
	testing.expect(t, !ok, "a mesh with a hole made a skin")
	skin_destroy(&sk)
}

@(test)
skin_stores_each_sample_once :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	for segments in ([]u32{2, 4, 8, 16}) {
		sk, ok := skin_make(&sp.sculptor, segments)
		testing.expect(t, ok)
		defer skin_destroy(&sk)
		testing.expect_value(t, int(sk.edge_count), len(sp.mesh.indices) / 2)
		uses := make([]int, skin_sample_count(&sk), context.temp_allocator)
		I := sp.mesh.indices[:]
		S := sk.segments
		for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			uses[skin_sample(&sk, I, tri, i, j)] += 1
		}
		// A vertex sample is used by each triangle at the vertex, an edge sample by the
		// edge's two triangles, an inside sample by its own triangle only.
		ok_all := true
		for n, x in uses {
			want := 1
			if x < int(sk.vert_count) {
				want = len(faces_of(&sp.sculptor, u32(x)))
			} else if x < int(sk.vert_count + sk.edge_count * (S - 1)) {
				want = 2
			}
			if n != want do ok_all = false
		}
		testing.expectf(t, ok_all, "%d segments: a sample is used the wrong number of times", segments)
	}
}

@(test)
skin_is_watertight :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	skin_bumpy(&sk)
	n := skin_sample_count(&sk)
	first := make([]Vec3, n, context.temp_allocator)
	seen := make([]bool, n, context.temp_allocator)
	I := sp.mesh.indices[:]
	mismatches := 0
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= sk.segments do for i in u32(0) ..= sk.segments - j {
		x := skin_sample(&sk, I, tri, i, j)
		p := skin_point(&sp.sculptor, &sk, tri, i, j)
		if !seen[x] {
			seen[x] = true
			first[x] = p
		} else if p != first[x] {
			mismatches += 1
		}
	}
	// Every triangle must reach a shared sample's point to the bit, or a crack shows.
	testing.expect_value(t, mismatches, 0)
}

@(test)
flat_skin_normals_are_the_mesh_normals :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 4)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	I := sp.mesh.indices[:]
	worst: f32 = 1
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= sk.segments do for i in u32(0) ..= sk.segments - j {
		_, want := skin_base(&sp.sculptor, &sk, tri, i, j)
		got := geom.oct_decode(sk.normals[skin_sample(&sk, I, tri, i, j)])
		worst = min(worst, linalg.dot(got, linalg.normalize(want)))
	}
	// Within what two 16-bit octahedral halves hold.
	testing.expectf(t, worst > 0.99999, "worst cosine %v", worst)
}

@(test)
even_skin_keeps_the_mesh_normals :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	// A skin raised by the same height everywhere is a bigger copy of the surface, so it
	// shades as the mesh does (to within the curve's change over one small triangle).
	for &h in sk.heights do h = 0.05
	skin_normals_all(&sp.sculptor, &sk)
	I := sp.mesh.indices[:]
	worst: f32 = 1
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= sk.segments do for i in u32(0) ..= sk.segments - j {
		_, want := skin_base(&sp.sculptor, &sk, tri, i, j)
		got := geom.oct_decode(sk.normals[skin_sample(&sk, I, tri, i, j)])
		worst = min(worst, linalg.dot(got, linalg.normalize(want)))
	}
	testing.expectf(t, worst > 0.999, "worst cosine %v", worst)
}

@(test)
skin_normals_lean_away_from_a_bump :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 4)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	I := sp.mesh.indices[:]
	v := I[0]
	sk.heights[v] = 0.02
	skin_normals_all(&sp.sculptor, &sk)
	// The samples one step from the raised vertex, on each triangle at it, lean away from it.
	bump := sp.mesh.positions[v]
	checked := 0
	for f in faces_of(&sp.sculptor, v) {
		c := skin_corner_of(I, f, v)
		i, j := skin_edge_place(sk.segments, c, 1)
		p, base := skin_base(&sp.sculptor, &sk, f, i, j)
		got := geom.oct_decode(sk.normals[skin_sample(&sk, I, f, i, j)])
		away := linalg.normalize(p - bump)
		testing.expectf(t, linalg.dot(got, away) > linalg.dot(linalg.normalize(base), away) + 0.01, "triangle %d does not lean away", f)
		checked += 1
	}
	testing.expect(t, checked >= 5)
}

@(test)
skin_normals_match_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial := skin_sphere_make(3)
	defer skin_sphere_free(serial)
	parallel := skin_sphere_make(3, &pool)
	defer skin_sphere_free(parallel)
	a, ok_a := skin_make(&serial.sculptor, 8)
	b, ok_b := skin_make(&parallel.sculptor, 8)
	testing.expect(t, ok_a && ok_b)
	defer skin_destroy(&a)
	defer skin_destroy(&b)
	skin_bumpy(&a)
	skin_bumpy(&b)
	skin_normals_all(&serial.sculptor, &a)
	skin_normals_all(&parallel.sculptor, &b)
	same := len(a.normals) == len(b.normals)
	for n, x in a.normals do if n != b.normals[x] do same = false
	for e, x in a.edges do if e != b.edges[x] do same = false
	testing.expect(t, same, "the parallel skin differs from the serial one")
}

// A sphere with a skin of `segments`, for the dab tests; free with skin_sphere_free.
@(private = "file")
skin_sphere_with :: proc(subdiv: int, segments: u32, pool: ^jobs.Pool = nil) -> ^Skin_Sphere {
	sp := skin_sphere_make(subdiv, pool)
	ok := sculptor_skin_set(&sp.sculptor, segments)
	assert(ok)
	return sp
}

@(private = "file")
SKIN_TOP :: Vec3{0, 0, 1}

@(test)
skin_draw_raises_heights_and_leaves_vertices :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	before := slice.clone(sp.mesh.positions[:], context.temp_allocator)
	changed := apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.3, strength = 1, skin = true}, SKIN_TOP)
	testing.expect(t, changed > 0, "the dab changed no sample")
	testing.expect(t, slice.equal(sp.mesh.positions[:], before), "a skin dab moved a vertex")
	raised := 0
	sk := sp.sculptor.skin
	for h in sk.heights do if h > 0 do raised += 1
	testing.expect_value(t, raised, changed)
	// The flush uploads samples and no vertices, and still reports where to redraw.
	vertex_ranges := sculptor_flush(&sp.sculptor)
	testing.expect_value(t, len(vertex_ranges), 0)
	testing.expect(t, len(sculptor_skin_ranges(&sp.sculptor)) > 0, "no sample range to upload")
	testing.expect(t, sp.sculptor.changed_bounds.lo.x <= sp.sculptor.changed_bounds.hi.x, "no box to redraw")
}

// A flush recomputes exactly the normals that went stale: after dabs of every skin kind,
// they equal a skin whose normals were all worked out afresh.
// After small dabs, a flush recomputes only the normals near them, and the ranges it lists
// for the GPU hold every normal that changed, while staying a small part of the skin.
@(test)
skin_flush_uploads_only_near_the_dabs :: proc(t: ^testing.T) {
	sp := skin_sphere_with(3, 8)
	defer skin_sphere_free(sp)
	sk := sp.sculptor.skin
	for kind in SKIN_KINDS {
		before := slice.clone(sk.normals, context.temp_allocator)
		_ = apply_dab(&sp.sculptor, {kind = kind, radius = 0.08, strength = 0.8, skin = true}, linalg.normalize(Vec3{0.2, 0.1, 1}))
		_ = sculptor_flush(&sp.sculptor)
		listed := make([]bool, len(sk.normals), context.temp_allocator)
		total := 0
		for r in sculptor_skin_ranges(&sp.sculptor) {
			for x in r.first ..< r.first + r.count do listed[x] = true
			total += int(r.count)
		}
		missed := 0
		for n, x in sk.normals do if n != before[x] && !listed[x] do missed += 1
		testing.expectf(t, missed == 0, "%v: %d changed normals not uploaded", kind, missed)
		testing.expectf(t, total > 0 && total < len(sk.normals) / 4, "%v: uploaded %d of %d", kind, total, len(sk.normals))
	}
	live := slice.clone(sk.normals, context.temp_allocator)
	skin_normals_all(&sp.sculptor, sk)
	testing.expect(t, slice.equal(live, sk.normals), "a flush left a stale normal")
}

@(test)
skin_flush_keeps_every_normal_current :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	sk := sp.sculptor.skin
	for kind in SKIN_KINDS {
		_ = apply_dab(&sp.sculptor, {kind = kind, radius = 0.4, strength = 0.8, skin = true}, linalg.normalize(Vec3{0.2, 0.1, 1}))
		_ = sculptor_flush(&sp.sculptor)
	}
	// A vertex move under the skin goes stale too.
	_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.5, strength = 1}, SKIN_TOP)
	_ = sculptor_flush(&sp.sculptor)
	live := slice.clone(sk.normals, context.temp_allocator)
	skin_normals_all(&sp.sculptor, sk)
	testing.expect(t, slice.equal(live, sk.normals), "a flush left a stale normal")
}

// The grid pass that gives a triangle's normals in one go (skin_grid_pass) gives every
// sample the bits skin_normal gives it alone, inside samples and border ones.
@(test)
skin_grid_pass_matches_each_normal :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 8)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	sk := s.skin
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1, skin = true}, linalg.normalize(Vec3{0.2, 0.1, 1}))
	_ = apply_dab(s, {kind = .Crease, radius = 0.3, strength = 0.8, skin = true}, linalg.normalize(Vec3{-0.1, 0.2, 1}))
	_ = sculptor_flush(s)
	I := s.mesh.indices[:]
	S := sk.segments
	wrong := 0
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		if sk.normals[skin_sample(sk, I, tri, i, j)] != geom.oct_encode(skin_normal(s, sk, tri, i, j)) do wrong += 1
	}
	testing.expectf(t, wrong == 0, "%d samples differ from skin_normal", wrong)
}

@(test)
skin_dabs_match_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for kind in SKIN_KINDS {
		a := skin_sphere_with(3, 8)
		b := skin_sphere_with(3, 8, &pool)
		defer skin_sphere_free(a)
		defer skin_sphere_free(b)
		for sp in ([2]^Skin_Sphere{a, b}) {
			sculptor_stroke_begin(&sp.sculptor)
			for k in 0 ..< 6 {
				at := linalg.normalize(Vec3{0.1 * f32(k), 0.05, 1})
				_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.3, strength = 1, skin = true}, at)
				_ = apply_dab(&sp.sculptor, {kind = kind, radius = 0.4, strength = 0.7, skin = true, symmetry = {.X}}, at)
				_ = sculptor_flush(&sp.sculptor)
			}
			_ = sculptor_stroke_end(&sp.sculptor)
		}
		same := slice.equal(a.sculptor.skin.heights, b.sculptor.skin.heights) && slice.equal(a.sculptor.skin.normals, b.sculptor.skin.normals)
		testing.expectf(t, same, "%v: the parallel skin differs from the serial one", kind)
	}
}

@(test)
skin_undo_restores_heights :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	sk := sp.sculptor.skin
	flat := slice.clone(sk.normals, context.temp_allocator)
	sculptor_stroke_begin(&sp.sculptor)
	for k in 0 ..< 4 do _ = apply_dab(&sp.sculptor, {kind = .Clay, radius = 0.35, strength = 1, skin = true}, linalg.normalize(Vec3{0.1 * f32(k), 0, 1}))
	_ = sculptor_stroke_end(&sp.sculptor)
	_ = sculptor_flush(&sp.sculptor)
	heights := slice.clone(sk.heights, context.temp_allocator)
	normals := slice.clone(sk.normals, context.temp_allocator)
	testing.expect(t, sculptor_undo(&sp.sculptor))
	_ = sculptor_flush(&sp.sculptor)
	for h in sk.heights do if h != 0 {
		testing.expect(t, false, "undo left a height")
		break
	}
	testing.expect(t, slice.equal(sk.normals, flat), "undo left a normal")
	testing.expect(t, sculptor_redo(&sp.sculptor))
	_ = sculptor_flush(&sp.sculptor)
	testing.expect(t, slice.equal(sk.heights, heights) && slice.equal(sk.normals, normals), "redo differs from the stroke")
}

// With mirror symmetry, every raised sample has a twin across the plane raised the same.
@(test)
skin_symmetric_dabs_mirror :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	sk := sp.sculptor.skin
	_ = apply_dab(&sp.sculptor, {kind = .Inflate, radius = 0.5, strength = 1, skin = true, symmetry = {.X}}, linalg.normalize(Vec3{0.5, 0.2, 1}))
	I := sp.mesh.indices[:]
	S := sk.segments
	Sample :: struct {
		p: Vec3,
		h: f32,
	}
	samples := make([dynamic]Sample, 0, len(sk.heights), context.temp_allocator)
	seen := make([]bool, len(sk.heights), context.temp_allocator)
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		x := skin_sample(sk, I, tri, i, j)
		if seen[x] do continue
		seen[x] = true
		p, _ := skin_base(&sp.sculptor, sk, tri, i, j)
		append(&samples, Sample{p, f32(sk.heights[x])})
	}
	worst: f32
	raised := 0
	for a in samples {
		if a.h == 0 do continue
		raised += 1
		mirror := Vec3{-a.p.x, a.p.y, a.p.z}
		best := max(f32)
		h: f32
		for b in samples {
			if d := linalg.length(b.p - mirror); d < best do best, h = d, b.h
		}
		if best < 1e-4 do worst = max(worst, abs(h - a.h))
	}
	testing.expect(t, raised > 0)
	testing.expectf(t, worst < 1e-3, "a mirrored sample differs by %v", worst)
}

// The records the renderer draws the skin by hold each triangle's edges and the corner it
// is drawn from, and turning the drawn corners back by that lead gives the mesh's corners,
// as skin.frag.slang does to find the samples.
@(test)
skin_tris_turn_back_to_the_mesh_corners :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	testing.expect(t, sculptor_skin_set(s, 4))
	tcount := len(sp.mesh.indices) / 3
	// Three groups in stripes, so many triangles start from a corner other than their first.
	s.groups.tris = make([]u16, tcount, s.history.allocator)
	for &g, i in s.groups.tris do g = u16(i % 3)
	groups_refresh(s)
	tris := sculptor_skin_tris(s, context.temp_allocator)
	testing.expect_value(t, len(tris), tcount)
	turned := 0
	for rec, f in tris {
		testing.expect(t, rec.xyz == s.skin.tri_edges[f])
		testing.expect_value(t, rec.w, u32(s.groups.lead[f]))
		if rec.w != 0 do turned += 1
		drawn := drawn_triangle(s, f)
		for c in 0 ..< u32(3) {
			testing.expect_value(t, drawn[(c + 3 - rec.w) % 3], sp.mesh.indices[3 * u32(f) + c])
		}
	}
	testing.expect(t, turned > 0)
}

// Adding, replacing and taking off the skin are undo steps, and the heights strokes left
// on a skin come back with it, normals and all, even after the mesh moved in between.
@(test)
skin_change_is_undone_with_its_heights :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	testing.expect(t, sculptor_skin_change(s, 4))
	testing.expect(t, !sculptor_skin_change(s, 4), "the same segments made a step")
	testing.expect(t, !sculptor_skin_change(s, 3), "odd segments made a step")
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Draw, radius = 0.4, strength = 1, skin = true}, Vec3{0, 0, 1})
	_ = sculptor_stroke_end(s)
	_ = sculptor_flush(s)
	heights := slice.clone(s.skin.heights, context.temp_allocator)
	normals := slice.clone(s.skin.normals, context.temp_allocator)
	stamp := sculptor_skin_stamp(s)
	testing.expect(t, sculptor_skin_change(s, 8))
	testing.expect_value(t, s.skin.segments, u32(8))
	testing.expect(t, sculptor_skin_stamp(s) != stamp)
	// A mesh stroke on the 8-segment skin's watch, undone before the skin goes back.
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Inflate, radius = 0.4, strength = 1}, Vec3{0, 0, 1})
	_ = sculptor_stroke_end(s)
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, sculptor_undo(s))
	_ = sculptor_flush(s)
	testing.expect_value(t, s.skin.segments, u32(4))
	testing.expect(t, slice.equal(s.skin.heights, heights), "the heights did not come back")
	testing.expect(t, slice.equal(s.skin.normals, normals), "the normals did not come back")
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, s.skin == nil, "undoing the first change left a skin")
	testing.expect(t, sculptor_redo(s))
	testing.expect(t, s.skin != nil && s.skin.segments == 4)
	testing.expect(t, sculptor_skin_change(s, 0))
	testing.expect(t, s.skin == nil)
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, s.skin != nil && s.skin.segments == 4)
}

// The skin's samples as points with their heights, in an order of the points alone, so
// differently numbered builds of the same skin compare.
@(private = "file")
Placed_Height :: struct {
	p: Vec3,
	h: f16,
}

@(private = "file")
skin_by_place :: proc(s: ^Sculptor) -> []Placed_Height {
	sk := s.skin
	I := s.mesh.indices[:]
	S := sk.segments
	out := make([]Placed_Height, len(sk.heights), context.temp_allocator)
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		x := skin_sample(sk, I, t, i, j)
		p, _ := skin_base(s, sk, t, i, j)
		// The flat point rounded, since triangles meeting at a sample compute it apart.
		out[x] = {{f32(i32(p.x * 1e5)), f32(i32(p.y * 1e5)), f32(i32(p.z * 1e5))}, sk.heights[x]}
	}
	slice.sort_by(out, proc(a, b: Placed_Height) -> bool {
		return a.p.x < b.p.x || (a.p.x == b.p.x && (a.p.y < b.p.y || (a.p.y == b.p.y && (a.p.z < b.p.z || (a.p.z == b.p.z && a.h < b.h)))))
	})
	return out
}

// The skin goes into the scene file after the levels and comes back on the top level of a
// fresh build, every height at its place, whatever numbers the build gives the vertices.
@(test)
skin_file_round_trip_keeps_every_height :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l: Levels
	levels_init(&l, geom.icosphere(1), &pool, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	top := &l.levels[1].sculptor
	testing.expect(t, sculptor_skin_set(top, 4))
	skin_bumpy(top.skin)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))
	testing.expect(t, levels_skin_write(&l, &out))
	want := skin_by_place(top)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, &pool, 64), "levels read failed")
	defer levels_destroy(&back)
	testing.expect(t, levels_skin_follows(&r))
	testing.expect(t, levels_skin_read(&back, &r), "skin read failed")
	testing.expect_value(t, r.at, len(out))
	sk := levels_skin(&back)
	testing.expect(t, sk != nil && sk.segments == 4)
	if sk == nil do return
	got := skin_by_place(&back.levels[1].sculptor)
	testing.expect(t, slice.equal(got, want), "the heights moved")
	// Damaged counts drop the skin and never assert.
	cut := geom.byte_reader(out[:len(out) - 3])
	again: Levels
	testing.expect(t, levels_read(&again, &cut, &pool, 64))
	defer levels_destroy(&again)
	testing.expect(t, !levels_skin_read(&again, &cut))
	testing.expect(t, levels_skin(&again) == nil)
}

// Apply on a skin of 4 segments adds two levels whose top has a vertex at every sample,
// raised by that sample's height off the Loop surface (each vertex as far from where a
// plain Subdivide puts it as its sample's height says), leaves the skinned level where it
// was and takes the skin off; with threads or without, to the same bits.
@(test)
skin_apply_bakes_every_sample_into_levels :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	tops: [2][]Vec3
	for threaded, run in ([?]bool{false, true}) {
		l: Levels
		levels_init(&l, geom.icosphere(1), &pool if threaded else nil, 64)
		defer levels_destroy(&l)
		testing.expect(t, levels_subdivide(&l))
		skinned := &l.levels[1].sculptor
		testing.expect(t, sculptor_skin_set(skinned, 4))
		sk := skinned.skin
		skin_bumpy(sk)
		testing.expect_value(t, levels_skin_apply_steps(&l), 2)
		vertices, _, _ := levels_skin_apply_estimate(&l)
		want := make([]f32, len(sk.heights), context.temp_allocator)
		for h, i in sk.heights do want[i] = f32(h)
		slice.sort(want)
		// The same levels made by plain Subdivides, numbered alike, are where each vertex
		// rises from.
		plain: Levels
		levels_init(&plain, geom.icosphere(1), nil, 64)
		defer levels_destroy(&plain)
		for _ in 0 ..< 3 do testing.expect(t, levels_subdivide(&plain))
		before := slice.clone(skinned.mesh.positions[:], context.temp_allocator)

		testing.expect(t, levels_skin_apply(&l))
		testing.expect_value(t, len(l.levels), 4)
		testing.expect_value(t, l.current, 3)
		testing.expect(t, levels_skin(&l) == nil && l.levels[1].sculptor.skin == nil, "the skin stayed")
		top := l.levels[3].mesh.positions[:]
		testing.expect_value(t, len(top), len(want))
		testing.expect_value(t, vertices, len(want))
		flat := plain.levels[3].mesh
		testing.expect_value(t, len(flat.positions), len(top))
		if len(flat.positions) != len(top) do return
		got := make([]f32, len(top), context.temp_allocator)
		off: f32
		for p, v in top {
			d := p - flat.positions[v]
			n := linalg.normalize(flat.normals[v])
			got[v] = linalg.dot(d, n)
			off = max(off, linalg.length(d - n * got[v]))
		}
		slice.sort(got)
		worst_h: f32
		for h, i in got do worst_h = max(worst_h, abs(h - want[i]))
		testing.expectf(t, worst_h < 1e-5, "a vertex rose %v away from its sample's height", worst_h)
		testing.expectf(t, off < 1e-5, "a vertex moved %v off its normal", off)
		testing.expect(t, slice.equal(l.levels[1].mesh.positions[:], before), "the skinned level moved")
		tops[run] = slice.clone(top, context.temp_allocator)
		// Going down a level and back keeps the baked detail.
		levels_set_current(&l, 1)
		levels_set_current(&l, 3)
		worst: f32
		for p, v in l.levels[3].mesh.positions do worst = max(worst, linalg.length(p - tops[run][v]))
		testing.expectf(t, worst < 1e-5, "the detail drifted by %v", worst)
	}
	testing.expect(t, slice.equal(tops[0], tops[1]), "threads changed the result")
	// No skin, nothing to apply.
	l: Levels
	levels_init(&l, geom.icosphere(1), nil, 64)
	defer levels_destroy(&l)
	testing.expect(t, !levels_skin_apply(&l))
	testing.expect_value(t, len(l.levels), 1)
}
