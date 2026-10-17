// Package render owns every GPU object the app creates directly (the ImGui backend
// owns its own). It draws the sculpt viewport into an offscreen texture that the UI
// then displays; it never reads or writes UI state.
package render

import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import sdl "vendor:sdl3"

import "../geom"

Mat4 :: matrix[4, 4]f32
IDENTITY :: Mat4(1)

VIEWPORT_COLOR_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

Renderer :: struct {
	device:        ^sdl.GPUDevice,
	window:        ^sdl.Window,
	depth_format:  sdl.GPUTextureFormat,
	mesh_pipeline:  ^sdl.GPUGraphicsPipeline,
	clear_pipeline: ^sdl.GPUGraphicsPipeline, // clears a scissored rectangle to the background
	last_version:   u64,  // source of Mesh_Buffers.version
	cull:           bool, // skip off-screen and back-facing chunks of items that have them
	partial:        bool, // while the camera and objects stay put, redraw only what changed
	present_mode:   sdl.GPUPresentMode, // how frames reach the screen; see renderer_set_vsync
}

// Viewport background, linear values written as-is (like the mesh shader's output).
BACKGROUND :: [4]f32{0.16, 0.17, 0.19, 1}

// A partial redraw is skipped in favour of a full one when the changed rectangle
// covers more than this share of the viewport.
PARTIAL_MAX_AREA :: 0.6

// Offscreen colour + depth pair the 3D viewport renders into. Recreated on resize.
Viewport_Target :: struct {
	color:  ^sdl.GPUTexture,
	depth:  ^sdl.GPUTexture,
	width:  u32,
	height: u32,
	cache:  Static_Cache,
	// Identifies what color and depth hold: camera, size, and every item's identity,
	// transform and colour (not its contents, which Draw_Item.damage accounts for).
	// 0 when they hold nothing reusable.
	frame_key: u64,
}

// Colour and depth of everything that is not `live`, as last drawn. While the camera
// and those objects stay put (all through a brush stroke), each frame copies this in
// and draws only the live objects on top, so idle meshes cost a screen-sized copy
// instead of all their triangles.
Static_Cache :: struct {
	color: ^sdl.GPUTexture,
	depth: ^sdl.GPUTexture,
	key:   u64, // hash of what the textures hold; 0 when they hold nothing
}

// GPU copy of a geom.Mesh. Positions (3 floats) and normals (octahedral, 2 snorm16)
// live in separate vertex buffers: 16 bytes a vertex. The transfer buffer is sized for
// typical per-frame sculpt updates, not the whole mesh; bigger uploads go through it
// in chunks.
Mesh_Buffers :: struct {
	positions:       ^sdl.GPUBuffer,
	normals:         ^sdl.GPUBuffer,
	indices:         ^sdl.GPUBuffer,
	transfer:        ^sdl.GPUTransferBuffer,
	transfer_size:   u32,
	vertex_capacity: u32,
	index_count:     u32,
	version:         u64, // changes whenever the buffers' contents do
	drawn_version:   u64, // version when last drawn into the viewport

	// Culled drawing: one indirect draw command per visible run of chunks, rebuilt
	// each frame the mesh is drawn. Created on first use, sized for every chunk.
	indirect:          ^sdl.GPUBuffer,
	indirect_transfer: ^sdl.GPUTransferBuffer,
	indirect_capacity: u32, // commands
	draw_count:        u32, // commands recorded this frame
	visible:           [dynamic]geom.Index_Range, // scratch
}

Normal_Packed :: [2]i16
VERTEX_BYTES :: size_of(geom.Vec3) + size_of(Normal_Packed)

// 16 MB holds positions and normals for 1M vertices: far more than a frame of
// sculpting changes, even with a large brush on a 10M vertex mesh.
TRANSFER_BUFFER_SIZE :: 16 << 20

// Matches Frame_Uniforms in mesh.vert (std140: column-major mat4s). Pushed per draw.
Frame_Uniforms :: struct {
	view_proj: Mat4,
	view:      Mat4,
	model:     Mat4,
}

