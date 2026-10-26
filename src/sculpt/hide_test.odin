package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sculptor over an icosphere with small nodes; free with hide_sphere_free.
@(private = "file")
Hide_Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

@(private = "file")
hide_sphere :: proc(subdiv: int, pool: ^jobs.Pool = nil) -> ^Hide_Sphere {
	sp := new(Hide_Sphere)
	sp.mesh = geom.icosphere(subdiv)
	sculptor_init(&sp.sculptor, &sp.mesh, pool, 64)
	for id in 0 ..< len(sp.sculptor.nodes) do mark_stale(&sp.sculptor, u32(id), .Shape)
	_ = sculptor_flush(&sp.sculptor)
	return sp
}

@(private = "file")
hide_sphere_free :: proc(sp: ^Hide_Sphere) {
	sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	free(sp)
}

// Looking down z, flat: x and y are already the screen.
@(private = "file")
FLAT: matrix[4, 4]f32 : 1

@(private = "file")
centre :: proc(m: geom.Mesh, t: int) -> Vec3 {
	return (m.positions[m.indices[3 * t]] + m.positions[m.indices[3 * t + 1]] + m.positions[m.indices[3 * t + 2]]) / 3
}

// Hiding by rectangle hides the triangles whose middle is inside it, through the mesh;
// a dab there moves nothing, the pointer passes through, and undo shows them again.
@(test)
hide_rectangle_hides_inside_it :: proc(t: ^testing.T) {
	sp := hide_sphere(5)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_hide_shape(s, FLAT, rect, .Hide))
	wrong, hidden := 0, 0
	for tri in 0 ..< len(m.indices) / 3 {
		c := centre(m^, tri)
		if (abs(c.x) < 0.3 && abs(c.y) < 0.3) != s.hide.tris[tri] do wrong += 1
		if s.hide.tris[tri] do hidden += 1
	}
	testing.expectf(t, wrong == 0, "%d triangles hidden wrongly", wrong)
	testing.expect_value(t, sculptor_hidden_count(s), hidden)
	// Both caps of the sphere (front and back) are hidden, so whole chunks drop out.
	units := sculptor_hidden_units(s)
	whole := 0
	for id in 0 ..< len(s.nodes) do if units[id] do whole += 1
	testing.expect(t, whole > 0)

	before := slice.clone(m.positions[:], context.temp_allocator)
	moved := apply_dab(s, {kind = .Draw, radius = 0.15, strength = 1}, {0, 0, 1})
	testing.expect_value(t, moved, 0)
	testing.expect(t, slice.equal(before, m.positions[:]))
	_, hit := sculptor_raycast(s, {0.013, 0.021, 3}, {0, 0, -1})
	testing.expect(t, !hit) // both sides are hidden there
	_, hit = sculptor_raycast(s, {0.6, 0, 3}, {0, 0, -1})
	testing.expect(t, hit)

	testing.expect(t, sculptor_undo(s))
	testing.expect_value(t, sculptor_hidden_count(s), 0)
	testing.expect(t, s.fade == nil)
	_, hit = sculptor_raycast(s, {0.013, 0.021, 3}, {0, 0, -1})
	testing.expect(t, hit)
	testing.expect(t, sculptor_redo(s))
	testing.expect_value(t, sculptor_hidden_count(s), hidden)
	testing.expect(t, sculptor_hide_command(s, .Show_All))
	testing.expect_value(t, sculptor_hidden_count(s), 0)
	testing.expect(t, !sculptor_hide_command(s, .Show_All))
}

// Show only keeps what is inside; invert swaps; hiding everything is refused.
@(test)
hide_show_only_invert_and_never_everything :: proc(t: ^testing.T) {
	sp := hide_sphere(4)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	total := len(m.indices) / 3
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_hide_shape(s, FLAT, rect, .Show_Only))
	shown := total - sculptor_hidden_count(s)
	for tri in 0 ..< total {
		c := centre(m^, tri)
		if !s.hide.tris[tri] do testing.expect(t, abs(c.x) < 0.3 && abs(c.y) < 0.3)
	}
	testing.expect(t, sculptor_hide_command(s, .Invert))
	testing.expect_value(t, sculptor_hidden_count(s), shown)
	// A shape off the mesh would leave nothing shown.
	away := [][2]f32{{2, 2}, {3, 2}, {3, 3}}
	testing.expect(t, !sculptor_hide_shape(s, FLAT, away, .Show_Only))
	testing.expect_value(t, sculptor_hidden_count(s), shown)
	testing.expect(t, sculptor_hide_command(s, .Show_All))
	testing.expect(t, !sculptor_hide_command(s, .Invert))
	// Undo walks back through all three.
	testing.expect(t, sculptor_undo(s) && sculptor_undo(s) && sculptor_undo(s))
	testing.expect_value(t, sculptor_hidden_count(s), 0)
}

