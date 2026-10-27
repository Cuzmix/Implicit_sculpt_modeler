package main

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../png_write"
import "../render"
import "../sculpt"

// A small quad object with UVs, as Retopologize makes one, in place of tree_scene's
// first sphere (freed by tree_free).
@(private = "file")
quad_object :: proc(t: ^testing.T, obj: ^Object) -> bool {
	source := geom.icosphere(3)
	defer geom.mesh_destroy(&source)
	bvh := geom.bvh_build(source)
	defer geom.bvh_destroy(&bvh)
	q, _, ok := geom.mesh_retopo(source, &bvh, 300, nil)
	if !testing.expect(t, ok) do return false
	uv := geom.quad_uv_unwrap(q, 0.01)
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	sculpt.levels_destroy(&obj.levels)
	sculpt.levels_init(&obj.levels, geom.quad_mesh_triangulate(q), nil, 64, old_to_new)
	delete(q.positions)
	for &f in q.quads do for &v in f do v = old_to_new[v]
	sculpt.levels_set_quads(&obj.levels, q.quads)
	sculpt.levels_set_uvs(&obj.levels, uv)
	return true
}

// A tiny PNG of one colour.
@(private = "file")
png_of :: proc(c: [4]u8, side := 4) -> []u8 {
	c := c
	pixels := make([]u8, side * side * 4, context.temp_allocator)
	for i in 0 ..< side * side do copy(pixels[4 * i:], c[:])
	return png_write.encode(pixels, side, side, false)
}

// The preview's vertices are the bake's split mesh: one a (vertex, chart) slot, its
// tangent through SHORT4_NORM within rounding, its vertex's mask in the normal's low bits,
// and the triangles split along the base level's own diagonals.
@(test)
textured_vertices_follow_the_split :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	if !quad_object(t, obj) do return
	s := &sculpt.levels_current(&obj.levels).sculptor
	s.mask = make([]u8, len(s.mesh.positions))
	for &m, v in s.mask do m = u8(v * 37 % 256)
	vertices, indices := textured_vertices(obj)
	quads := sculpt.levels_quad_mesh(&obj.levels)
	normals := geom.quad_mesh_normals(quads, context.temp_allocator)
	frame := geom.quad_mesh_tangents(quads, obj.levels.faces.uv, normals, context.temp_allocator)
	testing.expect_value(t, len(vertices), len(frame.vertex))
	testing.expect_value(t, len(indices), 6 * len(quads.quads))
	for v, slot in vertices {
		want := frame.tangents[slot]
		got := [4]f32{f32(v.tangent.x), f32(v.tangent.y), f32(v.tangent.z), f32(v.tangent.w)} / 32767
		testing.expectf(t, linalg.length(got - want) < 1e-4, "slot %d: tangent %v, wanted %v", slot, got, want)
		mask := u8((v.normal.x & 15) << 4 | (v.normal.y & 15))
		testing.expect_value(t, mask, s.mask[frame.vertex[slot]])
		testing.expect(t, v.position == quads.positions[frame.vertex[slot]])
	}
	// Each triangle is one of the base level's, corner for corner.
	base := sculpt.levels_current(&obj.levels).mesh.indices[:]
	found := make(map[[3]u32]bool, len(base) / 3, context.temp_allocator)
	for i := 0; i < len(base); i += 3 do found[{base[i], base[i + 1], base[i + 2]}] = true
	for i := 0; i < len(indices); i += 3 {
		tri := [3]u32{frame.vertex[indices[i]], frame.vertex[indices[i + 1]], frame.vertex[indices[i + 2]]}
		rolled := [3][3]u32{tri, {tri[1], tri[2], tri[0]}, {tri[2], tri[0], tri[1]}}
		testing.expectf(t, found[rolled[0]] || found[rolled[1]] || found[rolled[2]], "triangle %v is not the base level's", tri)
	}
	free_all(context.temp_allocator)
}

// The scene file keeps the maps byte for byte and refuses damaged ones; a file of version
// 16 has none.
@(test)
scene_keeps_textures :: proc(t: ^testing.T) {
	maps: Object_Textures
	maps.image[.Base_Color] = png_of({200, 30, 20, 255})
	maps.image[.Normal] = png_of({128, 128, 255, 255}, 8)
	defer textures_free(&maps)
	out: [dynamic]u8
	defer delete(out)
	textures_put(&out, maps)
	r := geom.byte_reader(out[:])
	back := textures_get(&r)
	defer textures_free(&back)
	testing.expect(t, r.ok && r.at == len(out))
	for m in render.Texture_Map do testing.expect_value(t, string(back.image[m]), string(maps.image[m]))
	testing.expect(t, back.stamp != 0, "read maps must be new to the preview")
	none: [dynamic]u8
	defer delete(none)
	textures_put(&none, {})
	r = geom.byte_reader(none[:])
	testing.expect(t, textures_get(&r).stamp == 0 && r.ok, "no maps, nothing to decode")

	// A bit past the maps, a count past the end, and bytes that are no image.
	for damage in 0 ..< 3 {
		bad := make([dynamic]u8, len(out), context.temp_allocator)
		copy(bad[:], out[:])
		switch damage {
		case 0: bad[0] = 1 << 3
		case 1: bad[1] = 0xff; bad[2] = 0xff
		case 2: bad[5] ~= 0xff // inside the first PNG's signature
		}
		r = geom.byte_reader(bad[:])
		got := textures_get(&r)
		testing.expectf(t, !r.ok, "damage %d was read", damage)
		for img in got.image do testing.expect(t, img == nil, "damaged maps must be freed")
	}
	free_all(context.temp_allocator)
}

