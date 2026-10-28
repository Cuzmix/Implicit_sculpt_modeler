package render

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

// The finishing stack: what the viewport shows, finished as a camera's picture is
// (finish.frag.slang), in one full-screen pass over what it would show otherwise. The
// chromatic aberration, bloom, vignette, white balance, contrast and saturation work on
// linear light, as Unreal orders them, the tone curve comes next, and lift, gamma, gain and
// grain work on the encoded values, as a grading panel's do. The bloom is a chain of half
// sizes before it (bloom_down and bloom_up), and sharpening a pass after it, which then takes
// the grain. With every control at its none value finish_active is false and nothing runs,
// so the picture stays the viewport's to the bit.

FINISH_FRAG_SPV :: #load("shaders/finish.frag.spv")
BLOOM_DOWN_FRAG_SPV :: #load("shaders/bloom_down.frag.spv")
BLOOM_UP_FRAG_SPV :: #load("shaders/bloom_up.frag.spv")
SHARPEN_FRAG_SPV :: #load("shaders/sharpen.frag.spv")

// The bloom chain's sizes at most, from half the picture's down: six halvings reach 1/64 of
// it, a glow about a fifth of a 1440p picture across at the widest scatter.
BLOOM_LEVELS_MAX :: 6
// The smallest side a level is made with: below it the tent reads more edge than picture.
BLOOM_LEVEL_MIN :: 8
// The finished picture before sharpening, unrounded so the sharpening and the dither after
// it start from more than 8 bits.
FINISH_MID_FORMAT :: sdl.GPUTextureFormat.R16G16B16A16_FLOAT
// The share of the light the Bloom control's top swaps for the glow, and the spread of the
// Aberration control's top as a share of the distance from the middle: about 9 pixels
// between red and blue in the corner of a 1440p picture, a cheap lens's worst.
BLOOM_MIX_MAX :: 0.3
ABERRATION_SPREAD_MAX :: 0.006

// The curve linear light is shown through. Neutral is display.slang's, the one every
// shading path writes with; AgX is Blender's filmic one, which rolls highlights off over
// more stops and keeps their hue; ACES is the film industry's, more contrast and more
// colour in bright light.
Tone_Curve :: enum u8 {
	Neutral,
	AgX,
	ACES,
}

// What the finishing stack does to the picture.
Finish_Look :: struct {
	curve:         Tone_Curve,
	contrast:      f32, // a power about mid grey: 1 none
	saturation:    f32, // 0 grey, 1 none
	// The colour of light taken as white, in linear sRGB as a factor of D65's: {1, 1, 1}
	// none; a bluer white warms the picture, as a camera's white balance does.
	white:         [3]f32,
	vignette:      f32, // how dark the corners go, 0 none to 1 black
	vignette_soft: f32, // the share of the way from the corners toward the middle it reaches
	lift:          f32, // raises the blacks: 0 none
	gamma:         f32, // brightens the midtones above 1: 1 none
	gain:          f32, // scales the whites: 1 none
	grain:         f32, // 0 none to 1 strong
	grain_size:    f32, // in pixels
	seed:          u32, // the grain's pattern
	bloom:         f32, // 0 none to 1 strong
	bloom_size:    f32, // the scatter, 0 tight to 1 wide
	bloom_threshold: f32, // the linear light the glow starts from: 0, all of it, as a lens scatters
	sharpen:       f32, // 0 none to 1 strong
	aberration:    f32, // 0 none to 1 strong
}

FINISH_NONE :: Finish_Look{contrast = 1, saturation = 1, white = {1, 1, 1}, vignette_soft = 0.6, gamma = 1, gain = 1, grain_size = 1.5, bloom_size = 0.7}

// Whether `look` changes the picture at all: the softness, the grain's size, its pattern,
// the bloom's size and threshold change nothing on their own.
finish_active :: proc(look: Finish_Look) -> bool {
	n := FINISH_NONE
	return look.curve != n.curve || look.contrast != n.contrast || look.saturation != n.saturation || look.white != n.white ||
		look.vignette != n.vignette || look.lift != n.lift || look.gamma != n.gamma || look.gain != n.gain || look.grain != n.grain ||
		look.bloom != n.bloom || look.sharpen != n.sharpen || look.aberration != n.aberration
}

