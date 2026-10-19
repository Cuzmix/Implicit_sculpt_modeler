package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
hd_make :: proc(subdiv, steps: int, node_triangles: u32 = 64, pool: ^jobs.Pool = nil) -> (l: Levels) {
	levels_init(&l, geom.icosphere(subdiv), pool, node_triangles)
	assert(levels_hd_set_steps(&l, steps))
	return
}

@(private = "file")
hd_dab :: proc(l: ^Levels, center: Vec3, radius: f32, strength: f32 = 1) -> int {
	return apply_dab(&levels_active(l).sculptor, {kind = .Draw, radius = radius, strength = strength}, center)
}

// Window positions by what they are, not how this window numbers them: the top-level
// node storing them and their place in its storage.
@(private = "file")
Hd_Key :: struct {
	node, index: u32,
}

@(private = "file")
hd_positions :: proc(l: ^Levels, with_border := false) -> map[Hd_Key]Vec3 {
	out := make(map[Hd_Key]Vec3, 1024, context.temp_allocator)
	r := &l.hd.region
	lv := l.hd.window
	for id, j in r.nodes {
		list := node_list(r.lists, u32(j))
		for w, i in list {
			if !with_border && lv.sculptor.fade[w] == 0 do continue
			out[{id, u32(i)}] = lv.mesh.positions[w]
		}
	}
	return out
}

// Closest distance from p to any of the points.
@(private = "file")
nearest :: proc(points: []Vec3, p: Vec3) -> f32 {
	best := max(f32)
	for q in points do best = min(best, linalg.length2(q - p))
	return linalg.sqrt(best)
}

@(test)
hd_grid_covers_each_triangle :: proc(t: ^testing.T) {
	for k in 1 ..= HD_MAX_STEPS {
		n := u32(1) << uint(k)
		size := int((n + 1) * (n + 2) / 2)
		seen := make([]bool, size, context.temp_allocator)
		for path in u32(0) ..< u32(1) << uint(2 * k) {
			c := hd_grid_corners(path, k)
			// Each descendant is a triangle one grid step across, the same way round as
			// its top-level triangle (corners counter-clockwise in grid coordinates).
			a := [2]i32{i32(c[1].x) - i32(c[0].x), i32(c[1].y) - i32(c[0].y)}
			b := [2]i32{i32(c[2].x) - i32(c[0].x), i32(c[2].y) - i32(c[0].y)}
			testing.expect_value(t, abs(a.x * b.y - a.y * b.x), 1)
			testing.expect(t, a.x * b.y - a.y * b.x > 0, "descendant turned over")
			for uv in c {
				testing.expect(t, uv.x + uv.y <= n, "grid point outside its triangle")
				seen[hd_grid_index(uv, k)] = true
			}
		}
		for s in seen do testing.expect(t, s, "grid point no descendant uses")
	}
}

// With no detail, a window is exactly where full Loop subdivision of the top level puts
// those vertices, and its border lies on the top level's triangles.
@(test)
hd_window_is_loop_subdivision :: proc(t: ^testing.T) {
	for steps in 1 ..= 2 {
		l := hd_make(3, steps)
		defer levels_destroy(&l)
		reference: Levels
		levels_init(&reference, geom.icosphere(3), nil, 64)
		defer levels_destroy(&reference)
		for _ in 0 ..< steps do assert(levels_subdivide(&reference))
		want := reference.levels[steps].mesh.positions[:]

		testing.expect(t, levels_hd_enter(&l, {0, 0, 1}, 1500), "no window")
		lv := l.hd.window
		top := l.levels[0]
		r := &l.hd.region
		testing.expect(t, len(r.nodes) > 1 && len(r.nodes) < len(top.sculptor.nodes), "window should cover some nodes")
		// Each region triangle's descendants, and the seals along each border edge.
		triangles := 0
		for id in r.nodes do triangles += int(top.sculptor.nodes[id].tri_count)
		seals := hd_border_edges(&l) * 2 * ((1 << uint(steps)) - 1)
		testing.expect_value(t, len(lv.mesh.indices) / 3, triangles << uint(2 * steps) + seals)
		border := 0
		for p, w in lv.mesh.positions {
			if lv.sculptor.fade[w] == 0 {
				border += 1
				continue
			}
			if d := nearest(want, p); d > 1e-6 {
				testing.expectf(t, false, "steps %d: window vertex %d is %v from the Loop subdivision", steps, w, d)
				break
			}
		}
		testing.expect(t, border > 0, "the window has no border")
		// Border vertices lie on top-level triangles outside the window.
		for p, w in lv.mesh.positions {
			if lv.sculptor.fade[w] != 0 do continue
			best := max(f32)
			for f in 0 ..< len(top.mesh.indices) / 3 {
				best = min(best, distance_to_triangle(top.mesh, u32(f), p))
			}
			if best > 1e-6 {
				testing.expectf(t, false, "border vertex %d is %v off the top level", w, best)
				break
			}
		}
		// Every window vertex is stored by at least one node, and leaving without a
		// stroke stores nothing.
		testing.expect_value(t, len(r.home), len(lv.mesh.positions))
		for h in r.home do testing.expect(t, h != HD_NONE, "window vertex with no storage")
		levels_hd_leave(&l)
		testing.expect(t, l.hd.window == nil, "window still open")
		testing.expect_value(t, levels_hd_stats(&l).stored_nodes, 0)
	}
}

