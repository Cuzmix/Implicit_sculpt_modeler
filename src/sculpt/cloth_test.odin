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
cloth_run :: proc(pool: ^jobs.Pool, mode: Cloth_Mode, steps: int, brush := Brush{kind = .Cloth, radius = 0.3, strength = 1}, settings := CLOTH_DEFAULTS, level := 5, center := Vec3{0, 0, 1}) -> (m: geom.Mesh, before: []Vec3) {
	m = geom.icosphere(level)
	before = make([]Vec3, len(m.positions), context.temp_allocator)
	s: Sculptor
	sculptor_init(&s, &m, pool, 96)
	defer sculptor_destroy(&s)
	copy(before, m.positions[:])
	sculptor_stroke_begin(&s)
	_ = sculptor_cloth_begin(&s, brush, center, mode, settings)
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
	// Gravity is a setting of every mode now; Push with no strength only lets it pull.
	m, before := cloth_run(nil, .Push, 20, {kind = .Cloth, radius = 0.3, strength = 0}, {region = .Local, stiffness = 1, firmness = 0.5, damping = 0.08, gravity = 1})
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
cloth_modes_move_the_way_they_say :: proc(t: ^testing.T) {
	// Push dents the top of the sphere in, Inflate swells it out, Expand spreads it.
	push, pb := cloth_run(nil, .Push, 20)
	defer geom.mesh_destroy(&push)
	inflate, ib := cloth_run(nil, .Inflate, 20)
	defer geom.mesh_destroy(&inflate)
	expand, eb := cloth_run(nil, .Expand, 20)
	defer geom.mesh_destroy(&expand)
	twist, tb := cloth_run(nil, .Twist, 20)
	defer geom.mesh_destroy(&twist)
	dent, swell, spread, turned: f32
	for i in 0 ..< len(pb) {
		dent += linalg.length(pb[i]) - linalg.length(push.positions[i])
		swell += linalg.length(inflate.positions[i]) - linalg.length(ib[i])
		spread += linalg.length(expand.positions[i].xy) - linalg.length(eb[i].xy)
		// Twist turns about the normal (z here): the angle round it grows one way.
		if linalg.length(tb[i].xy) > 0.05 && tb[i].z > 0.9 do turned += linalg.cross(tb[i].xy, twist.positions[i].xy - tb[i].xy)
	}
	testing.expectf(t, dent > 0, "push should dent the surface in, %v", dent)
	testing.expectf(t, swell > 0, "inflate should swell the surface out, %v", swell)
	testing.expectf(t, spread > 0, "expand should spread the cloth out, %v", spread)
	testing.expectf(t, turned > 0, "twist should turn the cloth about the normal, %v", turned)
}

@(test)
cloth_allow_expand_stretches_and_firmness_matters :: proc(t: ^testing.T) {
	// Without bending, so only the edges carry the drag.
	set := CLOTH_DEFAULTS
	set.firmness = 0
	held, hb := cloth_run(nil, .Drag, 30, settings = set)
	defer geom.mesh_destroy(&held)
	set.allow_expand = true
	loose, lb := cloth_run(nil, .Drag, 30, settings = set)
	defer geom.mesh_destroy(&loose)
	// Held, the cloth outside the brush is pulled along; let stretch, it stays behind.
	a, b: f32
	for i in 0 ..< len(hb) do if linalg.length(hb[i] - {0, 0, 1}) > 0.3 {
		a += linalg.length(held.positions[i] - hb[i])
		b += linalg.length(loose.positions[i] - lb[i])
	}
	testing.expectf(t, b < a * 0.8, "allowing edges to grow should leave the cloth behind: %v against %v", b, a)

	set = CLOTH_DEFAULTS
	set.firmness = 1
	firm, _ := cloth_run(nil, .Pinch, 20, settings = set)
	defer geom.mesh_destroy(&firm)
	set.firmness = 0
	soft, _ := cloth_run(nil, .Pinch, 20, settings = set)
	defer geom.mesh_destroy(&soft)
	differ := 0
	for p, i in firm.positions do if p != soft.positions[i] do differ += 1
	testing.expect(t, differ > 50, "firmness should change how the cloth folds")
}

@(test)
cloth_keep_area_pulls_toward_the_morph_target :: proc(t: ^testing.T) {
	// A sphere shrunk to 0.9 with the full-size one as its morph target: Keep area's
	// edges are longer than they are, so the free cloth swells back out.
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	sculptor_morph_store(&s)
	for &p in m.positions do p *= 0.9
	sculptor_nodes_moved(&s, {})
	_ = sculptor_flush(&s)
	before := make([]Vec3, len(m.positions), context.temp_allocator)
	copy(before, m.positions[:])
	set := CLOTH_DEFAULTS
	set.keep_area = true
	sculptor_stroke_begin(&s)
	_ = sculptor_cloth_begin(&s, {kind = .Cloth, radius = 0.5, strength = 0}, {0, 0, 0.9}, .Push, set)
	for _ in 1 ..= 20 do _ = sculptor_cloth_step(&s, {}, {0, -1, 0})
	sculptor_cloth_end(&s)
	_ = sculptor_stroke_end(&s)
	grew: f32
	for p, i in m.positions do grew += linalg.length(p) - linalg.length(before[i])
	testing.expectf(t, grew > 0, "keep area should grow the shrunk cloth back, %v", grew)
}

@(test)
cloth_symmetry_moves_both_halves_as_mirror_images :: proc(t: ^testing.T) {
	brush := Brush{kind = .Cloth, radius = 0.35, strength = 1, symmetry = {.X}}
	m, before := cloth_run(nil, .Pinch, 15, brush, level = 4, center = linalg.normalize(Vec3{0.5, 0, 0.85}))
	defer geom.mesh_destroy(&m)
	checked := 0
	for p, i in m.positions {
		if p == before[i] || before[i].x <= 0.05 do continue
		mirror := Vec3{-before[i].x, before[i].y, before[i].z}
		for q, k in before do if linalg.length(q - mirror) < 1e-5 {
			got := m.positions[k]
			testing.expectf(t, linalg.length(got - Vec3{-p.x, p.y, p.z}) < 1e-4, "vertex %d moved to %v, its mirror %d to %v", i, p, k, got)
			checked += 1
			break
		}
	}
	testing.expect(t, checked > 30, "too few mirrored vertices moved")
}

@(test)
cloth_regions_reach_as_far_as_they_say :: proc(t: ^testing.T) {
	reach := f32(0.3 * CLOTH_REACH)
	// Whole: gravity moves vertices far from the brush.
	set := CLOTH_DEFAULTS
	set.region, set.gravity = .Whole, 1
	whole, wb := cloth_run(nil, .Push, 10, {kind = .Cloth, radius = 0.3, strength = 0}, set, level = 4)
	defer geom.mesh_destroy(&whole)
	far := 0
	for p, i in whole.positions do if p != wb[i] && linalg.length(wb[i] - {0, 0, 1}) > 2 * reach do far += 1
	testing.expect(t, far > 100, "the whole mesh should hang under gravity")
	// Follows: a drag of 0.6 carries the region along, past where Local stops.
	set = CLOTH_DEFAULTS
	set.region = .Follows
	follows, fb := cloth_run(nil, .Pinch, 30, settings = set)
	defer geom.mesh_destroy(&follows)
	past := 0
	for p, i in follows.positions do if p != fb[i] && linalg.length(fb[i] - {0, 0, 1}) >= reach do past += 1
	testing.expect(t, past > 20, "the follows region should move where the brush went")
}

@(test)
cloth_serial_and_parallel_agree :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	set := CLOTH_DEFAULTS
	set.gravity = 0.5
	for mode in Cloth_Mode {
		set.region = .Follows if mode == .Pinch_Line else .Local
		brush := Brush{kind = .Cloth, radius = 0.6, strength = 1, symmetry = {.X} if mode == .Twist else {}}
		a, _ := cloth_run(nil, mode, 12, brush, set)
		defer geom.mesh_destroy(&a)
		b, _ := cloth_run(&pool, mode, 12, brush, set)
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