// Baking (textures_replace) and New UVs are undo steps of their own: undo puts the maps
// and the layout back and redo takes them again, while the object's strokes stay; the
// maps go when the UVs do.
@(test)
textures_undo_and_redo :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	defer textures_free(&obj.textures)
	if !quad_object(t, obj) do return
	baked: Object_Textures
	baked.image[.Normal] = png_of({128, 128, 255, 255})
	textures_replace(&app, obj, baked, "bake maps")
	testing.expect(t, object_has_textures(obj))
	stamp := obj.textures.stamp
	layout := raw_data(obj.levels.faces.uv.uvs)
	counter := obj.textures.layout
	testing.expect_value(t, counter, 0)

	object_layout_uvs(&app, obj)
	testing.expect(t, !object_has_textures(obj), "New UVs keeps maps made on the old layout")
	testing.expect(t, raw_data(obj.levels.faces.uv.uvs) != layout)
	testing.expect(t, obj.textures.layout != counter, "the preview must see the new layout")
	counter = obj.textures.layout
	testing.expect_value(t, len(app.history.done), 2)
	testing.expect_value(t, app.history.done[1].kind, History_Kind.Textures)

	history_undo(&app)
	testing.expect(t, object_has_textures(obj) && raw_data(obj.levels.faces.uv.uvs) == layout, "undo of New UVs brings both back")
	testing.expect(t, obj.textures.stamp != stamp, "the preview must see the change")
	testing.expect(t, obj.textures.layout != counter, "nor may it miss the old layout coming back")
	history_undo(&app)
	testing.expect(t, !object_has_textures(obj))
	history_redo(&app)
	history_redo(&app)
	testing.expect(t, !object_has_textures(obj) && raw_data(obj.levels.faces.uv.uvs) != layout)
	testing.expect(t, app.history.swap_bytes > 0, "texture steps count toward the memory limit")

	// Maps never outlive their UVs.
	history_undo(&app)
	sculpt.levels_drop_quads(&obj.levels)
	textures_settle(&app)
	testing.expect(t, !object_has_textures(obj))
	free_all(context.temp_allocator)
}

// The preview draws only what it can show: off, other levels, hidden parts, polygroup
// colours, a stroke on the object, and a view with nothing to show draw as clay.
@(test)
object_textured_only_when_it_can :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	lv := sculpt.levels_current(&obj.levels)
	app.texture_view = .Uv_Checker
	testing.expect(t, !object_textured(&app, obj, lv), "a sphere has no UVs")
	if !quad_object(t, obj) do return
	lv = sculpt.levels_current(&obj.levels)
	testing.expect(t, object_textured(&app, obj, lv))
	app.texture_view = .Off
	testing.expect(t, !object_textured(&app, obj, lv))
	app.texture_view = .Textured
	testing.expect(t, !object_textured(&app, obj, lv), "no maps on the GPU yet")
	app.texture_view = .Uv_Checker
	app.show_groups = true
	testing.expect(t, !object_textured(&app, obj, lv))
	app.show_groups = false
	app.stroke = {active = true, object = obj.id}
	testing.expect(t, !object_textured(&app, obj, lv))
	app.stroke = {}
	testing.expect(t, sculpt.levels_subdivide(&obj.levels))
	testing.expect(t, !object_textured(&app, obj, sculpt.levels_current(&obj.levels)), "only the base level has the UVs")
	free_all(context.temp_allocator)
}

// A big map is halved by 2 x 2 averages until it fits the preview.
@(test)
maps_halve_to_the_preview_size :: proc(t: ^testing.T) {
	pixels := make([]u8, 6 * 4 * 4)
	for i in 0 ..< 24 do pixels[4 * i] = u8(10 * i)
	half, size := texture_halve_to(pixels, 6, 4, 3)
	testing.expect_value(t, size, [2]int{3, 2})
	// The first 2 x 2 block's red: (0 + 10 + 60 + 70 + 2) / 4.
	testing.expect_value(t, half[0], u8(35))
	out, small := texture_halve_to(half, 3, 2, 1)
	defer delete(out)
	testing.expect_value(t, small, [2]int{1, 1})
	same, kept := texture_halve_to(out, 1, 1, 2)
	testing.expect(t, raw_data(same) == raw_data(out) && kept == [2]int{1, 1})
}