// Top-level edges between a triangle the window covers and one it does not.
@(private = "file")
hd_border_edges :: proc(l: ^Levels) -> int {
	s := &l.levels[len(l.levels) - 1].sculptor
	m := s.mesh
	covered := make([]bool, len(s.nodes), context.temp_allocator)
	for id in l.hd.region.nodes do covered[id] = true
	count := 0
	for f in 0 ..< u32(len(m.indices) / 3) {
		if !covered[s.node_of[s.bvh.tri_leaf[f]]] do continue
		for c in u32(0) ..< 3 {
			a, b := m.indices[3 * f + c], m.indices[3 * f + (c + 1) % 3]
			for g in geom.vertex_faces_of(s.faces, b) {
				after, _ := others(m.indices[:], g, b)
				if after == a && !covered[s.node_of[s.bvh.tri_leaf[g]]] do count += 1
			}
		}
	}
	return count
}

@(private = "file")
Hd_Edge :: [6]u32 // an edge's two ends, bit for bit

@(private = "file")
hd_count_edges :: proc(edges: ^map[Hd_Edge]int, m: ^geom.Mesh, f: u32) {
	for c in u32(0) ..< 3 {
		ends := [2]Vec3{m.positions[m.indices[3 * f + c]], m.positions[m.indices[3 * f + (c + 1) % 3]]}
		edges[transmute(Hd_Edge)ends] += 1
	}
}

// The window and the top level drawn around it close up: every edge of either runs the
// other way in a triangle of one of them, between the same points bit for bit, so
// drawing them leaves no pinholes.
@(test)
hd_window_meets_the_top_level_exactly :: proc(t: ^testing.T) {
	for steps in 1 ..= HD_MAX_STEPS {
		l := hd_make(3, steps)
		defer levels_destroy(&l)
		testing.expect(t, levels_hd_enter(&l, {0, 0, 1}, 1500 << uint(2 * steps - 2)), "no window")
		top := &l.levels[0].sculptor
		covered := make([]bool, len(top.nodes), context.temp_allocator)
		for id in l.hd.region.nodes do covered[id] = true
		edges := make(map[Hd_Edge]int, 4096, context.temp_allocator)
		window := &l.hd.window.mesh
		for f in 0 ..< u32(len(window.indices) / 3) do hd_count_edges(&edges, window, f)
		for f in 0 ..< u32(len(top.mesh.indices) / 3) {
			if !covered[top.node_of[top.bvh.tri_leaf[f]]] do hd_count_edges(&edges, top.mesh, f)
		}
		open := 0
		for e in edges {
			back := Hd_Edge{e[3], e[4], e[5], e[0], e[1], e[2]}
			open += int(back not_in edges)
		}
		testing.expectf(t, open == 0, "steps %d: %d edges with nothing on the other side", steps, open)
	}
}

