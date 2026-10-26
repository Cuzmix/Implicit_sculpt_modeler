package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"

// A strip folded into a U: a bottom arm along x from 0 to 2 at z = 0, a step up to
// z = 0.1 at x = 2, and a top arm back to x = 0, 0.2 wide in y. The two arms' ends at
// x = 0 are 0.1 apart in space and over 4 apart along the surface.
@(private = "file")
u_strip :: proc() -> (m: geom.Mesh) {
	path := make([dynamic]Vec3, context.temp_allocator)
	for i in 0 ..= 20 do append(&path, Vec3{0.1 * f32(i), 0, 0})
	for i in 0 ..= 20 do append(&path, Vec3{2 - 0.1 * f32(i), 0, 0.1})
	for p in path {
		append(&m.positions, p, p + {0, 0.2, 0})
	}
	for k in 0 ..< u32(len(path) - 1) {
		a, b, c, d := 2 * k, 2 * k + 1, 2 * k + 2, 2 * k + 3
		append(&m.indices, a, c, b, b, c, d)
	}
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	return
}

// Pressed on the bottom arm near x = 0, the mask frees the bottom arm out to the reach
// and keeps the top arm masked, though its end is a tenth away in space.
@(test)
topo_mask_follows_the_surface :: proc(t: ^testing.T) {
	m := u_strip()
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 8)
	defer sculptor_destroy(&s)
	testing.expect(t, sculptor_topo_mask_begin(&s, {0.05, 0.1, -1}, {0, 0, 1}, false))
	testing.expect(t, sculptor_topo_mask_reach(&s, 1, max(int)))
	for p, v in m.positions {
		switch {
		case p.z == 0 && p.x < 0.5:  testing.expectf(t, s.mask[v] == 0, "bottom vertex %v masked %d", p, s.mask[v])
		case p.z == 0 && p.x > 1.1:  testing.expectf(t, s.mask[v] == 255, "bottom vertex %v masked %d", p, s.mask[v])
		case p.z > 0:                testing.expectf(t, s.mask[v] == 255, "top vertex %v masked %d", p, s.mask[v])
		}
	}
	testing.expect(t, sculptor_topo_mask_end(&s))
}

// On a sphere: what lies beyond the reach in space is masked, what is near the press is
// free; a larger reach frees more and never masks anything again, going back to the first
// reach gives the first mask exactly, a small budget a frame ends where an unlimited one
// does, and the whole gesture is one undo step.
@(test)
topo_mask_grows_shrinks_and_is_one_step :: proc(t: ^testing.T) {
	ma, mb := geom.icosphere(3), geom.icosphere(3)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	a, b: Sculptor
	sculptor_init(&a, &ma, nil, 64)
	defer sculptor_destroy(&a)
	sculptor_init(&b, &mb, nil, 64)
	defer sculptor_destroy(&b)
	hit := Vec3{0, 0, 1}
	testing.expect(t, !sculptor_topo_mask_begin(&a, {3, 3, 3}, {0, 0, 1}, false))
	testing.expect(t, sculptor_topo_mask_begin(&a, {0.013, 0.021, 3}, {0, 0, -1}, false))
	testing.expect(t, sculptor_topo_masking(&a))
	testing.expect(t, sculptor_topo_mask_reach(&a, 0.6, max(int)))
	first := slice.clone(a.mask, context.temp_allocator)
	for p, v in ma.positions {
		d := linalg.length(p - hit)
		if d > 0.6 do testing.expectf(t, first[v] == 255, "%v masked %d", p, first[v])
		if d < 0.3 do testing.expectf(t, first[v] == 0, "%v masked %d", p, first[v])
	}
	testing.expect(t, sculptor_topo_mask_reach(&a, 1.2, max(int)))
	freed := 0
	for k, v in a.mask {
		testing.expect(t, k <= first[v])
		freed += int(k < first[v])
	}
	testing.expect(t, freed > 0)
	testing.expect(t, sculptor_topo_mask_reach(&a, 0.6, max(int)))
	testing.expect(t, slice.equal(a.mask, first))
	testing.expect(t, sculptor_topo_mask_reach(&a, 1.2, max(int)))

	testing.expect(t, sculptor_topo_mask_begin(&b, {0.013, 0.021, 3}, {0, 0, -1}, false))
	frames := 1
	for !sculptor_topo_mask_reach(&b, 1.2, 50) do frames += 1
	testing.expect(t, frames > 3)
	testing.expect(t, slice.equal(a.mask, b.mask))

	grown := slice.clone(a.mask, context.temp_allocator)
	steps := len(a.history.done)
	testing.expect(t, sculptor_topo_mask_end(&a))
	testing.expect(t, !sculptor_topo_masking(&a))
	testing.expect_value(t, len(a.history.done), steps + 1)
	testing.expect(t, sculptor_undo(&a))
	for k in a.mask do testing.expect(t, k == 0)
	testing.expect(t, sculptor_redo(&a))
	testing.expect(t, slice.equal(a.mask, grown))
	testing.expect(t, sculptor_topo_mask_end(&b))
}

