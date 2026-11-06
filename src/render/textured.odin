package render

import "../gpu"
import "core:log"
import "core:math/bits"

// The textured preview: a small mesh of its own for an object whose maps were baked or
// loaded (a retopologized object's quads, split where its UVs are, research-3-pbr.md
// section 7), drawn with textured.vert.slang and textured.frag.slang in place of the object's sculpt
// buffers. It has no chunks, culling or simplified copies: such an object is a few
// thousand to some hundred thousand quads, drawn whole in one call. The object's own
// buffers stay, for its wireframe, the studio render's shadows and the damage boxes.

// The maps a textured mesh can show, in the order the shader binds them after the MatCap.
Texture_Map :: enum u8 {
	Base_Color, // sRGB colour, multiplied by the item's colour
	Orm,        // linear: occlusion, roughness, metallic, as glTF packs them
	Normal,     // linear: a tangent-space normal, MikkTSpace's convention
}

// What a textured item shows: nothing (it draws as clay through its sculpt buffers), its
// maps, its normal map alone over its material, or a checker laid out by its UVs.
Texture_View :: enum u8 {
	Off,
	Textured,
	Normal_Map,
	Uv_Checker,
}

// One vertex of a textured mesh, in one interleaved buffer.
Textured_Vertex :: struct {
	position: [3]f32,
	normal:   Normal_Packed, // octahedral with the mask folded in (pack_normal), as the sculpt vertex
	tangent:  [4]i16,        // xyz unit, w ±1, read as SHORT4_NORM
	uv:       [2]f32,        // v up, as geom.Uv_Layout keeps it; the shader samples (u, 1 - v)
}
#assert(size_of(Textured_Vertex) == 32)

Textured_Mesh :: struct {
	vertices:        gpu.Buffer,
	indices:         gpu.Buffer,
	vertex_capacity: u32, // vertices
	index_capacity:  u32, // indices
	index_count:     u32,
	vertex_count:    u32,
	// For render mode (path.odin): each corner of each triangle of the object's sculpt mesh
	// the preview stands for, in that mesh's order, as a slot in `vertices`; as many
	// corners as `indices` has, or none (corner_count 0) where they could not be matched.
	corners:         gpu.Buffer,
	corner_count:    u32,
	maps:            [Texture_Map]gpu.Texture, // nil: none (a default is bound)
	sizes:           [Texture_Map][2]u32,
	stamp:           u64, // changes whenever the vertices or indices do
	maps_stamp:      u64, // changes whenever a map does
	// Per slot, the vertex of the level it stands for (Graphics_Storage_Read), so the
	// vertex stage pulls the slot's position, normal and paint from the level's own
	// buffers while `pulled` (textured.vert.slang): a stroke then shows on the textured
	// mesh with nothing gathered again. Nil where it was not given or the device refused.
	slot_vertex:     gpu.Buffer,
	pulled:          bool, // set by the owner for each frame it draws: the slots stand where uploaded when false (a Peel)
	// The texture paint layers' composite (textured_mesh_paint_tiles), `paint_side`
	// square: colour premultiplied by coverage (sRGB), and roughness and metal with their
	// coverages, premultiplied too (linear). Nil while there is none.
	paint:           gpu.Texture,
	paint_material:  gpu.Texture,
	paint_side:      u32,
}

// What textured_mesh_paint_tiles uploads for one tile: where it is, in tiles from the top
// left, and its texels (PAINT_TILE square, rows from the top, RGBA8), nil for none painted.
Paint_Tile :: struct {
	at:       [2]u32,
	color:    []u8,
	material: []u8,
}

// A paint tile's side in texels: sculpt.TEXEL_TILE, which render does not import.
PAINT_TILE :: 128

TEXTURE_FORMATS := [Texture_Map]gpu.Format {
	.Base_Color = .RGBA8_Srgb,
	.Orm        = .RGBA8_Unorm,
	.Normal     = .RGBA8_Unorm,
}

