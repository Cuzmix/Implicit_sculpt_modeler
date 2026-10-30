package render

import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl3"

import "../jobs"

// The studio render: while nothing on screen changes, each frame adds one shadow-mapped
// light sample to an accumulation target, and the viewport is shown darkened by what
// the samples found, so it settles over a second or two into ambient occlusion and a
// soft key light shadow, much like a path-traced preview. Ambient samples come from
// directions all round the scene; one sample in STUDIO_KEY_EVERY comes from around the
// mesh shader's key light, jittered over a small disc, which softens the shadow's edge.
// A change to what the samples are of (a stroke, a moved object or light, a resize) starts
// over; until then the plain viewport is copied through, so the cost while working is one
// copy a frame. A turn, pan or zoom of the view alone carries the samples to where they now
// are (studio_reproject.frag.slang) and adds one more each frame, so the occlusion and the
// shadows stay on screen while the camera moves, as EEVEE's and Toolbag's raster modes keep
// theirs; a change to the materials alone keeps them as they are.
// Where the device and the meshes allow, samples cast rays at the triangles instead
// (trace.odin), from the same lights; the shadow maps below are the fallback.
Studio :: struct {
	shadow_pipeline:    ^sdl.GPUGraphicsPipeline,
	depth_pipeline:     ^sdl.GPUGraphicsPipeline, // the camera's depth, front faces only, as the mesh pipeline
	gather_pipeline:    ^sdl.GPUGraphicsPipeline,
	composite_pipeline: ^sdl.GPUGraphicsPipeline,
	reproject_pipeline: ^sdl.GPUGraphicsPipeline,
	keep_pipeline:      ^sdl.GPUGraphicsPipeline,
	sampler:            ^sdl.GPUSampler,
	shadow:             ^sdl.GPUTexture, // depth from the light of the current sample
	accum:              ^sdl.GPUTexture, // summed samples: see studio_gather.frag.slang; one of accums
	accums:             [2]^sdl.GPUTexture, // this frame's sums and last frame's, which a reprojection reads
	// The depth the samples in accum were taken at, as the depth buffer holds it, for the
	// next reprojection; valid while depth_kept.
	prev_depth:         ^sdl.GPUTexture,
	shown:              ^sdl.GPUTexture, // what the viewport panel shows
	// The camera's depth at one sample, drawn when the viewport is multisampled, whose
	// own depth shaders cannot read; nil otherwise.
	view_depth:         ^sdl.GPUTexture,
	width, height:      u32, // of accum and shown
	samples:            int, // added to accum since it started over or was last carried, which stopping counts
	sequence:           int, // samples taken since it started over: the R2 sequence's place
	carried:            bool, // accum holds samples carried from an earlier view
	depth_kept:         bool,
	view_proj:          Mat4, // the view accum and prev_depth are of
	scene_key:          u64, // what the samples are of (studio_scene_key)
	lights_key:         u64, // the lights in the world the shadow samples were taken with
	// For the exit stats: frames whose samples were carried, those that added none (over
	// STUDIO_MOVING_TRIANGLES), and starts over.
	carries, carried_bare, restarts: int,
	shown_valid:        bool, // shown holds this frame's viewport, with or without samples
	failed:             bool, // the device refused part of it; the plain viewport shows
	trace:              Tracer,
	traced:             bool, // this still view's samples are traced
	softness:           f32, // the key light's disc these samples were taken over
	strengths:          [2]f32, // the occlusion and shadow strengths `shown` was composited with
}

// Shadow map size: fine enough for a crevice a few pixels wide at the default view.
STUDIO_SHADOW_SIZE :: 2048
// One sample in this many is a key light sample; the rest are ambient.
STUDIO_KEY_EVERY :: 4
// Radius of the disc the key light is jittered over, in radians: its shadow's softness,
// by default and within the range studio_frame takes.
STUDIO_KEY_SOFTNESS :: 0.06
STUDIO_SOFTNESS_MIN :: 0.01
STUDIO_SOFTNESS_MAX :: 0.5
// Depth bias and normal offset in shadow map texels: enough to keep a curved surface
// from shadowing itself without letting thin gaps leak light.
STUDIO_DEPTH_BIAS_TEXELS :: 2
STUDIO_NORMAL_OFFSET_TEXELS :: 1.5

