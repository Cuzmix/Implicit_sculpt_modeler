package voxel

import "core:math"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
warp_sphere :: proc(across: f32, pool: ^jobs.Pool = nil) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, pool)
	clay_fill_sphere(&c, {}, 1)
	return
}

// Where a ray down from (x, y, 5) meets the clay, or -1.
@(private = "file")
height_at :: proc(c: ^Clay, x: f32, y: f32 = 0) -> f32 {
	hit, _, ok := clay_raycast(c, {x, y, 5}, {0, 0, -1})
	return hit.z if ok else -1
}

@(private = "file")
closed_check :: proc(t: ^testing.T, c: ^Clay) {
	m := clay_to_mesh(c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted && check.degenerate_triangles == 0, "%v", check)
}

// Dabs of a Snake hook up from the top of the sphere, each where the last left the clay.
@(private = "file")
hook_stroke :: proc(c: ^Clay, radius: f32, dabs: int, step: Vec3) {
	clay_stroke_begin(c)
	at := Vec3{0, 0, 1}
	for _ in 0 ..< dabs {
		_ = clay_dab(c, {kind = .Snake_Hook, radius = radius, strength = 1, normal = {0, 0, 1}, drag = step}, at)
		at += step
	}
	_ = clay_stroke_end(c)
}

@(test)
a_snake_hook_pulls_a_horn_as_long_as_the_stroke :: proc(t: ^testing.T) {
	c := warp_sphere(128)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	hook_stroke(&c, 0.2, 16, {0, 0, 0.05})
	tip := height_at(&c, 0)
	testing.expectf(t, tip > 1.7 && tip < 1.8 + voxel, "the horn's tip is at %v, the stroke went to 1.8", tip)
	// Half way up there is clay, narrower than the brush; past the brush the side stayed.
	mid, _, ok := clay_raycast(&c, {5, 0, 1.4}, {-1, 0, 0})
	testing.expectf(t, ok && mid.x > 2 * voxel && mid.x < 0.2, "half way up the horn's side is at %v", mid)
	side, _, side_ok := clay_raycast(&c, {5, 0, 0}, {-1, 0, 0})
	testing.expectf(t, side_ok && math.abs(side.x - 1) < 0.5 * voxel, "the side moved to %v", side)
	closed_check(t, &c)
}

@(test)
a_snake_hook_is_the_same_on_any_thread_count_and_undoes_bit_for_bit :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	clays := [2]Clay{warp_sphere(96), warp_sphere(96, &pool)}
	defer for &c in clays do clay_destroy(&c)
	before := clay_hash(&clays[0])
	for &c in clays do hook_stroke(&c, 0.25, 8, {0.03, 0.01, 0.05})
	testing.expect(t, clay_hash(&clays[0]) == clay_hash(&clays[1]), "the hook differs between one thread and three")
	testing.expect(t, clay_hash(&clays[0]) != before, "the hook changed nothing")
	testing.expect(t, clay_undo(&clays[0]) && clay_hash(&clays[0]) == before, "undo left the field changed")
}

@(test)
pinch_draws_a_bump_toward_the_middle :: proc(t: ^testing.T) {
	c := warp_sphere(128)
	defer clay_destroy(&c)
	clay_stroke_begin(&c)
	_ = clay_dab(&c, {kind = .Add, radius = 0.1, strength = 1, normal = {0, 0, 1}}, {0.15, 0, 0.989})
	_ = clay_stroke_end(&c)
	peak :: proc(c: ^Clay) -> (best: f32) {
		top: f32 = -1
		for i in 0 ..= 60 {
			x := f32(i) * 0.005
			// The bump's height over the sphere there.
			if h := height_at(c, x) - math.sqrt(1 - x * x); h > top do top, best = h, x
		}
		return
	}
	was := peak(&c)
	clay_stroke_begin(&c)
	for _ in 0 ..< 4 do _ = clay_dab(&c, {kind = .Pinch, radius = 0.4, strength = 1, normal = {0, 0, 1}}, {0, 0, 1})
	_ = clay_stroke_end(&c)
	now := peak(&c)
	testing.expectf(t, now < was - 0.02, "the bump was at %v, after the pinch at %v", was, now)
	closed_check(t, &c)
}

@(test)
crease_cuts_a_groove_and_inverted_raises_a_ridge :: proc(t: ^testing.T) {
	for invert in ([2]bool{false, true}) {
		c := warp_sphere(128)
		defer clay_destroy(&c)
		voxel := c.volume.voxel
		clay_stroke_begin(&c)
		for i in 0 ..< 8 {
			y := -0.2 + f32(i) * 0.05
			_ = clay_dab(&c, {kind = .Crease, radius = 0.15, strength = 1, invert = invert, normal = {0, 0, 1}}, {0, y, math.sqrt(1 - y * y)})
		}
		_ = clay_stroke_end(&c)
		moved := height_at(&c, 0) - 1
		if invert {
			testing.expectf(t, moved > 2 * voxel, "the ridge rose %v", moved)
		} else {
			testing.expectf(t, moved < -2 * voxel, "the groove went %v deep", moved)
		}
		// Two radii to the side the surface stayed.
		side := height_at(&c, 0.3)
		testing.expectf(t, math.abs(side - math.sqrt(f32(1 - 0.09))) < voxel, "beside the crease the surface moved to %v", side)
		closed_check(t, &c)
	}
}
