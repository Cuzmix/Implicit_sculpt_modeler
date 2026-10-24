package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
levels_make :: proc(subdiv, steps: int, pool: ^jobs.Pool = nil) -> Levels {
	l: Levels
	levels_init(&l, geom.icosphere(subdiv), pool, 64)
	for _ in 0 ..< steps do assert(levels_subdivide(&l))
	return l
}

@(private = "file")
draw :: proc(l: ^Levels, center: Vec3, radius: f32, strength: f32 = 1, kind := Brush_Kind.Draw) -> int {
	return apply_dab(&levels_current(l).sculptor, {kind = kind, radius = radius, strength = strength}, center)
}

// Switches level and brings its normals up to date, as the app's next frame would.
@(private = "file")
switch_to :: proc(l: ^Levels, index: int) {
	levels_set_current(l, index)
	_ = sculptor_flush(&levels_current(l).sculptor)
}

@(private = "file")
snapshot :: proc(l: ^Levels) -> [][]Vec3 {
	out := make([][]Vec3, len(l.levels), context.temp_allocator)
	for lv, j in l.levels do out[j] = slice.clone(lv.mesh.positions[:], context.temp_allocator)
	return out
}

@(private = "file")
max_distance :: proc(a, b: []Vec3) -> f32 {
	d: f32
	for p, i in a do d = max(d, linalg.length(p - b[i]))
	return d
}

// Every vertex above the base is where its parents and detail put it, to within the
// rounding of re-encoding its detail.
@(private = "file")
expect_decoded :: proc(t: ^testing.T, l: ^Levels, loc := #caller_location) {
	for j in 1 ..< len(l.levels) {
		lv, below := l.levels[j], level_base(l.levels[j - 1])
		for p, u in lv.mesh.positions {
			off := linalg.length(p - frame_point(frame_at(&below, lv.parents[u]), lv.detail[u]))
			if off > 1e-6 {
				testing.expectf(t, false, "level %d vertex %d is %v off its decoded position", j, u, off, loc = loc)
				return
			}
		}
	}
}

@(test)
subdivide_builds_loop_levels :: proc(t: ^testing.T) {
	l := levels_make(2, 2)
	defer levels_destroy(&l)
	testing.expect_value(t, len(l.levels), 3)
	testing.expect_value(t, l.current, 2)
	want_vertices := [3]int{162, 642, 2562}
	for lv, j in l.levels {
		m := &lv.mesh
		testing.expect_value(t, len(m.positions), want_vertices[j])
		testing.expect_value(t, len(m.indices) / 3, 320 * (1 << uint(2 * j)))
		// Closed and consistently oriented: each directed edge once, and its reverse too.
		r := geom.mesh_check(m^)
		testing.expectf(t, r.closed, "level %d: %v", j, r)
		// Loop subdivision of the unit icosphere stays just inside the unit sphere.
		for p in m.positions {
			r := linalg.length(p)
			testing.expect(t, r > 0.9 && r <= 1.0001, "subdivided vertex strayed from the sphere")
		}
		for n, i in m.normals do testing.expect(t, linalg.dot(n, linalg.normalize(m.positions[i])) > 0.95, "normal not outward")
	}
	expect_decoded(t, &l)
	_, _, bytes := levels_subdivide_estimate(&l)
	testing.expect(t, bytes > 10242 * 60, "estimate too small")
}

@(test)
open_mesh_cannot_subdivide :: proc(t: ^testing.T) {
	m := geom.icosphere(1)
	remove_range(&m.indices, 0, 3) // a hole: three edges with one triangle each
	l: Levels
	levels_init(&l, m, nil, 16)
	defer levels_destroy(&l)
	testing.expect(t, !levels_subdivide(&l), "an open mesh was subdivided")
	testing.expect_value(t, len(l.levels), 1)
}

// A wide edit on the top level moves the levels below with it; switching back shows
// the edit as it was sculpted.
@(test)
fine_edit_moves_coarse_levels :: proc(t: ^testing.T) {
	l := levels_make(3, 2)
	defer levels_destroy(&l)
	base_before := slice.clone(l.levels[0].mesh.positions[:], context.temp_allocator)
	center := Vec3{0, 0, 1}
	for _ in 0 ..< 3 do testing.expect(t, draw(&l, center, 0.5) > 0, "dab moved nothing")
	_ = sculptor_flush(&levels_current(&l).sculptor)
	sculpted := slice.clone(l.levels[2].mesh.positions[:], context.temp_allocator)

	switch_to(&l, 0)
	base := l.levels[0].mesh.positions[:]
	raised, far_moved := 0, 0
	for p, i in base {
		d := linalg.length(base_before[i] - center)
		if d < 0.25 && linalg.length(p) > linalg.length(base_before[i]) + 0.05 do raised += 1
		if d > 0.8 && p != base_before[i] do far_moved += 1
	}
	testing.expect(t, raised > 5, "the base did not follow the edit")
	testing.expect_value(t, far_moved, 0)
	expect_decoded(t, &l)

	switch_to(&l, 2)
	testing.expect(t, slice.equal(l.levels[2].mesh.positions[:], sculpted), "the top level changed on the way down and back")
}

