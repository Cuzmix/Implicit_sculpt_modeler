package sculpt

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:testing"

import "../geom"

// A sphere, with bumps of relative height `bumps`, in small chunks, and the
// simplification tree a large mesh would get.
@(private = "file")
lod_sphere :: proc(s: ^Sculptor, m: ^geom.Mesh, subdivisions: int, node_triangles: u32, bumps: f32 = 0) {
	m^ = geom.icosphere(subdivisions)
	for &p in m.positions do p *= 1 + bumps * math.sin(9 * p.x) * math.sin(7 * p.y + 1)
	sculptor_init(s, m, nil, node_triangles)
	lod_init(s, min_triangles = 0)
}

// Triangles of a cut through the tree: each clean group drawn simplified with
// probability `coarse`, else its children.
@(private = "file")
random_cut :: proc(s: ^Sculptor, unit: u32, coarse: f32, out: ^[dynamic]u32) -> (groups: int) {
	nodes := len(s.nodes)
	if int(unit) < nodes {
		n := s.nodes[unit]
		append(out, ..s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count])
		return 0
	}
	g := s.lod.tree.groups[int(unit) - nodes]
	if !g.stale && rand.float32() < coarse {
		append(out, ..s.lod.indices[g.first_index:][:g.index_count])
		return 1
	}
	for child in s.lod.tree.units[g.child_first:][:g.child_count] do groups += random_cut(s, child, coarse, out)
	return
}

@(private = "file")
expect_closed_cuts :: proc(t: ^testing.T, s: ^Sculptor, loc := #caller_location) {
	cut: [dynamic]u32
	defer delete(cut)
	for coarse in ([?]f32{0, 0.3, 0.7, 1}) {
		for _ in 0 ..< 4 {
			clear(&cut)
			groups := 0
			for root in s.lod.tree.roots do groups += random_cut(s, root, coarse, &cut)
			closed := geom.mesh_check_indices(s.mesh.positions[:], cut[:]).closed
			testing.expectf(t, closed, "a cut drawing %d groups has a crack or overlap", groups, loc = loc)
			if coarse == 0 do testing.expect_value(t, len(cut), len(s.mesh.indices), loc = loc)
		}
	}
}

@(test)
lod_tree_covers_every_chunk_once :: proc(t: ^testing.T) {
	s: Sculptor
	m: geom.Mesh
	lod_sphere(&s, &m, 5, 32)
	defer geom.mesh_destroy(&m)
	defer sculptor_destroy(&s)
	l := &s.lod
	nodes := len(s.nodes)
	testing.expect(t, len(l.tree.groups) > 10, "too few groups to test")
	testing.expect_value(t, sculptor_lod_pending(&s), len(l.tree.groups))

	seen := make([]int, nodes + len(l.tree.groups), context.temp_allocator)
	for root in l.tree.roots {
		seen[root] += 1
		testing.expect_value(t, l.parent[root], LOD_NO_PARENT)
	}
	for g, i in l.tree.groups {
		children := l.tree.units[g.child_first:][:g.child_count]
		if l.parent[nodes + i] != LOD_NO_PARENT do testing.expectf(t, len(children) >= LOD_FANOUT && len(children) <= 2 * LOD_FANOUT - 2, "group of %d", len(children))
		for unit in children {
			seen[unit] += 1
			testing.expect_value(t, l.parent[unit], u32(i))
			if int(unit) >= nodes do testing.expect(t, l.height[int(unit) - nodes] < l.height[i], "a child is not below its group")
		}
	}
	for c, unit in seen do testing.expectf(t, c == 1, "unit %d appears %d times", unit, c)
}

@(test)
lod_cuts_are_closed_and_close :: proc(t: ^testing.T) {
	s: Sculptor
	m: geom.Mesh
	lod_sphere(&s, &m, 4, 32, bumps = 0.05)
	defer geom.mesh_destroy(&m)
	defer sculptor_destroy(&s)

	ranges, all := sculptor_lod_update(&s, finish = true)
	testing.expect_value(t, sculptor_lod_pending(&s), 0)
	testing.expect(t, all || len(ranges) == len(s.lod.tree.groups), "every copy should be uploaded")
	for g in s.lod.tree.groups do testing.expect(t, !g.stale && g.error != geom.LOD_NONE, "a group was left unbuilt")
	expect_closed_cuts(t, &s)

	for _, i in s.lod.tree.groups do expect_within_error(t, &s, i)
}

