package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// Mean of |length now / length before - 1| over the edges with a moved end.
@(private = "file")
mean_stretch :: proc(m: geom.Mesh, before: []Vec3) -> (stretch: f32, edges: int) {
	for tri in 0 ..< len(m.indices) / 3 {
		for k in 0 ..< 3 {
			a, b := m.indices[3 * tri + k], m.indices[3 * tri + (k + 1) % 3]
			if m.positions[a] == before[a] && m.positions[b] == before[b] do continue
			was := linalg.length(before[a] - before[b])
			stretch += abs(linalg.length(m.positions[a] - m.positions[b]) / was - 1)
			edges += 1
		}
	}
	if edges > 0 do stretch /= f32(edges)
	return
}

@(private = "file")
cloth_run :: proc(pool: ^jobs.Pool, mode: Cloth_Mode, steps: int, brush := Brush{kind = .Cloth, radius = 0.3, strength = 1}) -> (m: geom.Mesh, before: []Vec3) {
	m = geom.icosphere(5)
	before = make([]Vec3, len(m.positions), context.temp_allocator)
	s: Sculptor
	sculptor_init(&s, &m, pool, 96)
	defer sculptor_destroy(&s)
	copy(before, m.positions[:])
	sculptor_stroke_begin(&s)
	testing_center := Vec3{0, 0, 1}
	_ = sculptor_cloth_begin(&s, brush, testing_center, mode)
	for i in 1 ..= steps {
		_ = sculptor_cloth_step(&s, {0.3 * f32(i) / f32(steps), 0, 0}, {0, -1, 0})
	}
	sculptor_cloth_end(&s)
	_ = sculptor_stroke_end(&s)
	_ = sculptor_flush(&s)
	return
}

@(test)
cloth_drag_follows_the_pointer_without_stretching_and_stays_in_its_region :: proc(t: ^testing.T) {
	m, before := cloth_run(nil, .Drag, 30)
	defer geom.mesh_destroy(&m)
	reach := f32(0.3 * CLOTH_REACH)
	moved := 0
	for p, i in m.positions {
		if linalg.length(before[i] - {0, 0, 1}) >= reach {
			testing.expect_value(t, p, before[i])
		} else if p != before[i] {
			moved += 1
		}
	}
	testing.expect(t, moved > 100, "the cloth did not move")
	// The vertex at the brush's centre went where the pointer dragged it.
	nearest, best := 0, f32(1e9)
	for p, i in before do if d := linalg.length(p - {0, 0, 1}); d < best do nearest, best = i, d
	testing.expectf(t, linalg.length(m.positions[nearest] - before[nearest] - {0.3, 0, 0}) < 0.02, "centre moved by %v", m.positions[nearest] - before[nearest])
	// Grab drags the same way but stretches; cloth keeps the edges near their lengths.
	cloth, _ := mean_stretch(m, before)
	g := geom.icosphere(5)
	defer geom.mesh_destroy(&g)
	s: Sculptor
	sculptor_init(&s, &g, nil, 96)
	defer sculptor_destroy(&s)
	gb := make([]Vec3, len(g.positions), context.temp_allocator)
	copy(gb, g.positions[:])
	_ = sculptor_grab_begin(&s, {kind = .Grab, radius = 0.3, strength = 1}, {0, 0, 1})
	_ = sculptor_grab_move(&s, {0.3, 0, 0})
	grab, _ := mean_stretch(g, gb)
	testing.expectf(t, cloth < grab * 0.75, "cloth stretch %v should be well under grab's %v", cloth, grab)
}

@(test)
cloth_gravity_sags_and_pinch_gathers :: proc(t: ^testing.T) {
	m, before := cloth_run(nil, .Gravity, 20)
	defer geom.mesh_destroy(&m)
	sag: f32
	for p, i in m.positions do sag += before[i].y - p.y
	testing.expectf(t, sag > 0, "gravity should pull the region down, moved %v", sag)

	p, pb := cloth_run(nil, .Pinch, 20)
	defer geom.mesh_destroy(&p)
	closer := 0
	for q, i in p.positions {
		if q == pb[i] do continue
		if linalg.length(q.xy) < linalg.length(pb[i].xy) do closer += 1
	}
	testing.expect(t, closer > 50, "pinch should gather the cloth toward the brush")
}

@(test)
cloth_serial_and_parallel_agree :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for mode in Cloth_Mode {
		a, _ := cloth_run(nil, mode, 12, {kind = .Cloth, radius = 0.6, strength = 1})
		defer geom.mesh_destroy(&a)
		b, _ := cloth_run(&pool, mode, 12, {kind = .Cloth, radius = 0.6, strength = 1})
		defer geom.mesh_destroy(&b)
		for p, i in a.positions do if b.positions[i] != p {
			testing.expectf(t, false, "%v: vertex %d differs", mode, i)
			break
		}
	}
}

@(test)
cloth_stroke_undoes :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_ = sculptor_flush(&s)
	before := make([]Vec3, len(m.positions), context.temp_allocator)
	copy(before, m.positions[:])
	sculptor_stroke_begin(&s)
	_ = sculptor_cloth_begin(&s, {kind = .Cloth, radius = 0.4, strength = 1}, {0, 0, 1}, .Drag)
	for i in 1 ..= 5 do _ = sculptor_cloth_step(&s, {0, 0.05 * f32(i), 0}, {0, -1, 0})
	sculptor_cloth_end(&s)
	testing.expect(t, sculptor_stroke_end(&s), "the stroke should be an undo step")
	testing.expect(t, sculptor_undo(&s), "undo failed")
	for p, i in m.positions do testing.expect_value(t, p, before[i])
}
