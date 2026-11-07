package voxel

import "core:math"
import "core:testing"

import "../geom"

@(private = "file")
more_sphere :: proc(across: f32) -> (c: Clay) {
	clay_init(&c, 2 / across, {}, nil)
	clay_fill_sphere(&c, {}, 1)
	return
}

@(private = "file")
height :: proc(c: ^Clay, x: f32 = 0, y: f32 = 0) -> f32 {
	hit, _, ok := clay_raycast(c, {x, y, 5}, {0, 0, -1})
	return hit.z if ok else -1
}

@(private = "file")
closed :: proc(t: ^testing.T, c: ^Clay) {
	m := clay_to_mesh(c)
	defer geom.mesh_destroy(&m)
	check := geom.mesh_check(m)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted && check.degenerate_triangles == 0, "%v", check)
}

@(test)
layer_rises_one_height_a_stroke_however_often_it_passes :: proc(t: ^testing.T) {
	tops: [2]f32
	voxel: f32
	for dabs, i in ([2]int{3, 12}) {
		c := more_sphere(256)
		defer clay_destroy(&c)
		voxel = c.volume.voxel
		clay_stroke_begin(&c)
		for _ in 0 ..< dabs do _ = clay_dab(&c, {kind = .Layer, radius = 0.3, strength = 1, normal = {0, 0, 1}}, {0, 0, 1})
		_ = clay_stroke_end(&c)
		tops[i] = height(&c)
		if i == 1 do closed(t, &c)
	}
	layer := f32(0.3 * LAYER_HEIGHT)
	testing.expectf(t, math.abs(tops[0] - (1 + layer)) < voxel, "three dabs rose to %v, the layer is %v high", tops[0], layer)
	testing.expectf(t, math.abs(tops[1] - tops[0]) < 0.5 * voxel, "twelve dabs rose to %v, three to %v", tops[1], tops[0])
}

@(test)
clay_strips_level_off_at_their_plane_with_square_ends :: proc(t: ^testing.T) {
	c := more_sphere(256)
	defer clay_destroy(&c)
	voxel := c.volume.voxel
	r: f32 = 0.2
	clay_stroke_begin(&c)
	for _ in 0 ..< 20 do _ = clay_dab(&c, {kind = .Clay_Strips, radius = r, strength = 1, normal = {0, 0, 1}, along = {1, 0, 0}}, {0, 0, 1})
	_ = clay_stroke_end(&c)
	plane := 1 + r * CLAY_STRIPS_HEIGHT
	testing.expectf(t, math.abs(height(&c) - plane) < voxel, "the strip's top is at %v, its plane at %v", height(&c), plane)
	// Toward the square's corner, past where a round brush reaches, it built up too.
	corner := r * 0.75
	sphere := math.sqrt(1 - 2 * corner * corner)
	testing.expectf(t, height(&c, corner, corner) > sphere + voxel, "at the corner the top is at %v, the sphere's %v", height(&c, corner, corner), sphere)
	closed(t, &c)
}

@(test)
trim_cuts_the_top_off_a_ridge_and_inverted_leaves_a_valley_alone :: proc(t: ^testing.T) {
	for invert in ([2]bool{false, true}) {
		c := more_sphere(256)
		defer clay_destroy(&c)
		voxel := c.volume.voxel
		clay_stroke_begin(&c)
		for i in 0 ..< 10 {
			x := -0.1 + f32(i) * 0.02
			_ = clay_dab(&c, {kind = .Trim, radius = 0.5, strength = 1, invert = invert, normal = {0, 0, 1}, along = {1, 0, 0}}, {x, 0, math.sqrt(1 - x * x)})
		}
		_ = clay_stroke_end(&c)
		top := height(&c)
		if invert {
			// The planes turn the other way, into the clay's sides: the top stays.
			testing.expectf(t, top < 1 - voxel, "inverted the top is at %v", top)
		} else {
			testing.expectf(t, top < 1 - 2 * voxel, "the top is at %v, it was 1", top)
		}
		side := height(&c, 0, 0.8)
		testing.expectf(t, math.abs(side - 0.6) < voxel, "out past the brush the surface moved to %v", side)
		closed(t, &c)
	}
}

@(test)
polish_smooths_and_keeps_more_volume_than_smooth :: proc(t: ^testing.T) {
	lost: [2]f64
	for polish, i in ([2]bool{false, true}) {
		c := more_sphere(128)
		defer clay_destroy(&c)
		before := clay_to_mesh(&c)
		defer geom.mesh_destroy(&before)
		clay_stroke_begin(&c)
		for _ in 0 ..< 10 do _ = clay_dab(&c, {kind = .Smooth, radius = 0.5, strength = 1, normal = {0, 0, 1}, polish = polish}, {0, 0, 1})
		_ = clay_stroke_end(&c)
		after := clay_to_mesh(&c)
		defer geom.mesh_destroy(&after)
		lost[i] = geom.mesh_signed_volume(before) - geom.mesh_signed_volume(after)
		closed(t, &c)
	}
	testing.expectf(t, lost[0] > 0 && math.abs(lost[1]) < lost[0] * 0.5, "Smooth lost %v of the volume, Polish %v", lost[0], lost[1])
}