Finish :: struct {
	pipeline:      ^sdl.GPUGraphicsPipeline,
	sampler:       ^sdl.GPUSampler, // bilinear: the aberration's taps and the bloom read between pixels
	shown:         ^sdl.GPUTexture, // the finished picture
	width, height: u32, // of shown
	key:           u64, // what shown was made from (finish_key); 0 when it holds nothing
	failed:        bool, // the device refused part of it; the unfinished picture shows
	passes:        int, // finishing passes run, for the exit stats
	bloomed:       int, // of them, those with the bloom chain
	sharpened:     int, // and those sharpened
	// Sharpening's: the finish pass into the unrounded picture, and the pass from it.
	mid_pipeline:     ^sdl.GPUGraphicsPipeline,
	sharpen_pipeline: ^sdl.GPUGraphicsPipeline,
	mid:              ^sdl.GPUTexture,
	// The bloom chain: each level half the last, down then up, made the first time it is
	// wanted at the picture's size.
	down_pipeline: ^sdl.GPUGraphicsPipeline,
	up_pipeline:   ^sdl.GPUGraphicsPipeline,
	bloom_format:  sdl.GPUTextureFormat,
	down, up:      [BLOOM_LEVELS_MAX]^sdl.GPUTexture,
	level_size:    [BLOOM_LEVELS_MAX][2]u32,
	levels:        int, // 0 while there is no chain
	bloom_for:     [2]u32, // the picture size the chain was made for
}

// Matches Finish_Uniforms in finish.frag.slang.
@(private = "file")
Finish_Uniforms :: struct {
	params:   [4]f32,
	white_x:  [4]f32,
	white_y:  [4]f32,
	white_z:  [4]f32,
	vignette: [4]f32,
	grade:    [4]f32,
	grain:    [4]f32,
	effects:  [4]f32,
}
#assert(size_of(Finish_Uniforms) == 128)

// Matches the uniforms of bloom_down.frag.slang, bloom_up.frag.slang and sharpen.frag.slang.
@(private = "file")
Pass_Uniforms :: struct {
	params: [4]f32,
	size:   [4]f32,
}

// Finishes `source` (width x height) into Finish.shown with `look`. `linear` says the
// source holds exposed linear light (render mode's) rather than Neutral display values.
// `version` names what the source holds: the same source, version and look as last time
// leave shown as it is, so a still view costs nothing. Returns false when the device
// cannot run it, after which it never tries again and finish_texture is nil.
finish_frame :: proc(r: ^Renderer, f: ^Finish, cmd: ^sdl.GPUCommandBuffer, source: ^sdl.GPUTexture, width, height: u32, linear: bool, look: Finish_Look, version: u64) -> bool {
	if f.failed do return false
	if !finish_ensure(r, f, width, height) {
		finish_destroy(r, f)
		f.failed = true
		return false
	}
	key := finish_key(source, width, height, linear, look, version)
	if key == f.key do return true
	if !finish_ensure_effects(r, f, width, height, look) {
		finish_destroy(r, f)
		f.failed = true
		return false
	}
	f.key = key
	f.passes += 1
	sharpen := look.sharpen > 0
	glow := source
	if look.bloom > 0 {
		glow = bloom_chain(f, cmd, source, linear, look)
		f.bloomed += 1
	}
	u := finish_uniforms(look, linear, f32(width) / f32(max(height, 1)), !sharpen)
	samplers := [2]sdl.GPUTextureSamplerBinding{{texture = source, sampler = f.sampler}, {texture = glow, sampler = f.sampler}}
	if !sharpen {
		finish_pass(cmd, f.shown, f.pipeline, samplers[:], &u, size_of(u))
		return true
	}
	f.sharpened += 1
	finish_pass(cmd, f.mid, f.mid_pipeline, samplers[:], &u, size_of(u))
	su := Pass_Uniforms{params = {clamp(look.sharpen, 0, 1), clamp(look.grain, 0, 1), clamp(look.grain_size, 1, 4), transmute(f32)look.seed}}
	finish_pass(cmd, f.shown, f.sharpen_pipeline, {{texture = f.mid, sampler = f.sampler}}, &su, size_of(su.params))
	return true
}

