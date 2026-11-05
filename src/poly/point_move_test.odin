package poly

import "core:math/linalg"
import "core:testing"

@(test)
a_point_move_mirrors_keeps_the_plane_and_eases_the_falloff :: proc(t: ^testing.T) {
	m := primitive(.Plane, {across = 4})
	defer mesh_destroy(&m)
	start := make([]Vec3, len(m.positions))
	defer delete(start)
	copy(start, m.positions[:])
	// The point at the most +X, middle Z.
	pick := NONE
	for p, v in m.positions do if p.x > 0.49 && abs(p.z) < 1e-4 do pick = u32(v)
	testing.expect(t, pick != NONE)
	up := matrix[3, 3]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}
	// Alone it moves and nothing else does.
	{
		plan := point_move_plan(&m, {pick}, {}, 0)
		defer point_move_destroy(&plan)
		testing.expect_value(t, len(plan.verts), 1)
		point_move_apply(&m, &plan, start, up, {0.1, 0.2, 0})
		testing.expect(t, linalg.length(m.positions[pick] - (start[pick] + {0.1, 0.2, 0})) < 1e-6)
		copy(m.positions[:], start)
	}
	// Under X symmetry its image moves the mirrored way, and a point on the Z plane keeps
	// its Z.
	{
		plan := point_move_plan(&m, {pick}, {.X, .Z}, 0)
		defer point_move_destroy(&plan)
		testing.expect_value(t, len(plan.verts), 2)
		point_move_apply(&m, &plan, start, up, {0.1, 0.2, 0.3})
		for v, i in plan.verts {
			want := start[v] + plan.signs[i] * Vec3{0.1, 0.2, 0.3}
			want.z = start[v].z
			testing.expectf(t, linalg.length(m.positions[v] - want) < 1e-6, "point %d at %v, want %v", v, m.positions[v], want)
			testing.expect(t, .Z in plan.planes[i])
		}
		copy(m.positions[:], start)
	}
	// A falloff reaching half the plane moves the near points by less, the far not at all.
	{
		plan := point_move_plan(&m, {pick}, {}, 0.5)
		defer point_move_destroy(&plan)
		testing.expect(t, len(plan.verts) > 1)
		for v, i in plan.verts {
			d := linalg.length(start[v] - start[pick])
			testing.expect(t, abs(plan.weights[i] - point_move_falloff(d, 0.5)) < 1e-6 || v == pick)
			testing.expect(t, d < 0.5)
		}
		testing.expect_value(t, point_move_falloff(0, 0.5), f32(1))
		testing.expect_value(t, point_move_falloff(0.5, 0.5), f32(0))
	}
}
