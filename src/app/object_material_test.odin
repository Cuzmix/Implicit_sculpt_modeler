package main

import "core:math"
import "core:testing"

import "../geom"

// A material comes back from the scene file as it went in: a preset by its own label
// (never the file's bytes), a Custom one with its values, a MatCap with its picture's
// number, and none as none.
@(test)
materials_round_trip_in_the_file :: proc(t: ^testing.T) {
	steel, _ := material_by_name("steel")
	custom := Material{label = "Custom", selected = {0.2, 0.4, 0.6, 1}, idle = {0.3, 0.3, 0.3, 1}, shading = {0.1, 0.2, 40, 0.3}, metallic = 0.5, roughness = 0.7}
	image := Material{label = "Custom", selected = {1, 1, 1, 1}, idle = MATCAP_IDLE, matcap = MATCAP_IMAGE}
	for m in ([?]Material{MATERIALS[steel], custom, image, MATERIALS[FIRST_MATCAP], {}}) {
		out: [dynamic]u8
		defer delete(out)
		material_put(&out, m)
		r := geom.byte_reader(out[:])
		back := material_get(&r)
		testing.expect(t, r.ok)
		testing.expect_value(t, r.at, len(out))
		testing.expect_value(t, back, m)
	}
	// A preset's label is the preset's own string, not a copy of the file's.
	out: [dynamic]u8
	defer delete(out)
	material_put(&out, MATERIALS[steel])
	r := geom.byte_reader(out[:])
	back := material_get(&r)
	testing.expect(t, back.label == MATERIALS[steel].label)
	// A name no preset has (from a later version, say) reads as Custom with its values.
	clear(&out)
	material_put(&out, {label = "Velvet", selected = {0.5, 0.1, 0.1, 1}, idle = {0.4, 0.4, 0.4, 1}, roughness = 0.9})
	r = geom.byte_reader(out[:])
	back = material_get(&r)
	testing.expect(t, r.ok && back.label == "Custom" && back.roughness == 0.9)
}

// Values no material has make the file damaged, and the name read is freed either way
// (the test's tracking allocator would report it).
@(test)
damaged_materials_are_refused :: proc(t: ^testing.T) {
	good := MATERIALS[0]
	nan := f32(math.nan_f32())
	bad := [?]Material {
		{label = "Clay", selected = {nan, 0, 0, 1}},
		{label = "Clay", selected = {1.5, 0, 0, 1}},
		{label = "Clay", idle = {0, -0.1, 0, 1}},
		{label = "Clay", metallic = 2},
		{label = "Clay", roughness = -1},
		{label = "Clay", shading = {0, -1, 0, 0}},
		{label = "Clay", shading = {0, 0, math.inf_f32(1), 0}},
		{label = "Clay", matcap = MATCAP_IMAGE + 1},
		{label = "Clay", matcap = -1},
	}
	for m, i in bad {
		out: [dynamic]u8
		defer delete(out)
		material_put(&out, m)
		r := geom.byte_reader(out[:])
		back := material_get(&r)
		testing.expectf(t, !r.ok, "case %d read", i)
		testing.expect_value(t, back.label, nil)
	}
	// Cut short.
	out: [dynamic]u8
	defer delete(out)
	material_put(&out, good)
	r := geom.byte_reader(out[:len(out) - 2])
	_ = material_get(&r)
	testing.expect(t, !r.ok)
}

// The scene file has each object's material after its kind (version 14), so an object
// written now reads back with it.
@(test)
an_objects_material_is_in_its_bytes :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	gold, _ := material_by_name("gold")
	objs[1].material = MATERIALS[gold]
	out: [dynamic]u8
	defer delete(out)
	testing.expect(t, object_put_bytes(&out, objs[1]))
	back: Object
	r := geom.byte_reader(out[:])
	object_get_fields(&r, &back)
	defer delete(back.name)
	kind := geom.byte_get(&r, u8)
	testing.expect_value(t, kind, u8(OBJECT_KIND_MESH))
	testing.expect_value(t, material_get(&r), MATERIALS[gold])
	testing.expect(t, r.ok)
}

