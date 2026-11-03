package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A bumpy dense sphere carried onto a light one's skin: every sample lands on the dense
// surface, the gaps are small beside the bumps, and serial and parallel carries agree to
// the bit.
@(test)
skin_carry_takes_a_dense_surface :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	dense := skin_sphere_make(5, &pool)
	defer skin_sphere_free(dense)
	bump :: proc(p: Vec3) -> f32 {return 0.02 * math.sin(9 * p.x) * math.sin(9 * p.y)}
	for &p in dense.mesh.positions do p *= 1 + bump(p)
	sculptor_recompute_all(&dense.sculptor)

	carry :: proc(t: ^testing.T, dense: ^Skin_Sphere, pool: ^jobs.Pool) -> (heights: []f16, rep: Skin_Carry_Report, light: ^Skin_Sphere) {
		light = skin_sphere_with(2, 8, pool)
		rep = skin_carry(&light.sculptor, &dense.sculptor, 0.2)
		return slice.clone(light.sculptor.skin.heights, context.temp_allocator), rep, light
	}
	h_par, rep, light := carry(t, dense, &pool)
	defer skin_sphere_free(light)
	testing.expect_value(t, rep.lost, 0)
	testing.expectf(t, rep.worst < 0.02 && rep.mean < 0.004, "gaps: worst %v, mean %v", rep.worst, rep.mean)
	testing.expect(t, light.sculptor.skin.heat != nil)
	// Every sample's point, as the skin shows it over its curved base, sits on the bumpy
	// surface.
	sk := light.sculptor.skin
	S := sk.segments
	off := 0
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		b, n := skin_base(&light.sculptor, sk, tri, i, j)
		p := skin_point(&light.sculptor, sk, tri, i, j) + skin_curve(&light.sculptor, sk, tri, i, j, b, linalg.normalize0(n))
		u := linalg.normalize(p)
		if abs(linalg.length(p) - (1 + bump(u))) > 0.003 do off += 1
	}
	testing.expectf(t, off == 0, "%d samples off the surface", off)

	serial := skin_sphere_make(5)
	defer skin_sphere_free(serial)
	copy(serial.mesh.positions[:], dense.mesh.positions[:])
	sculptor_recompute_all(&serial.sculptor)
	h_ser, _, light2 := carry(t, serial, nil)
	defer skin_sphere_free(light2)
	testing.expect(t, slice.equal(h_par, h_ser), "serial and parallel carries differ")
}

// A skin carried onto a copy of its own mesh comes back as it was, near enough.
@(test)
skin_carry_reads_the_old_skin :: proc(t: ^testing.T) {
	old := skin_sphere_with(3, 4)
	defer skin_sphere_free(old)
	for &h, i in old.sculptor.skin.heights do h = f16(0.01 * math.sin(f32(i) * 0.37))
	fresh := skin_sphere_with(3, 4)
	defer skin_sphere_free(fresh)
	rep := skin_carry(&fresh.sculptor, &old.sculptor, 0.1)
	worst: f32
	for h, i in fresh.sculptor.skin.heights do worst = max(worst, abs(f32(h) - f32(old.sculptor.skin.heights[i])))
	testing.expectf(t, worst < 2e-4, "a height moved %v", worst)
	testing.expect_value(t, rep.lost, 0)
	testing.expect(t, skin_heat_drop(&fresh.sculptor))
	testing.expect(t, fresh.sculptor.skin.heat == nil)
	_ = geom.Mesh{}
}
