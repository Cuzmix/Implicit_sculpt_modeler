package main

import "core:strings"

import "../geom"

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
	// A matcap shades it instead of the lights: 1 + an index into MATCAP_RECIPES, or
	// MATCAP_IMAGE for the loaded image; 0 for none (matcaps.odin).
	matcap:    int,
}

// The View menu's materials. Clay is what the viewport always used; wrap lets the light
// reach past the terminator, as skin and wax scatter it. The ones after FIRST_PBR are
// physically based: metals take their colour from measured reflectances (linear F0), and
// the classic `shading` is left at the default as they do not use it.
MATERIALS := [?]Material {
	{"Clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {0.08, 0.2, 40, 0}, 0, 0, 0},
	{"Red wax", {0.62, 0.16, 0.12, 1}, {0.40, 0.30, 0.29, 1}, {0.06, 0.45, 60, 0.35}, 0, 0, 0},
	{"White", {0.82, 0.82, 0.80, 1}, {0.50, 0.50, 0.52, 1}, {0.12, 0.15, 24, 0.1}, 0, 0, 0},
	{"Grey", {0.50, 0.50, 0.52, 1}, {0.34, 0.34, 0.36, 1}, {0.10, 0.35, 80, 0}, 0, 0, 0},
	{"Skin", {0.78, 0.55, 0.45, 1}, {0.45, 0.40, 0.38, 1}, {0.07, 0.12, 20, 0.5}, 0, 0, 0},
	{"Gold", {1.00, 0.77, 0.34, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.30, 0},
	{"Copper", {0.95, 0.64, 0.54, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.35, 0},
	{"Chrome", {0.55, 0.56, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.08, 0},
	{"Steel", {0.56, 0.57, 0.58, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.45, 0},
	{"Plastic", {0.06, 0.18, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.25, 0},
	{"Ceramic", {0.70, 0.69, 0.66, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.12, 0},
	{"Rubber", {0.025, 0.025, 0.025, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.85, 0},
	{"PBR clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.60, 0},
	// The matcaps, in white so their pictures show as painted.
	{"Red wax MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 1},
	{"Clay MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 2},
	{"Grey MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 3},
	{"Skin MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 4},
	{"Pearl MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 5},
	{"Toon MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 6},
}

// The index of the first physically based material, where the View menu starts a new group.
FIRST_PBR :: 5
// The index of the first matcap, where the next group starts.
FIRST_MATCAP :: 13

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

// How strongly creases darken and crests lighten unless the settings say otherwise:
// enough for sculpted detail to read at any light angle without outlining every form.
CAVITY_DEFAULT :: 0.5
RIDGE_DEFAULT :: 0.3

// The furthest the exposure goes either way, in stops.
EXPOSURE_RANGE :: 3

// The viewport's look for render.Draw_Item.look: exposure, cavity and ridge.
viewport_look :: proc(app: ^App) -> [4]f32 {
	return {app.exposure, app.cavity, app.ridge, 0}
}

// The material `obj` is shaded with: its own, or the default (current_material) while it
// has none yet, which materials_settle gives it at the start of the next frame.
object_material :: proc(app: ^App, obj: ^Object) -> Material {
	return obj.material if obj.material.label != nil else current_material(app)
}

// Where `m` is in the Material section's list: its preset, or Custom.
material_index :: proc(m: Material) -> int {
	if m.label == nil do return 0
	i, found := material_by_name(string(m.label))
	return i if found else CUSTOM_MATERIAL
}

// Gives every selected object material `m` (a Scene_Command's .Material) and makes it the
// default new objects take, as picking a material does in the Material section. It is no
// undo step (a ZBrush material is outside its Undo History too), but the scene counts as
// changed.
material_set :: proc(app: ^App, m: Material) {
	m := m
	m.selected.a, m.idle.a = 1, 1
	if m.label == nil do m.label = "Custom"
	i := material_index(m)
	if i == CUSTOM_MATERIAL do app.custom = m
	app.material = i
	for obj in app.scene.objects do if object_in_selection(app, obj) do obj.material = m
	app.scene_edits += 1
}

// Gives each object that has no material yet (made this frame, or read from a scene
// older than version 13) the default, so it keeps it when the default changes.
materials_settle :: proc(app: ^App) {
	for obj in app.scene.objects {
		if obj.material.label != nil do continue
		autosave_settle(app)
		obj.material = current_material(app)
	}
}

// The scene file's form of a material (object_put): its label ("" for none yet, which
// reads back as none), colours, classic shading, metallic, roughness and matcap.
material_put :: proc(out: ^[dynamic]u8, m: Material) {
	geom.byte_put_string(out, string(m.label) if m.label != nil else "")
	geom.byte_put(out, m.selected.rgb)
	geom.byte_put(out, m.idle.rgb)
	geom.byte_put(out, m.shading)
	geom.byte_put(out, [2]f32{m.metallic, m.roughness})
	geom.byte_put(out, i32(m.matcap))
}

// Reads what material_put writes; r.ok goes false on values no material has. A preset's
// name takes the preset's own label and any other name becomes Custom, so the label never
// points into the file's bytes.
material_get :: proc(r: ^geom.Byte_Reader) -> (m: Material) {
	name := geom.byte_get_string(r)
	defer delete(name)
	m.selected.rgb = geom.byte_get(r, [3]f32)
	m.idle.rgb = geom.byte_get(r, [3]f32)
	m.selected.a, m.idle.a = 1, 1
	m.shading = geom.byte_get(r, [4]f32)
	surface := geom.byte_get(r, [2]f32)
	m.metallic, m.roughness = surface[0], surface[1]
	m.matcap = int(geom.byte_get(r, i32))
	unit :: proc(v: f32) -> bool {return v >= 0 && v <= 1}
	ok := unit(m.metallic) && unit(m.roughness) && m.matcap >= 0 && m.matcap <= MATCAP_IMAGE
	for k in 0 ..< 3 do ok &&= unit(m.selected[k]) && unit(m.idle[k])
	// Shininess goes well past 1; only a finite, non-negative value makes sense.
	for v in m.shading do ok &&= v >= 0 && v < 1e6
	if !ok {
		r.ok = false
		return {}
	}
	if name == "" do return {}
	i, found := material_by_name(name)
	m.label = MATERIALS[i].label if found && i < len(MATERIALS) else "Custom"
	return
}
