package sculpt

import "core:math/linalg"
import "core:testing"

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
