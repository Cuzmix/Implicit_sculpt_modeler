package main

import "core:fmt"
import "core:math"

import "../render"
import "../ui"

// Scene > Look: presets over the shading's parts, the material new objects take, the
// lights, the background, the style, live occlusion and the studio render, each still its
// own control. Sculpt studio matches renders of grey studio sculpts: a soft grey clay, a
// key light from the upper left whose soft shadows fall from the jaw onto the neck, deep
// shade under the forms, a light rim and a flat dark backdrop. Classic is the look the
// app always had. A fresh install, and a settings file from before there were presets,
// start in Sculpt studio (look_first_run); scripted runs and --no-settings keep Classic,
// the code's defaults, so tests and benches are unchanged.

Look_Preset :: enum u8 {
	Sculpt_Studio,
	Classic,
}

LOOK_PRESET_NAMES := [Look_Preset]string {
	.Sculpt_Studio = "Sculpt studio",
	.Classic       = "Classic",
}

// The material each preset gives the selected objects and new ones, by name.
LOOK_MATERIALS := [Look_Preset]string {
	.Sculpt_Studio = "Studio grey",
	.Classic       = "Clay",
}

// Sculpt studio's flat backdrop, a little darker than the gradient's middle.
LOOK_BACKGROUND_STUDIO :: Background_Settings{gradient = false, top = {0.165, 0.165, 0.17}, bottom = {0.09, 0.09, 0.1}}

// Sculpt studio's shadow strength and its key light's radius in radians (about 8.6°):
// soft-edged shadows that still read as cast.
LOOK_STUDIO_SHADOW :: 0.6
LOOK_STUDIO_SOFTNESS :: 0.15
// The studio render's strengths before there were presets, which Classic keeps.
STUDIO_AO_DEFAULT :: 0.85
STUDIO_SHADOW_DEFAULT :: 0.6

// Sculpt studio's lights: the key higher and further left than the classic one, the fill
// all but off so the shaded side stays dark, and the rim light behind on.
look_lights_studio :: proc() -> Light_Set {
	set := LIGHTS_DEFAULT
	set.lights[0].dir = {-0.6, 0.65, 0.45}
	set.lights[1].strength = 0.06
	set.lights[2].on = true
	set.lights[2].strength = 0.5
	return set
}

// Puts `preset` on: its material becomes the one new objects take, and with `selected`
// also the selected objects' (as a pick in the Material section); its lights become the
// scene's and the starting ones; and the background, cavity, style, live occlusion and
// studio render take its values. Not an undo step, as a material pick is not.
look_apply :: proc(app: ^App, preset: Look_Preset, selected: bool) {
	studio := preset == .Sculpt_Studio
	if i, ok := material_by_name(LOOK_MATERIALS[preset]); ok {
		app.material = i
		if selected do app.ui.scene_command = {kind = .Material, material = MATERIALS[i]}
	}
	lights := look_lights_studio() if studio else LIGHTS_DEFAULT
	app.start_lights = lights
	app.scene.lights = lights
	app.background = LOOK_BACKGROUND_STUDIO if studio else BACKGROUND_DEFAULT
	app.cavity, app.ridge = 0.7 if studio else CAVITY_DEFAULT, RIDGE_DEFAULT
	app.styled, app.rim, app.underside = studio, RIM_DEFAULT, UNDERSIDE_DEFAULT
	app.live_ao_on = studio
	app.studio_on = studio
	app.studio_ao = 1 if studio else STUDIO_AO_DEFAULT
	app.studio_shadow = LOOK_STUDIO_SHADOW if studio else STUDIO_SHADOW_DEFAULT
	app.studio_softness = LOOK_STUDIO_SOFTNESS if studio else render.STUDIO_KEY_SOFTNESS
	render.studio_reset(&app.studio)
	app.look_chosen = true
}

// Starts a fresh install, or a settings file from before the presets, in Sculpt studio,
// once: the settings then keep `look_chosen` and whatever was changed since.
look_first_run :: proc(app: ^App) {
	if !app.look_chosen do look_apply(app, .Sculpt_Studio, false)
}

// The preset the view is in, by what tells them apart (the style and the studio render),
// whatever has been adjusted since; nil for neither.
look_current :: proc(app: ^App) -> Maybe(Look_Preset) {
	if app.styled && app.studio_on do return .Sculpt_Studio
	if !app.styled && !app.studio_on do return .Classic
	return nil
}

// Scene > Look: the presets, then how bright the key light and the ambient light are and
// how dark and soft the shadows; under More the rest of the look's parts.
kit_look :: proc(app: ^App) {
	ctx := &app.kit.ctx
	names, hints: [len(Look_Preset)]string
	for p in Look_Preset do names[p], hints[p] = LOOK_PRESET_NAMES[p], command_hint(app, .Viewport_Look, int(p))
	shown := -1
	if p, ok := look_current(app).?; ok do shown = int(p)
	if picked := ui.tabs(ctx, "Look", names[:], shown, keys = hints[:]); picked >= 0 do command_run(app, .Viewport_Look, picked)
	set := &app.scene.lights
	if set.count > 0 {
		key := &set.lights[0]
		_ = ui.slider(ctx, "Key light", &key.strength, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", key.strength))
	}
	_ = ui.slider(ctx, "Ambient", &set.ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", set.ambient))
	_ = ui.slider(ctx, "Shadow", &app.studio_shadow, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_shadow))
	_ = ui.slider(ctx, "Shadow softness", &app.studio_softness, render.STUDIO_SOFTNESS_MIN, render.STUDIO_SOFTNESS_MAX, .Logarithmic, fmt.tprintf("%.1f°", math.to_degrees(app.studio_softness)))
	if kit_more(app, .Look) {
		_ = ui.slider(ctx, "Occlusion", &app.studio_ao, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_ao))
		_ = ui.switch_row(ctx, "Styled shading", &app.styled)
		if app.styled {
			_ = ui.slider(ctx, "Rim", &app.rim, 0, RIM_MAX, .Linear, fmt.tprintf("%.2f", app.rim))
			_ = ui.slider(ctx, "Underside", &app.underside, 0, 1, .Linear, fmt.tprintf("%.2f", app.underside))
		}
		grey := app.background.top.r
		if ui.slider(ctx, "Background", &grey, 0, 1, .Linear, fmt.tprintf("%.2f", grey)) do app.background.top = {grey, grey, min(grey * 1.03, 1)}
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Sculpt studio is soft grey clay under a key light from the upper left, with soft shadows, deep shade under the forms and a light rim; the shadows build up while the view is still. Classic is the look the app always had. Each slider is the control of the same name in Lights, Studio render or Background; Underside is how much light reaches surfaces facing down.")
}