// Vertices between hidden and shown triangles still move; those inside do not; mask
// commands leave hidden vertices' masks be.
@(test)
hide_border_vertices_still_move :: proc(t: ^testing.T) {
	sp := hide_sphere(5)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	rect := [][2]f32{{-1.5, 0}, {1.5, 0}, {1.5, 1.5}, {-1.5, 1.5}} // the y > 0 half
	testing.expect(t, sculptor_hide_shape(s, FLAT, rect, .Hide))
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, apply_dab(s, {kind = .Inflate, radius = 0.4, strength = 1}, {0, 0, 1}) > 0)
	moved_hidden, moved_shown := 0, 0
	for p, v in m.positions {
		if p == before[v] do continue
		if s.fade[v] == 0 do moved_hidden += 1
		else do moved_shown += 1
	}
	testing.expect_value(t, moved_hidden, 0)
	testing.expect(t, moved_shown > 0)
	testing.expect(t, sculptor_mask_command(s, .Fill))
	for k, v in s.mask do if (k == 255) == (s.fade[v] == 0) {
		testing.expectf(t, false, "vertex %d: mask %d, fade %d", v, k, s.fade[v])
		break
	}
}

// The index data for drawing makes hidden triangles degenerate, sends only changed
// nodes to a buffer that is current, and every hidden node to a new buffer.
@(test)
hide_indices_for_the_gpu :: proc(t: ^testing.T) {
	sp := hide_sphere(4)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	indices, ranges := sculptor_hidden_indices(s, 0)
	testing.expect_value(t, len(ranges), 0)
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_hide_shape(s, FLAT, rect, .Hide))
	stamp := sculptor_hidden_stamp(s)
	indices, ranges = sculptor_hidden_indices(s, 0)
	testing.expect(t, len(ranges) > 0)
	zeros, at := 0, 0
	for r in ranges {
		for k in 0 ..< int(r.index_count) / 3 {
			tri := int(r.first_index) / 3 + k
			got := indices[at + 3 * k:][:3]
			if s.hide.tris[tri] {
				zeros += 1
				testing.expect(t, got[0] == 0 && got[1] == 0 && got[2] == 0)
			} else {
				testing.expect(t, slice.equal(got, sp.mesh.indices[3 * tri:][:3]))
			}
		}
		at += int(r.index_count)
	}
	testing.expect_value(t, zeros, sculptor_hidden_count(s))
	// Current: nothing more to send until something changes.
	_, ranges = sculptor_hidden_indices(s, stamp)
	testing.expect_value(t, len(ranges), 0)
	testing.expect(t, sculptor_hide_command(s, .Show_All))
	_, ranges = sculptor_hidden_indices(s, stamp)
	testing.expect(t, len(ranges) > 0) // the nodes to show again
	// A new buffer has the mesh's own indices, which is all shown: nothing to send.
	_, ranges = sculptor_hidden_indices(s, 0)
	testing.expect_value(t, len(ranges), 0)
}

// Serial and threaded hiding give the same triangles and fades.
@(test)
hide_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a := hide_sphere(6)
	defer hide_sphere_free(a)
	b := hide_sphere(6, &pool)
	defer hide_sphere_free(b)
	lasso := [][2]f32{{-0.5, -0.2}, {0.1, -0.6}, {0.6, 0.4}, {0, 0.1}, {-0.4, 0.5}}
	testing.expect(t, sculptor_hide_shape(&a.sculptor, FLAT, lasso, .Show_Only))
	testing.expect(t, sculptor_hide_shape(&b.sculptor, FLAT, lasso, .Show_Only))
	testing.expect(t, slice.equal(a.sculptor.hide.tris, b.sculptor.hide.tris))
	testing.expect(t, slice.equal(a.sculptor.fade, b.sculptor.fade))
	testing.expect(t, slice.equal(a.sculptor.hide.units, b.sculptor.hide.units))
	// Mask hidden, Show all, then Hide unmasked: the conversions read across node borders.
	for sp in ([2]^Hide_Sphere{a, b}) {
		s := &sp.sculptor
		testing.expect(t, sculptor_mask_command(s, .Hidden))
		testing.expect(t, sculptor_hide_command(s, .Show_All))
		testing.expect(t, sculptor_hide_command(s, .Unmasked))
	}
	testing.expect(t, slice.equal(a.sculptor.mask, b.sculptor.mask))
	testing.expect(t, slice.equal(a.sculptor.hide.tris, b.sculptor.hide.tris))
	testing.expect(t, slice.equal(a.sculptor.fade, b.sculptor.fade))
}

