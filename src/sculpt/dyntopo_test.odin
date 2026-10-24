package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
Dyn_Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

// A dynamic sculptor over an icosphere; free with dyn_free.
@(private = "file")
dyn_make :: proc(t: ^testing.T, subdiv: int, pool: ^jobs.Pool = nil, node_triangles: u32 = 256) -> ^Dyn_Sphere {
	sp := new(Dyn_Sphere)
	sp.mesh = geom.icosphere(subdiv)
	sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	testing.expect(t, sculptor_dyn_enable(&sp.sculptor), "enable failed")
	return sp
}

@(private = "file")
dyn_free :: proc(sp: ^Dyn_Sphere) {
	sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	free(sp)
}

// Checks everything the dynamic layout keeps consistent: the pages, each vertex's
// triangle list, a closed manifold surface, the shared lists, the BVH and bounds.
@(private = "file")
expect_valid :: proc(t: ^testing.T, s: ^Sculptor, loc := #caller_location) -> bool {
	d := s.dyn
	m := s.mesh
	idx := m.indices[:]
	used :: proc(s: ^Sculptor, v: u32) -> bool {
		page := vert_page(v)
		return int(page) < len(s.nodes) && v - page * DYN_PAGE_VERTS < s.nodes[page].vert_count
	}
	corners := make([]int, len(m.positions), context.temp_allocator)
	directed := make(map[[2]u32]int, 1024, context.temp_allocator)
	for n, id in s.nodes {
		if n.vert_count > DYN_PAGE_VERTS || n.tri_count > DYN_PAGE_TRIS {
			testing.expectf(t, false, "node %d over its page: %d vertices, %d triangles", id, n.vert_count, n.tri_count, loc = loc)
			return false
		}
		for f in n.tri_first ..< n.tri_first + DYN_PAGE_TRIS {
			tri := idx[3 * f:][:3]
			if f >= n.tri_first + n.tri_count {
				if tri[0] != 0 || tri[1] != 0 || tri[2] != 0 {
					testing.expectf(t, false, "unused triangle slot %d is not zero", f, loc = loc)
					return false
				}
				continue
			}
			if tri[0] == tri[1] || tri[1] == tri[2] || tri[0] == tri[2] {
				testing.expectf(t, false, "triangle %d repeats a vertex: %v", f, tri, loc = loc)
				return false
			}
			for k in 0 ..< 3 {
				v := tri[k]
				if !used(s, v) {
					testing.expectf(t, false, "triangle %d uses unused vertex slot %d", f, v, loc = loc)
					return false
				}
				corners[v] += 1
				directed[{v, tri[(k + 1) % 3]}] += 1
				if !slice.contains(dyn_faces(d, v), f) {
					testing.expectf(t, false, "vertex %d does not list its triangle %d", v, f, loc = loc)
					return false
				}
			}
		}
	}
	for v in 0 ..< u32(len(m.positions)) {
		if !used(s, v) do continue
		if int(d.face_count[v]) != corners[v] || corners[v] == 0 {
			testing.expectf(t, false, "vertex %d lists %d triangles but is in %d", v, d.face_count[v], corners[v], loc = loc)
			return false
		}
	}
	for e, count in directed {
		if count != 1 || directed[{e[1], e[0]}] != 1 {
			testing.expectf(t, false, "edge %v: %d one way, %d the other", e, count, directed[{e[1], e[0]}], loc = loc)
			return false
		}
	}
	for n, id in s.nodes {
		shared := make([dynamic]u32, context.temp_allocator)
		owners := make([dynamic]u32, context.temp_allocator)
		for v in idx[3 * n.tri_first:][:3 * n.tri_count] {
			if vert_page(v) == u32(id) do continue
			if !slice.contains(shared[:], v) do append(&shared, v)
			if !slice.contains(owners[:], vert_page(v)) do append(&owners, vert_page(v))
		}
		got_shared := slice.clone(d.shared[id][:], context.temp_allocator)
		got_owners := slice.clone(d.owners[id][:], context.temp_allocator)
		slice.sort(shared[:])
		slice.sort(owners[:])
		slice.sort(got_shared)
		slice.sort(got_owners)
		if !slice.equal(shared[:], got_shared) || !slice.equal(owners[:], got_owners) {
			testing.expectf(t, false, "node %d: shared lists out of date", id, loc = loc)
			return false
		}
		if n.tri_count == 0 {
			if n.leaf != geom.BVH_NONE {
				testing.expectf(t, false, "empty node %d has a leaf", id, loc = loc)
				return false
			}
			continue
		}
		if n.leaf == geom.BVH_NONE || s.node_of[n.leaf] != u32(id) {
			testing.expectf(t, false, "node %d has no leaf", id, loc = loc)
			return false
		}
		leaf := s.bvh.nodes[n.leaf]
		if leaf.first != n.tri_first || leaf.count != n.tri_count {
			testing.expectf(t, false, "node %d: leaf covers %d+%d, node %d+%d", id, leaf.first, leaf.count, n.tri_first, n.tri_count, loc = loc)
			return false
		}
		for v in idx[3 * n.tri_first:][:3 * n.tri_count] {
			p := m.positions[v]
			if p.x < leaf.bounds.lo.x || p.y < leaf.bounds.lo.y || p.z < leaf.bounds.lo.z || p.x > leaf.bounds.hi.x || p.y > leaf.bounds.hi.y || p.z > leaf.bounds.hi.z {
				testing.expectf(t, false, "node %d: vertex %d outside its leaf's bounds", id, v, loc = loc)
				return false
			}
		}
		for p := leaf.parent; p != geom.BVH_NONE; p = s.bvh.nodes[p].parent {
			b := s.bvh.nodes[p].bounds
			if b.lo.x > leaf.bounds.lo.x || b.hi.x < leaf.bounds.hi.x || b.lo.z > leaf.bounds.lo.z || b.hi.z < leaf.bounds.hi.z {
				testing.expectf(t, false, "node %d: an ancestor's bounds miss it", id, loc = loc)
				return false
			}
		}
	}
	return true
}

