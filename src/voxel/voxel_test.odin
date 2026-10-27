package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// A unit sphere at the origin, `across` voxels across the domain's useful part: the voxel
// is 2 / across, so a sphere of radius 1 spans `across` voxels.
@(private = "file")
test_sphere :: proc(across: f32, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	return
}

@(private = "file")
test_dab :: proc(c: ^Clay, kind: Brush_Kind, at: Vec3, radius: f32, strength: f32 = 1, invert := false) -> int {
	return clay_dab(c, {kind = kind, radius = radius, strength = strength, invert = invert, normal = linalg.normalize0(at)}, at)
}

@(test)
sphere_fill_holds_distances_in_a_band_of_bricks_only :: proc(t: ^testing.T) {
	c := test_sphere(128)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	for dir in ([4]Vec3{{0, 0, 1}, {1, 0, 0}, linalg.normalize(Vec3{1, 1, 1}), linalg.normalize(Vec3{-2, 1, 3})}) {
		for d in ([5]f32{-2, -0.5, 0, 0.5, 2.5}) {
			p := dir * (1 + d * voxel)
			got := volume_sample(&c.volume, p)
			testing.expectf(t, math.abs(got - d) < 0.1, "at %v voxels along %v the field reads %v", d, dir, got)
		}
		// Deep inside and far outside are tiles, read as the clamp.
		testing.expect(t, volume_sample(&c.volume, dir * 0.5) <= -f32(CLAMP) / SCALE + 0.01, "the core is not inside")
		testing.expect(t, volume_sample(&c.volume, dir * 1.5) >= f32(CLAMP) / SCALE - 0.01, "the outside is not empty")
	}
	// A 128-voxel sphere's band is about its area in bricks, nowhere near the 4096 bricks of
	// the cube around it.
	bricks := volume_brick_count(&c.volume)
	testing.expectf(t, bricks > 500 && bricks < 2500, "%v bricks hold the band", bricks)
	testing.expectf(t, volume_bytes(&c.volume) < 4 << 20, "%v bytes for a 128-voxel sphere", volume_bytes(&c.volume))
}

@(test)
raycast_hits_the_sphere_where_the_ray_enters_it :: proc(t: ^testing.T) {
	c := test_sphere(128)
	defer clay_destroy(&c)
	hit, normal, ok := clay_raycast(&c, {0, 0, 5}, {0, 0, -1})
	testing.expect(t, ok, "the ray missed the sphere")
	testing.expectf(t, math.abs(hit.z - 1) < 0.02 && math.abs(hit.x) < 1e-4 && math.abs(hit.y) < 1e-4, "hit at %v", hit)
	testing.expectf(t, linalg.dot(normal, Vec3{0, 0, 1}) > 0.99, "normal %v", normal)
	// A ray starting inside the domain but outside the clay, at an angle.
	dir := linalg.normalize(Vec3{-1, -0.5, -1})
	hit, _, ok = clay_raycast(&c, {1.5, 0.75, 1.5}, dir)
	testing.expect(t, ok, "the angled ray missed")
	testing.expectf(t, math.abs(linalg.length(hit) - 1) < 0.02, "angled hit at %v, length %v", hit, linalg.length(hit))
	_, _, miss := clay_raycast(&c, {0, 3, 5}, {0, 0, -1})
	testing.expect(t, !miss, "a ray beside the sphere should miss")
	_, _, away := clay_raycast(&c, {0, 0, 5}, {0, 0, 1})
	testing.expect(t, !away, "a ray pointing away should miss")
}

