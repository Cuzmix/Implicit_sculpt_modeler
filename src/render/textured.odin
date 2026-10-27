package render

import "core:log"
import "core:math/bits"
import sdl "vendor:sdl3"

// The textured preview: a small mesh of its own for an object whose maps were baked or
// loaded (a retopologized object's quads, split where its UVs are, research-3-pbr.md
// section 7), drawn with textured.vert and textured.frag in place of the object's sculpt
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
	vertices:        ^sdl.GPUBuffer,
	indices:         ^sdl.GPUBuffer,
	transfer:        ^sdl.GPUTransferBuffer,
	vertex_capacity: u32, // vertices
	index_capacity:  u32, // indices
	transfer_size:   u32, // bytes
	index_count:     u32,
	maps:            [Texture_Map]^sdl.GPUTexture, // nil: none (a default is bound)
	sizes:           [Texture_Map][2]u32,
	stamp:           u64, // changes whenever the vertices or indices do
	maps_stamp:      u64, // changes whenever a map does
}

TEXTURE_FORMATS := [Texture_Map]sdl.GPUTextureFormat {
	.Base_Color = .R8G8B8A8_UNORM_SRGB,
	.Orm        = .R8G8B8A8_UNORM,
	.Normal     = .R8G8B8A8_UNORM,
}

// Copies `vertices` and `indices` into the mesh's buffers in a copy pass on `cmd`, growing
// them (and waiting for the GPU before the old ones go) when they are too small. False,
// with the reason logged and the mesh left drawing nothing, when the device refuses.
textured_mesh_upload :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, tm: ^Textured_Mesh, vertices: []Textured_Vertex, indices: []u32) -> bool {
	vbytes, ibytes := u32(len(vertices) * size_of(Textured_Vertex)), u32(len(indices) * size_of(u32))
	if vbytes == 0 || ibytes == 0 {
		tm.index_count = 0
		return true
	}
	if u32(len(vertices)) > tm.vertex_capacity || u32(len(indices)) > tm.index_capacity || vbytes + ibytes > tm.transfer_size {
		_ = sdl.WaitForGPUIdle(r.device)
		textured_buffers_release(r, tm)
		tm.vertex_capacity = u32(1) << u32(bits.log2(uint(len(vertices))) + 1)
		tm.index_capacity = u32(1) << u32(bits.log2(uint(len(indices))) + 1)
		tm.transfer_size = tm.vertex_capacity * size_of(Textured_Vertex) + tm.index_capacity * size_of(u32)
		tm.vertices = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = tm.vertex_capacity * size_of(Textured_Vertex)})
		tm.indices = sdl.CreateGPUBuffer(r.device, {usage = {.INDEX}, size = tm.index_capacity * size_of(u32)})
		tm.transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = tm.transfer_size})
		if tm.vertices == nil || tm.indices == nil || tm.transfer == nil {
			log.errorf("textured mesh buffers: %s", sdl.GetError())
			textured_buffers_release(r, tm)
			return false
		}
	}
	// Cycled, so a frame still reading the last upload keeps its copy.
	dst := ([^]u8)(sdl.MapGPUTransferBuffer(r.device, tm.transfer, true))
	if dst == nil {
		log.errorf("textured mesh upload: %s", sdl.GetError())
		tm.index_count = 0
		return false
	}
	copy(dst[:vbytes], ([^]u8)(raw_data(vertices))[:vbytes])
	copy(dst[vbytes:][:ibytes], ([^]u8)(raw_data(indices))[:ibytes])
	sdl.UnmapGPUTransferBuffer(r.device, tm.transfer)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = tm.transfer}, {buffer = tm.vertices, size = vbytes}, false)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = tm.transfer, offset = vbytes}, {buffer = tm.indices, size = ibytes}, false)
	sdl.EndGPUCopyPass(pass)
	tm.index_count = u32(len(indices))
	r.last_version += 1
	tm.stamp = r.last_version
	return true
}

// Sets map `m` from RGBA8 `pixels` (`width` by `height`, rows top to bottom) with a full
// mip chain, or removes it for nil pixels. The upload has a command buffer of its own and
// waits for it, like a MatCap's. False, with the map left out and the reason logged,
// when the device refuses.
textured_mesh_set_map :: proc(r: ^Renderer, tm: ^Textured_Mesh, m: Texture_Map, pixels: []u8, width, height: int) -> bool {
	if tm.maps[m] != nil {
		_ = sdl.WaitForGPUIdle(r.device)
		sdl.ReleaseGPUTexture(r.device, tm.maps[m])
		tm.maps[m], tm.sizes[m] = nil, {}
	}
	r.last_version += 1
	tm.maps_stamp = r.last_version
	if pixels == nil do return true
	tex := texture_create(r, TEXTURE_FORMATS[m], pixels, width, height)
	if tex == nil do return false
	tm.maps[m], tm.sizes[m] = tex, {u32(width), u32(height)}
	return true
}

