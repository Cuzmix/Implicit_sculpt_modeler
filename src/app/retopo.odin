package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../geom"
import "../png_write"
import "../sculpt"
import "../ui"

// Retopology and baking on the app side: Retopologize makes a new object of quads from
// the selected one (geom.mesh_retopo), with UVs laid out (geom.quad_uv_unwrap), next to
// it; Bake maps... then bakes another object's detail into normal and displacement maps
// on it (geom.bake_maps) and writes them to a folder with the quads as OBJ. Both work in
// the objects' own spaces, so moving or turning either object changes nothing.

// UV padding around each chart, in texels of the largest map size, so even a 4096 map
// keeps charts apart when filtered.
UV_PADDING :: f32(8.0 / 4096)

BAKE_SIZES := [?]i32{512, 1024, 2048, 4096}

Bake_Settings :: struct {
	source:      int, // id of the object to bake from; 0 picks the one the quads came from
	size:        i32, // texels square
	reach_edges: f32, // how far rays look, in the quads' average edge length
}

// The mesh to read the object's shape from: its top level (with the edits on any level
// carried up), or a packed copy when dynamic. Normals are computed fresh into `normals`
// (its own allocation, which the caller frees, along with `packed`).
object_shape :: proc(obj: ^Object, top: bool) -> (view: geom.Mesh, packed: geom.Mesh) {
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		view = packed
	} else {
		sculpt.levels_sync(&obj.levels)
		lv := obj.levels.levels[len(obj.levels.levels) - 1] if top else sculpt.levels_current(&obj.levels)
		// A view of the level's arrays, with normals of its own.
		view = geom.Mesh{positions = lv.mesh.positions, indices = lv.mesh.indices}
	}
	view.normals = make([dynamic]geom.Vec3, len(view.positions))
	geom.mesh_recompute_normals(&view)
	return
}

// Makes a new object of about `quads` quads on the shape of the level the selected
// object is on, with UVs, next to it, and selects it. Returns false only on a GPU failure.
object_retopo :: proc(app: ^App, obj: ^Object, quads: int) -> (made, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	view, packed := object_shape(obj, top = false)
	defer {
		delete(view.normals)
		geom.mesh_destroy(&packed)
	}
	bvh := geom.bvh_build_morton(view, geom.BVH_LEAF_SIZE, &app.pool)
	defer geom.bvh_destroy(&bvh)
	q, how, built := geom.mesh_retopo(view, &bvh, quads, &app.pool)
	free_all(context.temp_allocator)
	if !built {
		log.warnf("retopologize: %s has too few triangles for %d quads", object_label(obj), quads)
		return false, true
	}
	retopo_ms := time.duration_milliseconds(time.tick_since(start))
	uv_start := time.tick_now()
	uv := geom.quad_uv_unwrap(q, UV_PADDING)
	uv_ms := time.duration_milliseconds(time.tick_since(uv_start))

	mesh := geom.quad_mesh_triangulate(q)
	old_to_new := make([]u32, len(q.positions))
	defer delete(old_to_new)
	delete(q.positions)
	// Not in temp memory, which building frees.
	name := fmt.aprintf("%s retopo", object_label(obj))
	defer delete(name)
	t := obj.transform
	t.position = next_free_position(app)
	if !scene_add_mesh(app, mesh, name, obj.file, t, start, old_to_new) {
		delete(q.quads)
		geom.uv_layout_destroy(&uv)
		return false, false
	}
	twin := selected_object(app)
	for &f in q.quads do for &v in f do v = old_to_new[v]
	sculpt.levels_set_quads(&twin.levels, q.quads)
	sculpt.levels_set_uvs(&twin.levels, uv)
	app.ui.bake.source = obj.id
	report(app, Kit_Section.Retopo, {}, "Retopologized %s: %s quads, UVs in %d charts, %.0f ms", object_label(obj), thousands(len(q.quads)), uv.charts, retopo_ms + uv_ms)
	log.infof("retopologize: decimated to %d triangles, %d paired; %d vertices not put back; UVs fill %.0f%% in %.0f ms", how.decimated, how.paired, how.unprojected, 100 * uv.filled, uv_ms)
	return true, true
}

// Lays the selected quad object's UVs out again, for when its shape changed a lot since.
object_layout_uvs :: proc(app: ^App, obj: ^Object) {
	if !sculpt.levels_has_quads(&obj.levels) do return
	sculpt.levels_sync(&obj.levels)
	uv := geom.quad_uv_unwrap(sculpt.levels_quad_mesh(&obj.levels), UV_PADDING)
	sculpt.levels_set_uvs(&obj.levels, uv)
	app.scene_edits += 1
	log.infof("UVs: %d charts filling %.0f%%", uv.charts, 100 * uv.filled)
}

// The object Bake maps... reads the detail from: the one chosen, else the one the
// quads came from, else none.
bake_source :: proc(app: ^App, low: ^Object) -> ^Object {
	src := object_by_id(app, app.ui.bake.source)
	return src if src != low else nil
}

