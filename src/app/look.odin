package main

import "core:fmt"
import "core:math"

import "../render"
import "../ui"

// Scene > Look: how bright the key and ambient lights are, how dark and soft the shadows,
// and under More the rest of the look's parts, each still its own control. The viewport's
// shading modes (shading.odin) are Blender's; there are no look presets over them. A fresh
// install, and a settings file from before the presets went, start once in the studio look
// (look_first_run), which matches renders of grey studio sculpts: a soft grey clay, a key
// light from the upper left, deep shade under the forms, a light rim and a flat dark
// backdrop. Scripted runs and --no-settings keep the code's defaults, so tests and benches
// are unchanged.

// The material the studio look gives new objects, by name.
LOOK_MATERIAL_STUDIO :: "Studio grey"

// The studio look's flat backdrop, a little darker than the gradient's middle.
LOOK_BACKGROUND_STUDIO :: Background_Settings{gradient = false, top = {0.165, 0.165, 0.17}, bottom = {0.09, 0.09, 0.1}}

// The studio look's shadow strength and its key light's radius in radians (about 8.6°):
// soft-edged shadows that still read as cast.
LOOK_STUDIO_SHADOW :: 0.6
LOOK_STUDIO_SOFTNESS :: 0.15
// The render's strengths in the code's defaults, which scripted runs keep.
STUDIO_AO_DEFAULT :: 0.85
STUDIO_SHADOW_DEFAULT :: 0.6

// The studio look's lights: the key higher and further left than the classic one, the fill
// all but off so the shaded side stays dark, and the rim light behind on.
look_lights_studio :: proc() -> Light_Set {
	set := LIGHTS_DEFAULT
	set.lights[0].dir = {-0.6, 0.65, 0.45}
	set.lights[1].strength = 0.06
	set.lights[2].on = true
	set.lights[2].strength = 0.5
	return set
}

// Puts the studio look on: its material becomes the one new objects take; its lights the
// scene's and the starting ones; and the background, cavity, style, live occlusion and the
// render's strengths take its values. The Render switch is left as it is: Rendered is a
// shading mode of its own. Not an undo step, as a material pick is not.
look_studio_apply :: proc(app: ^App) {
	if i, ok := material_by_name(LOOK_MATERIAL_STUDIO); ok do app.material = i
	lights := look_lights_studio()
	app.start_lights = lights
	app.scene.lights = lights
	app.background = LOOK_BACKGROUND_STUDIO
	app.cavity, app.ridge = 0.7, RIDGE_DEFAULT
	app.styled, app.rim, app.underside = true, RIM_DEFAULT, UNDERSIDE_DEFAULT
	app.live_ao_on = true
	app.studio_ao = 1
	app.studio_shadow = LOOK_STUDIO_SHADOW
	app.studio_softness = LOOK_STUDIO_SOFTNESS
	render.studio_reset(&app.studio)
	app.look_chosen = true
}

// Starts a fresh install, or a settings file from before there was a studio look, in it,
// once: the settings then keep `look_chosen` and whatever was changed since.
look_first_run :: proc(app: ^App) {
	if !app.look_chosen do look_studio_apply(app)
}

// Scene > Look: how bright the key light and the ambient light are and how dark and soft
// the shadows; under More the rest of the look's parts.
kit_look :: proc(app: ^App) {
	ctx := &app.kit.ctx
	set := &app.scene.lights
	if set.count > 0 {
		key := &set.lights[0]
		_ = ui.slider(ctx, "Key light", &key.strength, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", key.strength))
	}
	_ = ui.slider(ctx, "Ambient", &set.ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", set.ambient))
	_ = ui.slider(ctx, "Shadow", &app.studio_shadow, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_shadow))
	_ = ui.slider(ctx, "Shadow softness", &app.studio_softness, render.STUDIO_SOFTNESS_MIN, render.STUDIO_SOFTNESS_MAX, .Logarithmic, fmt.tprintf("%.1f°", math.to_degrees(app.studio_softness)))
	kit_live_ao(app)
	if kit_more(app, .Look) {
		_ = ui.slider(ctx, "Occlusion", &app.studio_ao, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_ao))
		_ = ui.switch_row(ctx, "Styled shading", &app.styled)
		if app.styled {
			_ = ui.slider(ctx, "Rim", &app.rim, 0, RIM_MAX, .Linear, fmt.tprintf("%.2f", app.rim))
			_ = ui.slider(ctx, "Underside", &app.underside, 0, 1, .Linear, fmt.tprintf("%.2f", app.underside))
		}
		grey := app.background.top.r
		if ui.slider(ctx, "Background", &grey, 0, 1, .Linear, fmt.tprintf("%.2f", grey)) do app.background.top = {grey, grey, min(grey * 1.03, 1)}
		kit_live_ao_reach(app)
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Each slider is the control of the same name in Lights, Render's Fast quality or Background; Underside is how much light reaches surfaces facing down. The view's shading mode (Solid, Material Preview, Rendered) is on the Shading chip over the view.")
	ui.paragraph(ctx, "Occlusion while working darkens creases every frame, sculpting too, with the same Occlusion strength; Reach is how far it looks, as a share of the scene's size. With Render at Fast quality it shows until Fast has built up its first samples.")
}