// Detail sculpted on the top level rides on an edit made on the base.
@(test)
coarse_edit_keeps_fine_detail :: proc(t: ^testing.T) {
	l := levels_make(3, 2)
	defer levels_destroy(&l)
	spot := linalg.normalize(Vec3{0.2, 0.1, 1})
	for _ in 0 ..< 4 do draw(&l, spot, 0.06)
	switch_to(&l, 0)
	top := l.levels[2]
	detail := slice.clone(top.detail, context.temp_allocator)
	before := slice.clone(top.mesh.positions[:], context.temp_allocator)
	peak := nearest_vertex(top, spot)
	bump := bump_height(top, peak)
	testing.expect(t, bump > 0.005, "no bump to keep")

	for _ in 0 ..< 4 do draw(&l, {0, 0, 1}, 0.7)
	switch_to(&l, 2)
	testing.expect(t, slice.equal(top.detail, detail), "detail changed by an edit below")
	testing.expect(t, max_distance(top.mesh.positions[:], before) > 0.1, "the top level did not follow the base")
	testing.expect(t, abs(bump_height(top, peak) - bump) < 0.1 * bump, "the bump did not survive")
	expect_decoded(t, &l)
}

@(private = "file")
nearest_vertex :: proc(lv: ^Level, spot: Vec3) -> u32 {
	best, nearest := max(f32), u32(0)
	for p, i in lv.mesh.positions {
		if d := linalg.length(linalg.normalize(p) - spot); d < best do best, nearest = d, u32(i)
	}
	return nearest
}

// How far a vertex stands out from the vertices up to two edges away, along its normal.
@(private = "file")
bump_height :: proc(lv: ^Level, nearest: u32) -> f32 {
	m := &lv.mesh
	ring := make(map[u32]bool, 64, context.temp_allocator)
	ring[nearest] = true
	for _ in 0 ..< 2 {
		keys, _ := slice.map_keys(ring, context.temp_allocator)
		for v in keys do for f in geom.vertex_faces_of(lv.sculptor.faces, v) do for c in 0 ..< u32(3) do ring[m.indices[3 * f + c]] = true
	}
	sum: Vec3
	for v in ring do sum += m.positions[v]
	return linalg.dot(m.positions[nearest] - sum / f32(len(ring)), m.normals[nearest])
}

// A small edit on the top level reaches the base only softened.
@(test)
small_detail_stays_on_top :: proc(t: ^testing.T) {
	l := levels_make(3, 2)
	defer levels_destroy(&l)
	before := snapshot(&l)
	spot := linalg.normalize(Vec3{-0.3, 0.4, 0.8})
	for _ in 0 ..< 3 do draw(&l, spot, 0.05)
	top_moved := max_distance(l.levels[2].mesh.positions[:], before[2])
	switch_to(&l, 0)
	base_moved := max_distance(l.levels[0].mesh.positions[:], before[0])
	testing.expect(t, base_moved > 0 && base_moved < 0.6 * top_moved, "a small edit went down in full")
	expect_decoded(t, &l)
}

@(test)
switching_without_edits_changes_nothing :: proc(t: ^testing.T) {
	l := levels_make(2, 2)
	defer levels_destroy(&l)
	for i in 0 ..< 6 do draw(&l, linalg.normalize(Vec3{f32(i) - 2.5, 1, 2}), 0.3)
	switch_to(&l, 0)
	draw(&l, {1, 0, 0}, 0.6)
	switch_to(&l, 1)
	want := snapshot(&l)
	for j in ([?]int{2, 0, 1, 2, 1, 0}) {
		switch_to(&l, j)
		for lv, k in l.levels do testing.expect(t, slice.equal(lv.mesh.positions[:], want[k]), "a level moved without an edit")
	}
	expect_decoded(t, &l)
}

