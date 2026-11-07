package main

import "core:math"
import "core:os"
import "core:strings"
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
	// Every layer at a value of its own, so a field read into another's place shows.
	layered := custom
	layered.layers = {
		subsurface_color = {0.9, 0.4, 0.3}, subsurface_weight = 0.8, subsurface_radius = {1, 0.4, 0.2}, subsurface_scale = 0.03,
		coat_weight = 0.5, coat_roughness = 0.1, coat_ior = 1.55, specular_ior = 1.45,
		sheen_color = {0.2, 0.3, 0.4}, sheen_weight = 0.25, emission_color = {1, 0.5, 0}, emission_luminance = 3,
		transmission_color = {0.7, 0.8, 0.9}, transmission_weight = 0.6, transmission_depth = 0.2, thin_walled = 1,
		sheen_roughness = 0.45, subsurface_anisotropy = -0.3, thin_film_weight = 0.9, thin_film_thickness = 420, thin_film_ior = 1.3, specular_lessen = 0.16,
	}
	for m in ([?]Material{MATERIALS[steel], custom, image, MATERIALS[FIRST_MATCAP], {}, layered}) {
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
	material_put(&out, {label = "Felt", selected = {0.5, 0.1, 0.1, 1}, idle = {0.4, 0.4, 0.4, 1}, roughness = 0.9})
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
		{label = "Clay", layers = {subsurface_weight = nan}},
		{label = "Clay", layers = {coat_weight = 1.5}},
		{label = "Clay", layers = {subsurface_radius = {1, -1, 0}}},
		{label = "Clay", layers = {specular_ior = 0.5}},
		{label = "Clay", layers = {emission_luminance = math.inf_f32(1)}},
		{label = "Clay", layers = {subsurface_anisotropy = 2}},
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
	rec := test_object_record(out[:])
	testing.expect_value(t, geom.rec_get(&rec, Object_Tag.Kind, u8, 9), u8(OBJECT_KIND_MESH))
	mr, _ := geom.rec_reader(&rec, Object_Tag.Material)
	testing.expect_value(t, material_get(&mr), MATERIALS[gold])
	testing.expect(t, mr.ok && rec.ok)
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
	toon := MATERIALS[FIRST_MATCAP + 6]
	toon.selected = {0.5, 1, 1, 1}
	e := export_material(toon)
	testing.expect_value(t, e.base, matcap_base(MATCAP_RECIPES[6]) * [3]f32{0.5, 1, 1})
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

// The Material card's favourites toggle on and off in the order added, and settings.txt
// keeps them, a pack's part by its name.
@(test)
material_favorites_are_remembered :: proc(t: ^testing.T) {
	path := "build/material_favorites_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	mc := &a.kit.material_card
	testing.expect(t, material_favorite_toggle(mc, "Gold"))
	testing.expect(t, material_favorite_toggle(mc, "Red wax MatCap"))
	testing.expect(t, material_favorite_toggle(mc, "matcap:stone pack/Basalt"))
	testing.expect(t, !material_favorite_toggle(mc, "Red wax MatCap"))
	testing.expect_value(t, mc.favorite_count, 2)
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	settings_load(&b, path)
	got := &b.kit.material_card
	testing.expect_value(t, got.favorite_count, 2)
	testing.expect_value(t, material_favorite(got, "Gold"), 0)
	testing.expect_value(t, material_favorite(got, "matcap:stone pack/Basalt"), 1)
	testing.expect_value(t, material_favorite(got, "Red wax MatCap"), -1)
}

// Custom's layers are remembered by the settings; a custom_layers line with a value no
// material has, or too few values, is passed over whole and leaves none.
@(test)
custom_layers_are_remembered_and_bad_ones_passed_over :: proc(t: ^testing.T) {
	path := "build/custom_layers_test.txt"
	defer os.remove(path)
	a := new(App)
	defer free(a)
	defer results_destroy(a)
	a.custom = MATERIALS[0]
	a.custom.layers = {subsurface_color = {0.9, 0.5, 0.4}, subsurface_weight = 1, subsurface_scale = 0.02, coat_weight = 0.3, thin_film_thickness = 300}
	testing.expect(t, settings_save(a, path))
	b := new(App)
	defer free(b)
	defer results_destroy(b)
	settings_load(b, path)
	testing.expect_value(t, b.custom.layers, a.custom.layers)

	bad := [?]string {
		"custom_layers 0.5 0.5 0.5 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
		"custom_layers 0.5 0.5 0.5 1",
		"custom_layers 0.5 0.5 0.5 x 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
	}
	for line in bad {
		testing.expect(t, os.write_entire_file(path, transmute([]u8)line) == nil)
		c := new(App)
		settings_load(c, path)
		testing.expectf(t, c.custom.layers == {}, "%s", line)
		results_destroy(c)
		free(c)
	}
}

// Every preset's layers are ones a scene file accepts, so saving an object with any preset
// and opening it again never refuses the file.
@(test)
every_preset_has_valid_layers :: proc(t: ^testing.T) {
	for m in MATERIALS do testing.expectf(t, geom.material_layers_valid(m.layers), "%s", m.label)
}

// The shelf sorts every material by its own values, so each preset lands where its look says
// and no category the presets have is empty: metals in Metal, the coated paint and the
// smooth plastics in Glossy, the scattering ones in Skin & wax, cloth in Fabric, the light
// in Glow, and the rough or classic ones in Clay.
@(test)
presets_fall_into_their_categories :: proc(t: ^testing.T) {
	Want :: struct {
		name:     string,
		category: Material_Category,
	}
	wants := [?]Want {
		{"Clay", .Clay}, {"Studio grey", .Clay}, {"PBR clay", .Clay},
		{"Red wax", .Skin}, {"Skin", .Skin}, {"Wax", .Skin}, {"Jade", .Skin},
		{"Gold", .Metal}, {"Chrome", .Metal},
		{"Plastic", .Glossy}, {"Ceramic", .Glossy}, {"Car paint", .Glossy},
		{"Velvet", .Fabric}, {"Satin", .Fabric}, {"Neon", .Glow},
		{"Glass", .Glass}, {"Frosted glass", .Glass},
	}
	for w in wants {
		i, ok := material_by_name(w.name)
		testing.expectf(t, ok, "no preset %s", w.name)
		if ok do testing.expectf(t, material_category(MATERIALS[i]) == w.category, "%s: %v, want %v", w.name, material_category(MATERIALS[i]), w.category)
	}
	for m in MATERIALS[:FIRST_MATCAP] do testing.expect(t, material_category(m) != .Favourites)
}

// Importing Blender's glTF keeps its materials as the objects' own: Car Paint's coat and
// Glass's transmission on their objects, the empty gold listed but left on the default;
// the list survives the scene file.
@(test)
imported_materials_become_the_objects_own :: proc(t: ^testing.T) {
	m, note, _, ok := mesh_import_load(#directory + "testdata/import/materials.glb", "Imported", nil, keep_materials = true)
	defer delete(note)
	defer mesh_import_free(&m)
	testing.expect(t, ok)
	testing.expect_value(t, len(m.materials), 3)
	if len(m.materials) != 3 do return
	objs: [3]Object
	defer for &o in objs {
		delete(o.group_materials)
		imported_materials_destroy(&o.imported)
	}
	unvalued := 0
	for &o, k in objs do unvalued += object_take_imported(&o, m.materials[k][:])
	testing.expect_value(t, unvalued, 1)
	testing.expect_value(t, objs[0].material.layers.coat_weight, 0.25)
	testing.expect_value(t, objs[1].material.layers.transmission_weight, 1)
	testing.expect(t, objs[2].material.label == nil)
	testing.expect_value(t, objs[2].imported[0].name, "Metal - Gold")
	testing.expect(t, !objs[2].imported[0].valued)
	testing.expect(t, strings.contains(note, "\"Metal - Gold\" had no values"))
	// The list round-trips through the scene file's form.
	out: [dynamic]u8
	defer delete(out)
	imported_put(&out, &objs[1])
	r := geom.byte_reader(out[:])
	back: Object
	defer imported_materials_destroy(&back.imported)
	imported_get(&r, &back)
	testing.expect(t, r.ok && r.at == len(out))
	testing.expect_value(t, len(back.imported), 1)
	testing.expect_value(t, back.imported[0].name, "Glass")
	testing.expect_value(t, back.imported[0].group, 0)
	testing.expect(t, back.imported[0].valued)
}

// The Material card's balls keep their atlas cells: the same material shown again finds its
// cell (drawn once), a changed value takes another, and once every cell is taken the one
// shown longest ago is reused and drawn anew.
@(test)
material_balls_keep_their_cells :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	mc := &app.kit.material_card
	defer delete(mc.slots)
	mc.frame = 1
	gold, _ := material_by_name("gold")
	a, drawn := material_ball_slot(app, MATERIALS[gold])
	testing.expect(t, !drawn)
	mc.slots[a].drawn = true
	again, drawn_again := material_ball_slot(app, MATERIALS[gold])
	testing.expect_value(t, again, a)
	testing.expect(t, drawn_again)
	rough := MATERIALS[gold]
	rough.roughness = 0.9
	b, _ := material_ball_slot(app, rough)
	testing.expect(t, b != a)
	// Every other cell taken in later frames: gold, shown in frame 1, goes first.
	for i in 0 ..< len(mc.slots) - 2 {
		mc.frame += 1
		m := MATERIALS[gold]
		m.selected.r = f32(i) / 100
		_, _ = material_ball_slot(app, m)
	}
	mc.frame += 1
	fresh := MATERIALS[gold]
	fresh.metallic = 0.5
	c, drawn_c := material_ball_slot(app, fresh)
	testing.expect_value(t, c, a)
	testing.expect(t, !drawn_c)
}
