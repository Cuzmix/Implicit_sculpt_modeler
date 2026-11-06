package main

import "base:runtime"
import "core:fmt"
import "core:image"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import "../geom"
import "../jobs"
import "../render"
import "../sculpt"
import "../uv"
import "../ui"

// Texture maps on a retopologized object (stage 3.3, notes/rendering/textured-preview-
// design.md): the bake leaves its base colour, ORM and normal maps on the quad object it
// baked onto, the scene file keeps them, and the viewport shows them through the object's
// UVs in place of its clay (render/textured.odin) while View > Textures says so. The maps
// follow the UV layout they were made on: they live while the object's quads and UVs do
// (textures_settle) and go with Unwrap in the same undo step.

// An object's maps as image files (PNG from a bake), owned; nil for none.
Object_Textures :: struct {
	image: [render.Texture_Map][]u8,
	stamp: u32, // changes on every change, for the GPU copy (Texture_Preview.maps_stamp)
	// Changes when a .Textures step replaces the object's UV layout (Unwrap, its undo
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
	topology:   Split_Topology,
	peel:       f32, // the Peel the vertices were made at (uv_peel_of)
	// The base level's Mesh_Buffers.index_version the slots were made for, and whether they
	// were made with the vertex each stands for, so the mesh can pull (texture_pulls).
	index_version: u64,
	slots_pulled:  bool,
}

// How a level of triangles splits where its UVs are (textured_split), kept while its
// triangles and UVs stay: finding the slots reads every corner through a hash, about a
// third of a second for a million triangles, so a sculpt edit reuses them and only
// gathers each slot's position and normal again and squares its tangent to the new
// normal. Owned with the heap allocator; empty for a quad object's base level, whose split
// follows the bake's own frame and is made each time.
Split_Topology :: struct {
	index_version: u64, // the level's Mesh_Buffers.index_version the slots were made for
	layout:        u32, // the Object_Textures.layout they were made with
	vertex:        []u32,
	uv:            [][2]f32,
	tangents:      [][4]f32,
	indices:       []u32,
}

split_topology_free :: proc(t: ^Split_Topology) {
	h := runtime.heap_allocator()
	delete(t.vertex, h)
	delete(t.uv, h)
	delete(t.tangents, h)
	delete(t.indices, h)
	t^ = {}
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
// ones in the step; with `uvs` (made with the object's levels' allocator), the object's
// UVs are replaced in the same step (taken). Every scene change goes through the frame start, which settles autosave.
textures_replace :: proc(app: ^App, obj: ^Object, t: Object_Textures, what: string, uvs: Maybe(uv.Uvs) = nil) {
	autosave_settle(app)
	step := new(Texture_Step)
	step.textures = obj.textures
	obj.textures = t
	obj.textures.stamp = step.textures.stamp + 1
	obj.textures.layout = step.textures.layout
	if next, ok := uvs.?; ok {
		// Texture layers follow the UVs: laid out again for the new ones, the old tiles kept
		// in the step.
		sculpt.levels_texels_relayout(&obj.levels, next, &step.texels)
		step.uvs, step.has_uvs = obj.levels.uvs, true
		obj.levels.uvs = next
		obj.levels.uv_stamp += 1
		obj.textures.layout += 1
	}
	history_record_textures(app, obj, step, what)
	app.scene_edits += 1
}

// What a .Textures undo step keeps: the object's maps (and, for Unwrap, its UVs and its
// texture layers' tiles as they were laid out for them) on the other side of the change.
// Undo and redo swap them with the object's, so the same step goes back and forth.
Texture_Step :: struct {
	textures: Object_Textures,
	uvs:      uv.Uvs,
	has_uvs:  bool,
	texels:   [dynamic]sculpt.Texel_Step,
}

texture_step_free :: proc(step: ^Texture_Step) {
	if step == nil do return
	textures_free(&step.textures)
	if step.has_uvs do uv.destroy(&step.uvs)
	for &t in step.texels do sculpt.texel_step_free(&t)
	delete(step.texels)
	free(step)
}

// Bytes a step holds, counted toward the undo memory limit.
texture_step_bytes :: proc(step: ^Texture_Step) -> int {
	if step == nil do return 0
	n := textures_bytes(step.textures)
	if step.has_uvs do n += uv.bytes(step.uvs)
	for &t in step.texels do n += sculpt.texel_step_bytes(&t)
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
		obj.levels.uvs, step.uvs = step.uvs, obj.levels.uvs
		obj.levels.uv_stamp += 1
		obj.textures.layout += 1
	}
	for &t in step.texels do sculpt.levels_texel_step_swap(&obj.levels, &t)
}

