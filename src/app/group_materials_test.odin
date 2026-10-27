package main

import "core:math"
import "core:testing"

import "../geom"
import "../render"
import "../sculpt"

@(private = "file")
gold :: proc() -> Material {i, _ := material_by_name("gold"); return MATERIALS[i]}
@(private = "file")
steel :: proc() -> Material {i, _ := material_by_name("steel"); return MATERIALS[i]}

// A group takes a lit material, kept in group order; group 0 (the object's own), a MatCap
// and a sixteenth group are refused; clearing gives the group the object's back.
@(test)
groups_take_materials_of_their_own :: proc(t: ^testing.T) {
	obj: Object
	defer delete(obj.group_materials)
	testing.expect_value(t, group_material_set(&obj, 7, gold()), "")
	testing.expect_value(t, group_material_set(&obj, 2, steel()), "")
	testing.expect_value(t, group_material_set(&obj, 7, steel()), "")
	testing.expect_value(t, len(obj.group_materials), 2)
	testing.expect_value(t, obj.group_materials[0].group, u16(2))
	testing.expect_value(t, obj.group_materials[1], Group_Material{7, steel()})
	testing.expect(t, group_material_set(&obj, 0, gold()) != "")
	testing.expect(t, group_material_set(&obj, 3, MATERIALS[FIRST_MATCAP]) != "")
	for g in 10 ..< 23 do testing.expect_value(t, group_material_set(&obj, u16(g), gold()), "")
	testing.expect_value(t, len(obj.group_materials), GROUP_MATERIALS_MAX)
	testing.expect(t, group_material_set(&obj, 40, gold()) != "")
	testing.expect_value(t, group_material_set(&obj, 2, {}, clear = true), "")
	testing.expect_value(t, obj.group_materials[0].group, u16(7))
	// A custom one with no label is Custom, opaque.
	testing.expect_value(t, group_material_set(&obj, 2, {selected = {0.1, 0.2, 0.3, 0}}), "")
	testing.expect(t, obj.group_materials[0].material.label == "Custom" && obj.group_materials[0].material.selected.a == 1)
}

// After a group command each entry follows most of its triangles: renumbered groups keep
// their materials, a group cleared to 0 or emptied loses its own, and two entries landing
// on one group keep the first.
@(test)
group_materials_follow_their_triangles :: proc(t: ^testing.T) {
	table := []Group_Material{{1, gold()}, {2, steel()}, {9, gold()}}
	// Creases renumbered 1 -> 4 and 2 -> 0 (cleared); 9 has no triangles.
	before := []u16{1, 1, 1, 2, 2, 3}
	after := []u16{4, 4, 5, 0, 0, 6}
	out := group_materials_follow(table, before, after)
	defer delete(out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], Group_Material{4, gold()})
	// Most of group 1 went to 8; the rest stayed. Group 2 also went to 8, after 1 got it.
	after2 := []u16{8, 8, 1, 8, 8, 3}
	out2 := group_materials_follow(table, before, after2)
	defer delete(out2)
	testing.expect_value(t, len(out2), 1)
	testing.expect_value(t, out2[0], Group_Material{8, gold()})
	// A tie goes to the lower number, whatever the map's order.
	out3 := group_materials_follow(table[:1], []u16{1, 1}, []u16{6, 5})
	defer delete(out3)
	testing.expect_value(t, out3[0].group, u16(5))
}

