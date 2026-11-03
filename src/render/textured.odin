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
	transfer:        gpu.Transfer_Buffer,
	vertex_capacity: u32, // vertices
	index_capacity:  u32, // indices
	transfer_size:   u32, // bytes
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
}

TEXTURE_FORMATS := [Texture_Map]gpu.Format {
	.Base_Color = .RGBA8_Srgb,
	.Orm        = .RGBA8_Unorm,
	.Normal     = .RGBA8_Unorm,
}

// Copies `vertices` and `indices` into the mesh's buffers in a copy pass on `cmd`, growing
// them (and waiting for the GPU before the old ones go) when they are too small, with
// `corners` (geom.quad_mesh_triangle_corners; nil or the wrong count for none). False,
// with the reason logged and the mesh left drawing nothing, when the device refuses.
textured_mesh_upload :: proc(r: ^Renderer, cmd: gpu.Cmd, tm: ^Textured_Mesh, vertices: []Textured_Vertex, indices: []u32, corners: []u32 = nil) -> bool {
	vbytes, ibytes := u32(len(vertices) * size_of(Textured_Vertex)), u32(len(indices) * size_of(u32))
	if vbytes == 0 || ibytes == 0 {
		tm.index_count, tm.corner_count = 0, 0
		return true
	}
	if u32(len(vertices)) > tm.vertex_capacity || u32(len(indices)) > tm.index_capacity || vbytes + ibytes > tm.transfer_size {
		textured_buffers_release(r, tm)
		tm.vertex_capacity = u32(1) << u32(bits.log2(uint(len(vertices))) + 1)
		tm.index_capacity = u32(1) << u32(bits.log2(uint(len(indices))) + 1)
		tm.transfer_size = tm.vertex_capacity * size_of(Textured_Vertex) + 2 * tm.index_capacity * size_of(u32)
		tm.vertices = gpu.create_buffer({usage = {.Vertex}, size = tm.vertex_capacity * size_of(Textured_Vertex)})
		tm.indices = gpu.create_buffer({usage = {.Index}, size = tm.index_capacity * size_of(u32)})
		// Render mode only copies it into its own buffers; storage read is a usage every
		// device takes.
		tm.corners = gpu.create_buffer({usage = {.Storage_Read}, size = tm.index_capacity * size_of(u32)})
		tm.transfer = gpu.create_transfer_buffer({usage = .Upload, size = tm.transfer_size})
		if tm.vertices == 0 || tm.indices == 0 || tm.corners == 0 || tm.transfer == 0 {
			log.errorf("textured mesh buffers: %s", gpu.last_error())
			textured_buffers_release(r, tm)
			return false
		}
	}
	// Cycled, so a frame still reading the last upload keeps its copy.
	dst := ([^]u8)(gpu.map_transfer_buffer(tm.transfer, true))
	if dst == nil {
		log.errorf("textured mesh upload: %s", gpu.last_error())
		tm.index_count, tm.corner_count = 0, 0
		return false
	}
	copy(dst[:vbytes], ([^]u8)(raw_data(vertices))[:vbytes])
	copy(dst[vbytes:][:ibytes], ([^]u8)(raw_data(indices))[:ibytes])
	cbytes := ibytes if len(corners) == len(indices) else 0
	if cbytes > 0 do copy(dst[vbytes + ibytes:][:cbytes], ([^]u8)(raw_data(corners))[:cbytes])
	gpu.unmap_transfer_buffer(tm.transfer)
	pass := gpu.begin_copy_pass(cmd)
	gpu.upload_to_buffer(pass, {transfer_buffer = tm.transfer}, {buffer = tm.vertices, size = vbytes}, false)
	gpu.upload_to_buffer(pass, {transfer_buffer = tm.transfer, offset = vbytes}, {buffer = tm.indices, size = ibytes}, false)
	if cbytes > 0 do gpu.upload_to_buffer(pass, {transfer_buffer = tm.transfer, offset = vbytes + ibytes}, {buffer = tm.corners, size = cbytes}, false)
	gpu.end_copy_pass(pass)
	tm.index_count = u32(len(indices))
	tm.vertex_count = u32(len(vertices))
	tm.corner_count = cbytes / size_of(u32)
	r.last_version += 1
	tm.stamp = r.last_version
	return true
}

// Sets map `m` from RGBA8 `pixels` (`width` by `height`, rows top to bottom) with a full
// mip chain, or removes it for nil pixels. The upload has a command buffer of its own and
// waits for it, like a MatCap's. False, with the map left out and the reason logged,
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
	if tm.vertices == 0 && tm.maps == {} do return
	textured_buffers_release(r, tm)
	for tex in tm.maps do if tex != 0 do gpu.release_texture(tex)
	tm^ = {}
}

@(private = "file")
textured_buffers_release :: proc(r: ^Renderer, tm: ^Textured_Mesh) {
	if tm.vertices != 0 do gpu.release_buffer(tm.vertices)
	if tm.indices != 0 do gpu.release_buffer(tm.indices)
	if tm.corners != 0 do gpu.release_buffer(tm.corners)
	if tm.transfer != 0 do gpu.release_transfer_buffer(tm.transfer)
	tm.vertices, tm.indices, tm.corners, tm.transfer = 0, 0, 0, 0
	tm.vertex_capacity, tm.index_capacity, tm.transfer_size, tm.index_count, tm.vertex_count, tm.corner_count = 0, 0, 0, 0, 0, 0
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
	gpu.push_vertex_uniform_data(cmd, 0, frame, size_of(Frame_Uniforms))
	gpu.push_fragment_uniform_data(cmd, 0, material, size_of(Material_Uniforms))
	defaults := [Texture_Map]gpu.Texture{.Base_Color = r.no_matcap, .Orm = r.no_matcap, .Normal = r.no_normal_map}
	samplers := [5]gpu.Texture_Sampler_Binding{{texture = item.matcap if item.matcap != 0 else r.no_matcap, sampler = r.matcap_sampler}, environment_binding(r), {}, {}, {}}
	for m in Texture_Map do samplers[2 + int(m)] = {texture = tm.maps[m] if tm.maps[m] != 0 else defaults[m], sampler = r.texture_sampler}
	gpu.bind_fragment_samplers(pass, 0, &samplers[0], len(samplers))
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
