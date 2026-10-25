package main

import "core:strings"

// How objects are shaded in the viewport: a colour for the selected object, one for the
// others, the classic light's ambient, specular, shininess and wrap
// (render.Draw_Item.material), and for physically based materials metallic and roughness
// (render.Draw_Item.surface), where a roughness of 0 keeps the classic shading.
Material :: struct {
	label:     cstring,
	selected:  [4]f32,
	idle:      [4]f32,
	shading:   [4]f32,
	metallic:  f32,
	roughness: f32,
}

// The View menu's materials. Clay is what the viewport always used; wrap lets the light
// reach past the terminator, as skin and wax scatter it. The ones after FIRST_PBR are
// physically based: metals take their colour from measured reflectances (linear F0), and
// the classic `shading` is left at the default as they do not use it.
MATERIALS := [?]Material {
	{"Clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {0.08, 0.2, 40, 0}, 0, 0},
	{"Red wax", {0.62, 0.16, 0.12, 1}, {0.40, 0.30, 0.29, 1}, {0.06, 0.45, 60, 0.35}, 0, 0},
	{"White", {0.82, 0.82, 0.80, 1}, {0.50, 0.50, 0.52, 1}, {0.12, 0.15, 24, 0.1}, 0, 0},
	{"Grey", {0.50, 0.50, 0.52, 1}, {0.34, 0.34, 0.36, 1}, {0.10, 0.35, 80, 0}, 0, 0},
	{"Skin", {0.78, 0.55, 0.45, 1}, {0.45, 0.40, 0.38, 1}, {0.07, 0.12, 20, 0.5}, 0, 0},
	{"Gold", {1.00, 0.77, 0.34, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.30},
	{"Copper", {0.95, 0.64, 0.54, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.35},
	{"Chrome", {0.55, 0.56, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.08},
	{"Steel", {0.56, 0.57, 0.58, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.45},
	{"Plastic", {0.06, 0.18, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.25},
	{"Ceramic", {0.70, 0.69, 0.66, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.12},
	{"Rubber", {0.025, 0.025, 0.025, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.85},
	{"PBR clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.60},
}

// The index of the first physically based material, where the View menu starts a new group.
FIRST_PBR :: 5

// app.material's value for the material the View > Material sliders made (app.custom).
CUSTOM_MATERIAL :: len(MATERIALS)

// What a classic preset becomes when its sliders are first moved: rough, non-metal.
CUSTOM_ROUGHNESS :: 0.6

// Finds a preset by its label, or "Custom" for the edited one, ignoring case.
material_by_name :: proc(name: string) -> (index: int, ok: bool) {
	if strings.equal_fold(name, "custom") do return CUSTOM_MATERIAL, true
	for m, i in MATERIALS {
		if strings.equal_fold(name, string(m.label)) do return i, true
	}
	return 0, false
}

// The material objects are shaded with now.
current_material :: proc(app: ^App) -> Material {
	return app.custom if app.material == CUSTOM_MATERIAL else MATERIALS[app.material]
}
