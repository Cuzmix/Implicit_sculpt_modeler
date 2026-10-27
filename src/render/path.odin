package render

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../jobs"

// Render mode (stage 4.4): progressive path tracing of the shown scene while the view
// stays still, as Blender's Cycles viewport builds up. At the first sample of a still
// view every traced item's triangles, normals, paint and chunk trees (trace.odin's,
// brought up to date the way the traced studio does) are copied on the GPU into one set
// of scene buffers, with a tree over every item's chunks in world space built on the CPU,
// so one compute kernel (render_trace.comp) can follow a whole path through the scene.
// Each frame it adds a band of rows of one sample to the sum, swapping between two sums
// so a band never reads what it writes; once a sample is in, the denoiser
// (render_atrous.frag) filters the mean along the first sample's guides and
// render_display.frag lays it over the viewport. Any change starts over; the plain viewport (or the studio's, or live
// occlusion) shows until the first samples are in. See-through items are left out, as
// the studio leaves them.

RENDER_TRACE_COMP_SPV :: #load("shaders/render_trace.comp.spv")
RENDER_DISPLAY_FRAG_SPV :: #load("shaders/render_display.frag.spv")
RENDER_ATROUS_FRAG_SPV :: #load("shaders/render_atrous.frag.spv")

RENDER_FORMAT :: sdl.GPUTextureFormat.R32G32B32A32_FLOAT
// The denoiser's guides and its passes' images.
RENDER_GUIDE_FORMAT :: sdl.GPUTextureFormat.R16G16B16A16_FLOAT
// The denoiser's passes while the image is noisy, its taps 1 to 16 pixels apart; from
// RENDER_DENOISE_FULL samples on it takes one pass fewer each time the samples grow four
// times, down to two, as less noise needs less reach.
@(private = "file")
RENDER_DENOISE_PASSES :: 5
@(private = "file")
RENDER_DENOISE_FULL :: 64
// The Samples and Bounces sliders' ranges and starting values.
RENDER_SAMPLES_DEFAULT :: 1024
RENDER_SAMPLES_MAX :: 4096
RENDER_BOUNCES_DEFAULT :: 6
RENDER_BOUNCES_MAX :: 12

// render_trace.comp's STUDIO_BLUR: how blurred the built-in studio is where paths leave.
@(private = "file")
RENDER_STUDIO_BLUR :: 0.25
// Matches local_size in render_trace.comp.
@(private = "file")
RENDER_GROUP :: 8
// What tablets may hold in the scene buffers all together, besides each being under
// TRACE_BUFFER_MAX: render mode copies the traced meshes, so a large scene refuses rather
// than crowd out the rest of the app.
@(private = "file")
RENDER_SCENE_MAX :: 256 << 20 when ODIN_PLATFORM_SUBTARGET == .Android else max(int)
// A frame that took longer than this halves the rows a frame takes, one under the
// shorter doubles them: the sample's cost spread so the interface keeps its frame rate.
@(private = "file")
RENDER_FRAME_SLOW :: 50 * time.Millisecond
@(private = "file")
RENDER_FRAME_FAST :: 20 * time.Millisecond
@(private = "file")
RENDER_ROWS_MIN :: 16
// Uploads go through a transfer buffer this big, cycled between batches.
@(private = "file")
RENDER_TRANSFER_SIZE :: 4 << 20

// The item flags of render_trace.comp's ITEM_ constants.
@(private = "file")
ITEM_PAINT :: 1
@(private = "file")
ITEM_GROUPS :: 2
@(private = "file")
ITEM_SLOTS :: 4
@(private = "file")
ITEM_TEXTURED :: 8

Path_Render :: struct {
	// Its own pipelines for bringing the items' trees up to date, as the studio's.
	tracer:         Tracer,
	pipeline:       ^sdl.GPUComputePipeline,
	display:        ^sdl.GPUGraphicsPipeline,
	atrous:         ^sdl.GPUGraphicsPipeline,
	sampler:        ^sdl.GPUSampler,
	// The built-in studio's table for sampling it by brightness, in its own space, and its
	// mean luminance.
	studio_table:   ^sdl.GPUTexture,
	studio_mean:    f32,
	transfer:       ^sdl.GPUTransferBuffer,
	// The sum of the samples done in accum[current]; the sample under way is written to
	// the other one, band by band.
	accum:          [2]^sdl.GPUTexture,
	current:        int,
	shown:          ^sdl.GPUTexture, // what the viewport panel shows
	// The first sample's colour and normal with distance, and the denoiser's two images,
	// one pass reading the other.
	guides:         [2]^sdl.GPUTexture,
	filtered:       [2]^sdl.GPUTexture,
	// The textured items whose maps this view binds, by map slot, with their maps' stamps
	// when it was built (a map that changes since starts the view over), and how many more
	// showed textured than there are slots.
	tex_meshes:     [RENDER_TEXTURED_MAX]^Textured_Mesh,
	tex_stamps:     [RENDER_TEXTURED_MAX]u64,
	tex_left_out:   int,
	// The size the paths are traced at (render_size), and the viewport's, which `shown` has.
	width, height:  u32,
	view_width:     u32,
	view_height:    u32,
	half:           bool, // traced at half size each way
	buffers:        [Scene_Buffer]^sdl.GPUBuffer,
	capacity:       [Scene_Buffer]u32,
	uniforms:       Render_Uniforms, // this still view's
	samples:        int, // complete samples in accum[current]
	row:            u32, // where the next band of the sample under way starts
	rows:           u32, // rows a band takes
	bounces:        int,
	softness:       f32, // the lights' size this view was started with
	exposure:       f32, // what `shown` was laid out with
	denoised:       bool, // ...and whether it was denoised
	valid:          bool, // this still view started
	built:          bool, // ...and its scene is in the buffers
	refused:        string, // why this view cannot be rendered (a scene too big for the device); "" when it can
	failed:         bool, // the device refused part of it; render mode stays off
	last_frame:     time.Tick,
	// For the exit stats: samples rendered, the time they took between their first band
	// and their last, and the scene buffers' size.
	total_samples:  int,
	total_ms:       f64,
	sample_started: time.Tick,
	bytes:          int,
}

