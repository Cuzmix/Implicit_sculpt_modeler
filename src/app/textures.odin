package main

import "base:runtime"
import "core:fmt"
import "core:image"
import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

import "../geom"
import "../render"
import "../sculpt"
import "../ui"
import "../retopo"

// Texture maps on a retopologized object (stage 3.3, notes/rendering/textured-preview-
// design.md): the bake leaves its base colour, ORM and normal maps on the quad object it
// baked onto, the scene file keeps them, and the viewport shows them through the object's
// UVs in place of its clay (render/textured.odin) while View > Textures says so. The maps
// follow the UV layout they were made on: they live while the object's quads and UVs do
// (textures_settle) and go with New UVs in the same undo step.

// An object's maps as image files (PNG from a bake), owned; nil for none.
Object_Textures :: struct {
	image: [render.Texture_Map][]u8,
	stamp: u32, // changes on every change, for the GPU copy (Texture_Preview.maps_stamp)
	// Changes when a .Textures step replaces the object's UV layout (New UVs, its undo
	// and redo), for the preview's vertices (Texture_Preview.layout); not saved, and kept
	// when the maps are replaced.
	layout: u32,
}

// Images larger than this a side are refused: core:image's own limit is 8192 x 8192.
TEXTURE_MAX_SIDE :: 8192
// The viewport shows a map at most this big a side, halved until it fits: three 4096
// maps with their mips take about 256 MB, which a tablet should not spend on a preview.
TEXTURE_PREVIEW_SIDE :: 2048 when MOBILE else 4096

// The GPU side of an object's preview, never saved: its textured mesh, what it was built
// from, and the thread decoding its maps.
Texture_Preview :: struct {
	mesh:       render.Textured_Mesh,
	shape:      u64,    // the base level's Mesh_Buffers.version the vertices were made from
	layout:     u32,    // the Object_Textures.layout the vertices were made with
	maps_stamp: u32,    // the Object_Textures.stamp the maps hold
	decoder:    ^Texture_Decoder,
	// Maps whose image did not decode, so they are not tried again until they change;
	// the object shows without them.
	failed:     [render.Texture_Map]bool,
	// The GPU refused the textured mesh, so the object draws as clay (said once) until
	// its shape or layout changes.
	broken:     bool,
}

// A thread turning an object's images into RGBA8 pixels: it works on copies, so the
// object's images may change or go meanwhile, and the frame loop takes its pixels.
Texture_Decoder :: struct {
	stamp:  u32,
	image:  [render.Texture_Map][]u8, // copies, owned
	pixels: [render.Texture_Map][]u8, // RGBA8 rows top to bottom, owned; nil for none or a failure
	size:   [render.Texture_Map][2]int,
	failed: [render.Texture_Map]bool,
	side:   int, // halved until no side is larger
	done:   bool, // atomic
	thread: ^thread.Thread,
}

// Whether `obj` has any map.
object_has_textures :: proc(obj: ^Object) -> bool {
	for img in obj.textures.image do if img != nil do return true
	return false
}

// Frees the images.
textures_free :: proc(t: ^Object_Textures) {
	for img in t.image do delete(img)
	t.image = {}
}

// Total bytes of the images, for the undo memory limit and the scene file's estimate.
textures_bytes :: proc(t: Object_Textures) -> (n: int) {
	for img in t.image do n += len(img)
	return
}

// Copies of `t`'s images.
textures_clone :: proc(t: Object_Textures) -> (c: Object_Textures) {
	for img, m in t.image do if img != nil do c.image[m] = clone_bytes(img)
	c.stamp = t.stamp
	return
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	c := make([]u8, len(b))
	copy(c, b)
	return c
}

// Why `data` cannot be a map ("" when it can): it must be an image core:image reads, no
// larger than TEXTURE_MAX_SIDE a side. Reads only its header.
texture_image_check :: proc(data: []u8) -> string {
	img, err := image.load_from_bytes(data, {.info})
	if err != nil do return fmt.tprintf("%v (PNG, JPEG, BMP, TGA and QOI images work)", err)
	defer image.destroy(img)
	if img.width < 1 || img.height < 1 || img.width > TEXTURE_MAX_SIDE || img.height > TEXTURE_MAX_SIDE {
		return fmt.tprintf("%d x %d is not between 1 and %d a side", img.width, img.height, TEXTURE_MAX_SIDE)
	}
	return ""
}

