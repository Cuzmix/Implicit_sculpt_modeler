package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
UP :: Vec3{0, 0, 1}

@(private = "file")
DOWN :: Vec3{0, 0, -1}

@(private = "file")
dab_at :: proc(s: ^Sculptor, at: Vec3, color: [3]u8) {
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Paint, radius = 0.6, strength = 1, color = color}, at)
	_ = sculptor_stroke_end(s)
	_ = sculptor_flush(s)
}

// The first paint makes one picked layer whose colours are the sculptor's own, and while
// the stack stays plain what shows is those colours themselves, with no composite.
@(test)
paint_layers_first_paint_makes_a_plain_layer :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	testing.expect(t, !sculptor_paint_shows(&s))
	dab_at(&s, UP, {200, 20, 10})
	testing.expect_value(t, len(sculptor_paint_layers(&s)), 1)
	testing.expect_value(t, sculptor_paint_picked(&s), 0)
	shown := sculptor_paint_shown(&s)
	testing.expect(t, raw_data(shown) == raw_data(s.color), "a plain stack copied its colours")
	testing.expect(t, s.paint.shown == nil, "a plain stack made a composite")
}

// Two layers composite bottom up, a hidden top layer shows the bottom's bytes exactly, and
// the composite is the same whether the pool runs it or the caller does.
@(test)
paint_layers_composite_is_exact_and_deterministic :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	shown: [2][]Color
	for p, k in ([2]^jobs.Pool{nil, &pool}) {
		m := geom.icosphere(4)
		s: Sculptor
		sculptor_init(&s, &m, p, 64)
		dab_at(&s, UP, {200, 20, 10})
		bottom := slice.clone(s.color, context.temp_allocator)
		testing.expect_value(t, sculptor_paint_add(&s), 1)
		dab_at(&s, {0.6, 0, 0.8}, {10, 30, 220})
		testing.expect(t, sculptor_paint_set(&s, 1, true, 0.5))
		_ = sculptor_stroke_end(&s)
		_ = sculptor_flush(&s)
		testing.expect(t, s.paint.shown != nil, "two layers made no composite")
		shown[k] = slice.clone(sculptor_paint_shown(&s), context.temp_allocator)
		testing.expect(t, sculptor_paint_set(&s, 1, false, 0.5))
		_ = sculptor_stroke_end(&s)
		_ = sculptor_flush(&s)
		testing.expect(t, slice.equal(sculptor_paint_shown(&s), bottom), "a hidden top layer changed the bottom's colours")
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
	testing.expect(t, slice.equal(shown[0], shown[1]), "serial and parallel composites differ")
	mixed := 0
	for c in shown[0] do if c.a > 0 && c.b > 10 && c.r > 10 do mixed += 1
	testing.expect(t, mixed > 0, "nowhere shows both layers")
}

// Undoing a stroke puts back the colours of the layer it painted, even after another layer
// was picked, and leaves the picked layer alone.
@(test)
paint_layers_undo_finds_the_layer_it_painted :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	dab_at(&s, UP, {200, 20, 10})
	_ = sculptor_paint_add(&s)
	dab_at(&s, UP, {10, 30, 220})
	top := slice.clone(s.color, context.temp_allocator)
	sculptor_paint_pick(&s, 0)
	bottom := slice.clone(s.color, context.temp_allocator)
	testing.expect(t, sculptor_undo(&s), "nothing to undo")
	testing.expect(t, slice.equal(s.color, bottom), "undo changed the picked layer")
	for c in sculptor_paint_layer_colors(&s, 1) do testing.expect(t, c == {}, "undo left the top layer painted")
	testing.expect(t, sculptor_redo(&s))
	testing.expect(t, slice.equal(sculptor_paint_layer_colors(&s, 1), top), "redo did not repaint the top layer")
}

// Add, move, set, merge down and remove each undo and redo to the same stack.
@(test)
paint_layers_stack_steps_undo_and_redo :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	dab_at(&s, UP, {200, 20, 10})
	_ = sculptor_paint_add(&s)
	dab_at(&s, DOWN, {10, 30, 220})
	ids :: proc(s: ^Sculptor) -> [4]u32 {
		out: [4]u32
		for l, i in s.paint.list do if i < 4 do out[i] = l.id
		return out
	}
	testing.expect_value(t, ids(&s), [4]u32{1, 2, 0, 0})
	testing.expect(t, sculptor_paint_move(&s, 0))
	testing.expect_value(t, ids(&s), [4]u32{2, 1, 0, 0})
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, ids(&s), [4]u32{1, 2, 0, 0})
	testing.expect(t, sculptor_paint_set(&s, 0, true, 0.25))
	_ = sculptor_stroke_end(&s)
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, s.paint.list[0].opacity, 1)
	testing.expect(t, sculptor_redo(&s))
	testing.expect_value(t, s.paint.list[0].opacity, 0.25)
	_ = sculptor_flush(&s)
	before := slice.clone(sculptor_paint_shown(&s), context.temp_allocator)
	testing.expect(t, sculptor_paint_merge_down(&s, 1))
	_ = sculptor_flush(&s)
	testing.expect_value(t, len(s.paint.list), 1)
	testing.expect(t, slice.equal(sculptor_paint_shown(&s), before), "merge down changed what shows")
	testing.expect(t, sculptor_undo(&s))
	_ = sculptor_flush(&s)
	testing.expect_value(t, ids(&s), [4]u32{1, 2, 0, 0})
	testing.expect_value(t, s.paint.list[0].opacity, 0.25)
	testing.expect(t, slice.equal(sculptor_paint_shown(&s), before), "undoing a merge changed what shows")
	testing.expect(t, sculptor_paint_remove(&s, 1))
	testing.expect_value(t, len(s.paint.list), 1)
	testing.expect_value(t, sculptor_paint_picked(&s), 0)
	testing.expect(t, sculptor_undo(&s))
	testing.expect_value(t, ids(&s), [4]u32{1, 2, 0, 0})
	testing.expect_value(t, sculptor_paint_picked(&s), 1)
}

// A level change mirrors the stack onto the level it goes to, and the scene file brings
// the stack back as it was written.
@(test)
paint_layers_follow_levels_and_files :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l: Levels
	levels_init(&l, geom.icosphere(2), &pool, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	s := &levels_current(&l).sculptor
	dab_at(s, UP, {200, 20, 10})
	_ = sculptor_paint_add(s)
	dab_at(s, DOWN, {10, 30, 220})
	testing.expect(t, sculptor_paint_set(s, 1, true, 0.5))
	_ = sculptor_stroke_end(s)
	levels_set_current(&l, 0)
	base := &l.levels[0].sculptor
	testing.expect_value(t, len(base.paint.list), 2)
	testing.expect_value(t, base.paint.list[1].opacity, 0.5)
	testing.expect_value(t, sculptor_paint_picked(base), 1)
	testing.expect(t, sculptor_paint_layer_colors(base, 0) != nil, "the bottom layer's colours did not come down")

	_ = sculptor_flush(base)
	want := slice.clone(sculptor_paint_shown(base), context.temp_allocator)
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, &pool, 64), "read failed")
	defer levels_destroy(&back)
	b := &levels_current(&back).sculptor
	testing.expect_value(t, len(b.paint.list), 2)
	testing.expect_value(t, sculptor_paint_picked(b), 1)
	testing.expect_value(t, sculptor_paint_layer_name(&b.paint.list[1]), "Paint 2")
	_ = sculptor_flush(b)
	testing.expect_value(t, len(sculptor_paint_shown(b)), len(want))
}