// Hide masked hides the triangles masked at least half at every corner and Hide
// unmasked the rest, so the two are complements and Invert turns one into the other;
// without a mask neither does anything, and undo puts back what was shown.
@(test)
hide_by_mask_hides_complements :: proc(t: ^testing.T) {
	sp := hide_sphere(4)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	total := len(m.indices) / 3
	testing.expect(t, !sculptor_hide_command(s, .Masked))
	testing.expect(t, !sculptor_hide_command(s, .Unmasked))
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_mask_shape(s, FLAT, rect, false))

	testing.expect(t, sculptor_hide_command(s, .Masked))
	masked := slice.clone(s.hide.tris, context.temp_allocator)
	wrong, count := 0, 0
	for tri in 0 ..< total {
		c := m.indices[3 * tri:][:3]
		want := s.mask[c[0]] >= MASK_HALF && s.mask[c[1]] >= MASK_HALF && s.mask[c[2]] >= MASK_HALF
		if want != masked[tri] do wrong += 1
		if want do count += 1
	}
	testing.expectf(t, wrong == 0, "%d triangles hidden wrongly", wrong)
	testing.expect(t, count > 0 && count < total)
	testing.expect(t, sculptor_hide_command(s, .Invert))
	inverted := slice.clone(s.hide.tris, context.temp_allocator)

	testing.expect(t, sculptor_undo(s) && sculptor_undo(s))
	testing.expect_value(t, sculptor_hidden_count(s), 0)
	testing.expect(t, sculptor_hide_command(s, .Unmasked))
	testing.expect_value(t, sculptor_hidden_count(s), total - count)
	for tri in 0 ..< total do if s.hide.tris[tri] == masked[tri] do wrong += 1
	testing.expectf(t, wrong == 0, "%d triangles in both or neither", wrong)
	testing.expect(t, slice.equal(inverted, s.hide.tris))
	// What is hidden stays hidden: Hide masked now would hide everything, so it is refused.
	testing.expect(t, !sculptor_hide_command(s, .Masked))
	testing.expect(t, sculptor_hide_refused_all(s))
	testing.expect(t, sculptor_undo(s))
	testing.expect_value(t, sculptor_hidden_count(s), 0)
}

// Mask hidden masks every corner of a hidden triangle and unmasks the rest, so after
// Show all the mask is the part that was hidden; undo brings back the old mask.
@(test)
mask_hidden_makes_the_hidden_part_the_mask :: proc(t: ^testing.T) {
	sp := hide_sphere(4)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	testing.expect(t, !sculptor_mask_command(s, .Hidden)) // nothing hidden
	// A mask away from what gets hidden, which Mask hidden clears.
	side := [][2]f32{{0.6, -0.2}, {0.9, -0.2}, {0.9, 0.2}, {0.6, 0.2}}
	testing.expect(t, sculptor_mask_shape(s, FLAT, side, false))
	before := slice.clone(s.mask, context.temp_allocator)
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_hide_shape(s, FLAT, rect, .Hide))
	testing.expect(t, sculptor_mask_command(s, .Hidden))
	corner := make([]bool, len(m.positions), context.temp_allocator)
	for x, tri in s.hide.tris do if x do for c in m.indices[3 * tri:][:3] do corner[c] = true
	wrong := 0
	for v in 0 ..< len(m.positions) do if s.mask[v] != (255 if corner[v] else 0) do wrong += 1
	testing.expectf(t, wrong == 0, "%d vertices masked wrongly", wrong)
	masked := slice.clone(s.mask, context.temp_allocator)
	hidden := slice.clone(s.hide.tris, context.temp_allocator)
	testing.expect(t, sculptor_hide_command(s, .Show_All))
	testing.expect(t, slice.equal(masked, s.mask))
	// Hide masked then hides at least what was hidden: also any shown triangle all of
	// whose corners touched a hidden one.
	testing.expect(t, sculptor_hide_command(s, .Masked))
	lost := 0
	for x, tri in hidden do if x && !s.hide.tris[tri] do lost += 1
	testing.expectf(t, lost == 0, "%d hidden triangles not hidden again", lost)
	testing.expect(t, sculptor_hidden_count(s) >= len(slice.filter(hidden, proc(x: bool) -> bool {return x}, context.temp_allocator)))
	testing.expect(t, sculptor_undo(s) && sculptor_undo(s) && sculptor_undo(s))
	testing.expect(t, sculptor_hidden_count(s) > 0)
	testing.expect(t, slice.equal(before, s.mask))
}

// Under dynamic topology nothing is hidden, so none of the conversions does anything.
@(test)
hide_by_mask_refused_with_dynamic_topology :: proc(t: ^testing.T) {
	sp := hide_sphere(3)
	defer hide_sphere_free(sp)
	s := &sp.sculptor
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_hide_shape(s, FLAT, rect, .Hide))
	testing.expect(t, sculptor_mask_shape(s, FLAT, rect, false))
	testing.expect(t, sculptor_dyn_enable(s))
	defer sculptor_dyn_disable(s)
	testing.expect(t, !sculptor_hide_command(s, .Masked))
	testing.expect(t, !sculptor_hide_command(s, .Unmasked))
	testing.expect(t, !sculptor_mask_command(s, .Hidden))
}
