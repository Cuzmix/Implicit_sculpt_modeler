package render

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import sdl "vendor:sdl3"

// Live ambient occlusion (stage 4.2, notes/rendering/stage4-design.md): screen-space
// occlusion from the camera's depth, every frame, so creases and contact darken while
// sculpting, not only once the view is still as in the studio render. GTAO
// (gtao.frag.slang) finds the occlusion into `ao`, possibly at half size; ao_blur.frag.slang
// averages it and darkens the viewport image with it into `shown`, which the panel then
// shows. A partial redraw of the viewport reruns both only over the rectangle it
// redrew, padded by how far they read, and `ao` and `shown` keep the rest, so the cost
// while sculpting follows the brush, and the pixels match a full pass exactly.
Live_AO :: struct {
	gtao_pipeline:  ^sdl.GPUGraphicsPipeline,
	blur_pipeline:  ^sdl.GPUGraphicsPipeline,
	depth_pipeline: ^sdl.GPUGraphicsPipeline, // the camera's depth at one sample, under multisampling
	clear_pipeline: ^sdl.GPUGraphicsPipeline, // clears a rectangle of that depth for a partial redraw
	sampler:        ^sdl.GPUSampler,
	ao:             ^sdl.GPUTexture, // LIVE_AO_FORMAT, the viewport's size divided by `scale`
	shown:          ^sdl.GPUTexture, // what the viewport panel shows
	// The camera's depth at one sample, drawn when the viewport is multisampled, whose
	// own depth shaders cannot read; nil otherwise.
	view_depth:     ^sdl.GPUTexture,
	width, height:  u32, // of shown (the viewport's)
	scale:          u32, // viewport pixels per ao texel, each way
	// What the textures were last made for (live_ao_key); 0 when they hold nothing, so the
	// next frame runs in full.
	key:            u64,
	failed:         bool, // the device refused part of it; the plain viewport shows
	// Frames that ran over the whole viewport, over a rectangle, and not at all (nothing
	// changed), for the exit stats.
	full, partial, skipped: int,
}

// The farthest gtao.frag.slang searches, in viewport pixels: it bounds the cost close up, and
// how far a partial redraw's rectangle is padded.
LIVE_AO_MAX_PX :: 48

// Half floats: a pixel's value may pass 1 (gtao.frag.slang), which the blur's average needs.
LIVE_AO_FORMAT :: sdl.GPUTextureFormat.R16_FLOAT

GTAO_FRAG_CODE :: #load("shaders/gtao.frag" + SHADER_EXT)
AO_BLUR_FRAG_CODE :: #load("shaders/ao_blur.frag" + SHADER_EXT)

// Matches Gtao_Uniforms in gtao.frag.slang.
@(private = "file")
Gtao_Uniforms :: struct {
	inv_proj: Mat4,
	size:     [4]f32,
	params:   [4]f32,
}

// Matches Blur_Uniforms in ao_blur.frag.slang.
@(private = "file")
Blur_Uniforms :: struct {
	inv_proj: Mat4,
	size:     [4]f32,
	params:   [4]f32,
}