// Waits for the GPU and releases everything the mesh holds.
textured_mesh_destroy :: proc(r: ^Renderer, tm: ^Textured_Mesh) {
	if tm.vertices == nil && tm.maps == {} do return
	_ = sdl.WaitForGPUIdle(r.device)
	textured_buffers_release(r, tm)
	for tex in tm.maps do if tex != nil do sdl.ReleaseGPUTexture(r.device, tex)
	tm^ = {}
}

@(private = "file")
textured_buffers_release :: proc(r: ^Renderer, tm: ^Textured_Mesh) {
	if tm.vertices != nil do sdl.ReleaseGPUBuffer(r.device, tm.vertices)
	if tm.indices != nil do sdl.ReleaseGPUBuffer(r.device, tm.indices)
	if tm.transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, tm.transfer)
	tm.vertices, tm.indices, tm.transfer = nil, nil, nil
	tm.vertex_capacity, tm.index_capacity, tm.transfer_size, tm.index_count = 0, 0, 0, 0
}

// Whether `item` draws through its textured mesh: it has one with something in it, a
// view that shows it, and the device made the textured pipeline.
@(private)
draws_textured :: proc(pipes: ^Mesh_Pipelines, item: Draw_Item) -> bool {
	return item.textured != nil && item.texture_view != .Off && item.textured.index_count > 0 && pipes.textured != nil
}

// Draws `item` from its textured mesh with the textured pipeline (bound by the caller),
// its maps bound after the MatCap and defaults for the ones it lacks.
@(private)
draw_textured_item :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, item: Draw_Item, frame: ^Frame_Uniforms, material: ^Material_Uniforms, stats: ^Viewport_Stats) {
	tm := item.textured
	for m in Texture_Map do material.maps[int(m)] = 1 if tm.maps[m] != nil else 0
	material.maps.w = f32(item.texture_view)
	sdl.PushGPUVertexUniformData(cmd, 0, frame, size_of(Frame_Uniforms))
	sdl.PushGPUFragmentUniformData(cmd, 0, material, size_of(Material_Uniforms))
	defaults := [Texture_Map]^sdl.GPUTexture{.Base_Color = r.no_matcap, .Orm = r.no_matcap, .Normal = r.no_normal_map}
	samplers := [4]sdl.GPUTextureSamplerBinding{{texture = item.matcap if item.matcap != nil else r.no_matcap, sampler = r.matcap_sampler}, {}, {}, {}}
	for m in Texture_Map do samplers[1 + int(m)] = {texture = tm.maps[m] if tm.maps[m] != nil else defaults[m], sampler = r.texture_sampler}
	sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], len(samplers))
	vbuf := sdl.GPUBufferBinding{buffer = tm.vertices}
	sdl.BindGPUVertexBuffers(pass, 0, &vbuf, 1)
	sdl.BindGPUIndexBuffer(pass, {buffer = tm.indices}, ._32BIT)
	sdl.DrawGPUIndexedPrimitives(pass, tm.index_count, 1, 0, 0, 0)
	if stats == nil do return
	stats.triangles += u64(tm.index_count / 3)
	stats.draws += 1
}

// Makes a sampled texture of `format` from RGBA8 `pixels` (`width` by `height`, rows top
// to bottom) with a full mip chain built on the GPU. Nil, with the reason logged, when
// the device refuses.
@(private)
texture_create :: proc(r: ^Renderer, format: sdl.GPUTextureFormat, pixels: []u8, width, height: int) -> ^sdl.GPUTexture {
	assert(width > 0 && height > 0 && len(pixels) == width * height * 4)
	levels := u32(bits.log2(uint(max(width, height)))) + 1
	tex := sdl.CreateGPUTexture(r.device, {
		type = .D2, format = format, usage = {.SAMPLER, .COLOR_TARGET},
		width = u32(width), height = u32(height), layer_count_or_depth = 1, num_levels = levels,
	})
	if tex == nil {
		log.errorf("texture %d x %d: %s", width, height, sdl.GetError())
		return nil
	}
	if !texture_upload(r, tex, pixels, width, height, mips = levels > 1) {
		sdl.ReleaseGPUTexture(r.device, tex)
		return nil
	}
	return tex
}
