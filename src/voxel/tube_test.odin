package voxel

import "core:math"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
tube_sphere :: proc(across: f32, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	return
}

@(private = "file")
top_at :: proc(c: ^Clay, x: f32, y: f32 = 0) -> f32 {
	hit, _, ok := clay_raycast(c, {x, y, 5}, {0, 0, -1})
	return hit.z if ok else -1
}

// A Tube stroke as the app lays one: each point found straight down on the clay as it was
// at the press, the tube's axis `lift` of its radius out along the normal there, each dab
// joined to the last.
@(private = "file")
tube_stroke :: proc(c: ^Clay, xs: []f32, radius: f32, lift: f32, invert := false) {
	clay_stroke_begin(c)
	from: Vec3
	for x, i in xs {
		hit, normal, ok := clay_raycast_press(c, {x, 0, 5}, {0, 0, -1})
		if !ok do continue
		at := hit + normal * (radius * lift)
		if i == 0 do from = at
		_ = clay_dab(c, {kind = .Tube, radius = radius, strength = 1, invert = invert, normal = normal, from = from}, at)
		from = at
	}
	_ = clay_stroke_end(c)
}

@(private = "file")
tube_closed :: proc(t: ^testing.T, c: ^Clay) {
	m := clay_to_mesh(c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted && check.degenerate_triangles == 0, "%v", check)
}

@(test)
a_tube_lays_an_even_rope_and_passing_back_adds_nothing :: proc(t: ^testing.T) {
	r: f32 = 0.08
	path: [dynamic]f32
	defer delete(path)
	for i in 0 ..= 12 do append(&path, -0.3 + f32(i) * 0.05)
	tops: [2][9]f32
	voxel: f32
	for back, k in ([2]bool{false, true}) {
		c := tube_sphere(256)
		defer clay_destroy(&c)
		voxel = c.volume.voxel
		xs := make([dynamic]f32, context.temp_allocator)
		append(&xs, ..path[:])
		// There and back again in the same stroke.
		if back do for i := len(path) - 1; i >= 0; i -= 1 do append(&xs, path[i])
		tube_stroke(&c, xs[:], r, 0.5)
		for j in 0 ..< 9 do tops[k][j] = top_at(&c, -0.2 + f32(j) * 0.05)
		if back do tube_closed(t, &c)
	}
	// The axis runs round the sphere at 1 + r/2, so the rope's top is that far plus r.
	big := 1 + 0.5 * r
	for j in 0 ..< 9 {
		x := -0.2 + f32(j) * 0.05
		want := math.sqrt(big * big - x * x) + r
		testing.expectf(t, math.abs(tops[0][j] - want) < voxel, "at %v the rope's top is at %v, it should be at %v", x, tops[0][j], want)
		testing.expectf(t, math.abs(tops[1][j] - tops[0][j]) < 0.5 * voxel, "at %v going back raised the rope from %v to %v", x, tops[0][j], tops[1][j])
	}
	c := tube_sphere(256)
	defer clay_destroy(&c)
	tube_stroke(&c, path[:], r, 0.5)
	side := top_at(&c, 0, 0.3)
	testing.expectf(t, math.abs(side - math.sqrt(f32(1 - 0.09))) < voxel, "beside the rope the surface moved to %v", side)
}

@(test)
an_inverted_tube_carves_a_groove :: proc(t: ^testing.T) {
	c := tube_sphere(256)
	defer clay_destroy(&c)
	r: f32 = 0.08
	xs := [?]f32{-0.2, -0.1, 0, 0.1, 0.2}
	tube_stroke(&c, xs[:], r, 0, invert = true)
	testing.expectf(t, top_at(&c, 0) < 1 - 0.9 * r, "the groove's floor is at %v", top_at(&c, 0))
	tube_closed(t, &c)
}

@(test)
a_tube_is_the_same_on_any_thread_count_and_undoes_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{tube_sphere(128), tube_sphere(128, &pool)}
	defer for &c in clays do clay_destroy(&c)
	before := clay_hash(&clays[0])
	xs := [?]f32{-0.3, -0.15, 0, 0.15, 0.3}
	for &c in clays do tube_stroke(&c, xs[:], 0.1, 0.5)
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "the tube differs between one thread and three")
	testing.expect(t, clay_hash(&clays[0]) != before, "the tube changed nothing")
	testing.expect(t, clay_undo(&clays[0]) && clay_hash(&clays[0]) == before, "undo left the field changed")
}
