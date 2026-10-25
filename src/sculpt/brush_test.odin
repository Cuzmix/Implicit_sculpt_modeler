package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(test)
raycast_hits_front_of_sphere :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	hit, ok := raycast(m, {0, 0, 5}, {0, 0, -1})
	testing.expect(t, ok, "ray missed")
	testing.expect(t, math.abs(hit.z - 1) < 0.01, "hit is not on the near side")
	_, miss := raycast(m, {0, 3, 5}, {0, 0, -1})
	testing.expect(t, !miss, "ray above the sphere should miss")
}

@(test)
draw_dab_raises_only_inside_radius :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := make([]Vec3, len(m.positions), context.temp_allocator)
	copy(before, m.positions[:])
	_ = sculptor_flush(&s)

	center := Vec3{0, 0, 1}
	moved := apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1}, center)
	testing.expect(t, moved > 0, "dab moved nothing")
	for p, i in m.positions {
		dist := linalg.length(before[i] - center)
		if dist >= 0.3 {
			testing.expect_value(t, p, before[i])
		} else if dist < 0.1 {
			testing.expect(t, linalg.length(p) > 1, "vertex near the centre was not pushed out")
		}
	}

	ranges := sculptor_flush(&s)
	covered: u32
	for r in ranges do covered += r.count
	testing.expect(t, covered > 0 && covered < u32(len(m.positions)), "dirty ranges should be partial")
	for i in 0 ..< u32(len(m.positions)) {
		if m.positions[i] == before[i] do continue
		inside := false
		for r in ranges do inside ||= i >= r.first && i < r.first + r.count
		testing.expect(t, inside, "moved vertex outside the dirty ranges")
	}
	testing.expect_value(t, len(sculptor_flush(&s)), 0)
}

@(test)
nodes_own_contiguous_vertex_ranges :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 128)
	defer sculptor_destroy(&s)
	next: u32
	for n in s.nodes {
		testing.expect_value(t, n.vert_first, next)
		next += n.vert_count
	}
	testing.expect_value(t, int(next), len(m.positions))

	// A leaf's triangles use exactly its owned and shared vertices, and the owner list
	// names the node owning each shared vertex.
	for leaf, b_index in s.bvh.nodes {
		if leaf.count == 0 do continue
		id := s.node_of[b_index]
		n := s.nodes[id]
		shared := s.shared[n.shared_first:][:n.shared_count]
		owners := s.owners[n.owner_first:][:n.owner_count]
		for k in leaf.first ..< leaf.first + leaf.count {
			for c in 0 ..< u32(3) {
				v := m.indices[3 * k + c]
				if v >= n.vert_first && v < n.vert_first + n.vert_count do continue
				_, found := slice.linear_search(shared, v)
				testing.expect(t, found, "triangle vertex is neither owned nor shared")
			}
		}
		for v in shared {
			owner := owner_node(s.nodes, v)
			_, found := slice.linear_search(owners, owner)
			testing.expect(t, found && owner != id, "shared vertex owner missing")
		}
	}
}

// After any sequence of dabs, incremental normals and BVH bounds must equal a full
// recompute, and the parallel path must give the same mesh as the serial one.
@(test)
incremental_updates_match_full_recompute :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)

	run :: proc(pool: ^jobs.Pool) -> geom.Mesh {
		m := geom.icosphere(5)
		s: Sculptor
		sculptor_init(&s, &m, pool, 96)
		defer sculptor_destroy(&s)
		for i in 0 ..< 40 {
			a := f32(i) * 0.37
			center := linalg.normalize(Vec3{math.cos(a), 0.3 * math.sin(3 * a), math.sin(a)})
			kind := Brush_Kind.Smooth if i % 4 == 3 else .Draw
			apply_dab(&s, {kind = kind, radius = 0.12 + 0.1 * f32(i % 3), strength = 0.8, invert = i % 5 == 0}, center)
			if i % 3 == 2 do sculptor_flush(&s)
		}
		sculptor_flush(&s)
		for node in s.bvh.nodes {
			if node.count == 0 do continue
			want := geom.leaf_bounds(s.bvh, m, node)
			if node.bounds != want do panic("stale leaf bounds after dabs")
		}
		return m
	}
	serial := run(nil)
	defer geom.mesh_destroy(&serial)
	parallel := run(&pool)
	defer geom.mesh_destroy(&parallel)
	for p, i in serial.positions {
		testing.expect_value(t, parallel.positions[i], p)
	}

	full := geom.Mesh{
		positions = slice_to_dynamic(serial.positions[:]),
		normals = make([dynamic]Vec3, len(serial.normals)),
		indices = slice_to_dynamic(serial.indices[:]),
	}
	defer geom.mesh_destroy(&full)
	geom.mesh_recompute_normals(&full)
	for n, i in serial.normals {
		testing.expect(t, linalg.dot(n, full.normals[i]) > 0.99999, "stale normal after dabs")
	}
}

