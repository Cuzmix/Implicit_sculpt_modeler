package sculpt

import "core:slice"
import "core:testing"

import "../geom"

@(private = "file")
TRIAL_AT :: Vec3{0, 1, 0}

// A trial reads the sculptor and moves nothing: the positions, the undo and the stroke's
// records stay as they were.
@(test)
trial_dabs_move_nothing :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(s.mesh.positions[:], context.temp_allocator)
	dabs, verts, ok := sculptor_trial_dabs(&s, {kind = .Clay, radius = 0.3, strength = 0.5}, TRIAL_AT, 3, context.temp_allocator)
	testing.expect(t, ok, "no trial")
	testing.expect_value(t, len(dabs), 1)
	testing.expect(t, verts > 0 && len(dabs[0].ranges) > 0, "no ranges")
	testing.expect(t, slice.equal(s.mesh.positions[:], before), "the trial moved the mesh")
	testing.expect_value(t, len(s.history.done), 0)
	testing.expect_value(t, len(s.gpu_dabs), 0)
	testing.expect(t, !s.history.recording, "a stroke began")
}

// The trial's ranges hold every vertex the stroke's first dab moves, at the same place
// with the same brush.
@(test)
trial_ranges_hold_what_a_dab_moves :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	brush := Brush{kind = .Draw, radius = 0.25, strength = 0.6, symmetry = {.X}}
	at := Vec3{0.3, 0.9, 0.2}
	dabs, _, ok := sculptor_trial_dabs(&s, brush, at, 1, context.temp_allocator)
	testing.expect(t, ok, "no trial")
	testing.expect_value(t, len(dabs), 2)
	ranges := sculptor_trial_ranges(dabs, context.temp_allocator)
	before := slice.clone(s.mesh.positions[:], context.temp_allocator)
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, brush, at)
	_ = sculptor_stroke_end(&s)
	moved := 0
	for p, v in s.mesh.positions {
		if p == before[v] do continue
		moved += 1
		inside := false
		for r in ranges do if u32(v) >= r.first && u32(v) < r.first + r.count do inside = true
		if !inside {
			testing.expectf(t, false, "vertex %d moved outside the trial's ranges", v)
			break
		}
	}
	testing.expect(t, moved > 0, "the dab moved nothing")
	// The ranges come merged and in order, none overlapping.
	for i in 1 ..< len(ranges) do testing.expect(t, ranges[i - 1].first + ranges[i - 1].count < ranges[i].first, "ranges overlap or touch")
}

// No trial for a brush the GPU's kernels do not lay, while a stroke records, or past the
// cap, which then says how many vertices it would have reached.
@(test)
trial_dabs_refuse :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_, _, ok := sculptor_trial_dabs(&s, {kind = .Grab, radius = 0.3, strength = 1}, TRIAL_AT, 1, context.temp_allocator)
	testing.expect(t, !ok, "a trial of Grab")
	sculptor_stroke_begin(&s)
	_, _, ok = sculptor_trial_dabs(&s, {kind = .Draw, radius = 0.3, strength = 1}, TRIAL_AT, 1, context.temp_allocator)
	testing.expect(t, !ok, "a trial during a stroke")
	_ = sculptor_stroke_end(&s)
	big := geom.icosphere(8)
	defer geom.mesh_destroy(&big)
	b: Sculptor
	sculptor_init(&b, &big, nil, 64)
	defer sculptor_destroy(&b)
	dabs, verts, capped := sculptor_trial_dabs(&b, {kind = .Draw, radius = 3, strength = 1}, TRIAL_AT, 1, context.temp_allocator)
	testing.expect(t, !capped && dabs == nil, "a trial past the cap")
	testing.expect(t, verts > HOVER_VERTS_MAX, "the cap's count")
}
