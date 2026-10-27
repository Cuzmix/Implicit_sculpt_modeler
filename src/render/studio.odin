package render

import "core:log"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

// The studio render: while nothing on screen changes, each frame adds one shadow-mapped
// light sample to an accumulation target, and the viewport is shown darkened by what
// the samples found, so it settles over a second or two into ambient occlusion and a
// soft key light shadow, much like a path-traced preview. Ambient samples come from
// directions all round the scene; one sample in STUDIO_KEY_EVERY comes from around the
// mesh shader's key light, jittered over a small disc, which softens the shadow's edge.
// Any change to the viewport (a stroke, the camera, a resize) starts over; until then
// the plain viewport is copied through, so the cost while working is one copy a frame.
Studio :: struct {
	shadow_pipeline:    ^sdl.GPUGraphicsPipeline,
	depth_pipeline:     ^sdl.GPUGraphicsPipeline, // the camera's depth, front faces only, as the mesh pipeline
	gather_pipeline:    ^sdl.GPUGraphicsPipeline,
	composite_pipeline: ^sdl.GPUGraphicsPipeline,
	sampler:            ^sdl.GPUSampler,
	shadow:             ^sdl.GPUTexture, // depth from the light of the current sample
	accum:              ^sdl.GPUTexture, // summed samples: see studio_gather.frag
	shown:              ^sdl.GPUTexture, // what the viewport panel shows
	// The camera's depth at one sample, drawn when the viewport is multisampled, whose
	// own depth shaders cannot read; nil otherwise.
	view_depth:         ^sdl.GPUTexture,
	width, height:      u32, // of accum and shown
	samples:            int, // in accum
	shown_valid:        bool, // shown holds this frame's viewport, with or without samples
	failed:             bool, // the device refused part of it; the plain viewport shows
}

// Shadow map size: fine enough for a crevice a few pixels wide at the default view.
STUDIO_SHADOW_SIZE :: 2048
// One sample in this many is a key light sample; the rest are ambient.
STUDIO_KEY_EVERY :: 4
// Radius of the disc the key light is jittered over, in radians: its shadow's softness.
STUDIO_KEY_SOFTNESS :: 0.06
// Depth bias and normal offset in shadow map texels: enough to keep a curved surface
// from shadowing itself without letting thin gaps leak light.
STUDIO_DEPTH_BIAS_TEXELS :: 2
STUDIO_NORMAL_OFFSET_TEXELS :: 1.5

STUDIO_ACCUM_FORMAT :: sdl.GPUTextureFormat.R16G16B16A16_FLOAT

SHADOW_VERT_SPV :: #load("shaders/shadow.vert.spv")
SHADOW_FRAG_SPV :: #load("shaders/shadow.frag.spv")
STUDIO_GATHER_FRAG_SPV :: #load("shaders/studio_gather.frag.spv")
STUDIO_COMPOSITE_FRAG_SPV :: #load("shaders/studio_composite.frag.spv")

// Matches Gather_Uniforms in studio_gather.frag.
@(private = "file")
Gather_Uniforms :: struct {
	inv_view_proj:   Mat4,
	light_view_proj: Mat4,
	light_dir:       [4]f32,
	params:          [4]f32,
}

