package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sphere whose top cap the mask holds (or, with On masked, the only part that moves),
// settled for `steps` steps onto a floor through its lowest point. Returns the settled
// mesh, the last step's motion and the positions it started from.
@(private = "file")
settle_run :: proc(t: ^testing.T, pool: ^jobs.Pool, steps: int, on_masked := false) -> (m: geom.Mesh, motion: f32, before: []Vec3) {
	m = geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, pool, 64)
	defer sculptor_destroy(&s)
	values := make([]u8, len(m.positions), context.temp_allocator)
	for p, v in m.positions do values[v] = 255 if p.y > 0.7 else 0
	testing.expect(t, sculptor_mask_values(&s, values, .Replace))
	before = slice.clone(m.positions[:], context.temp_allocator)
	set := CLOTH_DEFAULTS
	set.gravity, set.on_masked = 1, on_masked
	sculptor_stroke_begin(&s)
	n := sculptor_settle_begin(&s, set)
	testing.expect(t, n > 0 && n < len(m.positions), "settle should simulate the free part alone")
	sculptor_cloth_collide(&s, {floor = true, floor_at = {0, -1, 0}, floor_up = {0, 1, 0}})
	for _ in 0 ..< steps do motion = sculptor_settle_step(&s, {0, -1, 0})
	sculptor_cloth_end(&s)
	testing.expect(t, sculptor_stroke_end(&s), "settle should be an undo step")
	settled := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_undo(&s), "undo failed")
	testing.expect(t, slice.equal(m.positions[:], before), "undo should put every vertex back")
	copy(m.positions[:], settled)
	return
}

@(test)
settle_drapes_and_comes_to_rest :: proc(t: ^testing.T) {
	m, motion, before := settle_run(t, nil, 400)
	defer geom.mesh_destroy(&m)
	testing.expectf(t, motion < 0.01, "the cloth should come to rest, still moving %v links a step", motion)
	low, fell := f32(1e9), f32(0)
	for p, v in m.positions {
		low = min(low, p.y)
		if before[v].y > 0.7 do testing.expect_value(t, p, before[v])
		fell = max(fell, before[v].y - p.y)
	}
	testing.expectf(t, low > -1.001, "the floor should hold it, lowest %v", low)
	testing.expectf(t, fell > 0.2, "gravity should pull the free part down, at most %v", fell)

	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	b, _, _ := settle_run(t, &pool, 40)
	defer geom.mesh_destroy(&b)
	a, _, _ := settle_run(t, nil, 40)
	defer geom.mesh_destroy(&a)
	testing.expect(t, slice.equal(a.positions[:], b.positions[:]), "serial and parallel differ")
}

@(test)
settle_on_masked_moves_only_the_mask :: proc(t: ^testing.T) {
	m, _, before := settle_run(t, nil, 60, on_masked = true)
	defer geom.mesh_destroy(&m)
	moved := 0
	for p, v in m.positions {
		if before[v].y <= 0.7 do testing.expect_value(t, p, before[v])
		else if p != before[v] do moved += 1
	}
	testing.expect(t, moved > 10, "the masked cap should fall")
}

// The filters pull the free part (above y = 0) toward the shape they make, and drawn in,
// it folds rather than shrinking: its edges stay near their lengths, where the filter's
// own shape would halve some.
@(test)
filters_fold_the_free_part :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T, pool: ^jobs.Pool, kind: Cloth_Filter_Kind, amount: f32) -> (m: geom.Mesh, shrink: f32, before: []Vec3) {
		m = geom.icosphere(4)
		s: Sculptor
		sculptor_init(&s, &m, pool, 64)
		defer sculptor_destroy(&s)
		values := make([]u8, len(m.positions), context.temp_allocator)
		for p, v in m.positions do values[v] = 255 if p.y < 0 else 0
		testing.expect(t, sculptor_mask_values(&s, values, .Replace))
		before = slice.clone(m.positions[:], context.temp_allocator)
		sculptor_stroke_begin(&s)
		testing.expect(t, sculptor_filter_begin(&s, kind, axes = {.X}) > 0)
		for _ in 0 ..< 60 do _ = sculptor_filter_step(&s, amount, {0, -1, 0})
		sculptor_cloth_end(&s)
		testing.expect(t, sculptor_stroke_end(&s))
		shrink = 1
		for i := 0; i < len(m.indices); i += 3 {
			for e in 0 ..< 3 {
				a, b := m.indices[i + e], m.indices[i + (e + 1) % 3]
				if before[a].y < 0.05 || before[b].y < 0.05 do continue
				shrink = min(shrink, linalg.length(m.positions[a] - m.positions[b]) / linalg.length(before[a] - before[b]))
			}
		}
		return
	}
	for kind in Cloth_Filter_Kind {
		m, shrink, before := run(t, nil, kind, -1)
		defer geom.mesh_destroy(&m)
		moved: f32
		for p, v in m.positions {
			if before[v].y < 0 do testing.expect_value(t, p, before[v])
			moved = max(moved, linalg.length(p - before[v]))
		}
		testing.expectf(t, moved > 0.02, "%v moved the free part at most %v", kind, moved)
		testing.expectf(t, shrink > 0.65, "%v shrank an edge to %v of its length", kind, shrink)
	}
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a, _, _ := run(t, nil, .Scale, -0.5)
	defer geom.mesh_destroy(&a)
	b, _, _ := run(t, &pool, .Scale, -0.5)
	defer geom.mesh_destroy(&b)
	testing.expect(t, slice.equal(a.positions[:], b.positions[:]), "serial and parallel differ")
}