@(test)
add_raises_the_surface_and_subtract_lowers_it_under_the_brush_only :: proc(t: ^testing.T) {
	c := test_sphere(128)
	defer clay_destroy(&c)
	top := Vec3{0, 0, 1}
	clay_stroke_begin(&c)
	for _ in 0 ..< 5 do testing.expect(t, test_dab(&c, .Add, top, 0.3) > 0, "the Add dab wrote nothing")
	testing.expect(t, clay_stroke_end(&c), "the stroke changed nothing")
	hit, _, ok := clay_raycast(&c, {0, 0, 5}, {0, 0, -1})
	testing.expectf(t, ok && hit.z > 1.02, "after Add the top is at %v", hit)
	side, _, side_ok := clay_raycast(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, side_ok && math.abs(side.x - 1) < 0.02, "Add moved the side to %v", side)

	clay_stroke_begin(&c)
	for _ in 0 ..< 12 do _ = test_dab(&c, .Subtract, {1, 0, 0}, 0.3)
	_ = clay_stroke_end(&c)
	side, _, side_ok = clay_raycast(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, side_ok && side.x < 0.98, "after Subtract the side is at %v", side)
	// The mesh follows: a closed surface whose volume grew at the top and shrank at the side.
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && !r.inverted && r.degenerate_triangles == 0, "%v", r)
}

@(test)
serial_and_parallel_strokes_agree_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{test_sphere(96), test_sphere(96, &pool)}
	defer for &c in clays do clay_destroy(&c)
	for &c in clays {
		_ = clay_flush(&c)
		kinds := [5]Brush_Kind{.Add, .Smooth, .Inflate, .Flatten, .Subtract}
		for kind, k in kinds {
			clay_stroke_begin(&c)
			for i in 0 ..< 6 {
				a := f32(i) * 0.15 + f32(k)
				at := linalg.normalize(Vec3{math.cos(a), math.sin(a), 0.3})
				_ = test_dab(&c, kind, at, 0.25, 0.8, invert = i % 2 == 1)
			}
			_ = clay_stroke_end(&c)
			_ = clay_flush(&c)
		}
	}
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "the fields differ between one thread and three")
	testing.expect(t, volume_brick_count(&clays[0].volume) == volume_brick_count(&clays[1].volume), "the brick counts differ")
	a := clay_to_mesh(&clays[0])
	defer geom.mesh_destroy(&a)
	b := clay_to_mesh(&clays[1])
	defer geom.mesh_destroy(&b)
	testing.expect(t, len(a.positions) == len(b.positions) && len(a.indices) == len(b.indices), "the meshes differ in size")
	same := true
	for p, i in a.positions do if p != b.positions[i] || a.normals[i] != b.normals[i] do same = false
	for k, i in a.indices do if k != b.indices[i] do same = false
	testing.expect(t, same, "the meshes differ")
}

@(test)
the_surface_is_closed_once_the_node_borders_are_welded :: proc(t: ^testing.T) {
	c := test_sphere(128)
	defer clay_destroy(&c)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && !r.inverted && r.degenerate_triangles == 0 && r.nan_count == 0, "%v", r)
	want := 4.0 / 3.0 * math.PI
	testing.expectf(t, math.abs(r.volume - want) < want * 0.02, "volume %v, a unit sphere has %v", r.volume, want)
	// Every vertex is within a voxel of the sphere and its normal points along its radius.
	voxel := c.volume.voxel
	for p, i in m.positions {
		testing.expectf(t, math.abs(linalg.length(p) - 1) < voxel, "vertex %v is off the sphere", p)
		testing.expectf(t, linalg.dot(m.normals[i], linalg.normalize(p)) > 0.95, "normal %v at %v", m.normals[i], p)
	}
	// The nodes hold their border vertices twice; welding removed exactly those.
	vertices, triangles := surface_counts(&c.surface)
	dup := clay_duplicate_vertices(&c)
	testing.expectf(t, dup > 0 && vertices - dup == len(m.positions), "%v vertices, %v duplicates, %v welded", vertices, dup, len(m.positions))
	testing.expectf(t, triangles >= len(m.indices) / 3, "%v triangles in slots, %v after the weld", triangles, len(m.indices) / 3)
}

@(test)
remeshing_only_the_dirty_nodes_equals_remeshing_everything :: proc(t: ^testing.T) {
	c := test_sphere(96)
	defer clay_destroy(&c)
	_ = clay_flush(&c)
	clay_stroke_begin(&c)
	for i in 0 ..< 8 {
		a := f32(i) * 0.2
		_ = test_dab(&c, .Add, linalg.normalize(Vec3{math.cos(a), 0.2, math.sin(a)}), 0.2)
	}
	_ = clay_stroke_end(&c)
	a := clay_to_mesh(&c)
	defer geom.mesh_destroy(&a)
	surface_mark_all(&c)
	b := clay_to_mesh(&c)
	defer geom.mesh_destroy(&b)
	testing.expect(t, len(a.positions) == len(b.positions) && len(a.indices) == len(b.indices), "the meshes differ in size")
	same := true
	for p, i in a.positions do if p != b.positions[i] do same = false
	testing.expect(t, same, "a dirty-only remesh differs from a full one")
}