// Undoing strokes newest first, across levels, gives back the shape from before them.
@(test)
undo_across_levels :: proc(t: ^testing.T) {
	l := levels_make(3, 2)
	defer levels_destroy(&l)
	before := snapshot(&l)
	stroke :: proc(l: ^Levels, center: Vec3, radius: f32) {
		s := &levels_current(l).sculptor
		sculptor_stroke_begin(s)
		for k in 0 ..< 5 do draw(l, center + Vec3{0.03 * f32(k), 0, 0}, radius)
		_ = sculptor_stroke_end(s)
		_ = sculptor_flush(s)
	}
	stroke(&l, {0, 0, 1}, 0.3)
	switch_to(&l, 0)
	stroke(&l, linalg.normalize(Vec3{0, 0.5, 1}), 0.6)
	switch_to(&l, 1)
	stroke(&l, linalg.normalize(Vec3{0.5, 0, 1}), 0.2)

	for j in ([?]int{1, 0, 2}) {
		switch_to(&l, j)
		testing.expect(t, sculptor_undo(&levels_current(&l).sculptor), "nothing to undo")
		_ = sculptor_flush(&levels_current(&l).sculptor)
	}
	switch_to(&l, 0)
	for lv, j in l.levels {
		testing.expectf(t, max_distance(lv.mesh.positions[:], before[j]) < 1e-5, "level %d not back to its shape", j)
	}
	expect_decoded(t, &l)
}

@(test)
delete_higher_and_lower_levels :: proc(t: ^testing.T) {
	l := levels_make(2, 3)
	defer levels_destroy(&l)
	switch_to(&l, 1)
	levels_delete_higher(&l)
	testing.expect_value(t, len(l.levels), 2)
	testing.expect_value(t, l.current, 1)
	testing.expect(t, levels_subdivide(&l), "subdivide after deleting higher levels")
	switch_to(&l, 1)
	draw(&l, {0, 1, 0}, 0.4)
	levels_delete_lower(&l)
	testing.expect_value(t, len(l.levels), 2)
	testing.expect_value(t, l.current, 0)
	base := l.levels[0]
	testing.expect_value(t, len(base.mesh.positions), 642)
	testing.expect(t, base.parents == nil && base.detail == nil, "new base still linked below")
	expect_decoded(t, &l)
	testing.expect(t, levels_subdivide(&l), "subdivide after deleting lower levels")
	expect_decoded(t, &l)
}

// After syncs, every level's BVH bounds and normals are what a rebuild would give.
@(test)
synced_levels_stay_consistent :: proc(t: ^testing.T) {
	l := levels_make(3, 2)
	defer levels_destroy(&l)
	sculptor_recompute_all(&l.levels[0].sculptor) // the icosphere's normals are exact, not face-weighted
	for i in 0 ..< 12 {
		a := f32(i) * 0.7
		switch_to(&l, i % 3)
		kind := Brush_Kind.Smooth if i % 4 == 3 else .Draw
		draw(&l, linalg.normalize(Vec3{math.cos(a), 0.3, math.sin(a)}), 0.1 + 0.1 * f32(i % 3), 0.8, kind)
		_ = sculptor_flush(&levels_current(&l).sculptor)
	}
	switch_to(&l, 0)
	for lv, lv_index in l.levels {
		s := &lv.sculptor
		_ = sculptor_flush(s)
		for node in s.bvh.nodes {
			if node.count > 0 && node.bounds != geom.leaf_bounds(s.bvh, lv.mesh, node) {
				testing.expect(t, false, "stale leaf bounds after a sync")
				break
			}
		}
		for v in 0 ..< u32(len(lv.mesh.positions)) {
			sum: Vec3
			for f in geom.vertex_faces_of(s.faces, v) do sum += face_normal(s.mesh, f)
			if lv.mesh.normals[v] != linalg.normalize0(sum) {
				testing.expectf(t, false, "stale normal after a sync: level %d vertex %d node %d got %v want %v", lv_index, v, lv.node_of_vertex[v], lv.mesh.normals[v], linalg.normalize0(sum))
				break
			}
		}
		testing.expect_value(t, len(s.edited_nodes), 0)
	}
	expect_decoded(t, &l)
}

// Threads only split the work: the levels come out bit for bit the same.
@(test)
parallel_levels_match_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> [][]Vec3 {
		l := levels_make(3, 2, pool)
		defer levels_destroy(&l)
		for i in 0 ..< 9 {
			a := f32(i) * 0.9
			switch_to(&l, (i * 2) % 3)
			for k in 0 ..< 3 do draw(&l, linalg.normalize(Vec3{math.cos(a + 0.05 * f32(k)), 0.2, math.sin(a)}), 0.35)
			_ = sculptor_flush(&levels_current(&l).sculptor)
		}
		switch_to(&l, 1)
		return snapshot(&l)
	}
	serial := run(nil)
	parallel := run(&pool)
	for level, j in serial do testing.expectf(t, slice.equal(level, parallel[j]), "level %d differs with threads", j)
}
