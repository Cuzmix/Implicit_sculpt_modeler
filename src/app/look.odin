package main

import "core:fmt"

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
// scene's and the starting ones; the main view's look becomes Clay; and the background,
// cavity, style, live occlusion and the render's strengths take its values. The Render switch is left as it is: Rendered is a
// shading mode of its own. Not an undo step, as a material pick is not.
look_studio_apply :: proc(app: ^App) {
	if i, ok := material_by_name(LOOK_MATERIAL_STUDIO); ok do app.material = i
	lights := look_lights_studio()
	app.start_lights = lights
	app.scene.lights = lights
	app.background = LOOK_BACKGROUND_STUDIO
	app.cavity, app.ridge = CAVITY_DEFAULT, RIDGE_DEFAULT
	app.styled, app.rim, app.underside = true, RIM_DEFAULT, UNDERSIDE_DEFAULT
	app.live_ao_on = true
	app.studio_ao = 1
	app.studio_shadow = LOOK_STUDIO_SHADOW
	app.studio_softness = LOOK_STUDIO_SOFTNESS
	// The main view opens in Clay on its default MatCap (Grey clay), as ZBrush opens on a
	// sculpting MatCap: the first stroke reads every form whatever side faces the camera.
	// The scene's lights above are kept for Lit, Full and Rendered. It is sculpting's look,
	// so painting and lighting keep theirs (Each tool keeps its look).
	look_of(&app.kit, .Sculpt).mode = .Clay
	render.studio_reset(&app.studio)
	app.look_chosen = true
}

// Starts a fresh install, or a settings file from before there was a studio look, in it,
// once: the settings then keep `look_chosen` and whatever was changed since.
look_first_run :: proc(app: ^App) {
	if !app.look_chosen do look_studio_apply(app)
}

// The Light card's Viewport style: how the viewport draws forms whatever the material.
// Cavity and Ridge are kit_style_detail, which the Material card's More options draws too,
// as a material is judged by them. Occlusion while working darkens creases every frame;
// Cavity darkens creases and Ridge lightens crests, so fine detail reads at any light angle;
// Styled shading adds the studio look's rim and its dark underside. Under More the rest:
// how far the occlusion looks, the style's strengths, the exposure, and dimming the objects
// not selected. The lights' own strengths are in Lights, the render's shadows in Render.
kit_viewport_style :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_live_ao(app)
	kit_style_detail(app)
	_ = ui.switch_row(ctx, "Styled shading", &app.styled)
	if kit_more(app, .Style) {
		kit_live_ao_reach(app)
		if app.styled {
			_ = ui.slider(ctx, "Rim", &app.rim, 0, RIM_MAX, .Linear, fmt.tprintf("%.2f", app.rim))
			_ = ui.slider(ctx, "Underside", &app.underside, 0, 1, .Linear, fmt.tprintf("%.2f", app.underside))
		}
		_ = ui.slider(ctx, "Exposure", &app.exposure, -EXPOSURE_RANGE, EXPOSURE_RANGE, .Linear, fmt.tprintf("%+.1f stops", app.exposure))
		_ = ui.switch_row(ctx, "Dim the others", &app.dim_others)
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Occlusion while working darkens creases every frame, sculpting too. Cavity and Ridge make fine detail read under any light; Styled shading adds a rim and a dark underside.")
}

// Cavity, which darkens creases, and Ridge, which lightens crests, so fine detail reads at
// any light angle on every material and MatCap. Viewport style and the Material card's
// More options both draw this one proc, so the two are the same sliders on the same values.
kit_style_detail :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.slider(ctx, "Cavity", &app.cavity, 0, 1, .Linear, fmt.tprintf("%.2f", app.cavity))
	_ = ui.slider(ctx, "Ridge", &app.ridge, 0, 1, .Linear, fmt.tprintf("%.2f", app.ridge))
}
