package render

import "../gpu"
import "base:intrinsics"
import "core:log"

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
	image:       gpu.Texture, // nil draws from the glyph atlas
	// The image is drawn larger than shown over a clear of nothing (the navigation head):
	// filtered, which averages its samples, and with its colour taken back out of its
	// alpha, so its edge does not darken.
	smooth:      bool,
}

// What the interface needs on the GPU: its pipelines (one per target format, made on
// first use), the glyph atlas, and vertex and index buffers grown to the largest frame.
Ui_Pass :: struct {
	formats:      [2]gpu.Format,
	pipelines:    [2]gpu.Graphics_Pipeline,
	sampler:      gpu.Sampler,
	smooth:       gpu.Sampler, // filtering, for Ui_Draw.smooth
	atlas:        gpu.Texture,
	atlas_size:   [2]u32,
	vertices:     gpu.Buffer,
	indices:      gpu.Buffer,
	vertex_bytes: u32, // capacities
	index_bytes:  u32,
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
	if !r.has_device do return
	for p in up.pipelines do if p != 0 do gpu.release_graphics_pipeline(p)
	if up.sampler != 0 do gpu.release_sampler(up.sampler)
	if up.smooth != 0 do gpu.release_sampler(up.smooth)
	if up.atlas != 0 do gpu.release_texture(up.atlas)
	if up.vertices != 0 do gpu.release_buffer(up.vertices)
	if up.indices != 0 do gpu.release_buffer(up.indices)
	up^ = {}
}

// Copies this frame's triangles, and the part of the glyph atlas that changed, to the
// GPU in a copy pass on `cmd`; it must come before the render pass that draws them.
// `atlas` is the kit's whole single-channel atlas, `dirty` the rectangle (x0, y0, x1,
// y1) that changed, `atlas_changed` false when nothing did. A new atlas size uploads
// all of it.
ui_pass_upload :: proc(r: ^Renderer, up: ^Ui_Pass, cmd: gpu.Cmd, vertices: []Ui_Vertex, indices: []u32, atlas: []u8, atlas_size: [2]u32, dirty: [4]int, atlas_changed: bool) -> bool {
	debug_group(cmd, "Interface upload", .Interface)
	if up.sampler == 0 {
		// Nearest: glyphs sit on whole pixels and the viewport image is shown pixel for
		// pixel, so nothing is ever blurred by filtering.
		up.sampler = gpu.create_sampler({
			min_filter = .Nearest, mag_filter = .Nearest, mipmap_mode = .Nearest,
			address_mode_u = .Clamp_To_Edge, address_mode_v = .Clamp_To_Edge, address_mode_w = .Clamp_To_Edge,
		})
		if up.sampler == 0 {
			log.errorf("ui sampler: %s", gpu.last_error())
			return false
		}
	}
	if up.smooth == 0 {
		up.smooth = gpu.create_sampler({
			min_filter = .Linear, mag_filter = .Linear, mipmap_mode = .Nearest,
			address_mode_u = .Clamp_To_Edge, address_mode_v = .Clamp_To_Edge, address_mode_w = .Clamp_To_Edge,
		})
		if up.smooth == 0 {
			log.errorf("ui sampler: %s", gpu.last_error())
			return false
		}
	}
	dirty := dirty
	upload_atlas := atlas_changed
	if up.atlas == 0 || up.atlas_size != atlas_size {
		if up.atlas != 0 {
			gpu.release_texture(up.atlas)
		}
		up.atlas = gpu.create_texture({
			type = .D2, format = .R8_Unorm, usage = {.Sampled},
			width = atlas_size.x, height = atlas_size.y, layer_count_or_depth = 1, num_levels = 1,
		})
		if up.atlas == 0 {
			log.errorf("ui atlas: %s", gpu.last_error())
			return false
		}
		up.atlas_size = atlas_size
		dirty, upload_atlas = {0, 0, int(atlas_size.x), int(atlas_size.y)}, true
	}
	vb := u32(len(vertices) * size_of(Ui_Vertex))
	ib := u32(len(indices) * size_of(u32))
	if !grow_buffer(r, &up.vertices, &up.vertex_bytes, vb, {.Vertex}) do return false
	if !grow_buffer(r, &up.indices, &up.index_bytes, ib, {.Index}) do return false

	aw, ah := u32(dirty[2] - dirty[0]), u32(dirty[3] - dirty[1])
	if !upload_atlas || aw == 0 || ah == 0 do aw, ah = 0, 0
	ok := gpu.upload(cmd, up.vertices, 0, ([^]u8)(raw_data(vertices))[:vb]) && gpu.upload(cmd, up.indices, 0, ([^]u8)(raw_data(indices))[:ib])
	if ok && aw > 0 {
		dst := gpu.stage_texture(cmd, {texture = up.atlas, x = u32(dirty[0]), y = u32(dirty[1]), w = aw, h = ah, d = 1}, aw * ah, aw, ah)
		for row in 0 ..< int(ah) do if dst != nil {
			copy(dst[u32(row) * aw:][:aw], atlas[(dirty[1] + row) * int(atlas_size.x) + dirty[0]:][:aw])
		}
		ok = dst != nil
	}
	if !ok do log.errorf("ui upload: %s", gpu.last_error())
	return ok
}