// Drops the maps of every object that no longer has the UVs they were made on: a rebuild,
// deleting the levels below or dynamic topology drop an object's quads, and their own
// undo step (a swap's snapshot) keeps the maps with the quads. Each frame, beside
// materials_settle.
textures_settle :: proc(app: ^App) {
	for obj in app.scene.objects {
		if !object_has_textures(obj) || sculpt.levels_has_uvs(&obj.levels) do continue
		autosave_settle(app)
		textures_free(&obj.textures)
		obj.textures.stamp += 1
	}
}

// Replaces `obj`'s maps with `t` (taken) as one undo step named `what`, keeping the old
// ones in the step; with `uvs`, the object's UV layout is replaced in the same step
// (taken). Every scene change goes through the frame start, which settles autosave.
textures_replace :: proc(app: ^App, obj: ^Object, t: Object_Textures, what: string, uvs: Maybe(geom.Uv_Layout) = nil) {
	autosave_settle(app)
	step := new(Texture_Step)
	step.textures = obj.textures
	obj.textures = t
	obj.textures.stamp = step.textures.stamp + 1
	obj.textures.layout = step.textures.layout
	if layout, ok := uvs.?; ok {
		step.uvs, step.has_uvs = obj.levels.faces.uv, true
		obj.levels.faces.uv = layout
		obj.textures.layout += 1
	}
	history_record_textures(app, obj, step, what)
	app.scene_edits += 1
}

// What a .Textures undo step keeps: the object's maps (and, for New UVs, its UV layout)
// on the other side of the change. Undo and redo swap them with the object's, so the same
// step goes back and forth.
Texture_Step :: struct {
	textures: Object_Textures,
	uvs:      geom.Uv_Layout,
	has_uvs:  bool,
}

texture_step_free :: proc(step: ^Texture_Step) {
	if step == nil do return
	textures_free(&step.textures)
	if step.has_uvs do geom.uv_layout_destroy(&step.uvs)
	free(step)
}

// Bytes a step holds, counted toward the undo memory limit.
texture_step_bytes :: proc(step: ^Texture_Step) -> int {
	if step == nil do return 0
	n := textures_bytes(step.textures)
	if step.has_uvs do n += len(step.uvs.uvs) * size_of([4][2]f32) + len(step.uvs.chart) * size_of(u32)
	return n
}

// Undoes or redoes a .Textures step on `obj`: its maps (and layout) and the step's trade
// places.
texture_step_swap :: proc(obj: ^Object, step: ^Texture_Step) {
	stamp, layout := obj.textures.stamp, obj.textures.layout
	obj.textures, step.textures = step.textures, obj.textures
	obj.textures.stamp = max(stamp, step.textures.stamp) + 1
	obj.textures.layout = layout
	if step.has_uvs {
		obj.levels.faces.uv, step.uvs = step.uvs, obj.levels.faces.uv
		obj.textures.layout += 1
	}
}

// New UVs as a scene command: lays the selected quad object's UVs out again and drops its
// maps, which followed the old layout, in one undo step.
object_layout_uvs :: proc(app: ^App, obj: ^Object) {
	if !sculpt.levels_has_quads(&obj.levels) do return
	sculpt.levels_sync(&obj.levels)
	uv := geom.quad_uv_unwrap(sculpt.levels_quad_mesh(&obj.levels), retopo.UV_PADDING)
	had := object_has_textures(obj)
	textures_replace(app, obj, {}, "new UVs", uv)
	note := ", its maps removed (they followed the old UVs)" if had else ""
	report(app, Kit_Section.Retopo, {}, "New UVs on %s: %d charts filling %.0f%%%s", object_label(obj), uv.charts, 100 * uv.filled, note)
}