// One full-screen pass of `pipeline` into `target`, reading `samplers`.
@(private = "file")
finish_pass :: proc(cmd: ^sdl.GPUCommandBuffer, target: ^sdl.GPUTexture, pipeline: ^sdl.GPUGraphicsPipeline, samplers: []sdl.GPUTextureSamplerBinding, uniforms: rawptr, uniform_size: int) {
	info := sdl.GPUColorTargetInfo{texture = target, load_op = .DONT_CARE, store_op = .STORE, cycle = true}
	pass := gpu_begin_render_pass(cmd, &info, 1, nil)
	gpu_bind_graphics_pipeline(pass, pipeline)
	gpu_bind_fragment_samplers(pass, 0, raw_data(samplers), u32(len(samplers)))
	gpu_push_fragment_uniform_data(cmd, 0, uniforms, u32(uniform_size))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)
}

// Runs the bloom chain on `source` and returns its glow: down to the smallest level, then up
// again, each step up mixing the coarser glow into the finer level's light by the scatter.
@(private = "file")
bloom_chain :: proc(f: ^Finish, cmd: ^sdl.GPUCommandBuffer, source: ^sdl.GPUTexture, linear: bool, look: Finish_Look) -> ^sdl.GPUTexture {
	threshold := max(look.bloom_threshold, 0)
	for i in 0 ..< f.levels {
		input := source if i == 0 else f.down[i - 1]
		size := f.level_size[i]
		u := Pass_Uniforms{
			params = {1 if i == 0 else 0, 1 if linear else 0, threshold, 0},
			size = {1 / f32(size.x), 1 / f32(size.y), 0, 0},
		}
		finish_pass(cmd, f.down[i], f.down_pipeline, {{texture = input, sampler = f.sampler}}, &u, size_of(u))
	}
	if f.levels == 1 do return f.down[0]
	// Unity HDRP's range of scatter: never all of one size.
	scatter := math.lerp(f32(0.05), 0.95, clamp(look.bloom_size, 0, 1))
	for i := f.levels - 2; i >= 0; i -= 1 {
		coarse := f.down[i + 1] if i == f.levels - 2 else f.up[i + 1]
		size := f.level_size[i]
		u := Pass_Uniforms{params = {scatter, 0, 0, 0}, size = {1 / f32(size.x), 1 / f32(size.y), 0, 0}}
		finish_pass(cmd, f.up[i], f.up_pipeline, {{texture = coarse, sampler = f.sampler}, {texture = f.down[i], sampler = f.sampler}}, &u, size_of(u))
	}
	return f.up[0]
}

// The finished picture, or nil when there is none (finish_frame has not run since the
// last reset, or the device cannot run it).
finish_texture :: proc(f: ^Finish) -> ^sdl.GPUTexture {
	if f.failed || f.key == 0 do return nil
	return f.shown
}

// Makes finish_texture nil until the next finish_frame, as when the finishing stack stops.
finish_reset :: proc(f: ^Finish) {
	f.key = 0
}

finish_destroy :: proc(r: ^Renderer, f: ^Finish) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	for p in ([?]^sdl.GPUGraphicsPipeline{f.pipeline, f.mid_pipeline, f.sharpen_pipeline, f.down_pipeline, f.up_pipeline}) {
		if p != nil do gpu_release_graphics_pipeline(r.device, p)
	}
	if f.sampler != nil do gpu_release_sampler(r.device, f.sampler)
	if f.shown != nil do gpu_release_texture(r.device, f.shown)
	if f.mid != nil do gpu_release_texture(r.device, f.mid)
	bloom_release(r, f)
	f^ = {failed = f.failed, passes = f.passes, bloomed = f.bloomed, sharpened = f.sharpened}
}

