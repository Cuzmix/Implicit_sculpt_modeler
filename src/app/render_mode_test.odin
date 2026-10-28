package main

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"

import "../geom"
import "../render"

// Render mode takes the viewport's lights into the world, with sizes whose light arrives
// as strongly as the viewport's (three times the strength), and pick chances that add up.
@(test)
render_lights_reach_the_world :: proc(t: ^testing.T) {
	l := render.lights_default()
	l.pos[2] = {0, 0, -5, render.LIGHT_POINT}
	l.color[2] = {1, 0.5, 0.25, 2}
	l.shape[2].x = 2
	softness: f32 = 0.1
	// The view turns a quarter about y, so the world's x is the view's z.
	view := linalg.matrix4_rotate_f32(math.PI / 2, {0, 1, 0})
	w := render.lights_to_world(l, view, {}, softness)
	to_world := linalg.inverse(view)
	key := to_world * [4]f32{l.pos[0].x, l.pos[0].y, l.pos[0].z, 0}
	for c in 0 ..< 3 do testing.expect(t, abs(w.pos[0][c] - key[c]) < 1e-5)
	testing.expect(t, abs(linalg.length(w.pos[0].xyz) - 1) < 1e-5)

	// A sun: a cone of half-angle `softness` whose radiance gives 3 x strength.
	sun := w.size[0].y * math.PI * math.pow(math.sin(softness), 2)
	testing.expect(t, abs(sun - 3) < 1e-4)
	testing.expect(t, abs(w.size[0].x - math.cos(softness)) < 1e-6)
	// A point light: a sphere as wide as that angle from the scene's middle, giving
	// 3 x strength at its reference distance.
	at := to_world * [4]f32{0, 0, -5, 1}
	for c in 0 ..< 3 do testing.expect(t, abs(w.pos[2][c] - at[c]) < 1e-4)
	radius := w.size[2].x
	testing.expect(t, abs(radius - 5 * math.tan(softness)) < 1e-4)
	point := w.size[2].y * math.PI * radius * radius / (2 * 2)
	testing.expect(t, abs(point - 3 * 2) < 1e-3)

	// A light's own size wins over the softness: a sun of 10 degrees across, a lamp of
	// radius 0.5.
	l.shape[0].w = math.sin(math.to_radians(f32(5)))
	l.shape[2].w = 0.5
	sized := render.lights_to_world(l, view, {}, softness)
	testing.expect(t, abs(sized.size[0].x - math.cos(math.to_radians(f32(5)))) < 1e-5)
	testing.expect_value(t, sized.size[2].x, f32(0.5))
	testing.expect(t, abs(sized.size[0].y * math.PI * math.pow(l.shape[0].w, 2) - 3) < 1e-3)

	// Chances by strength times the brightest channel, adding up to one; the last light
	// picked takes whatever rounding leaves.
	total: f32
	for i in 0 ..< render.LIGHT_COUNT do total += w.size[i].w
	testing.expect(t, abs(total - 1) < 1e-5)
	testing.expect(t, abs(w.size[2].w / w.size[0].w - 2) < 1e-4)
	testing.expect_value(t, w.size[2].z, f32(2))
	testing.expect_value(t, w.size[3].w, f32(0))
}

// The classic shading's highlight power becomes the GGX roughness of about the same
// width; a physically based material keeps its own.
@(test)
render_roughness_follows_the_highlight :: proc(t: ^testing.T) {
	testing.expect(t, abs(render.path_roughness({0.1, 0.2, 14, 0}, {}) - math.pow(f32(2) / 16, 0.25)) < 1e-6)
	testing.expect(t, render.path_roughness({0.1, 0.2, 200, 0}, {}) < render.path_roughness({0.1, 0.2, 10, 0}, {}))
	testing.expect_value(t, render.path_roughness({0.1, 0.2, 14, 0}, {1, 0.3}), f32(0.3))
}

// A box through a similarity holds the turned, scaled and moved box.
@(test)
render_boxes_reach_the_world :: proc(t: ^testing.T) {
	model := linalg.matrix4_translate_f32({1, 0, 0}) * linalg.matrix4_rotate_f32(math.PI / 4, {0, 0, 1}) * linalg.matrix4_scale_f32(2)
	b := render.aabb_transform(geom.Aabb{{-1, -1, -1}, {1, 1, 1}}, model)
	r := f32(2 * math.SQRT_TWO)
	want := geom.Aabb{{1 - r, -r, -2}, {1 + r, r, 2}}
	for c in 0 ..< 3 {
		testing.expect(t, abs(b.lo[c] - want.lo[c]) < 1e-4)
		testing.expect(t, abs(b.hi[c] - want.hi[c]) < 1e-4)
	}
}