@(private = "file")
euler :: proc(s: ^Sculptor) -> int {
	v, f := sculptor_vertex_count(s), sculptor_triangle_count(s)
	return v - 3 * f / 2 + f
}

// Turning dynamic topology on keeps the mesh exactly, and off again packs it back.
@(test)
dyn_enable_keeps_the_mesh :: proc(t: ^testing.T) {
	mesh := geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &mesh, nil, 256)
	positions := slice.clone(mesh.positions[:], context.temp_allocator)
	indices := slice.clone(mesh.indices[:], context.temp_allocator)
	testing.expect(t, sculptor_dyn_enable(&s))
	testing.expect(t, expect_valid(t, &s))
	out, _ := sculptor_compact_mesh(&s, context.temp_allocator)
	testing.expect(t, slice.equal(out.positions[:], positions), "positions changed")
	testing.expect(t, slice.equal(out.indices[:], indices), "triangles changed")
	hit, ok := sculptor_raycast(&s, {0.013, 0.021, 3}, {0, 0, -1})
	testing.expect(t, ok && abs(hit.z - 1) < 0.01, "raycast missed")
	sculptor_dyn_disable(&s)
	testing.expect(t, s.dyn == nil && len(mesh.positions) == len(positions) && len(mesh.indices) == len(indices))
	sculptor_destroy(&s)
	geom.mesh_destroy(&mesh)
}

// Dabs over a coarse mesh split its long edges until none in the brush is longer than
// the detail size, keeping everything consistent and the surface closed.
@(test)
dyn_dabs_split_long_edges :: proc(t: ^testing.T) {
	sp := dyn_make(t, 2)
	defer dyn_free(sp)
	s := &sp.sculptor
	before := sculptor_triangle_count(s)
	brush := Brush{kind = .Draw, radius = 0.5, strength = 0.2, detail = 0.2}
	for _ in 0 ..< 4 {
		_ = apply_dab(s, brush, {0, 0, 1})
		_ = sculptor_flush(s)
		if !expect_valid(t, s) do return
	}
	after := sculptor_triangle_count(s)
	testing.expectf(t, after > before + 300, "%d triangles before, %d after", before, after)
	testing.expectf(t, euler(s) == 2, "Euler characteristic %d", euler(s))
	m := s.mesh
	for n in s.nodes {
		for f in n.tri_first ..< n.tri_first + n.tri_count {
			for k in u32(0) ..< 3 {
				a, b := m.indices[3 * f + k], m.indices[3 * f + (k + 1) % 3]
				mid := (m.positions[a] + m.positions[b]) * 0.5 - Vec3{0, 0, 1}
				if linalg.length(mid) < 0.4 && linalg.length(m.positions[a] - m.positions[b]) > 0.1 {
					testing.expectf(t, false, "edge %d-%d in the brush is still long", a, b)
					return
				}
			}
		}
	}
}