// The table goes into the scene file after the material and comes back as it was; a
// table with group 0, out of order, a MatCap, no label or too many entries is damage.
@(test)
group_materials_round_trip_and_refuse_damage :: proc(t: ^testing.T) {
	obj: Object
	defer delete(obj.group_materials)
	_ = group_material_set(&obj, 3, gold())
	_ = group_material_set(&obj, 12, {label = "Custom", selected = {0.2, 0.4, 0.6, 1}, idle = {0.3, 0.3, 0.3, 1}, roughness = 0.5})
	out: [dynamic]u8
	defer delete(out)
	group_materials_put(&out, &obj)
	back: Object
	defer delete(back.group_materials)
	r := geom.byte_reader(out[:])
	group_materials_get(&r, &back)
	testing.expect(t, r.ok && r.at == len(out))
	testing.expect_value(t, len(back.group_materials), 2)
	for e, i in back.group_materials do testing.expect_value(t, e, obj.group_materials[i])

	write :: proc(out: ^[dynamic]u8, entries: []Group_Material) {
		clear(out)
		geom.byte_put(out, u16(len(entries)))
		for e in entries {
			geom.byte_put(out, e.group)
			material_put(out, e.material)
		}
	}
	bad := [?][]Group_Material {
		{{0, gold()}},
		{{4, gold()}, {4, steel()}},
		{{5, gold()}, {2, steel()}},
		{{1, MATERIALS[FIRST_MATCAP]}},
		{{1, {}}},
	}
	for entries, i in bad {
		write(&out, entries)
		damaged: Object
		r = geom.byte_reader(out[:])
		group_materials_get(&r, &damaged)
		testing.expectf(t, !r.ok, "case %d read", i)
		delete(damaged.group_materials)
	}
	clear(&out)
	geom.byte_put(&out, u16(GROUP_MATERIALS_MAX + 1))
	r = geom.byte_reader(out[:])
	group_materials_get(&r, &back)
	testing.expect(t, !r.ok)
}

// The draw slots: slot k + 1 for the k-th entry, its group and its material's colour as
// the object's own is tinted (muted when another object is selected), the others unused.
@(test)
group_materials_fill_the_draw_slots :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	testing.expect(t, object_material_slots(&app, objs[0], 0) == nil)
	_ = group_material_set(objs[1], 3, gold())
	_ = group_material_set(objs[1], 8, steel())
	app.dim_others = true
	slots := object_material_slots(&app, objs[1], 1)
	testing.expect(t, slots != nil)
	if slots == nil do return
	testing.expect_value(t, slots.groups[0], render.SLOT_NONE)
	testing.expect_value(t, slots.groups[1], u32(3))
	testing.expect_value(t, slots.groups[2], u32(8))
	testing.expect_value(t, slots.groups[3], render.SLOT_NONE)
	testing.expect_value(t, slots.uniforms.color[1], gold().idle)
	testing.expect_value(t, slots.uniforms.surface[2], [4]f32{steel().metallic, steel().roughness, 0, 0})
	app.scene.selected = 1
	slots = object_material_slots(&app, objs[1], 1)
	testing.expect_value(t, slots.uniforms.color[1], gold().selected)
}

// A group command that moves the groups moves the table in the same undo step: Creases
// on a smooth sphere makes one group 0, which drops group 1's material; undo brings both
// back, and redo takes them again.
@(test)
undo_brings_a_group_commands_table_back :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	app.ui.crease_degrees = sculpt.CREASE_GROUP_DEGREES
	group_command(&app, .Visible)
	s := object_sculptor(objs[0])
	testing.expect(t, sculpt.sculptor_has_groups(s))
	g := sculpt.sculptor_groups(s)[0]
	testing.expect(t, g != 0)
	_ = group_material_set(objs[0], g, gold())
	group_command(&app, .Creases)
	testing.expect_value(t, len(objs[0].group_materials), 0)
	history_undo(&app)
	testing.expect_value(t, sculpt.sculptor_groups(s)[0], g)
	testing.expect_value(t, len(objs[0].group_materials), 1)
	testing.expect_value(t, objs[0].group_materials[0], Group_Material{g, gold()})
	history_redo(&app)
	testing.expect_value(t, len(objs[0].group_materials), 0)
}