// Copies `vertices` and `indices` into the mesh's buffers before the next pass on `cmd`,
// growing them when they are too small, with
// `corners` (geom.quad_mesh_triangle_corners; nil or the wrong count for none). False,
// with the reason logged and the mesh left drawing nothing, when the device refuses.
textured_mesh_upload :: proc(r: ^Renderer, cmd: gpu.Cmd, tm: ^Textured_Mesh, vertices: []Textured_Vertex, indices: []u32, corners: []u32 = nil, slot_vertex: []u32 = nil) -> bool {
	vbytes, ibytes := u32(len(vertices) * size_of(Textured_Vertex)), u32(len(indices) * size_of(u32))
	if vbytes == 0 || ibytes == 0 {
		tm.index_count, tm.corner_count = 0, 0
		return true
	}
	if u32(len(vertices)) > tm.vertex_capacity || u32(len(indices)) > tm.index_capacity {
		textured_buffers_release(r, tm)
		tm.vertex_capacity = u32(1) << u32(bits.log2(uint(len(vertices))) + 1)
		tm.index_capacity = u32(1) << u32(bits.log2(uint(len(indices))) + 1)
		tm.vertices = gpu.create_buffer({usage = {.Vertex}, size = tm.vertex_capacity * size_of(Textured_Vertex)})
		tm.indices = gpu.create_buffer({usage = {.Index}, size = tm.index_capacity * size_of(u32)})
		// Render mode only copies it into its own buffers; storage read is a usage every
		// device takes.
		tm.corners = gpu.create_buffer({usage = {.Storage_Read}, size = tm.index_capacity * size_of(u32)})
		// Pulling is optional: a device that refuses the buffer draws the slots as uploaded.
		tm.slot_vertex = gpu.create_buffer({usage = {.Graphics_Storage_Read}, size = tm.vertex_capacity * size_of(u32)})
		if tm.vertices == 0 || tm.indices == 0 || tm.corners == 0 {
			log.errorf("textured mesh buffers: %s", gpu.last_error())
			textured_buffers_release(r, tm)
			return false
		}
	}
	cbytes := ibytes if len(corners) == len(indices) else 0
	ok := gpu.upload(cmd, tm.vertices, 0, ([^]u8)(raw_data(vertices))[:vbytes]) && gpu.upload(cmd, tm.indices, 0, ([^]u8)(raw_data(indices))[:ibytes])
	if ok && cbytes > 0 do ok = gpu.upload(cmd, tm.corners, 0, ([^]u8)(raw_data(corners))[:cbytes])
	tm.pulled = false
	if ok && tm.slot_vertex != 0 && len(slot_vertex) == len(vertices) {
		ok = gpu.upload(cmd, tm.slot_vertex, 0, ([^]u8)(raw_data(slot_vertex))[:len(slot_vertex) * size_of(u32)])
	}
	if !ok {
		log.errorf("textured mesh upload: %s", gpu.last_error())
		tm.index_count, tm.corner_count = 0, 0
		return false
	}
	tm.index_count = u32(len(indices))
	tm.vertex_count = u32(len(vertices))
	tm.corner_count = cbytes / size_of(u32)
	r.last_version += 1
	tm.stamp = r.last_version
	return true
}

// Sets map `m` from RGBA8 `pixels` (`width` by `height`, rows top to bottom) with a full
// mip chain, or removes it for nil pixels. The upload has a command buffer of its own and
// is submitted at once, like a MatCap's. False, with the map left out and the reason logged,
// when the device refuses.
textured_mesh_set_map :: proc(r: ^Renderer, tm: ^Textured_Mesh, m: Texture_Map, pixels: []u8, width, height: int) -> bool {
	if tm.maps[m] != 0 {
		gpu.release_texture(tm.maps[m])
		tm.maps[m], tm.sizes[m] = 0, {}
	}
	r.last_version += 1
	tm.maps_stamp = r.last_version
	if pixels == nil do return true
	tex := texture_create(r, TEXTURE_FORMATS[m], pixels, width, height)
	if tex == 0 do return false
	tm.maps[m], tm.sizes[m] = tex, {u32(width), u32(height)}
	return true
}

// Releases everything the mesh holds (freed once no frame in flight draws it).
textured_mesh_destroy :: proc(r: ^Renderer, tm: ^Textured_Mesh) {
	textured_buffers_release(r, tm)
	for tex in tm.maps do if tex != 0 do gpu.release_texture(tex)
	_ = textured_mesh_paint_size(r, tm, 0)
	tm^ = {}
}

