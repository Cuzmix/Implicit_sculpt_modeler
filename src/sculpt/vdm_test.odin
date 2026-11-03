package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// VDM stamps (vdm.odin): Draw with a vector alpha, on vertices and into the skin.

@(private = "file")
VDM_AT :: Vec3{0, 0, 1}

// A horn stamped on a dense sphere's vertices rises about its height at the middle and
// curls toward the alpha's up, moving the far side of its base past the near side.
@(test)
vdm_horn_on_vertices_rises_and_curls :: proc(t: ^testing.T) {
	mesh := geom.icosphere(5)
	defer geom.mesh_destroy(&mesh)
	s: Sculptor
	sculptor_init(&s, &mesh, nil, 64)
	defer sculptor_destroy(&s)
	horn := vdm_make(.Horn, 64)
	defer alpha_destroy(&horn)
	before := slice.clone(mesh.positions[:], context.temp_allocator)
	radius: f32 = 0.3
	testing.expect(t, apply_dab(&s, {kind = .Draw, radius = radius, strength = 1, alpha = &horn, alpha_up = {0, 1, 0}}, VDM_AT) > 0)
	rise, lean: f32
	for p, v in mesh.positions {
		d := p - before[v]
		rise = max(rise, d.z)
		lean = max(lean, d.y)
	}
	testing.expectf(t, rise > 0.8 * 1.6 * radius && rise < 1.1 * 1.6 * radius, "the horn rose %v for %v", rise, 1.6 * radius)
	testing.expectf(t, lean > 0.5 * radius, "the horn leaned only %v toward its up", lean)
}

// A stamp into the skin moves no vertex and puts the horn into heights and the vector
// page; a stamp whose size the routing splits gives about the same horn as one that goes
// all into the skin, the vertices taking the broad part.
@(test)
vdm_into_the_skin_and_split :: proc(t: ^testing.T) {
	horn := vdm_make(.Horn, 64)
	defer alpha_destroy(&horn)
	tips: [2]Vec3
	for split, k in ([2]bool{false, true}) {
		sp := skin_sphere_with(3, 16)
		defer skin_sphere_free(sp)
		s := &sp.sculptor
		verts := slice.clone(sp.mesh.positions[:], context.temp_allocator)
		before := side_points_by_sample(s)
		radius: f32 = 0.2
		testing.expect(t, apply_dab(s, {kind = .Draw, radius = radius, strength = 1, alpha = &horn, alpha_up = {0, 1, 0}, skin = true, skin_split = split}, VDM_AT) > 0)
		if !split do testing.expect(t, slice.equal(sp.mesh.positions[:], verts), "a skin stamp moved a vertex")
		if split do testing.expect(t, !slice.equal(sp.mesh.positions[:], verts), "a split stamp moved no vertex")
		testing.expect(t, s.skin.side != nil, "no vector page")
		after := side_points_by_sample(s)
		for p, i in after {
			if p.z - before[i].z > tips[k].z do tips[k] = p - before[i]
		}
	}
	testing.expectf(t, tips[0].z > 0.25 && tips[0].y > 0.02, "the skin's horn tip moved %v", tips[0])
	testing.expectf(t, linalg.length(tips[1] - tips[0]) < 0.25 * tips[0].z, "split %v against skin %v", tips[1], tips[0])
}

// Every sample's point on the skin, by sample.
@(private = "file")
side_points_by_sample :: proc(s: ^Sculptor) -> []Vec3 {
	sk := s.skin
	I := s.mesh.indices[:]
	S := sk.segments
	out := make([]Vec3, len(sk.heights), context.temp_allocator)
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		out[skin_sample(sk, I, t, i, j)] = skin_point(s, sk, t, i, j)
	}
	return out
}

// An image of offsets becomes a VDM alpha of the right size, whose grey values follow
// the offsets' lengths.
@(test)
vdm_from_vectors_keeps_the_offsets :: proc(t: ^testing.T) {
	src := make([][3]f32, 8 * 8, context.temp_allocator)
	src[3 * 8 + 4] = {0.1, 0.2, 0.5}
	a, ok := alpha_from_vectors(src, 8, 8)
	defer alpha_destroy(&a)
	testing.expect(t, ok && a.size == 8)
	testing.expect_value(t, a.vectors[3 * 8 + 4], [3]f32{0.1, 0.2, 0.5})
	testing.expect_value(t, a.values[3 * 8 + 4], 1)
	testing.expect_value(t, a.values[0], 0)
	_, empty := alpha_from_vectors(nil, 0, 0)
	testing.expect(t, !empty)
}

// Each file convention reads back what it wrote, to the bit, and the conventions agree on
// which way is out of the surface.
@(test)
vdm_axes_round_trip :: proc(t: ^testing.T) {
	v := Vec3{0.25, -0.5, 0.75}
	for axes in Vdm_Axes {
		testing.expectf(t, vdm_from_file(vdm_to_file(v, axes), axes) == v, "%v changed the offset", axes)
		testing.expectf(t, vdm_from_file({0, 0, 0}, axes) == {}, "%v moved a zero", axes)
	}
	testing.expect_value(t, vdm_from_file({0, 0.5, 0}, .ZBrush).z, 2)
	testing.expect_value(t, vdm_from_file({0, 0, 0.5}, .Blender).z, 1)
}

// A capture of a slab whose skin stands a little off its top everywhere reads that as the
// stamp's height over the whole face, and nothing sideways; a slab untouched captures
// nothing; and with sideways offsets in the skin the capture carries them.
@(test)
vdm_capture_reads_the_skin :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 2)
	defer jobs.pool_destroy(&pool)
	m, ok := geom.primitive(.Plane, 3000, &pool)
	testing.expect(t, ok)
	s: Sculptor
	sculptor_init(&s, &m, &pool)
	for id in 0 ..< len(s.nodes) do mark_stale(&s, u32(id), .Shape)
	_ = sculptor_flush(&s)
	defer {
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
	testing.expect(t, sculptor_skin_set(&s, 4))
	flat, why := vdm_capture(&s, 32)
	testing.expect_value(t, why, "")
	most: f32
	for v in flat.vectors do most = max(most, linalg.length(v))
	testing.expectf(t, most < 0.02, "an untouched slab captured an offset of %v", most)
	alpha_destroy(&flat)

	for &h in s.skin.heights do h = 0.02
	raised, _ := vdm_capture(&s, 32)
	defer alpha_destroy(&raised)
	// The middle of the stamp, well inside the slab's flat top (half width 0.8 or so).
	mid := raised.vectors[16 * 32 + 16]
	testing.expectf(t, abs(mid.z - 0.02 / 0.8) < 0.004 && abs(mid.x) < 0.002 && abs(mid.y) < 0.002, "the middle read %v", mid)

	skin_side_fit(s.skin, s.history.allocator)
	for &sd in s.skin.side do sd = {0.03, 0}
	for &h in s.skin.heights do h = 0
	side, _ := vdm_capture(&s, 32)
	defer alpha_destroy(&side)
	m2 := side.vectors[16 * 32 + 16]
	sideways := linalg.length(m2.xy)
	testing.expectf(t, abs(sideways - 0.03 / 0.8) < 0.006 && abs(m2.z) < 0.004, "the middle read %v", m2)
}