// With collapsing on, a large detail size merges a fine mesh's short edges.
@(test)
dyn_dabs_collapse_short_edges :: proc(t: ^testing.T) {
	sp := dyn_make(t, 5)
	defer dyn_free(sp)
	s := &sp.sculptor
	before := sculptor_triangle_count(s)
	mesh_before, _ := sculptor_compact_mesh(s, context.temp_allocator)
	brush := Brush{kind = .Smooth, radius = 0.5, strength = 0.5, detail = 0.4, collapse = true}
	sculptor_stroke_begin(s)
	for _ in 0 ..< 4 {
		_ = apply_dab(s, brush, {0, 0, 1})
		_ = sculptor_flush(s)
		if !expect_valid(t, s) do return
	}
	_ = sculptor_stroke_end(s)
	after := sculptor_triangle_count(s)
	testing.expectf(t, after < before - 500, "%d triangles before, %d after", before, after)
	testing.expectf(t, euler(s) == 2, "Euler characteristic %d", euler(s))
	testing.expect(t, sculptor_undo(s))
	_ = sculptor_flush(s)
	if !expect_valid(t, s) do return
	undone, _ := sculptor_compact_mesh(s, context.temp_allocator)
	testing.expect(t, slice.equal(undone.positions[:], mesh_before.positions[:]) && slice.equal(undone.indices[:], mesh_before.indices[:]), "undo did not restore the mesh")
}

// Refining far past a page's size splits nodes, and undo and redo bring back the mesh
// exactly as it was before and after the stroke.
@(test)
dyn_undo_redo_restore_exactly :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sp := dyn_make(t, 3, &pool)
	defer dyn_free(sp)
	s := &sp.sculptor
	nodes_before := 0
	for n in s.nodes do nodes_before += int(n.tri_count > 0)
	before, _ := sculptor_compact_mesh(s, context.temp_allocator)
	sculptor_stroke_begin(s)
	for k in 0 ..< 12 {
		at := linalg.normalize(Vec3{0.1 * f32(k) - 0.6, 0.2, 1})
		_ = apply_dab(s, {kind = .Draw, radius = 0.6, strength = 0.3, detail = 0.06, collapse = true}, at)
		_ = sculptor_flush(s)
		if !expect_valid(t, s) do return
	}
	testing.expect(t, sculptor_stroke_end(s))
	nodes_after := 0
	for n in s.nodes do nodes_after += int(n.tri_count > 0)
	testing.expectf(t, nodes_after > nodes_before, "no node split: %d nodes before and after", nodes_before)
	after, _ := sculptor_compact_mesh(s, context.temp_allocator)
	testing.expect(t, len(after.indices) > 4 * len(before.indices), "the stroke made too few triangles")

	for round in 0 ..< 2 {
		testing.expect(t, sculptor_undo(s))
		_ = sculptor_flush(s)
		if !expect_valid(t, s) do return
		undone, _ := sculptor_compact_mesh(s, context.temp_allocator)
		testing.expectf(t, slice.equal(undone.positions[:], before.positions[:]) && slice.equal(undone.indices[:], before.indices[:]), "round %d: undo did not restore the mesh", round)
		testing.expect(t, sculptor_redo(s))
		_ = sculptor_flush(s)
		if !expect_valid(t, s) do return
		redone, _ := sculptor_compact_mesh(s, context.temp_allocator)
		testing.expectf(t, slice.equal(redone.positions[:], after.positions[:]) && slice.equal(redone.indices[:], after.indices[:]), "round %d: redo did not restore the mesh", round)
	}
	_, ok := sculptor_raycast(s, {0.013, 0.021, 3}, {0, 0, -1})
	testing.expect(t, ok, "raycast missed after undo and redo")
}

// Every dab brush works with dynamic topology, with symmetry too, and a fully masked
// area keeps its triangles.
@(test)
dyn_every_brush_and_the_mask :: proc(t: ^testing.T) {
	for kind in Brush_Kind {
		if kind == .Grab || kind == .Mask do continue
		sp := dyn_make(t, 3)
		s := &sp.sculptor
		sculptor_stroke_begin(s)
		for k in 0 ..< 3 {
			at := linalg.normalize(Vec3{0.2 * f32(k), 0.1, 1})
			_ = apply_dab(s, {kind = kind, radius = 0.4, strength = 0.5, detail = 0.15, collapse = true, symmetry = {.X}}, at)
			_ = sculptor_flush(s)
		}
		_ = sculptor_stroke_end(s)
		ok := expect_valid(t, s)
		testing.expectf(t, ok && euler(s) == 2, "%v: Euler characteristic %d", kind, euler(s))
		dyn_free(sp)
		if !ok do return
	}

	sp := dyn_make(t, 3)
	defer dyn_free(sp)
	s := &sp.sculptor
	_ = sculptor_mask_command(s, .Fill)
	before := sculptor_triangle_count(s)
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 0.5, detail = 0.1, collapse = true}, {0, 0, 1})
	testing.expect(t, sculptor_triangle_count(s) == before, "a masked area changed its triangles")
}