// A merge renumbers each object's groups, and the table with them: the first object's
// own entries move to their new numbers, and the second object's groups take its
// material (or their own), so every part looks as it did.
@(test)
a_merge_keeps_each_parts_material :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	// The first sphere's lower half a group with gold, the second all steel.
	s := object_sculptor(objs[0])
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	for p, v in s.mesh.positions do if p.y > 0 do s.mask[v] = 0
	testing.expect(t, sculpt.sculptor_group_command(s, .Masked))
	lower := u16(0)
	for g in sculpt.sculptor_groups(s) do lower = max(lower, g)
	_ = group_material_set(objs[0], lower, gold())
	objs[0].material = MATERIALS[0]
	objs[1].material = steel()
	pair := [2]^Object{objs[0], objs[1]}
	table: [dynamic]Group_Material
	defer delete(table)
	mesh, surface, ok := merge_meshes(pair[:], objs[0].transform, &table)
	testing.expect(t, ok)
	defer {
		geom.mesh_destroy(&mesh)
		delete(surface.groups)
		delete(surface.color)
	}
	// Groups: the first sphere's two (1 and 2, by first triangle, from 1 since it has a
	// group material), then the second's one (3).
	testing.expect_value(t, len(table), 2)
	if len(table) < 2 do return
	testing.expect_value(t, table[0].material, gold())
	testing.expect(t, table[0].group == 1 || table[0].group == 2)
	testing.expect_value(t, table[1], Group_Material{3, steel()})
	// The gold entry's group holds the triangles that were the lower half.
	for e in table do if e.material == gold() {
		n := 0
		for g in surface.groups do n += int(g == e.group)
		before := 0
		for g in sculpt.sculptor_groups(s) do before += int(g == lower)
		testing.expect_value(t, n, before)
	}
}

// An export gives each face its group's slot; with paint the colours are the paint over
// each face's own material and the materials go white: for glTF the seam vertices are
// copied so each side keeps its colour, for USD a colour goes on each face corner.
@(test)
exports_paint_over_each_faces_material :: proc(t: ^testing.T) {
	app: App
	obj: Object
	defer delete(obj.group_materials)
	obj.material = steel()
	_ = group_material_set(&obj, 5, gold())
	positions := []geom.Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
	normals := []geom.Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}}
	indices := []u32{0, 1, 2, 0, 2, 3}
	groups := []u16{2, 5}
	// Clear paint but on vertex 3, which is fully red.
	paint := []sculpt.Color{{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {255, 0, 0, 255}}
	defer free_all(context.temp_allocator)
	under := proc(m: Material) -> (c: [3]u8) {
		base := export_material(m).base
		for k in 0 ..< 3 do c[k] = u8(math.round(srgb_encode(base[k]) * 255))
		return
	}
	m := geom.Mesh_Export{positions = positions, normals = normals, indices = indices, material = export_material(steel())}
	export_group_materials(&app, &obj, &m, groups, nil, true)
	testing.expect_value(t, len(m.group_materials), 1)
	testing.expect_value(t, m.face_material[0], u8(0))
	testing.expect_value(t, m.face_material[1], u8(1))
	testing.expect_value(t, m.group_materials[0].base, export_material(gold()).base)
	testing.expect(t, m.colors == nil && len(m.positions) == 4)
	glb := geom.Mesh_Export{positions = positions, normals = normals, indices = indices, material = export_material(steel())}
	export_group_materials(&app, &obj, &glb, groups, paint, true)
	// Vertices 0 and 2 are copied for the gold triangle.
	testing.expect_value(t, len(glb.positions), 6)
	testing.expect_value(t, glb.group_materials[0].base, [3]f32{1, 1, 1})
	testing.expect_value(t, glb.colors[0], under(steel()))
	testing.expect_value(t, glb.colors[4], under(gold()))
	testing.expect_value(t, glb.colors[3], [3]u8{255, 0, 0})
	usd := geom.Mesh_Export{positions = positions, normals = normals, indices = indices, material = export_material(steel())}
	export_group_materials(&app, &obj, &usd, groups, paint, false)
	testing.expect(t, usd.corner_colors)
	testing.expect_value(t, len(usd.colors), 6)
	testing.expect_value(t, len(usd.positions), 4)
	testing.expect_value(t, usd.colors[2], under(steel()))
	testing.expect_value(t, usd.colors[4], under(gold()))
	testing.expect_value(t, usd.colors[5], [3]u8{255, 0, 0})
	// No face in a group with a material leaves the export as it was.
	none := geom.Mesh_Export{positions = positions, normals = normals, indices = indices}
	export_group_materials(&app, &obj, &none, []u16{1, 2}, paint, true)
	testing.expect(t, none.face_material == nil && none.colors == nil)
}