// Draws the uploaded triangles into an open render pass whose target has `format` and
// is `size` pixels, or with `turns` (pre-rotation, 1 to 3) is `size` turned that many
// quarter turns clockwise: the triangles and their clip rectangles are turned with it.
ui_pass_draw :: proc(r: ^Renderer, up: ^Ui_Pass, cmd: gpu.Cmd, pass: gpu.Render_Pass, format: gpu.Format, size: [2]u32, draws: []Ui_Draw, turns := 0) {
	if len(draws) == 0 || up.vertices == 0 || up.indices == 0 || up.atlas == 0 do return
	pipeline := ui_pipeline(r, up, format)
	if pipeline == 0 do return
	gpu.bind_graphics_pipeline(pass, pipeline)
	vbind := gpu.Buffer_Binding{buffer = up.vertices}
	gpu.bind_vertex_buffers(pass, 0, &vbind, 1)
	gpu.bind_index_buffer(pass, {buffer = up.indices}, .U32)
	// The cosine and sine of the turn, exact for quarter turns.
	TURN := [4][2]f32{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
	turn := TURN[turns & 3]
	vu := Ui_Vertex_Uniforms{{f32(size.x), f32(size.y), turn.x, turn.y}}
	gpu.push_vertex_uniform_data(cmd, 0, &vu, size_of(vu))
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
		gpu.set_scissor(pass, {x0, y0, x1 - x0, y1 - y0})
		fu: Ui_Fragment_Uniforms
		binding := gpu.Texture_Sampler_Binding{sampler = up.sampler}
		if d.image != 0 {
			binding.texture = d.image
			fu.params = {1, 1, 1, 1 if d.smooth else 0}
			if d.smooth do binding.sampler = up.smooth
		} else {
			binding.texture = up.atlas
			fu.params = {1 / f32(up.atlas_size.x), 1 / f32(up.atlas_size.y), 0, 0}
		}
		gpu.bind_fragment_samplers(pass, 0, &binding, 1)
		gpu.push_fragment_uniform_data(cmd, 0, &fu, size_of(fu))
		gpu.draw_indexed_primitives(pass, d.index_count, 1, d.first_index, 0, 0)
	}
}