// Records this frame's live occlusion after render_viewport, whose `drawn` says what it
// redrew: `reach` is how far occluders count, as a share of the scene's radius,
// `strength` how strongly it darkens (0 to 1), `scale` 1 for full size or 2 for half.
// With `line_px` 0 or more (a wipe compare), pixels from that column on darken by
// `strength_right` instead, so only the side whose pass wants occlusion shows it.
// Leaves the result in Live_AO.shown. Returns false only when it cannot run on this
// device, after which it never tries again.
live_ao_frame :: proc(r: ^Renderer, lao: ^Live_AO, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, drawn: Viewport_Stats, reach, strength: f32, scale: u32, strength_right: f32 = 0, line_px: f32 = -1) -> bool {
	if lao.failed do return false
	if !live_ao_ensure(r, lao, vt, max(scale, 1)) {
		live_ao_destroy(r, lao)
		lao.failed = true
		return false
	}
	// The reach in the world from the scene's size, the radius snapped to sixteenths of an
	// octave so a stroke that grows the scene seldom changes it (which reruns everything).
	_, radius, ok := scene_sphere(items)
	if !ok do radius = 1
	radius = math.pow(2, math.round(math.log2(radius) * 16) / 16)
	world_reach := max(reach, 1e-4) * radius
	key := live_ao_key(vt^, proj, lao.scale, world_reach, {strength, strength_right, line_px})
	W, H := i32(vt.width), i32(vt.height)
	whole := Rect{0, 0, W, H}
	rect := whole
	partial := drawn.partial && key == lao.key
	lao.key = key
	if partial {
		changed := Rect{drawn.redrawn[0], drawn.redrawn[1], drawn.redrawn[2], drawn.redrawn[3]}
		if drawn.redrawn_px == 0 || changed.w <= 0 || changed.h <= 0 {
			lao.skipped += 1
			return true
		}
		rect = changed
		lao.partial += 1
	} else {
		lao.full += 1
	}

	// The depth both passes read: the viewport's own, or with multisampling the camera's
	// drawn again at one sample over what changed.
	depth := vt.depth
	if lao.view_depth != nil {
		depth = lao.view_depth
		view_depth_draw(r, cmd, lao.depth_pipeline, lao.clear_pipeline, lao.view_depth, vt.width, vt.height, view, proj, items, rect if partial else nil)
	}

	// What each pass must redo. An ao texel reads depth at most LIVE_AO_MAX_PX + 1 pixels
	// from its own (the farthest step, 48 + 1.3 rounded) and its neighbours 1 pixel away for
	// the normal; a shown pixel reads ao texels 2 away and their depths. Each pad is one
	// more than that, and rounded out to whole texels, so nothing a changed pixel reaches is
	// left with last frame's value.
	s := i32(lao.scale)
	aw, ah := i32(lao.width + lao.scale - 1) / s, i32(lao.height + lao.scale - 1) / s
	ao_rect := Rect{0, 0, aw, ah}
	blur_rect := whole
	if partial {
		pad := i32(LIVE_AO_MAX_PX + 3)
		x0, y0 := floor_div(rect.x - pad, s), floor_div(rect.y - pad, s)
		x1, y1 := ceil_div(rect.x + rect.w + pad, s), ceil_div(rect.y + rect.h + pad, s)
		ao_rect = rect_clamp(x0, y0, x1, y1, aw, ah)
		blur_rect = rect_clamp((ao_rect.x - 3) * s, (ao_rect.y - 3) * s, (ao_rect.x + ao_rect.w + 3) * s, (ao_rect.y + ao_rect.h + 3) * s, W, H)
	}

	inv_proj := linalg.inverse(proj)
	ortho := proj[3, 3] == 1
	g := Gtao_Uniforms {
		inv_proj = inv_proj,
		size     = {f32(vt.width), f32(vt.height), f32(lao.scale), 1 if ortho else 0},
		params   = {world_reach, proj[1, 1] * f32(vt.height) / 2, LIVE_AO_MAX_PX, 0},
	}
	target := sdl.GPUColorTargetInfo{texture = lao.ao, load_op = .LOAD if partial else .DONT_CARE, store_op = .STORE, cycle = !partial}
	pass := gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(pass, lao.gtao_pipeline)
	gpu_set_scissor(pass, {ao_rect.x, ao_rect.y, ao_rect.w, ao_rect.h})
	binding := sdl.GPUTextureSamplerBinding{texture = depth, sampler = lao.sampler}
	gpu_bind_fragment_samplers(pass, 0, &binding, 1)
	gpu_push_fragment_uniform_data(cmd, 0, &g, size_of(g))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)

	b := Blur_Uniforms {
		inv_proj = inv_proj,
		size     = g.size,
		// Texels farther than half the reach in depth from the pixel's are another surface.
		params   = {clamp(strength, 0, 1), world_reach * 0.5, line_px, clamp(strength_right, 0, 1)},
	}
	target = {texture = lao.shown, load_op = .LOAD if partial else .DONT_CARE, store_op = .STORE, cycle = !partial}
	pass = gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(pass, lao.blur_pipeline)
	gpu_set_scissor(pass, {blur_rect.x, blur_rect.y, blur_rect.w, blur_rect.h})
	samplers := [3]sdl.GPUTextureSamplerBinding{{texture = vt.color, sampler = lao.sampler}, {texture = lao.ao, sampler = lao.sampler}, {texture = depth, sampler = lao.sampler}}
	gpu_bind_fragment_samplers(pass, 0, &samplers[0], len(samplers))
	gpu_push_fragment_uniform_data(cmd, 0, &b, size_of(b))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)
	return true
}

// What the viewport panel should show while live occlusion is on: its image, or nil
// when there is none (it has not run since it was last reset, or cannot run) and the
// plain viewport shows.
live_ao_texture :: proc(lao: ^Live_AO) -> ^sdl.GPUTexture {
	if lao.failed || lao.key == 0 do return nil
	return lao.shown
}

// Makes the next live_ao_frame run in full: for every frame it does not run (it is off,
// or the studio render shows instead), since the viewport may change meanwhile.
live_ao_reset :: proc(lao: ^Live_AO) {
	lao.key = 0
}

// Whether live occlusion can run here: it needs to read depth in a shader.
live_ao_supported :: proc(r: ^Renderer, lao: ^Live_AO) -> bool {
	return r.depth_sampled && !lao.failed
}