// Render mode is a command, off at the start of every run; its samples, bounces, denoise,
// half resolution, depth of field and blur are remembered, and the point in focus is not.
@(test)
render_mode_is_not_remembered :: proc(t: ^testing.T) {
	path := "build/render_mode_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	command_run(&a, .Render_Mode)
	testing.expect(t, a.render_on && command_checked(&a, .Render_Mode, 0))
	a.render_samples, a.render_bounces, a.render_denoise, a.render_half = 300, 3, false, true
	a.render_dof, a.render_blur, a.focus = true, 0.75, Vec3{1, 2, 3}
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	testing.expect(t, !b.render_on)
	testing.expect_value(t, b.render_samples, i32(300))
	testing.expect_value(t, b.render_bounces, i32(3))
	testing.expect(t, !b.render_denoise)
	testing.expect(t, b.render_half)
	testing.expect(t, b.render_dof)
	testing.expect_value(t, b.render_blur, f32(0.75))
	_, picked := b.focus.?
	testing.expect(t, !picked)
}

// Depth of field focuses on the pivot until a point is picked, which Focus on the pivot
// lets go of; off, the lens is none, so moving the pivot starts nothing over.
@(test)
render_lens_focuses_on_the_pivot_or_the_picked_point :: proc(t: ^testing.T) {
	a: App
	defer results_destroy(&a)
	a.camera.target = {0, 1, 0}
	a.render_blur = 0.5
	testing.expect_value(t, render_lens(&a), render.Lens{})
	a.render_dof = true
	testing.expect_value(t, render_lens(&a), render.Lens{on = true, blur = 0.5, focus = {0, 1, 0}})
	testing.expect(t, !command_enabled(&a, .Focus_Pivot))
	a.focus = Vec3{2, 0, 0}
	testing.expect_value(t, render_lens(&a).focus, [3]f32{2, 0, 0})
	testing.expect(t, command_run(&a, .Focus_Pivot))
	testing.expect_value(t, render_lens(&a).focus, [3]f32{0, 1, 0})
	// Pick focus waits for a press, and run again waits no more.
	testing.expect(t, command_run(&a, .Pick_Focus) && a.ui.focus_armed)
	testing.expect(t, command_run(&a, .Pick_Focus) && !a.ui.focus_armed)
}

// Half resolution traces half the viewport each way, rounded up so every pixel is covered.
@(test)
render_half_size_covers_the_viewport :: proc(t: ^testing.T) {
	w, h := render.render_size(1600, 900, false)
	testing.expect(t, w == 1600 && h == 900)
	w, h = render.render_size(1601, 899, true)
	testing.expect(t, w == 801 && h == 450)
	w, h = render.render_size(1, 1, true)
	testing.expect(t, w == 1 && h == 1)
}

// The denoiser reaches far while the image is noisy and less as the samples build up.
@(test)
render_denoise_eases_with_samples :: proc(t: ^testing.T) {
	passes := [?][2]int{{1, 5}, {64, 5}, {255, 5}, {256, 4}, {1024, 3}, {4096, 2}, {100_000, 2}}
	for c in passes {
		n, _ := render.render_denoise_passes(c[0])
		testing.expect_value(t, n, c[1])
	}
	_, early := render.render_denoise_passes(4)
	_, late := render.render_denoise_passes(4096)
	testing.expect_value(t, early, f32(2))
	testing.expect_value(t, late, f32(0.15))
}