// One mesh to draw this frame: where it sits in the world and its clay colour.
// `live` marks the object being worked on; everything else may come from the cache.
// With `chunks` (in index-buffer order, covering the mesh) and Renderer.cull, only the
// chunks that can be seen are drawn; `model` must then be translation plus uniform
// scale, as the culling transforms the eye into the mesh's space with its inverse.
Draw_Item :: struct {
	mesh:   ^Mesh_Buffers,
	model:  Mat4,
	color:  [4]f32,
	live:   bool,
	chunks: []geom.Chunk,
	// Mesh-space box around everything that changed since the previous frame, before
	// and after the change; empty (lo > hi) when nothing did. A mesh whose buffers
	// changed without a damage box makes the next frame a full redraw.
	damage: geom.Aabb,
}

// What render_viewport did this frame, for the stats panel.
Viewport_Stats :: struct {
	triangles:     u64,  // triangles submitted
	draws:         u64,  // draw commands (indirect ones counted one by one)
	chunks:        u64,  // chunks considered for culling
	culled_view:   u64,  // ...outside the view
	culled_back:   u64,  // ...facing away
	cull_ms:       f64,  // CPU time spent culling and writing draw commands
	partial:       bool, // kept the previous frame and redrew only `redrawn_px` pixels
	redrawn_px:    u64,
	cache_used:    bool, // idle objects came from the cache
	cache_redrawn: bool, // ...which had to be redrawn first
}

// Matches Material_Uniforms in mesh.frag.
Material_Uniforms :: struct {
	base_color: [4]f32,
	params:     [4]f32, // x: ambient, y: specular strength, z: specular power
}

MESH_VERT_SPV :: #load("shaders/mesh.vert.spv")
MESH_FRAG_SPV :: #load("shaders/mesh.frag.spv")
CLEAR_VERT_SPV :: #load("shaders/clear.vert.spv")
CLEAR_FRAG_SPV :: #load("shaders/clear.frag.spv")

renderer_init :: proc(r: ^Renderer, window: ^sdl.Window, debug: bool) -> bool {
	r.window = window
	r.device = sdl.CreateGPUDevice({.SPIRV}, debug, nil)
	if r.device == nil {
		log.errorf("CreateGPUDevice failed: %s", sdl.GetError())
		return false
	}
	log.infof("GPU: %s", gpu_description(r))
	if !sdl.ClaimWindowForGPUDevice(r.device, window) {
		log.errorf("ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		return false
	}

	r.depth_format = .D32_FLOAT
	if !sdl.GPUTextureSupportsFormat(r.device, r.depth_format, .D2, {.DEPTH_STENCIL_TARGET}) {
		r.depth_format = .D24_UNORM
	}

	r.mesh_pipeline = create_mesh_pipeline(r)
	r.clear_pipeline = create_clear_pipeline(r)
	return r.mesh_pipeline != nil && r.clear_pipeline != nil
}

// The GPU's name, backend and driver version, for logs and benchmark reports.
// Temp-allocated.
gpu_description :: proc(r: ^Renderer) -> string {
	props := sdl.GetGPUDeviceProperties(r.device)
	name := sdl.GetStringProperty(props, sdl.PROP_GPU_DEVICE_NAME_STRING, "unknown GPU")
	version := sdl.GetStringProperty(props, sdl.PROP_GPU_DEVICE_DRIVER_VERSION_STRING, "unknown")
	return fmt.tprintf("%s (%s, driver %s)", name, sdl.GetGPUDeviceDriver(r.device), version)
}

// Picks how frames reach the screen. With vsync (the default), a frame waits for the
// display's refresh: no tearing, and the frame rate is capped at the refresh rate.
// Without, a frame is shown as soon as it is ready: mailbox where the window offers it
// (no tearing; a newer frame replaces one still waiting), else immediate (may tear).
// Returns false, keeping the current mode, when the window offers neither or the
// change fails. Recreates the swapchain, so it must not be called while a swapchain
// texture is acquired.
renderer_set_vsync :: proc(r: ^Renderer, vsync: bool) -> bool {
	mode := sdl.GPUPresentMode.VSYNC
	if !vsync {
		switch {
		case sdl.WindowSupportsGPUPresentMode(r.device, r.window, .MAILBOX):
			mode = .MAILBOX
		case sdl.WindowSupportsGPUPresentMode(r.device, r.window, .IMMEDIATE):
			mode = .IMMEDIATE
		case:
			log.warn("vsync stays on: the display offers no other present mode")
			return false
		}
	}
	if mode == r.present_mode do return true
	if !sdl.SetGPUSwapchainParameters(r.device, r.window, .SDR, mode) {
		log.errorf("SetGPUSwapchainParameters failed: %s", sdl.GetError())
		return false
	}
	r.present_mode = mode
	log.infof("present mode: %v", mode)
	return true
}

// Waits for the GPU, then releases everything the renderer created, in reverse order.
renderer_destroy :: proc(r: ^Renderer) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	if r.mesh_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.mesh_pipeline)
	if r.clear_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.clear_pipeline)
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
		{slot = 1, pitch = size_of(Normal_Packed), input_rate = .VERTEX},
	}
	attributes := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3},
		{location = 1, buffer_slot = 1, format = .SHORT2_NORM},
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

