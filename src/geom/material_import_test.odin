package geom

import "core:os"
import "core:testing"

// Blender's glTF of Car Paint, Glass and a gold whose shader a node graph fed: the first two
// come with their values and extensions, read as OpenPBR's layers, the third with its name
// and nothing else.
@(test)
blender_gltf_materials_keep_their_values :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(#directory + "../app/testdata/import/materials.glb", context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	parts: [dynamic]Mesh_Part
	defer mesh_parts_destroy(&parts)
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	_, failed := mesh_read_gltf(&parts, data, look = &look)
	testing.expect_value(t, failed, Mesh_File_Error.None)
	if len(look.materials) != 3 {
		testing.expect_value(t, len(look.materials), 3)
		return
	}
	paint, glass, gold := look.materials[0], look.materials[1], look.materials[2]
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-4}
	testing.expect_value(t, paint.name, "Car Paint")
	testing.expect(t, paint.valued)
	// No baseColorFactor or metallicFactor: glTF's own defaults, white and metal.
	testing.expect_value(t, paint.color, [3]f32{1, 1, 1})
	testing.expect_value(t, paint.metallic, 1)
	testing.expect(t, near(paint.roughness, 0.5))
	testing.expect(t, near(paint.layers.coat_weight, 0.25) && near(paint.layers.coat_roughness, 0.05))
	testing.expect(t, near(paint.layers.specular_ior, 1.45) && near(paint.layers.specular_lessen, 0.16))
	testing.expect_value(t, glass.name, "Glass")
	testing.expect(t, near(glass.color.r, 0.8) && glass.metallic == 0 && near(glass.roughness, 0.05))
	testing.expect(t, glass.layers.transmission_weight == 1 && near(glass.layers.transmission_color.g, 0.8))
	// Solid glass, as Blender reads its own export back, though glTF calls it a thin wall.
	testing.expect_value(t, glass.layers.thin_walled, 0)
	testing.expect(t, near(glass.layers.specular_lessen, 0.8) && near(glass.layers.specular_ior, 1.45))
	testing.expect_value(t, gold.name, "Metal - Gold")
	testing.expect(t, !gold.valued)
	for m in look.materials do testing.expect(t, material_layers_valid(m.layers))
}

// Every layer glTF has an extension for comes back from our own .glb as it went in.
@(test)
glb_material_layers_round_trip :: proc(t: ^testing.T) {
	sphere := icosphere(1)
	defer mesh_destroy(&sphere)
	out := make([dynamic]u8)
	defer delete(out)
	layers := Material_Layers {
		coat_weight = 0.5, coat_roughness = 0.1, specular_ior = 1.6, specular_lessen = 0.3,
		sheen_color = {0.5, 0.25, 1}, sheen_weight = 1, sheen_roughness = 0.4,
		emission_color = {1, 0.5, 0}, emission_luminance = 3,
		transmission_color = {0.9, 0.8, 0.7}, transmission_weight = 0.75, transmission_depth = 0.2,
		thin_film_weight = 0.6, thin_film_thickness = 420, thin_film_ior = 1.3,
	}
	m := Mesh_Export{name = "Sphere", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:]}
	m.material = Export_Material{name = "Layered", base = {0.2, 0.4, 0.6}, metallic = 0.25, roughness = 0.35, layers = layers}
	testing.expect(t, mesh_write_glb(&out, m))
	parts: [dynamic]Mesh_Part
	defer mesh_parts_destroy(&parts)
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	_, failed := mesh_read_gltf(&parts, out[:], look = &look)
	testing.expect_value(t, failed, Mesh_File_Error.None)
	if len(look.materials) != 1 do return
	back := look.materials[0]
	testing.expect_value(t, back.name, "Layered")
	testing.expect(t, back.valued)
	testing.expect_value(t, back.metallic, 0.25)
	testing.expect_value(t, back.roughness, 0.35)
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-5}
	l := back.layers
	testing.expect(t, near(l.coat_weight, 0.5) && near(l.coat_roughness, 0.1) && near(l.specular_ior, 1.6) && near(l.specular_lessen, 0.3))
	testing.expect(t, near(l.sheen_color.b, 1) && l.sheen_weight == 1 && near(l.sheen_roughness, 0.4))
	testing.expect(t, l.emission_color == {1, 0.5, 0} && near(l.emission_luminance, 3))
	testing.expect(t, near(l.transmission_weight, 0.75) && near(l.transmission_depth, 0.2) && near(l.transmission_color.b, 0.7))
	testing.expect(t, near(l.thin_film_weight, 0.6) && near(l.thin_film_thickness, 420) && near(l.thin_film_ior, 1.3))
}

// A part's materials become polygroups numbered by first use; one material is the part's
// own; past PART_MATERIALS_MAX each merges into the nearest kept one.
@(test)
materials_become_polygroups :: proc(t: ^testing.T) {
	look: Mesh_Look
	defer mesh_look_destroy(&look)
	for k in 0 ..< PART_MATERIALS_MAX + 2 {
		v := f32(k) / f32(PART_MATERIALS_MAX + 2)
		append(&look.materials, Mesh_Material{color = {v, v, v}, image = -1, valued = true})
	}
	parts := make([]Mesh_Part, 2)
	defer {
		for &p in parts do mesh_part_destroy(&p)
		delete(parts)
	}
	// Part 0: materials 3, 3, 1, -1, then every one in turn; part 1: material 5 alone.
	append(&parts[0].materials, 3, 3, 1, -1)
	for k in 0 ..< PART_MATERIALS_MAX + 2 do append(&parts[0].materials, i32(k))
	append(&parts[1].materials, 5, 5)
	lists, merged := mesh_parts_material_groups(parts, &look)
	defer part_materials_destroy(lists)
	testing.expect_value(t, len(lists[0]), PART_MATERIALS_MAX)
	testing.expect_value(t, merged, 2)
	testing.expect_value(t, parts[0].groups[0], 1) // material 3 named first
	testing.expect_value(t, parts[0].groups[2], 2) // then material 1
	testing.expect_value(t, parts[0].groups[3], 0) // none
	testing.expect_value(t, lists[0][0].material.color, look.materials[3].color)
	// The last two merge into the nearest kept, the brightest kept one.
	testing.expect_value(t, parts[0].groups[len(parts[0].groups) - 1], parts[0].groups[len(parts[0].groups) - 3])
	testing.expect_value(t, len(lists[1]), 1)
	testing.expect_value(t, lists[1][0].group, 0)
	testing.expect_value(t, len(parts[1].groups), 0)
}
