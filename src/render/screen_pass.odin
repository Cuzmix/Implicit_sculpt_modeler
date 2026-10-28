package render

import "core:log"
import "core:math/linalg"
import sdl "vendor:sdl3"

import "../geom"

// What the screen-space passes after the viewport share (the studio render, live ambient
// occlusion): full-screen triangles through a fragment shader, and the camera's depth at
// one sample, drawn again when the viewport is multisampled, whose own depth shaders
// cannot read.

// Matches Shadow_Uniforms in shadow.vert.slang.
@(private)
Shadow_Uniforms :: struct {
	light_view_proj: Mat4,
	model:           Mat4,
}

// Draws the camera's depth into `target` (one sample, `width` by `height`, the
// viewport's size) through the same culled runs of chunks the viewport draws, so hidden
// parts stay out of it, with `depth_pipeline` (create_shadow_pipeline with cull_back).
// With `rect`, only that rectangle is cleared (by `clear_pipeline`, from
// create_depth_clear_pipeline) and drawn again, culled to it at full detail as render_rect
// draws, and the rest keeps what it held; without, all of it is, simplified where a full
// redraw of the viewport simplifies (lod_view), so the depth is the surface the colour shows.
@(private)
view_depth_draw :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, depth_pipeline, clear_pipeline: ^sdl.GPUGraphicsPipeline, target: ^sdl.GPUTexture, width, height: u32, view, proj: Mat4, items: []Draw_Item, rect: Maybe(Rect) = nil) {
	stats: Viewport_Stats
	part, partial := rect.?
	if partial {
		prepare_draws(r, cmd, view, proj, items, nil, &stats, rect_narrow(part, width, height))
	} else {
		prepare_draws(r, cmd, view, proj, items, nil, &stats, lod = lod_view(r, height, proj))
	}
	depth := sdl.GPUDepthStencilTargetInfo {
		texture          = target,
		clear_depth      = 1,
		load_op          = .LOAD if partial else .CLEAR,
		store_op         = .STORE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
		// A partial redraw keeps the rest, so it must draw into the same texture.
		cycle            = !partial,
	}
	pass := sdl.BeginGPURenderPass(cmd, nil, 0, &depth)
	if partial {
		sdl.SetGPUScissor(pass, {part.x, part.y, part.w, part.h})
		sdl.BindGPUGraphicsPipeline(pass, clear_pipeline)
		sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	}
	sdl.BindGPUGraphicsPipeline(pass, depth_pipeline)
	for item in items {
		// See-through items leave the viewport's own depth be, so they stay out of this
		// one too: the anti-aliased viewport then shades as the plain one does.
		if blended(&r.single, item) do continue
		u := Shadow_Uniforms{proj * view, item.model}
		sdl.PushGPUVertexUniformData(cmd, 0, &u, size_of(u))
		vbufs := [1]sdl.GPUBufferBinding{{buffer = item.mesh.positions}}
		sdl.BindGPUVertexBuffers(pass, 0, &vbufs[0], 1)
		draw_item_triangles(r, pass, item, nil)
	}
	sdl.EndGPURenderPass(pass)
}