@(private = "file")
Scene_Buffer :: enum {
	Positions,
	Indices,
	Attributes,
	Nodes,
	Order,
	Chunks,
	Items,
	// Each textured item's preview vertices (render.Textured_Vertex, 8 words each), then
	// its corners (a slot of those a corner of each triangle).
	Textured,
}

// How many textured items render mode shows with their maps: three maps each, after the
// sum, the environment and its table, 12 of the 16 samplers a stage may bind. Others show
// their material, and the Render section says so.
RENDER_TEXTURED_MAX :: 3
@(private = "file")
RENDER_SAMPLERS :: 3 + 3 * RENDER_TEXTURED_MAX

// Item_Record.tex.w: the item's map slot in the low bits (RENDER_TEXTURED_MAX for none,
// which only the UV checker needs), the view from bit 4, and from bit 8 which maps it has.
@(private = "file")
TEX_VIEW_SHIFT :: 4
@(private = "file")
TEX_MAPS_SHIFT :: 8

// Matches Item in render_trace.comp (std430).
Item_Record :: struct {
	model:        Mat4,
	inv_model:    Mat4,
	color:        [4]f32,
	surface:      [4]f32, // x: metallic, y: roughness
	offs:         [4]u32, // x: the first vertex, y: the ITEM_ flags
	slot_group:   [GROUP_SLOTS]u32,
	slot_color:   [GROUP_SLOTS][4]f32,
	slot_surface: [GROUP_SLOTS][4]f32,
	// A textured item's (ITEM_TEXTURED): its first triangle in the merged indices, where
	// its corners and its preview vertices start in the Textured buffer (words), and its
	// map slot, view and maps (TEX_ shifts).
	tex:          [4]u32,
}
#assert(size_of(Item_Record) == 768)

// Matches Render_Uniforms in render_trace.comp (std140).
Render_Uniforms :: struct {
	inv_view_proj: Mat4,
	lights:        Lights_World,
	env_axes:      [3][4]f32,
	env:           [4]f32,
	scene:         [4]f32,
	counts:        [4]u32, // this sample, the band's first row, bounces, where paint starts
	extra:         [4]u32, // where the scene tree starts in the nodes, 1 when it is empty
}

// The lights in world space with each one's size and pick chance: render_trace.comp's
// light_pos through light_size, then rig_x, y and z.
Lights_World :: struct {
	pos:   [LIGHT_COUNT][4]f32,
	color: [LIGHT_COUNT][4]f32,
	spot:  [LIGHT_COUNT][4]f32,
	shape: [LIGHT_COUNT][4]f32,
	size:  [LIGHT_COUNT][4]f32,
	rig:   [3][4]f32,
}
#assert(size_of(Render_Uniforms) == 64 + size_of(Lights_World) + 48 + 64)

