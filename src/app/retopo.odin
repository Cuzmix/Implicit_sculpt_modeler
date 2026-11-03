package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "../geom"
import "../hdri"
import "../render"
import "../png_write"
import "../sculpt"
import "../ui"
import "../retopo"

// Retopology and baking on the app side: Quad Remesh makes a new object of quads from
// the selected one (quadmesh.remesh, or geom.mesh_retopo), with UVs laid out
// (geom.quad_uv_unwrap), next to it; Bake maps... then bakes another object's detail into normal and displacement maps
// on it (geom.bake_maps) and writes them to a folder with the quads as OBJ. Both work in
// the objects' own spaces, so moving or turning either object changes nothing.

BAKE_SIZES := [?]i32{512, 1024, 2048, 4096}

Bake_Settings :: struct {
	source:          int, // id of the object to bake from; 0 picks the one the quads came from
	size:            i32, // texels square
	reach_edges:     f32, // how far rays look, in the quads' average edge length
	// The bake set's maps beyond normal and displacement (geom.Bake_Kind).
	base_color:      bool,
	orm:             bool,
	id:              bool,
	occlusion_rays:  i32, // per texel, 0 for none
	occlusion_reach: f32, // as a share of the source's size (its bounds' diagonal)
	vector:          bool, // a vector displacement map, NAME_vdm.exr
	object_space:    bool, // normal and vector maps in the object's axes, not the tangent frame
	target:          Bake_Target, // the program the maps are for
}

// The programs the maps are laid out for: Unreal reads a normal map with DirectX's green
// (down), the rest with OpenGL's (up); all four read MikkTSpace tangents, and Blender's
// layout (x, y and z in red, green and blue) for a vector map.
Bake_Target :: enum u8 {
	Blender,
	Unity,
	Unreal,
	Godot,
}

BAKE_TARGET_NAMES := [Bake_Target]string {
	.Blender = "Blender",
	.Unity   = "Unity",
	.Unreal  = "Unreal",
	.Godot   = "Godot",
}

BAKE_OCCLUSION_RAYS_MAX :: 64