@(test)
undo_restores_the_field_bit_for_bit_and_redo_the_stroke :: proc(t: ^testing.T) {
	c := test_sphere(96)
	defer clay_destroy(&c)
	before, bricks_before := clay_hash(&c), volume_brick_count(&c.volume)
	testing.expect(t, !clay_can_undo(&c) && !clay_can_redo(&c), "a new clay has history")
	clay_stroke_begin(&c)
	for _ in 0 ..< 10 do _ = test_dab(&c, .Add, {0, 0, 1}, 0.4)
	for _ in 0 ..< 10 do _ = test_dab(&c, .Subtract, {0, 1, 0}, 0.4)
	testing.expect(t, clay_stroke_end(&c), "the stroke changed nothing")
	after, bricks_after := clay_hash(&c), volume_brick_count(&c.volume)
	testing.expect(t, after != before, "the stroke left the field as it was")
	testing.expect(t, clay_undo_bytes(&c) > 0 && clay_undo_bytes(&c) < 4 << 20, "the step holds a strange amount")
	testing.expect(t, clay_can_undo(&c) && clay_undo(&c), "undo refused")
	testing.expect(t, clay_hash(&c) == before && volume_brick_count(&c.volume) == bricks_before, "undo did not restore the field")
	testing.expect(t, clay_can_redo(&c) && clay_redo(&c), "redo refused")
	testing.expect(t, clay_hash(&c) == after && volume_brick_count(&c.volume) == bricks_after, "redo did not restore the stroke")
	// A new stroke drops the redo step; an empty stroke keeps no step.
	_ = clay_undo(&c)
	clay_stroke_begin(&c)
	testing.expect(t, !clay_stroke_end(&c), "an empty stroke kept a step")
	testing.expect(t, !clay_can_redo(&c), "the redo step survived a new stroke")
	testing.expect(t, !clay_can_undo(&c), "an empty stroke left an undo step")
}

@(test)
inflate_and_smooth_strokes_keep_the_surface_closed_and_the_band_true :: proc(t: ^testing.T) {
	c := test_sphere(96)
	defer clay_destroy(&c)
	clay_stroke_begin(&c)
	for _ in 0 ..< 200 do _ = test_dab(&c, .Inflate, {0, 0, 1}, 0.5)
	_ = clay_stroke_end(&c)
	clay_stroke_begin(&c)
	for _ in 0 ..< 50 do _ = test_dab(&c, .Smooth, {0, 0, 1}, 0.5)
	_ = clay_stroke_end(&c)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && r.boundary_edges == 0 && !r.inverted, "%v", r)
	hit, _, ok := clay_raycast(&c, {0, 0, 5}, {0, 0, -1})
	testing.expectf(t, ok && hit.z > 1.05, "200 Inflate dabs left the top at %v", hit)
	// After the repair the field climbs a voxel a voxel away from the surface it moved.
	voxel := c.volume.voxel
	for d in ([3]f32{1.5, 2.5, -1.5}) {
		p := hit + {0, 0, d * voxel}
		got := volume_sample(&c.volume, p)
		testing.expectf(t, math.abs(got - d) < 0.5, "%v voxels above the inflated top the field reads %v", d, got)
	}
}

