package render

import "base:intrinsics"
import "core:log"

import sdl "vendor:sdl3"

UI_VERT_CODE :: #load("shaders/ui.vert" + SHADER_EXT)
UI_FRAG_CODE :: #load("shaders/ui.frag" + SHADER_EXT)

// One corner of an interface triangle, as the app's interface kit makes them (it mirrors
// ui.Vertex; render does not import the kit). Matches ui.vert.slang.
Ui_Vertex :: struct {
	pos:   [2]f32, // physical pixels from the target's top-left
	uv:    [2]f32, // atlas pixels, or 0 to 1 across an image
	color: [4]u8,
}

// A run of indices drawn with one texture and one clip rectangle (pixels).
Ui_Draw :: struct {
	first_index: u32,
	index_count: u32,
	clip:        [4]i32, // x, y, width, height
	image:       ^sdl.GPUTexture, // nil draws from the glyph atlas
	// The image is drawn larger than shown over a clear of nothing (the navigation head):
	// filtered, which averages its samples, and with its colour taken back out of its
	// alpha, so its edge does not darken.
	smooth:      bool,
}

// What the interface needs on the GPU: its pipelines (one per target format, made on
// first use), the glyph atlas, and vertex and index buffers grown to the largest frame.
Ui_Pass :: struct {
	formats:      [2]sdl.GPUTextureFormat,
	pipelines:    [2]^sdl.GPUGraphicsPipeline,
	sampler:      ^sdl.GPUSampler,
	smooth:       ^sdl.GPUSampler, // filtering, for Ui_Draw.smooth
	atlas:        ^sdl.GPUTexture,
	atlas_size:   [2]u32,
	vertices:     ^sdl.GPUBuffer,
	indices:      ^sdl.GPUBuffer,
	vertex_bytes: u32, // capacities
	index_bytes:  u32,
	transfer:     ^sdl.GPUTransferBuffer,
	transfer_bytes: u32,
}

@(private = "file")
Ui_Vertex_Uniforms :: struct {
	target: [4]f32, // xy the size in pixels the triangles are laid out in, zw the turn's cosine and sine
}

@(private = "file")
Ui_Fragment_Uniforms :: struct {
	params: [4]f32,
}

ui_pass_destroy :: proc(r: ^Renderer, up: ^Ui_Pass) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	for p in up.pipelines do if p != nil do gpu_release_graphics_pipeline(r.device, p)
	if up.sampler != nil do gpu_release_sampler(r.device, up.sampler)
	if up.smooth != nil do gpu_release_sampler(r.device, up.smooth)
	if up.atlas != nil do gpu_release_texture(r.device, up.atlas)
	if up.vertices != nil do gpu_release_buffer(r.device, up.vertices)
	if up.indices != nil do gpu_release_buffer(r.device, up.indices)
	if up.transfer != nil do gpu_release_transfer_buffer(r.device, up.transfer)
	up^ = {}
}