// After sculpting, turning dynamic topology off gives a plain closed mesh with what
// was sculpted, and the mask kept.
@(test)
dyn_disable_after_sculpting :: proc(t: ^testing.T) {
	sp := dyn_make(t, 3)
	defer dyn_free(sp)
	s := &sp.sculptor
	_ = apply_dab(s, {kind = .Mask, radius = 0.3, strength = 1}, {1, 0, 0})
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 0.5, detail = 0.1}, {0, 0, 1})
	_ = sculptor_flush(s)
	vertices, triangles := sculptor_vertex_count(s), sculptor_triangle_count(s)
	masked := 0
	for n in s.nodes do for v in n.vert_first ..< n.vert_first + n.vert_count do masked += int(s.mask[v] > 0)
	sculptor_dyn_disable(s)
	testing.expect(t, len(sp.mesh.positions) == vertices && len(sp.mesh.indices) == 3 * triangles)
	now := 0
	for k in s.mask do now += int(k > 0)
	testing.expectf(t, now == masked && masked > 0, "%d masked vertices before, %d after", masked, now)
	_ = apply_dab(s, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
}

// Grab and Mask strokes, which make no new triangles, undo exactly on a dynamic
// sculptor too, after a stroke that did.
@(test)
dyn_grab_and_mask_strokes_undo :: proc(t: ^testing.T) {
	sp := dyn_make(t, 3)
	defer dyn_free(sp)
	s := &sp.sculptor
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 0.5, detail = 0.08, collapse = true}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_end(s))
	_ = sculptor_flush(s)
	refined, _ := sculptor_compact_mesh(s, context.temp_allocator)

	sculptor_stroke_begin(s)
	testing.expect(t, sculptor_grab_begin(s, {kind = .Grab, radius = 0.4, strength = 1}, {0, 0, 1}) > 0)
	_ = sculptor_grab_move(s, {0.2, 0, 0.1})
	_ = sculptor_flush(s)
	sculptor_grab_end(s)
	testing.expect(t, sculptor_stroke_end(s))
	grabbed, _ := sculptor_compact_mesh(s, context.temp_allocator)
	testing.expect(t, !slice.equal(grabbed.positions[:], refined.positions[:]), "the grab moved nothing")

	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Mask, radius = 0.3, strength = 1}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_end(s))
	_, mask := sculptor_compact_mesh(s, context.temp_allocator)
	testing.expect(t, slice.any_of_proc(mask, proc(k: u8) -> bool {return k > 0}), "the mask stroke painted nothing")

	testing.expect(t, sculptor_undo(s))
	_ = sculptor_flush(s)
	_, mask = sculptor_compact_mesh(s, context.temp_allocator)
	testing.expect(t, !slice.any_of_proc(mask, proc(k: u8) -> bool {return k > 0}), "undo left the mask")
	testing.expect(t, sculptor_undo(s))
	_ = sculptor_flush(s)
	if !expect_valid(t, s) do return
	undone, _ := sculptor_compact_mesh(s, context.temp_allocator)
	testing.expect(t, slice.equal(undone.positions[:], refined.positions[:]) && slice.equal(undone.indices[:], refined.indices[:]), "undo did not restore the grab")
	_, ok := sculptor_raycast(s, {0.013, 0.021, 3}, {0, 0, -1})
	testing.expect(t, ok, "raycast missed after undoing the grab")
}