@(private)
create_clear_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size = len(CLEAR_VERT_SPV), code = raw_data(CLEAR_VERT_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .VERTEX,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size = len(CLEAR_FRAG_SPV), code = raw_data(CLEAR_FRAG_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .FRAGMENT, num_uniform_buffers = 1,
	})
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil {
		log.errorf("CreateGPUShader failed: %s", sdl.GetError())
		return nil
	}
	color_targets := [1]sdl.GPUColorTargetDescription{{format = VIEWPORT_COLOR_FORMAT}}
	pipeline := sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		// Writes far-plane depth everywhere it lands, whatever was there.
		depth_stencil_state = {compare_op = .ALWAYS, enable_depth_test = true, enable_depth_write = true},
		target_info = {
			color_target_descriptions = &color_targets[0],
			num_color_targets = len(color_targets),
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	})
	if pipeline == nil {
		log.errorf("CreateGPUGraphicsPipeline (clear) failed: %s", sdl.GetError())
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
	if vt.cache.color != nil do sdl.ReleaseGPUTexture(r.device, vt.cache.color)
	if vt.cache.depth != nil do sdl.ReleaseGPUTexture(r.device, vt.cache.depth)
	vt^ = {}
}

// Creates the cache textures on first use, at the target's size. They are released
// with the target, so a resize recreates them.
@(private)
static_cache_ensure :: proc(r: ^Renderer, vt: ^Viewport_Target) -> bool {
	if vt.cache.color != nil do return true
	vt.cache.color = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	vt.cache.depth = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	vt.cache.key = 0
	if vt.cache.color == nil || vt.cache.depth == nil {
		log.errorf("viewport cache creation failed: %s", sdl.GetError())
		if vt.cache.color != nil do sdl.ReleaseGPUTexture(r.device, vt.cache.color)
		if vt.cache.depth != nil do sdl.ReleaseGPUTexture(r.device, vt.cache.depth)
		vt.cache = {}
		return false
	}
	return true
}

// Creates the GPU buffers for `mesh` and uploads all of it, in chunks through the
// transfer buffer, waiting for the GPU after each chunk. For loading, not per frame.
mesh_buffers_create :: proc(r: ^Renderer, mesh: geom.Mesh) -> (mb: Mesh_Buffers, ok: bool) {
	vcount := u32(len(mesh.positions))
	icount := u32(len(mesh.indices))
	vbytes := vcount * size_of(geom.Vec3)
	nbytes := vcount * size_of(Normal_Packed)
	ibytes := icount * size_of(u32)

	mb.vertex_capacity = vcount
	mb.index_count = icount
	r.last_version += 1
	mb.version = r.last_version
	mb.transfer_size = TRANSFER_BUFFER_SIZE
	mb.positions = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = vbytes})
	mb.normals = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = nbytes})
	mb.indices = sdl.CreateGPUBuffer(r.device, {usage = {.INDEX}, size = ibytes})
	mb.transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = mb.transfer_size})
	if mb.positions == nil || mb.normals == nil || mb.indices == nil || mb.transfer == nil {
		log.errorf("mesh buffer creation failed: %s", sdl.GetError())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}
	ok = upload_blocking(r, &mb, mb.indices, slice.to_bytes(mesh.indices[:])) &&
		upload_blocking(r, &mb, mb.positions, slice.to_bytes(mesh.positions[:])) &&
		upload_normals_blocking(r, &mb, mesh.normals[:])
	if !ok {
		log.errorf("mesh upload failed: %s", sdl.GetError())
		mesh_buffers_destroy(r, &mb)
		return {}, false
	}
	return mb, true
}