// What a .Textures step that loads map `m` is called in the History (constants: the
// History does not own its labels).
TEXTURE_LOAD_LABELS := [render.Texture_Map]string {
	.Base_Color = "load base colour map",
	.Orm        = "load ORM map",
	.Normal     = "load normal map",
}

// Why `obj` cannot take maps ("" when it can): they are drawn and exported through the
// UVs of its base level, which Unwrap gives any sculpt.
texture_target_check :: proc(obj: ^Object) -> string {
	if obj == nil do return "Select an object with UVs first"
	if obj.voxel != nil || obj.curve != nil || obj.cage != nil do return fmt.tprintf("%s takes no maps: it has no sculpt surface", object_label(obj))
	if !sculpt.levels_has_uvs(&obj.levels) do return fmt.tprintf("%s has no UVs: Unwrap in the Mesh card's UVs section gives it some", object_label(obj))
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
	report(app, Section.Textures, {}, "Loaded %s as the %s map of %s", filepath.base(path), TEXTURE_MAP_NAMES[m], object_label(obj))
	return ""
}

// Removes all of `obj`'s maps as one undo step.
texture_remove :: proc(app: ^App, obj: ^Object) {
	if obj == nil || !object_has_textures(obj) do return
	textures_replace(app, obj, {}, "remove maps")
	report(app, Section.Textures, {}, "Removed the maps of %s", object_label(obj))
}

// Whether `obj` draws through its textured preview this frame, with `lv` the level shown:
// a view is on, the object is on its base level with UVs, sculpted in no other
// way that the preview cannot show (dynamic topology, HD, hidden parts, polygroup colours,
// The texture view object `obj` draws in, set by the view's own: Peel shows the checker
// when nothing else is shown, so the islands can be told apart as they lay flat.
object_texture_view :: proc(app: ^App, obj: ^Object) -> render.Texture_View {
	if app.texture_view == .Off && uv_peel_of(app, obj) > 0 do return .Uv_Checker
	// Texture paint shows wherever the object does, as vertex paint does.
	if app.texture_view == .Off && sculpt.levels_texels_show(&obj.levels) do return .Textured
	return app.texture_view
}

// Whether `obj`'s textured mesh pulls its slots from the level's buffers (Textured_Mesh.
// slot_vertex), so it follows a stroke with nothing gathered: not while a Peel moves the
// slots, nor on a quad object's base level, whose slots carry the normals its maps were
// baked with.
texture_pulls :: proc(app: ^App, obj: ^Object) -> bool {
	return uv_peel_of(app, obj) == 0 && !(obj.levels.current == 0 && sculpt.levels_has_quad_uvs(&obj.levels))
}