// Draws the interface into a new `size` texture of VIEWPORT_COLOR_FORMAT cleared to
// `clear` and returns its RGBA8 rows, top to bottom (for --dump-screen; the swapchain
// cannot be read back). Waits for the GPU.
ui_pass_capture :: proc(r: ^Renderer, up: ^Ui_Pass, size: [2]u32, clear: [4]f32, draws: []Ui_Draw, vertices: []Ui_Vertex, indices: []u32, atlas: []u8, atlas_size: [2]u32, allocator := context.allocator) -> []u8 {
	target := gpu.create_texture({
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.Color_Target, .Sampled},
		width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1,
	})
	if target == 0 do return nil
	defer gpu.release_texture(target)
	cmd := gpu.acquire_command_buffer()
	if cmd == nil do return nil
	// The whole atlas again: the copy on the GPU is current, but this keeps the capture
	// independent of what the last frame uploaded.
	if !ui_pass_upload(r, up, cmd, vertices, indices, atlas, atlas_size, {0, 0, int(atlas_size.x), int(atlas_size.y)}, true) {
		_, _ = gpu.submit(cmd)
		return nil
	}
	info := gpu.Color_Target{texture = target, clear_color = clear, load_op = .Clear, store_op = .Store}
	pass := gpu.begin_render_pass(cmd, &info, 1, nil)
	ui_pass_draw(r, up, cmd, pass, VIEWPORT_COLOR_FORMAT, size, draws)
	gpu.end_render_pass(pass)
	return texture_download_in(r, cmd, target, size.x, size.y, allocator)
}

@(private = "file")
ui_pipeline :: proc(r: ^Renderer, up: ^Ui_Pass, format: gpu.Format) -> gpu.Graphics_Pipeline {
	for p, i in up.pipelines do if p != 0 && up.formats[i] == format do return p
	slot := -1
	for p, i in up.pipelines do if p == 0 {
		slot = i
		break
	}
	if slot < 0 do return 0
	vert := gpu.create_shader(UI_VERT)
	frag := gpu.create_shader(UI_FRAG)
	defer if vert != 0 do gpu.release_shader(vert)
	defer if frag != 0 do gpu.release_shader(frag)
	if vert == 0 || frag == 0 {
		log.errorf("ui shaders: %s", gpu.last_error())
		return 0
	}
	buffers := [1]gpu.Vertex_Buffer{{slot = 0, pitch = size_of(Ui_Vertex), input_rate = .Vertex}}
	attributes := [3]gpu.Vertex_Attribute {
		{location = 0, buffer_slot = 0, format = .Float2, offset = u32(offset_of(Ui_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .Float2, offset = u32(offset_of(Ui_Vertex, uv))},
		{location = 2, buffer_slot = 0, format = .Ubyte4_Norm, offset = u32(offset_of(Ui_Vertex, color))},
	}
	// Straight alpha, as the kit's colours are: what is under shows through by 1 - alpha.
	blend := gpu.Blend_State {
		src_color_blendfactor = .Src_Alpha, dst_color_blendfactor = .One_Minus_Src_Alpha, color_blend_op = .Add,
		src_alpha_blendfactor = .One, dst_alpha_blendfactor = .One_Minus_Src_Alpha, alpha_blend_op = .Add,
		enable_blend = true,
	}
	targets := [1]gpu.Color_Target_Desc{{format = format, blend_state = blend}}
	p := gpu.create_graphics_pipeline({
		vertex_shader = vert,
		fragment_shader = frag,
		vertex_input = {
			buffers = buffers[:],
			attributes = attributes[:],
		},
		primitive = .Triangle_List,
		rasterizer_state = {fill_mode = .Fill, cull_mode = .None},
		targets = {color_targets = targets[:]},
	})
	if p == 0 {
		log.errorf("ui pipeline: %s", gpu.last_error())
		return 0
	}
	up.pipelines[slot], up.formats[slot] = p, format
	return p
}

// Makes `buffer` hold at least `need` bytes, doubling, and keeps it otherwise.
@(private = "file")
grow_buffer :: proc(r: ^Renderer, buffer: ^gpu.Buffer, capacity: ^u32, need: u32, usage: gpu.Buffer_Usages) -> bool {
	if need <= capacity^ && buffer^ != 0 do return true
	if buffer^ != 0 {
		gpu.release_buffer(buffer^)
	}
	// Starting at 512 KB (about 25k vertices, several times what the interface draws)
	// means it never grows in practice.
	size := max(need, 512 * 1024)
	size = 1 << u32(32 - intrinsics.count_leading_zeros(size - 1))
	buffer^ = gpu.create_buffer({usage = usage, size = size})
	if buffer^ == 0 {
		capacity^ = 0
		log.errorf("ui buffer: %s", gpu.last_error())
		return false
	}
	capacity^ = size
	return true
}
