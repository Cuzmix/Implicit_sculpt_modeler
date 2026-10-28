package main

import "core:math"
import "core:testing"

import "../render"

// Neutral's inverse gives back the light behind every colour Neutral shows, up to about
// thirteen times white, where an 8-bit picture stops telling light apart; and every 8-bit
// colour, those Neutral never shows too (a MatCap's or a wire's, encoded without it),
// comes back as light a number can hold. What an 8-bit step loses, finish.frag.slang carries
// over as what Neutral gives back short of the colour shown.
@(test)
finish_neutral_inverse_round_trips :: proc(t: ^testing.T) {
	decode :: proc(code: f32) -> f32 {
		c := code / 255
		return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
	}
	// Light from far below mid grey to past white, every mix of the three channels.
	STEPS :: 48
	worst: f32
	for r in 0 ..< STEPS do for g in 0 ..< STEPS do for b in 0 ..< STEPS {
		light := [3]f32{math.pow(2, f32(r) / 4 - 12), math.pow(2, f32(g) / 4 - 12), math.pow(2, f32(b) / 4 - 12)}
		shown := render.tone_neutral(light)
		back := render.tone_neutral(render.tone_neutral_inverse(shown))
		for k in 0 ..< 3 do worst = max(worst, abs(back[k] - shown[k]))
	}
	testing.expectf(t, worst < 1e-4, "a colour came back %f away", worst)
	for r in 0 ..< 256 do for g in 0 ..< 256 do for b in 0 ..< 256 {
		x := render.tone_neutral_inverse({decode(f32(r)), decode(f32(g)), decode(f32(b))})
		for k in 0 ..< 3 {
			if !(x[k] >= 0 && x[k] < 64) {
				testing.expectf(t, false, "code %d %d %d came back as %v", r, g, b, x)
				return
			}
		}
	}
}

// Neutral's inverse keeps its order: more light shown is more light back, and dark codes
// come back as the darkest light, so a contrast change cannot reorder them.
@(test)
finish_neutral_inverse_is_monotonic :: proc(t: ^testing.T) {
	last: f32 = -1
	for i in 0 ..= 254 {
		y := f32(i) / 255
		x := render.tone_neutral_inverse({y, y, y}).r
		testing.expectf(t, x > last || i == 0, "code %d came back as %f, not above %f", i, x, last)
		last = x
	}
	testing.expect(t, render.tone_neutral_inverse({0, 0, 0}) == {0, 0, 0})
}

// The AgX sigmoid meets black, mid grey and white exactly, with the slope it is made for at
// mid grey, and its scales are the ones its ends ask for.
@(test)
finish_agx_sigmoid_meets_its_ends :: proc(t: ^testing.T) {
	testing.expect(t, abs(render.agx_sigmoid(0)) < 1e-9)
	testing.expect(t, abs(render.agx_sigmoid(1) - 1) < 1e-9)
	testing.expect(t, abs(render.agx_sigmoid(render.AGX_PIVOT_X) - 0.5) < 1e-12)
	h := 1e-6
	slope := (render.agx_sigmoid(render.AGX_PIVOT_X + h) - render.agx_sigmoid(render.AGX_PIVOT_X - h)) / (2 * h)
	testing.expect(t, abs(slope - render.AGX_SLOPE) < 1e-4)
	testing.expect(t, abs(render.agx_scale(render.AGX_PIVOT_X, 0.5, render.AGX_TOE_POWER) - render.AGX_TOE_SCALE) < 1e-12)
	testing.expect(t, abs(render.agx_scale(1 - render.AGX_PIVOT_X, 0.5, render.AGX_SHOULDER_POWER) - render.AGX_SHOULDER_SCALE) < 1e-12)
	// Mid grey's place: 0.18 in the 16.5 stops from -12.47 to +4.03.
	testing.expect(t, abs((math.log2(f64(0.18)) + 12.47393) / (12.47393 + 4.026069) - render.AGX_PIVOT_X) < 1e-12)
	// Mid grey shows the same under every curve.
	neutral := f64(render.tone_neutral({0.18, 0.18, 0.18}).r)
	testing.expect(t, abs(render.agx_grey(0.18 * render.AGX_EXPOSURE) - neutral) < 1e-6)
	testing.expect(t, abs(render.aces_grey(0.18 * render.ACES_EXPOSURE) - neutral) < 1e-6)
	last := -1.0
	for i in 0 ..= 100 {
		y := render.agx_sigmoid(f64(i) / 100)
		testing.expect(t, y > last)
		last = y
	}
}

// The defaults finish nothing, so the picture stays the viewport's; daylight is no white
// balance at all, and a higher temperature warms the picture.
@(test)
finish_defaults_change_nothing :: proc(t: ^testing.T) {
	testing.expect(t, !render.finish_active(finish_look(FINISH_DEFAULTS)))
	testing.expect(t, finish_look(FINISH_DEFAULTS).white == {1, 1, 1})
	m := render.white_balance({1, 1, 1})
	for r in 0 ..< 3 do for c in 0 ..< 3 do testing.expect(t, abs(m[r, c] - (1 if r == c else 0)) < 1e-5)

	warm := FINISH_DEFAULTS
	warm.kelvin = 9000
	testing.expect(t, render.finish_active(finish_look(warm)))
	w := render.white_balance(finish_look(warm).white)
	grey := w * [3]f32{0.5, 0.5, 0.5}
	testing.expectf(t, grey.r > grey.b, "9000 K should warm grey, gave %v", grey)
	// The white taken as white comes out white.
	white := finish_look(warm).white
	out := w * white
	for k in 0 ..< 3 do testing.expect(t, abs(out[k] - 1) < 1e-4)

	// The softness and the grain's size alone change nothing.
	soft := FINISH_DEFAULTS
	soft.vignette_soft, soft.grain_size = 0.2, 3
	testing.expect(t, !render.finish_active(finish_look(soft)))
}

// The finish shows only while the Render switch is on and a control is away from none;
// Reset finish puts every control back.
@(test)
finish_runs_with_the_render_switch :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.finish = FINISH_DEFAULTS
	app.finish.curve = .AgX
	testing.expect(t, !finish_wanted(app))
	app.studio_on = true
	testing.expect(t, finish_wanted(app))
	finish_reset_command(app)
	testing.expect(t, app.finish == FINISH_DEFAULTS)
	testing.expect(t, !finish_wanted(app))
	testing.expect_value(t, finish_fingerprint(app), u64(0))
}