// Picking a material gives it to every selected object and makes it the one new objects
// take; the others keep theirs, and the scene counts as changed.
@(test)
a_material_goes_to_the_selection :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	materials_settle(&app)
	for obj in objs do testing.expect_value(t, obj.material, MATERIALS[0])
	// The first and third are selected.
	app.scene.selected = 0
	append(&app.scene.also, objs[2].id)
	app.scene.also_for = objs[0].id
	steel, _ := material_by_name("steel")
	edits := app.scene_edits
	material_set(&app, MATERIALS[steel])
	testing.expect_value(t, objs[0].material, MATERIALS[steel])
	testing.expect_value(t, objs[1].material, MATERIALS[0])
	testing.expect_value(t, objs[2].material, MATERIALS[steel])
	testing.expect_value(t, app.material, steel)
	testing.expect(t, app.scene_edits > edits)
	// A Custom one becomes the Custom new objects take.
	own := Material{label = "Custom", selected = {0.1, 0.2, 0.3, 1}, idle = {0.4, 0.4, 0.4, 1}, roughness = 0.5}
	material_set(&app, own)
	testing.expect_value(t, app.material, CUSTOM_MATERIAL)
	testing.expect_value(t, app.custom, own)
	testing.expect_value(t, objs[2].material, own)
	// An object made now has none until the frame settles it to the default.
	objs[1].material = {}
	testing.expect_value(t, object_material(&app, objs[1]), own)
	materials_settle(&app)
	testing.expect_value(t, objs[1].material, own)
}

// With Dim the others on, objects not selected show their material's muted colour;
// off, their own.
@(test)
dim_the_others_mutes_the_unselected :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	red, _ := material_by_name("red wax")
	for obj in objs do obj.material = MATERIALS[red]
	app.scene.selected = 0
	app.dim_others = true
	selected, _, _ := object_draw_tint(&app, objs[0], 0)
	other, _, _ := object_draw_tint(&app, objs[1], 1)
	testing.expect_value(t, selected, MATERIALS[red].selected)
	testing.expect_value(t, other, MATERIALS[red].idle)
	app.dim_others = false
	other, _, _ = object_draw_tint(&app, objs[1], 1)
	testing.expect_value(t, other, MATERIALS[red].selected)
}

// Exports describe each kind of material in glTF's terms: physically based as it is, a
// classic one with the roughness its highlight has and no metal, a MatCap by its painted
// colour, all tinted as the viewport tints them.
@(test)
materials_export_in_metallic_roughness_terms :: proc(t: ^testing.T) {
	gold, _ := material_by_name("gold")
	g := export_material(MATERIALS[gold])
	testing.expect_value(t, g.name, "Gold")
	testing.expect_value(t, g.base, MATERIALS[gold].selected.rgb)
	testing.expect(t, g.metallic == 1 && g.roughness == MATERIALS[gold].roughness)
	// Clay's highlight power of 40 is GGX alpha sqrt(2/42), about 0.47 roughness.
	clay := export_material(MATERIALS[0])
	testing.expect(t, clay.metallic == 0 && abs(clay.roughness - 0.467) < 0.001)
	// A sharper highlight is smoother.
	grey, _ := material_by_name("grey")
	testing.expect(t, export_material(MATERIALS[grey]).roughness < clay.roughness)
	toon := MATERIALS[FIRST_MATCAP + 5]
	toon.selected = {0.5, 1, 1, 1}
	e := export_material(toon)
	testing.expect_value(t, e.base, MATCAP_RECIPES[5].base * [3]f32{0.5, 1, 1})
	testing.expect_value(t, e.metallic, 0)
	image := export_material({label = "Custom", selected = {1, 1, 1, 1}, matcap = MATCAP_IMAGE})
	testing.expect(t, image.base == 0.5 && image.roughness == 0.5 && image.name == "Custom")
}

// A scrub shows each material on the objects Apply to names and keeps the last one
// lifted on, or puts back what each object had, however many it passed; Every object
// reaches the objects not selected too.
@(test)
a_material_scrub_keeps_or_puts_back :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	defer {delete(app.material_saved.ids); delete(app.material_saved.before)}
	objs := tree_scene(&app)
	materials_settle(&app)
	app.scene.selected = 0
	gold, _ := material_by_name("gold")
	steel, _ := material_by_name("steel")
	objs[1].material = MATERIALS[steel]
	material_command(&app, MATERIALS[gold], .Every, .Show)
	material_command(&app, MATERIALS[FIRST_MATCAP], .Every, .Show)
	for obj in objs do testing.expect_value(t, obj.material, MATERIALS[FIRST_MATCAP])
	material_command(&app, {}, .Every, .Back)
	testing.expect_value(t, objs[0].material, MATERIALS[0])
	testing.expect_value(t, objs[1].material, MATERIALS[steel])
	testing.expect_value(t, app.material, 0)
	testing.expect(t, !app.material_saved.active)
	// Kept: what was shown stays, on the selected object alone.
	material_command(&app, MATERIALS[gold], .Selection, .Show)
	material_command(&app, {}, .Selection, .Keep)
	testing.expect_value(t, objs[0].material, MATERIALS[gold])
	testing.expect_value(t, objs[1].material, MATERIALS[steel])
	testing.expect_value(t, app.material_keeps, 1)
	material_command(&app, {}, .Selection, .Back)
	testing.expect_value(t, objs[0].material, MATERIALS[gold])
}
