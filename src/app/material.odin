package main

import "core:math"
import "core:slice"
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
	// A matcap shades it instead of the lights: 1 + an index into MATCAP_RECIPES,
	// MATCAP_IMAGE for the loaded image, or PACK_MATCAP + an index into Library.matcaps
	// for a content pack's; 0 for none (matcaps.odin).
	matcap:    int,
	// A content pack's material: 1 + an index into Library.materials, whose label this
	// is; 0 for the others (pack_material.odin).
	pack:      int,
	// Subsurface scattering, coat, sheen, emission, transmission and thin film over the
	// above; zero for none (geom.Material_Layers).
	layers:    geom.Material_Layers,
}

// The View menu's materials. Clay is what the viewport always used; wrap lets the light
// reach past the terminator, as skin and wax scatter it. The ones after FIRST_PBR are
// physically based: metals take their colour from measured reflectances (linear F0), and
// the classic `shading` is left at the default as they do not use it.
MATERIALS := [?]Material {
	{"Clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {0.08, 0.2, 40, 0}, 0, 0, 0, 0, {}},
	{"Red wax", {0.62, 0.16, 0.12, 1}, {0.40, 0.30, 0.29, 1}, {0.06, 0.45, 60, 0.35}, 0, 0, 0, 0, {}},
	{"White", {0.82, 0.82, 0.80, 1}, {0.50, 0.50, 0.52, 1}, {0.12, 0.15, 24, 0.1}, 0, 0, 0, 0, {}},
	{"Grey", {0.50, 0.50, 0.52, 1}, {0.34, 0.34, 0.36, 1}, {0.10, 0.35, 80, 0}, 0, 0, 0, 0, {}},
	{"Skin", {0.78, 0.55, 0.45, 1}, {0.45, 0.40, 0.38, 1}, {0.07, 0.12, 20, 0.5}, 0, 0, 0, 0, {}},
	// Scene > Look's Sculpt studio: a soft grey with a broad, faint sheen and a little wrap.
	{"Studio grey", {0.55, 0.55, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {0.12, 0.10, 14, 0.15}, 0, 0, 0, 0, {}},
	{"Gold", {1.00, 0.77, 0.34, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.30, 0, 0, {}},
	{"Copper", {0.95, 0.64, 0.54, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.35, 0, 0, {}},
	{"Chrome", {0.55, 0.56, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.08, 0, 0, {}},
	{"Steel", {0.56, 0.57, 0.58, 1}, {0.42, 0.42, 0.44, 1}, {}, 1, 0.45, 0, 0, {}},
	{"Plastic", {0.06, 0.18, 0.55, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.25, 0, 0, {}},
	{"Ceramic", {0.70, 0.69, 0.66, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.12, 0, 0, {}},
	{"Rubber", {0.025, 0.025, 0.025, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.85, 0, 0, {}},
	{"PBR clay", {0.55, 0.40, 0.32, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.60, 0, 0, {}},
	// Materials light passes into, which Full render scatters under the surface (the
	// Material_Layers' subsurface): the base colour is the colour seen, and how far light
	// travels inside, per channel, in mesh units (an imported model's radius is 1). Wax
	// carries red and green furthest, jade green, milk and marble nearly evenly.
	{"Wax", {0.80, 0.62, 0.38, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.35, 0, 0, {subsurface_color = 1, subsurface_weight = 1, subsurface_radius = {1, 0.75, 0.4}, subsurface_scale = 0.12}},
	{"Jade", {0.24, 0.55, 0.34, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.22, 0, 0, {subsurface_color = 1, subsurface_weight = 1, subsurface_radius = {0.5, 1, 0.6}, subsurface_scale = 0.08}},
	{"Marble", {0.84, 0.83, 0.79, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.18, 0, 0, {subsurface_color = 1, subsurface_weight = 1, subsurface_radius = {1, 0.92, 0.8}, subsurface_scale = 0.04}},
	{"Milk", {0.90, 0.88, 0.80, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.30, 0, 0, {subsurface_color = 1, subsurface_weight = 1, subsurface_radius = {1, 0.9, 0.7}, subsurface_scale = 0.15}},
	// Layered materials (Full render shows their layers; the viewport, for now, their base):
	// car paint's clear coat over a metallic red, velvet's and satin's sheen, and neon's glow.
	{"Car paint", {0.55, 0.03, 0.04, 1}, {0.42, 0.42, 0.44, 1}, {}, 0.6, 0.4, 0, 0, {coat_weight = 1, coat_roughness = 0.03}},
	{"Velvet", {0.30, 0.02, 0.06, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.9, 0, 0, {sheen_color = {1, 0.55, 0.65}, sheen_weight = 1, sheen_roughness = 0.5}},
	{"Satin", {0.62, 0.62, 0.66, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.45, 0, 0, {sheen_color = {1, 1, 1}, sheen_weight = 0.6, sheen_roughness = 0.25}},
	{"Neon", {0.04, 0.04, 0.05, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.3, 0, 0, {emission_color = {1, 0.12, 0.55}, emission_luminance = 2.5}},
	// Glass, clear and frosted: light passes through, bent by its IOR (1.5), and Full
	// render shows what is behind it; the viewport, for now, its base.
	{"Glass", {1, 1, 1, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.02, 0, 0, {transmission_color = {1, 1, 1}, transmission_weight = 1}},
	{"Frosted glass", {1, 1, 1, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.3, 0, 0, {transmission_color = {0.95, 0.98, 1}, transmission_weight = 1}},
	// A soap film: a thin sheet that lets light straight through and reflects in the
	// colours of interference, from a film 350 nm thick.
	{"Soap film", {1, 1, 1, 1}, {0.42, 0.42, 0.44, 1}, {}, 0, 0.02, 0, 0, {transmission_color = {1, 1, 1}, transmission_weight = 1, thin_walled = 1, thin_film_weight = 1, thin_film_thickness = 350, thin_film_ior = 1.33}},
	// The matcaps, in white so their pictures show as painted.
	{"Red wax MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 1, 0, {}},
	{"Brown clay MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 2, 0, {}},
	{"Grey clay MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 3, 0, {}},
	{"Green clay MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 4, 0, {}},
	{"Skin MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 5, 0, {}},
	{"Pearl MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 6, 0, {}},
	{"Toon MatCap", {1, 1, 1, 1}, MATCAP_IDLE, {}, 0, 0, 7, 0, {}},
}

// The index of the first physically based material, where the View menu starts a new group.
FIRST_PBR :: 6
// The index of the first matcap, where the next group starts.
FIRST_MATCAP :: 25

// app.material's value for the material the View > Material sliders made (app.custom).
CUSTOM_MATERIAL :: len(MATERIALS)
// app.material's value for a content pack's material: PACK_MATERIAL + its index in
// Library.materials, apart from the presets and Custom.
PACK_MATERIAL :: 1 << 16

// The values of a geom.Material_Layers the settings' custom_layers line holds: all its fields.
CUSTOM_LAYER_VALUES :: 32

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

// The material new objects take: a preset, Custom, or a content pack's (Clay once its
// pack is gone).
current_material :: proc(app: ^App) -> Material {
	switch {
	case app.material == CUSTOM_MATERIAL: return app.custom
	case app.material >= PACK_MATERIAL:
		if pm, ok := pack_material_at(app, app.material - PACK_MATERIAL); ok do return pm.material
		return MATERIALS[0]
	}
	return MATERIALS[app.material]
}

// How strongly creases darken and crests lighten unless the settings say otherwise:
// enough for sculpted detail to read at any light angle without outlining every form.
CAVITY_DEFAULT :: 0.35
RIDGE_DEFAULT :: 0.3
// The style's rim strength and the share of the ambient light under the forms, matched to
// renders of grey studio sculpts: a light rim, and deep shade under a jaw or a brow.
RIM_DEFAULT :: 0.35
RIM_MAX :: 1
UNDERSIDE_DEFAULT :: 0.15

// The furthest the exposure goes either way, in stops.
EXPOSURE_RANGE :: 3

// The viewport's look for render.Draw_Item.look: exposure, cavity and ridge.
viewport_look :: proc(app: ^App) -> [4]f32 {
	return {app.exposure, app.cavity, app.ridge, 0}
}

// The style the viewport's objects are shaded with (render.Draw_Item.style): zero, the
// classic rim and even ambient light, unless App.styled.
viewport_style :: proc(app: ^App) -> [4]f32 {
	// z leaves the mask's darkening out, whichever style is drawn.
	hide_mask: f32 = 1 if app.ui.mask_hidden else 0
	if !app.styled do return {0, 0, hide_mask, 0}
	return {clamp(app.rim, 0, RIM_MAX), clamp(app.underside, 0, 1), hide_mask, 1}
}

// The material `obj` is shaded with: its own, or the default (current_material) while it
// has none yet, which materials_settle gives it at the start of the next frame.
object_material :: proc(app: ^App, obj: ^Object) -> Material {
	return obj.material if obj.material.label != nil else current_material(app)
}

// The layers `m` is drawn with: its own, or none under a MatCap, whose picture is the
// whole look.
material_layers_drawn :: proc(m: Material) -> geom.Material_Layers {
	return {} if m.matcap != 0 else m.layers
}

// Where `m` is in the Material section's list: its preset, a content pack's, or Custom.
material_index :: proc(m: Material) -> int {
	if m.label == nil do return 0
	if m.pack > 0 do return PACK_MATERIAL + m.pack - 1
	i, found := material_by_name(string(m.label))
	return i if found else CUSTOM_MATERIAL
}

// Gives every selected object material `m` (a Scene_Command's .Material) and makes it the
// default new objects take, as picking a material does in the Material section. It is no
// undo step (a ZBrush material is outside its Undo History too), but the scene counts as
// changed.
material_set :: proc(app: ^App, m: Material, to := Material_Target.Selection) {
	m := m
	m.selected.a, m.idle.a = 1, 1
	if m.label == nil do m.label = "Custom"
	// Moving a slider on a pack's material makes a Custom one, which is no longer the
	// pack's; a pack removed since the material was picked leaves Clay.
	if m.label == "Custom" do m.pack = 0
	if m.pack > 0 {
		if _, ok := pack_material_at(app, m.pack - 1); !ok do m = MATERIALS[0]
	}
	if m.matcap >= PACK_MATCAP {
		if _, ok := pack_matcap_at(app, m.matcap - PACK_MATCAP); !ok do m.matcap = 0
	}
	i := material_index(m)
	if i == CUSTOM_MATERIAL do app.custom = m
	app.material = i
	for obj in app.scene.objects do if material_takes(app, obj, to) do obj.material = m
	app.scene_edits += 1
}

// Which objects a material picked on the Material card goes to (its Apply to): the
// selected ones, every object in the selected one's folder, or every object.
Material_Target :: enum u8 {
	Selection,
	Folder,
	Every,
}

// Whether `obj` takes a material sent to `to`.
material_takes :: proc(app: ^App, obj: ^Object, to: Material_Target) -> bool {
	switch to {
	case .Selection: return object_in_selection(app, obj)
	case .Folder:
		sel := selected_object(app)
		if sel == nil do return false
		return obj == sel || object_in_selection(app, obj) || (sel.folder != 0 && obj.folder != 0 && folder_within(app, obj.folder, sel.folder))
	case .Every:     return true
	}
	return false
}

// A scrub over the Material card's spheres (Nomad's): each sphere the finger passes shows
// its material on the objects at once, the materials they had kept aside; lifting on a
// sphere keeps it, sliding off and lifting puts them back.
Material_Preview :: enum u8 {
	None, // an ordinary pick
	Show, // shows the material, keeping what the objects had the first time
	Keep, // keeps what is shown
	Back, // puts back what the objects had
}

// What a scrub keeps aside: each object's material by id, and the default new objects take.
Material_Saved :: struct {
	active:   bool,
	ids:      [dynamic]int,
	before:   [dynamic]Material,
	material: int,
	custom:   Material,
}

// Applies a Scene_Command's .Material: `m` to the objects `to` names, as a pick or as a
// step of a scrub (`preview`).
material_command :: proc(app: ^App, m: Material, to: Material_Target, preview: Material_Preview) {
	sv := &app.material_saved
	switch preview {
	case .None:
		material_saved_drop(app)
		material_set(app, m, to)
	case .Show:
		if !sv.active {
			sv.active, sv.material, sv.custom = true, app.material, app.custom
			for obj in app.scene.objects {
				if !material_takes(app, obj, to) do continue
				append(&sv.ids, obj.id)
				append(&sv.before, obj.material)
			}
		}
		material_set(app, m, to)
		app.material_previews += 1
	case .Keep:
		if sv.active do app.material_keeps += 1
		material_saved_drop(app)
	case .Back:
		if !sv.active do return
		for id, i in sv.ids do if obj := object_by_id(app, id); obj != nil do obj.material = sv.before[i]
		app.material, app.custom = sv.material, sv.custom
		app.scene_edits += 1
		material_saved_drop(app)
	}
}

// Forgets what a scrub kept aside.
material_saved_drop :: proc(app: ^App) {
	sv := &app.material_saved
	clear(&sv.ids)
	clear(&sv.before)
	sv.active = false
}

// Gives each object that has no material yet (made this frame, or read from a scene
// with none named) the default, so it keeps it when the default changes.
materials_settle :: proc(app: ^App) {
	for obj in app.scene.objects {
		if obj.material.label != nil do continue
		autosave_settle(app)
		obj.material = current_material(app)
	}
}

// The scene file's form of a material (object_put), a record (tags are never reused or
// retyped, geom/record.odin): its label ("" for none yet, which reads back as none),
// colours, classic shading, metallic, roughness and matcap, then what of it is a content
// pack's, by name: the material as `<id>/<name>` and the matcap as `<id>/<stem>`, each
// absent for none (material_refs), then its layers, a field each. A pack's matcap goes as
// 0, so a scene opened where the pack is not installed shows the lights.
Material_Tag :: enum u16 {
	Label         = 1,  // text
	Selected      = 2,  // [3]f32 linear colour while selected
	Idle          = 3,  // [3]f32 colour otherwise
	Shading       = 4,  // [4]f32 classic shading
	Metallic      = 5,  // f32
	Roughness     = 6,  // f32
	Matcap        = 7,  // i32
	Pack_Material = 8,  // text `<id>/<name>`
	Pack_Matcap   = 9,  // text `<id>/<stem>`
	Layers        = 10, // Material_Layer_Tag record
}

// A material's layers (geom.Material_Layers), a field a value; a value the file lacks is
// zero, which material_layers_resolve reads as the layer's default.
Material_Layer_Tag :: enum u16 {
	Subsurface_Color      = 1,
	Subsurface_Weight     = 2,
	Subsurface_Radius     = 3,
	Subsurface_Scale      = 4,
	Coat_Weight           = 5,
	Coat_Roughness        = 6,
	Coat_Ior              = 7,
	Specular_Ior          = 8,
	Sheen_Color           = 9,
	Sheen_Weight          = 10,
	Emission_Color        = 11,
	Emission_Luminance    = 12,
	Transmission_Color    = 13,
	Transmission_Weight   = 14,
	Transmission_Depth    = 15,
	Thin_Walled           = 16,
	Sheen_Roughness       = 17,
	Subsurface_Anisotropy = 18,
	Thin_Film_Weight      = 19,
	Thin_Film_Thickness   = 20,
	Thin_Film_Ior         = 21,
	Specular_Lessen       = 22,
}

// Where each layer's value sits in geom.Material_Layers and how many bytes it takes.
@(private = "file")
MATERIAL_LAYER_FIELDS := [Material_Layer_Tag]struct {
	offset, size: uintptr,
} {
	.Subsurface_Color = {offset_of(geom.Material_Layers, subsurface_color), size_of([3]f32)},
	.Subsurface_Weight = {offset_of(geom.Material_Layers, subsurface_weight), size_of(f32)},
	.Subsurface_Radius = {offset_of(geom.Material_Layers, subsurface_radius), size_of([3]f32)},
	.Subsurface_Scale = {offset_of(geom.Material_Layers, subsurface_scale), size_of(f32)},
	.Coat_Weight = {offset_of(geom.Material_Layers, coat_weight), size_of(f32)},
	.Coat_Roughness = {offset_of(geom.Material_Layers, coat_roughness), size_of(f32)},
	.Coat_Ior = {offset_of(geom.Material_Layers, coat_ior), size_of(f32)},
	.Specular_Ior = {offset_of(geom.Material_Layers, specular_ior), size_of(f32)},
	.Sheen_Color = {offset_of(geom.Material_Layers, sheen_color), size_of([3]f32)},
	.Sheen_Weight = {offset_of(geom.Material_Layers, sheen_weight), size_of(f32)},
	.Emission_Color = {offset_of(geom.Material_Layers, emission_color), size_of([3]f32)},
	.Emission_Luminance = {offset_of(geom.Material_Layers, emission_luminance), size_of(f32)},
	.Transmission_Color = {offset_of(geom.Material_Layers, transmission_color), size_of([3]f32)},
	.Transmission_Weight = {offset_of(geom.Material_Layers, transmission_weight), size_of(f32)},
	.Transmission_Depth = {offset_of(geom.Material_Layers, transmission_depth), size_of(f32)},
	.Thin_Walled = {offset_of(geom.Material_Layers, thin_walled), size_of(f32)},
	.Sheen_Roughness = {offset_of(geom.Material_Layers, sheen_roughness), size_of(f32)},
	.Subsurface_Anisotropy = {offset_of(geom.Material_Layers, subsurface_anisotropy), size_of(f32)},
	.Thin_Film_Weight = {offset_of(geom.Material_Layers, thin_film_weight), size_of(f32)},
	.Thin_Film_Thickness = {offset_of(geom.Material_Layers, thin_film_thickness), size_of(f32)},
	.Thin_Film_Ior = {offset_of(geom.Material_Layers, thin_film_ior), size_of(f32)},
	.Specular_Lessen = {offset_of(geom.Material_Layers, specular_lessen), size_of(f32)},
}

material_put :: proc(out: ^[dynamic]u8, m: Material, refs := Material_Refs{}) {
	T :: Material_Tag
	rec := geom.record_begin(out)
	defer geom.record_end(out, rec)
	if m.label != nil do geom.rec_put_string(out, T.Label, string(m.label))
	geom.rec_put(out, T.Selected, m.selected.rgb)
	geom.rec_put(out, T.Idle, m.idle.rgb)
	geom.rec_put(out, T.Shading, m.shading)
	geom.rec_put(out, T.Metallic, m.metallic)
	geom.rec_put(out, T.Roughness, m.roughness)
	geom.rec_put(out, T.Matcap, i32(m.matcap if m.matcap < PACK_MATCAP else 0))
	if refs.material != "" do geom.rec_put_string(out, T.Pack_Material, refs.material)
	if refs.matcap != "" do geom.rec_put_string(out, T.Pack_Matcap, refs.matcap)
	at := geom.rec_begin(out, T.Layers)
	layers := m.layers
	bytes := slice.bytes_from_ptr(&layers, size_of(layers))
	for f, tag in MATERIAL_LAYER_FIELDS {
		geom.byte_put(out, u16(tag))
		geom.byte_put(out, u64(f.size))
		append(out, ..bytes[f.offset:][:f.size])
	}
	geom.rec_end(out, at)
}

// Reads what material_put writes; r.ok goes false on values
// no material has. A preset's name takes the preset's own label and any other name
// becomes Custom, so the label never points into the file's bytes. A content pack's
// material or matcap is looked up in `app`'s library; one whose pack is not installed
// (or with no app) leaves a Custom material with the same colours and the lights, and
// counts in `missing`.
material_get :: proc(r: ^geom.Byte_Reader, app: ^App = nil, missing: ^int = nil) -> (m: Material) {
	T :: Material_Tag
	rec := geom.record_take(r)
	known, _ := geom.record_known(&rec, Material_Tag)
	name, _ := geom.rec_find(&rec, T.Label)
	m.selected.rgb = geom.rec_get(&rec, T.Selected, [3]f32, [3]f32{1, 1, 1})
	m.idle.rgb = geom.rec_get(&rec, T.Idle, [3]f32, [3]f32{1, 1, 1})
	m.selected.a, m.idle.a = 1, 1
	m.shading = geom.rec_get(&rec, T.Shading, [4]f32, [4]f32{})
	m.metallic = geom.rec_get(&rec, T.Metallic, f32, 0)
	m.roughness = geom.rec_get(&rec, T.Roughness, f32, 0.5)
	m.matcap = int(geom.rec_get(&rec, T.Matcap, i32, 0))
	pack_material, _ := geom.rec_find(&rec, T.Pack_Material)
	pack_matcap, _ := geom.rec_find(&rec, T.Pack_Matcap)
	refs := Material_Refs{string(pack_material), string(pack_matcap)}
	lr, _ := geom.rec_sub(&rec, T.Layers)
	known_layers, _ := geom.record_known(&lr, Material_Layer_Tag)
	bytes := slice.bytes_from_ptr(&m.layers, size_of(m.layers))
	for f, tag in MATERIAL_LAYER_FIELDS {
		payload, present := geom.rec_find(&lr, tag)
		if !present do continue
		if uintptr(len(payload)) != f.size do lr.ok = false
		else do copy(bytes[f.offset:][:f.size], payload)
	}
	unit :: proc(v: f32) -> bool {return v >= 0 && v <= 1}
	ok := rec.ok && lr.ok && known && known_layers && unit(m.metallic) && unit(m.roughness) && m.matcap >= 0 && m.matcap <= MATCAP_IMAGE
	// A reference is `<id>/<name>`, and a pack's matcap stands in for the number.
	ok &&= material_ref_valid(refs.material) && material_ref_valid(refs.matcap) && (refs.matcap == "" || m.matcap == 0)
	for k in 0 ..< 3 do ok &&= unit(m.selected[k]) && unit(m.idle[k])
	// Shininess goes well past 1; only a finite, non-negative value makes sense.
	for v in m.shading do ok &&= v >= 0 && v < 1e6
	ok &&= geom.material_layers_valid(m.layers)
	if !ok {
		r.ok = false
		return {}
	}
	if len(name) == 0 do return {}
	i, found := material_by_name(string(name))
	m.label = MATERIALS[i].label if found && i < len(MATERIALS) else "Custom"
	if refs.material == "" && refs.matcap == "" do return
	if j := pack_material_by_ref(app, refs.material) if app != nil else -1; j >= 0 {
		return app.library.materials[j].material
	}
	k := pack_matcap_by_ref(app, refs.matcap) if app != nil else -1
	if k >= 0 do m.matcap = PACK_MATCAP + k
	if (refs.material != "" || k < 0) && missing != nil do missing^ += 1
	return
}

// `m` in glTF's metallic-roughness terms, for the glTF and USD exports. Physically based
// materials go as they are. A classic one's highlight becomes the roughness whose GGX
// lobe is about as wide (Blinn-Phong power n is GGX alpha sqrt(2 / (n + 2)), and
// roughness is alpha's square root), with no metal. A MatCap has no lights to go by: a
// built-in one gives its painted colour and the roughness its highlight has, a loaded
// image or a content pack's picture a mid grey; all tinted by the colour, as the
// viewport tints them.
export_material :: proc(m: Material) -> geom.Export_Material {
	out := geom.Export_Material {
		name      = string(m.label) if m.label != nil else "Custom",
		base      = m.selected.rgb,
		metallic  = m.metallic,
		roughness = m.roughness,
		layers    = material_layers_drawn(m),
	}
	phong :: proc(power: f32) -> f32 {return clamp(math.sqrt(math.sqrt(2 / (max(power, 0) + 2))), 0.04, 1)}
	switch {
	case m.matcap == MATCAP_IMAGE || m.matcap >= PACK_MATCAP:
		out.base, out.metallic, out.roughness = 0.5 * m.selected.rgb, 0, 0.5
	case m.matcap > 0 && m.matcap <= len(MATCAP_RECIPES):
		r := MATCAP_RECIPES[m.matcap - 1]
		out.base, out.metallic, out.roughness = matcap_base(r) * m.selected.rgb, 0, phong(r.tight_power)
	case m.roughness == 0:
		out.metallic, out.roughness = 0, phong(m.shading[2])
	}
	return out
}