// What a .Textures step that loads map `m` is called in the History (constants: the
// History does not own its labels).
TEXTURE_LOAD_LABELS := [render.Texture_Map]string {
	.Base_Color = "load base colour map",
	.Orm        = "load ORM map",
	.Normal     = "load normal map",
}

// Why `obj` cannot take maps ("" when it can): they are drawn and exported through the
// UVs of a quad object's base level.
texture_target_check :: proc(obj: ^Object) -> string {
	if obj == nil do return "Select an object with UVs first"
	if obj.voxel != nil || !sculpt.levels_has_quads(&obj.levels) || !sculpt.levels_has_uvs(&obj.levels) {
		return fmt.tprintf("%s has no UVs: Shape > Rebuild > Quads makes an object with them", object_label(obj))
	}
	return ""
}

// Loads the image file at `path` as `obj`'s map `m`, in place of any it had, as one undo
// step, and turns the texture view on when it was off so the map shows. Only the header is
// read here: the decode is the preview's thread's, which says if the rest is damaged.
// Returns why nothing was loaded, "" when it was.
texture_load :: proc(app: ^App, obj: ^Object, m: render.Texture_Map, path: string) -> string {
	if why := texture_target_check(obj); why != "" do return why
	data, err := file_read_any(path)
	if err != nil do return fmt.tprintf("Cannot read %s: %v", filepath.base(path), err)
	if why := texture_image_check(data); why != "" {
		delete(data)
		return fmt.tprintf("Cannot use %s as a map: %s", filepath.base(path), why)
	}
	t := textures_clone(obj.textures)
	delete(t.image[m])
	t.image[m] = data
	textures_replace(app, obj, t, TEXTURE_LOAD_LABELS[m])
	if app.texture_view == .Off do app.texture_view = .Textured
	report(app, Kit_Section.Textures, {}, "Loaded %s as the %s map of %s", filepath.base(path), TEXTURE_MAP_NAMES[m], object_label(obj))
	return ""
}

// Removes all of `obj`'s maps as one undo step.
texture_remove :: proc(app: ^App, obj: ^Object) {
	if obj == nil || !object_has_textures(obj) do return
	textures_replace(app, obj, {}, "remove maps")
	report(app, Kit_Section.Textures, {}, "Removed the maps of %s", object_label(obj))
}

// Whether `obj` draws through its textured preview this frame, with `lv` the level shown:
// a view is on, the object is on its base level with quads and UVs, sculpted in no other
// way that the preview cannot show (dynamic topology, HD, hidden parts, polygroup colours,
// a stroke on it right now) and the view has something to show.
object_textured :: proc(app: ^App, obj: ^Object, lv: ^sculpt.Level) -> bool {
	view := texture_view_shown(app)
	if view == .Off || obj.voxel != nil || obj.levels.current != 0 || object_in_hd(obj) || object_dynamic(obj) do return false
	if !sculpt.levels_has_quads(&obj.levels) || !sculpt.levels_has_uvs(&obj.levels) do return false
	if sculpt.sculptor_hidden_units(&lv.sculptor) != nil || app.show_groups do return false
	if app.stroke.active && app.stroke.object == obj.id do return false
	maps := obj.preview.mesh.maps
	switch view {
	case .Off:        return false
	case .Textured:   return maps != {}
	case .Normal_Map: return maps[.Normal] != nil
	case .Uv_Checker: return true
	}
	return false
}