// Copies `data` to the start of `buffer` one transfer buffer at a time.
@(private)
upload_blocking :: proc(r: ^Renderer, mb: ^Mesh_Buffers, buffer: ^sdl.GPUBuffer, data: []u8) -> bool {
	for offset := 0; offset < len(data); offset += int(mb.transfer_size) {
		chunk := data[offset:min(offset + int(mb.transfer_size), len(data))]
		dst := sdl.MapGPUTransferBuffer(r.device, mb.transfer, false)
		if dst == nil do return false
		copy(([^]u8)(dst)[:len(chunk)], chunk)
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		cmd := sdl.AcquireGPUCommandBuffer(r.device)
		if cmd == nil do return false
		pass := sdl.BeginGPUCopyPass(cmd)
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer}, {buffer = buffer, offset = u32(offset), size = u32(len(chunk))}, false)
		sdl.EndGPUCopyPass(pass)
		if !sdl.SubmitGPUCommandBuffer(cmd) || !sdl.WaitForGPUIdle(r.device) do return false
	}
	return true
}

// Packs and copies every normal, one transfer buffer at a time.
@(private)
upload_normals_blocking :: proc(r: ^Renderer, mb: ^Mesh_Buffers, normals: []geom.Vec3) -> bool {
	per_batch := int(mb.transfer_size / size_of(Normal_Packed))
	for first := 0; first < len(normals); first += per_batch {
		batch := normals[first:min(first + per_batch, len(normals))]
		dst := cast([^]Normal_Packed)sdl.MapGPUTransferBuffer(r.device, mb.transfer, false)
		if dst == nil do return false
		for n, i in batch do dst[i] = geom.oct_encode(n)
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		cmd := sdl.AcquireGPUCommandBuffer(r.device)
		if cmd == nil do return false
		pass := sdl.BeginGPUCopyPass(cmd)
		size := u32(len(batch) * size_of(Normal_Packed))
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer}, {buffer = mb.normals, offset = u32(first * size_of(Normal_Packed)), size = size}, false)
		sdl.EndGPUCopyPass(pass)
		if !sdl.SubmitGPUCommandBuffer(cmd) || !sdl.WaitForGPUIdle(r.device) do return false
	}
	return true
}

mesh_buffers_destroy :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.positions != nil do sdl.ReleaseGPUBuffer(r.device, mb.positions)
	if mb.normals != nil do sdl.ReleaseGPUBuffer(r.device, mb.normals)
	if mb.indices != nil do sdl.ReleaseGPUBuffer(r.device, mb.indices)
	if mb.transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.transfer)
	if mb.indirect != nil do sdl.ReleaseGPUBuffer(r.device, mb.indirect)
	if mb.indirect_transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.indirect_transfer)
	delete(mb.visible)
	mb^ = {}
}