// Detail stored from one window decodes to what that window showed, and to the same
// bits in every other window that covers it.
@(test)
hd_detail_carries_between_windows :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l := hd_make(3, 2, pool = &pool)
	defer levels_destroy(&l)
	a := linalg.normalize(Vec3{0.2, 0.1, 1})
	testing.expect(t, levels_hd_enter(&l, a, 3000), "no first window")
	unsculpted := hd_positions(&l)
	for _ in 0 ..< 3 do testing.expect(t, hd_dab(&l, a, 0.15) > 0, "dab moved nothing")
	_ = sculptor_flush(&l.hd.window.sculptor)
	sculpted := hd_positions(&l)
	moved := 0
	for key, p in sculpted do moved += int(p != unsculpted[key])
	testing.expect(t, moved > 50, "the dabs should move the surface")
	levels_hd_leave(&l)
	st := levels_hd_stats(&l)
	testing.expect(t, st.stored_nodes > 0 && st.stored_nodes < len(l.levels[0].sculptor.nodes), "only sculpted nodes should store detail")

	// The same window again shows what was sculpted, to within rounding. A vertex
	// stored by several nodes has the same detail in each.
	testing.expect(t, levels_hd_enter(&l, a, 3000), "no second window")
	again := hd_positions(&l)
	copies := make(map[u32]Vec3, 1024, context.temp_allocator)
	mismatched, shared_copies := 0, 0
	for id, j in l.hd.region.nodes {
		store := l.hd.detail[id]
		if store == nil do continue
		for w, i in node_list(l.hd.region.lists, u32(j)) {
			if d, seen := copies[w]; seen {
				shared_copies += 1
				mismatched += int(d != store[i])
			} else {
				copies[w] = store[i]
			}
		}
	}
	testing.expect(t, shared_copies > 0, "no vertex stored twice")
	testing.expect_value(t, mismatched, 0)
	testing.expect_value(t, len(again), len(sculpted))
	for key, p in again {
		if d := linalg.length(p - sculpted[key]); d > 1e-6 {
			testing.expectf(t, false, "node %d vertex %d came back %v off", key.node, key.index, d)
			break
		}
	}
	levels_hd_leave(&l)
	testing.expect_value(t, levels_hd_stats(&l).stored_nodes, st.stored_nodes)

	// A window shifted to one side decodes exactly the same bits where the two overlap.
	testing.expect(t, levels_hd_enter(&l, linalg.normalize(Vec3{-0.3, 0, 1}), 3000), "no shifted window")
	shifted := hd_positions(&l)
	shared, raised := 0, 0
	for key, p in shifted {
		q, ok := again[key]
		if !ok do continue
		shared += 1
		raised += int(p != unsculpted[key])
		if p != q {
			testing.expectf(t, false, "node %d vertex %d: %v in one window, %v in the other", key.node, key.index, q, p)
			break
		}
	}
	testing.expect(t, shared > 100, "the windows should overlap")
	testing.expect(t, raised > 0, "the overlap should include sculpted vertices")
	levels_hd_leave(&l)
	testing.expect_value(t, levels_hd_stats(&l).stored_nodes, st.stored_nodes)
}

// Brushes leave the border alone, and a stroke that is undone stores nothing.
@(test)
hd_border_is_frozen :: proc(t: ^testing.T) {
	l := hd_make(3, 1)
	defer levels_destroy(&l)
	testing.expect(t, levels_hd_enter(&l, {0, 0, 1}, 800), "no window")
	lv := l.hd.window
	before := hd_positions(&l, with_border = true)
	sculptor_stroke_begin(&lv.sculptor)
	for p, w in lv.mesh.positions {
		if lv.sculptor.fade[w] == 0 do _ = hd_dab(&l, p, 0.3)
	}
	testing.expect(t, sculptor_stroke_end(&lv.sculptor), "the stroke changed nothing")
	after := hd_positions(&l, with_border = true)
	inside := 0
	for key, p in after {
		w := node_list(l.hd.region.lists, u32(index_of(l.hd.region.nodes, key.node)))[key.index]
		if lv.sculptor.fade[w] == 0 {
			testing.expect(t, p == before[key], "a border vertex moved")
		} else {
			inside += int(p != before[key])
		}
	}
	testing.expect(t, inside > 0, "nothing inside the border moved")
	testing.expect(t, sculptor_undo(&lv.sculptor), "no undo")
	levels_hd_leave(&l)
	testing.expect_value(t, levels_hd_stats(&l).stored_nodes, 0)
}

