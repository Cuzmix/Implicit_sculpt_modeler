package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"

// A map read into the skin puts every sample where it says, over the curved base: a
// height map raises each flat point along its normal, an object-space vector map moves
// it bodily (through the vector page), and Undo brings the old skin back.
@(test)
skin_map_places_every_sample :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	sk := s.skin
	uvs := Skin_Uvs {
		uv      = make([][3][2]f32, sk.tri_count, context.temp_allocator),
		tangent = make([][3][4]f32, sk.tri_count, context.temp_allocator),
	}
	pixels := make([][3]f32, 4, context.temp_allocator)
	place :: proc(t: ^testing.T, s: ^Sculptor, want: proc(p, nu: Vec3) -> Vec3) {
		sk := s.skin
		S := sk.segments
		worst: f32
		for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			b, n := skin_base(s, sk, tri, i, j)
			nu := linalg.normalize0(n)
			at := skin_point(s, sk, tri, i, j) + skin_curve(s, sk, tri, i, j, b, nu)
			worst = max(worst, linalg.length(at - want(b, nu)))
		}
		testing.expectf(t, worst < 1e-4, "a sample is %v off", worst)
	}
	for &p in pixels do p = {0.75, 0, 0}
	testing.expect(t, sculptor_skin_from_map(s, {2, 2, pixels, .Height, 0.5, 0.04}, uvs))
	testing.expect(t, s.skin.side == nil, "a height map made a vector page")
	place(t, s, proc(p, nu: Vec3) -> Vec3 {return p + nu * 0.01})
	for &p in pixels do p = {0.01, -0.02, 0.015}
	testing.expect(t, sculptor_skin_from_map(s, {2, 2, pixels, .Object_Vector, 0, 1}, uvs))
	testing.expect(t, s.skin.side != nil)
	place(t, s, proc(p, nu: Vec3) -> Vec3 {return p + {0.01, -0.02, 0.015}})
	testing.expect(t, sculptor_undo(s))
	place(t, s, proc(p, nu: Vec3) -> Vec3 {return p + nu * 0.01})
	testing.expect(t, sculptor_undo(s))
	worst: f32
	for h in s.skin.heights do worst = max(worst, abs(f32(h)))
	testing.expect_value(t, worst, 0)
}

// The micro-map of a skin puts every grid vertex where the skin shows it: the flat point
// plus the interpolated vertex normal times its value, each triangle's values in
// bird-curve order; a vector page is reported folded.
@(test)
skin_bary_puts_every_vertex_where_the_skin_shows_it :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	sk := s.skin
	for &h, x in sk.heights do h = f16(0.002 * f32(x % 7) - 0.006)
	values, level, folded, ok := sculptor_skin_bary(s, context.temp_allocator)
	if !testing.expect(t, ok) do return
	testing.expect_value(t, level, 2)
	testing.expect(t, !folded)
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	N := s.mesh.normals[:]
	S := sk.segments
	per := u32(geom.bary_vertex_count(level))
	worst: f32
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		w := [3]f32{1 - f32(i + j) / f32(S), f32(i) / f32(S), f32(j) / f32(S)}
		flat, dir: Vec3
		for k in 0 ..< 3 {
			flat += P[I[3 * tri + u32(k)]] * w[k]
			dir += N[I[3 * tri + u32(k)]] * w[k]
		}
		b, n := skin_base(s, sk, tri, i, j)
		nu := linalg.normalize0(n)
		shown := skin_point(s, sk, tri, i, j) + skin_curve(s, sk, tri, i, j, b, nu)
		got := flat + dir * values[tri * per + geom.bary_bird_index(i, j, level)]
		worst = max(worst, linalg.length(got - shown))
	}
	testing.expectf(t, worst < 1e-5, "a grid vertex is %v from the skin", worst)
	skin_side_fit(sk, context.allocator)
	sk.side[3] = {0.01, 0}
	_, _, folded, _ = sculptor_skin_bary(s, context.temp_allocator)
	testing.expect(t, folded)
}