// Records this frame's render mode work after render_viewport: starts over when `changed`
// (anything was redrawn this frame) or the bounces or softness changed; otherwise, at the first band
// of a still view, builds its scene, then adds one band of rows of the sample under way,
// and once a sample's last band is in, lays the sum out in `shown` with `exposure`. Stops
// at `max_samples`, and lays it out again when `exposure` or `denoise` change after.
// `lights` are the viewport's (view space); `softness` is the studio's
// Shadow softness, the angle a sun spans and, at a light's distance from the scene's
// middle, a point or spot light's radius. Returns false only when the device cannot run
// it, after which it never tries again. `half` traces a quarter of the pixels, half the
// viewport's size each way, and lays them out over it smoothly: what tablets take.
render_frame :: proc(r: ^Renderer, pr: ^Path_Render, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, changed: bool, max_samples, bounces: int, lights: Lights, softness, exposure: f32, denoise: bool, half := false, pool: ^jobs.Pool = nil) -> bool {
	if pr.failed do return false
	if !path_ensure(r, pr, vt, half) {
		path_render_destroy(r, pr)
		pr.failed = true
		return false
	}
	now := time.tick_now()
	interval := time.tick_diff(pr.last_frame, now) if pr.last_frame != {} else 0
	pr.last_frame = now
	if changed || !pr.valid || bounces != pr.bounces || softness != pr.softness {
		path_render_reset(pr)
		pr.valid, pr.bounces, pr.softness = true, bounces, softness
		return true
	}
	if pr.samples >= max_samples || pr.refused != "" {
		if pr.samples > 0 && (exposure != pr.exposure || denoise != pr.denoised) do path_display(pr, cmd, vt, exposure, denoise)
		return true
	}
	if !pr.built {
		if !path_scene_build(r, pr, cmd, vt, view, proj, items, lights, softness, pool) do return true
		pr.built = true
	}
	// A map that changed under a still view (a decode that finished) starts it over.
	for t, k in pr.tex_meshes {
		if t != nil && t.maps_stamp != pr.tex_stamps[k] {
			path_render_reset(pr)
			return true
		}
	}
	// The bands follow how long frames take, never what the image is: a pixel's samples
	// depend only on the pixel and the sample.
	if pr.rows == 0 do pr.rows = pr.height if ODIN_PLATFORM_SUBTARGET != .Android else max(pr.height / 4, RENDER_ROWS_MIN)
	if interval > RENDER_FRAME_SLOW do pr.rows = max(pr.rows / 2, RENDER_ROWS_MIN)
	else if interval > 0 && interval < RENDER_FRAME_FAST do pr.rows = min(pr.rows * 2, pr.height)
	if pr.row == 0 do pr.sample_started = now

	rows := min(pr.rows, pr.height - pr.row)
	u := pr.uniforms
	u.counts.x, u.counts.y, u.counts.z = u32(pr.samples), pr.row, u32(bounces)
	bindings := [3]sdl.GPUStorageTextureReadWriteBinding{{texture = pr.accum[1 - pr.current]}, {texture = pr.guides[0]}, {texture = pr.guides[1]}}
	pass := sdl.BeginGPUComputePass(cmd, &bindings[0], len(bindings), nil, 0)
	sdl.BindGPUComputePipeline(pass, pr.pipeline)
	// The image itself, not its prefiltered copy: the paths find its blur on their own,
	// and the table is built over it.
	env_map := r.environment.source if r.environment != nil else r.no_environment
	table := r.environment.table if r.environment != nil else pr.studio_table
	samplers: [RENDER_SAMPLERS]sdl.GPUTextureSamplerBinding
	samplers[0], samplers[1], samplers[2] = {texture = pr.accum[pr.current], sampler = pr.sampler}, {texture = env_map, sampler = r.env_sampler}, {texture = table, sampler = pr.sampler}
	defaults := [Texture_Map]^sdl.GPUTexture{.Base_Color = r.no_matcap, .Orm = r.no_matcap, .Normal = r.no_normal_map}
	for slot in 0 ..< RENDER_TEXTURED_MAX {
		t := pr.tex_meshes[slot]
		for m in Texture_Map {
			tex := t.maps[m] if t != nil && t.maps[m] != nil else defaults[m]
			samplers[3 + 3 * slot + int(m)] = {texture = tex, sampler = r.texture_sampler}
		}
	}
	sdl.BindGPUComputeSamplers(pass, 0, &samplers[0], len(samplers))
	reads: [Scene_Buffer]^sdl.GPUBuffer = pr.buffers
	sdl.BindGPUComputeStorageBuffers(pass, 0, &reads[Scene_Buffer(0)], len(Scene_Buffer))
	sdl.PushGPUComputeUniformData(cmd, 0, &u, size_of(u))
	sdl.DispatchGPUCompute(pass, (pr.width + RENDER_GROUP - 1) / RENDER_GROUP, (rows + RENDER_GROUP - 1) / RENDER_GROUP, 1)
	sdl.EndGPUComputePass(pass)
	pr.row += rows
	if pr.row < pr.height do return true

	pr.row = 0
	pr.current = 1 - pr.current
	pr.samples += 1
	pr.total_samples += 1
	pr.total_ms += time.duration_milliseconds(time.tick_since(pr.sample_started))
	path_display(pr, cmd, vt, exposure, denoise)
	return true
}

// What the viewport panel should show while render mode is on: its image, or nil when it
// has none yet (or cannot make one).
render_texture :: proc(pr: ^Path_Render) -> ^sdl.GPUTexture {
	if pr.failed || pr.samples == 0 do return nil
	return pr.shown
}

// Makes the next render_frame start over.
path_render_reset :: proc(pr: ^Path_Render) {
	pr.samples, pr.row, pr.current = 0, 0, 0
	pr.valid, pr.built, pr.refused = false, false, ""
}

path_render_destroy :: proc(r: ^Renderer, pr: ^Path_Render) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	if pr.pipeline != nil do sdl.ReleaseGPUComputePipeline(r.device, pr.pipeline)
	if pr.display != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, pr.display)
	if pr.atrous != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, pr.atrous)
	if pr.sampler != nil do sdl.ReleaseGPUSampler(r.device, pr.sampler)
	if pr.studio_table != nil do sdl.ReleaseGPUTexture(r.device, pr.studio_table)
	if pr.transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, pr.transfer)
	path_targets_release(r, pr)
	for b in pr.buffers do if b != nil do sdl.ReleaseGPUBuffer(r.device, b)
	tracer_destroy(r, &pr.tracer)
	// The counters outlive the device's objects, for the exit stats.
	pr^ = {tracer = pr.tracer, failed = pr.failed, total_samples = pr.total_samples, total_ms = pr.total_ms, bytes = pr.bytes}
}