// After every flush, every vertex normal is what a recompute from scratch gives, so
// updating only the border vertices of nodes next to moved ones misses none.
@(test)
flush_leaves_no_stale_normal :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	// Start from face-weighted normals everywhere, as the flush computes them.
	for id in 0 ..< len(s.nodes) do mark_stale(&s, u32(id), .Shape)
	_ = sculptor_flush(&s)
	for i in 0 ..< 30 {
		a := f32(i) * 0.41
		center := linalg.normalize(Vec3{math.cos(a), 0.5 * math.sin(2 * a), math.sin(a)})
		kind := Brush_Kind.Smooth if i % 4 == 3 else .Draw
		_ = apply_dab(&s, {kind = kind, radius = 0.05 + 0.04 * f32(i % 4), strength = 0.9}, center)
		if i % 2 == 0 do continue
		_ = sculptor_flush(&s)
		for v in 0 ..< u32(len(m.positions)) {
			sum: Vec3
			for f in geom.vertex_faces_of(s.faces, v) do sum += face_normal(s.mesh, f)
			if m.normals[v] != linalg.normalize0(sum) {
				testing.expectf(t, false, "stale normal at vertex %d after dab %d", v, i)
				return
			}
		}
	}
}

// During a stroke a changed chunk keeps current bounds but an open cone. Once the
// stroke ends, flushes work out the cones CONE_BATCH at a time, giving every chunk
// what a rebuild from scratch gives.
@(test)
cones_wait_for_the_end_of_a_stroke :: proc(t: ^testing.T) {
	m := geom.icosphere(6)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 32)
	defer sculptor_destroy(&s)
	sculptor_stroke_begin(&s)
	for k in 0 ..< 24 {
		a := f32(k) * 0.26
		_ = apply_dab(&s, {kind = .Draw, radius = 0.5, strength = 1}, Vec3{math.cos(a), 0, math.sin(a)})
		_ = sculptor_flush(&s)
	}
	open := 0
	for c, id in s.chunks {
		testing.expect_value(t, c.bounds, s.bvh.nodes[s.nodes[id].leaf].bounds)
		if c.cone_cutoff >= 1 do open += 1
	}
	testing.expect(t, open > CONE_BATCH && open < len(s.chunks), "the stroke's chunks, and only those, should have open cones")
	_ = sculptor_stroke_end(&s)
	flushes := 0
	for len(s.waiting_cones) > 0 && flushes < 100 {
		before := len(s.waiting_cones)
		_ = sculptor_flush(&s)
		testing.expect_value(t, before - len(s.waiting_cones), min(before, CONE_BATCH))
		flushes += 1
	}
	testing.expect(t, flushes > 1, "the cones should take more than one flush")
	got := slice.clone(s.chunks, context.temp_allocator)
	for id in 0 ..< len(s.nodes) do update_chunk(&s, u32(id), nil)
	for c, id in got do testing.expect_value(t, c, s.chunks[id])
}

@(private = "file")
slice_to_dynamic :: proc(s: $S/[]$T) -> [dynamic]T {
	d := make([dynamic]T, len(s))
	copy(d[:], s)
	return d
}

@(test)
smooth_dab_reduces_bump :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)

	center := Vec3{0, 0, 1}
	for _ in 0 ..< 5 do apply_dab(&s, {kind = .Draw, radius = 0.25, strength = 1}, center)
	peak_before := max_radius(m)
	for _ in 0 ..< 10 do apply_dab(&s, {kind = .Smooth, radius = 0.4, strength = 1}, center)
	testing.expect(t, max_radius(m) < peak_before, "smoothing did not lower the bump")
}

@(private = "file")
max_radius :: proc(m: geom.Mesh) -> f32 {
	r: f32
	for p in m.positions do r = max(r, linalg.length(p))
	return r
}