// Brings `obj`'s preview up to date for this frame, after its base level's upload (`gpu`)
// on the frame's `cmd`, and returns the textured mesh to draw, or nil to draw it as clay.
// Starts decoding changed maps on a thread, one object at a time (each decode holds its
// pixels until the frame loop takes them); until they are in, the object shows without
// them. A GPU failure leaves the object as clay with a note.
texture_preview_frame :: proc(app: ^App, cmd: render.Cmd, obj: ^Object, gpu: ^render.Mesh_Buffers) -> ^render.Textured_Mesh {
	p := &obj.preview
	texture_decoder_poll(app, obj)
	if p.decoder == nil && p.maps_stamp != obj.textures.stamp && app.texture_decodes == 0 do texture_decoder_start(app, obj)
	lv := sculpt.levels_current(&obj.levels)
	if !object_textured(app, obj, lv) do return nil
	current := p.shape == gpu.version && p.layout == obj.textures.layout
	if p.broken && current do return nil
	if !current || p.mesh.index_count == 0 {
		vertices, indices, corners := textured_vertices(obj)
		p.shape, p.layout = gpu.version, obj.textures.layout
		p.broken = !render.textured_mesh_upload(&app.renderer, cmd, &p.mesh, vertices, indices, corners)
		if p.broken {
			file_note(app, true, "The GPU refused the textured copy of %s; it shows as clay", object_label(obj))
			return nil
		}
	}
	return &p.mesh
}

// The preview's vertices: the base level's quads split where the UVs are, with the same
// smooth normals and tangents the bake read its normal map with and the `.glb` carries
// (geom.quad_mesh_split_uvs), so the map reads back as baked; each with its vertex's mask.
// And for render mode, which traces the base level's own triangles, the slot each of their
// corners takes; nil, said in the log, if they cannot all be matched to the quads. Temp
// memory.
textured_vertices :: proc(obj: ^Object) -> (vertices: []render.Textured_Vertex, indices: []u32, corners: []u32) {
	quads := sculpt.levels_quad_mesh(&obj.levels)
	uvs := obj.levels.faces.uv
	normals := geom.quad_mesh_normals(quads, context.temp_allocator)
	frame := geom.quad_mesh_tangents(quads, uvs, normals, context.temp_allocator)
	positions, split_normals, uv_coords, split_indices := geom.quad_mesh_split_uvs(quads, uvs, normals, frame, context.temp_allocator)
	indices = split_indices
	base := obj.levels.levels[0]
	matched: bool
	corners, matched = geom.quad_mesh_triangle_corners(quads, split_indices, base.mesh.indices[:], base.sculptor.faces, context.temp_allocator)
	if !matched {
		log.warnf("%s: its triangles are not all halves of its quads; render mode shows it without its maps", object_label(obj))
		corners = nil
	}
	mask := sculpt.levels_current(&obj.levels).sculptor.mask
	vertices = make([]render.Textured_Vertex, len(positions), context.temp_allocator)
	for &v, slot in vertices {
		m: u8 = mask[frame.vertex[slot]] if mask != nil else 0
		t := frame.tangents[slot]
		v = {
			position = positions[slot],
			normal   = render.pack_normal(split_normals[slot], m),
			tangent  = {snorm16(t.x), snorm16(t.y), snorm16(t.z), snorm16(t.w)},
			uv       = uv_coords[slot],
		}
	}
	return
}

@(private = "file")
snorm16 :: proc(x: f32) -> i16 {
	return i16(clamp(x, -1, 1) * 32767 + (0.5 if x >= 0 else -0.5))
}

// The colour a textured item draws with: its base colour map is multiplied by the item's
// tint over the material's own colour (white unless the object is idle, picked or a
// ghost), so the maps show as baked and dim with the others; without a base colour map
// the tint itself, as on clay.
textured_color :: proc(tint: [4]f32, m: Material, has_base: bool) -> [4]f32 {
	if !has_base do return tint
	c := tint
	for k in 0 ..< 3 do c[k] = tint[k] / m.selected[k] if m.selected[k] > 1e-4 else 1
	return c
}

// Starts decoding `obj`'s maps as they are now.
@(private = "file")
texture_decoder_start :: proc(app: ^App, obj: ^Object) {
	d := new(Texture_Decoder)
	d.stamp = obj.textures.stamp
	d.image = textures_clone(obj.textures).image
	d.side = TEXTURE_PREVIEW_SIDE
	obj.preview.decoder = d
	app.texture_decodes += 1
	d.thread = thread.create_and_start_with_data(d, proc(data: rawptr) {
		d := (^Texture_Decoder)(data)
		// The pixels it leaves are freed by the frame loop with the same heap allocator,
		// and its temp memory is its own, freed at the end.
		context.allocator = runtime.heap_allocator()
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		for img, m in d.image {
			if img == nil do continue
			pixels, w, h, failed := matcap_pixels(img)
			if failed != "" {
				d.failed[m] = true
				continue
			}
			d.pixels[m], d.size[m] = texture_halve_to(pixels, w, h, d.side)
		}
		sync.atomic_store(&d.done, true)
	}, context, .Low, name = "texture decode")
}