// How much of the ambient light's strength a surface takes, beside a light's strength
// facing it: about what the classic materials' ambient (0.06 to 0.12) and the physically
// based studio's diffuse give. Shadows take away only the lights' share of a pixel.
STUDIO_AMBIENT_SHARE :: 0.1

STUDIO_ACCUM_FORMAT :: sdl.GPUTextureFormat.R16G16B16A16_FLOAT
STUDIO_PREV_DEPTH_FORMAT :: sdl.GPUTextureFormat.R32_FLOAT

// What a carried pixel's history may weigh at most, in samples: thirty-two ambient ones (each
// adds about a quarter to the cosine sum), about half a second of new samples at 60 Hz, so a
// turn's stale samples fade about as fast as the eye follows them while one frame's sample
// moves the picture too little to show as noise; and four light ones.
STUDIO_CARRY_AMBIENT :: 32
STUDIO_CARRY_KEY :: 4
// The ambient cosine sum at which a carried pixel's own samples are trusted over live
// occlusion's picture under it, about sixteen samples: below it the two are mixed, so a
// surface the turn uncovered shows live occlusion's smooth shading rather than one
// sample's speckle.
STUDIO_CARRY_SETTLED :: 4.0
// Likewise the shadows' weight, about two light samples, eight frames.
STUDIO_CARRY_KEY_SETTLED :: 2.0
// Above this many triangles a moving view's frames only carry the samples and add none:
// each new sample draws every triangle into the shadow map, too much on a tablet every
// frame of a turn. Traced samples cost by pixels, not triangles, and always add.
STUDIO_MOVING_TRIANGLES :: 2_000_000

SHADOW_VERT_CODE :: #load("shaders/shadow.vert" + SHADER_EXT)
SHADOW_FRAG_CODE :: #load("shaders/shadow.frag" + SHADER_EXT)
STUDIO_GATHER_FRAG_CODE :: #load("shaders/studio_gather.frag" + SHADER_EXT)
STUDIO_COMPOSITE_FRAG_CODE :: #load("shaders/studio_composite.frag" + SHADER_EXT)
STUDIO_REPROJECT_FRAG_CODE :: #load("shaders/studio_reproject.frag" + SHADER_EXT)
STUDIO_DEPTH_KEEP_FRAG_CODE :: #load("shaders/studio_depth_keep.frag" + SHADER_EXT)

// Matches Reproject_Uniforms in studio_reproject.frag.slang.
@(private = "file")
Reproject_Uniforms :: struct {
	inv_view_proj:      Mat4,
	prev_view_proj:     Mat4,
	prev_inv_view_proj: Mat4,
	params:             [4]f32,
}

// Matches Gather_Uniforms in studio_gather.frag.slang.
@(private = "file")
Gather_Uniforms :: struct {
	inv_view_proj:   Mat4,
	light_view_proj: Mat4,
	light_dir:       [4]f32,
	params:          [4]f32,
	shadow:          Shadow_Lights,
}
#assert(size_of(Gather_Uniforms) == 160 + size_of(Shadow_Lights))

// Matches the shadow_ uniforms studio_weight.slang reads: the lights in the world (as
// lights_to_world gives them), each one's distance, reach and spot edge with the chance
// it is picked in shape.w, and in pick x the light this sample took and z the ambient
// light (STUDIO_AMBIENT_SHARE of it over the lights' total brightness).
Shadow_Lights :: struct {
	pos:   [LIGHT_COUNT][4]f32,
	shape: [LIGHT_COUNT][4]f32,
	spot:  [LIGHT_COUNT][4]f32,
	pick:  [4]f32,
}
#assert(size_of(Shadow_Lights) == 400)

