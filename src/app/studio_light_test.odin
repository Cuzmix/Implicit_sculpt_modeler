package main

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../render"

// The studio's light samples share themselves among the lights by brightness, every light
// over its own disc, and weigh in the ambient light against the lights' total.
@(test)
studio_shadows_come_from_every_light :: proc(t: ^testing.T) {
	l := render.lights_default()
	l.color[1].w = 0.5 // the fill, a quarter of the brightness
	l.pos[2] = {0, 2, -3, render.LIGHT_POINT}
	l.color[2] = {1, 1, 1, 0.5} // a lamp, another quarter; the key has half
	l.shape[2] = {2, 0, 0, 0.25}
	l.shape[0].w = math.sin(math.to_radians(f32(10)))
	view := linalg.MATRIX4F32_IDENTITY
	softness: f32 = 0.05
	picked: [render.LIGHT_COUNT]int
	SAMPLES :: 3000
	for m in 0 ..< SAMPLES {
		sl := render.studio_light(l, view, {}, softness, m * render.STUDIO_KEY_EVERY + render.STUDIO_KEY_EVERY - 1)
		testing.expect(t, sl.lit)
		j := int(sl.shadow.pick.x)
		picked[j] += 1
		switch j {
		case 0:
			// The key's own size, 20 degrees across.
			testing.expect(t, abs(sl.radius - math.tan(math.to_radians(f32(10)))) < 1e-5)
			testing.expect(t, !sl.sphere)
		case 1:
			testing.expect_value(t, sl.radius, softness)
		case 2:
			testing.expect(t, sl.sphere && sl.sphere_radius == 0.25 && sl.at == [3]f32{0, 2, -3})
		}
		for c in sl.r2 do testing.expect(t, c >= 0 && c < 1)
	}
	testing.expect_value(t, picked[0] + picked[1] + picked[2], SAMPLES)
	share := [3]f32{0.5, 0.25, 0.25}
	for i in 0 ..< 3 do testing.expect(t, abs(f32(picked[i]) / SAMPLES - share[i]) < 0.01)

	// The ambient light against the lights' brightness, 2 in all.
	sl := render.studio_light(l, view, {}, softness, 3)
	testing.expect(t, abs(sl.shadow.pick.z - render.STUDIO_AMBIENT_SHARE * 1 / 2) < 1e-6)
	testing.expect(t, abs(sl.shadow.shape[2].w - 0.25) < 1e-5)

	// No light on, no shadow.
	dark := l
	for &c in dark.color do c.w = 0
	testing.expect(t, !render.studio_light(dark, view, {}, softness, 3).lit)
}
