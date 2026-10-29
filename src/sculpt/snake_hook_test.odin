package sculpt

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

// A horn pulled straight up out of the sphere's top with `brush`, 10 steps of 0.05;
// returns how wide it is halfway up and whether the mesh stays closed.
@(private = "file")
horn :: proc(brush: Brush) -> (width: f32, closed: bool) {
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil)
	defer sculptor_destroy(&s)
	defer geom.mesh_destroy(&m)
	sculptor_recompute_all(&s)
	b := brush
	b.drag = {0, 0, 0.05}
	at := Vec3{0, 0, 1}
	sculptor_stroke_begin(&s)
	for _ in 0 ..< 10 {
		_ = apply_dab(&s, b, at)
		at += b.drag
	}
	_ = sculptor_stroke_end(&s)
	for p in m.positions do if p.z > 1.2 && p.z < 1.3 do width = max(width, linalg.length(p.xy))
	r := geom.mesh_check(m)
	return width, r.closed && r.degenerate_triangles == 0
}

// Pinch draws the horn in thinner and Magnify (pinch below zero) fattens it, both
// keeping the surface whole.
@(test)
snake_hook_pinch_thins_and_magnify_fattens :: proc(t: ^testing.T) {
	plain, plain_ok := horn({kind = .Snake_Hook, radius = 0.25, strength = 0.5})
	thin, thin_ok := horn({kind = .Snake_Hook, radius = 0.25, strength = 0.5, hook_pinch = 1})
	fat, fat_ok := horn({kind = .Snake_Hook, radius = 0.25, strength = 0.5, hook_pinch = -1})
	testing.expectf(t, thin < plain && plain < fat, "widths: pinched %.4f, plain %.4f, magnified %.4f", thin, plain, fat)
	testing.expect(t, plain_ok && thin_ok && fat_ok)
}

// The Elastic tip drags what lies past the ring too, fading out by ELASTIC_REACH radii,
// where the plain hook leaves it.
@(test)
snake_hook_elastic_tip_reaches_past_the_ring :: proc(t: ^testing.T) {
	moved_past :: proc(elastic: bool) -> (past, beyond: int) {
		m := geom.icosphere(5)
		s: Sculptor
		sculptor_init(&s, &m, nil)
		defer sculptor_destroy(&s)
		defer geom.mesh_destroy(&m)
		before := make([]Vec3, len(m.positions), context.temp_allocator)
		copy(before, m.positions[:])
		center := Vec3{0, 0, 1}
		_ = apply_dab(&s, {kind = .Snake_Hook, radius = 0.2, strength = 0.5, drag = {0, 0, 0.05}, hook_elastic = elastic, volume = 0.8}, center)
		for p, v in m.positions {
			if p == before[v] do continue
			d := linalg.length(before[v] - center)
			if d > 0.25 do past += 1
			if d >= ELASTIC_REACH * 0.2 do beyond += 1
		}
		return
	}
	plain, _ := moved_past(false)
	elastic, beyond := moved_past(true)
	testing.expectf(t, plain == 0 && elastic > 0 && beyond == 0, "past the ring: plain %d, elastic %d; beyond the reach %d", plain, elastic, beyond)
}

// Rake turns what the hook drags as the hook turns: a dab with a quarter turn about Z
// carries a point off the axis round it, by the falloff there; mirrored by X symmetry,
// the image turns the other way.
@(test)
snake_hook_rake_turns_with_the_hook :: proc(t: ^testing.T) {
	testing.expect(t, linalg.length(rotate_about({1, 0, 0}, {0, 0, 1}, math.PI / 2) - {0, 1, 0}) < 1e-6)
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil)
	defer sculptor_destroy(&s)
	defer geom.mesh_destroy(&m)
	before := make([]Vec3, len(m.positions), context.temp_allocator)
	copy(before, m.positions[:])
	center := linalg.normalize(Vec3{0.5, 0, 1})
	_ = apply_dab(&s, {kind = .Snake_Hook, radius = 0.3, strength = 0.5, drag = {0, 0, 1e-4}, hook_rake = 1, rake_axis = linalg.normalize(center), rake_angle = 0.5, symmetry = {.X}}, center)
	// About the axis through the press each side turns; mirrored across x = 0, what moves
	// on the right moves the mirrored way on the left: the same in y, opposite in x.
	right, left: Vec3
	for p, v in m.positions {
		if before[v].y < 0.05 do continue
		if before[v].x > 0.3 do right += p - before[v]
		if before[v].x < -0.3 do left += p - before[v]
	}
	testing.expectf(t, right.y != 0 && abs(right.y - left.y) < 1e-3 * abs(right.y) && abs(right.x + left.x) < 1e-3 * abs(right.y), "moved %v on the right, %v on the left", right, left)
}