// Takes a finished decode into the GPU maps; with `wait`, waits for one still running
// (an object about to go).
texture_decoder_poll :: proc(app: ^App, obj: ^Object, wait := false) {
	p := &obj.preview
	d := p.decoder
	if d == nil || (!wait && !sync.atomic_load(&d.done)) do return
	thread.join(d.thread)
	thread.destroy(d.thread)
	p.decoder = nil
	app.texture_decodes -= 1
	defer {
		for img in d.image do delete(img)
		for px in d.pixels do delete(px, runtime.heap_allocator())
		free(d)
	}
	if wait do return
	for m in render.Texture_Map {
		fresh := d.failed[m] && !p.failed[m]
		p.failed[m] = d.failed[m]
		if fresh do file_note(app, true, "The %s map of %s could not be read; it shows without it", TEXTURE_MAP_NAMES[m], object_label(obj))
		if d.pixels[m] == nil {
			if p.mesh.maps[m] != nil do _ = render.textured_mesh_set_map(&app.renderer, &p.mesh, m, nil, 0, 0)
			continue
		}
		if !render.textured_mesh_set_map(&app.renderer, &p.mesh, m, d.pixels[m], d.size[m].x, d.size[m].y) {
			file_note(app, true, "The GPU refused the %d x %d %s map of %s; it shows without it", d.size[m].x, d.size[m].y, TEXTURE_MAP_NAMES[m], object_label(obj))
		}
	}
	p.maps_stamp = d.stamp
}

TEXTURE_VIEW_NAMES := [render.Texture_View]string {
	.Off        = "Textures off (clay)",
	.Textured   = "Show textures",
	.Normal_Map = "Normal map only",
	.Uv_Checker = "UV checker",
}

// The file request that loads each map, and its command's choices.
TEXTURE_FILE_KINDS := [render.Texture_Map]File_Kind {
	.Base_Color = .Base_Color_Map,
	.Orm        = .Orm_Map,
	.Normal     = .Normal_Map,
}

TEXTURE_LOAD_NAMES := [render.Texture_Map]string {
	.Base_Color = "Load base colour map...",
	.Orm        = "Load ORM map...",
	.Normal     = "Load normal map...",
}

// The Object palette's Textures section: how objects with maps show, and the selected
// object's maps, each with what the viewport holds of it and its Load button; under More,
// Remove maps.
kit_textures_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	kit_last_result(app, .Textures)
	if texture_target_check(obj) != "" {
		ui.paragraph(ctx, "Shows and loads texture maps on an object with UVs: make one with Shape > Rebuild > Quads, then bake onto it under UVs and baking or load maps here.")
		return
	}
	views := [len(render.Texture_View)]string{"Clay", "Maps", "Normal", "Checker"}
	if picked := ui.tabs(ctx, "texture view", views[:], int(app.texture_view)); picked >= 0 do app.texture_view = render.Texture_View(picked)
	shown := make([dynamic]string, context.temp_allocator)
	p := &obj.preview
	for m in render.Texture_Map {
		state: string
		switch {
		case obj.textures.image[m] == nil:    state = "none"
		case p.failed[m]:                     state = "unreadable"
		case p.maps_stamp != obj.textures.stamp: state = "loading"
		case p.mesh.maps[m] == nil:           state = "not shown"
		case:                                 state = fmt.tprintf("%d x %d", p.mesh.sizes[m].x, p.mesh.sizes[m].y)
		}
		append(&shown, fmt.tprintf("%s: %s", TEXTURE_MAP_LABELS[m], state))
	}
	ui.paragraph(ctx, strings.join(shown[:], ", ", context.temp_allocator))
	for m in render.Texture_Map do _ = command_button(app, .Load_Texture, int(m), label = TEXTURE_LOAD_NAMES[m], variant = .Bordered)
	ui.paragraph(ctx, "Clay shows objects without their maps; Maps shows them, Normal the object's own material through its normal map, and Checker a grid laid out by the UVs. A loaded map replaces the one before it, and undo brings that back. ORM is occlusion, roughness and metal in red, green and blue, as glTF reads them.")
	if kit_more(app, .Textures) {
		_ = command_button(app, .Remove_Textures, variant = .Bordered)
		kit_more_end(app)
	}
}