// Records copies of the positions and normals of every vertex in `ranges` into `cmd`.
// Ranges are packed into the transfer buffer, which is cycled so an upload never
// stalls on the previous frame's copy; if they do not fit, they go in several batches.
mesh_buffers_upload_ranges :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, mesh: geom.Mesh, ranges: []geom.Vertex_Range) {
	if len(ranges) > 0 {
		r.last_version += 1
		mb.version = r.last_version
	}
	capacity := mb.transfer_size / VERTEX_BYTES // vertices per batch
	pending := ranges
	split: geom.Vertex_Range // remainder of a range cut at a batch boundary
	for len(pending) > 0 || split.count > 0 {
		// Plan a batch: whole ranges, then part of the next if it does not fit.
		Planned :: struct {
			r:   geom.Vertex_Range,
			dst: u32,
		}
		batch: [dynamic; 256]Planned
		used: u32
		for used < capacity && len(batch) < cap(batch) {
			next: geom.Vertex_Range
			if split.count > 0 {
				next, split = split, {}
			} else if len(pending) > 0 {
				next, pending = pending[0], pending[1:]
			} else {
				break
			}
			assert(next.first + next.count <= mb.vertex_capacity)
			if next.count > capacity - used {
				split = {next.first + (capacity - used), next.count - (capacity - used)}
				next.count = capacity - used
			}
			append(&batch, Planned{next, used})
			used += next.count
		}

		// Positions for the batch first, then packed normals, each laid out by range.
		mapped := cast([^]u8)sdl.MapGPUTransferBuffer(r.device, mb.transfer, true)
		dst_p := cast([^]geom.Vec3)mapped
		dst_n := cast([^]Normal_Packed)(mapped[used * size_of(geom.Vec3):])
		for p in batch {
			copy(dst_p[p.dst:][:p.r.count], mesh.positions[p.r.first:][:p.r.count])
			for n, k in mesh.normals[p.r.first:][:p.r.count] do dst_n[p.dst + u32(k)] = geom.oct_encode(n)
		}
		sdl.UnmapGPUTransferBuffer(r.device, mb.transfer)
		pass := sdl.BeginGPUCopyPass(cmd)
		for p in batch {
			src_p := p.dst * size_of(geom.Vec3)
			src_n := used * size_of(geom.Vec3) + p.dst * size_of(Normal_Packed)
			sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = src_p}, {buffer = mb.positions, offset = p.r.first * size_of(geom.Vec3), size = p.r.count * size_of(geom.Vec3)}, false)
			sdl.UploadToGPUBuffer(pass, {transfer_buffer = mb.transfer, offset = src_n}, {buffer = mb.normals, offset = p.r.first * size_of(Normal_Packed), size = p.r.count * size_of(Normal_Packed)}, false)
		}
		sdl.EndGPUCopyPass(pass)
	}
}

// Records the viewport: the live items over everything else. With `use_cache`, the
// other items are drawn into the cache only when they, the camera or the target size
// changed since the cache was filled; otherwise every item is drawn every frame.
//
// With Renderer.partial, a frame whose camera, size and items match the previous one
// keeps the previous colour and depth and redraws only the screen rectangle the items'
// damage boxes cover, or nothing at all when nothing changed.
render_viewport :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, use_cache: bool) -> (stats: Viewport_Stats) {
	key := frame_key(vt^, view, proj, items)
	defer {
		vt.frame_key = key
		for item in items do item.mesh.drawn_version = item.mesh.version
	}
	if r.partial && key == vt.frame_key {
		if rect, ok := damage_rect(vt^, view, proj, items); ok {
			stats.partial = true
			if rect.w > 0 && rect.h > 0 do render_rect(r, cmd, vt, view, proj, items, rect, &stats)
			return
		}
	}
	render_full(r, cmd, vt, view, proj, items, use_cache, &stats)
	return
}

// Pixel rectangle, top-left origin.
@(private)
Rect :: struct {
	x, y, w, h: i32,
}

// The viewport rectangle covering every item's damage box, padded by a couple of
// pixels; zero-sized when nothing on screen changed. ok is false when a full redraw is
// needed instead: an item changed without saying where, a box reaches behind the
// eye, or the rectangle is too large to be worth it.
@(private)
damage_rect :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item) -> (rect: Rect, ok: bool) {
	W, H := f32(vt.width), f32(vt.height)
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{min(f32), min(f32)}
	for item in items {
		b := item.damage
		damaged := b.lo.x <= b.hi.x
		if !damaged {
			if item.mesh.version != item.mesh.drawn_version do return {}, false
			continue
		}
		clip := proj * view * item.model
		for corner in 0 ..< 8 {
			p := [4]f32 {
				b.hi.x if corner & 1 != 0 else b.lo.x,
				b.hi.y if corner & 2 != 0 else b.lo.y,
				b.hi.z if corner & 4 != 0 else b.lo.z,
				1,
			}
			c := clip * p
			if c.w <= 1e-4 do return {}, false
			px := [2]f32{(c.x / c.w * 0.5 + 0.5) * W, (0.5 - c.y / c.w * 0.5) * H}
			lo = linalg.min(lo, px)
			hi = linalg.max(hi, px)
		}
	}
	if lo.x > hi.x do return {}, true // nothing changed
	PAD :: 2
	x0 := i32(clamp(math.floor(lo.x) - PAD, 0, W))
	y0 := i32(clamp(math.floor(lo.y) - PAD, 0, H))
	x1 := i32(clamp(math.ceil(hi.x) + PAD, 0, W))
	y1 := i32(clamp(math.ceil(hi.y) + PAD, 0, H))
	if x1 <= x0 || y1 <= y0 do return {}, true // changed only off screen
	if f32((x1 - x0) * (y1 - y0)) > PARTIAL_MAX_AREA * W * H do return {}, false
	return {x0, y0, x1 - x0, y1 - y0}, true
}