// Records this frame's studio work after render_viewport: starts over when `changed`
// (anything was redrawn this frame), otherwise adds a sample until there are
// `max_samples`, and leaves the result in Studio.shown. `ao` and `shadow` (0 to 1) are
// how strongly occlusion and the lights' shadows darken the image; `lights` are the
// lights the items are shaded with, every one of which casts a shadow (studio_light), and
// `softness` the radius in radians of the disc of a light without a size of its own,
// which a change starts over. A
// change of `ao` or `shadow` once the samples are done composites them again. A traced
// view builds what changed of its trees on `pool` at its first sample. When only the view
// moved, the samples are carried instead of started over (studio_carry); `under` is then
// shown where they are too few, live occlusion's picture when it runs (nil: the viewport's).
// Returns false only when the studio cannot run on this device, after which it never tries
// again.
studio_frame :: proc(r: ^Renderer, st: ^Studio, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, changed: bool, max_samples: int, ao, shadow: f32, lights: Lights = {}, pool: ^jobs.Pool = nil, softness: f32 = STUDIO_KEY_SOFTNESS, under: ^sdl.GPUTexture = nil) -> bool {
	debug_group(cmd, "Studio", .Studio)
	if st.failed do return false
	if !studio_ensure(r, st, vt) {
		st.failed = true
		studio_destroy(r, st)
		st.failed = true
		return false
	}
	soft := clamp(softness, STUDIO_SOFTNESS_MIN, STUDIO_SOFTNESS_MAX)
	moving, kept_shadows := false, true
	if changed || !st.shown_valid || soft != st.softness {
		carried: bool
		carried, moving, kept_shadows = studio_carry(r, st, cmd, vt, view, proj, items, soft, max_samples, lights)
		if !carried {
			st.softness = soft
			st.samples, st.sequence, st.carried, st.depth_kept = 0, 0, false, false
			st.shown_valid = true
			st.restarts += 1
			st.scene_key = studio_scene_key(items, soft, vt.epoch)
			st.view_proj = proj * view
			if center, _, ok := scene_sphere(items); ok do st.lights_key = studio_lights_key(lights, view, center, soft)
			copy_pass := gpu_begin_copy_pass(cmd)
			gpu_copy_texture_to_texture(copy_pass, {texture = vt.color}, {texture = st.shown}, vt.width, vt.height, 1, cycle = true)
			gpu_end_copy_pass(copy_pass)
			return true
		}
	}
	if st.samples >= max_samples || moving && !st.traced && studio_triangles(items) > STUDIO_MOVING_TRIANGLES {
		if st.carried && st.samples < max_samples do st.carried_bare += 1
		if (st.samples > 0 || st.carried) && (moving || st.strengths != {ao, shadow}) do studio_composite(st, cmd, vt, ao, shadow, under, moving && !kept_shadows)
		return true
	}
	center, radius, ok := scene_sphere(items)
	if !ok do return true

	// This sample's light: all round the scene for ambient, around one of the lights for
	// the shadow. The R2 sequence spreads consecutive samples evenly at any count.
	k := st.sequence
	u := math.mod(0.5 + f32(k) * 0.7548777, 1)
	v := math.mod(0.5 + f32(k) * 0.5698403, 1)
	sl := studio_light(lights, view, center, soft, k)
	// With no light on there is no shadow, and every sample goes to the occlusion.
	key := sl.lit && k % STUDIO_KEY_EVERY == STUDIO_KEY_EVERY - 1
	if key do u, v = sl.r2.x, sl.r2.y
	dir, base, side, up: [3]f32
	if key {
		base = sl.dir
		side = linalg.normalize(linalg.cross(base, [3]f32{0, 1, 0} if abs(base.y) < 0.99 else [3]f32{1, 0, 0}))
		up = linalg.cross(side, base)
		a, rr := 2 * math.PI * v, sl.radius * math.sqrt(u)
		dir = linalg.normalize(base + (side * math.cos(a) + up * math.sin(a)) * rr)
	} else {
		z := 1 - 2 * u
		ring := math.sqrt(max(1 - z * z, 0))
		dir = {ring * math.cos(2 * math.PI * v), z, ring * math.sin(2 * math.PI * v)}
	}

	// Whether this scene is traced is settled at its first sample, which also brings the
	// trees up to date, before anything reads them; a carried view's geometry is the same.
	if st.sequence == 0 do st.traced = trace_prepare(r, &st.trace, cmd, vt, items, pool, ray_query = true)
	// The sums start from nothing, unless they were carried.
	first := st.samples == 0 && !st.carried

	// The depth the samples read: the viewport's own, or with multisampling the camera's
	// drawn again at one sample, once per view (it is the same for every sample; a
	// carried view drew it before carrying).
	view_depth := vt.depth
	if vt.samples != ._1 {
		view_depth = st.view_depth
		if first do view_depth_draw(r, cmd, st.depth_pipeline, nil, st.view_depth, vt.width, vt.height, view, proj, items)
	}
	defer if !st.depth_kept do studio_keep_depth(st, cmd, view_depth)

	if st.traced {
		// The ray of each pixel spreads this sample's point over the hemisphere or the
		// key light's disc itself, so the gather's direction is not used.
		light := Trace_Light{key = key, base = base, side = side, up = up, radius = sl.radius, r2 = {u, v}, sphere = key && sl.sphere, at = sl.at, sphere_radius = sl.sphere_radius, shadow = sl.shadow}
		trace_sample(r, &st.trace, cmd, st.accum, view_depth, st.sampler, view, proj, items, light, TRACE_EPSILON * radius, first)
		st.samples += 1
		st.sequence += 1
		studio_composite(st, cmd, vt, ao, shadow, under, moving && !kept_shadows)
		return true
	}
	light := light_view_proj(center, radius, dir)

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
	pass := gpu_begin_render_pass(cmd, nil, 0, &depth)
	gpu_bind_graphics_pipeline(pass, st.shadow_pipeline)
	for item in items {
		mb := item.mesh
		u := Shadow_Uniforms{light, item.model}
		gpu_push_vertex_uniform_data(cmd, 0, &u, size_of(u))
		vbufs := [1]sdl.GPUBufferBinding{{buffer = mb.positions}}
		gpu_bind_vertex_buffers(pass, 0, &vbufs[0], 1)
		gpu_bind_index_buffer(pass, {buffer = mb.indices}, ._32BIT)
		gpu_draw_indexed_primitives(pass, mb.index_count, 1, 0, 0, 0)
	}
	gpu_end_render_pass(pass)

	// Add what that light reaches to the accumulation target.
	texel := 2 * radius / STUDIO_SHADOW_SIZE
	g := Gather_Uniforms {
		inv_view_proj   = linalg.inverse(proj * view),
		light_view_proj = light,
		light_dir       = {dir.x, dir.y, dir.z, 1 if key else 0},
		params          = {STUDIO_DEPTH_BIAS_TEXELS / f32(STUDIO_SHADOW_SIZE), STUDIO_NORMAL_OFFSET_TEXELS * texel, 1 / f32(STUDIO_SHADOW_SIZE), 0},
		shadow          = sl.shadow,
	}
	target := sdl.GPUColorTargetInfo {
		texture  = st.accum,
		load_op  = .CLEAR if first else .LOAD,
		store_op = .STORE,
	}
	pass = gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(pass, st.gather_pipeline)
	samplers := [2]sdl.GPUTextureSamplerBinding{{texture = view_depth, sampler = st.sampler}, {texture = st.shadow, sampler = st.sampler}}
	gpu_bind_fragment_samplers(pass, 0, &samplers[0], 2)
	gpu_push_fragment_uniform_data(cmd, 0, &g, size_of(g))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)
	st.samples += 1
	st.sequence += 1
	studio_composite(st, cmd, vt, ao, shadow, under, moving && !kept_shadows)
	return true
}

