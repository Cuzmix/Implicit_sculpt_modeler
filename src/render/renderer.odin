// Package render owns every GPU object the app creates directly (the ImGui backend
// owns its own). It draws the sculpt viewport into an offscreen texture that the UI
// then displays; it never reads or writes UI state.
package render

import "core:log"
import sdl "vendor:sdl3"

import "../geom"

Mat4 :: matrix[4, 4]f32

VIEWPORT_COLOR_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

Renderer :: struct {
	device:        ^sdl.GPUDevice,
	window:        ^sdl.Window,
	depth_format:  sdl.GPUTextureFormat,
	mesh_pipeline: ^sdl.GPUGraphicsPipeline,
}

// Offscreen colour + depth pair the 3D viewport renders into. Recreated on resize.
Viewport_Target :: struct {
	color:  ^sdl.GPUTexture,
	depth:  ^sdl.GPUTexture,
	width:  u32,
	height: u32,
}

// GPU copy of a geom.Mesh. Positions and normals live in separate vertex buffers so
// either can be re-uploaded alone; the transfer buffer is sized for a full upload.
Mesh_Buffers :: struct {
	positions:       ^sdl.GPUBuffer,
	normals:         ^sdl.GPUBuffer,
	indices:         ^sdl.GPUBuffer,
	transfer:        ^sdl.GPUTransferBuffer,
	vertex_capacity: u32,
	index_count:     u32,
}

// Matches Frame_Uniforms in mesh.vert (std140: two column-major mat4).
Frame_Uniforms :: struct {
	view_proj: Mat4,
	view:      Mat4,
}

// Matches Material_Uniforms in mesh.frag.
Material_Uniforms :: struct {
	base_color: [4]f32,
	params:     [4]f32, // x: ambient, y: specular strength, z: specular power
}

MESH_VERT_SPV :: #load("shaders/mesh.vert.spv")
MESH_FRAG_SPV :: #load("shaders/mesh.frag.spv")

renderer_init :: proc(r: ^Renderer, window: ^sdl.Window, debug: bool) -> bool {
	r.window = window
	r.device = sdl.CreateGPUDevice({.SPIRV}, debug, nil)
	if r.device == nil {
		log.errorf("CreateGPUDevice failed: %s", sdl.GetError())
		return false
	}
	log.infof("GPU driver: %s", sdl.GetGPUDeviceDriver(r.device))
	if !sdl.ClaimWindowForGPUDevice(r.device, window) {
		log.errorf("ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		return false
	}

	r.depth_format = .D32_FLOAT
	if !sdl.GPUTextureSupportsFormat(r.device, r.depth_format, .D2, {.DEPTH_STENCIL_TARGET}) {
		r.depth_format = .D24_UNORM
	}

	r.mesh_pipeline = create_mesh_pipeline(r)
	return r.mesh_pipeline != nil
}

// Waits for the GPU, then releases everything the renderer created, in reverse order.
renderer_destroy :: proc(r: ^Renderer) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	if r.mesh_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.mesh_pipeline)
	sdl.ReleaseWindowFromGPUDevice(r.device, r.window)
	sdl.DestroyGPUDevice(r.device)
	r^ = {}
}

@(private)
create_mesh_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size           = len(MESH_VERT_SPV),
		code                = raw_data(MESH_VERT_SPV),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size           = len(MESH_FRAG_SPV),
		code                = raw_data(MESH_FRAG_SPV),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .FRAGMENT,
		num_uniform_buffers = 1,
	})
	// Shaders are only needed until the pipeline is built.
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil {
		log.errorf("CreateGPUShader failed: %s", sdl.GetError())
		return nil
	}

	buffers := [2]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of(geom.Vec3), input_rate = .VERTEX},
		{slot = 1, pitch = size_of(geom.Vec3), input_rate = .VERTEX},
	}
	attributes := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .FLOAT3},
	}
	color_targets := [1]sdl.GPUColorTargetDescription{{format = VIEWPORT_COLOR_FORMAT}}

	pipeline := sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = len(buffers),
			vertex_attributes = &attributes[0],
			num_vertex_attributes = len(attributes),
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .BACK, front_face = .COUNTER_CLOCKWISE},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {
			color_target_descriptions = &color_targets[0],
			num_color_targets = len(color_targets),
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == nil {
		log.errorf("CreateGPUGraphicsPipeline failed: %s", sdl.GetError())
	}
	return pipeline
}

// Ensures the target matches the requested size. Old textures are released; SDL_GPU
// defers the actual free until in-flight command buffers no longer reference them.
viewport_target_resize :: proc(r: ^Renderer, vt: ^Viewport_Target, requested_width, requested_height: u32) -> bool {
	width, height := max(requested_width, 1), max(requested_height, 1)
	if vt.color != nil && vt.width == width && vt.height == height do return true
	viewport_target_destroy(r, vt)

	vt.color = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
	})
	vt.depth = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
	})
	if vt.color == nil || vt.depth == nil {
		log.errorf("viewport target creation failed: %s", sdl.GetError())
		viewport_target_destroy(r, vt)
		return false
	}
	vt.width, vt.height = width, height
	return true
}