// a stroke on it right now) and the view has something to show.
object_textured :: proc(app: ^App, obj: ^Object, lv: ^sculpt.Level) -> bool {
	view := texture_view_shown(app)
	if view == .Off && uv_peel_of(app, obj) > 0 do view = .Uv_Checker
	if view == .Off && sculpt.levels_texels_show(&obj.levels) do view = .Textured
	if view == .Off || obj.voxel != nil || object_in_hd(obj) || object_dynamic(obj) do return false
	if !sculpt.levels_has_uvs(&obj.levels) do return false
	if sculpt.sculptor_hidden_units(&lv.sculptor) != nil || app.show_groups do return false
	// A pulled mesh follows the stroke as it is made; one that is not would show the
	// surface as it was, so the object draws as clay until the stroke ends.
	if app.stroke.active && app.stroke.object == obj.id && !texture_pulls(app, obj) do return false
	maps := obj.preview.mesh.maps
	switch view {
	case .Off:        return false
	case .Textured:   return maps != {} || sculpt.levels_texels_show(&obj.levels)
	case .Normal_Map: return maps[.Normal] != 0
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
	texture_paint_frame(app, cmd, obj)
	if !object_textured(app, obj, lv) do return nil
	peel := uv_peel_of(app, obj)
	pull := texture_pulls(app, obj)
	// A pulled mesh reads its positions and normals from the level's buffers, so a sculpt
	// edit asks for its slots again only where render mode reads their normals.
	moved := p.shape != gpu.version && (!pull || p.index_version != gpu.index_version || render_running(app))
	current := !moved && p.layout == obj.textures.layout && p.peel == peel
	if p.broken && current do return nil
	if !current || p.mesh.index_count == 0 {
		vertices, indices, corners, slot_vertex := textured_vertices(obj, gpu, &p.topology, &app.pool, peel, app.ui.uv_peel_frame)
		p.shape, p.index_version, p.layout, p.peel = gpu.version, gpu.index_version, obj.textures.layout, peel
		p.broken = !render.textured_mesh_upload(&app.renderer, cmd, &p.mesh, vertices, indices, corners, slot_vertex)
		if p.broken {
			file_note(app, true, "The GPU refused the textured copy of %s; it shows as clay", object_label(obj))
			return nil
		}
		p.slots_pulled = slot_vertex != nil
	}
	p.mesh.pulled = pull && p.slots_pulled
	return &p.mesh
}

// Brings `obj`'s texture paint textures up to date on the frame's `cmd`: the composite of
// its texture layers (sculpt.levels_texels_flush), made at their size, and the tiles that
// changed since the last frame uploaded; dropped once no texture layer is left. A GPU
// failure leaves the object without its texture paint, said once.
texture_paint_frame :: proc(app: ^App, cmd: render.Cmd, obj: ^Object) {
	l := &obj.levels
	p := &obj.preview
	side := u32(l.texels.side) if len(l.texels.layers) > 0 else 0
	if side != p.mesh.paint_side {
		if !render.textured_mesh_paint_size(&app.renderer, &p.mesh, side) {
			file_note(app, true, "The GPU refused the texture paint of %s; it shows without it", object_label(obj))
			return
		}
		// New textures hold nothing: every tile goes up.
		l.texels.whole = true
	}
	if side == 0 do return
	// The texel map a stroke on the picked texture layer paints through is made here, between
	// strokes, after a layer, level or UV change, so no stroke starts by waiting for it.
	if layer, _ := sculpt.levels_texel_picked(l); layer != nil && !app.stroke.active do _ = sculpt.levels_texel_map(l)
	sculpt.levels_texels_flush(l)
	changed, all := sculpt.levels_texels_take(l)
	if len(changed) == 0 && !all do return
	across := sculpt.texel_tiles_across(int(side))
	tiles := make([dynamic]render.Paint_Tile, 0, across * across if all else len(changed), context.temp_allocator)
	add :: proc(tiles: ^[dynamic]render.Paint_Tile, l: ^sculpt.Levels, index, across: int) {
		t := sculpt.levels_texels_shown(l, index)
		up := render.Paint_Tile{at = {u32(index % across), u32(index / across)}}
		if t != nil {
			up.color = slice.to_bytes(t.color) if t.color != nil else nil
			up.material = slice.to_bytes(t.material) if t.material != nil else nil
		}
		append(tiles, up)
	}
	if all do for index in 0 ..< across * across do add(&tiles, l, index, across)
	else do for index in changed do add(&tiles, l, int(index), across)
	_ = render.textured_mesh_paint_tiles(&app.renderer, cmd, &p.mesh, tiles[:])
}

// Level `level` of the object split where its UVs are, as the textured preview draws it
// and a textured `.glb` carries it: per slot its vertex, position, smooth normal,
// coordinate and tangent, the triangles by slot, and for render mode, which traces the
// level's own triangles, the slot each of their corners takes (nil, said in the log, when
// they cannot all be matched). A quad object's base level splits its quads
// (geom.quad_mesh_split_uvs), with the normals and tangents the bake read its normal map
// with, so the map reads back as baked; any other level its triangles (uv.split), with its
// own normals and the UVs it takes from the base (sculpt.levels_uvs_at). Temp memory.
Textured_Split :: struct {
	vertex:    []u32,
	positions: []geom.Vec3,
	normals:   []geom.Vec3,
	uv:        [][2]f32,
	tangents:  [][4]f32,
	indices:   []u32,
	corners:   []u32,
}

textured_split :: proc(obj: ^Object, level: int) -> (s: Textured_Split) {
	base := obj.levels.levels[0]
	if layout, ok := sculpt.levels_quad_uvs(&obj.levels); ok && level == 0 {
		quads := sculpt.levels_quad_mesh(&obj.levels)
		normals := geom.quad_mesh_normals(quads, context.temp_allocator)
		frame := geom.quad_mesh_tangents(quads, layout, normals, context.temp_allocator)
		s.positions, s.normals, s.uv, s.indices = geom.quad_mesh_split_uvs(quads, layout, normals, frame, context.temp_allocator)
		s.vertex, s.tangents = frame.vertex, frame.tangents
		matched: bool
		s.corners, matched = geom.quad_mesh_triangle_corners(quads, s.indices, base.mesh.indices[:], base.sculptor.faces, context.temp_allocator)
		if !matched {
			log.warnf("%s: its triangles are not all halves of its quads; render mode shows it without its maps", object_label(obj))
			s.corners = nil
		}
		return
	}
	lv := obj.levels.levels[level]
	positions := lv.mesh.positions[:]
	normals := lv.mesh.normals[:]
	u, ok := sculpt.levels_uvs_at(&obj.levels, level, context.temp_allocator)
	if !ok do return
	sp := uv.split(u, positions, lv.mesh.indices[:], normals, context.temp_allocator)
	s.vertex, s.uv, s.tangents, s.indices = sp.vertex, sp.uv, sp.tangents, sp.indices
	s.positions = make([]geom.Vec3, len(sp.vertex), context.temp_allocator)
	s.normals = make([]geom.Vec3, len(sp.vertex), context.temp_allocator)
	for v, slot in sp.vertex do s.positions[slot], s.normals[slot] = positions[v], normals[v]
	// The split keeps the level's triangles in their order, so each corner's slot is its own.
	s.corners = sp.indices
	return
}

// The preview's vertices (textured_split), each with its vertex's mask, for the level
// shown, whose buffers are `gpu`; a level of triangles keeps its split in `topology`
// (Split_Topology) and reuses it while it fits. With `peel` above 0 each slot moves that
// far toward its UV coordinate laid on a square through the object's middle along `frame`
// (right, up and toward the eye, in the object's axes) (Peel). Temp memory.
textured_vertices :: proc(obj: ^Object, gpu: ^render.Mesh_Buffers, topology: ^Split_Topology, pool: ^jobs.Pool, peel: f32 = 0, frame := [3]geom.Vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}) -> (vertices: []render.Textured_Vertex, indices: []u32, corners: []u32, slot_vertex: []u32) {
	level := obj.levels.current
	lv := sculpt.levels_current(&obj.levels)
	Job :: struct {
		vertices:  []render.Textured_Vertex,
		vertex:    []u32,
		positions: []geom.Vec3,
		normals:   []geom.Vec3,
		tangents:  [][4]f32,
		uv:        [][2]f32,
		mask:      []u8,
		gather:    bool, // positions and normals by vertex, tangents squared to them
		peel:      f32,
		center:    geom.Vec3, // the middle of the level's box, where the flat square stands
		side:      f32,       // its longest side, the square's
		frame:     [3]geom.Vec3,
	}
	job := Job{mask = lv.sculptor.mask, peel = clamp(peel, 0, 1), frame = frame}
	if job.peel > 0 && len(lv.mesh.positions) > 0 {
		lo, hi := lv.mesh.positions[0], lv.mesh.positions[0]
		for p in lv.mesh.positions do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
		job.center, job.side = 0.5 * (lo + hi), max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
	}
	if level == 0 && sculpt.levels_has_quad_uvs(&obj.levels) {
		split_topology_free(topology)
		s := textured_split(obj, level)
		indices, corners = s.indices, s.corners
		job.vertex, job.positions, job.normals, job.tangents, job.uv = s.vertex, s.positions, s.normals, s.tangents, s.uv
	} else {
		if topology.vertex == nil || topology.index_version != gpu.index_version || topology.layout != obj.textures.layout {
			split_topology_free(topology)
			s := textured_split(obj, level)
			if s.vertex == nil do return
			h := runtime.heap_allocator()
			topology^ = {gpu.index_version, obj.textures.layout, slice.clone(s.vertex, h), slice.clone(s.uv, h), slice.clone(s.tangents, h), slice.clone(s.indices, h)}
		}
		// The split keeps the level's triangles in their order, so each corner's slot is its own.
		indices, corners = topology.indices, topology.indices
		job.vertex, job.positions, job.normals, job.tangents, job.uv = topology.vertex, lv.mesh.positions[:], lv.mesh.normals[:], topology.tangents, topology.uv
		job.gather = true
	}
	job.vertices = make([]render.Textured_Vertex, len(job.vertex), context.temp_allocator)
	jobs.parallel_ranges(pool, len(job.vertices), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for slot in lo ..< hi {
			v := job.vertex[slot]
			m: u8 = job.mask[v] if job.mask != nil else 0
			t := job.tangents[slot]
			p, n := job.positions[v], job.normals[v]
			if job.gather {
				// The tangent kept from the split, squared to the normal as it is now: a
				// sculpt edit turns the surface a little, which the preview need not
				// follow more closely than this.
				d := geom.Vec3{t.x, t.y, t.z}
				d = linalg.normalize0(d - linalg.dot(d, n) * n)
				if d == {} do d, _ = geom.perpendicular_pair(n)
				t.xyz = d
			} else {
				p, n = job.positions[slot], job.normals[slot]
			}
			if job.peel > 0 {
				// The UV square, as large as the object's longest side, stands in its middle
				// facing the eye, u to the right and v up, so the islands read as laid out.
				at := job.uv[slot] - 0.5
				flat := job.center + job.side * (at.x * job.frame[0] + at.y * job.frame[1])
				p = linalg.lerp(p, flat, job.peel)
				n = linalg.normalize0(linalg.lerp(n, job.frame[2], job.peel))
				if n == {} do n = job.frame[2]
			}
			job.vertices[slot] = {
				position = p,
				normal   = render.pack_normal(n, m),
				tangent  = {snorm16(t.x), snorm16(t.y), snorm16(t.z), snorm16(t.w)},
				uv       = job.uv[slot],
			}
		}
	}, geom.RANGE_GRAIN)
	vertices = job.vertices
	// The level's own vertex per slot, for pulling: only where the slots stand on the
	// level's vertices (a level of triangles, not peeled).
	if job.gather && job.peel == 0 do slot_vertex = job.vertex
	if job.peel > 0 && job.peel < 1 {
		// Midway, a piece from the far side turns through edge-on toward the eye, and its
		// triangles face away until it has: each goes twice, the second turned round with
		// its normal flipped, so no piece goes missing while it turns.
		count := len(vertices)
		both := make([]render.Textured_Vertex, 2 * count, context.temp_allocator)
		copy(both, vertices)
		for v, i in vertices {
			w := v
			n, m := geom.oct_masked_decode(v.normal)
			w.normal = render.pack_normal(-n, m)
			both[count + i] = w
		}
		twice := make([]u32, 2 * len(indices), context.temp_allocator)
		copy(twice, indices)
		for k in 0 ..< len(indices) / 3 {
			o := len(indices) + 3 * k
			twice[o], twice[o + 1], twice[o + 2] = indices[3 * k] + u32(count), indices[3 * k + 2] + u32(count), indices[3 * k + 1] + u32(count)
		}
		vertices, indices = both, twice
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
			if p.mesh.maps[m] != 0 do _ = render.textured_mesh_set_map(&app.renderer, &p.mesh, m, nil, 0, 0)
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

// The Textures card: how objects with maps show, and the selected
// object's maps, each with what the viewport holds of it and its Load button; under More,
// Remove maps.
kit_textures_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	kit_last_result(app, .Textures)
	if obj != nil && obj.voxel == nil && obj.curve == nil && obj.cage == nil && !sculpt.levels_has_uvs(&obj.levels) {
		kit_uvs_ask(app, "This object has no UVs. Texture maps need them.")
		return
	}
	if texture_target_check(obj) != "" {
		ui.paragraph(ctx, "Shows and loads texture maps on a sculpt with UVs: select one, or give one UVs with Unwrap.")
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
		case p.mesh.maps[m] == 0:           state = "not shown"
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
	split_topology_free(&obj.preview.topology)
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