// Carries the samples to this frame's view when what they are of is unchanged and only the
// view moved, or nothing they are of changed at all (the materials, the LOD's settle), and
// reports whether it did and whether the view moved. The occlusion always carries; the
// shadows only when the lights stood still in the world, as lights fixed to the scene do
// (lights fixed to the camera turn with it, and their shadows build again from new samples).
@(private = "file")
studio_carry :: proc(r: ^Renderer, st: ^Studio, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, view, proj: Mat4, items: []Draw_Item, soft: f32, max_samples: int, lights: Lights) -> (carried, moving, keep_shadows: bool) {
	if !st.shown_valid || !st.depth_kept || soft != st.softness || max_samples <= 0 do return
	if st.samples == 0 && !st.carried do return
	if studio_scene_key(items, soft, vt.epoch) != st.scene_key do return
	center, _, ok := scene_sphere(items)
	if !ok do return
	view_proj := proj * view
	moving = view_proj != st.view_proj
	lights_key := studio_lights_key(lights, view, center, soft)
	keep_shadows = lights_key == st.lights_key
	// Unmoved, a change of the lights is a change of what the shadow samples are of; and
	// samples fewer than a carry keeps cost nothing to start over, which leaves a view that
	// never moves exactly as it always was.
	if !moving && (!keep_shadows || st.samples + int(st.carried) * STUDIO_CARRY_AMBIENT < STUDIO_CARRY_AMBIENT) do return false, false, false

	// The depth this frame's view is read at, drawn first with multisampling.
	view_depth := vt.depth
	if vt.samples != ._1 {
		view_depth = st.view_depth
		view_depth_draw(r, cmd, st.depth_pipeline, nil, st.view_depth, vt.width, vt.height, view, proj, items)
	}
	from := st.accum
	to := st.accums[1] if st.accum == st.accums[0] else st.accums[0]
	u := Reproject_Uniforms{
		inv_view_proj      = linalg.inverse(view_proj),
		prev_view_proj     = st.view_proj,
		prev_inv_view_proj = linalg.inverse(st.view_proj),
		params             = {0.25 * STUDIO_CARRY_AMBIENT, STUDIO_CARRY_KEY, 1 if keep_shadows else 0, 0},
	}
	target := sdl.GPUColorTargetInfo{texture = to, load_op = .DONT_CARE, store_op = .STORE}
	pass := gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(pass, st.reproject_pipeline)
	samplers := [3]sdl.GPUTextureSamplerBinding{{texture = view_depth, sampler = st.sampler}, {texture = st.prev_depth, sampler = st.sampler}, {texture = from, sampler = st.sampler}}
	gpu_bind_fragment_samplers(pass, 0, &samplers[0], len(samplers))
	gpu_push_fragment_uniform_data(cmd, 0, &u, size_of(u))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)
	st.accum = to
	st.view_proj, st.lights_key = view_proj, lights_key
	st.samples, st.carried, st.depth_kept = 0, true, false
	st.carries += 1
	// What the next frame carries from is this one's depth, kept even when no sample is added.
	studio_keep_depth(st, cmd, view_depth)
	return true, moving, keep_shadows
}