// Maps the pixel rectangle `rect` of a `width` by `height` target to the whole of clip
// space, so culling against the narrowed frustum keeps only the chunks that can touch it.
@(private)
rect_narrow :: proc(rect: Rect, width, height: u32) -> Mat4 {
	W, H := f32(width), f32(height)
	nx0, nx1 := 2 * f32(rect.x) / W - 1, 2 * f32(rect.x + rect.w) / W - 1
	ny0, ny1 := 1 - 2 * f32(rect.y + rect.h) / H, 1 - 2 * f32(rect.y) / H
	cx, hx := (nx0 + nx1) / 2, (nx1 - nx0) / 2
	cy, hy := (ny0 + ny1) / 2, (ny1 - ny0) / 2
	return Mat4{
		1 / hx, 0, 0, -cx / hx,
		0, 1 / hy, 0, -cy / hy,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
}

// A sphere around every item, as scene_sphere finds it, for the app's Depth pass.
items_sphere :: proc(items: []Draw_Item) -> (center: [3]f32, radius: f32, ok: bool) {
	return scene_sphere(items)
}

// A sphere around every item's chunks in the world, or for an item without chunks (the
// live boolean's preview), its CPU mesh's vertices. False with nothing to draw.
@(private)
scene_sphere :: proc(items: []Draw_Item) -> (center: [3]f32, radius: f32, ok: bool) {
	box := geom.AABB_EMPTY
	for item in items {
		if len(item.chunks) == 0 && item.source != nil {
			for p in item.source.positions {
				w := item.model * [4]f32{p.x, p.y, p.z, 1}
				geom.aabb_grow(&box, w.xyz)
			}
		}
		for c in item.chunks {
			if c.bounds.lo.x > c.bounds.hi.x do continue
			for corner in 0 ..< 8 {
				p := [3]f32 {
					c.bounds.hi.x if corner & 1 != 0 else c.bounds.lo.x,
					c.bounds.hi.y if corner & 2 != 0 else c.bounds.lo.y,
					c.bounds.hi.z if corner & 4 != 0 else c.bounds.lo.z,
				}
				w := item.model * [4]f32{p.x, p.y, p.z, 1}
				geom.aabb_grow(&box, w.xyz)
			}
		}
	}
	if box.lo.x > box.hi.x do return
	center = (box.lo + box.hi) / 2
	radius = max(linalg.length(box.hi - box.lo) / 2, 1e-3)
	return center, radius, true
}

// Depth from a light (both faces, so an open mesh or a hole still casts its shadow) or,
// with `cull_back`, the camera's (front faces, matching what the viewport drew).
@(private)
create_shadow_pipeline :: proc(r: ^Renderer, cull_back: bool) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size = len(SHADOW_VERT_SPV), code = raw_data(SHADOW_VERT_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .VERTEX, num_uniform_buffers = 1,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size = len(SHADOW_FRAG_SPV), code = raw_data(SHADOW_FRAG_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .FRAGMENT,
	})
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil do return nil
	buffers := [1]sdl.GPUVertexBufferDescription{{slot = 0, pitch = size_of(geom.Vec3), input_rate = .VERTEX}}
	attributes := [1]sdl.GPUVertexAttribute{{location = 0, buffer_slot = 0, format = .FLOAT3}}
	return sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attributes[0],
			num_vertex_attributes = 1,
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .BACK if cull_back else .NONE, front_face = .COUNTER_CLOCKWISE},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {depth_stencil_format = r.depth_format, has_depth_stencil_target = true},
	})
}

// A full-screen triangle at the far plane (clear.vert.slang) that writes its depth whatever
// was there, and no colour: clears a scissored part of a depth target, which a render
// pass can only clear whole.
@(private)
create_depth_clear_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size = len(CLEAR_VERT_SPV), code = raw_data(CLEAR_VERT_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .VERTEX,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size = len(SHADOW_FRAG_SPV), code = raw_data(SHADOW_FRAG_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .FRAGMENT,
	})
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil do return nil
	return sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		depth_stencil_state = {compare_op = .ALWAYS, enable_depth_test = true, enable_depth_write = true},
		target_info = {depth_stencil_format = r.depth_format, has_depth_stencil_target = true},
	})
}

// A full-screen triangle (clear.vert.slang) through `frag_spv`, which reads `samplers` samplers
// and one uniform buffer, into one colour target; `additive` blends by adding.
@(private)
create_fullscreen_pipeline :: proc(r: ^Renderer, frag_spv: []u8, format: sdl.GPUTextureFormat, samplers: u32, additive := false) -> ^sdl.GPUGraphicsPipeline {
	vert := sdl.CreateGPUShader(r.device, {
		code_size = len(CLEAR_VERT_SPV), code = raw_data(CLEAR_VERT_SPV), entrypoint = "main",
		format = {.SPIRV}, stage = .VERTEX,
	})
	frag := sdl.CreateGPUShader(r.device, {
		code_size = len(frag_spv), code = raw_data(frag_spv), entrypoint = "main",
		format = {.SPIRV}, stage = .FRAGMENT, num_samplers = samplers, num_uniform_buffers = 1,
	})
	defer if vert != nil do sdl.ReleaseGPUShader(r.device, vert)
	defer if frag != nil do sdl.ReleaseGPUShader(r.device, frag)
	if vert == nil || frag == nil {
		log.errorf("full-screen pass shaders: %s", sdl.GetError())
		return nil
	}
	blend := sdl.GPUColorTargetBlendState{}
	if additive {
		blend = {
			src_color_blendfactor = .ONE, dst_color_blendfactor = .ONE, color_blend_op = .ADD,
			src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE, alpha_blend_op = .ADD,
			enable_blend = true,
		}
	}
	color_targets := [1]sdl.GPUColorTargetDescription{{format = format, blend_state = blend}}
	return sdl.CreateGPUGraphicsPipeline(r.device, {
		vertex_shader = vert,
		fragment_shader = frag,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		target_info = {color_target_descriptions = &color_targets[0], num_color_targets = 1},
	})
}