// Bakes the bake source's detail onto the selected quad object and writes, into
// `folder`, NAME_normal.png (tangent space, OpenGL's green up), NAME_displacement.png
// (16-bit grey, 32768 for none), NAME_displacement.txt (the distance the full range
// stands for) and NAME.obj (the quads with their UVs), NAME being the object's.
bake_to_folder :: proc(app: ^App, folder: string) {
	low := selected_object(app)
	if low == nil || !sculpt.levels_has_uvs(&low.levels) {
		file_note(app, true, "Bake: select an object made by Retopologize first")
		return
	}
	src := bake_source(app, low)
	if src == nil {
		file_note(app, true, "Bake: choose the object to bake from")
		return
	}
	stroke_finish(app)
	object_hd_leave(app, low)
	object_hd_leave(app, src)
	start := time.tick_now()
	view, packed := object_shape(src, top = true)
	defer {
		delete(view.normals)
		geom.mesh_destroy(&packed)
	}
	bvh := geom.bvh_build_morton(view, geom.BVH_LEAF_SIZE, &app.pool)
	defer geom.bvh_destroy(&bvh)
	sculpt.levels_sync(&low.levels)
	quads := sculpt.levels_quad_mesh(&low.levels)
	edge: f32
	for f in quads.quads do for k in 0 ..< 4 do edge += linalg.length(quads.positions[f[(k + 1) % 4]] - quads.positions[f[k]])
	edge /= f32(max(4 * len(quads.quads), 1))
	size := int(app.ui.bake.size)
	maps := geom.bake_maps(quads, low.levels.faces.uv, view, &bvh, size, app.ui.bake.reach_edges * edge, &app.pool)
	defer geom.bake_maps_destroy(&maps)
	baked_ms := time.duration_milliseconds(time.tick_since(start))

	base, _ := strings.replace_all(object_label(low), " ", "_", context.temp_allocator)
	path :: proc(folder, base, suffix: string) -> string {
		joined, _ := filepath.join({folder, strings.concatenate({base, suffix}, context.temp_allocator)}, context.temp_allocator)
		return joined
	}
	normal_png := png_write.encode(maps.normal, size, size, false)
	defer delete(normal_png)
	samples := geom.bake_displacement_samples(maps)
	defer delete(samples)
	disp_png := png_write.encode_gray16(samples, size, size)
	defer delete(disp_png)
	obj_text := make([dynamic]u8)
	defer delete(obj_text)
	geom.quad_mesh_write_obj(&obj_text, quads.positions, quads.quads, low.levels.faces.uv.uvs, low.file.scale, low.file.position)
	full := maps.max_displacement * low.file.scale
	note := fmt.tprintf("Displacement %s_displacement.png: 16-bit grey, 32768 is the surface of %s.obj, 0 and 65535 are %v units in and out along its normal (in the OBJ's units).\n", base, base, full)
	if !write_file_safely(app, path(folder, base, "_normal.png"), normal_png, "bake") do return
	if !write_file_safely(app, path(folder, base, "_displacement.png"), disp_png, "bake") do return
	if !write_file_safely(app, path(folder, base, "_displacement.txt"), transmute([]u8)note, "bake") do return
	if !write_file_safely(app, path(folder, base, ".obj"), obj_text[:], "bake") do return
	share := 100 * f64(maps.hit) / f64(max(maps.covered, 1))
	report(app, Kit_Section.Retopo, {.Warning} if share < 99 else {}, "Baked %s from %s at %d x %d in %.0f ms: %.1f%% of texels found the surface, displacement up to %.4g; %s_normal.png, _displacement.png and .obj written",
		object_label(low), object_label(src), size, size, baked_ms, share, full, base)
}

// The interface's UVs and baking section: Retopologize itself is Shape > Rebuild's Quads.
kit_retopo_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	kit_last_result(app, .Retopo)
	if obj == nil || !sculpt.levels_has_uvs(&obj.levels) {
		ui.paragraph(ctx, "Bakes onto an object with UVs: make one with Shape > Rebuild > Quads, then select it here.")
		return
	}
	src := bake_source(app, obj)
	names := make([dynamic]string, context.temp_allocator)
	ids := make([dynamic]int, context.temp_allocator)
	append(&names, "Choose the source")
	append(&ids, 0)
	chosen := 0
	for other in app.scene.objects {
		if other == obj do continue
		if other == src do chosen = len(names)
		append(&names, fmt.tprintf("Bake from %s##%d", object_label(other), other.id))
		append(&ids, other.id)
	}
	if picked := ui.select(ctx, "bake from", names[:], chosen); picked >= 0 do app.ui.bake.source = ids[picked]
	bake, uvs := kit_button_pair(ctx, "Bake maps...", "New UVs")
	if bake do file_dialog(app, .Bake)
	if uvs do object_layout_uvs(app, obj)
	ui.paragraph(ctx, "Bakes the source's detail (its top level) into normal and displacement maps on this object's UVs, and writes them with the quads as OBJ into a folder.")
	if kit_more(app, .Retopo) {
		sizes: [len(BAKE_SIZES)]string
		size := -1
		for s, i in BAKE_SIZES {
			sizes[i] = fmt.tprintf("%d", s)
			if s == app.ui.bake.size do size = i
		}
		if picked := ui.tabs(ctx, "bake size", sizes[:], size); picked >= 0 do app.ui.bake.size = BAKE_SIZES[picked]
		_ = ui.slider(ctx, "Reach", &app.ui.bake.reach_edges, 0.5, 10, .Linear, fmt.tprintf("%.1f edges", app.ui.bake.reach_edges))
		ui.paragraph(ctx, "The maps' size in texels, and Reach: how far each texel looks either way.")
		kit_more_end(app)
	}
}