// Keeps `view_depth` for the next frame's carry.
@(private = "file")
studio_keep_depth :: proc(st: ^Studio, cmd: ^sdl.GPUCommandBuffer, view_depth: ^sdl.GPUTexture) {
	target := sdl.GPUColorTargetInfo{texture = st.prev_depth, load_op = .DONT_CARE, store_op = .STORE}
	pass := gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(pass, st.keep_pipeline)
	samplers := [1]sdl.GPUTextureSamplerBinding{{texture = view_depth, sampler = st.sampler}}
	gpu_bind_fragment_samplers(pass, 0, &samplers[0], len(samplers))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)
	st.depth_kept = true
}

// What the studio's samples are of, as one number: each item's mesh, its contents, its
// place and what of it is hidden, the softness of the lights, and the viewport's epoch. The
// view, the materials and the lights are not in it: the view is carried, the materials are
// composited fresh every frame, and the lights have studio_lights_key.
studio_scene_key :: proc(items: []Draw_Item, softness: f32, epoch: u64) -> u64 {
	Keyed :: struct {
		mesh:          uintptr,
		version:       u64,
		index_version: u64,
		hidden_stamp:  u32,
		model:         Mat4,
		hidden:        u64,
	}
	e := epoch
	h := hash.fnv64a(mem.ptr_to_bytes(&e))
	soft := softness
	h = hash.fnv64a(mem.ptr_to_bytes(&soft), h)
	for item in items {
		k := Keyed{uintptr(rawptr(item.mesh)), item.mesh.version, item.mesh.index_version, item.mesh.hidden_stamp, item.model, 0}
		if len(item.hidden) > 0 do k.hidden = hash.fnv64a(transmute([]u8)item.hidden)
		h = hash.fnv64a(mem.ptr_to_bytes(&k), h)
	}
	return max(h, 1)
}

// The lights the shadow samples are of, in the world, as one number: unchanged by a turn of
// the view for lights fixed to the scene, changed by it for lights fixed to the camera.
studio_lights_key :: proc(lights: Lights, view: Mat4, center: [3]f32, softness: f32) -> u64 {
	l := lights if lights != {} else lights_default()
	world := lights_to_world(l, view, center, softness)
	// The studio's turn is what the materials reflect, which no shadow sample reads.
	world.rig = {}
	// The world positions of camera-fixed lights come through a matrix inverse, whose last
	// bits can differ for a view that only seems unchanged; a ten-thousandth is far below
	// any visible move of a shadow.
	values := cast(^[size_of(Lights_World) / size_of(f32)]f32)&world
	for &v in values do v = math.round(v * 1e4)
	return hash.fnv64a(mem.ptr_to_bytes(&world))
}

// The triangles the items draw, which a shadow map sample draws every one of.
@(private = "file")
studio_triangles :: proc(items: []Draw_Item) -> (n: int) {
	for item in items do n += int(item.mesh.index_count / 3)
	return
}