// Copies this frame's triangles, and the part of the glyph atlas that changed, to the
// GPU in a copy pass on `cmd`; it must come before the render pass that draws them.
// `atlas` is the kit's whole single-channel atlas, `dirty` the rectangle (x0, y0, x1,
// y1) that changed, `atlas_changed` false when nothing did. A new atlas size uploads
// all of it.
ui_pass_upload :: proc(r: ^Renderer, up: ^Ui_Pass, cmd: ^sdl.GPUCommandBuffer, vertices: []Ui_Vertex, indices: []u32, atlas: []u8, atlas_size: [2]u32, dirty: [4]int, atlas_changed: bool) -> bool {
	debug_group(cmd, "Interface upload", .Interface)
	if up.sampler == nil {
		// Nearest: glyphs sit on whole pixels and the viewport image is shown pixel for
		// pixel, so nothing is ever blurred by filtering.
		up.sampler = gpu_create_sampler(r.device, {
			min_filter = .NEAREST, mag_filter = .NEAREST, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		if up.sampler == nil {
			log.errorf("ui sampler: %s", sdl.GetError())
			return false
		}
	}
	if up.smooth == nil {
		up.smooth = gpu_create_sampler(r.device, {
			min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		if up.smooth == nil {
			log.errorf("ui sampler: %s", sdl.GetError())
			return false
		}
	}
	dirty := dirty
	upload_atlas := atlas_changed
	if up.atlas == nil || up.atlas_size != atlas_size {
		if up.atlas != nil {
			_ = gpu_wait_for_idle(r.device)
			gpu_release_texture(r.device, up.atlas)
		}
		up.atlas = gpu_create_texture(r.device, {
			type = .D2, format = .R8_UNORM, usage = {.SAMPLER},
			width = atlas_size.x, height = atlas_size.y, layer_count_or_depth = 1, num_levels = 1,
		})
		if up.atlas == nil {
			log.errorf("ui atlas: %s", sdl.GetError())
			return false
		}
		up.atlas_size = atlas_size
		dirty, upload_atlas = {0, 0, int(atlas_size.x), int(atlas_size.y)}, true
	}
	vb := u32(len(vertices) * size_of(Ui_Vertex))
	ib := u32(len(indices) * size_of(u32))
	if !grow_buffer(r, &up.vertices, &up.vertex_bytes, vb, {.VERTEX}) do return false
	if !grow_buffer(r, &up.indices, &up.index_bytes, ib, {.INDEX}) do return false

	aw, ah := u32(dirty[2] - dirty[0]), u32(dirty[3] - dirty[1])
	if !upload_atlas || aw == 0 || ah == 0 do aw, ah = 0, 0
	need := vb + ib + aw * ah
	if need == 0 do return true
	if need > up.transfer_bytes {
		if up.transfer != nil {
			_ = gpu_wait_for_idle(r.device)
			gpu_release_transfer_buffer(r.device, up.transfer)
		}
		size := max(need, 1024 * 1024)
		size = 1 << u32(32 - intrinsics.count_leading_zeros(size - 1))
		up.transfer = gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = size})
		if up.transfer == nil {
			up.transfer_bytes = 0
			log.errorf("ui transfer buffer: %s", sdl.GetError())
			return false
		}
		up.transfer_bytes = size
	}
	dst := ([^]u8)(gpu_map_transfer_buffer(r.device, up.transfer, true))
	if dst == nil {
		log.errorf("ui map: %s", sdl.GetError())
		return false
	}
	if vb > 0 do copy(dst[:vb], ([^]u8)(raw_data(vertices))[:vb])
	if ib > 0 do copy(dst[vb:][:ib], ([^]u8)(raw_data(indices))[:ib])
	for row in 0 ..< int(ah) {
		src := atlas[(dirty[1] + row) * int(atlas_size.x) + dirty[0]:][:aw]
		copy(dst[vb + ib + u32(row) * aw:][:aw], src)
	}
	gpu_unmap_transfer_buffer(r.device, up.transfer)

	pass := gpu_begin_copy_pass(cmd)
	if vb > 0 do gpu_upload_to_buffer(pass, {transfer_buffer = up.transfer, offset = 0}, {buffer = up.vertices, offset = 0, size = vb}, false)
	if ib > 0 do gpu_upload_to_buffer(pass, {transfer_buffer = up.transfer, offset = vb}, {buffer = up.indices, offset = 0, size = ib}, false)
	if aw > 0 {
		gpu_upload_to_texture(pass,
			{transfer_buffer = up.transfer, offset = vb + ib, pixels_per_row = aw, rows_per_layer = ah},
			{texture = up.atlas, x = u32(dirty[0]), y = u32(dirty[1]), w = aw, h = ah, d = 1}, false)
	}
	gpu_end_copy_pass(pass)
	return true
}

// Draws the uploaded triangles into an open render pass whose target has `format` and
// is `size` pixels, or with `turns` (pre-rotation, 1 to 3) is `size` turned that many
// quarter turns clockwise: the triangles and their clip rectangles are turned with it.
ui_pass_draw :: proc(r: ^Renderer, up: ^Ui_Pass, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, format: sdl.GPUTextureFormat, size: [2]u32, draws: []Ui_Draw, turns := 0) {
	if len(draws) == 0 || up.vertices == nil || up.indices == nil || up.atlas == nil do return
	pipeline := ui_pipeline(r, up, format)
	if pipeline == nil do return
	gpu_bind_graphics_pipeline(pass, pipeline)
	vbind := sdl.GPUBufferBinding{buffer = up.vertices}
	gpu_bind_vertex_buffers(pass, 0, &vbind, 1)
	gpu_bind_index_buffer(pass, {buffer = up.indices}, ._32BIT)
	// The cosine and sine of the turn, exact for quarter turns.
	TURN := [4][2]f32{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
	turn := TURN[turns & 3]
	vu := Ui_Vertex_Uniforms{{f32(size.x), f32(size.y), turn.x, turn.y}}
	gpu_push_vertex_uniform_data(cmd, 0, &vu, size_of(vu))
	for d in draws {
		if d.index_count == 0 do continue
		x0, y0 := clamp(d.clip[0], 0, i32(size.x)), clamp(d.clip[1], 0, i32(size.y))
		x1, y1 := clamp(d.clip[0] + d.clip[2], 0, i32(size.x)), clamp(d.clip[1] + d.clip[3], 0, i32(size.y))
		if x1 <= x0 || y1 <= y0 do continue
		w, h := i32(size.x), i32(size.y)
		// The window's point (x, y) is the turned image's (h - y, x) a quarter turn on.
		switch turns & 3 {
		case 1: x0, y0, x1, y1 = h - y1, x0, h - y0, x1
		case 2: x0, y0, x1, y1 = w - x1, h - y1, w - x0, h - y0
		case 3: x0, y0, x1, y1 = y0, w - x1, y1, w - x0
		}
		gpu_set_scissor(pass, {x0, y0, x1 - x0, y1 - y0})
		fu: Ui_Fragment_Uniforms
		binding := sdl.GPUTextureSamplerBinding{sampler = up.sampler}
		if d.image != nil {
			binding.texture = d.image
			fu.params = {1, 1, 1, 1 if d.smooth else 0}
			if d.smooth do binding.sampler = up.smooth
		} else {
			binding.texture = up.atlas
			fu.params = {1 / f32(up.atlas_size.x), 1 / f32(up.atlas_size.y), 0, 0}
		}
		gpu_bind_fragment_samplers(pass, 0, &binding, 1)
		gpu_push_fragment_uniform_data(cmd, 0, &fu, size_of(fu))
		gpu_draw_indexed_primitives(pass, d.index_count, 1, d.first_index, 0, 0)
	}
}

// Draws the interface into a new `size` texture of VIEWPORT_COLOR_FORMAT cleared to
// `clear` and returns its RGBA8 rows, top to bottom (for --dump-screen; the swapchain
// cannot be read back). Waits for the GPU.
ui_pass_capture :: proc(r: ^Renderer, up: ^Ui_Pass, size: [2]u32, clear: [4]f32, draws: []Ui_Draw, vertices: []Ui_Vertex, indices: []u32, atlas: []u8, atlas_size: [2]u32, allocator := context.allocator) -> []u8 {
	target := gpu_create_texture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1,
	})
	if target == nil do return nil
	defer gpu_release_texture(r.device, target)
	cmd := gpu_acquire_command_buffer(r.device)
	if cmd == nil do return nil
	// The whole atlas again: the copy on the GPU is current, but this keeps the capture
	// independent of what the last frame uploaded.
	if !ui_pass_upload(r, up, cmd, vertices, indices, atlas, atlas_size, {0, 0, int(atlas_size.x), int(atlas_size.y)}, true) {
		_ = gpu_submit_command_buffer(cmd)
		return nil
	}
	info := sdl.GPUColorTargetInfo{texture = target, clear_color = sdl.FColor(clear), load_op = .CLEAR, store_op = .STORE}
	pass := gpu_begin_render_pass(cmd, &info, 1, nil)
	ui_pass_draw(r, up, cmd, pass, VIEWPORT_COLOR_FORMAT, size, draws)
	gpu_end_render_pass(pass)
	if !gpu_submit_command_buffer(cmd) do return nil
	return texture_download(r, target, size.x, size.y, allocator)
}

@(private = "file")
ui_pipeline :: proc(r: ^Renderer, up: ^Ui_Pass, format: sdl.GPUTextureFormat) -> ^sdl.GPUGraphicsPipeline {
	for p, i in up.pipelines do if p != nil && up.formats[i] == format do return p
	slot := -1
	for p, i in up.pipelines do if p == nil {
		slot = i
		break
	}
	if slot < 0 do return nil
	vert := gpu_create_shader(r.device, {
		code_size = len(UI_VERT_CODE), code = raw_data(UI_VERT_CODE), entrypoint = SHADER_ENTRY,
		format = SHADER_FORMAT, stage = .VERTEX, num_uniform_buffers = 1,
	})
	frag := gpu_create_shader(r.device, {
		code_size = len(UI_FRAG_CODE), code = raw_data(UI_FRAG_CODE), entrypoint = SHADER_ENTRY,
		format = SHADER_FORMAT, stage = .FRAGMENT, num_samplers = 1, num_uniform_buffers = 1,
	})
	defer if vert != nil do gpu_release_shader(r.device, vert)
	defer if frag != nil do gpu_release_shader(r.device, frag)
	if vert == nil || frag == nil {
		log.errorf("ui shaders: %s", sdl.GetError())
		return nil
	}
	buffers := [1]sdl.GPUVertexBufferDescription{{slot = 0, pitch = size_of(Ui_Vertex), input_rate = .VERTEX}}
	attributes := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Ui_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Ui_Vertex, uv))},
		{location = 2, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Ui_Vertex, color))},
	}
	// Straight alpha, as the kit's colours are: what is under shows through by 1 - alpha.
	blend := sdl.GPUColorTargetBlendState {
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
		enable_blend = true,
	}
	targets := [1]sdl.GPUColorTargetDescription{{format = format, blend_state = blend}}
	p := gpu_create_graphics_pipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = len(buffers),
			vertex_attributes = &attributes[0],
			num_vertex_attributes = len(attributes),
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		target_info = {color_target_descriptions = &targets[0], num_color_targets = 1},
	})
	if p == nil {
		log.errorf("ui pipeline: %s", sdl.GetError())
		return nil
	}
	up.pipelines[slot], up.formats[slot] = p, format
	return p
}

// Makes `buffer` hold at least `need` bytes, doubling, and keeps it otherwise.
@(private = "file")
grow_buffer :: proc(r: ^Renderer, buffer: ^^sdl.GPUBuffer, capacity: ^u32, need: u32, usage: sdl.GPUBufferUsageFlags) -> bool {
	if need <= capacity^ && buffer^ != nil do return true
	if buffer^ != nil {
		_ = gpu_wait_for_idle(r.device)
		gpu_release_buffer(r.device, buffer^)
	}
	// Growing waits for the GPU to go idle, which on the first frames is waiting for a
	// whole viewport of a big mesh; starting at 512 KB (about 25k vertices, several
	// times what the interface draws) means it never grows in practice.
	size := max(need, 512 * 1024)
	size = 1 << u32(32 - intrinsics.count_leading_zeros(size - 1))
	buffer^ = gpu_create_buffer(r.device, {usage = usage, size = size})
	if buffer^ == nil {
		capacity^ = 0
		log.errorf("ui buffer: %s", sdl.GetError())
		return false
	}
	capacity^ = size
	return true
}