// Redraws one rectangle of the previous frame: clears it, then draws the chunks of
// every item that fall inside it, scissored to it.
@(private)
render_rect :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, rect: Rect, stats: ^Viewport_Stats) {
	// Maps the rectangle to the whole of clip space, so culling against the narrowed
	// frustum keeps only the chunks that can touch it.
	W, H := f32(vt.width), f32(vt.height)
	nx0, nx1 := 2 * f32(rect.x) / W - 1, 2 * f32(rect.x + rect.w) / W - 1
	ny0, ny1 := 1 - 2 * f32(rect.y + rect.h) / H, 1 - 2 * f32(rect.y) / H
	cx, hx := (nx0 + nx1) / 2, (nx1 - nx0) / 2
	cy, hy := (ny0 + ny1) / 2, (ny1 - ny0) / 2
	narrow := Mat4{
		1 / hx, 0, 0, -cx / hx,
		0, 1 / hy, 0, -cy / hy,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	prepare_draws(r, cmd, view, proj, items, nil, stats, narrow)
	pass := begin_mesh_pass(r, cmd, vt.color, vt.depth, load = true, keep_depth = true)
	sdl.SetGPUScissor(pass, {rect.x, rect.y, rect.w, rect.h})
	sdl.BindGPUGraphicsPipeline(pass, r.clear_pipeline)
	background := BACKGROUND
	sdl.PushGPUFragmentUniformData(cmd, 0, &background, size_of(background))
	sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	sdl.BindGPUGraphicsPipeline(pass, r.mesh_pipeline)
	draw_items(r, cmd, pass, view, proj, items, nil, stats)
	sdl.EndGPURenderPass(pass)
	stats.redrawn_px = u64(rect.w) * u64(rect.h)
}

// Hash of what frame_key in Viewport_Target describes.
@(private)
frame_key :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item) -> u64 {
	Keyed :: struct {
		mesh:  ^Mesh_Buffers,
		model: Mat4,
		color: [4]f32,
	}
	Header :: struct {
		view, proj:    Mat4,
		width, height: u32,
		items:         int,
	}
	header := Header{view, proj, vt.width, vt.height, len(items)}
	h := hash.fnv64a(slice.bytes_from_ptr(&header, size_of(header)))
	for item in items {
		k := Keyed{item.mesh, item.model, item.color}
		h = hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
	}
	return max(h, 1)
}

// Redraws the whole viewport: the live items over the idle ones, which come from the
// cache when `use_cache` and they, the camera and the size are unchanged.
@(private)
render_full :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, use_cache: bool, stats: ^Viewport_Stats) {
	live := 0
	for item in items do live += int(item.live)
	// With nothing live (or nothing idle) there is nothing to reuse.
	if !use_cache || live == 0 || live == len(items) || !static_cache_ensure(r, vt) {
		vt.cache.key = 0
		prepare_draws(r, cmd, view, proj, items, nil, stats)
		pass := begin_mesh_pass(r, cmd, vt.color, vt.depth, load = false, keep_depth = true)
		draw_items(r, cmd, pass, view, proj, items, nil, stats)
		sdl.EndGPURenderPass(pass)
		return
	}
	stats.cache_used = true

	key := static_key(vt^, view, proj, items)
	redraw := key != vt.cache.key
	prepare_draws(r, cmd, view, proj, items, nil if redraw else true, stats)
	if redraw {
		pass := begin_mesh_pass(r, cmd, vt.cache.color, vt.cache.depth, load = false, keep_depth = true)
		draw_items(r, cmd, pass, view, proj, items, false, stats)
		sdl.EndGPURenderPass(pass)
		vt.cache.key = key
		stats.cache_redrawn = true
	}

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	for pair in ([2][2]^sdl.GPUTexture{{vt.cache.color, vt.color}, {vt.cache.depth, vt.depth}}) {
		sdl.CopyGPUTextureToTexture(copy_pass, {texture = pair[0]}, {texture = pair[1]}, vt.width, vt.height, 1, cycle = true)
	}
	sdl.EndGPUCopyPass(copy_pass)

	pass := begin_mesh_pass(r, cmd, vt.color, vt.depth, load = true, keep_depth = true)
	draw_items(r, cmd, pass, view, proj, items, true, stats)
	sdl.EndGPURenderPass(pass)
}