// The lights as render mode takes them: `lights` (view space, as the viewport's) turned
// into the world by the inverse of `view`, each with its size and the chance it is
// picked. A light with a size of its own (shape.w: a sun's sine of its angular radius, a
// point or spot light's radius) keeps it; one without spans a cone of half-angle
// `softness`, as a sun, or is a sphere whose radius is that angle seen from the scene's
// `center`. Their radiance gives the viewport's light, three times the strength where it
// arrives (mesh_shading.glsl), as the irradiance of the cone or sphere.
lights_to_world :: proc(lights: Lights, view: Mat4, center: [3]f32, softness: f32) -> (out: Lights_World) {
	l := lights if lights != {} else lights_default()
	to_world := linalg.inverse(view)
	rot := linalg.Matrix3f32{to_world[0, 0], to_world[0, 1], to_world[0, 2], to_world[1, 0], to_world[1, 1], to_world[1, 2], to_world[2, 0], to_world[2, 1], to_world[2, 2]}
	for c in 0 ..< 3 {
		v := rot * l.rig[c].xyz
		out.rig[c] = {v.x, v.y, v.z, l.rig[c].w}
	}
	angle := clamp(softness, STUDIO_SOFTNESS_MIN, STUDIO_SOFTNESS_MAX)
	total: f32
	weight: [LIGHT_COUNT]f32
	for i in 0 ..< LIGHT_COUNT {
		p := l.pos[i]
		strength := l.color[i].w
		out.color[i] = l.color[i]
		out.shape[i] = l.shape[i]
		s := rot * l.spot[i].xyz
		out.spot[i] = {s.x, s.y, s.z, l.spot[i].w}
		if p.w < 0.5 {
			d := linalg.normalize(rot * p.xyz)
			out.pos[i] = {d.x, d.y, d.z, p.w}
			half := clamp(math.asin(min(l.shape[i].w, 1)), STUDIO_SOFTNESS_MIN, math.PI / 2) if l.shape[i].w > 0 else angle
			out.size[i].x = math.cos(half)
			out.size[i].y = 3 * strength / (math.PI * math.pow(math.sin(half), 2))
		} else {
			w := to_world * [4]f32{p.x, p.y, p.z, 1}
			out.pos[i] = {w.x, w.y, w.z, p.w}
			radius := max(l.shape[i].w if l.shape[i].w > 0 else linalg.length(w.xyz - center) * math.tan(angle), 1e-4)
			ref := l.shape[i].x
			out.size[i].x = radius
			out.size[i].y = 3 * strength * ref * ref / (math.PI * radius * radius)
		}
		if strength > 0 {
			c := l.color[i].rgb
			weight[i] = strength * max(c.r, c.g, c.b)
		}
		total += weight[i]
	}
	running: f32
	for i in 0 ..< LIGHT_COUNT {
		if total <= 0 || weight[i] <= 0 do continue
		running += weight[i] / total
		out.size[i].z = running
		out.size[i].w = weight[i] / total
	}
	// The last light picked takes whatever rounding left over.
	for i := LIGHT_COUNT - 1; i >= 0; i -= 1 {
		if out.size[i].w > 0 {
			out.size[i].z = 2
			break
		}
	}
	return
}

// The roughness render mode gives a material: a physically based one's own, or for the
// classic shading the GGX roughness whose highlight is about as wide as its Blinn-Phong
// power's (Walter et al. 2007: power = 2/alpha² - 2, alpha = roughness²).
path_roughness :: proc(material: [4]f32, surface: [2]f32) -> f32 {
	if surface.y > 0 do return surface.y
	m := material if material != {} else DEFAULT_MATERIAL
	return math.pow(2 / (max(m.z, 0) + 2), 0.25)
}

// A box in mesh space as a box in the world, through the similarity `model`.
aabb_transform :: proc(b: geom.Aabb, model: Mat4) -> geom.Aabb {
	out := geom.AABB_EMPTY
	for k in 0 ..< 8 {
		p := [3]f32{b.hi.x if k & 1 != 0 else b.lo.x, b.hi.y if k & 2 != 0 else b.lo.y, b.hi.z if k & 4 != 0 else b.lo.z}
		w := model * [4]f32{p.x, p.y, p.z, 1}
		geom.aabb_grow(&out, w.xyz)
	}
	return out
}