// Each map's name to start a sentence.
TEXTURE_MAP_LABELS := [render.Texture_Map]string {
	.Base_Color = "Base colour",
	.Orm        = "ORM",
	.Normal     = "Normal",
}

TEXTURE_MAP_NAMES := [render.Texture_Map]string {
	.Base_Color = "base colour",
	.Orm        = "occlusion, roughness and metal",
	.Normal     = "normal",
}

// Halves `pixels` (RGBA8, `width` by `height`, taken) by 2 x 2 averages until no side is
// larger than `side`; returns them (the same slice when already small enough) and their size.
texture_halve_to :: proc(pixels: []u8, width, height, side: int) -> (out: []u8, size: [2]int) {
	out, size = pixels, {width, height}
	for size.x > side || size.y > side {
		w, h := max(size.x / 2, 1), max(size.y / 2, 1)
		half := make([]u8, w * h * 4)
		for y in 0 ..< h {
			for x in 0 ..< w {
				for c in 0 ..< 4 {
					sum: u32
					for dy in 0 ..< 2 do for dx in 0 ..< 2 {
						sx, sy := min(2 * x + dx, size.x - 1), min(2 * y + dy, size.y - 1)
						sum += u32(out[(sy * size.x + sx) * 4 + c])
					}
					half[(y * w + x) * 4 + c] = u8((sum + 2) / 4)
				}
			}
		}
		delete(out)
		out, size = half, {w, h}
	}
	return
}

// Releases `obj`'s preview: its decode (waited for) and GPU copy.
texture_preview_release :: proc(app: ^App, obj: ^Object) {
	texture_decoder_poll(app, obj, wait = true)
	render.textured_mesh_destroy(&app.renderer, &obj.preview.mesh)
	obj.preview = {}
}

// The scene file's form of an object's maps (version 18): a byte of which maps there are
// (bit k for Texture_Map k), then each one's byte count and bytes, in that order.
textures_put :: proc(out: ^[dynamic]u8, t: Object_Textures) {
	bits: u8
	for img, m in t.image do if img != nil do bits |= 1 << u8(m)
	geom.byte_put(out, bits)
	for img in t.image {
		if img == nil do continue
		geom.byte_put(out, u32(len(img)))
		append(out, ..img)
	}
}

// Reads what textures_put wrote; r.ok goes false on damage: a map that is not one, a count
// past the end, or an image whose header does not read as one no larger than the limit.
textures_get :: proc(r: ^geom.Byte_Reader) -> (t: Object_Textures) {
	bits := geom.byte_get(r, u8)
	if bits >= 1 << len(render.Texture_Map) {
		r.ok = false
		return
	}
	for m in render.Texture_Map {
		if bits & (1 << u8(m)) == 0 do continue
		n := int(geom.byte_get(r, u32))
		if !r.ok || n < 1 || n > len(r.data) - r.at {
			r.ok = false
			break
		}
		img := r.data[r.at:][:n]
		r.at += n
		if texture_image_check(img) != "" {
			r.ok = false
			break
		}
		t.image[m] = clone_bytes(img)
	}
	if !r.ok do textures_free(&t)
	// Read maps are new to the object's preview, which starts at stamp 0; with none, the
	// two agree and nothing is decoded.
	if bits != 0 && r.ok do t.stamp = 1
	return
}