// The environment's table picks each texel as often as its luminance times its share of
// the sphere asks, and a constant panorama's density is even over the sphere, 1 / 4π.
@(test)
render_environment_table_samples_by_brightness :: proc(t: ^testing.T) {
	W, H :: 16, 8
	lum := make([]f32, W * H, context.temp_allocator)
	for &v in lum do v = 1
	flat := render.env_table_build(lum, W, H, context.temp_allocator)
	for e, i in flat.texels {
		s := math.sin((f32(i / W) + 0.5) / H * math.PI)
		testing.expect(t, abs(e.z / s - 1 / (4 * math.PI)) < 1e-3)
	}
	testing.expect(t, abs(flat.mean - 1) < 1e-5)

	// A bright spot: what each texel is picked with, from the alias table, matches its
	// chance.
	lum[3 * W + 5] = 500
	lum[6 * W + 1] = 20
	tab := render.env_table_build(lum, W, H, context.temp_allocator)
	got := make([]f32, W * H, context.temp_allocator)
	for e, i in tab.texels {
		got[i] += e.x / (W * H)
		got[int(e.y)] += (1 - e.x) / (W * H)
	}
	total: f32
	for e, i in tab.texels {
		chance := e.z * 2 * math.PI * math.PI / (W * H)
		testing.expect(t, abs(got[i] - chance) < 1e-5)
		total += chance
	}
	testing.expect(t, abs(total - 1) < 1e-4)
	// The spot lends its brightness to the texels round it, which a filtered lookup
	// reaches into, so the nine together take nearly every pick.
	around: f32
	for y in 2 ..= 4 do for x in 4 ..= 6 do around += got[y * W + x]
	testing.expect(t, around > 0.9)
	testing.expect(t, got[2 * W + 4] > 0.08)
}

// Light samples go to the environment by the light it gives against the lights', never
// below a tenth for either, and the lights' chances make room; the built-in studio's
// only while no light is on.
@(test)
render_environment_shares_light_samples :: proc(t: ^testing.T) {
	l := render.lights_default()
	world := render.lights_to_world(l, linalg.MATRIX4F32_IDENTITY, {}, 0.1)
	key := world.size[0].w
	share := render.env_share(&world, l, 3 * (1 + render.FILL_STRENGTH))
	testing.expect(t, abs(share - 0.5) < 1e-5)
	testing.expect(t, abs(world.size[0].w - key * 0.5) < 1e-6)
	testing.expect(t, abs(world.size[0].z - (0.5 + 0.5 * key)) < 1e-6)
	testing.expect_value(t, world.size[1].z, f32(2))

	dim := render.lights_to_world(l, linalg.MATRIX4F32_IDENTITY, {}, 0.1)
	testing.expect_value(t, render.env_share(&dim, l, 1e-6), f32(0.1))
	none := render.lights_to_world(l, linalg.MATRIX4F32_IDENTITY, {}, 0.1)
	testing.expect_value(t, render.env_share(&none, l, 0), f32(0))
	testing.expect_value(t, none.size[0].w, key)

	// The built-in studio takes light samples only while every light is off.
	studio := render.lights_to_world(l, linalg.MATRIX4F32_IDENTITY, {}, 0.1)
	testing.expect_value(t, render.env_share(&studio, l, 100, smooth = true), f32(0))
	testing.expect_value(t, studio.size[0].w, key)
	dark := l
	for &c in dark.color do c.w = 0
	unlit := render.lights_to_world(dark, linalg.MATRIX4F32_IDENTITY, {}, 0.1)
	testing.expect_value(t, render.env_share(&unlit, dark, 1, smooth = true), f32(1))
}

// Scene > Render's one switch runs the chosen quality and never both: Full takes over from
// Fast and back, the switch turns either off, and the Sculpt studio look's Fast
// leaves a Full render running.
@(test)
render_switch_runs_one_quality :: proc(t: ^testing.T) {
	a: App
	defer results_destroy(&a)
	testing.expect(t, command_run(&a, .Studio_Render))
	testing.expect(t, a.studio_on && !a.render_on && a.render_quality == .Fast)
	testing.expect(t, command_run(&a, .Render_Mode))
	testing.expect(t, !a.studio_on && a.render_on && a.render_quality == .Full)
	testing.expect(t, command_checked(&a, .Studio_Render) && command_checked(&a, .Render_Mode))
	testing.expect(t, command_run(&a, .Studio_Render))
	testing.expect(t, !render_switch_on(&a) && a.render_quality == .Full)
	// On again, the switch keeps the quality it had.
	testing.expect(t, command_run(&a, .Studio_Render))
	testing.expect(t, a.render_on && !a.studio_on)
	look_apply(&a, .Sculpt_Studio, false)
	testing.expect(t, a.render_on && !a.studio_on)
	testing.expect_value(t, look_current(&a), Maybe(Look_Preset)(.Sculpt_Studio))
	render_set(&a, true, .Fast)
	testing.expect(t, a.studio_on && !a.render_on)
	look_apply(&a, .Classic, false)
	testing.expect(t, !render_switch_on(&a))
}