@(private = "file")
bloom_release :: proc(r: ^Renderer, f: ^Finish) {
	for i in 0 ..< BLOOM_LEVELS_MAX {
		if f.down[i] != nil do gpu_release_texture(r.device, f.down[i])
		if f.up[i] != nil do gpu_release_texture(r.device, f.up[i])
	}
	f.down, f.up, f.levels, f.bloom_for = {}, {}, 0, {}
}

// The bloom chain's level sizes for a picture of `width` x `height`: half its size, then
// half again while the smaller side keeps BLOOM_LEVEL_MIN pixels, BLOOM_LEVELS_MAX at most;
// one level always, however small the picture.
bloom_levels :: proc(width, height: u32) -> (sizes: [BLOOM_LEVELS_MAX][2]u32, count: int) {
	w, h := max(width / 2, 1), max(height / 2, 1)
	for count < BLOOM_LEVELS_MAX {
		sizes[count] = {w, h}
		count += 1
		if min(w, h) / 2 < BLOOM_LEVEL_MIN do break
		w, h = w / 2, h / 2
	}
	return
}

// The white balance as a matrix on linear sRGB: von Kries scaling in Bradford's cone
// space, taking `white` to D65's white, as Blender's and Lightroom's do. The identity for
// {1, 1, 1}.
white_balance :: proc(white: [3]f32) -> matrix[3, 3]f32 {
	// Linear sRGB to XYZ (D65), and XYZ to Bradford's cone responses.
	RGB_XYZ :: matrix[3, 3]f32{
		0.4124564, 0.3575761, 0.1804375,
		0.2126729, 0.7151522, 0.0721750,
		0.0193339, 0.1191920, 0.9503041,
	}
	BRADFORD :: matrix[3, 3]f32{
		0.8951, 0.2664, -0.1614,
		-0.7502, 1.7135, 0.0367,
		0.0389, -0.0685, 1.0296,
	}
	to_cone := BRADFORD * RGB_XYZ
	src := to_cone * linalg.Vector3f32(white)
	dst := to_cone * linalg.Vector3f32{1, 1, 1}
	scale := matrix[3, 3]f32{
		dst.x / max(src.x, 1e-6), 0, 0,
		0, dst.y / max(src.y, 1e-6), 0,
		0, 0, dst.z / max(src.z, 1e-6),
	}
	return linalg.inverse(to_cone) * scale * to_cone
}

// PBR Neutral's curve as display.slang's tone_map has it, for the tests.
tone_neutral :: proc(c: [3]f32) -> [3]f32 {
	START :: 0.8 - 0.04
	DESATURATION :: 0.15
	c := c
	x := min(c.r, c.g, c.b)
	offset: f32 = x - 6.25 * x * x if x < 0.08 else 0.04
	c -= offset
	peak := max(c.r, c.g, c.b)
	if peak < START do return c
	d :: 1.0 - START
	new_peak := 1 - d * d / (peak + d - START)
	c *= new_peak / peak
	g := 1 - 1 / (DESATURATION * (peak - new_peak) + 1)
	return c + (new_peak - c) * g
}

// tone_neutral undone as display.slang's neutral_inverse does it, for the tests.
tone_neutral_inverse :: proc(y: [3]f32) -> [3]f32 {
	START :: 0.8 - 0.04
	DESATURATION :: 0.15
	TOP :: 0.99555
	d :: 1.0 - START
	c := y
	new_peak := min(max(y.r, y.g, y.b), TOP)
	if new_peak >= START {
		peak := START - d + d * d / (1 - new_peak)
		g := 1 - 1 / (DESATURATION * (peak - new_peak) + 1)
		c = ([3]f32{min(y.r, new_peak), min(y.g, new_peak), min(y.b, new_peak)} - g * new_peak) / (1 - g)
		c *= peak / new_peak
	}
	least := max(min(c.r, c.g, c.b), 0)
	offset: f32 = 0.4 * math.sqrt(least) - least if least < 0.04 else 0.04
	c += offset
	return {max(c.r, 0), max(c.g, 0), max(c.b, 0)}
}