// Records this frame's studio work after render_viewport: starts over when `changed`
// (anything was redrawn this frame), otherwise adds a sample until there are
// `max_samples`, and leaves the result in Studio.shown. `ao` and `shadow` (0 to 1) are
// how strongly occlusion and the key light's shadow darken the image; `lights` are the
// lights the items are shaded with, whose brightest casts the shadow (lights_key). Returns false
// only when the studio cannot run on this device, after which it never tries again.
studio_frame :: proc(r: ^Renderer, st: ^Studio, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, changed: bool, max_samples: int, ao, shadow: f32, lights: Lights = {}) -> bool {
	if st.failed do return false
	if !studio_ensure(r, st, vt) {
		st.failed = true
		studio_destroy(r, st)
		st.failed = true
		return false
	}
	if changed || !st.shown_valid {
		st.samples = 0
		st.shown_valid = true
		copy_pass := sdl.BeginGPUCopyPass(cmd)
		sdl.CopyGPUTextureToTexture(copy_pass, {texture = vt.color}, {texture = st.shown}, vt.width, vt.height, 1, cycle = true)
		sdl.EndGPUCopyPass(copy_pass)
		return true
	}
	if st.samples >= max_samples do return true
	center, radius, ok := scene_sphere(items)
	if !ok do return true

	// This sample's light: all round the scene for ambient, around the key light for the
	// shadow. The R2 sequence spreads consecutive samples evenly at any count.
	k := st.samples
	u := math.mod(0.5 + f32(k) * 0.7548777, 1)
	v := math.mod(0.5 + f32(k) * 0.5698403, 1)
	// With no light on there is no shadow, and every sample goes to the occlusion.
	key_dir, lit := lights_key(lights, (view * [4]f32{center.x, center.y, center.z, 1}).xyz)
	key := lit && k % STUDIO_KEY_EVERY == STUDIO_KEY_EVERY - 1
	dir: [3]f32
	if key {
		rot := linalg.transpose(linalg.Matrix3f32{view[0, 0], view[0, 1], view[0, 2], view[1, 0], view[1, 1], view[1, 2], view[2, 0], view[2, 1], view[2, 2]})
		base := linalg.normalize(rot * key_dir)
		side := linalg.normalize(linalg.cross(base, [3]f32{0, 1, 0} if abs(base.y) < 0.99 else [3]f32{1, 0, 0}))
		up := linalg.cross(side, base)
		a, rr := 2 * math.PI * v, STUDIO_KEY_SOFTNESS * math.sqrt(u)
		dir = linalg.normalize(base + (side * math.cos(a) + up * math.sin(a)) * rr)
	} else {
		z := 1 - 2 * u
		ring := math.sqrt(max(1 - z * z, 0))
		dir = {ring * math.cos(2 * math.PI * v), z, ring * math.sin(2 * math.PI * v)}
	}
	light := light_view_proj(center, radius, dir)

	// The depth the gather reads: the viewport's own, or with multisampling the camera's
	// drawn again at one sample, once per still view (it is the same for every sample).
	view_depth := vt.depth
	if vt.samples != ._1 {
		view_depth = st.view_depth
		if st.samples == 0 do view_depth_draw(r, cmd, st.depth_pipeline, nil, st.view_depth, vt.width, vt.height, view, proj, items)
	}

	// Depth from the light, every triangle of every item.
	depth := sdl.GPUDepthStencilTargetInfo {
		texture          = st.shadow,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .STORE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
		cycle            = true,
	}
	pass := sdl.BeginGPURenderPass(cmd, nil, 0, &depth)
	sdl.BindGPUGraphicsPipeline(pass, st.shadow_pipeline)
	for item in items {
		mb := item.mesh
		u := Shadow_Uniforms{light, item.model}
		sdl.PushGPUVertexUniformData(cmd, 0, &u, size_of(u))
		vbufs := [1]sdl.GPUBufferBinding{{buffer = mb.positions}}
		sdl.BindGPUVertexBuffers(pass, 0, &vbufs[0], 1)
		sdl.BindGPUIndexBuffer(pass, {buffer = mb.indices}, ._32BIT)
		sdl.DrawGPUIndexedPrimitives(pass, mb.index_count, 1, 0, 0, 0)
	}
	sdl.EndGPURenderPass(pass)

	// Add what that light reaches to the accumulation target.
	texel := 2 * radius / STUDIO_SHADOW_SIZE
	g := Gather_Uniforms {
		inv_view_proj   = linalg.inverse(proj * view),
		light_view_proj = light,
		light_dir       = {dir.x, dir.y, dir.z, 1 if key else 0},
		params          = {STUDIO_DEPTH_BIAS_TEXELS / f32(STUDIO_SHADOW_SIZE), STUDIO_NORMAL_OFFSET_TEXELS * texel, 1 / f32(STUDIO_SHADOW_SIZE), 0},
	}
	target := sdl.GPUColorTargetInfo {
		texture  = st.accum,
		load_op  = .CLEAR if st.samples == 0 else .LOAD,
		store_op = .STORE,
	}
	pass = sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	sdl.BindGPUGraphicsPipeline(pass, st.gather_pipeline)
	samplers := [2]sdl.GPUTextureSamplerBinding{{texture = view_depth, sampler = st.sampler}, {texture = st.shadow, sampler = st.sampler}}
	sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], 2)
	sdl.PushGPUFragmentUniformData(cmd, 0, &g, size_of(g))
	sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	sdl.EndGPURenderPass(pass)
	st.samples += 1

	// The image shown: the viewport darkened by what the samples found.
	target = {texture = st.shown, load_op = .DONT_CARE, store_op = .STORE, cycle = true}
	pass = sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	sdl.BindGPUGraphicsPipeline(pass, st.composite_pipeline)
	samplers = {{texture = vt.color, sampler = st.sampler}, {texture = st.accum, sampler = st.sampler}}
	sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], 2)
	params := [4]f32{clamp(ao, 0, 1), clamp(shadow, 0, 1), 0, 0}
	sdl.PushGPUFragmentUniformData(cmd, 0, &params, size_of(params))
	sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	sdl.EndGPURenderPass(pass)
	return true
}