@(private = "file")
path_ensure :: proc(r: ^Renderer, pr: ^Path_Render, vt: ^Viewport_Target, half: bool) -> bool {
	if pr.pipeline == nil {
		usage := sdl.GPUTextureUsageFlags{.SAMPLER, .COMPUTE_STORAGE_WRITE}
		if !sdl.GPUTextureSupportsFormat(r.device, RENDER_FORMAT, .D2, usage) || !sdl.GPUTextureSupportsFormat(r.device, RENDER_GUIDE_FORMAT, .D2, usage) {
			log.warn("render mode: this device cannot write RGBA32F and RGBA16F from compute; it stays off")
			return false
		}
		pr.pipeline = sdl.CreateGPUComputePipeline(r.device, {
			code_size = len(RENDER_TRACE_COMP_SPV), code = raw_data(RENDER_TRACE_COMP_SPV), entrypoint = "main",
			format = {.SPIRV}, num_samplers = RENDER_SAMPLERS, num_readonly_storage_buffers = len(Scene_Buffer), num_readwrite_storage_textures = 3,
			num_uniform_buffers = 1, threadcount_x = RENDER_GROUP, threadcount_y = RENDER_GROUP, threadcount_z = 1,
		})
		pr.display = create_fullscreen_pipeline(r, RENDER_DISPLAY_FRAG_SPV, VIEWPORT_COLOR_FORMAT, samplers = 4)
		pr.atrous = create_fullscreen_pipeline(r, RENDER_ATROUS_FRAG_SPV, RENDER_GUIDE_FORMAT, samplers = 3)
		pr.sampler = sdl.CreateGPUSampler(r.device, {
			min_filter = .NEAREST, mag_filter = .NEAREST, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		pr.transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = RENDER_TRANSFER_SIZE})
		studio := studio_table_build(context.temp_allocator)
		pr.studio_table, pr.studio_mean = env_table_texture(r, studio), studio.mean
		if pr.studio_table == nil || pr.pipeline == nil || pr.display == nil || pr.atrous == nil || pr.sampler == nil || pr.transfer == nil {
			log.errorf("render mode: setup failed (%s); it stays off", sdl.GetError())
			return false
		}
	}
	width, height := render_size(vt.width, vt.height, half)
	if pr.shown != nil && pr.view_width == vt.width && pr.view_height == vt.height && pr.half == half do return true
	path_targets_release(r, pr)
	for &t in pr.accum {
		t = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = RENDER_FORMAT, usage = {.SAMPLER, .COMPUTE_STORAGE_WRITE},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	for &t in pr.guides {
		t = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = RENDER_GUIDE_FORMAT, usage = {.SAMPLER, .COMPUTE_STORAGE_WRITE},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	for &t in pr.filtered {
		t = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = RENDER_GUIDE_FORMAT, usage = {.SAMPLER, .COLOR_TARGET},
			width = width, height = height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	pr.shown = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	pr.width, pr.height, pr.view_width, pr.view_height, pr.half, pr.rows = width, height, vt.width, vt.height, half, 0
	path_render_reset(pr)
	if pr.accum[0] == nil || pr.accum[1] == nil || pr.shown == nil || pr.guides[0] == nil || pr.guides[1] == nil || pr.filtered[0] == nil || pr.filtered[1] == nil {
		log.errorf("render mode: target creation failed (%s); it stays off", sdl.GetError())
		return false
	}
	return true
}

// The size render mode traces a `width` by `height` viewport at: the same, or with `half`
// half each way, rounded up, so the paths cover every pixel.
render_size :: proc(width, height: u32, half: bool) -> (u32, u32) {
	if !half do return width, height
	return max((width + 1) / 2, 1), max((height + 1) / 2, 1)
}

// The images the size of the traced image and of the viewport.
@(private = "file")
path_targets_release :: proc(r: ^Renderer, pr: ^Path_Render) {
	targets := [7]^sdl.GPUTexture{pr.accum[0], pr.accum[1], pr.shown, pr.guides[0], pr.guides[1], pr.filtered[0], pr.filtered[1]}
	for t in targets do if t != nil do sdl.ReleaseGPUTexture(r.device, t)
}

// How many denoiser passes `samples` take, and how far, relative, light may differ before
// a tap stops counting: generous while noise is large, halving pass by pass (Dammertz).
render_denoise_passes :: proc(samples: int) -> (passes: int, spread: f32) {
	passes = RENDER_DENOISE_PASSES
	for n := RENDER_DENOISE_FULL * 4; n <= samples && passes > 2; n *= 4 do passes -= 1
	spread = max(0.15, 4 / math.sqrt(f32(max(samples, 1))))
	return
}

// Lays the sum out over the viewport into `shown`, denoised first when `denoise`.
@(private = "file")
path_display :: proc(pr: ^Path_Render, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, exposure: f32, denoise: bool) {
	pr.exposure, pr.denoised = exposure, denoise
	out := 0
	if denoise {
		passes, spread := render_denoise_passes(pr.samples)
		for i in 0 ..< passes {
			src := pr.accum[pr.current] if i == 0 else pr.filtered[1 - out]
			target := sdl.GPUColorTargetInfo{texture = pr.filtered[out], load_op = .DONT_CARE, store_op = .STORE}
			pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
			sdl.BindGPUGraphicsPipeline(pass, pr.atrous)
			samplers := [3]sdl.GPUTextureSamplerBinding{{texture = src, sampler = pr.sampler}, {texture = pr.guides[0], sampler = pr.sampler}, {texture = pr.guides[1], sampler = pr.sampler}}
			sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], len(samplers))
			params := [4]f32{f32(int(1) << uint(i)), spread / f32(int(1) << uint(i)), 1 if i == 0 else 0, 0}
			sdl.PushGPUFragmentUniformData(cmd, 0, &params, size_of(params))
			sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
			sdl.EndGPURenderPass(pass)
			out = 1 - out
		}
	}
	target := sdl.GPUColorTargetInfo{texture = pr.shown, load_op = .DONT_CARE, store_op = .STORE, cycle = true}
	pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	sdl.BindGPUGraphicsPipeline(pass, pr.display)
	samplers := [4]sdl.GPUTextureSamplerBinding{{texture = vt.color, sampler = pr.sampler}, {texture = pr.accum[pr.current], sampler = pr.sampler}, {texture = pr.filtered[1 - out], sampler = pr.sampler}, {texture = pr.guides[0], sampler = pr.sampler}}
	sdl.BindGPUFragmentSamplers(pass, 0, &samplers[0], len(samplers))
	params := [4]f32{exposure, f32(pr.samples), 1 if denoise else 0, 1 if pr.half else 0}
	sdl.PushGPUFragmentUniformData(cmd, 0, &params, size_of(params))
	sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
	sdl.EndGPURenderPass(pass)
}

// One traced item's place in the scene buffers.
@(private = "file")
Path_Item :: struct {
	item:                        int, // in the frame's items
	vertices, triangles:         u32,
	vertex_off, tri_off:         u32,
	nodes, words:                u32,
	node_off, word_off:          u32,
	chunk_off:                   u32,
	paint:                       bool, // its paint buffer is copied
	// A textured item's preview, with where its vertices and corners go in the Textured
	// buffer (words) and its map slot (RENDER_TEXTURED_MAX for none).
	textured:                    ^Textured_Mesh,
	tex_vertex_off, tex_corner_off: u32,
	tex_slot:                    u32,
}

// Brings the traced items' trees up to date and copies everything the kernel reads into
// the scene buffers, with the tree over every shown chunk in the world; fills
// pr.uniforms. False, with pr.refused saying why, when the scene cannot be rendered.
@(private = "file")
path_scene_build :: proc(r: ^Renderer, pr: ^Path_Render, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, lights: Lights, softness: f32, pool: ^jobs.Pool) -> bool {
	if !trace_prepare(r, &pr.tracer, cmd, vt, items, pool) {
		pr.refused = "Render mode cannot trace this scene on this device; the log says why."
		return false
	}
	placed := make([dynamic]Path_Item, context.temp_allocator)
	vertex_count, tri_count, node_count, word_count, chunk_count, textured_count, textured_words: u32
	pr.tex_meshes, pr.tex_stamps, pr.tex_left_out = {}, {}, 0
	for item, i in items {
		if blended(&r.single, item) do continue
		tm := item.mesh.trace
		if tm == nil || tm.tlas_empty do continue
		p := Path_Item{item = i, vertices = u32(len(item.source.positions)), triangles = u32(len(item.source.indices) / 3)}
		for tree in tm.trees {
			p.nodes += u32(len(tree.nodes))
			p.words += u32((len(tree.order) + 1) / 2)
		}
		p.vertex_off, p.tri_off, p.node_off, p.word_off, p.chunk_off = vertex_count, tri_count, node_count, word_count, chunk_count
		p.paint = item.mesh.paint != nil && (item.paint || item.groups || item.slots != nil)
		if t := item.textured; t != nil && item.texture_view != .Off && t.index_count > 0 && t.corner_count == 3 * p.triangles {
			p.tex_slot = RENDER_TEXTURED_MAX
			if item.texture_view != .Uv_Checker {
				if textured_count < RENDER_TEXTURED_MAX {
					p.tex_slot = textured_count
					pr.tex_meshes[textured_count], pr.tex_stamps[textured_count] = t, t.maps_stamp
					textured_count += 1
				} else {
					pr.tex_left_out += 1
				}
			}
			if p.tex_slot < RENDER_TEXTURED_MAX || item.texture_view == .Uv_Checker {
				// It shows its maps or checker over its preview's normals, never paint or
				// polygroups, as in the viewport.
				p.textured, p.paint = t, false
				p.tex_vertex_off, p.tex_corner_off = textured_words, textured_words + t.vertex_count * size_of(Textured_Vertex) / size_of(u32)
				textured_words = p.tex_corner_off + t.corner_count
			}
		}
		vertex_count += p.vertices
		tri_count += p.triangles
		node_count += p.nodes
		word_count += p.words
		chunk_count += u32(len(tm.trees))
		append(&placed, p)
	}
	if len(placed) >= 1 << 12 {
		pr.refused = "Render mode traces at most 4096 objects."
		return false
	}

	// The chunks, rebased into the merged buffers, and the tree over the shown ones in the
	// world.
	chunks := make([][4]u32, max(chunk_count, 1), context.temp_allocator)
	world_bounds := make([dynamic]geom.Aabb, context.temp_allocator)
	world_ids := make([dynamic]u32, context.temp_allocator)
	records := make([]Item_Record, max(len(placed), 1), context.temp_allocator)
	for p, k in placed {
		item := items[p.item]
		tm := item.mesh.trace
		node_at, word_at: u32
		for tree, t in tm.trees {
			first_tri := tm.ranges[t].first_index / 3
			chunks[p.chunk_off + u32(t)] = {p.node_off + node_at, 2 * (p.word_off + word_at), p.tri_off + first_tri, u32(len(tree.nodes)) | u32(k) << 20}
			node_at += u32(len(tree.nodes))
			word_at += u32((len(tree.order) + 1) / 2)
		}
		shown, bounds := trace_shown(item, tm)
		for run, j in shown {
			append(&world_bounds, aabb_transform(bounds[j], item.model))
			append(&world_ids, p.chunk_off + run)
		}
		records[k] = path_item_record(item, p)
	}
	tlas := make([dynamic]geom.Gpu_Bvh_Node, context.temp_allocator)
	if len(world_bounds) > 0 {
		order := make([]u32, len(world_bounds), context.temp_allocator)
		geom.gpu_bvh_build(world_bounds[:], 1, &tlas, order, context.temp_allocator)
		for &n in tlas do if n.count > 0 do n.first = world_ids[order[n.first]]
	}

	sizes: [Scene_Buffer]int
	sizes[.Positions] = int(vertex_count) * size_of(geom.Vec3)
	sizes[.Indices] = int(tri_count) * 3 * size_of(u32)
	sizes[.Attributes] = int(vertex_count) * (size_of(Normal_Packed) + size_of(Paint_Packed))
	sizes[.Nodes] = (int(node_count) + len(tlas)) * size_of(geom.Gpu_Bvh_Node)
	sizes[.Order] = int(word_count) * size_of(u32)
	sizes[.Chunks] = len(chunks) * size_of([4]u32)
	sizes[.Items] = len(records) * size_of(Item_Record)
	sizes[.Textured] = int(textured_words) * size_of(u32)
	total := 0
	for s in sizes {
		if s > TRACE_BUFFER_MAX {
			pr.refused = "This scene is too large for render mode on this device."
			return false
		}
		total += s
	}
	if total > RENDER_SCENE_MAX {
		pr.refused = "This scene is too large for render mode on this device."
		return false
	}
	for which in Scene_Buffer {
		if !path_buffer_ensure(r, pr, which, sizes[which]) {
			pr.refused = "The device refused render mode's scene buffers; the log says why."
			return false
		}
	}

	// Each item's own data, copied on the GPU.
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	paint_base := vertex_count * size_of(Normal_Packed)
	for p in placed {
		item := items[p.item]
		mb, tm := item.mesh, item.mesh.trace
		gpu_copy(copy_pass, mb.positions, pr.buffers[.Positions], p.vertex_off * size_of(geom.Vec3), p.vertices * size_of(geom.Vec3))
		gpu_copy(copy_pass, mb.indices, pr.buffers[.Indices], p.tri_off * 3 * size_of(u32), p.triangles * 3 * size_of(u32))
		gpu_copy(copy_pass, mb.normals, pr.buffers[.Attributes], p.vertex_off * size_of(Normal_Packed), p.vertices * size_of(Normal_Packed))
		if p.paint do gpu_copy(copy_pass, mb.paint, pr.buffers[.Attributes], paint_base + p.vertex_off * size_of(Paint_Packed), p.vertices * size_of(Paint_Packed))
		gpu_copy(copy_pass, tm.buffers[.Nodes], pr.buffers[.Nodes], p.node_off * size_of(geom.Gpu_Bvh_Node), p.nodes * size_of(geom.Gpu_Bvh_Node))
		gpu_copy(copy_pass, tm.buffers[.Order], pr.buffers[.Order], p.word_off * size_of(u32), p.words * size_of(u32))
		if t := p.textured; t != nil {
			gpu_copy(copy_pass, t.vertices, pr.buffers[.Textured], p.tex_vertex_off * size_of(u32), t.vertex_count * size_of(Textured_Vertex))
			gpu_copy(copy_pass, t.corners, pr.buffers[.Textured], p.tex_corner_off * size_of(u32), t.corner_count * size_of(u32))
		}
	}
	sdl.EndGPUCopyPass(copy_pass)
	ok := path_upload(r, pr, cmd, .Chunks, 0, slice.to_bytes(chunks)) &&
		path_upload(r, pr, cmd, .Items, 0, slice.to_bytes(records)) &&
		path_upload(r, pr, cmd, .Nodes, int(node_count) * size_of(geom.Gpu_Bvh_Node), slice.to_bytes(tlas[:]))
	if !ok {
		pr.refused = "Render mode's upload failed; the log says why."
		return false
	}

	center, radius, _ := scene_sphere(items)
	u := &pr.uniforms
	u^ = {}
	u.inv_view_proj = linalg.inverse(proj * view)
	u.lights = lights_to_world(lights, view, center, softness)
	if r.environment != nil {
		look := r.environment_look
		to_world := linalg.inverse(view)
		for c in 0 ..< 3 {
			v := to_world * [4]f32{look.rotation[c].x, look.rotation[c].y, look.rotation[c].z, 0}
			u.env_axes[c] = {v.x, v.y, v.z, 0}
		}
		u.env = {1, look.strength, 0, 0}
	}
	u.scene = {center.x, center.y, center.z, radius}
	env_light := math.PI * (r.environment.mean * r.environment_look.strength if r.environment != nil else pr.studio_mean * 0.7 * max(u.lights.rig[0].w, 0))
	u.env.z = env_share(&u.lights, lights, env_light, smooth = r.environment == nil)
	u.counts.w = paint_base / size_of(u32)
	u.extra = {node_count, 1 if len(tlas) == 0 else 0, 0, 0}
	pr.bytes = 0
	for c in pr.capacity do pr.bytes += int(c)
	return true
}

// The built-in studio's table, over its luminance in its own space.
@(private = "file")
studio_table_build :: proc(allocator := context.allocator) -> Env_Table {
	w, h := STUDIO_TABLE_WIDTH, STUDIO_TABLE_WIDTH / 2
	lum := make([]f32, w * h, context.temp_allocator)
	for y in 0 ..< h do for x in 0 ..< w do lum[y * w + x] = studio_luminance(panorama_direction(x, y, w, h), RENDER_STUDIO_BLUR)
	return env_table_build(lum, w, h, allocator)
}

// The chance a light sample takes the environment, by the light each gives a surface
// facing it (`env_light` for the environment, π times its mean radiance; three times the
// strength for a light, as the viewport's), at least a tenth for either while both give
// any; the lights' chances in `world` shrink to share the rest. A `smooth` environment,
// the built-in studio, takes none while a light is on: the bounces find its broad light
// well enough, and every sample it took from the lights left their shadows noisier (16
// samples of the three spheres under the default lights: 17% more noise at its share by
// light, 5% even at a twentieth), while with no light on it is all there is and sampling
// it is a little better than the bounces alone (8% less).
env_share :: proc(world: ^Lights_World, lights: Lights, env_light: f32, smooth := false) -> f32 {
	l := lights if lights != {} else lights_default()
	light_total: f32
	for i in 0 ..< LIGHT_COUNT {
		if world.size[i].w <= 0 do continue
		c := l.color[i]
		light_total += 3 * c.w * max(c.r, c.g, c.b)
	}
	share: f32
	switch {
	case env_light <= 0:   share = 0
	case light_total <= 0: share = 1
	case smooth:           share = 0
	case:                  share = clamp(env_light / (env_light + light_total), 0.1, 0.9)
	}
	for i in 0 ..< LIGHT_COUNT {
		if world.size[i].w <= 0 do continue
		world.size[i].w *= 1 - share
		if world.size[i].z <= 1 do world.size[i].z = share + (1 - share) * world.size[i].z
	}
	return share
}

// An item's record: where it sits, its material as render mode takes it, and its groups'
// materials.
@(private = "file")
path_item_record :: proc(item: Draw_Item, p: Path_Item) -> (rec: Item_Record) {
	rec.model = item.model
	rec.inv_model = linalg.inverse(item.model)
	rec.color = item.color
	rec.surface = {item.surface.x, path_roughness(item.material, item.surface), 0, 0}
	if item.matcap != nil {
		// A MatCap's picture holds its light; traced, it is its colour, a little darker as
		// the picture's own shading leaves it, half rough.
		rec.color.rgb *= 0.8
		rec.surface = {0, 0.5, 0, 0}
	}
	rec.offs.x = p.vertex_off
	if t := p.textured; t != nil {
		rec.offs.y |= ITEM_TEXTURED
		maps: u32
		for m in Texture_Map do if t.maps[m] != nil do maps |= 1 << u32(m)
		rec.tex = {p.tri_off, p.tex_corner_off, p.tex_vertex_off, p.tex_slot | u32(item.texture_view) << TEX_VIEW_SHIFT | maps << TEX_MAPS_SHIFT}
	}
	if p.paint {
		if item.paint do rec.offs.y |= ITEM_PAINT
		if item.groups do rec.offs.y |= ITEM_GROUPS
		if item.slots != nil {
			rec.offs.y |= ITEM_SLOTS
			s := item.slots
			rec.slot_group = s.groups
			for k in 0 ..< GROUP_SLOTS {
				rec.slot_color[k] = s.uniforms.color[k]
				rec.slot_surface[k] = {s.uniforms.surface[k].x, path_roughness(s.uniforms.params[k], s.uniforms.surface[k].xy), 0, 0}
			}
		}
	}
	return
}

@(private = "file")
gpu_copy :: proc(pass: ^sdl.GPUCopyPass, src, dst: ^sdl.GPUBuffer, offset, size: u32) {
	if src == nil || size == 0 do return
	sdl.CopyGPUBufferToBuffer(pass, {buffer = src}, {buffer = dst, offset = offset}, size, false)
}

// Makes a scene buffer at least `size` bytes, a quarter again over when it grows.
@(private = "file")
path_buffer_ensure :: proc(r: ^Renderer, pr: ^Path_Render, which: Scene_Buffer, wanted: int) -> bool {
	size := max(wanted, 64)
	if pr.buffers[which] != nil && u32(size) <= pr.capacity[which] do return true
	if pr.buffers[which] != nil {
		_ = sdl.WaitForGPUIdle(r.device)
		sdl.ReleaseGPUBuffer(r.device, pr.buffers[which])
	}
	capacity := u32(min(size + size / 4, TRACE_BUFFER_MAX))
	pr.buffers[which] = sdl.CreateGPUBuffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = capacity})
	pr.capacity[which] = capacity if pr.buffers[which] != nil else 0
	if pr.buffers[which] == nil {
		log.errorf("render mode: a buffer of %d MB was refused (%s)", capacity >> 20, sdl.GetError())
		return false
	}
	return true
}

// Copies `data` into a scene buffer at `offset` through the transfer buffer, a batch at a
// time.
@(private = "file")
path_upload :: proc(r: ^Renderer, pr: ^Path_Render, cmd: ^sdl.GPUCommandBuffer, which: Scene_Buffer, offset: int, data: []u8) -> bool {
	for at := 0; at < len(data); at += RENDER_TRANSFER_SIZE {
		part := data[at:min(at + RENDER_TRANSFER_SIZE, len(data))]
		dst := sdl.MapGPUTransferBuffer(r.device, pr.transfer, true)
		if dst == nil {
			log.errorf("render mode: upload failed (%s)", sdl.GetError())
			return false
		}
		runtime.mem_copy_non_overlapping(dst, raw_data(part), len(part))
		sdl.UnmapGPUTransferBuffer(r.device, pr.transfer)
		pass := sdl.BeginGPUCopyPass(cmd)
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = pr.transfer}, {buffer = pr.buffers[which], offset = u32(offset + at), size = u32(len(part))}, false)
		sdl.EndGPUCopyPass(pass)
	}
	return true
}
