package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"

// Draw with Accumulate off, dabs a fifth of a radius apart: the heights the stroke keeps
// are the falloff of each vertex's distance to the path itself, not the most of a row of
// round dabs, which scalloped at the dabs' spacing and drew ribs across the stroke.
@(test)
stroke_without_accumulate_is_smooth_between_dabs :: proc(t: ^testing.T) {
	mesh := geom.icosphere(6)
	defer geom.mesh_destroy(&mesh)
	s: Sculptor
	sculptor_init(&s, &mesh, nil, 64)
	defer sculptor_destroy(&s)
	_ = sculptor_flush(&s)
	brush := Brush{kind = .Draw, radius = 0.2, strength = 0.5, no_accumulate = true}
	centers: [dynamic]Vec3
	defer delete(centers)
	sculptor_stroke_begin(&s)
	for x := f32(-0.3); x <= 0.3; x += 0.04 {
		at := linalg.normalize(Vec3{x, 0, 1})
		append(&centers, at)
		_ = apply_dab(&s, brush, at)
	}
	_ = sculptor_stroke_end(&s)
	_ = sculptor_flush(&s)
	amount := brush.radius * brush.strength * DRAW_HEIGHT
	worst: f32
	checked := 0
	for p, v in mesh.positions {
		if abs(p.x) > 0.12 || p.z < 0.5 do continue
		// Its distance to the path the centres lay along.
		near := max(f32)
		for i in 1 ..< len(centers) {
			a, b := centers[i - 1], centers[i]
			k := clamp(linalg.dot(p - a, b - a) / linalg.dot(b - a, b - a), 0, 1)
			near = min(near, linalg.length(p - (a + (b - a) * k)))
		}
		if near > 0.85 * brush.radius do continue
		l := s.layer[v]
		h := l.height if l.stroke == s.layer_stroke else 0
		worst = max(worst, abs(h - amount * falloff(near * near / (brush.radius * brush.radius))))
		checked += 1
	}
	testing.expect(t, checked > 200, "too few vertices beside the stroke")
	testing.expectf(t, worst < 0.002 * amount, "the heights stray from the path's falloff by %v of %v", worst, amount)
}