// Brushes fade out toward the border, so a stroke across it leaves a slope: they barely
// move the vertices beside it, and strengthen smoothly further in.
@(test)
hd_brushes_fade_toward_the_border :: proc(t: ^testing.T) {
	l := hd_make(5, 1, 128)
	defer levels_destroy(&l)
	testing.expect(t, levels_hd_enter(&l, {0, 0, 1}, 20_000), "no window") // about half the sphere
	lv := l.hd.window
	m := &lv.mesh
	fade := lv.sculptor.fade
	full, steepest, beside := 0, 0, 0
	for f in 0 ..< len(m.indices) / 3 {
		c := m.indices[3 * f:][:3]
		on_border := fade[c[0]] == 0 || fade[c[1]] == 0 || fade[c[2]] == 0
		for i in 0 ..< 3 {
			steepest = max(steepest, abs(int(fade[c[i]]) - int(fade[c[(i + 1) % 3]])))
			if on_border do beside = max(beside, int(fade[c[i]]))
		}
	}
	for x in fade do full += int(x == 255)
	testing.expect(t, full > len(fade) / 4, "too little of the window at full strength")
	testing.expectf(t, steepest <= 48, "fade steps by %d between neighbours", steepest)
	testing.expectf(t, beside > 0 && beside <= 26, "brushes move vertices beside the border at %d/255", beside)
	levels_hd_leave(&l)
}

@(private = "file")
index_of :: proc(values: []u32, x: u32) -> int {
	for v, i in values do if v == x do return i
	return -1
}

// Sculpted HD detail rides on a later change of the top level: the bump keeps its
// height above the surface it sits on.
@(test)
hd_detail_rides_on_the_top_level :: proc(t: ^testing.T) {
	l := hd_make(4, 1, 128)
	defer levels_destroy(&l)
	at := Vec3{0, 0, 1}
	testing.expect(t, levels_hd_enter(&l, at, 4000), "no window")
	_ = hd_dab(&l, at, 0.06)
	levels_hd_leave(&l)
	height :: proc(l: ^Levels) -> (h: f32) {
		lv := l.hd.window
		base := Loop_Base{l.hd.region.below.positions[:], l.hd.region.below.indices[:], l.hd.region.below.faces}
		for p, w in lv.mesh.positions {
			if lv.sculptor.fade[w] == 0 do continue
			f := frame_at(&base, lv.parents[w])
			h = max(h, dot(p - f.origin, f.n))
		}
		return
	}
	testing.expect(t, levels_hd_enter(&l, at, 4000), "no window")
	before := height(&l)
	testing.expect(t, before > 0.001, "no bump")
	levels_hd_leave(&l)

	// A broad push on the top level under the bump.
	top := &l.levels[0].sculptor
	for _ in 0 ..< 4 do _ = apply_dab(top, {kind = .Draw, radius = 0.6, strength = 1}, at)
	_ = sculptor_flush(top)
	testing.expect(t, levels_hd_enter(&l, at, 4000), "no window after the top level moved")
	after := height(&l)
	testing.expectf(t, abs(after - before) < 1e-4, "bump height %v before, %v after", before, after)
	peak: f32
	for p in l.hd.window.mesh.positions do peak = max(peak, linalg.length(p))
	testing.expect(t, peak > 1.05, "the window should follow the top level's push")
}

