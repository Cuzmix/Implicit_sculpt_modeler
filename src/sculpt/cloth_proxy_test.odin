package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sphere whose top cap the mask holds, settled through a proxy of about `budget` free
// vertices for `steps` steps onto a floor through its lowest point and written back.
// Returns the settled mesh and where it began; checks that undo puts it back.
@(private = "file")
proxy_run :: proc(t: ^testing.T, pool: ^jobs.Pool, budget, steps: int, level := 5) -> (m: geom.Mesh, before: []Vec3) {
	m = geom.icosphere(level)
	s: Sculptor
	sculptor_init(&s, &m, pool, 64)
	defer sculptor_destroy(&s)
	values := make([]u8, len(m.positions), context.temp_allocator)
	for p, v in m.positions do values[v] = 255 if p.y > 0.7 else 0
	testing.expect(t, sculptor_mask_values(&s, values, .Replace))
	before = slice.clone(m.positions[:], context.temp_allocator)
	sculptor_stroke_begin(&s)
	p: Cloth_Proxy
	defer cloth_proxy_destroy(&p)
	testing.expect(t, sculptor_proxy_build(&p, &s, budget, false))
	coarse := len(p.mesh.positions)
	testing.expectf(t, coarse < len(m.positions) / 3, "the proxy should be coarse: %d of %d vertices", coarse, len(m.positions))
	set := CLOTH_DEFAULTS
	set.gravity = 1
	n := sculptor_settle_begin(&p.sculptor, set)
	testing.expectf(t, n > 0 && n <= budget * 3 / 2, "the proxy should simulate about the budget, %d", n)
	sculptor_cloth_collide(&p.sculptor, {floor = true, floor_at = {0, -1, 0}, floor_up = {0, 1, 0}})
	for _ in 0 ..< steps do _ = sculptor_settle_step(&p.sculptor, {0, -1, 0})
	sculptor_cloth_end(&p.sculptor)
	testing.expect(t, sculptor_proxy_write(&p, &s) > 0)
	testing.expect(t, sculptor_stroke_end(&s), "the write-back should be an undo step")
	settled := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_undo(&s), "undo failed")
	testing.expect(t, slice.equal(m.positions[:], before), "undo should put every vertex back")
	copy(m.positions[:], settled)
	return
}

// The proxy carries the cloth's drape onto the dense mesh: the masked cap stays put to
// the bit, the free part falls, the floor still holds it (within the copy's error), and
// the result is the same on any number of threads.
@(test)
proxy_settles_the_dense_mesh :: proc(t: ^testing.T) {
	m, before := proxy_run(t, nil, 1500, 120)
	defer geom.mesh_destroy(&m)
	low, fell := f32(1e9), f32(0)
	for p, v in m.positions {
		low = min(low, p.y)
		if before[v].y > 0.7 do testing.expect_value(t, p, before[v])
		fell = max(fell, before[v].y - p.y)
	}
	testing.expectf(t, low > -1.03, "the floor should hold it, lowest %v", low)
	testing.expectf(t, fell > 0.1, "gravity should pull the free part down, at most %v", fell)
	r := geom.mesh_check(m)
	testing.expectf(t, r.nan_count == 0, "the written mesh should stay sound: %v", r)

	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	// A mesh large enough to be simplified a run at a time.
	b, _ := proxy_run(t, &pool, 3000, 5, level = 7)
	defer geom.mesh_destroy(&b)
	a, _ := proxy_run(t, nil, 3000, 5, level = 7)
	defer geom.mesh_destroy(&a)
	testing.expect(t, slice.equal(a.positions[:], b.positions[:]), "serial and parallel differ")
}

// A proxy written back without a step puts every vertex where it was, to within rounding.
@(test)
proxy_write_without_a_step_keeps_the_mesh :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(m.positions[:], context.temp_allocator)
	sculptor_stroke_begin(&s)
	p: Cloth_Proxy
	defer cloth_proxy_destroy(&p)
	testing.expect(t, sculptor_proxy_build(&p, &s, 2000, false))
	_ = sculptor_proxy_write(&p, &s)
	_ = sculptor_stroke_end(&s)
	worst: f32
	for q, v in m.positions do worst = max(worst, linalg.length(q - before[v]))
	testing.expectf(t, worst < 1e-5, "the write-back moved a vertex %v", worst)
}