@(private = "file")
finish_uniforms :: proc(look: Finish_Look, linear: bool, aspect: f32, ends: bool) -> (u: Finish_Uniforms) {
	w := white_balance(look.white)
	u.params = {f32(look.curve), 1 if linear else 0, max(look.contrast, 0.01), max(look.saturation, 0)}
	u.white_x = {w[0, 0], w[1, 0], w[2, 0], 0}
	u.white_y = {w[0, 1], w[1, 1], w[2, 1], 0}
	u.white_z = {w[0, 2], w[1, 2], w[2, 2], 0}
	u.vignette = {clamp(look.vignette, 0, 1), clamp(look.vignette_soft, 0.05, 1), aspect, 0}
	u.grade = {look.lift, max(look.gamma, 0.01), max(look.gain, 0), clamp(look.grain, 0, 1)}
	u.grain = {clamp(look.grain_size, 1, 4), transmute(f32)look.seed, 0, 0}
	u.effects = {BLOOM_MIX_MAX * clamp(look.bloom, 0, 1), ABERRATION_SPREAD_MAX * clamp(look.aberration, 0, 1), 1 if ends else 0, max(look.bloom_threshold, 0)}
	return
}

// What a finished picture is made from: the source, its size and contents, and the look.
@(private = "file")
finish_key :: proc(source: ^sdl.GPUTexture, width, height: u32, linear: bool, look: Finish_Look, version: u64) -> u64 {
	Key :: struct {
		source:        uintptr,
		width, height: u32,
		linear:        bool,
		look:          Finish_Look,
		version:       u64,
	}
	k := Key{uintptr(rawptr(source)), width, height, linear, look, version}
	return max(hash.fnv64a(([^]u8)(&k)[:size_of(k)]), 1)
}

// Creates the pipeline and sampler on first use, and the finished picture at the size
// asked whenever it changes.
@(private = "file")
finish_ensure :: proc(r: ^Renderer, f: ^Finish, width, height: u32) -> bool {
	if f.pipeline == nil {
		f.pipeline = create_fullscreen_pipeline(r, FINISH_FRAG_SPV, VIEWPORT_COLOR_FORMAT, samplers = 2)
		f.sampler = gpu_create_sampler(r.device, {
			min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		if f.pipeline == nil || f.sampler == nil {
			log.errorf("finishing: setup failed (%s); the picture shows unfinished", sdl.GetError())
			return false
		}
	}
	if f.shown != nil && f.width == width && f.height == height do return true
	if f.shown != nil do gpu_release_texture(r.device, f.shown)
	f.shown = gpu_create_texture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
	})
	f.width, f.height, f.key = width, height, 0
	if f.shown == nil {
		log.errorf("finishing: target creation failed (%s); the picture shows unfinished", sdl.GetError())
		return false
	}
	if f.mid != nil do gpu_release_texture(r.device, f.mid)
	f.mid = nil
	bloom_release(r, f)
	return true
}