// For every item that will be drawn this frame (those whose `live` matches, all of
// them when `live` is nil) and can be culled, culls its chunks against the camera and
// uploads one indirect draw command per visible run. Must run before the render
// passes, since uploads need a copy pass.
// `narrow` maps clip space to a smaller frustum to cull against (see render_rect).
@(private)
prepare_draws :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats, narrow := IDENTITY) {
	if !r.cull do return
	t0 := sdl.GetTicksNS()
	defer stats.cull_ms += f64(sdl.GetTicksNS() - t0) / 1e6
	eye_world := linalg.inverse(view) * [4]f32{0, 0, 0, 1}
	copy_pass: ^sdl.GPUCopyPass
	for item in items {
		if want, filtered := live.?; filtered && item.live != want do continue
		mb := item.mesh
		if len(item.chunks) == 0 || !indirect_ensure(r, mb, u32(len(item.chunks))) do continue
		eye := linalg.inverse(item.model) * eye_world
		clear(&mb.visible)
		cs := geom.cull_chunks(item.chunks, narrow * proj * view * item.model, eye.xyz, &mb.visible)
		stats.chunks += u64(cs.chunks)
		stats.culled_view += u64(cs.frustum)
		stats.culled_back += u64(cs.backface)
		mb.draw_count = u32(len(mb.visible))
		if mb.draw_count == 0 do continue
		dst := cast([^]sdl.GPUIndexedIndirectDrawCommand)sdl.MapGPUTransferBuffer(r.device, mb.indirect_transfer, true)
		for v, i in mb.visible {
			dst[i] = {num_indices = v.index_count, num_instances = 1, first_index = v.first_index}
		}
		sdl.UnmapGPUTransferBuffer(r.device, mb.indirect_transfer)
		if copy_pass == nil do copy_pass = sdl.BeginGPUCopyPass(cmd)
		size := mb.draw_count * size_of(sdl.GPUIndexedIndirectDrawCommand)
		sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = mb.indirect_transfer}, {buffer = mb.indirect, size = size}, true)
	}
	if copy_pass != nil do sdl.EndGPUCopyPass(copy_pass)
}

// Creates the mesh's indirect command buffer for up to `commands` draws. On failure
// the mesh is drawn whole.
@(private)
indirect_ensure :: proc(r: ^Renderer, mb: ^Mesh_Buffers, commands: u32) -> bool {
	if mb.indirect != nil && mb.indirect_capacity >= commands do return true
	if mb.indirect != nil do sdl.ReleaseGPUBuffer(r.device, mb.indirect)
	if mb.indirect_transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.indirect_transfer)
	size := commands * size_of(sdl.GPUIndexedIndirectDrawCommand)
	mb.indirect = sdl.CreateGPUBuffer(r.device, {usage = {.INDIRECT}, size = size})
	mb.indirect_transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = size})
	mb.indirect_capacity = commands
	if mb.indirect == nil || mb.indirect_transfer == nil {
		log.errorf("indirect buffer creation failed: %s", sdl.GetError())
		if mb.indirect != nil do sdl.ReleaseGPUBuffer(r.device, mb.indirect)
		if mb.indirect_transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, mb.indirect_transfer)
		mb.indirect, mb.indirect_transfer, mb.indirect_capacity = nil, nil, 0
		return false
	}
	return true
}