@(test)
hd_steps_rules :: proc(t: ^testing.T) {
	m := geom.icosphere(2)
	remove_range(&m.indices, 0, 3)
	open: Levels
	levels_init(&open, m, nil, 64)
	defer levels_destroy(&open)
	testing.expect(t, !levels_hd_set_steps(&open, 1), "an open mesh got an HD level")
	testing.expect(t, !levels_hd_enter(&open, {0, 0, 1}), "a window without an HD level")

	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	assert(levels_subdivide(&l))
	testing.expect(t, levels_hd_set_steps(&l, 2), "no HD level")
	testing.expect(t, !levels_subdivide(&l), "subdivided under an HD level")
	testing.expect_value(t, levels_hd_vertices(&l), 10242) // two Loop steps above 642 vertices
	testing.expect(t, levels_hd_set_steps(&l, 1), "steps cannot change while nothing is stored")
	testing.expect(t, levels_hd_enter(&l, {0, 0, 1}, 2000), "no window")
	testing.expect(t, levels_active(&l) == l.hd.window, "the window is not the active level")
	testing.expect(t, !levels_hd_set_steps(&l, 2), "steps changed with a window open")
	_ = hd_dab(&l, {0, 0, 1}, 0.2)
	levels_hd_leave(&l)
	testing.expect(t, levels_hd_stats(&l).stored_nodes > 0, "nothing stored")
	testing.expect(t, !levels_hd_set_steps(&l, 2), "steps changed with detail stored")

	// Deleting the top level from below takes the HD level with it.
	levels_set_current(&l, 0)
	levels_delete_higher(&l)
	testing.expect_value(t, l.hd.steps, 0)
	testing.expect_value(t, levels_hd_stats(&l).stored_nodes, 0)
	testing.expect(t, levels_hd_set_steps(&l, 1), "no HD level on the new top")
	levels_hd_delete(&l)
	testing.expect_value(t, l.hd.steps, 0)
}

// The top level hides exactly the window's chunks, and every simplification group over
// one of them.
@(test)
hd_hides_covered_chunks_and_groups :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(7), nil) // over LOD_MIN_TRIANGLES, so it has groups
	defer levels_destroy(&l)
	assert(levels_hd_set_steps(&l, 1))
	s := &l.levels[0].sculptor
	testing.expect(t, len(s.lod.tree.groups) > 0, "no simplification groups")
	testing.expect(t, levels_hd_enter(&l, {0, 0, 1}, 50_000), "no window")
	hidden := levels_hd_hidden(&l)
	nodes := len(s.nodes)
	testing.expect_value(t, len(hidden), nodes + len(s.lod.tree.groups))
	covered := make([]bool, nodes, context.temp_allocator)
	for id in l.hd.region.nodes do covered[id] = true
	for c, id in covered do testing.expect_value(t, hidden[id], c)
	for g, i in s.lod.tree.groups {
		over := false
		under := make([dynamic]u32, context.temp_allocator)
		append(&under, u32(nodes + i))
		_ = g
		for len(under) > 0 {
			unit := pop(&under)
			if int(unit) < nodes {
				over ||= covered[unit]
				continue
			}
			sub := s.lod.tree.groups[int(unit) - nodes]
			append(&under, ..s.lod.tree.units[sub.child_first:][:sub.child_count])
		}
		testing.expect_value(t, hidden[nodes + i], over)
	}
	levels_hd_leave(&l)
	testing.expect(t, levels_hd_hidden(&l) == nil, "hidden after leaving")
}

// Distance from p to triangle f of the mesh.
@(private = "file")
distance_to_triangle :: proc(m: geom.Mesh, f: u32, p: Vec3) -> f32 {
	a, b, c := m.positions[m.indices[3 * f]], m.positions[m.indices[3 * f + 1]], m.positions[m.indices[3 * f + 2]]
	// Closest point by regions (Ericson, Real-Time Collision Detection 5.1.5).
	ab, ac, ap := b - a, c - a, p - a
	d1, d2 := linalg.dot(ab, ap), linalg.dot(ac, ap)
	if d1 <= 0 && d2 <= 0 do return linalg.length(p - a)
	bp := p - b
	d3, d4 := linalg.dot(ab, bp), linalg.dot(ac, bp)
	if d3 >= 0 && d4 <= d3 do return linalg.length(p - b)
	vc := d1 * d4 - d3 * d2
	if vc <= 0 && d1 >= 0 && d3 <= 0 do return linalg.length(p - (a + ab * (d1 / (d1 - d3))))
	cp := p - c
	d5, d6 := linalg.dot(ab, cp), linalg.dot(ac, cp)
	if d6 >= 0 && d5 <= d6 do return linalg.length(p - c)
	vb := d5 * d2 - d1 * d6
	if vb <= 0 && d2 >= 0 && d6 <= 0 do return linalg.length(p - (a + ac * (d2 / (d2 - d6))))
	va := d3 * d6 - d5 * d4
	if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 do return linalg.length(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))))
	denom := 1 / (va + vb + vc)
	return linalg.length(p - (a + ab * (vb * denom) + ac * (vc * denom)))
}