// Creates what sharpening and the bloom need, the first time `look` asks for them at this size.
@(private = "file")
finish_ensure_effects :: proc(r: ^Renderer, f: ^Finish, width, height: u32, look: Finish_Look) -> bool {
	if look.sharpen > 0 {
		if f.mid_pipeline == nil do f.mid_pipeline = create_fullscreen_pipeline(r, FINISH_FRAG_SPV, FINISH_MID_FORMAT, samplers = 2)
		if f.sharpen_pipeline == nil do f.sharpen_pipeline = create_fullscreen_pipeline(r, SHARPEN_FRAG_SPV, VIEWPORT_COLOR_FORMAT, samplers = 1)
		if f.mid == nil {
			f.mid = gpu_create_texture(r.device, {
				type = .D2, format = FINISH_MID_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
				width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
			})
		}
		if f.mid_pipeline == nil || f.sharpen_pipeline == nil || f.mid == nil {
			log.errorf("finishing: sharpening setup failed (%s); the picture shows unfinished", sdl.GetError())
			return false
		}
	}
	if look.bloom > 0 {
		if f.down_pipeline == nil {
			// Packed floats where the device draws into them, at half half-floats' memory.
			f.bloom_format = .R11G11B10_UFLOAT
			if !gpu_texture_supports_format(r.device, f.bloom_format, .D2, {.COLOR_TARGET, .SAMPLER}) do f.bloom_format = .R16G16B16A16_FLOAT
			f.down_pipeline = create_fullscreen_pipeline(r, BLOOM_DOWN_FRAG_SPV, f.bloom_format, samplers = 1)
			f.up_pipeline = create_fullscreen_pipeline(r, BLOOM_UP_FRAG_SPV, f.bloom_format, samplers = 2)
			if f.down_pipeline == nil || f.up_pipeline == nil {
				log.errorf("finishing: bloom setup failed (%s); the picture shows unfinished", sdl.GetError())
				return false
			}
		}
		if f.levels == 0 || f.bloom_for != {width, height} {
			bloom_release(r, f)
			f.level_size, f.levels = bloom_levels(width, height)
			f.bloom_for = {width, height}
			for i in 0 ..< f.levels {
				info := sdl.GPUTextureCreateInfo{
					type = .D2, format = f.bloom_format, usage = {.COLOR_TARGET, .SAMPLER},
					width = f.level_size[i].x, height = f.level_size[i].y, layer_count_or_depth = 1, num_levels = 1,
				}
				f.down[i] = gpu_create_texture(r.device, info)
				// The finest level's upsample is the glow; the coarsest has none.
				if i < f.levels - 1 do f.up[i] = gpu_create_texture(r.device, info)
				if f.down[i] == nil || (i < f.levels - 1 && f.up[i] == nil) {
					log.errorf("finishing: bloom targets failed (%s); the picture shows unfinished", sdl.GetError())
					return false
				}
			}
		}
	}
	return true
}

// finish.frag.slang's AgX sigmoid, its constants as it has them: mid grey's place in the log
// encoding, the slope there, and each side's power and the scale that puts its end at
// exactly 0 or 1 (agx_scale gives them).
AGX_PIVOT_X :: 0.6060605707714036
AGX_SLOPE :: 2.0
AGX_TOE_POWER :: 3.0
AGX_SHOULDER_POWER :: 2.85
AGX_TOE_SCALE :: 0.5122773845447605
AGX_SHOULDER_SCALE :: 0.5593522525840448

// The scale of a side of the sigmoid that reaches `reach` (above or below mid grey's 0.5)
// over `run` of the encoding with slope AGX_SLOPE, as a hyperbola of `power`.
agx_scale :: proc(run, reach, power: f64) -> f64 {
	a := AGX_SLOPE * run
	return a / math.pow(math.pow(a / reach, power) - 1, 1 / power)
}

// finish.frag.slang's scales of the light before AgX's and ACES's curves, which show mid grey
// as tone_neutral does.
AGX_EXPOSURE :: 0.5942082129838109
ACES_EXPOSURE :: 1.2159790709970744

// finish.frag.slang's agx_sigmoid, for the tests.
agx_sigmoid :: proc(x: f64) -> f64 {
	shoulder := x >= AGX_PIVOT_X
	scale: f64 = AGX_SHOULDER_SCALE if shoulder else AGX_TOE_SCALE
	power: f64 = AGX_SHOULDER_POWER if shoulder else AGX_TOE_POWER
	u := AGX_SLOPE * (x - AGX_PIVOT_X) / scale
	return 0.5 + scale * u / math.pow(1 + math.pow(abs(u), power), 1 / power)
}

// finish.frag.slang's AgX for a grey (the inset and outset leave greys alone), for the tests.
agx_grey :: proc(v: f64) -> f64 {
	LOW :: -12.47393
	HIGH :: 4.026069
	x := (clamp(math.log2(max(v, 1e-10)), LOW, HIGH) - LOW) / (HIGH - LOW)
	return math.pow(clamp(agx_sigmoid(x), 0, 1), 2.2)
}

// finish.frag.slang's ACES fit for a grey (its matrices leave greys almost alone), for the tests.
aces_grey :: proc(v: f64) -> f64 {
	a := v * (v + 0.0245786) - 0.000090537
	b := v * (0.983729 * v + 0.4329510) + 0.238081
	return a / b
}
