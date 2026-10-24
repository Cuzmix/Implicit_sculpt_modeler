package geom

// Response curves: a cubic Bézier from (0, 0) to (1, 1) with two control points, as
// drawing programs offer for pen pressure (CSS's cubic-bezier is the same curve). With
// both controls' x in [0, 1], x grows with the curve's parameter, so every x in [0, 1]
// has exactly one y.

Curve :: struct {
	c1, c2: [2]f32,
}

// y = x.
CURVE_LINEAR :: Curve{{1.0 / 3, 1.0 / 3}, {2.0 / 3, 2.0 / 3}}

// The curve's y at x, 0 below the range and 1 above: the parameter where the curve
// reaches x is found by bisection, which needs no derivative and so stays accurate
// where the curve is flat or steep, then y is read there.
curve_at :: proc(curve: Curve, x: f32) -> f32 {
	// The ends exactly: where x barely moves with the parameter, the bisection stops
	// short of them in f32.
	if x <= 0 do return 0
	if x >= 1 do return 1
	c := curve_clamped(curve)
	lo, hi: f32 = 0, 1
	for _ in 0 ..< 24 {
		mid := 0.5 * (lo + hi)
		if bezier(c.c1.x, c.c2.x, mid) < x {
			lo = mid
		} else {
			hi = mid
		}
	}
	return clamp(bezier(c.c1.y, c.c2.y, 0.5 * (lo + hi)), 0, 1)
}

// The curve with its control points inside the unit square, where curve_at needs them.
curve_clamped :: proc(c: Curve) -> Curve {
	return {{clamp(c.c1.x, 0, 1), clamp(c.c1.y, 0, 1)}, {clamp(c.c2.x, 0, 1), clamp(c.c2.y, 0, 1)}}
}

// One coordinate of the cubic Bézier through 0, a, b, 1 at parameter t.
@(private = "file")
bezier :: #force_inline proc(a, b, t: f32) -> f32 {
	u := 1 - t
	return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
}