@(test)
freed_index_slots_hold_zeros_and_flush_reports_what_changed :: proc(t: ^testing.T) {
	c := test_sphere(96)
	defer clay_destroy(&c)
	first := clay_flush(&c)
	testing.expect(t, first.regrow, "the first flush must remake the GPU copy")
	none := clay_flush(&c)
	testing.expect(t, !none.regrow && len(none.ranges) == 0 && len(none.indices) == 0, "a flush without changes uploads")
	// Carve the top away so nodes there empty and their slots are freed.
	clay_stroke_begin(&c)
	for _ in 0 ..< 40 do _ = test_dab(&c, .Subtract, {0, 0, 1}, 0.6)
	_ = clay_stroke_end(&c)
	f := clay_flush(&c)
	testing.expect(t, f.regrow || len(f.ranges) > 0, "the carve uploaded nothing")
	s := &c.surface
	used := make([]bool, len(s.mesh.indices), context.temp_allocator)
	emptied := 0
	for n in s.nodes {
		for k in n.idx_first ..< n.idx_first + n.idx_count do used[k] = true
		if n.vert_cap == 0 && n.coord.z > 0 do emptied += 1
	}
	for k, i in s.mesh.indices do testing.expectf(t, used[i] || k == 0, "index slot %v outside every node holds %v", i, k)
	testing.expect(t, emptied > 0, "no node emptied")
	// Every slot in use is covered by a node whose triangles point at its own vertices.
	for n in s.nodes do for k in s.mesh.indices[n.idx_first:][:n.idx_count] {
		testing.expect(t, k >= n.vert_first && k < n.vert_first + n.vert_count, "a triangle points outside its node")
	}
}

@(test)
a_clay_survives_the_file_and_damaged_bytes_are_refused :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	c := test_sphere(96, &pool)
	defer clay_destroy(&c)
	clay_stroke_begin(&c)
	for _ in 0 ..< 5 do _ = test_dab(&c, .Add, {0, 0, 1}, 0.3)
	_ = clay_stroke_end(&c)
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, clay_write(&c, &out), "the write stopped")
	testing.expectf(t, len(out) <= clay_write_estimate(&c), "%v bytes written, %v estimated", len(out), clay_write_estimate(&c))
	r := geom.byte_reader(out[:])
	back: Clay
	testing.expect(t, clay_read(&back, &r, &pool), "the clay did not read back")
	defer clay_destroy(&back)
	testing.expect(t, r.at == len(out), "bytes were left over")
	testing.expect(t, clay_hash(&back) == clay_hash(&c), "the field changed through the file")
	testing.expect(t, back.volume.voxel == c.volume.voxel && back.volume.origin == c.volume.origin, "the placement changed")
	a := clay_to_mesh(&c)
	defer geom.mesh_destroy(&a)
	b := clay_to_mesh(&back)
	defer geom.mesh_destroy(&b)
	testing.expect(t, len(a.positions) == len(b.positions) && len(a.indices) == len(b.indices), "the meshes differ")

	// Short, a bad tile code, a wrong tag: each refused without a trace.
	for cut in ([3]int{len(out) - 1, len(out) / 2, 20}) {
		short := geom.byte_reader(out[:cut])
		bad: Clay
		testing.expectf(t, !clay_read(&bad, &short, nil), "%v bytes read as a clay", cut)
	}
	damaged := make([]u8, len(out), context.temp_allocator)
	copy(damaged, out[:])
	damaged[28 + 12] = 7 // the first chunk's first tile code
	d := geom.byte_reader(damaged)
	bad: Clay
	testing.expect(t, !clay_read(&bad, &d, nil), "a bad tile code read as a clay")
	damaged[0] = 'X'
	d = geom.byte_reader(damaged)
	testing.expect(t, !clay_read(&bad, &d, nil), "a wrong tag read as a clay")
	// A write asked to stop, stops.
	abort := true
	stopped := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, !clay_write(&c, &stopped, &abort), "the write ignored the abort")
}

@(test)
the_eikonal_update_solves_one_two_and_three_axes :: proc(t: ^testing.T) {
	far := f32(CLAMP) / SCALE
	testing.expect(t, eikonal_update({0, far, far}) == 1, "one axis")
	testing.expect(t, math.abs(eikonal_update({0, 0, far}) - math.SQRT_TWO / 2) < 1e-5, "two axes")
	testing.expect(t, math.abs(eikonal_update({0, 0, 0}) - 1 / math.sqrt(f32(3))) < 1e-5, "three axes")
	testing.expect(t, math.abs(eikonal_update({2, 3.5, far}) - 3) < 1e-5, "a second axis past the one-axis solution does not take part")
}
