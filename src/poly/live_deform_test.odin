package poly

import "core:math"
import "core:math/linalg"
import "core:testing"

// Twisting a tall box keeps its middle slice still and turns its ends by half the amount
// each way; tapering keeps its low end and widens its high one; bending a quarter turn
// tips the top's normal a quarter turn; none of them changes the topology.
@(test)
deform_bends_twists_and_tapers_along_an_axis :: proc(t: ^testing.T) {
	cage := primitive(.Cube, {across = 2})
	defer mesh_destroy(&cage)
	for &p in cage.positions do p.y *= 3
	b := mesh_bounds(&cage)
	twist := Live{deform = .Twist, deform_axis = .Y, deform_amount = math.PI / 2}
	lm, err := live_build(&cage, twist)
	defer live_mesh_destroy(&lm)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, len(lm.mesh.positions), len(cage.positions))
	for p, v in cage.positions {
		q := lm.mesh.positions[v]
		// The distance from the axis and the height stay.
		testing.expectf(t, abs(linalg.length(q.xz) - linalg.length(p.xz)) < 1e-4 && abs(q.y - p.y) < 1e-5, "%v -> %v", p, q)
		if abs(p.y) < 1e-6 do testing.expectf(t, linalg.length(q - p) < 1e-5, "middle moved: %v -> %v", p, q)
	}
	taper := Live{deform = .Taper, deform_axis = .Y, deform_amount = 1}
	lt, _ := live_build(&cage, taper)
	defer live_mesh_destroy(&lt)
	for p, v in cage.positions {
		q := lt.mesh.positions[v]
		want: f32 = 1 if abs(p.y - b.lo.y) < 1e-6 else (2 if abs(p.y - b.hi.y) < 1e-6 else 1.5)
		testing.expectf(t, abs(q.x - p.x * want) < 1e-4 && abs(q.z - p.z * want) < 1e-4, "%v -> %v, want x%v", p, q, want)
	}
	bend := Live{deform = .Bend, deform_axis = .Y, deform_amount = math.PI / 2}
	lb, _ := live_build(&cage, bend)
	defer live_mesh_destroy(&lb)
	c0 := mesh_check(&lb.mesh)
	testing.expectf(t, check_ok(c0) && c0.border_edges == 0, "%v", c0)
	top := u32(0)
	for f in 0 ..< u32(len(cage.face_he)) do if face_normal(&cage, f).y > 0.9 do top = f
	n := face_normal(&lb.mesh, top)
	// Half of a quarter turn round X at the top: its normal, up at the start, leans
	// halfway to Z.
	testing.expectf(t, abs(n.y - math.SQRT_TWO / 2) < 0.02 && abs(abs(n.z) - math.SQRT_TWO / 2) < 0.02, "top normal %v", n)
}

// Displace moves points along their normals by a noise of their place: the sphere stays
// closed, its points move by at most the strength, and the same cage gives the same
// surface again.
@(test)
displace_pushes_points_by_a_repeatable_noise :: proc(t: ^testing.T) {
	cage := primitive(.Sphere, {across = 6})
	defer mesh_destroy(&cage)
	a := mesh_clone(cage)
	defer mesh_destroy(&a)
	b := mesh_clone(cage)
	defer mesh_destroy(&b)
	live_displace(&a, 0.1, 0.3)
	live_displace(&b, 0.1, 0.3)
	c := mesh_check(&a)
	testing.expectf(t, check_ok(c) && c.border_edges == 0, "%v", c)
	moved := 0
	for p, v in cage.positions {
		d := linalg.length(a.positions[v] - p)
		testing.expectf(t, d <= 0.1 + 1e-5, "moved %v", d)
		if d > 1e-4 do moved += 1
		testing.expect(t, a.positions[v] == b.positions[v])
	}
	testing.expectf(t, moved > len(cage.positions) / 2, "%d of %d moved", moved, len(cage.positions))
	for i in 0 ..< 200 {
		x := live_noise({f32(i) * 0.37, f32(i) * 0.11, -f32(i) * 0.23})
		testing.expect(t, x >= -1 && x <= 1)
	}
}