viewport_target_destroy :: proc(r: ^Renderer, vt: ^Viewport_Target) {
	if vt.color != nil do sdl.ReleaseGPUTexture(r.device, vt.color)
	if vt.depth != nil do sdl.ReleaseGPUTexture(r.device, vt.depth)
	vt^ = {}
}

mesh_buffers_create :: proc(r: ^Renderer, mesh: geom.Mesh) -> (mb: Mesh_Buffers, ok: bool) {
	vcount := u32(len(mesh.positions))
	icount := u32(len(mesh.indices))
	vbytes := vcount * size_of(geom.Vec3)
	ibytes := icount * size_of(u32)

	mb.vertex_capacity = vcount
	mb.index_count = icount
	mb.positions = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = vbytes})
	mb.normals = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = vbytes})
	mb.indices = sdl.CreateGPUBuffer(r.device, {usage = {.INDEX}, size = ibytes})
	// Large enough for positions + normals, or for the index data on first upload.
	mb.transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = max(2 * vbytes, ibytes)})
	if mb.positions == nil || mb.normals == nil || mb.indices == nil || mb.transfer == nil {
		log.errorf("mesh buffer creation failed: %s", sdl.GetError())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}

	// One-off upload of the index buffer on its own command buffer.
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	dst := cast([^]u32)sdl.MapGPUTransferBuffer(r.device, mb.transfer, false)
	copy(dst[:icount], mesh.indices[:])
	sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer}, {buffer = mb.indices, size = ibytes}, false)
	sdl.EndGPUCopyPass(pass)
	ok = sdl.SubmitGPUCommandBuffer(cmd)
	return mb, ok
}

mesh_buffers_destroy :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.positions != nil do sdl.ReleaseGPUBuffer(r.device, mb.positions)
	if mb.normals != nil do sdl.ReleaseGPUBuffer(r.device, mb.normals)
	if mb.indices != nil do sdl.ReleaseGPUBuffer(r.device, mb.indices)
	if mb.transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.transfer)
	mb^ = {}
}

// Records a copy of vertices [first, first+count) of positions and normals into `cmd`.
// The transfer buffer is cycled so an upload never stalls on the previous frame's copy.
mesh_buffers_upload_vertices :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, mesh: geom.Mesh, first, count: u32) {
	if count == 0 do return
	assert(first + count <= mb.vertex_capacity)
	bytes := count * size_of(geom.Vec3)
	offset := first * size_of(geom.Vec3)

	dst := cast([^]geom.Vec3)sdl.MapGPUTransferBuffer(r.device, mb.transfer, true)
	copy(dst[:count], mesh.positions[first:first + count])
	copy(dst[count:2 * count], mesh.normals[first:first + count])
	sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)

	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = 0}, {buffer = mb.positions, offset = offset, size = bytes}, false)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = bytes}, {buffer = mb.normals, offset = offset, size = bytes}, false)
	sdl.EndGPUCopyPass(pass)
}

// Records the viewport render pass: clear, then draw the mesh with the clay material.
render_viewport :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: Viewport_Target, mb: Mesh_Buffers, view, proj: Mat4) {
	color := sdl.GPUColorTargetInfo {
		texture     = vt.color,
		clear_color = {0.16, 0.17, 0.19, 1},
		load_op     = .CLEAR,
		store_op    = .STORE,
		cycle       = true,
	}
	depth := sdl.GPUDepthStencilTargetInfo {
		texture          = vt.depth,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
		cycle            = true,
	}
	pass := sdl.BeginGPURenderPass(cmd, &color, 1, &depth)
	defer sdl.EndGPURenderPass(pass)

	frame := Frame_Uniforms{view_proj = proj * view, view = view}
	material := Material_Uniforms{base_color = {0.55, 0.40, 0.32, 1}, params = {0.08, 0.2, 40, 0}}
	sdl.PushGPUVertexUniformData(cmd, 0, &frame, size_of(frame))
	sdl.PushGPUFragmentUniformData(cmd, 0, &material, size_of(material))

	sdl.BindGPUGraphicsPipeline(pass, r.mesh_pipeline)
	vbufs := [2]sdl.GPUBufferBinding{{buffer = mb.positions}, {buffer = mb.normals}}
	sdl.BindGPUVertexBuffers(pass, 0, &vbufs[0], len(vbufs))
	sdl.BindGPUIndexBuffer(pass, {buffer = mb.indices}, ._32BIT)
	sdl.DrawGPUIndexedPrimitives(pass, mb.index_count, 1, 0, 0, 0)
}