// The mesh to read the object's shape from: its top level (with the edits on any level
// carried up), or a packed copy when dynamic. Normals are computed fresh into `normals`
// (its own allocation, which the caller frees, along with `packed`). With `mask`, a
// dynamic object's mask in the packed copy's order goes there for the caller to free
// (nil when it has none; a level's own mask is the sculptor's, in the level's order).
object_shape :: proc(obj: ^Object, top: bool, mask: ^[]u8 = nil) -> (view: geom.Mesh, packed: geom.Mesh) {
	if object_dynamic(obj) {
		packed_mask: []u8
		packed, packed_mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		if mask != nil && sculpt.sculptor_has_mask(object_sculptor(obj)) do mask^ = packed_mask
		else do delete(packed_mask)
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

// The options as the Rebuild section has them set.
quad_options :: proc(app: ^App) -> retopo.Options {
	mirror := symmetry_planes(app, selected_object(app)) if app.ui.retopo_keep_symmetry else {}
	return {app.ui.retopo_engine, app.ui.retopo_adaptivity, mirror, app.ui.retopo_close_first, app.ui.retopo_keep_groups, app.ui.retopo_keep_creases, app.ui.retopo_edge_degrees, app.ui.retopo_use_paint, app.ui.retopo_use_mask}
}

// The Edge angle slider's floor: lower would keep nearly every edge of a sculpt.
RETOPO_EDGE_DEGREES_MIN :: f32(15)

// What the selected object carries for the options that ask for it: its polygroups per
// triangle of the shown level, the base level's creases when the base level is the one
// shown (the creases are the base level's, and a level above has other vertices), and
// the shown level's paint and mask per vertex for Use paint and Use mask. All are copies
// the caller frees (quad_source_destroy): the job's thread reads them while the object
// goes on being edited. A dynamic object's packing renumbers its vertices and keeps no
// paint, so its mask comes from the packing (object_shape, long_job_copy) and its paint
// is not used.
quad_source :: proc(obj: ^Object, options: retopo.Options) -> (src: retopo.Source) {
	if obj == nil || obj.voxel != nil do return
	s := object_sculptor(obj)
	if sculpt.sculptor_has_groups(s) do src.groups = slice.clone(sculpt.sculptor_groups(s))
	if !object_dynamic(obj) {
		if obj.levels.current == 0 {
			sharp := obj.levels.levels[0].sharp
			if len(sharp.edges) > 0 do src.creases = slice.clone(sharp.edges)
		}
		if options.use_paint && sculpt.sculptor_has_color(s) do src.paint = slice.clone(s.color)
		if options.use_mask && sculpt.sculptor_has_mask(s) do src.mask = slice.clone(s.mask)
	}
	return
}

quad_source_destroy :: proc(src: ^retopo.Source) {
	delete(src.groups)
	delete(src.creases)
	delete(src.paint)
	delete(src.mask)
	src^ = {}
}

// The panel set to a command's options (Adjust last); Keep symmetry turns on when the
// command kept some, and is left as it is when there was none to keep.
quad_options_set :: proc(app: ^App, o: retopo.Options) {
	app.ui.retopo_engine, app.ui.retopo_adaptivity, app.ui.retopo_close_first = o.engine, o.adaptivity, o.close_first
	app.ui.retopo_keep_groups, app.ui.retopo_keep_creases = o.keep_groups, o.keep_creases
	app.ui.retopo_edge_degrees = o.edge_degrees if o.edge_degrees > 0 else retopo.EDGE_DEGREES_DEFAULT
	app.ui.retopo_use_paint, app.ui.retopo_use_mask = o.use_paint, o.use_mask
	if o.mirror.axes != {} do app.ui.retopo_keep_symmetry = true
}

// Makes a new object of about `quads` quads on the shape of the level the selected
// object is on, with UVs, next to it, and selects it. Returns false only on a GPU failure.
// A long job (long_job.odin) runs the same two halves, retopo.compute on its thread.
object_retopo :: proc(app: ^App, obj: ^Object, quads: int, options: retopo.Options) -> (made, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	source := quad_source(obj, options)
	defer quad_source_destroy(&source)
	view, packed := object_shape(obj, top = false, mask = &source.mask if options.use_mask && object_dynamic(obj) else nil)
	r := retopo.compute(view, quads, options, &app.pool, source = source)
	delete(view.normals)
	geom.mesh_destroy(&packed)
	if !r.built {
		log.warnf("quad remesh: %s has too few triangles for %d quads", object_label(obj), quads)
		return false, true
	}
	return retopo_apply(app, obj, &r, start)
}

// Makes the object from a computed retopology of `obj`, next to it, and selects it; the
// result's parts become the object's. `start` is when the work began, for the mesh's build.
retopo_apply :: proc(app: ^App, obj: ^Object, r: ^retopo.Result, start: time.Tick) -> (made, ok: bool) {
	res := r^
	r^ = {}
	defer delete(res.reason)
	old_to_new := make([]u32, len(res.mesh.positions))
	defer delete(old_to_new)
	tri_from: []u32
	if res.polys.first != nil do tri_from = make([]u32, len(res.mesh.indices) / 3)
	defer delete(tri_from)
	delete(res.q.positions)
	// Not in temp memory, which building frees.
	name := fmt.aprintf("%s retopo", object_label(obj))
	defer delete(name)
	t := obj.transform
	t.position = next_free_position(app)
	if !scene_add_mesh(app, res.mesh, name, obj.file, t, start, old_to_new, material = obj.material, tri_from = tri_from) {
		delete(res.q.quads)
		geom.uv_layout_destroy(&res.uv)
		sculpt.polys_destroy(&res.polys)
		return false, false
	}
	twin := selected_object(app)
	if res.polys.first != nil {
		// The base level keeps the polygons, so Wireframe draws their edges and Subdivide
		// cuts them as Catmull-Clark cuts quads.
		retopo.polys_renumber(&res.polys, old_to_new, tri_from)
		if !sculpt.levels_set_polys(&twin.levels, res.polys, {}, .Smooth) do log.errorf("quad remesh: the polygons did not fit the triangles cut from them, so %s keeps none", object_label(twin))
	}
	charts := 0
	if res.q.quads != nil {
		for &f in res.q.quads do for &v in f do v = old_to_new[v]
		sculpt.levels_set_quads(&twin.levels, res.q.quads)
		sculpt.levels_set_uvs(&twin.levels, res.uv)
		charts = res.uv.charts
	}
	app.ui.bake.source = obj.id
	// "Quad remeshed X: 1,180 quads (AutoRemesher), UVs in 12 charts, 226 ms", with the
	// other polygons and no UVs when some are not quads, and why the built-in engine ran
	// when it was not asked for.
	engine := retopo.ENGINE_NAMES[res.engine]
	if res.reason != "" do engine = fmt.tprintf("built-in, as AutoRemesher said %s", res.reason)
	if res.mirrored do engine = fmt.tprintf("%s, mirrored across %s", engine, planes_label(res.mirror))
	if res.unmirrored != "" do engine = fmt.tprintf("%s, not mirrored since %s", engine, res.unmirrored)
	if res.closed > 0 do engine = fmt.tprintf("%s, closed first", engine)
	if res.features > 0 do engine = fmt.tprintf("%s, %s group and crease edges kept", engine, thousands(res.features))
	if res.unkept != "" do engine = fmt.tprintf("%s, %s", engine, res.unkept)
	flags: Report_Flags
	if res.reason != "" || res.quads != res.faces do flags += {.Warning}
	faces := fmt.tprintf("%s quads", thousands(res.quads))
	if res.quads != res.faces do faces = fmt.tprintf("%s quads, %d triangles and %d larger faces, so no UVs", thousands(res.quads), res.triangles, res.ngons)
	uvs := fmt.tprintf(", UVs in %d charts", charts) if charts > 0 else ""
	report(app, Kit_Section.Retopo, flags, "Quad remeshed %s: %s (%s)%s, %.0f ms", object_label(obj), faces, engine, uvs, res.retopo_ms + res.uv_ms)
	if res.engine == .Own {
		how := res.how
		log.infof("quad remesh: built-in decimated to %d triangles, %d paired; %d vertices not put back; UVs fill %.0f%% in %.0f ms", how.decimated, how.paired, how.unprojected, 100 * res.uv.filled, res.uv_ms)
	}
	return true, true
}

// The object Bake maps... reads the detail from: the one chosen, else the one the
// quads came from, else none.
bake_source :: proc(app: ^App, low: ^Object) -> ^Object {
	src := object_by_id(app, app.ui.bake.source)
	// An object bakes from itself only from its own detail skin.
	if src == low && object_top_skin(low) == nil do return nil
	return src
}

// Bakes the bake source's detail onto the selected quad object and writes, into
// `folder`, NAME_normal.png (tangent space, OpenGL's green up), NAME_displacement.png
// (16-bit grey, 32768 for none), NAME_displacement.txt (the distance the full range
// stands for) and NAME.obj (the quads with their UVs), NAME being the object's.
bake_to_folder :: proc(app: ^App, folder: string) {
	low := selected_object(app)
	if low == nil || !sculpt.levels_has_uvs(&low.levels) {
		file_note(app, true, "Bake: select an object made by Quad Remesh first")
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
	// A source with a detail skin bakes the surface the skin shows; from the low object's
	// own skin, each texel takes its own point's offset (geom.Bake_Source.rest).
	view, packed, rest: geom.Mesh
	skinned := object_top_skin(src) != nil
	if skinned {
		top := &src.levels.levels[len(src.levels.levels) - 1].sculptor
		packed, rest, _ = sculpt.sculptor_skin_mesh(top)
		view = packed
		view.normals = make([dynamic]geom.Vec3, len(view.positions))
		geom.mesh_recompute_normals(&view)
	} else {
		view, packed = object_shape(src, top = true)
	}
	defer {
		delete(view.normals)
		geom.mesh_destroy(&packed)
		delete(rest.positions)
	}
	bvh := geom.bvh_build_morton(view, geom.BVH_LEAF_SIZE, &app.pool)
	defer geom.bvh_destroy(&bvh)
	rest_bvh: geom.Bvh
	defer if src == low do geom.bvh_destroy(&rest_bvh)
	sculpt.levels_sync(&low.levels)
	quads := sculpt.levels_quad_mesh(&low.levels)
	edge: f32
	for f in quads.quads do for k in 0 ..< 4 do edge += linalg.length(quads.positions[f[(k + 1) % 4]] - quads.positions[f[k]])
	edge /= f32(max(4 * len(quads.quads), 1))
	size := int(app.ui.bake.size)
	set := &app.ui.bake
	kinds: bit_set[geom.Bake_Kind]
	if set.base_color do kinds += {.Base_Color}
	if set.orm do kinds += {.Orm}
	if set.id do kinds += {.Id}
	if set.vector do kinds += {.Vector}
	source := bake_source_of(app, src, view, &bvh)
	if src == low {
		rest_bvh = geom.bvh_build_morton(rest, geom.BVH_LEAF_SIZE, &app.pool)
		source.rest, source.rest_bvh = rest, &rest_bvh
	}
	options := geom.Bake_Options{object_space = set.object_space, directx = set.target == .Unreal}
	maps := geom.bake_maps(quads, low.levels.faces.uv, source, size, set.reach_edges * edge, kinds, &app.pool, options = options)
	defer geom.bake_maps_destroy(&maps)
	baked_ms := time.duration_milliseconds(time.tick_since(start))

	base, _ := strings.replace_all(object_label(low), " ", "_", context.temp_allocator)
	path :: proc(folder, base, suffix: string) -> string {
		joined, _ := filepath.join({folder, strings.concatenate({base, suffix}, context.temp_allocator)}, context.temp_allocator)
		return joined
	}
	normal_png := png_write.encode(maps.normal, size, size, false)
	defer delete(normal_png)
	// The bake set's maps, each with its file's suffix.
	Extra :: struct {
		pixels: []u8,
		suffix: string,
	}
	extras := [?]Extra{{maps.base_color, "_base_color.png"}, {maps.orm, "_orm.png"}, {maps.id, "_id.png"}}
	written := make([dynamic]string, context.temp_allocator)
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
	pngs: [len(extras)][]u8
	defer for p in pngs do delete(p)
	for e, k in extras {
		if e.pixels == nil do continue
		pngs[k] = png_write.encode(e.pixels, size, size, false)
		if !write_file_safely(app, path(folder, base, e.suffix), pngs[k], "bake") do return
		append(&written, e.suffix)
	}
	if maps.vector != nil {
		// In the OBJ's units, as the displacement's note gives them.
		for &v in maps.vector do v *= low.file.scale
		exr := hdri.exr_encode(maps.vector, size, size)
		defer delete(exr)
		if !write_file_safely(app, path(folder, base, "_vdm.exr"), exr, "bake") do return
		append(&written, "_vdm.exr")
	}
	glb := make([dynamic]u8)
	defer delete(glb)
	// glTF reads a tangent-space normal map with green up only.
	glb_normal := normal_png if !set.object_space && set.target != .Unreal else nil
	bake_glb(&glb, low, quads, source, object_label(low), glb_normal, pngs[0], pngs[1], set.occlusion_rays > 0)
	if !write_file_safely(app, path(folder, base, ".glb"), glb[:], "bake") do return
	append(&written, ".glb")
	// The maps stay on the object, shown through its UVs (textures.odin): the first bake of
	// a run turns the view on so the result shows at once. The ID map is a mask source, not
	// a look, so it stays a file.
	// The viewport reads a normal map in the tangent frame with green up, and an object's
	// own skin already shows its detail, so only such a map from another object is shown.
	shown_normal := normal_png if !set.object_space && set.target != .Unreal && src != low else nil
	kept: Object_Textures
	for img, m in ([render.Texture_Map][]u8{.Base_Color = pngs[0], .Orm = pngs[1], .Normal = shown_normal}) {
		if img == nil do continue
		kept.image[m] = make([]u8, len(img))
		copy(kept.image[m], img)
	}
	textures_replace(app, low, kept, "bake maps")
	if app.texture_view == .Off do app.texture_view = .Textured
	share := 100 * f64(maps.hit) / f64(max(maps.covered, 1))
	more := strings.join(written[:], ", ", context.temp_allocator)
	report(app, Kit_Section.Retopo, {.Warning} if share < 99 else {}, "Baked %s from %s at %d x %d in %.0f ms: %.1f%% of texels found the surface, displacement up to %.4g; %s_normal.png, _displacement.png%s%s and .obj written, and the maps shown on it (View > Textures)%s",
		object_label(low), object_label(src), size, size, baked_ms, share, full, base, ", " if more != "" else "", more,
		"; it has dynamic topology, so no paint or polygroups to bake" if object_dynamic(src) && kinds & {.Base_Color, .Id} != {} else "")
}

// The baked quad object `low` as a binary glTF, ready to look at in another program
// (quad_object_glb), with the maps just written (`base_color` and `orm` nil when not
// baked). Without a base colour map the material takes the source's own colour, and
// without an ORM map its roughness and metal; `occlusion` says whether the ORM map's red
// is baked occlusion.
bake_glb :: proc(out: ^[dynamic]u8, low: ^Object, quads: geom.Quad_Mesh, src: geom.Bake_Source, name: string, normal, base_color, orm: []u8, occlusion: bool) {
	own := src.surfaces[0] if len(src.surfaces) > 0 else geom.Bake_Surface{base = 0.6, roughness = 0.5}
	mat := geom.Export_Material {
		name      = fmt.tprintf("%s baked", name),
		base      = own.base,
		metallic  = own.metallic,
		roughness = own.roughness,
	}
	_, _ = quad_object_glb(out, low, quads, name, {.Base_Color = base_color, .Orm = orm, .Normal = normal}, mat, occlusion)
}

// Quad object `obj` (`quads`, its base level) as a binary glTF: its quads as triangles,
// split where the UVs are, with normals, UVs and the tangents the normal map was baked
// in, and material `mat` with `maps` (nil for none) embedded as its textures: a base
// colour map stands for the material's colour, and an ORM map for its roughness and metal
// and, with `occlusion`, its occlusion. A map that is neither PNG nor JPEG, the two glTF
// reads, goes as PNG. `morphs` are the base level's layers and `colors` its vertex colours
// (nil for none), carried onto the split vertices, and `lights` go beside the mesh.
// Returns how many vertices were
// written; false when the file would pass glTF's 4 GB.
quad_object_glb :: proc(out: ^[dynamic]u8, obj: ^Object, quads: geom.Quad_Mesh, name: string, maps: [render.Texture_Map][]u8, mat: geom.Export_Material, occlusion: bool, morphs: []geom.Morph_Target = nil, colors: [][3]u8 = nil, lights: []geom.Export_Light = nil) -> (vertices: int, ok: bool) {
	maps := maps
	for &img in maps {
		if img == nil || geom.image_mime(img) == "image/jpeg" || (len(img) >= 4 && string(img[:4]) == "\x89PNG") do continue
		pixels, w, h, failed := matcap_pixels(img, context.temp_allocator)
		img = png_write.encode(pixels, w, h, false, context.temp_allocator) if failed == "" else nil
	}
	uvs := obj.levels.faces.uv
	normals := geom.quad_mesh_normals(quads, context.temp_allocator)
	frame := geom.quad_mesh_tangents(quads, uvs, normals, context.temp_allocator)
	positions, split_normals, texcoords, indices := geom.quad_mesh_split_uvs(quads, uvs, normals, frame, context.temp_allocator)
	images := make([dynamic]geom.Export_Image, context.temp_allocator)
	mat := mat
	if img := maps[.Base_Color]; img != nil {
		append(&images, geom.Export_Image{"base colour", img})
		mat.textures[.Base_Color], mat.base = len(images), 1
	}
	if img := maps[.Orm]; img != nil {
		append(&images, geom.Export_Image{"occlusion, roughness, metal", img})
		mat.textures[.Orm], mat.metallic, mat.roughness = len(images), 1, 1
		if occlusion do mat.textures[.Occlusion] = len(images)
	}
	if img := maps[.Normal]; img != nil {
		append(&images, geom.Export_Image{"normal", img})
		mat.textures[.Normal] = len(images)
	}
	// A layer moves a vertex, and so every slot the split made of it.
	split := make([]geom.Morph_Target, len(morphs), context.temp_allocator)
	at := make([]i32, len(quads.positions), context.temp_allocator)
	for m, k in morphs {
		slice.fill(at, -1)
		for v, i in m.vertices do at[v] = i32(i)
		vertices := make([dynamic]u32, context.temp_allocator)
		deltas := make([dynamic]geom.Vec3, context.temp_allocator)
		for v, slot in frame.vertex {
			if at[v] < 0 do continue
			append(&vertices, u32(slot))
			append(&deltas, m.deltas[at[v]])
		}
		split[k] = {m.name, m.weight, vertices[:], deltas[:]}
	}
	split_colors: [][3]u8
	if colors != nil {
		split_colors = make([][3]u8, len(frame.vertex), context.temp_allocator)
		for v, slot in frame.vertex do split_colors[slot] = colors[v]
	}
	m := geom.Mesh_Export {
		name      = name,
		positions = positions,
		normals   = split_normals,
		indices   = indices,
		texcoords = texcoords,
		tangents  = frame.tangents,
		images    = images[:],
		material  = mat,
		morphs    = split,
		colors    = split_colors,
		scale     = obj.file.scale,
		offset    = obj.file.position,
		lights    = lights,
	}
	return len(positions), geom.mesh_write_glb(out, m)
}

// What a bake reads from object `src`, whose top level (or packed copy, when dynamic) is
// `view` with `bvh` over it: its paint, polygroups and materials (its own and its
// groups'), and the occlusion settings. In temporary memory, but for the views of the
// level's arrays.
bake_source_of :: proc(app: ^App, src: ^Object, view: geom.Mesh, bvh: ^geom.Bvh) -> (s: geom.Bake_Source) {
	s.mesh, s.bvh = view, bvh
	set := app.ui.bake
	if set.occlusion_rays > 0 {
		box := geom.AABB_EMPTY
		for p in view.positions do box = {linalg.min(box.lo, p), linalg.max(box.hi, p)}
		s.occlusion_rays = int(set.occlusion_rays)
		s.occlusion_reach = set.occlusion_reach * linalg.length(box.hi - box.lo) if len(view.positions) > 0 else 0
	}
	which, materials := group_slots(app, src)
	s.surfaces = make([]geom.Bake_Surface, len(materials), context.temp_allocator)
	for m, k in materials do s.surfaces[k] = {m.base, m.metallic, m.roughness}
	// A dynamic object's packed copy has neither its paint nor its groups.
	if object_dynamic(src) || src.voxel != nil do return
	sculpt.levels_paint_to_top(&src.levels)
	top := &src.levels.levels[len(src.levels.levels) - 1].sculptor
	s.paint = top.color
	s.groups = top.groups.tris
	if s.groups != nil && len(src.group_materials) > 0 {
		s.slots = make([]u8, len(s.groups), context.temp_allocator)
		for g, t in s.groups do s.slots[t] = which[g]
	}
	return
}

// The interface's UVs and baking section: Quad Remesh itself is Shape > Rebuild's Quads.
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
		if other == obj && object_top_skin(obj) == nil do continue
		if other == src do chosen = len(names)
		append(&names, fmt.tprintf("Bake from its own skin##%d", other.id) if other == obj else fmt.tprintf("Bake from %s##%d", object_label(other), other.id))
		append(&ids, other.id)
	}
	if picked := ui.select(ctx, "bake from", names[:], chosen); picked >= 0 do app.ui.bake.source = ids[picked]
	bake, uvs := kit_button_pair(ctx, "Bake maps...", "New UVs")
	if bake do file_dialog(app, .Bake)
	if uvs do app.ui.scene_command = {kind = .Layout_Uvs}
	ui.paragraph(ctx, "Bakes the source's detail (its top level) into normal and displacement maps on this object's UVs, with its colour and the other maps chosen under More options, and writes them with the quads as OBJ into a folder.")
	if kit_more(app, .Retopo) {
		sizes: [len(BAKE_SIZES)]string
		size := -1
		for s, i in BAKE_SIZES {
			sizes[i] = fmt.tprintf("%d", s)
			if s == app.ui.bake.size do size = i
		}
		if picked := ui.tabs(ctx, "bake size", sizes[:], size); picked >= 0 do app.ui.bake.size = BAKE_SIZES[picked]
		_ = ui.slider(ctx, "Reach", &app.ui.bake.reach_edges, 0.5, 10, .Linear, fmt.tprintf("%.1f edges", app.ui.bake.reach_edges))
		set := &app.ui.bake
		_ = ui.switch_row(ctx, "Base colour", &set.base_color)
		_ = ui.switch_row(ctx, "Occlusion, roughness, metal", &set.orm)
		_ = ui.switch_row(ctx, "Polygroup colours", &set.id)
		_ = ui.switch_row(ctx, "Vector displacement (VDM)", &set.vector)
		_ = ui.switch_row(ctx, "Object space", &set.object_space)
		ui.label(ctx, "MAPS FOR")
		targets: [len(Bake_Target)]string
		for name, k in BAKE_TARGET_NAMES do targets[int(k)] = name
		if picked := ui.tabs(ctx, "bake target", targets[:], int(set.target)); picked >= 0 do set.target = Bake_Target(picked)
		if set.orm {
			rays := f32(set.occlusion_rays)
			if ui.slider(ctx, "Occlusion rays", &rays, 0, BAKE_OCCLUSION_RAYS_MAX, .Linear, fmt.tprintf("%d", set.occlusion_rays) if set.occlusion_rays > 0 else "Off") do set.occlusion_rays = i32(rays + 0.5)
			if set.occlusion_rays > 0 do _ = ui.slider(ctx, "Occlusion reach", &set.occlusion_reach, 0.01, 1, .Logarithmic, fmt.tprintf("%.0f%% of its size", 100 * set.occlusion_reach))
		}
		ui.paragraph(ctx, "The maps' size in texels, and Reach: how far each texel looks either way. Base colour is the polypaint over the materials; occlusion, roughness and metal go in one map's red, green and blue, as glTF reads them; polygroup colours make an ID map. More occlusion rays are smoother and slower. Vector displacement writes the whole offset to the sculpt as a 32-bit OpenEXR map (x, y and z in red, green and blue, as Blender reads it). Object space gives the normal and vector maps in the object's own axes instead of the surface's tangent frame. Maps for Unreal turn the normal map's green over, as DirectX reads it.")
		kit_more_end(app)
	}
}