// After a flush, every vertex's normal is what its triangles give, edits or not.
@(test)
dyn_flush_leaves_normals_current :: proc(t: ^testing.T) {
	sp := dyn_make(t, 3)
	defer dyn_free(sp)
	s := &sp.sculptor
	m := s.mesh
	// The icosphere comes with exact sphere normals: start from the triangles' instead.
	for n in s.nodes {
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			sum: Vec3
			for f in dyn_faces(s.dyn, v) do sum += face_normal(m, f)
			m.normals[v] = linalg.normalize0(sum)
		}
	}
	sculptor_stroke_begin(s)
	for k in 0 ..< 16 {
		at := linalg.normalize(Vec3{0.08 * f32(k) - 0.6, 0.3 * f32(k % 3) - 0.3, 1})
		_ = apply_dab(s, {kind = .Draw, radius = 0.35, strength = 0.4, detail = 0.08 + 0.02 * f32(k % 4), collapse = true}, at)
		_ = sculptor_flush(s)
		for n in s.nodes {
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				sum: Vec3
				for f in dyn_faces(s.dyn, v) do sum += face_normal(m, f)
				want := linalg.normalize0(sum)
				if linalg.length(m.normals[v] - want) > 1e-4 {
					testing.expectf(t, false, "dab %d: vertex %d has normal %v, its triangles give %v", k, v, m.normals[v], want)
					return
				}
			}
		}
	}
	_ = sculptor_stroke_end(s)
}

// A long stroke that refines a lot, round and round the same ring, keeps a valid
// surface of well-shaped triangles without folds: splits bisect triangles across
// their longest side, and slivers left over collapse.
@(test)
dyn_long_stroke_keeps_a_clean_surface :: proc(t: ^testing.T) {
	sp := dyn_make(t, 4)
	defer dyn_free(sp)
	s := &sp.sculptor
	m := s.mesh
	sculptor_stroke_begin(s)
	for k in 0 ..< 160 {
		a := 2 * math.PI * f32(k) / 80
		at := linalg.normalize(Vec3{0.4 * math.cos(a), 0.4 * math.sin(a), 1})
		strength: f32 = 0 if k < 80 else 0.5 // the topology alone, then with the brush moving it
		_ = apply_dab(s, {kind = .Draw, radius = 0.25, strength = strength, detail = 0.06, collapse = true}, at)
		_ = sculptor_flush(s)
		if k % 20 != 19 do continue
		if !expect_valid(t, s) {
			testing.expectf(t, false, "invalid after dab %d", k)
			return
		}
		smallest: f32 = 180
		for n in s.nodes {
			for f in n.tri_first ..< n.tri_first + n.tri_count {
				for c in u32(0) ..< 3 {
					p := m.positions[m.indices[3 * f + c]]
					e1 := m.positions[m.indices[3 * f + (c + 1) % 3]] - p
					e2 := m.positions[m.indices[3 * f + (c + 2) % 3]] - p
					cos := linalg.dot(e1, e2) / (linalg.length(e1) * linalg.length(e2))
					smallest = min(smallest, math.acos(clamp(cos, -1, 1)) * 180 / math.PI)
				}
				fn := face_normal(m, f)
				for c in u32(0) ..< 3 {
					if linalg.dot(fn, m.normals[m.indices[3 * f + c]]) <= 0 {
						testing.expectf(t, false, "dab %d: triangle %d faces away from its corner %d's normal", k, f, c)
						return
					}
				}
			}
		}
		if smallest < 15 {
			testing.expectf(t, false, "dab %d: a triangle has a %.2f degree angle", k, smallest)
			return
		}
	}
	_ = sculptor_stroke_end(s)
	packed, _ := sculptor_compact_mesh(s, context.temp_allocator)
	r := geom.mesh_check(packed)
	testing.expectf(t, r.closed && r.degenerate_triangles == 0 && r.nan_count == 0 && !r.inverted, "mesh check: %v", r)
}

// Turning dynamic topology on, a refining stroke and turning it off give the same bits
// with worker threads as without.
@(test)
dyn_serial_and_parallel_match :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool) -> (refined, packed: geom.Mesh) {
		sp := dyn_make(t, 3, pool, 64)
		defer dyn_free(sp)
		s := &sp.sculptor
		sculptor_stroke_begin(s)
		for k in 0 ..< 24 {
			at := linalg.normalize(Vec3{0.05 * f32(k) - 0.6, 0.2, 1})
			_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 0.3, detail = 0.08, collapse = true, symmetry = {.X}}, at)
			_ = sculptor_flush(s)
		}
		_ = sculptor_stroke_end(s)
		refined, _ = sculptor_compact_mesh(s, context.temp_allocator)
		sculptor_dyn_disable(s)
		packed, _ = sculptor_compact_mesh(s, context.temp_allocator)
		return
	}
	serial_refined, serial_packed := run(t, nil)
	parallel_refined, parallel_packed := run(t, &pool)
	testing.expect(t, len(serial_refined.indices) > 0)
	testing.expect(t, slice.equal(serial_refined.positions[:], parallel_refined.positions[:]) && slice.equal(serial_refined.indices[:], parallel_refined.indices[:]), "the stroke differs")
	testing.expect(t, slice.equal(serial_refined.normals[:], parallel_refined.normals[:]), "the normals differ")
	testing.expect(t, slice.equal(serial_packed.positions[:], parallel_packed.positions[:]) && slice.equal(serial_packed.indices[:], parallel_packed.indices[:]), "turning it off differs")
}

