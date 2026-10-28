package render

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

// The finishing stack: what the viewport shows, finished as a camera's picture is
// (finish.frag), in one full-screen pass over what it would show otherwise. The vignette,
// white balance, contrast and saturation work on linear light, as Unreal orders them, the
// tone curve comes next, and lift, gamma, gain and grain work on the encoded values, as a
// grading panel's do. With every control at its none value finish_active is false and
// nothing runs, so the picture stays the viewport's to the bit.

FINISH_FRAG_SPV :: #load("shaders/finish.frag.spv")

// The curve linear light is shown through. Neutral is display.glsl's, the one every
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
}

FINISH_NONE :: Finish_Look{contrast = 1, saturation = 1, white = {1, 1, 1}, vignette_soft = 0.6, gamma = 1, gain = 1, grain_size = 1.5}

// Whether `look` changes the picture at all: the softness, the grain's size and its
// pattern change nothing on their own.
finish_active :: proc(look: Finish_Look) -> bool {
	n := FINISH_NONE
	return look.curve != n.curve || look.contrast != n.contrast || look.saturation != n.saturation || look.white != n.white ||
		look.vignette != n.vignette || look.lift != n.lift || look.gamma != n.gamma || look.gain != n.gain || look.grain != n.grain
}

Finish :: struct {
	pipeline:      ^sdl.GPUGraphicsPipeline,
	sampler:       ^sdl.GPUSampler,
	shown:         ^sdl.GPUTexture, // the finished picture
	width, height: u32, // of shown
	key:           u64, // what shown was made from (finish_key); 0 when it holds nothing
	failed:        bool, // the device refused part of it; the unfinished picture shows
	passes:        int, // finishing passes run, for the exit stats
}

// Matches Finish_Uniforms in finish.frag.
@(private = "file")
Finish_Uniforms :: struct {
	params:   [4]f32,
	white_x:  [4]f32,
	white_y:  [4]f32,
	white_z:  [4]f32,
	vignette: [4]f32,
	grade:    [4]f32,
	grain:    [4]f32,
}
#assert(size_of(Finish_Uniforms) == 112)

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
	f.key = key
	f.passes += 1
	u := finish_uniforms(look, linear, f32(width) / f32(max(height, 1)))
	target := sdl.GPUColorTargetInfo{texture = f.shown, load_op = .DONT_CARE, store_op = .STORE, cycle = true}
	pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	sdl.BindGPUGraphicsPipeline(pass, f.pipeline)
	samplers := [1]sdl.GPUTextureSamplerBinding{{texture = source, sampler = f.sampler}}
	sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], len(samplers))
	sdl.PushGPUFragmentUniformData(cmd, 0, &u, size_of(u))
	sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	sdl.EndGPURenderPass(pass)
	return true
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
	_ = sdl.WaitForGPUIdle(r.device)
	if f.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, f.pipeline)
	if f.sampler != nil do sdl.ReleaseGPUSampler(r.device, f.sampler)
	if f.shown != nil do sdl.ReleaseGPUTexture(r.device, f.shown)
	f^ = {failed = f.failed, passes = f.passes}
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

// PBR Neutral's curve as display.glsl's tone_map has it, for the tests.
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

// tone_neutral undone as display.glsl's neutral_inverse does it, for the tests.
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
finish_uniforms :: proc(look: Finish_Look, linear: bool, aspect: f32) -> (u: Finish_Uniforms) {
	w := white_balance(look.white)
	u.params = {f32(look.curve), 1 if linear else 0, max(look.contrast, 0.01), max(look.saturation, 0)}
	u.white_x = {w[0, 0], w[1, 0], w[2, 0], 0}
	u.white_y = {w[0, 1], w[1, 1], w[2, 1], 0}
	u.white_z = {w[0, 2], w[1, 2], w[2, 2], 0}
	u.vignette = {clamp(look.vignette, 0, 1), clamp(look.vignette_soft, 0.05, 1), aspect, 0}
	u.grade = {look.lift, max(look.gamma, 0.01), max(look.gain, 0), clamp(look.grain, 0, 1)}
	u.grain = {clamp(look.grain_size, 1, 4), transmute(f32)look.seed, 0, 0}
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
		f.pipeline = create_fullscreen_pipeline(r, FINISH_FRAG_SPV, VIEWPORT_COLOR_FORMAT, samplers = 1)
		f.sampler = sdl.CreateGPUSampler(r.device, {
			min_filter = .NEAREST, mag_filter = .NEAREST, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		if f.pipeline == nil || f.sampler == nil {
			log.errorf("finishing: setup failed (%s); the picture shows unfinished", sdl.GetError())
			return false
		}
	}
	if f.shown != nil && f.width == width && f.height == height do return true
	if f.shown != nil do sdl.ReleaseGPUTexture(r.device, f.shown)
	f.shown = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
	})
	f.width, f.height, f.key = width, height, 0
	if f.shown == nil {
		log.errorf("finishing: target creation failed (%s); the picture shows unfinished", sdl.GetError())
		return false
	}
	return true
}

// finish.frag's AgX sigmoid, its constants as it has them: mid grey's place in the log
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

// finish.frag's scales of the light before AgX's and ACES's curves, which show mid grey
// as tone_neutral does.
AGX_EXPOSURE :: 0.5942082129838109
ACES_EXPOSURE :: 1.2159790709970744

// finish.frag's agx_sigmoid, for the tests.
agx_sigmoid :: proc(x: f64) -> f64 {
	shoulder := x >= AGX_PIVOT_X
	scale: f64 = AGX_SHOULDER_SCALE if shoulder else AGX_TOE_SCALE
	power: f64 = AGX_SHOULDER_POWER if shoulder else AGX_TOE_POWER
	u := AGX_SLOPE * (x - AGX_PIVOT_X) / scale
	return 0.5 + scale * u / math.pow(1 + math.pow(abs(u), power), 1 / power)
}

// finish.frag's AgX for a grey (the inset and outset leave greys alone), for the tests.
agx_grey :: proc(v: f64) -> f64 {
	LOW :: -12.47393
	HIGH :: 4.026069
	x := (clamp(math.log2(max(v, 1e-10)), LOW, HIGH) - LOW) / (HIGH - LOW)
	return math.pow(clamp(agx_sigmoid(x), 0, 1), 2.2)
}

// finish.frag's ACES fit for a grey (its matrices leave greys almost alone), for the tests.
aces_grey :: proc(v: f64) -> f64 {
	a := v * (v + 0.0245786) - 0.000090537
	b := v * (0.983729 * v + 0.4329510) + 0.238081
	return a / b
}