// Every full-detail vertex under a group lies within the group's error of its copy.
// The error is estimated from quadrics, which can run a little short on patches this
// small, hence the margin.
@(private = "file")
expect_within_error :: proc(t: ^testing.T, s: ^Sculptor, group: int, loc := #caller_location) {
	g := s.lod.tree.groups[group]
	fine := make([dynamic]u32, context.temp_allocator)
	gather_fine(s, u32(len(s.nodes) + group), &fine)
	copy_ := s.lod.indices[g.first_index:][:g.index_count]
	worst := distance_to_surface(s.mesh.positions[:], fine[:], copy_)
	testing.expectf(t, worst <= 1.1 * g.error + 1e-5, "group %d strays %v, error %v", group, worst, g.error, loc = loc)
	testing.expect(t, len(copy_) < len(fine), "a copy has as many triangles as it stands for", loc = loc)
}

@(private = "file")
gather_fine :: proc(s: ^Sculptor, unit: u32, out: ^[dynamic]u32) {
	if int(unit) < len(s.nodes) {
		n := s.nodes[unit]
		append(out, ..s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count])
		return
	}
	g := s.lod.tree.groups[int(unit) - len(s.nodes)]
	for child in s.lod.tree.units[g.child_first:][:g.child_count] do gather_fine(s, child, out)
}

@(test)
lod_edits_wait_for_rebuild :: proc(t: ^testing.T) {
	s: Sculptor
	m: geom.Mesh
	lod_sphere(&s, &m, 5, 32)
	defer geom.mesh_destroy(&m)
	defer sculptor_destroy(&s)
	_, _ = sculptor_lod_update(&s, finish = true)
	l := &s.lod

	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1}, {0, 0, 1})
	_ = sculptor_flush(&s)
	// Every group above an edited chunk is stale; no other group is.
	above := make([]bool, len(l.tree.groups), context.temp_allocator)
	for id in s.edited_nodes {
		for p := l.parent[id]; p != LOD_NO_PARENT; p = l.parent[len(s.nodes) + int(p)] do above[p] = true
	}
	stale := 0
	for g, i in l.tree.groups {
		testing.expect_value(t, g.stale, above[i])
		if g.stale do stale += 1
	}
	testing.expect(t, stale > 0 && stale < len(l.tree.groups), "the dab should stale some groups")
	testing.expect_value(t, sculptor_lod_pending(&s), stale)
	expect_closed_cuts(t, &s)

	// Nothing is rebuilt while the stroke goes on.
	ranges, all := sculptor_lod_update(&s, finish = true)
	testing.expect(t, len(ranges) == 0 && !all, "rebuilt during a stroke")
	testing.expect_value(t, sculptor_lod_pending(&s), stale)

	// Afterwards, updates a frame's worth of work at a time catch up.
	_ = sculptor_stroke_end(&s)
	_ = sculptor_flush(&s)
	uploaded, moved := 0, false
	for calls := 0; sculptor_lod_pending(&s) > 0 && calls < 1000; calls += 1 {
		ranges, all = sculptor_lod_update(&s)
		uploaded += len(ranges)
		moved ||= all
	}
	testing.expect_value(t, sculptor_lod_pending(&s), 0)
	testing.expect(t, moved || uploaded == stale, "every rebuilt copy should be uploaded")
	expect_closed_cuts(t, &s)
	// The rebuilt copies follow the dab.
	for i in 0 ..< len(l.tree.groups) do if above[i] do expect_within_error(t, &s, i)
}