// On an open mesh, edits keep the border where it is: its edges split at their
// middles and no vertex on it collapses, so it never pinches or pulls in, and the
// surface stays one disc (V - E + F = 1).
@(test)
dyn_open_mesh_keeps_its_border :: proc(t: ^testing.T) {
	sphere := geom.icosphere(4)
	defer geom.mesh_destroy(&sphere)
	// The cap above z = 0.3: a disc-like patch whose border the stroke crosses.
	m: geom.Mesh
	defer geom.mesh_destroy(&m)
	append(&m.positions, ..sphere.positions[:])
	for f := 0; f < len(sphere.indices); f += 3 {
		tri := sphere.indices[f:][:3]
		if sphere.positions[tri[0]].z + sphere.positions[tri[1]].z + sphere.positions[tri[2]].z > 0.9 do append(&m.indices, ..tri)
	}
	resize(&m.normals, len(m.positions))
	_, err := geom.mesh_clean(&m, nil)
	testing.expect_value(t, err, geom.Mesh_File_Error.None)
	before := geom.mesh_check(m)
	testing.expect(t, before.boundary_edges > 0 && before.non_manifold_edges == 0)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, sculptor_dyn_enable(&s), "enable refused an open mesh")
	sculptor_stroke_begin(&s)
	for k in 0 ..< 60 {
		// Back and forth across the border, splitting and collapsing.
		x := -0.6 + 1.2 * f32(k % 30) / 29
		at := linalg.normalize(Vec3{x, 0.75, 0.6})
		detail: f32 = 0.08 if k < 30 else 0.5
		_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.2, detail = detail, collapse = true}, at)
		_ = sculptor_flush(&s)
	}
	_ = sculptor_stroke_end(&s)
	splits, collapses := sculptor_dyn_edits(&s)
	testing.expectf(t, splits > 0 && collapses > 0, "%d splits, %d collapses", splits, collapses)
	packed, _ := sculptor_compact_mesh(&s, context.temp_allocator)
	after := geom.mesh_check(packed)
	testing.expectf(t, after.non_manifold_edges == 0 && after.inconsistent_edges == 0 && after.degenerate_triangles == 0 && after.boundary_edges > before.boundary_edges,
		"before %v\nafter %v", before, after)
	disc :: proc(r: geom.Mesh_Report) -> int {return r.vertices - (3 * r.triangles + r.boundary_edges) / 2 + r.triangles}
	testing.expect_value(t, disc(before), 1)
	testing.expect_value(t, disc(after), 1)
	smallest: f32 = 180
	for f := 0; f < len(packed.indices); f += 3 {
		for c in 0 ..< 3 {
			p := packed.positions[packed.indices[f + c]]
			e1 := packed.positions[packed.indices[f + (c + 1) % 3]] - p
			e2 := packed.positions[packed.indices[f + (c + 2) % 3]] - p
			smallest = min(smallest, math.acos(clamp(linalg.dot(e1, e2) / (linalg.length(e1) * linalg.length(e2)), -1, 1)) * 180 / math.PI)
		}
	}
	// Coarsening a fine area by collapses alone leaves corners of about 11 degrees.
	testing.expectf(t, smallest >= 10, "a triangle has a %.2f degree angle", smallest)
}

// An edge in three triangles cannot be edited by its direction: such a mesh is refused.
@(test)
dyn_refuses_non_manifold_edges :: proc(t: ^testing.T) {
	m := geom.icosphere(2)
	defer geom.mesh_destroy(&m)
	// A fin on the first edge: a new vertex and a triangle that runs that edge again.
	a, b := m.indices[0], m.indices[1]
	append(&m.positions, Vec3{2, 2, 2})
	append(&m.normals, Vec3{})
	append(&m.indices, a, b, u32(len(m.positions) - 1))
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, !sculptor_dyn_enable(&s), "a non-manifold mesh was taken")
	testing.expect(t, s.dyn == nil)
}