// Whether the studio's picture is worth showing over live occlusion's: it has `min`
// samples, or carries samples from earlier views.
studio_shows :: proc(st: ^Studio, min: int) -> bool {
	return st.samples >= min || st.carried
}

// The light a studio sample's shadow comes from (studio_light).
Studio_Light :: struct {
	lit:           bool, // any light is on
	r2:            [2]f32, // the point of the light's disc
	dir:           [3]f32, // toward the light from the scene's middle (world, unit)
	radius:        f32, // the disc's radius around dir, as a tangent
	sphere:        bool, // a point or spot light, which the traced rays end at
	at:            [3]f32, // ...where it is (world)
	sphere_radius: f32,
	shadow:        Shadow_Lights,
}

// Which light studio sample `k` takes its shadow from, and its disc: each light sample
// picks one by its share of the lights' brightness through a golden-ratio sequence, and
// its disc's point from two more dimensions of the same family (R3), so every light's
// disc is covered evenly however the samples are shared. A sun's disc is as wide as its
// own size (Lights.shape.w, the sine of its angular radius) or else `softness`; a point
// or spot light's sphere is its own radius, or else `softness` seen from `center`.
studio_light :: proc(lights: Lights, view: Mat4, center: [3]f32, softness: f32, k: int) -> (sl: Studio_Light) {
	l := lights if lights != {} else lights_default()
	world := lights_to_world(l, view, center, softness)
	brightness: f32
	for i in 0 ..< LIGHT_COUNT {
		if world.size[i].w <= 0 do continue
		c := l.color[i]
		brightness += c.w * max(c.r, c.g, c.b)
		sl.shadow.pos[i] = world.pos[i]
		sl.shadow.shape[i] = {world.shape[i].x, world.shape[i].y, world.shape[i].z, world.size[i].w}
		sl.shadow.spot[i] = world.spot[i]
	}
	if brightness <= 0 do return
	sl.lit = true
	m := f32(k / STUDIO_KEY_EVERY)
	pick := math.mod(0.5 + m * 0.8191725, 1)
	j := -1
	for i in 0 ..< LIGHT_COUNT {
		if world.size[i].w <= 0 do continue
		j = i
		if pick < world.size[i].z do break
	}
	sl.r2 = {math.mod(0.5 + m * 0.6710436, 1), math.mod(0.5 + m * 0.5497005, 1)}
	sl.shadow.pick = {f32(j), 0, STUDIO_AMBIENT_SHARE * max(l.rig[0].w, 0) / brightness, 0}
	size := l.shape[j].w
	if l.pos[j].w == LIGHT_SUN {
		sl.dir = world.pos[j].xyz
		sl.radius = math.tan(math.asin(min(size, 0.99))) if size > 0 else softness
		return
	}
	sl.sphere = true
	sl.at = world.pos[j].xyz
	sl.sphere_radius = world.size[j].x
	// The shadow map's stand-in: one direction from the middle, over the sphere's angle.
	to := sl.at - center
	dist := linalg.length(to)
	sl.dir = to / dist if dist > 1e-6 else {0, 1, 0}
	sl.radius = sl.sphere_radius / max(dist, 1e-6)
	return
}

// The image shown: the viewport darkened by what the samples found; where carried samples
// are too few, mixed toward `under` (nil: the viewport). `no_shadows` leaves the shadows out
// while the view turns with lights fixed to the camera, whose shadows build again only once
// it rests: a frame's one light sample would show as speckle.
@(private = "file")
studio_composite :: proc(st: ^Studio, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, ao, shadow: f32, under: ^sdl.GPUTexture = nil, no_shadows := false) {
	st.strengths = {ao, shadow}
	target := sdl.GPUColorTargetInfo{texture = st.shown, load_op = .DONT_CARE, store_op = .STORE, cycle = true}
	pass := gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(pass, st.composite_pipeline)
	samplers := [3]sdl.GPUTextureSamplerBinding{{texture = vt.color, sampler = st.sampler}, {texture = st.accum, sampler = st.sampler}, {texture = under if under != nil else vt.color, sampler = st.sampler}}
	gpu_bind_fragment_samplers(pass, 0, &samplers[0], len(samplers))
	params := [4]f32{clamp(ao, 0, 1), 0 if no_shadows else clamp(shadow, 0, 1), STUDIO_CARRY_SETTLED if st.carried else 0, STUDIO_CARRY_KEY_SETTLED}
	gpu_push_fragment_uniform_data(cmd, 0, &params, size_of(params))
	gpu_draw_primitives(pass, 3, 1, 0, 0)
	gpu_end_render_pass(pass)
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
	st.shown_valid, st.carried, st.depth_kept = false, false, false
}

