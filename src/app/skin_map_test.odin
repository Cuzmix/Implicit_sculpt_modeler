package main

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"

import "../geom"
import "../jobs"
import "../png_write"
import "../sculpt"

// How far the shown skin of `obj` is from `before` at worst, how many of its samples are
// over 0.001 from it, and how far it is from its base at worst.
@(private = "file")
skin_map_spread :: proc(obj: ^Object, before: []geom.Vec3) -> (apart: f32, far: int, lift: f32) {
	shown, rest, ok := sculpt.sculptor_skin_mesh(object_sculptor(obj), context.temp_allocator)
	if !ok do return max(f32), max(int), 0
	for p, i in shown.positions {
		lift = max(lift, linalg.length(p - rest.positions[i]))
		if before != nil do apart = max(apart, linalg.length(p - before[i]))
		if before != nil && linalg.length(p - before[i]) > 0.001 do far += 1
	}
	return
}

// A grey map with the distance its range stands for in a text file beside it goes into a
// quad object's skin; the maps a bake of that skin writes read back to the same skin, the
// height map and the tangent vector map both; each load is one undo step.
@(test)
skin_map_round_trips_through_a_bake :: proc(t: ^testing.T) {
	FOLDER :: "build/skin_map_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	app := new(App)
	defer free(app)
	jobs.pool_init(&app.pool, 2)
	defer jobs.pool_destroy(&app.pool)
	objs := tree_scene(app)
	defer tree_free(app)
	obj := objs[0]
	obj.file = {scale = 1}
	{
		source := geom.icosphere(3)
		defer geom.mesh_destroy(&source)
		bvh := geom.bvh_build(source)
		defer geom.bvh_destroy(&bvh)
		q, _, ok := geom.mesh_retopo(source, &bvh, 600, nil)
		if !testing.expect(t, ok) do return
		uv := geom.quad_uv_unwrap(q, 0.01)
		old_to_new := make([]u32, len(q.positions), context.temp_allocator)
		sculpt.levels_destroy(&obj.levels)
		sculpt.levels_init(&obj.levels, geom.quad_mesh_triangulate(q), nil, 64, old_to_new)
		delete(q.positions)
		for &f in q.quads do for &v in f do v = old_to_new[v]
		sculpt.levels_set_quads(&obj.levels, q.quads)
		sculpt.levels_set_uvs(&obj.levels, uv)
		// The frame loop keeps the normals; here nothing has drawn it yet.
		geom.mesh_recompute_normals(object_sculptor(obj).mesh)
	}
	testing.expect(t, skin_map_refusal(obj) != "", "a map is offered with no skin")
	testing.expect(t, command_run(app, .Detail_Skin, 2))
	testing.expect_value(t, skin_map_refusal(obj), "")

	// Soft waves, 0.02 in and out at their extremes.
	SIDE :: 128
	values := make([]u16, SIDE * SIDE, context.temp_allocator)
	for y in 0 ..< SIDE do for x in 0 ..< SIDE {
		w := 0.5 + 0.45 * math.sin(f32(x) * math.TAU / SIDE * 3) * math.cos(f32(y) * math.TAU / SIDE * 2)
		values[y * SIDE + x] = u16(w * 65535 + 0.5)
	}
	png := png_write.encode_gray16(values, SIDE, SIDE, context.temp_allocator)
	testing.expect(t, os.write_entire_file(FOLDER + "waves.png", png) == nil)
	testing.expect(t, os.write_entire_file(FOLDER + "waves.txt", transmute([]u8)string("0 and 65535 are 0.02 units in and out")) == nil)
	app.skin_map_range = 1
	done := len(app.history.done)
	testing.expect(t, skin_map_load(app, FOLDER + "waves.png"))
	testing.expect_value(t, len(app.history.done), done + 1)
	_, _, lift := skin_map_spread(obj, nil)
	testing.expectf(t, lift > 0.01 && lift < 0.0205, "the waves lift the skin %v, not up to 0.018", lift)
	shown, _, _ := sculpt.sculptor_skin_mesh(object_sculptor(obj), context.temp_allocator)
	before := shown.positions[:]

	// The skin's own bake, read back as each kind of map.
	app.ui.bake = {source = obj.id, size = 512, reach_edges = 0.5, vector = true}
	bake_to_folder(app, FOLDER)
	base, _ := strings.replace_all(object_label(obj), " ", "_", context.temp_allocator)
	maps := [?]struct {
		suffix: string,
		kind:   sculpt.Skin_Map_Kind,
	}{{"_displacement.png", .Height}, {"_vdm.exr", .Tangent_Vector}}
	for m in maps {
		app.skin_map_kind = m.kind
		path := strings.concatenate({FOLDER, base, m.suffix}, context.temp_allocator)
		testing.expectf(t, skin_map_load(app, path), "%s did not load", m.suffix)
		// The waves are read through each chart on its own, so they step across the UV
		// seams; there, a little over a percent of the samples, the bake's texels can only
		// hold that step as a ramp. Everywhere else the skin comes back as it went out.
		apart, far, again := skin_map_spread(obj, before)
		testing.expectf(t, far * 50 < len(before) && apart < 0.3 * again, "%s read back %v away at worst, %d samples over 0.001 (lift %v)", m.suffix, apart, far, again)
	}
	// Undo goes back a map at a time, to the waves.
	history_undo(app)
	history_undo(app)
	apart, _, _ := skin_map_spread(obj, before)
	testing.expectf(t, apart < 1e-6, "undo left the skin %v from the waves", apart)
	// The waves as a micro-map: the right size for the skin's level, every value in it.
	testing.expect(t, skin_bary_export(app, FOLDER + "waves.bary"))
	bary, read_err := os.read_entire_file(FOLDER + "waves.bary", context.temp_allocator)
	testing.expect(t, read_err == nil && len(bary) > 64 && string(bary[1:5]) == "BARY")
	tris := len(object_sculptor(obj).mesh.indices) / 3
	testing.expectf(t, len(bary) > tris * geom.bary_vertex_count(2) * 2, "%d bytes for %d triangles", len(bary), tris)
	// A grey PNG is a height only.
	app.skin_map_kind = .Object_Vector
	testing.expect(t, !skin_map_load(app, FOLDER + "waves.png"), "a PNG loaded as a vector map")
}