// Makes the paint textures `side` square, cleared to paint nothing, or drops them for 0;
// nothing when they already are. False, with the reason logged and none left, when the
// device refuses. They have no mips: a stroke changes some tiles each frame, which a mip
// chain would have to follow.
textured_mesh_paint_size :: proc(r: ^Renderer, tm: ^Textured_Mesh, side: u32) -> bool {
	if tm.paint_side == side do return true
	if tm.paint != 0 do gpu.release_texture(tm.paint)
	if tm.paint_material != 0 do gpu.release_texture(tm.paint_material)
	tm.paint, tm.paint_material, tm.paint_side = 0, 0, 0
	r.last_version += 1
	tm.maps_stamp = r.last_version
	if side == 0 do return true
	formats := [2]gpu.Format{.RGBA8_Srgb, .RGBA8_Unorm}
	made: [2]gpu.Texture
	zero := make([]u8, int(side) * int(side) * 4, context.temp_allocator)
	for f, k in formats {
		made[k] = gpu.create_texture({type = .D2, format = f, usage = {.Sampled}, width = side, height = side, layer_count_or_depth = 1, num_levels = 1})
		if made[k] == 0 || !texture_upload(r, made[k], zero, int(side), int(side), mips = false) {
			log.errorf("paint texture %d square: %s", side, gpu.last_error())
			for t in made do if t != 0 do gpu.release_texture(t)
			return false
		}
	}
	tm.paint, tm.paint_material, tm.paint_side = made[0], made[1], side
	return true
}

// Copies paint tiles into the paint textures before the next pass on `cmd`. False, with
// the reason logged, when the device refuses one (the rest still go).
textured_mesh_paint_tiles :: proc(r: ^Renderer, cmd: gpu.Cmd, tm: ^Textured_Mesh, tiles: []Paint_Tile) -> bool {
	if tm.paint == 0 do return false
	@(static, rodata)
	ZERO := [PAINT_TILE * PAINT_TILE * 4]u8{}
	ok := true
	for t in tiles {
		at := t.at * PAINT_TILE
		if at.x + PAINT_TILE > tm.paint_side || at.y + PAINT_TILE > tm.paint_side do continue
		for k in 0 ..< 2 {
			pixels := t.color if k == 0 else t.material
			if pixels == nil do pixels = ZERO[:]
			assert(len(pixels) == len(ZERO))
			tex := tm.paint if k == 0 else tm.paint_material
			if !gpu.upload_texture(cmd, {texture = tex, x = at.x, y = at.y, w = PAINT_TILE, h = PAINT_TILE, d = 1}, pixels) {
				log.errorf("paint tile upload: %s", gpu.last_error())
				ok = false
			}
		}
	}
	r.last_version += 1
	tm.maps_stamp = r.last_version
	return ok
}

@(private = "file")
textured_buffers_release :: proc(r: ^Renderer, tm: ^Textured_Mesh) {
	if tm.vertices != 0 do gpu.release_buffer(tm.vertices)
	if tm.indices != 0 do gpu.release_buffer(tm.indices)
	if tm.corners != 0 do gpu.release_buffer(tm.corners)
	if tm.slot_vertex != 0 do gpu.release_buffer(tm.slot_vertex)
	tm.vertices, tm.indices, tm.corners, tm.slot_vertex = 0, 0, 0, 0
	tm.vertex_capacity, tm.index_capacity, tm.index_count, tm.vertex_count, tm.corner_count = 0, 0, 0, 0, 0
}

// Whether `item` draws through its textured mesh: it has one with something in it, a
// view that shows it, and the device made the textured pipeline.
@(private)
draws_textured :: proc(pipes: ^Mesh_Pipelines, item: Draw_Item) -> bool {
	return item.textured != nil && item.texture_view != .Off && item.textured.index_count > 0 && pipes.textured != 0
}