// What the viewport panel should show while the studio render is on: its image, or nil
// when there is none yet (or the device cannot make one) and the plain viewport shows.
studio_texture :: proc(st: ^Studio) -> ^sdl.GPUTexture {
	if st.failed || !st.shown_valid do return nil
	return st.shown
}

// Makes the next studio_frame start over and show the plain viewport, as when the studio
// render is turned off and on.
studio_reset :: proc(st: ^Studio) {
	st.samples = 0
	st.shown_valid = false
}

studio_destroy :: proc(r: ^Renderer, st: ^Studio) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	if st.shadow_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, st.shadow_pipeline)
	if st.depth_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, st.depth_pipeline)
	if st.gather_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, st.gather_pipeline)
	if st.composite_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, st.composite_pipeline)
	if st.sampler != nil do sdl.ReleaseGPUSampler(r.device, st.sampler)
	for t in ([4]^sdl.GPUTexture{st.shadow, st.accum, st.shown, st.view_depth}) do if t != nil do sdl.ReleaseGPUTexture(r.device, t)
	st^ = {}
}

// A light looking at the scene's bounding sphere from `dir`, parallel, its depth range
// just covering the sphere.
@(private = "file")
light_view_proj :: proc(center: [3]f32, radius: f32, dir: [3]f32) -> Mat4 {
	eye := center + dir * (2 * radius)
	up := [3]f32{0, 1, 0} if abs(dir.y) < 0.99 else [3]f32{1, 0, 0}
	f := linalg.normalize(center - eye)
	s := linalg.normalize(linalg.cross(f, up))
	u := linalg.cross(s, f)
	view := Mat4{
		s.x, s.y, s.z, -linalg.dot(s, eye),
		u.x, u.y, u.z, -linalg.dot(u, eye),
		-f.x, -f.y, -f.z, linalg.dot(f, eye),
		0, 0, 0, 1,
	}
	near, far := radius * 0.9, radius * 3.1
	h := 1 / radius
	proj := Mat4{
		h, 0, 0, 0,
		0, h, 0, 0,
		0, 0, 1 / (near - far), near / (near - far),
		0, 0, 0, 1,
	}
	return proj * view
}

// Creates the pipelines, sampler and shadow map on first use, and the accumulation and
// shown textures at the viewport's size whenever it changes.
@(private = "file")
studio_ensure :: proc(r: ^Renderer, st: ^Studio, vt: ^Viewport_Target) -> bool {
	if !r.depth_sampled {
		log.warn("studio render: this device cannot sample the depth format; it stays off")
		return false
	}
	if st.shadow_pipeline == nil {
		st.shadow_pipeline = create_shadow_pipeline(r, cull_back = false)
		st.depth_pipeline = create_shadow_pipeline(r, cull_back = true)
		st.gather_pipeline = create_fullscreen_pipeline(r, STUDIO_GATHER_FRAG_SPV, STUDIO_ACCUM_FORMAT, samplers = 2, additive = true)
		st.composite_pipeline = create_fullscreen_pipeline(r, STUDIO_COMPOSITE_FRAG_SPV, VIEWPORT_COLOR_FORMAT, samplers = 2)
		st.sampler = sdl.CreateGPUSampler(r.device, {
			min_filter = .NEAREST, mag_filter = .NEAREST, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		st.shadow = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = STUDIO_SHADOW_SIZE, height = STUDIO_SHADOW_SIZE, layer_count_or_depth = 1, num_levels = 1,
		})
		if st.shadow_pipeline == nil || st.depth_pipeline == nil || st.gather_pipeline == nil || st.composite_pipeline == nil || st.sampler == nil || st.shadow == nil {
			log.errorf("studio render: setup failed (%s); it stays off", sdl.GetError())
			return false
		}
	}
	want_view_depth := vt.samples != ._1
	if st.accum != nil && st.width == vt.width && st.height == vt.height && want_view_depth == (st.view_depth != nil) do return true
	for t in ([3]^sdl.GPUTexture{st.accum, st.shown, st.view_depth}) do if t != nil do sdl.ReleaseGPUTexture(r.device, t)
	st.view_depth = nil
	if want_view_depth {
		st.view_depth = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	st.accum = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = STUDIO_ACCUM_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	st.shown = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	st.width, st.height = vt.width, vt.height
	st.samples, st.shown_valid = 0, false
	if st.accum == nil || st.shown == nil || want_view_depth && st.view_depth == nil {
		log.errorf("studio render: target creation failed (%s); it stays off", sdl.GetError())
		return false
	}
	return true
}