@(test)
lod_slots_move_and_compact :: proc(t: ^testing.T) {
	s: Sculptor
	m: geom.Mesh
	lod_sphere(&s, &m, 4, 32)
	defer geom.mesh_destroy(&m)
	defer sculptor_destroy(&s)
	_, _ = sculptor_lod_update(&s, finish = true)
	l := &s.lod
	before := make([][]u32, len(l.tree.groups), context.temp_allocator)
	for g, i in l.tree.groups {
		before[i] = make([]u32, g.index_count, context.temp_allocator)
		copy(before[i], l.indices[g.first_index:][:g.index_count])
	}
	expect_unchanged :: proc(t: ^testing.T, l: ^Lod_State, before: [][]u32, loc := #caller_location) {
		for g, i in l.tree.groups {
			testing.expect(t, g.first_index + l.capacity[i] <= u32(len(l.indices)), "a slot runs past the end", loc = loc)
			got := l.indices[g.first_index:][:g.index_count]
			testing.expect_value(t, len(got), len(before[i]), loc = loc)
			for v, k in before[i] do if got[k] != v {
				testing.expectf(t, false, "group %d changed after moving", i, loc = loc)
				break
			}
		}
	}
	// Copies that outgrow their slots move to the end.
	firsts := make([]u32, len(l.tree.groups), context.temp_allocator)
	for &g, i in l.tree.groups {
		firsts[i] = g.first_index
		l.capacity[i] = g.index_count - 3
		g.stale = true
		append(&l.stale, u32(i))
	}
	_, _ = sculptor_lod_update(&s, finish = true)
	for g, i in l.tree.groups do testing.expect(t, g.first_index != firsts[i], "a copy stayed in a slot too small for it")
	testing.expect(t, l.wasted > 0, "outgrown slots should count as wasted")
	expect_unchanged(t, l, before)
	expect_closed_cuts(t, &s)

	// Compaction packs them and asks for everything to be uploaded again.
	lod_compact(l)
	testing.expect_value(t, l.wasted, 0)
	total := 0
	for c in l.capacity do total += int(c)
	testing.expect_value(t, len(l.indices), total)
	expect_unchanged(t, l, before)
	expect_closed_cuts(t, &s)
	ranges, all := sculptor_lod_update(&s)
	testing.expect(t, all && len(ranges) == 0, "a compaction should ask for a full upload")
}

// The renderer's selection: with no error allowed it draws exactly what plain culling
// draws; with any error allowed, only whole groups.
@(test)
cull_lod_selects_by_error :: proc(t: ^testing.T) {
	s: Sculptor
	m: geom.Mesh
	lod_sphere(&s, &m, 5, 32)
	defer geom.mesh_destroy(&m)
	defer sculptor_destroy(&s)
	_, _ = sculptor_lod_update(&s, finish = true)
	eye := Vec3{0.4, 0.8, 3.2}
	f := 1 / math.tan(f32(0.35))
	proj := geom.Mat4{f, 0, 0, 0, 0, f, 0, 0, 0, 0, -1, -0.01, 0, 0, -1, 0}
	clip := proj * lod_look_at(eye, {0, 0, 0})

	plain, fine, coarse: [dynamic]geom.Index_Range
	defer delete(plain)
	defer delete(fine)
	defer delete(coarse)
	_ = geom.cull_chunks(s.chunks, clip, eye, &plain)
	stats := geom.cull_lod(s.chunks, s.lod.tree, clip, eye, 500, 0, &fine, &coarse)
	testing.expect_value(t, len(coarse), 0)
	testing.expect_value(t, stats.groups, 0)
	testing.expect_value(t, triangles(fine[:]), triangles(plain[:]))

	clear(&fine)
	stats = geom.cull_lod(s.chunks, s.lod.tree, clip, eye, 500, 1e9, &fine, &coarse)
	testing.expect_value(t, len(fine), 0)
	testing.expect(t, stats.groups > 0 && stats.groups <= len(s.lod.tree.roots), "a huge error should draw the roots")

	clear(&fine)
	clear(&coarse)
	stats = geom.cull_lod(s.chunks, s.lod.tree, clip, eye, 500, 1, &fine, &coarse)
	testing.expect(t, stats.groups > 0, "one pixel of error should allow some groups")
	testing.expect(t, triangles(fine[:]) + triangles(coarse[:]) < triangles(plain[:]), "the selection should draw fewer triangles")
}