live_ao_destroy :: proc(r: ^Renderer, lao: ^Live_AO) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	for p in ([4]^sdl.GPUGraphicsPipeline{lao.gtao_pipeline, lao.blur_pipeline, lao.depth_pipeline, lao.clear_pipeline}) do if p != nil do gpu_release_graphics_pipeline(r.device, p)
	if lao.sampler != nil do gpu_release_sampler(r.device, lao.sampler)
	for t in ([3]^sdl.GPUTexture{lao.ao, lao.shown, lao.view_depth}) do if t != nil do gpu_release_texture(r.device, t)
	full, partial, skipped := lao.full, lao.partial, lao.skipped
	lao^ = {}
	lao.full, lao.partial, lao.skipped = full, partial, skipped
}

// Identifies what the last run's textures were made for: when any of it changes, the
// next run covers the whole viewport.
@(private = "file")
live_ao_key :: proc(vt: Viewport_Target, proj: Mat4, scale: u32, reach: f32, strength: [3]f32) -> u64 {
	Keyed :: struct { // no padding: every byte is hashed
		proj:          Mat4,
		width, height: u32,
		samples:       u32,
		scale:         u32,
		reach:         f32,
		strength:      [3]f32, // left, right of a wipe's line, and the line
	}
	k := Keyed{proj, vt.width, vt.height, u32(vt.samples), scale, reach, strength}
	return max(hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k))), 1)
}

// Creates the pipelines and sampler on first use, and the textures at the viewport's size
// whenever it, the sample count or `scale` changes.
@(private = "file")
live_ao_ensure :: proc(r: ^Renderer, lao: ^Live_AO, vt: ^Viewport_Target, scale: u32) -> bool {
	if !r.depth_sampled {
		log.warn("live occlusion: this device cannot sample the depth format; it stays off")
		return false
	}
	if lao.gtao_pipeline == nil {
		lao.gtao_pipeline = create_fullscreen_pipeline(r, GTAO_FRAG_CODE, LIVE_AO_FORMAT, samplers = 1)
		lao.blur_pipeline = create_fullscreen_pipeline(r, AO_BLUR_FRAG_CODE, VIEWPORT_COLOR_FORMAT, samplers = 3)
		lao.depth_pipeline = create_shadow_pipeline(r, cull_back = true)
		lao.clear_pipeline = create_depth_clear_pipeline(r)
		lao.sampler = gpu_create_sampler(r.device, {
			min_filter = .NEAREST, mag_filter = .NEAREST, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		if lao.gtao_pipeline == nil || lao.blur_pipeline == nil || lao.depth_pipeline == nil || lao.clear_pipeline == nil || lao.sampler == nil {
			log.errorf("live occlusion: setup failed (%s); it stays off", sdl.GetError())
			return false
		}
	}
	want_view_depth := vt.samples != ._1
	if lao.ao != nil && lao.width == vt.width && lao.height == vt.height && lao.scale == scale && want_view_depth == (lao.view_depth != nil) do return true
	// A frame in flight may still read these; SDL_GPU defers the release until it is done.
	for t in ([3]^sdl.GPUTexture{lao.ao, lao.shown, lao.view_depth}) do if t != nil do gpu_release_texture(r.device, t)
	lao.ao, lao.shown, lao.view_depth = nil, nil, nil
	lao.key = 0
	if want_view_depth {
		lao.view_depth = gpu_create_texture(r.device, {
			type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	lao.ao = gpu_create_texture(r.device, {
		type = .D2, format = LIVE_AO_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = (vt.width + scale - 1) / scale, height = (vt.height + scale - 1) / scale, layer_count_or_depth = 1, num_levels = 1,
	})
	lao.shown = gpu_create_texture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	lao.width, lao.height, lao.scale = vt.width, vt.height, scale
	if lao.ao == nil || lao.shown == nil || want_view_depth && lao.view_depth == nil {
		log.errorf("live occlusion: target creation failed (%s); it stays off", sdl.GetError())
		return false
	}
	return true
}

@(private = "file")
floor_div :: proc(a, b: i32) -> i32 {
	q := a / b
	return q - 1 if a % b != 0 && a < 0 else q
}

@(private = "file")
ceil_div :: proc(a, b: i32) -> i32 {
	return -floor_div(-a, b)
}

// The rectangle from (x0, y0) to (x1, y1), exclusive, clamped to a `w` by `h` target.
@(private = "file")
rect_clamp :: proc(x0, y0, x1, y1, w, h: i32) -> Rect {
	a, b := clamp(x0, 0, w), clamp(y0, 0, h)
	c, d := clamp(x1, 0, w), clamp(y1, 0, h)
	return {a, b, max(c - a, 0), max(d - b, 0)}
}
