package main

import "core:strings"

// How objects are shaded in the viewport: a colour for the selected object, one for the
// others, and the light's ambient, specular, shininess and wrap (render.Draw_Item.material).
Material :: struct {
	label:    cstring,
	selected: [4]f32,
	idle:     [4]f32,
	shading:  [4]f32,
}

// The View menu's materials. Clay is what the viewport always used; wrap lets the light
// reach past the terminator, as skin and wax scatter it.
MATERIALS := [?]Material {
	{"Clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {0.08, 0.2, 40, 0}},
	{"Red wax", {0.62, 0.16, 0.12, 1}, {0.40, 0.30, 0.29, 1}, {0.06, 0.45, 60, 0.35}},
	{"White", {0.82, 0.82, 0.80, 1}, {0.50, 0.50, 0.52, 1}, {0.12, 0.15, 24, 0.1}},
	{"Grey", {0.50, 0.50, 0.52, 1}, {0.34, 0.34, 0.36, 1}, {0.10, 0.35, 80, 0}},
	{"Skin", {0.78, 0.55, 0.45, 1}, {0.45, 0.40, 0.38, 1}, {0.07, 0.12, 20, 0.5}},
}

material_by_name :: proc(name: string) -> (index: int, ok: bool) {
	for m, i in MATERIALS {
		if strings.equal_fold(name, string(m.label)) do return i, true
	}
	return 0, false
}
