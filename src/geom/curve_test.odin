package geom

import "core:math"
import "core:testing"

@(test)
curve_linear_is_the_identity :: proc(t: ^testing.T) {
	worst: f32
	for i in 0 ..= 100 {
		x := f32(i) / 100
		worst = max(worst, abs(curve_at(CURVE_LINEAR, x) - x))
	}
	testing.expectf(t, worst < 1e-5, "linear curve is %v off", worst)
}

@(test)
curve_ends_hold_and_it_never_falls :: proc(t: ^testing.T) {
	curves := [?]Curve {
		{{0.1, 0.6}, {0.4, 0.95}}, // soft: little pressure goes far
		{{0.6, 0.05}, {0.95, 0.4}}, // firm
		{{0.5, 0}, {0.5, 1}},       // an S
		{{1, 0}, {0, 1}},           // controls crossed: the steepest middle allowed
		{{0, 1}, {1, 0}},           // and the flattest
		{{-1, 2}, {3, -1}},         // outside the square: clamped
	}
	for c in curves {
		testing.expectf(t, curve_at(c, 0) < 1e-5 && curve_at(c, 1) > 1 - 1e-5, "%v: ends at %v and %v", c, curve_at(c, 0), curve_at(c, 1))
		testing.expect(t, curve_at(c, -3) == curve_at(c, 0) && curve_at(c, 7) == curve_at(c, 1), "x outside [0, 1] is clamped")
		last: f32 = -1
		for i in 0 ..= 200 {
			y := curve_at(c, f32(i) / 200)
			testing.expectf(t, !math.is_nan(y) && y >= last - 1e-5, "%v falls at x = %v", c, f32(i) / 200)
			last = y
		}
	}
	soft := Curve{{0.1, 0.6}, {0.4, 0.95}}
	firm := Curve{{0.6, 0.05}, {0.95, 0.4}}
	testing.expect(t, curve_at(soft, 0.3) > 0.6 && curve_at(firm, 0.3) < 0.1, "soft gives more and firm less at light pressure")
}