// Identifies the cache contents: the target size, camera, and every idle item's
// buffers (by identity and version), transform and colour.
@(private)
static_key :: proc(vt: Viewport_Target, view, proj: Mat4, items: []Draw_Item) -> u64 {
	Keyed :: struct {
		mesh:    ^Mesh_Buffers,
		version: u64,
		model:   Mat4,
		color:   [4]f32,
	}
	Header :: struct {
		view, proj:    Mat4,
		width, height: u32,
	}
	header := Header{view, proj, vt.width, vt.height}
	h := hash.fnv64a(slice.bytes_from_ptr(&header, size_of(header)))
	for item in items {
		if item.live do continue
		k := Keyed{item.mesh, item.mesh.version, item.model, item.color}
		h = hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
	}
	return max(h, 1) // 0 means empty
}

@(private)
begin_mesh_pass :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, color_tex, depth_tex: ^sdl.GPUTexture, load, keep_depth: bool) -> ^sdl.GPURenderPass {
	color := sdl.GPUColorTargetInfo {
		texture     = color_tex,
		clear_color = sdl.FColor(BACKGROUND),
		load_op     = .LOAD if load else .CLEAR,
		store_op    = .STORE,
		cycle       = !load,
	}
	depth := sdl.GPUDepthStencilTargetInfo {
		texture          = depth_tex,
		clear_depth      = 1,
		load_op          = .LOAD if load else .CLEAR,
		store_op         = .STORE if keep_depth else .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
		cycle            = !load,
	}
	pass := sdl.BeginGPURenderPass(cmd, &color, 1, &depth)
	sdl.BindGPUGraphicsPipeline(pass, r.mesh_pipeline)
	return pass
}

// Draws the items whose `live` flag matches (all of them when `live` is nil) with the
// clay material: the visible runs prepare_draws found, or the whole mesh.
@(private)
draw_items :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, view, proj: Mat4, items: []Draw_Item, live: Maybe(bool), stats: ^Viewport_Stats) {
	for item in items {
		if want, filtered := live.?; filtered && item.live != want do continue
		frame := Frame_Uniforms{view_proj = proj * view, view = view, model = item.model}
		material := Material_Uniforms{base_color = item.color, params = {0.08, 0.2, 40, 0}}
		sdl.PushGPUVertexUniformData(cmd, 0, &frame, size_of(frame))
		sdl.PushGPUFragmentUniformData(cmd, 0, &material, size_of(material))
		mb := item.mesh
		vbufs := [2]sdl.GPUBufferBinding{{buffer = mb.positions}, {buffer = mb.normals}}
		sdl.BindGPUVertexBuffers(pass, 0, &vbufs[0], len(vbufs))
		sdl.BindGPUIndexBuffer(pass, {buffer = mb.indices}, ._32BIT)
		if r.cull && len(item.chunks) > 0 && mb.indirect != nil {
			if mb.draw_count > 0 do sdl.DrawGPUIndexedPrimitivesIndirect(pass, mb.indirect, 0, mb.draw_count)
			for v in mb.visible do stats.triangles += u64(v.index_count / 3)
			stats.draws += u64(mb.draw_count)
		} else {
			sdl.DrawGPUIndexedPrimitives(pass, mb.index_count, 1, 0, 0, 0)
			stats.triangles += u64(mb.index_count / 3)
			stats.draws += 1
		}
	}
}

// Reads the viewport colour back to the CPU (RGBA8, rows top to bottom), waiting for
// the GPU. For tests and debugging, not per frame. Returns nil on failure.
viewport_download :: proc(r: ^Renderer, vt: ^Viewport_Target, allocator := context.allocator) -> []u8 {
	size := vt.width * vt.height * 4
	transfer := sdl.CreateGPUTransferBuffer(r.device, {usage = .DOWNLOAD, size = size})
	if transfer == nil do return nil
	defer sdl.ReleaseGPUTransferBuffer(r.device, transfer)
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil do return nil
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(pass, {texture = vt.color, w = vt.width, h = vt.height, d = 1}, {transfer_buffer = transfer})
	sdl.EndGPUCopyPass(pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) || !sdl.WaitForGPUIdle(r.device) do return nil
	src := sdl.MapGPUTransferBuffer(r.device, transfer, false)
	if src == nil do return nil
	pixels := make([]u8, size, allocator)
	copy(pixels, ([^]u8)(src)[:size])
	sdl.UnmapGPUTransferBuffer(r.device, transfer)
	return pixels
}