// Draws `item` from its textured mesh with the textured pipeline (bound by the caller),
// its maps bound after the MatCap and the environment, and defaults for the ones it lacks.
@(private)
draw_textured_item :: proc(r: ^Renderer, cmd: gpu.Cmd, pass: gpu.Render_Pass, item: Draw_Item, frame: ^Frame_Uniforms, material: ^Material_Uniforms, stats: ^Viewport_Stats) {
	tm := item.textured
	for m in Texture_Map do material.maps[int(m)] = 1 if tm.maps[m] != 0 else 0
	material.maps.w = f32(item.texture_view)
	push_fragment(cmd, Textured_Frag_Uniforms.Material_Uniforms, material)
	defaults := [Texture_Map]gpu.Texture{.Base_Color = r.no_matcap, .Orm = r.no_matcap, .Normal = r.no_normal_map}
	map_binding :: proc(r: ^Renderer, tm: ^Textured_Mesh, defaults: [Texture_Map]gpu.Texture, m: Texture_Map) -> gpu.Texture_Sampler_Binding {
		return {texture = tm.maps[m] if tm.maps[m] != 0 else defaults[m], sampler = r.texture_sampler}
	}
	samplers := [Textured_Frag_Samplers]gpu.Texture_Sampler_Binding {
		.matcap             = {texture = item.matcap if item.matcap != 0 else r.no_matcap, sampler = r.matcap_sampler},
		.environment_map    = environment_binding(r),
		.base_map           = map_binding(r, tm, defaults, .Base_Color),
		.orm_map            = map_binding(r, tm, defaults, .Orm),
		.normal_map         = map_binding(r, tm, defaults, .Normal),
		.paint_map          = {texture = tm.paint if tm.paint != 0 else r.no_paint_map, sampler = r.texture_sampler},
		.paint_material_map = {texture = tm.paint_material if tm.paint_material != 0 else r.no_paint_map, sampler = r.texture_sampler},
	}
	// The see-through pipeline's fragment shader (textured_area.frag) reads the same maps.
	#assert(len(Textured_Area_Frag_Samplers) == len(Textured_Frag_Samplers) && int(Textured_Area_Frag_Samplers.normal_map) == int(Textured_Frag_Samplers.normal_map))
	bind_fragment_samplers(pass, &samplers)
	// The level's buffers when pulling (textured.vert.slang), dummies otherwise.
	mb := item.mesh
	pull := tm.pulled && tm.slot_vertex != 0 && mb != nil && mb.storage && mb.normals != 0
	// The frame's uniforms are the caller's for the next item too: only this push pulls.
	skin := frame.skin
	frame.skin.x = 1 if pull else 0
	push_vertex(cmd, Textured_Vert_Uniforms.Frame_Uniforms, frame)
	frame.skin = skin
	storage := [Textured_Vert_Buffers]gpu.Buffer{
		.slot_vertex          = tm.slot_vertex if pull else r.no_paint,
		.positions            = mb.positions if pull else r.no_paint,
		.normals              = mb.normals if pull else r.no_paint,
		.paint                = mb.paint if pull && mb.paint != 0 else r.no_paint,
		.paint_material_words = mb.paint_material if pull && mb.paint_material != 0 else r.no_paint,
	}
	bind_vertex_storage(pass, &storage)
	vbuf := gpu.Buffer_Binding{buffer = tm.vertices}
	gpu.bind_vertex_buffers(pass, 0, &vbuf, 1)
	gpu.bind_index_buffer(pass, {buffer = tm.indices}, .U32)
	gpu.draw_indexed_primitives(pass, tm.index_count, 1, 0, 0, 0)
	if stats == nil do return
	stats.triangles += u64(tm.index_count / 3)
	stats.draws += 1
}

// Makes a sampled texture of `format` from RGBA8 `pixels` (`width` by `height`, rows top
// to bottom) with a full mip chain built on the GPU. Nil, with the reason logged, when
// the device refuses.
@(private)
texture_create :: proc(r: ^Renderer, format: gpu.Format, pixels: []u8, width, height: int) -> gpu.Texture {
	assert(width > 0 && height > 0 && len(pixels) == width * height * 4)
	levels := u32(bits.log2(uint(max(width, height)))) + 1
	tex := gpu.create_texture({
		type = .D2, format = format, usage = {.Sampled, .Color_Target},
		width = u32(width), height = u32(height), layer_count_or_depth = 1, num_levels = levels,
	})
	if tex == 0 {
		log.errorf("texture %d x %d: %s", width, height, gpu.last_error())
		return 0
	}
	if !texture_upload(r, tex, pixels, width, height, mips = levels > 1) {
		gpu.release_texture(tex)
		return 0
	}
	return tex
}
