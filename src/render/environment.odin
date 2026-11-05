package render

import "../gpu"
import "core:log"
import "core:math/bits"
import "core:mem"

// Image environments (image-based lighting): an equirectangular panorama the physically
// based materials reflect and take their diffuse light from in place of the built-in
// studio, and that the background can show. The panorama goes up as an RGBA16F texture
// with a full mip chain (the source), then is prefiltered once, on the GPU, into a
// texture half its size whose levels hold it as GGX lobes of growing roughness see it
// (env_prefilter.frag.slang), so a reflection at any roughness is one texture fetch. Its
// diffuse light comes as nine spherical harmonics the app works out on the CPU.

// The prefiltered texture's levels: roughness 0, 0.2, ... 1. Fewer for a panorama too
// small to halve that often.
ENV_LEVELS :: 6

ENV_FORMAT :: gpu.Format.RGBA16_Float

Environment :: struct {
	source:        gpu.Texture,
	prefiltered:   gpu.Texture,
	levels:        int, // the prefiltered texture's
	width, height: int, // the source's
	sh:            [9][3]f32,
	// Render mode's table for sampling it by brightness (env_sample.odin), its size, and
	// its mean luminance over the sphere.
	table:         gpu.Texture,
	table_width:   int,
	table_height:  int,
	mean:          f32,
	// From Renderer.last_version, so the frame keys tell a new one from an old one at the
	// same address.
	stamp:         u64,
}

// How the environment shows this frame (Renderer.environment_look, set by the app): the
// panorama's axes in view space as the columns of a rotation (w unused), its strength as
// a linear factor, the Blur of the background (0 to 1), the exposure the background is
// shown with, and whether the background shows it. No padding: it is hashed.
Environment_Look :: struct {
	rotation:   [3][4]f32,
	strength:   f32,
	blur:       f32,
	exposure:   f32,
	background: b32,
}
#assert(size_of(Environment_Look) == 64)

// Matches Prefilter_Uniforms in env_prefilter.frag.slang.
@(private = "file")
Prefilter_Uniforms :: struct {
	params: [4]f32, // x: roughness, y: the source's width, z: its height
	target: [4]f32, // xy: the level's size, z: the source mip a mirror reads
}

// Makes an environment from `pixels`, linear RGB rows top (straight up) to bottom,
// `width` by `height` (2:1, at least 64 wide), and its harmonics `sh`: uploads it,
// builds its mips and prefilters it on a command buffer of its own, waiting for the GPU,
// so it may be called outside a frame. False, with the reason logged, when the device
// refuses; nothing is left made then.
environment_create :: proc(r: ^Renderer, pixels: [][3]f32, width, height: int, sh: [9][3]f32) -> (env: Environment, ok: bool) {
	assert(len(pixels) == width * height && width >= 2 && height >= 2)
	defer if !ok do environment_destroy(r, &env)
	env.width, env.height, env.sh = width, height, sh
	pw, ph := width / 2, height / 2
	env.levels = min(ENV_LEVELS, int(bits.log2(uint(ph))) + 1)
	env.source = gpu.create_texture({
		type = .D2, format = ENV_FORMAT, usage = {.Sampled, .Color_Target},
		width = u32(width), height = u32(height), layer_count_or_depth = 1,
		num_levels = u32(bits.log2(uint(width))) + 1,
	})
	env.prefiltered = gpu.create_texture({
		type = .D2, format = ENV_FORMAT, usage = {.Sampled, .Color_Target},
		width = u32(pw), height = u32(ph), layer_count_or_depth = 1, num_levels = u32(env.levels),
	})
	if env.source == 0 || env.prefiltered == 0 {
		log.errorf("environment %d x %d: %s", width, height, gpu.last_error())
		return
	}
	half := make([][4]f16, len(pixels))
	defer delete(half)
	for p, i in pixels do half[i] = {f16(p.x), f16(p.y), f16(p.z), 1}
	if !texture_upload(r, env.source, mem.slice_to_bytes(half), width, height, mips = true) do return
	lum, tw, th := env_table_luminance(pixels, width, height, context.temp_allocator)
	table := env_table_build(lum, tw, th, context.temp_allocator)
	env.table = env_table_texture(r, table)
	if env.table == 0 do return
	env.table_width, env.table_height, env.mean = tw, th, table.mean

	pipeline := create_prefilter_pipeline(r)
	if pipeline == 0 do return
	defer gpu.release_graphics_pipeline(pipeline)
	cmd := gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("environment prefilter: %s", gpu.last_error())
		return
	}
	for level in 0 ..< env.levels {
		target := gpu.Color_Target{texture = env.prefiltered, mip_level = u32(level), load_op = .Dont_Care, store_op = .Store}
		pass := gpu.begin_render_pass(cmd, &target, 1, nil)
		gpu.bind_graphics_pipeline(pass, pipeline)
		samplers := [Env_Prefilter_Frag_Samplers]gpu.Texture_Sampler_Binding{.source = {texture = env.source, sampler = r.env_sampler}}
		bind_fragment_samplers(pass, &samplers)
		u := Prefilter_Uniforms {
			params = {f32(level) / f32(max(env.levels - 1, 1)), f32(width), f32(height), 0},
			target = {f32(max(pw >> uint(level), 1)), f32(max(ph >> uint(level), 1)), 1, 0},
		}
		push_fragment(cmd, Env_Prefilter_Frag_Uniforms.Prefilter_Uniforms, &u)
		gpu.draw_primitives(pass, 3, 1, 0, 0)
		gpu.end_render_pass(pass)
	}
	ticket, submitted := gpu.submit(cmd)
	if !submitted {
		log.errorf("environment prefilter submit: %s", gpu.last_error())
		return
	}
	if !gpu.wait(ticket) {
		log.errorf("environment prefilter wait: %s", gpu.last_error())
		return
	}
	r.last_version += 1
	env.stamp = r.last_version
	return env, true
}

