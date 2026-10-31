package main

import "core:fmt"

import "../ui"
import "../geom"

// Lens's look cards (round 2 of the mockups, screen studio2): Lights, Material and
// Environment as cards of the stack, which a fresh layout leaves out and Studio shows.
// Lights lists each light as a row with its colour, temperature and intensity, the picked
// one holding Intensity and Size, as Marmoset's and Blender's light lists do; Material
// is its own card (lens_materials.odin); Environment is the Environment section. The full sections
// (the light sphere, kinds, cones, MatCaps and packs) are cards of their own, Light settings
// and Material settings, which the cards' More opens.

// A light row's height, and the colour dot's radius, in points.
LIGHT_ROW_H :: 36
LIGHT_DOT :: 6

// The Lights card's content.
kit_lens_lights :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	set := &app.scene.lights
	// Everything changed here, from a press to its release, is one undo step, as in the
	// Lights section.
	before := set^
	what := "Lights"
	defer {
		lights_settle(app)
		if set^ != before do light_drag_changed(app, before, what)
	}
	app.light_pick = clamp(app.light_pick, 0, max(int(set.count) - 1, 0))
	width := ui.fill_width(ctx)
	for &l, i in set.lights[:set.count] {
		picked := i == app.light_pick
		name := fmt.tprintf("lens light %d", i)
		if picked {
			if r := ui.prev_rect(ctx, name); r.w > 0 do ui.fill_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.16))
		}
		ui.begin(ctx, name, {direction = .Column, width = width, height = 0 if picked else LIGHT_ROW_H, padding = 0})
		a := ui.area(ctx, fmt.tprintf("%s##lens light pick %d", light_name(set, i), i), {width, LIGHT_ROW_H})
		mid := a.rect.y + a.rect.h * 0.5
		if a.hovered && !picked do ui.fill_rect(ctx, a.rect, t.radius_small, t.fill_hover)
		rgb := light_rgb(l)
		dot := ui.Color{u8(geom.srgb_encode(min(rgb.r, 1)) * 255 + 0.5), u8(geom.srgb_encode(min(rgb.g, 1)) * 255 + 0.5), u8(geom.srgb_encode(min(rgb.b, 1)) * 255 + 0.5), 255}
		ui.fill_circle(ctx, {a.rect.x + 14, mid}, LIGHT_DOT, dot if l.on else ui.color_fade(dot, 0.35))
		fg := t.text if l.on else t.text_secondary
		ui.text(ctx, light_name(set, i), a.rect.x + 30, mid, t.text_size, fg, .Semibold if picked else .Regular)
		ui.text(ctx, light_line(l), a.rect.x + a.rect.w - 8, mid, t.small_size, t.text_tertiary, .Regular, .Right)
		if a.clicked do app.light_pick = i
		if picked {
			ui.begin(ctx, fmt.tprintf("lens light %d sliders", i), {direction = .Column, width = width, padding = 8, gap = 4})
			_ = ui.slider(ctx, fmt.tprintf("Intensity##lens light %d", i), &l.strength, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", l.strength))
			if l.kind == .Sun {
				_ = ui.slider(ctx, fmt.tprintf("Size##lens light %d", i), &l.angle, 0, LIGHT_ANGLE_MAX, .Linear, fmt.tprintf("%.1f°", l.angle))
			} else {
				widest := clamp(max(l.radius, app.camera.distance * 0.5), 1e-3, LIGHT_RADIUS_MAX)
				_ = ui.slider(ctx, fmt.tprintf("Size##lens light %d", i), &l.radius, 0, widest, .Linear, fmt.tprintf("%.2f", l.radius))
			}
			ui.end(ctx)
		}
		ui.end(ctx)
	}
	if ui.button(ctx, "Add light##lens", .Light, .Accent, width, ui.ICON_PLUS, enabled = set.count < LIGHT_COUNT) {
		_ = light_add(app, .Point)
		what = "Add light"
	}
	// The lights stay with the camera, so the model is lit the same way as it turns, or
	// with the scene, as on a turntable: every light at once, kept where it is on screen.
	follow := !lights_fixed(app)
	if ui.switch_row(ctx, "Lights follow the camera", &follow) do lights_fix(app, !follow)
	if set.count == 0 do ui.paragraph(ctx, "The scene has no lights: its ambient light and the environment light it.")
}

// A light's line on its row: its colour temperature, when it has one, and its intensity.
light_line :: proc(l: Light) -> string {
	if l.kelvin > 0 do return fmt.tprintf("%.0f K · %.1f", l.kelvin, l.strength)
	return fmt.tprintf("%.1f", l.strength)
}

// A preset's colour as its sphere shows it: the colour of a selected object, in sRGB.
material_swatch :: proc(m: Material) -> ui.Color {
	c := m.selected
	return {u8(geom.srgb_encode(clamp(c.r, 0, 1)) * 255 + 0.5), u8(geom.srgb_encode(clamp(c.g, 0, 1)) * 255 + 0.5), u8(geom.srgb_encode(clamp(c.b, 0, 1)) * 255 + 0.5), 255}
}