// Inverted, the press is masked and the far side free; hidden vertices keep their mask;
// a cancel puts the mask back exactly and leaves no step.
@(test)
topo_mask_inverts_keeps_hidden_and_cancels :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	values := make([]u8, len(m.positions), context.temp_allocator)
	for p, v in m.positions do values[v] = 200 if p.y > 0.6 else 0
	testing.expect(t, sculptor_mask_values(&s, values, .Replace))
	testing.expect(t, sculptor_hide_command(&s, .Masked))
	before := slice.clone(s.mask, context.temp_allocator)
	steps := len(s.history.done)
	testing.expect(t, sculptor_topo_mask_begin(&s, {0.013, 0.021, 3}, {0, 0, -1}, true))
	testing.expect(t, sculptor_topo_mask_reach(&s, 0.8, max(int)))
	hidden := 0
	for p, v in m.positions {
		if vertex_hidden(&s, u32(v)) {
			hidden += 1
			testing.expect_value(t, s.mask[v], u8(200))
			continue
		}
		d := linalg.length(p - Vec3{0, 0, 1})
		if d < 0.5 do testing.expectf(t, s.mask[v] == 255, "%v masked %d", p, s.mask[v])
		if d > 0.8 do testing.expectf(t, s.mask[v] == 0, "%v masked %d", p, s.mask[v])
	}
	testing.expect(t, hidden > 0)
	sculptor_topo_mask_cancel(&s)
	testing.expect(t, slice.equal(s.mask, before))
	testing.expect_value(t, len(s.history.done), steps)
	testing.expect(t, !s.history.recording)
}

// With dynamic topology on it masks the vertices the nodes own and is one undo step.
@(test)
topo_mask_works_with_dynamic_topology :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	testing.expect(t, sculptor_dyn_enable(&s))
	defer sculptor_dyn_disable(&s)
	testing.expect(t, sculptor_topo_mask_begin(&s, {0.013, 0.021, 3}, {0, 0, -1}, false))
	testing.expect(t, sculptor_topo_mask_reach(&s, 0.6, max(int)))
	free_, masked := 0, 0
	for n in s.nodes {
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			free_ += int(s.mask[v] == 0)
			masked += int(s.mask[v] == 255)
		}
	}
	testing.expect(t, free_ > 0 && masked > free_)
	testing.expect(t, sculptor_topo_mask_end(&s))
	testing.expect(t, sculptor_undo(&s))
	for n in s.nodes do for v in n.vert_first ..< n.vert_first + n.vert_count do testing.expect(t, s.mask[v] == 0)
}

// Changing the reach while the search is only partly settled (growing, shrinking below
// its frontier, growing again) ends with the mask an unlimited search gives for the last
// reach.
@(test)
topo_mask_reach_changes_while_settling :: proc(t: ^testing.T) {
	ma, mb := geom.icosphere(3), geom.icosphere(3)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	a, b: Sculptor
	sculptor_init(&a, &ma, nil, 64)
	defer sculptor_destroy(&a)
	sculptor_init(&b, &mb, nil, 64)
	defer sculptor_destroy(&b)
	testing.expect(t, sculptor_topo_mask_begin(&a, {0.013, 0.021, 3}, {0, 0, -1}, false))
	steps := [?]struct {
		reach:  f32,
		budget: int,
		calls:  int,
	}{{0.5, 30, 3}, {1.3, 50, 5}, {0.4, 20, 3}, {1.6, 40, 4}, {1.0, 60, 2}}
	for st in steps do for _ in 0 ..< st.calls do _ = sculptor_topo_mask_reach(&a, st.reach, st.budget)
	for !sculptor_topo_mask_reach(&a, 1.0, 40) {}
	testing.expect(t, sculptor_topo_mask_begin(&b, {0.013, 0.021, 3}, {0, 0, -1}, false))
	testing.expect(t, sculptor_topo_mask_reach(&b, 1.0, max(int)))
	testing.expect(t, slice.equal(a.mask, b.mask))
	testing.expect(t, sculptor_topo_mask_end(&a))
	testing.expect(t, sculptor_topo_mask_end(&b))
}