// Releases the textures; a frame in flight that samples them keeps them until it is done.
environment_destroy :: proc(r: ^Renderer, env: ^Environment) {
	if env.source == 0 && env.prefiltered == 0 && env.table == 0 do return
	if env.source != 0 do gpu.release_texture(env.source)
	if env.prefiltered != 0 do gpu.release_texture(env.prefiltered)
	if env.table != 0 do gpu.release_texture(env.table)
	env^ = {}
}

// The bytes the environment's textures hold on the GPU, mips included.
environment_bytes :: proc(env: Environment) -> int {
	if env.source == 0 do return 0
	// A full mip chain adds a third; each texel is 8 bytes.
	source := env.width * env.height * 8 * 4 / 3
	prefiltered := 0
	for level in 0 ..< env.levels do prefiltered += max(env.width / 2 >> uint(level), 1) * max(env.height / 2 >> uint(level), 1) * 8
	return source + prefiltered + env.table_width * env.table_height * 16
}

// The environment's part of a mesh draw's uniforms, left zero (the studio) without one.
@(private)
material_environment :: proc(r: ^Renderer, m: ^Material_Uniforms) {
	env := r.environment
	if env == nil do return
	look := r.environment_look
	m.env = {1, look.strength, f32(env.levels - 1), 0}
	m.env_axes = look.rotation
	for c, k in env.sh do m.env_sh[k] = {c.x, c.y, c.z, 0}
}

// The prefiltered environment's binding: every pipeline that has the sampler is given one,
// the black stand-in when there is no environment.
@(private)
environment_binding :: proc(r: ^Renderer) -> gpu.Texture_Sampler_Binding {
	texture := r.environment.prefiltered if r.environment != nil else r.no_environment
	return {texture = texture, sampler = r.env_sampler}
}

// Whether the background shows the environment this frame.
@(private)
environment_background :: proc(r: ^Renderer) -> bool {
	return r.environment != nil && bool(r.environment_look.background)
}

// What the frame keys hash of the environment: which one, and how it shows; all zero
// without one, so the look of an environment not in use changes nothing.
@(private)
Environment_Keyed :: struct {
	stamp: u64,
	look:  Environment_Look,
}

@(private)
environment_keyed :: proc(r: ^Renderer) -> Environment_Keyed {
	if r.environment == nil do return {}
	return {r.environment.stamp, r.environment_look}
}

@(private = "file")
create_prefilter_pipeline :: proc(r: ^Renderer) -> gpu.Graphics_Pipeline {
	vert := gpu.create_shader(CLEAR_VERT)
	frag := gpu.create_shader(ENV_PREFILTER_FRAG)
	defer if vert != 0 do gpu.release_shader(vert)
	defer if frag != 0 do gpu.release_shader(frag)
	if vert == 0 || frag == 0 {
		log.errorf("environment prefilter shaders: %s", gpu.last_error())
		return 0
	}
	color_targets := [1]gpu.Color_Target_Desc{{format = ENV_FORMAT}}
	pipeline := gpu.create_graphics_pipeline({
		vertex_shader = vert,
		fragment_shader = frag,
		primitive = .Triangle_List,
		rasterizer_state = {fill_mode = .Fill, cull_mode = .None},
		targets = {color_targets = color_targets[:]},
	})
	if pipeline == 0 do log.errorf("environment prefilter pipeline: %s", gpu.last_error())
	return pipeline
}
