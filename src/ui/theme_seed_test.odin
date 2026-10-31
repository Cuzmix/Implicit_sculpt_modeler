package ui

import "core:reflect"
import "core:testing"

// The colour fields of a Theme, by name, for comparing two themes field by field.
@(private = "file")
theme_colors :: proc(t: ^Theme) -> (names: [dynamic]string, values: [dynamic]Color) {
	names = make([dynamic]string, context.temp_allocator)
	values = make([dynamic]Color, context.temp_allocator)
	for f in reflect.struct_fields_zipped(Theme) {
		if f.type.id != Color do continue
		append(&names, f.name)
		append(&values, (^Color)(uintptr(t) + f.offset)^)
	}
	return
}

// How far apart two colours are: the largest difference of a channel.
@(private = "file")
color_distance :: proc(a, b: Color) -> int {
	d := 0
	for i in 0 ..< 4 do d = max(d, abs(int(a[i]) - int(b[i])))
	return d
}

@(private = "file", rodata)
EVERY_SEED := [?]Theme_Seed{THEME_SEED_LENS, THEME_SEED_STUDIO, THEME_SEED_GRAPHITE, THEME_SEED_PAPER, THEME_SEED_MIDNIGHT, THEME_SEED_HIGH_CONTRAST}

// Lens's seed is Lens to within a few steps a channel, so moving one of its sliders a
// little moves its greys a little rather than jumping to another palette.
@(test)
the_lens_seed_comes_out_as_lens :: proc(t: ^testing.T) {
	exact := THEME_LENS
	d := theme_derive(THEME_SEED_LENS)
	names, a := theme_colors(&exact)
	_, b := theme_colors(&d)
	for name, i in names {
		testing.expectf(t, color_distance(a[i], b[i]) <= 8, "%s: Lens %v, derived %v", name, a[i], b[i])
	}
}

// An untouched seed gives the exact theme to the bit; an accent alone changes only the
// accent's colours, never a grey, a radius or a size.
@(test)
an_accent_alone_leaves_the_greys_exact :: proc(t: ^testing.T) {
	testing.expect(t, theme_from_seed(THEME_SEED_LENS, THEME_LENS, THEME_SEED_LENS) == THEME_LENS)
	seed := THEME_SEED_STUDIO
	seed.accent = {0xa0, 0x8c, 0xff, 0xff}
	got := theme_from_seed(seed, THEME_STUDIO, THEME_SEED_STUDIO)
	testing.expect_value(t, got.accent, seed.accent)
	testing.expect_value(t, got.chosen, seed.accent)
	testing.expect_value(t, got.accent_soft.a, THEME_STUDIO.accent_soft.a)
	studio := THEME_STUDIO
	names, a := theme_colors(&studio)
	_, b := theme_colors(&got)
	for name, i in names {
		if name == "accent" || name == "accent_soft" || name == "on_accent" || name == "chosen" || name == "on_chosen" || name == "camera" do continue
		testing.expectf(t, a[i] == b[i], "%s changed: %v to %v", name, a[i], b[i])
	}
	testing.expect_value(t, got.radius_medium, THEME_STUDIO.radius_medium)
	testing.expect_value(t, got.target, THEME_STUDIO.target)
}

// Every built-in theme can be read: labels on the panels at 4.5 to 1 or better (WCAG
// AA), hints and the accent at 3, and the ink on the accent at 4.5.
@(test)
every_seed_keeps_its_text_readable :: proc(t: ^testing.T) {
	for seed, i in EVERY_SEED {
		th := theme_derive(seed)
		ground := Color{th.surface.r, th.surface.g, th.surface.b, 255}
		testing.expectf(t, color_contrast(th.text, ground) >= 7, "seed %d text %.2f", i, color_contrast(th.text, ground))
		testing.expectf(t, color_contrast(th.text_secondary, ground) >= 4.5, "seed %d labels %.2f", i, color_contrast(th.text_secondary, ground))
		testing.expectf(t, color_contrast(th.text_tertiary, ground) >= 3, "seed %d hints %.2f", i, color_contrast(th.text_tertiary, ground))
		testing.expectf(t, color_contrast(th.accent, ground) >= 3, "seed %d accent %.2f", i, color_contrast(th.accent, ground))
		testing.expectf(t, color_contrast(th.on_accent, th.accent) >= 4.5, "seed %d on accent %.2f", i, color_contrast(th.on_accent, th.accent))
		testing.expectf(t, color_contrast(th.on_chosen, th.chosen) >= 3, "seed %d chosen tile %.2f", i, color_contrast(th.on_chosen, th.chosen))
	}
}

// A light seed puts dark text on light surfaces and washes with black; a dark one the
// other way round; pure black makes the frame black.
@(test)
light_and_dark_seeds_point_their_greys_the_right_way :: proc(t: ^testing.T) {
	light := theme_derive(THEME_SEED_PAPER)
	testing.expect(t, color_luminance(light.surface) > color_luminance(light.text))
	testing.expect(t, color_luminance(light.surface_raised) >= color_luminance(light.surface))
	testing.expect_value(t, light.fill_hover.r, 0)
	dark := theme_derive(THEME_SEED_LENS)
	testing.expect(t, color_luminance(dark.surface) < color_luminance(dark.text))
	testing.expect_value(t, dark.fill_hover.r, 255)
	testing.expect_value(t, theme_derive(THEME_SEED_MIDNIGHT).frame, Color{0, 0, 0, 255})
}

// More contrast spreads the surfaces and text further apart, and corners and opacity do
// what they say.
@(test)
the_sliders_move_what_they_name :: proc(t: ^testing.T) {
	lo, hi := THEME_SEED_LENS, THEME_SEED_LENS
	lo.contrast, hi.contrast = 0, 1
	a, b := theme_derive(lo), theme_derive(hi)
	testing.expect(t, color_contrast(b.text_tertiary, b.surface) > color_contrast(a.text_tertiary, a.surface))
	testing.expect(t, color_luminance(b.fill) > color_luminance(a.fill))
	round := THEME_SEED_LENS
	round.corners, round.opacity = .Square, 0.7
	r := theme_derive(round)
	testing.expect(t, r.radius_large < THEME_LENS.radius_large)
	testing.expect_value(t, r.surface.a, u8(179))
	round.opacity = 0.1
	testing.expect_value(t, theme_derive(round).surface.a, u8(153))
}

@(test)
hsl_and_contrast_match_known_values :: proc(t: ^testing.T) {
	testing.expect_value(t, color_hsl(0, 100, 50), Color{255, 0, 0, 255})
	testing.expect_value(t, color_hsl(120, 100, 25), Color{0, 128, 0, 255})
	testing.expect_value(t, color_hsl(-120, 100, 50), Color{0, 0, 255, 255})
	c := color_contrast({0, 0, 0, 255}, {255, 255, 255, 255})
	testing.expect(t, c > 20.99 && c < 21.01)
}