studio_destroy :: proc(r: ^Renderer, st: ^Studio) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	if st.shadow_pipeline != nil do gpu_release_graphics_pipeline(r.device, st.shadow_pipeline)
	if st.depth_pipeline != nil do gpu_release_graphics_pipeline(r.device, st.depth_pipeline)
	if st.gather_pipeline != nil do gpu_release_graphics_pipeline(r.device, st.gather_pipeline)
	if st.composite_pipeline != nil do gpu_release_graphics_pipeline(r.device, st.composite_pipeline)
	if st.reproject_pipeline != nil do gpu_release_graphics_pipeline(r.device, st.reproject_pipeline)
	if st.keep_pipeline != nil do gpu_release_graphics_pipeline(r.device, st.keep_pipeline)
	if st.sampler != nil do gpu_release_sampler(r.device, st.sampler)
	for t in ([6]^sdl.GPUTexture{st.shadow, st.accums[0], st.accums[1], st.shown, st.view_depth, st.prev_depth}) do if t != nil do gpu_release_texture(r.device, t)
	tracer_destroy(r, &st.trace)
	st^ = {trace = st.trace, carries = st.carries, carried_bare = st.carried_bare, restarts = st.restarts}
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
		st.gather_pipeline = create_fullscreen_pipeline(r, STUDIO_GATHER_FRAG_CODE, STUDIO_ACCUM_FORMAT, samplers = 2, additive = true)
		st.composite_pipeline = create_fullscreen_pipeline(r, STUDIO_COMPOSITE_FRAG_CODE, VIEWPORT_COLOR_FORMAT, samplers = 3)
		st.reproject_pipeline = create_fullscreen_pipeline(r, STUDIO_REPROJECT_FRAG_CODE, STUDIO_ACCUM_FORMAT, samplers = 3)
		st.keep_pipeline = create_fullscreen_pipeline(r, STUDIO_DEPTH_KEEP_FRAG_CODE, STUDIO_PREV_DEPTH_FORMAT, samplers = 1)
		st.sampler = gpu_create_sampler(r.device, {
			min_filter = .NEAREST, mag_filter = .NEAREST, mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE, address_mode_w = .CLAMP_TO_EDGE,
		})
		st.shadow = gpu_create_texture(r.device, {
			type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = STUDIO_SHADOW_SIZE, height = STUDIO_SHADOW_SIZE, layer_count_or_depth = 1, num_levels = 1,
		})
		if st.shadow_pipeline == nil || st.depth_pipeline == nil || st.gather_pipeline == nil || st.composite_pipeline == nil || st.reproject_pipeline == nil || st.keep_pipeline == nil || st.sampler == nil || st.shadow == nil {
			log.errorf("studio render: setup failed (%s); it stays off", sdl.GetError())
			return false
		}
	}
	want_view_depth := vt.samples != ._1
	if st.accum != nil && st.width == vt.width && st.height == vt.height && want_view_depth == (st.view_depth != nil) do return true
	for t in ([5]^sdl.GPUTexture{st.accums[0], st.accums[1], st.shown, st.view_depth, st.prev_depth}) do if t != nil do gpu_release_texture(r.device, t)
	st.view_depth, st.accum, st.accums, st.prev_depth = nil, nil, {}, nil
	if want_view_depth {
		st.view_depth = gpu_create_texture(r.device, {
			type = .D2, format = r.depth_format, usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	for &a in st.accums {
		a = gpu_create_texture(r.device, {
			type = .D2, format = STUDIO_ACCUM_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
			width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
		})
	}
	st.accum = st.accums[0]
	st.prev_depth = gpu_create_texture(r.device, {
		type = .D2, format = STUDIO_PREV_DEPTH_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	st.shown = gpu_create_texture(r.device, {
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	st.width, st.height = vt.width, vt.height
	st.samples, st.shown_valid, st.carried, st.depth_kept = 0, false, false, false
	if st.accums[0] == nil || st.accums[1] == nil || st.prev_depth == nil || st.shown == nil || want_view_depth && st.view_depth == nil {
		log.errorf("studio render: target creation failed (%s); it stays off", sdl.GetError())
		return false
	}
	return true
}