// Hidden chunks are never drawn, nor any group over one (it would cover them), while
// everything else is drawn as usual.
@(test)
cull_lod_leaves_out_hidden :: proc(t: ^testing.T) {
	s: Sculptor
	m: geom.Mesh
	lod_sphere(&s, &m, 5, 32)
	defer geom.mesh_destroy(&m)
	defer sculptor_destroy(&s)
	_, _ = sculptor_lod_update(&s, finish = true)
	nodes := len(s.nodes)
	hidden := make([]bool, nodes + len(s.lod.tree.groups), context.temp_allocator)
	for id in 0 ..< nodes / 4 { // node ids follow the BVH, so this is one patch of the sphere
		unit := u32(id)
		hidden[unit] = true
		for s.lod.parent[unit] != LOD_NO_PARENT {
			unit = u32(nodes) + s.lod.parent[unit]
			hidden[unit] = true
		}
	}
	eye := Vec3{0.4, 0.8, 3.2}
	f := 1 / math.tan(f32(0.35))
	proj := geom.Mat4{f, 0, 0, 0, 0, f, 0, 0, 0, 0, -1, -0.01, 0, 0, -1, 0}
	clip := proj * lod_look_at(eye, {0, 0, 0})
	overlaps :: proc(ranges: []geom.Index_Range, first, count: u32) -> bool {
		for r in ranges do if r.first_index < first + count && first < r.first_index + r.index_count do return true
		return false
	}

	plain, fine, coarse: [dynamic]geom.Index_Range
	defer delete(plain)
	defer delete(fine)
	defer delete(coarse)
	_ = geom.cull_chunks(s.chunks, clip, eye, &plain, hidden = hidden[:nodes])
	_ = geom.cull_lod(s.chunks, s.lod.tree, clip, eye, 500, 0, &fine, &coarse, hidden)
	testing.expect_value(t, triangles(fine[:]), triangles(plain[:]))
	testing.expect(t, len(plain) > 0, "everything was left out")
	for c, id in s.chunks {
		if hidden[id] do testing.expect(t, !overlaps(plain[:], c.first_index, c.index_count), "plain culling drew a hidden chunk")
	}

	clear(&fine)
	clear(&coarse)
	stats := geom.cull_lod(s.chunks, s.lod.tree, clip, eye, 500, 1e9, &fine, &coarse, hidden)
	testing.expect(t, stats.groups > 0, "no group drawn simplified")
	for c, id in s.chunks {
		if hidden[id] do testing.expect(t, !overlaps(fine[:], c.first_index, c.index_count), "a hidden chunk was drawn")
	}
	for g, i in s.lod.tree.groups {
		if hidden[nodes + i] do testing.expect(t, !overlaps(coarse[:], g.first_index, g.index_count), "a group over a hidden chunk was drawn")
	}
}

@(private = "file")
triangles :: proc(ranges: []geom.Index_Range) -> (n: int) {
	for r in ranges do n += int(r.index_count / 3)
	return
}

@(private = "file")
lod_look_at :: proc(eye, target: Vec3) -> geom.Mat4 {
	f := linalg.normalize(target - eye)
	r := linalg.normalize(linalg.cross(f, Vec3{0, 1, 0}))
	u := linalg.cross(r, f)
	return geom.Mat4{
		r.x, r.y, r.z, -linalg.dot(r, eye),
		u.x, u.y, u.z, -linalg.dot(u, eye),
		-f.x, -f.y, -f.z, linalg.dot(f, eye),
		0, 0, 0, 1,
	}
}

@(private = "file")
closest_on_triangle :: proc(p, a, b, c: Vec3) -> Vec3 {
	// Ericson, Real-Time Collision Detection, 5.1.5.
	ab, ac, ap := b - a, c - a, p - a
	d1, d2 := linalg.dot(ab, ap), linalg.dot(ac, ap)
	if d1 <= 0 && d2 <= 0 do return a
	bp := p - b
	d3, d4 := linalg.dot(ab, bp), linalg.dot(ac, bp)
	if d3 >= 0 && d4 <= d3 do return b
	vc := d1 * d4 - d3 * d2
	if vc <= 0 && d1 >= 0 && d3 <= 0 do return a + ab * (d1 / (d1 - d3))
	cp := p - c
	d5, d6 := linalg.dot(ab, cp), linalg.dot(ac, cp)
	if d6 >= 0 && d5 <= d6 do return c
	vb := d5 * d2 - d1 * d6
	if vb <= 0 && d2 >= 0 && d6 <= 0 do return a + ac * (d2 / (d2 - d6))
	va := d3 * d6 - d5 * d4
	if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 do return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	denom := 1 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)
}

// Largest distance from a vertex of `from` to the surface `to`.
@(private = "file")
distance_to_surface :: proc(positions: []Vec3, from, to: []u32) -> f32 {
	worst: f32
	for v in from {
		p := positions[v]
		best := max(f32)
		for t := 0; t < len(to); t += 3 {
			q := closest_on_triangle(p, positions[to[t]], positions[to[t + 1]], positions[to[t + 2]])
			best = min(best, linalg.length2(q - p))
		}
		worst = max(worst, best)
	}
	return math.sqrt(worst)
}
