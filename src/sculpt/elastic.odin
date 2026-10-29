package sculpt

import "core:math"
import "core:math/linalg"

// The Elastic brush (Blender's Elastic Deform): a grab whose weights are how an elastic
// solid moves when pulled at one point, so the part pulled keeps its shape, the surround
// stretches smoothly with no edge to the falloff, and Volume decides how much the sides
// thin as it stretches. The displacement of a point at r from the press, pulled by d, is
// a regularized Kelvinlet (de Goes and James, Regularized Kelvinlets, 2017):
//     u(r) = [A(r) I + B(r) r r^T] d,  A = (a - b) / re + a e^2 / (2 re^3),  B = b / re^3,
// with re = sqrt(|r|^2 + e^2), a = 1 / (4 pi mu), b = a / (4 (1 - nu)). Three scales e, 2e
// and 4e weighed 1, -1.25 and 0.25 (the paper's tri-scale, as Blender's) cancel the far
// field, and dividing by the value at the press makes the point pressed follow the
// pointer exactly, which leaves only Poisson's ratio nu to choose. It is linear in d, so
// it is a Grab follow matrix per vertex and everything Grab does (symmetry, undo, the
// drag modes) holds for it.

// How far Elastic reaches, in brush radii: the field is faded to nothing between
// ELASTIC_FADE and here (it is a tenth of the pull or less there, the most of it ahead of
// the pull), so a move costs a bounded reach rather than the whole mesh.
ELASTIC_REACH :: 3
ELASTIC_FADE :: 2

// The smallest scale, as a share of the brush radius, as Blender's: the point pressed and
// what lies within the ring move most, a fifth of the pull at the ring's edge.
ELASTIC_SCALE :: 1

@(private)
Kelvinlet :: struct {
	eps2:      [3]f32, // the three scales squared
	weights:   [3]f32,
	a, b:      f32,
	inv_tip:   f32, // 1 over A at the press, so the point pressed moves by the pull
	fade_from: f32,
	fade_to:   f32,
}

// The constants for a brush of `radius` keeping `volume` (0 to 1) of its volume: Poisson's
// ratio is half of it, a half being a solid that cannot be squeezed.
@(private)
kelvinlet_make :: proc(radius, volume: f32) -> (k: Kelvinlet) {
	nu := 0.5 * clamp(volume, 0, 1)
	k.a = 1
	k.b = k.a / (4 * (1 - nu))
	e := ELASTIC_SCALE * radius
	k.weights = {1, -1.25, 0.25}
	scales := [3]f32{1, 2, 4}
	tip: f32
	for i in 0 ..< 3 {
		ei := e * scales[i]
		k.eps2[i] = ei * ei
		tip += k.weights[i] * (1.5 * k.a - k.b) / ei
	}
	k.inv_tip = 1 / tip
	k.fade_from, k.fade_to = ELASTIC_FADE * radius, ELASTIC_REACH * radius
	return
}

// The follow matrix of a vertex at `r` from the press: u(r) over the pull, faded out
// toward the reach.
@(private)
kelvinlet_follow :: #force_inline proc(k: ^Kelvinlet, r: Vec3) -> (m: matrix[3, 3]f32) {
	d2 := linalg.dot(r, r)
	A, B: f32
	for i in 0 ..< 3 {
		re2 := d2 + k.eps2[i]
		re := math.sqrt(re2)
		re3 := re2 * re
		A += k.weights[i] * ((k.a - k.b) / re + k.a * k.eps2[i] / (2 * re3))
		B += k.weights[i] * k.b / re3
	}
	fade: f32 = 1
	if d := math.sqrt(d2); d > k.fade_from {
		t := clamp((k.fade_to - d) / (k.fade_to - k.fade_from), 0, 1)
		fade = t * t * (3 - 2 * t)
	}
	A *= fade * k.inv_tip
	B *= fade * k.inv_tip
	for i in 0 ..< 3 {
		for c in 0 ..< 3 do m[i, c] = B * r[i] * r[c]
		m[i, i] += A
	}
	return
}