@(test)
bvh_raycast_matches_brute_force_after_sculpting :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	geom.mesh_sort_vertices_spatially(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)

	// Sculpt a few strong dabs so refit has real work to get right.
	for i in 0 ..< 20 {
		a := f32(i) * 0.3
		apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1, invert = i % 3 == 0}, linalg.normalize(Vec3{math.cos(a), 0.4, math.sin(a)}))
	}

	misses := 0
	for i in 0 ..< 500 {
		a, b := f32(i) * 0.61803, f32(i) * 0.2914
		origin := 4 * Vec3{math.cos(a) * math.cos(b), math.sin(b), math.sin(a) * math.cos(b)}
		target := Vec3{math.sin(f32(i)), math.cos(f32(i) * 1.3), math.sin(f32(i) * 0.7)} * 1.2
		dir := linalg.normalize(target - origin)
		want, want_ok := raycast(m, origin, dir)
		got, got_ok := sculptor_raycast(&s, origin, dir)
		testing.expect_value(t, got_ok, want_ok)
		if want_ok && got_ok {
			testing.expect(t, linalg.length(got - want) < 1e-4, "BVH hit differs from brute force")
		}
		if !want_ok do misses += 1
	}
	testing.expect(t, misses > 0 && misses < 500, "rays should include hits and misses")
}

@(test)
bvh_gather_matches_linear_scan :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)

	center := linalg.normalize(Vec3{0.3, 0.5, 0.8})
	radius: f32 = 0.27
	expected := 0
	for p in m.positions {
		if linalg.length(p - center) < radius do expected += 1
	}
	got := apply_dab(&s, {kind = .Smooth, radius = radius, strength = 0}, center)
	testing.expect_value(t, got, expected)
}

// Culling may skip a chunk only if none of its triangles could be drawn: every
// triangle facing the eye with a corner inside the view must be in a drawn range.
@(test)
culling_keeps_every_visible_triangle :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_ = sculptor_chunk_groups(&s) // made now, so the dabs must keep them current
	for k in 0 ..< 20 {
		a := f32(k) * 0.3
		_ = apply_dab(&s, {kind = .Draw, radius = 0.25, strength = 1, invert = k % 3 == 0}, linalg.normalize(Vec3{math.cos(a), 0.4, math.sin(a)}))
	}
	_ = sculptor_flush(&s)
	groups := sculptor_chunk_groups(&s)
	testing.expect(t, len(groups) > 2, "too few chunk groups to test")
	for g, k in groups {
		lo := k * geom.CHUNK_GROUP
		testing.expect_value(t, g, geom.chunk_group(s.chunks[lo:min(lo + geom.CHUNK_GROUP, len(s.chunks))]))
	}

	// Incremental chunks match chunks built from scratch.
	fresh := make([]geom.Chunk, len(s.nodes), context.temp_allocator)
	copy(fresh, s.chunks)
	for id in 0 ..< len(s.nodes) do update_chunk(&s, u32(id), nil)
	for c, id in fresh do testing.expect_value(t, c, s.chunks[id])

	eyes := [?]Vec3{{0, 0, 3.5}, {2, 1.5, -2}, {0, 0, 1.3}, {0.3, 0.2, 0.1}}
	out: [dynamic]geom.Index_Range
	defer delete(out)
	culled_any := false
	for eye in eyes {
		view := look_at(eye, {0, 0, 0} if eye != {0.3, 0.2, 0.1} else {1, 0, 0})
		f := 1 / math.tan(f32(0.35))
		proj := geom.Mat4{f, 0, 0, 0, 0, f, 0, 0, 0, 0, -1, -0.01, 0, 0, -1, 0}
		clip := proj * view
		clear(&out)
		stats := geom.cull_chunks(s.chunks, clip, eye, &out)
		culled_any ||= stats.frustum + stats.backface > 0
		// A group at a time gives the same ranges.
		grouped: [dynamic]geom.Index_Range
		defer delete(grouped)
		_ = geom.cull_chunks_grouped(s.chunks, groups, clip, eye, &grouped)
		testing.expectf(t, slice.equal(out[:], grouped[:]), "eye %v: %d ranges by groups, %d chunk by chunk", eye, len(grouped), len(out))
		drawn := make([]bool, len(m.indices) / 3, context.temp_allocator)
		for r in out do for tri in r.first_index / 3 ..< (r.first_index + r.index_count) / 3 do drawn[tri] = true
		for tri in 0 ..< len(m.indices) / 3 {
			p0, p1, p2 := m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]
			n := linalg.cross(p1 - p0, p2 - p0)
			if linalg.dot(n, p0 - eye) >= 0 do continue // faces away
			inside := false
			for p in ([3]Vec3{p0, p1, p2}) {
				c := clip * [4]f32{p.x, p.y, p.z, 1}
				inside ||= c.w > 0 && abs(c.x) <= c.w && abs(c.y) <= c.w && c.z >= 0 && c.z <= c.w
			}
			if inside && !drawn[tri] {
				testing.expectf(t, false, "visible triangle %d culled from eye %v", tri, eye)
				return
			}
		}
	}
	testing.expect(t, culled_any, "nothing was ever culled")
}

@(private = "file")
look_at :: proc(eye, target: Vec3) -> geom.Mat4 {
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
