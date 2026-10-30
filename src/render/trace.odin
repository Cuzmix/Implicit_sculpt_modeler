package render

import "base:runtime"
import "core:hash"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../jobs"

// The traced studio render (stage 4.3): the studio's samples cast a ray per pixel against
// the real triangles instead of reading shadow maps, so occlusion and the key light's
// shadow reach detail finer than a shadow map's texel. Each mesh keeps a tree over the
// triangles of each of its chunks (geom/chunk_bvh.odin), built on the CPU when its
// triangles change and refit on the GPU when only its vertices moved (blas_refit.comp.slang),
// and a tree over its shown chunks, from the bounds the sculptor keeps. A sample clears
// `visible` to 1, runs studio_trace.comp.slang once per item, each storing 0 where its
// triangles block the ray, and adds the result to the studio's accumulation target in
// the gather's encoding (studio_trace_add.frag.slang), so the composite reads both alike.
// Anything the device refuses, or a mesh that cannot be traced, leaves that run on the
// shadow-map gather, which stays as it was.

STUDIO_TRACE_COMP_CODE :: #load("shaders/studio_trace.comp" + SHADER_EXT)
// The same kernel over the driver's acceleration structures (Gpu_Caps.ray_query), which
// only the own Vulkan backend offers, so it has no Metal source.
when ODIN_OS != .Darwin {
	STUDIO_TRACE_RQ_COMP_CODE :: #load("shaders/studio_trace_rq.comp.spv")
}
STUDIO_TRACE_ADD_FRAG_CODE :: #load("shaders/studio_trace_add.frag" + SHADER_EXT)
BLAS_REFIT_COMP_CODE :: #load("shaders/blas_refit.comp" + SHADER_EXT)

// Matches numthreads in studio_trace.comp.slang and blas_refit.comp.slang.
@(private = "file")
TRACE_GROUP :: 8
@(private = "file")
REFIT_THREADS :: 64
// The widest dispatch every device must accept; more chunks spread over rows.
@(private = "file")
MAX_GROUPS_X :: 65535
// An item without chunks (the live boolean's preview) is traced in runs this long.
@(private = "file")
TRACE_RANGE_TRIANGLES :: 1024
// The largest storage buffer Vulkan guarantees a shader can read (maxStorageBufferRange),
// which SDL gives no way to query: Android tablets keep to it, so a larger mesh stays on
// the gather there, and the iPad, whose Metal reads more, keeps to it as a memory budget.
// Desktop GPUs read any buffer SDL can make.
TRACE_BUFFER_MAX :: 128 << 20 when MOBILE else int(max(u32))
// The least distance a ray starts off the surface, as a share of the scene's radius: well
// above a float's rounding at the scene's scale.
TRACE_EPSILON :: 1e-4
// Uploads go through a transfer buffer this big, cycled between batches.
@(private = "file")
TRACE_TRANSFER_SIZE :: 16 << 20
// A mesh's acceleration structure is built afresh after this many refits in a row, since
// each refit keeps the tree of the first build however far the vertices have moved.
@(private = "file")
BLAS_REFITS_MAX :: 16

Tracer :: struct {
	trace_pipeline: ^sdl.GPUComputePipeline,
	refit_pipeline: ^sdl.GPUComputePipeline,
	add_pipeline:   ^sdl.GPUGraphicsPipeline,
	visible:        ^sdl.GPUTexture, // R32_FLOAT, 1 where this sample's ray got out
	width, height:  u32, // of visible
	transfer:       ^sdl.GPUTransferBuffer,
	failed:         bool, // the device refused part of it; the studio stays on the gather
	// For the exit stats: samples traced, time spent building chunk trees and how many
	// were built, and the GPU memory of the trees of the items traced last.
	samples:        int,
	build_ms:       f64,
	chunks_built:   int,
	bytes:          int,
	// Ray queries (Gpu_Caps.ray_query, with Renderer.ray_query on): the kernel, the top
	// level over every traced item's structure, and the tables the kernel reads to turn
	// down hidden triangles. `rq` is whether this view traces that way; `rq_failed` that
	// the device refused it, and every view walks our trees instead.
	rq_pipeline:    ^sdl.GPUComputePipeline,
	tlas:           ^Gpu_Accel,
	rq_buffers:     [Rq_Buffer]^sdl.GPUBuffer,
	rq_capacity:    [Rq_Buffer]u32,
	rq:             bool,
	rq_failed:      bool,
	// For the exit stats: samples traced with ray queries, and structures built and refit.
	rq_samples:     int,
	blas_builds:    int,
	blas_refits:    int,
}

@(private = "file")
Rq_Buffer :: enum {
	Instances, // per traced item: its index buffer's address and where its runs start
	Runs,      // each geometry's first triangle, item after item
}

// Matches Instance in studio_trace.comp.slang.
@(private = "file")
Rq_Instance :: struct {
	indices: [2]u32,
	runs:    u32,
	pad:     u32,
}

// One mesh's trees, inside its Mesh_Buffers and released with them.
Trace_Mesh :: struct {
	trees:          [dynamic]geom.Chunk_Bvh,
	keys:           [dynamic]u64, // geom.chunk_bvh_key of each tree's run
	ranges:         [dynamic]geom.Index_Range, // each tree's triangles
	chunk_of:       [dynamic]u32, // the item's chunk each run is part of; max(u32) for none
	range_bounds:   [dynamic]geom.Aabb, // each run's box, for an item without chunks
	index_version:  u64, // Mesh_Buffers.index_version the keys were checked at
	refit_version:  u64, // Mesh_Buffers.version the GPU boxes were refit for; 0 for none
	tlas_key:       u64, // what the chunk tree on the GPU was built over; 0 for nothing
	tlas_empty:     bool, // every chunk is hidden or empty: nothing to trace
	// On the GPU: every chunk tree's nodes one after another, their triangle offsets two
	// to a word, each chunk's {node_off, order_off, first_tri, node_count}, and the
	// tree over the chunks; and how many bytes each holds.
	buffers:        [Trace_Buffer]^sdl.GPUBuffer,
	capacity:       [Trace_Buffer]u32,
	bytes:          int,
	// Under ray queries: the driver's structure over the shown runs, one geometry for each
	// stretch of them alike in opacity, and the key it was built for (the geometries, the
	// index versions and the vertex count), the version it was built or refit at and the
	// refits since it was built. A run is opaque unless it holds a triangle with a
	// repeated corner or the mesh has hidden triangles, whose candidates the kernel checks.
	blas:           ^Gpu_Accel,
	blas_key:       u64,
	blas_version:   u64,
	blas_refits:    int,
	geometries:     [dynamic]Blas_Geometry,
	rq_empty:       bool, // nothing shown: no structure
	// The runs whose repeated corners were looked for, at which index version, and what
	// was found.
	rq_ranges:      [dynamic]geom.Index_Range,
	rq_opaque:      [dynamic]bool,
	rq_index_version: u64,
}

@(private = "file")
Trace_Buffer :: enum {
	Nodes,
	Order,
	Chunks,
	Tlas,
}

// Matches Trace_Uniforms in studio_trace.comp.slang.
@(private = "file")
Trace_Uniforms :: struct {
	inv_view_proj: Mat4,
	to_mesh:       Mat4,
	key_base:      [4]f32,
	key_side:      [4]f32,
	key_up:        [4]f32,
	params:        [4]f32,
	sphere:        [4]f32,
}
#assert(size_of(Trace_Uniforms) == 208)

// Matches Add_Uniforms in studio_trace_add.frag.slang.
@(private = "file")
Add_Uniforms :: struct {
	inv_view_proj: Mat4,
	params:        [4]f32, // x: 1 for a light sample
	shadow:        Shadow_Lights,
}
#assert(size_of(Add_Uniforms) == 64 + 16 + size_of(Shadow_Lights))

// One sample's light for trace_sample: a light (`key`) or all round the surface; and this
// sample's point of the R2 sequence. A sun's direction (world, toward it) is `base`, its
// disc spanning `side` and `up` out to `radius`; a point or spot light (`sphere`) is a
// sphere at `at` of radius `sphere_radius`. `shadow` weighs the sample among the lights.
Trace_Light :: struct {
	key:            bool,
	base, side, up: [3]f32,
	radius:         f32,
	r2:             [2]f32,
	sphere:         bool,
	at:             [3]f32,
	sphere_radius:  f32,
	shadow:         Shadow_Lights,
}

// Readies every item's trees for this still view: builds the chunk trees whose triangles
// changed (on the pool), refits the boxes of meshes whose vertices moved, and rebuilds
// the tree over the chunks where they moved or were hidden. Returns false, with nothing
// left half done, when this view cannot be traced and the studio should use its gather:
// tracing is off, the device refused it, or an item cannot be traced. `ray_query`, which
// the caller passes once its kernel for them is made (trace_rq_kernel, render mode's own),
// lets the view trace with ray queries instead (Renderer.ray_query): tr.rq says whether it
// does, and then our trees are left as they were.
trace_prepare :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, items: []Draw_Item, pool: ^jobs.Pool, ray_query := false) -> bool {
	if !r.trace || tr.failed do return false
	if !tracer_ensure(r, tr, vt) {
		tracer_destroy(r, tr)
		tr.failed = true
		return false
	}
	for item in items {
		if blended(&r.single, item) do continue
		if !trace_traceable(item) do return false
	}
	// Ray queries where offered and on; any refusal sends the whole view to our trees.
	tr.rq = ray_query && r.ray_query && r.caps.ray_query && !tr.rq_failed && trace_prepare_rq(r, tr, cmd, items, pool)
	if tr.rq do return true
	tr.bytes = 0
	for item in items {
		if blended(&r.single, item) do continue
		if !trace_mesh_update(r, tr, cmd, item, pool) do return false
		tr.bytes += item.mesh.trace.bytes
	}
	return true
}

// Adds one traced sample to `accum` (cleared first when `first`), read from `view_depth`
// (the camera's depth at one sample) through `sampler`. `epsilon` is the least distance a
// ray starts off the surface, in world units.
trace_sample :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, accum, view_depth: ^sdl.GPUTexture, sampler: ^sdl.GPUSampler, view, proj: Mat4, items: []Draw_Item, light: Trace_Light, epsilon: f32, first: bool) {
	debug_group(cmd, "Studio trace")
	clear := sdl.GPUColorTargetInfo {
		texture     = tr.visible,
		clear_color = {1, 1, 1, 1},
		load_op     = .CLEAR,
		store_op    = .STORE,
		cycle       = true,
	}
	gpu_end_render_pass(gpu_begin_render_pass(cmd, &clear, 1, nil))

	// The tables the ray query kernel reads, written for this sample since a buffer's
	// address changes when an upload cycles it.
	if tr.rq do trace_rq_tables(r, tr, cmd, items)

	// Every item's dispatch only stores 0, so one pass holds them all, unordered.
	binding := sdl.GPUStorageTextureReadWriteBinding{texture = tr.visible}
	pass := gpu_begin_compute_pass(cmd, &binding, 1, nil, 0)
	gpu_bind_compute_pipeline(pass, tr.rq_pipeline if tr.rq else tr.trace_pipeline)
	depth := sdl.GPUTextureSamplerBinding{texture = view_depth, sampler = sampler}
	gpu_bind_compute_samplers(pass, 0, &depth, 1)
	u := Trace_Uniforms {
		inv_view_proj = linalg.inverse(proj * view),
		key_base      = {light.base.x, light.base.y, light.base.z, 1 if light.key else 0},
		key_side      = {light.side.x, light.side.y, light.side.z, light.radius},
		key_up        = {light.up.x, light.up.y, light.up.z, 0},
		params        = {light.r2.x, light.r2.y, epsilon, 1 if light.sphere else 0},
		sphere        = {light.at.x, light.at.y, light.at.z, light.sphere_radius},
	}
	if tr.rq {
		// One dispatch traces every item, in world space.
		reads := [2]^sdl.GPUBuffer{tr.rq_buffers[.Instances], tr.rq_buffers[.Runs]}
		gpu_bind_compute_storage_buffers(pass, 0, raw_data(reads[:]), len(reads))
		gpu_bind_compute_accel(pass, tr.tlas)
		u.to_mesh = 1
		gpu_push_compute_uniform_data(cmd, 0, &u, size_of(u))
		gpu_dispatch_compute(pass, (tr.width + TRACE_GROUP - 1) / TRACE_GROUP, (tr.height + TRACE_GROUP - 1) / TRACE_GROUP, 1)
		tr.rq_samples += 1
	}
	for item in items {
		if tr.rq do break
		if blended(&r.single, item) do continue
		tm := item.mesh.trace
		if tm == nil || tm.tlas_empty do continue
		reads := [6]^sdl.GPUBuffer{item.mesh.positions, item.mesh.indices, tm.buffers[.Nodes], tm.buffers[.Order], tm.buffers[.Chunks], tm.buffers[.Tlas]}
		gpu_bind_compute_storage_buffers(pass, 0, raw_data(reads[:]), len(reads))
		u.to_mesh = linalg.inverse(item.model)
		gpu_push_compute_uniform_data(cmd, 0, &u, size_of(u))
		gpu_dispatch_compute(pass, (tr.width + TRACE_GROUP - 1) / TRACE_GROUP, (tr.height + TRACE_GROUP - 1) / TRACE_GROUP, 1)
	}
	gpu_end_compute_pass(pass)

	target := sdl.GPUColorTargetInfo {
		texture  = accum,
		load_op  = .CLEAR if first else .LOAD,
		store_op = .STORE,
	}
	add := gpu_begin_render_pass(cmd, &target, 1, nil)
	gpu_bind_graphics_pipeline(add, tr.add_pipeline)
	samplers := [2]sdl.GPUTextureSamplerBinding{{texture = tr.visible, sampler = sampler}, {texture = view_depth, sampler = sampler}}
	gpu_bind_fragment_samplers(add, 0, &samplers[0], 2)
	au := Add_Uniforms{inv_view_proj = u.inv_view_proj, params = {1 if light.key else 0, 0, 0, 0}, shadow = light.shadow}
	gpu_push_fragment_uniform_data(cmd, 0, &au, size_of(au))
	gpu_draw_primitives(add, 3, 1, 0, 0)
	gpu_end_render_pass(add)
	tr.samples += 1
}

tracer_destroy :: proc(r: ^Renderer, tr: ^Tracer) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	if tr.trace_pipeline != nil do gpu_release_compute_pipeline(r.device, tr.trace_pipeline)
	if tr.refit_pipeline != nil do gpu_release_compute_pipeline(r.device, tr.refit_pipeline)
	if tr.add_pipeline != nil do gpu_release_graphics_pipeline(r.device, tr.add_pipeline)
	if tr.visible != nil do gpu_release_texture(r.device, tr.visible)
	if tr.transfer != nil do gpu_release_transfer_buffer(r.device, tr.transfer)
	if tr.rq_pipeline != nil do gpu_release_compute_pipeline(r.device, tr.rq_pipeline)
	gpu_release_accel(r.device, tr.tlas)
	for b in tr.rq_buffers do if b != nil do gpu_release_buffer(r.device, b)
	// The counters outlive the device's objects, for the exit stats.
	tr^ = {samples = tr.samples, build_ms = tr.build_ms, chunks_built = tr.chunks_built, failed = tr.failed, rq_failed = tr.rq_failed, rq_samples = tr.rq_samples, blas_builds = tr.blas_builds, blas_refits = tr.blas_refits}
}

// Releases a mesh's trees; mesh_buffers_destroy calls it, after the caller has waited
// for the GPU as it must before releasing the mesh's own buffers.
@(private)
trace_mesh_destroy :: proc(r: ^Renderer, tm: ^Trace_Mesh) {
	for &tree in tm.trees do geom.chunk_bvh_destroy(&tree)
	delete(tm.trees)
	delete(tm.keys)
	delete(tm.ranges)
	delete(tm.chunk_of)
	delete(tm.range_bounds)
	for b in tm.buffers do if b != nil do gpu_release_buffer(r.device, b)
	gpu_release_accel(r.device, tm.blas)
	delete(tm.geometries)
	delete(tm.rq_ranges)
	delete(tm.rq_opaque)
	tm^ = {}
}

// Whether an item can be traced at all: its mesh's buffers can be read by compute, it
// has the CPU mesh they were made from, and (on tablets) every buffer fits the range a
// shader is guaranteed to read.
@(private = "file")
trace_traceable :: proc(item: Draw_Item) -> bool {
	mb, src := item.mesh, item.source
	if src == nil || !mb.storage do return false
	if u32(len(src.positions)) > mb.vertex_capacity || u32(len(src.indices)) > mb.index_count do return false
	if int(mb.vertex_capacity) * size_of(geom.Vec3) > TRACE_BUFFER_MAX || int(mb.index_count) * size_of(u32) > TRACE_BUFFER_MAX do return false
	for c in item.chunks do if c.first_index + c.index_count > u32(len(src.indices)) do return false
	return true
}

@(private = "file")
tracer_ensure :: proc(r: ^Renderer, tr: ^Tracer, vt: ^Viewport_Target) -> bool {
	if tr.trace_pipeline == nil {
		visible_usage := sdl.GPUTextureUsageFlags{.COLOR_TARGET, .SAMPLER, .COMPUTE_STORAGE_WRITE}
		if !gpu_texture_supports_format(r.device, .R32_FLOAT, .D2, visible_usage) {
			log.warn("traced studio: this device cannot write R32_FLOAT from compute; the studio uses shadow maps")
			return false
		}
		tr.trace_pipeline = gpu_create_compute_pipeline(r.device, {
			code_size = len(STUDIO_TRACE_COMP_CODE), code = raw_data(STUDIO_TRACE_COMP_CODE), entrypoint = SHADER_ENTRY,
			format = SHADER_FORMAT, num_samplers = 1, num_readonly_storage_buffers = 6, num_readwrite_storage_textures = 1,
			num_uniform_buffers = 1, threadcount_x = TRACE_GROUP, threadcount_y = TRACE_GROUP, threadcount_z = 1,
		})
		tr.refit_pipeline = gpu_create_compute_pipeline(r.device, {
			code_size = len(BLAS_REFIT_COMP_CODE), code = raw_data(BLAS_REFIT_COMP_CODE), entrypoint = SHADER_ENTRY,
			format = SHADER_FORMAT, num_readonly_storage_buffers = 4, num_readwrite_storage_buffers = 1,
			num_uniform_buffers = 1, threadcount_x = REFIT_THREADS, threadcount_y = 1, threadcount_z = 1,
		})
		tr.add_pipeline = create_fullscreen_pipeline(r, STUDIO_TRACE_ADD_FRAG_CODE, STUDIO_ACCUM_FORMAT, samplers = 2, additive = true)
		tr.transfer = gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = TRACE_TRANSFER_SIZE})
		if tr.trace_pipeline == nil || tr.refit_pipeline == nil || tr.add_pipeline == nil || tr.transfer == nil {
			log.errorf("traced studio: setup failed (%s); the studio uses shadow maps", sdl.GetError())
			return false
		}
	}
	if tr.visible != nil && tr.width == vt.width && tr.height == vt.height do return true
	if tr.visible != nil do gpu_release_texture(r.device, tr.visible)
	tr.visible = gpu_create_texture(r.device, {
		type = .D2, format = .R32_FLOAT, usage = {.COLOR_TARGET, .SAMPLER, .COMPUTE_STORAGE_WRITE},
		width = vt.width, height = vt.height, layer_count_or_depth = 1, num_levels = 1,
	})
	tr.width, tr.height = vt.width, vt.height
	if tr.visible == nil {
		log.errorf("traced studio: target creation failed (%s); the studio uses shadow maps", sdl.GetError())
		return false
	}
	return true
}

// Brings one item's trees up to date with its mesh, recording uploads and the refit
// into `cmd`. False when the device refused a buffer.
@(private = "file")
trace_mesh_update :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, item: Draw_Item, pool: ^jobs.Pool) -> bool {
	debug_group(cmd, "Trace mesh update")
	mb, src := item.mesh, item.source
	if mb.trace == nil do mb.trace = new(Trace_Mesh)
	tm := mb.trace

	ranges, chunk_of := trace_runs(item)

	// The triangles: only runs whose key changed are built again. Keys are checked only
	// when the mesh's own indices were uploaded since, or the runs changed.
	same := slice.equal(ranges[:], tm.ranges[:])
	rebuilt := false
	if !same || tm.index_version != mb.index_version || len(tm.trees) != len(ranges) {
		start := time.tick_now()
		keys := make([]u64, len(ranges), context.temp_allocator)
		trace_keys(pool, src.indices[:], ranges[:], keys)
		trees := make([dynamic]geom.Chunk_Bvh, len(ranges))
		which := make([dynamic]u32, context.temp_allocator)
		if same && len(tm.trees) == len(ranges) {
			for k, i in keys {
				trees[i] = tm.trees[i]
				if k != tm.keys[i] do append(&which, u32(i))
			}
		} else {
			// The runs moved (dynamic topology grew a chunk, a voxel surface was laid out
			// again): a tree whose key is unchanged moves to its run's new place. The map
			// is only looked up, so its order decides nothing.
			old := make(map[u64]int, len(tm.keys), context.temp_allocator)
			for k, i in tm.keys do old[k] = i
			for k, i in keys {
				if j, ok := old[k]; ok && tm.trees[j].nodes.allocator.procedure != nil {
					trees[i] = tm.trees[j]
					tm.trees[j] = {}
				} else {
					append(&which, u32(i))
				}
			}
			for &tree in tm.trees do geom.chunk_bvh_destroy(&tree)
		}
		geom.chunk_bvh_build_many(pool, src.positions[:], src.indices[:], ranges[:], which[:], trees[:])
		delete(tm.trees)
		tm.trees = trees
		resize(&tm.keys, len(keys))
		copy(tm.keys[:], keys)
		resize(&tm.ranges, len(ranges))
		copy(tm.ranges[:], ranges[:])
		resize(&tm.chunk_of, len(chunk_of))
		copy(tm.chunk_of[:], chunk_of[:])
		tm.index_version = mb.index_version
		rebuilt = len(which) > 0 || !same || tm.buffers[.Nodes] == nil
		tr.chunks_built += len(which)
		tr.build_ms += time.duration_milliseconds(time.tick_since(start))
	}
	if rebuilt {
		if !trace_mesh_upload_trees(r, tr, cmd, tm) {
			trace_mesh_invalidate(tm)
			return false
		}
		tm.refit_version = 0
		tm.tlas_key = 0
	}

	// The boxes, wherever the vertices moved since the last refit.
	if tm.refit_version != mb.version {
		if len(item.chunks) == 0 {
			resize(&tm.range_bounds, len(tm.ranges))
			for x, i in tm.ranges {
				b := geom.AABB_EMPTY
				for v in src.indices[x.first_index:][:x.index_count] do geom.aabb_grow(&b, src.positions[v])
				tm.range_bounds[i] = b
			}
		}
		chunk_count := u32(len(tm.ranges))
		groups := (chunk_count + REFIT_THREADS - 1) / REFIT_THREADS
		groups_x := min(groups, MAX_GROUPS_X)
		groups_y := (groups + groups_x - 1) / max(groups_x, 1)
		params := [4]u32{chunk_count, groups_x, 0, 0}
		gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
		binding := sdl.GPUStorageBufferReadWriteBinding{buffer = tm.buffers[.Nodes]}
		pass := gpu_begin_compute_pass(cmd, nil, 0, &binding, 1)
		gpu_bind_compute_pipeline(pass, tr.refit_pipeline)
		reads := [4]^sdl.GPUBuffer{mb.positions, mb.indices, tm.buffers[.Order], tm.buffers[.Chunks]}
		gpu_bind_compute_storage_buffers(pass, 0, raw_data(reads[:]), len(reads))
		if groups > 0 do gpu_dispatch_compute(pass, groups_x, groups_y, 1)
		gpu_end_compute_pass(pass)
		tm.refit_version = mb.version
	}

	// The tree over the shown chunks, from their boxes, wherever those moved or the
	// hidden ones changed.
	shown, bounds := trace_shown(item, tm)
	key := max(hash.fnv64a(slice.to_bytes(bounds[:]), hash.fnv64a(slice.to_bytes(shown[:]))), 1)
	tm.tlas_empty = len(shown) == 0
	if key == tm.tlas_key || tm.tlas_empty do return true
	nodes := make([dynamic]geom.Gpu_Bvh_Node, context.temp_allocator)
	order := make([]u32, len(shown), context.temp_allocator)
	geom.gpu_bvh_build(bounds[:], 1, &nodes, order, context.temp_allocator)
	// A leaf holds one run: name it directly, so the shader needs no order of its own.
	for &n in nodes do if n.count > 0 do n.first = shown[order[n.first]]
	if !trace_buffer_upload(r, tr, cmd, tm, .Tlas, slice.to_bytes(nodes[:])) {
		trace_mesh_invalidate(tm)
		return false
	}
	tm.tlas_key = key
	return true
}

// The runs the trees cover, in temp memory: the item's chunks, split where one is too
// long for 16-bit offsets, or fixed runs over the whole mesh for an item without chunks;
// and the chunk each is part of (max(u32) for none).
@(private = "file")
trace_runs :: proc(item: Draw_Item) -> (ranges: [dynamic]geom.Index_Range, chunk_of: [dynamic]u32) {
	ranges = make([dynamic]geom.Index_Range, context.temp_allocator)
	chunk_of = make([dynamic]u32, context.temp_allocator)
	if len(item.chunks) > 0 {
		for c, i in item.chunks {
			for at := u32(0); at < c.index_count; at += 3 * geom.CHUNK_BVH_MAX_TRIANGLES {
				append(&ranges, geom.Index_Range{c.first_index + at, min(c.index_count - at, 3 * geom.CHUNK_BVH_MAX_TRIANGLES)})
				append(&chunk_of, u32(i))
			}
		}
	} else {
		count := u32(len(item.source.indices))
		for at := u32(0); at < count; at += 3 * TRACE_RANGE_TRIANGLES {
			append(&ranges, geom.Index_Range{at, min(count - at, 3 * TRACE_RANGE_TRIANGLES)})
			append(&chunk_of, max(u32))
		}
	}
	return
}

// ---- Ray queries --------------------------------------------------------------------

// The traced studio's ray query kernel, made on first use where the device offers ray
// queries and they are on (Renderer.ray_query): whether trace_prepare may trace this
// tracer's view that way. A refusal is logged and the studio walks its own trees from then.
trace_rq_kernel :: proc(r: ^Renderer, tr: ^Tracer) -> bool {
	if !r.ray_query || !r.caps.ray_query || tr.rq_failed do return false
	if tr.rq_pipeline == nil {
		when ODIN_OS != .Darwin {
			tr.rq_pipeline = gpu_create_compute_pipeline_traced(r.device, {
				code_size = len(STUDIO_TRACE_RQ_COMP_CODE), code = raw_data(STUDIO_TRACE_RQ_COMP_CODE), entrypoint = SHADER_ENTRY,
				format = SHADER_FORMAT, num_samplers = 1, num_readonly_storage_buffers = 2, num_readwrite_storage_textures = 1,
				num_uniform_buffers = 1, threadcount_x = TRACE_GROUP, threadcount_y = TRACE_GROUP, threadcount_z = 1,
			})
		}
		if tr.rq_pipeline == nil {
			log.warnf("traced studio: the ray query kernel could not be made (%s); it walks its own trees", sdl.GetError())
			tr.rq_failed = true
			return false
		}
	}
	return true
}

// Brings every traced item's acceleration structure up to date and builds the top level
// over them, an instance for each item with a structure, numbered in order from 0; false
// when the device refused any of it, and the view walks our trees.
@(private = "file")
trace_prepare_rq :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, items: []Draw_Item, pool: ^jobs.Pool) -> bool {
	debug_group(cmd, "Ray query structures")
	instances := make([dynamic]Tlas_Instance, context.temp_allocator)
	bytes := 0
	for item in items {
		if blended(&r.single, item) do continue
		if !trace_mesh_update_rq(r, tr, cmd, item, pool) do return false
		tm := item.mesh.trace
		bytes += int(gpu_accel_bytes(tm.blas))
		if !tm.rq_empty do append(&instances, Tlas_Instance{blas = tm.blas, transform = item.model, custom = u32(len(instances))})
	}
	gpu_accel_trim(r.device)
	tr.bytes = bytes
	if len(instances) == 0 {
		gpu_release_accel(r.device, tr.tlas)
		tr.tlas = nil
		return true
	}
	tlas := gpu_build_tlas(cmd, instances[:], tr.tlas)
	if tlas == nil {
		log.warn("ray queries: the top-level acceleration structure could not be built; the view walks the app's own trees")
		return false
	}
	if tlas != tr.tlas do gpu_release_accel(r.device, tr.tlas)
	tr.tlas = tlas
	tr.bytes += int(gpu_accel_bytes(tlas))
	return true
}

// Builds or refits one item's acceleration structure, recording it into `cmd`; false when
// the device refused it or (on tablets) it is larger than the trace budget.
@(private = "file")
trace_mesh_update_rq :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, item: Draw_Item, pool: ^jobs.Pool) -> bool {
	mb, src := item.mesh, item.source
	if mb.trace == nil do mb.trace = new(Trace_Mesh)
	tm := mb.trace
	ranges, chunk_of := trace_runs(item)
	// Which runs hold a triangle with a repeated corner, looked for again when the mesh's
	// own indices were uploaded since or the runs changed.
	if !slice.equal(ranges[:], tm.rq_ranges[:]) || tm.rq_index_version != mb.index_version {
		resize(&tm.rq_opaque, len(ranges))
		trace_opaque(pool, src.indices[:], ranges[:], tm.rq_opaque[:])
		resize(&tm.rq_ranges, len(ranges))
		copy(tm.rq_ranges[:], ranges[:])
		tm.rq_index_version = mb.index_version
	}
	// The shown runs, as the tree over the chunks takes them, merged where they follow
	// one another alike in opacity. Hidden triangles are uploaded as repeated corners
	// the CPU mesh does not have, so a mesh with any makes every run not opaque.
	geometries := make([dynamic]Blas_Geometry, context.temp_allocator)
	for x, i in ranges {
		if c := chunk_of[i]; c != max(u32) {
			if item.hidden != nil && int(c) < len(item.hidden) && item.hidden[c] do continue
			if b := item.chunks[c].bounds; b.lo.x > b.hi.x do continue
		}
		g := Blas_Geometry{first_triangle = x.first_index / 3, triangle_count = x.index_count / 3, opaque = tm.rq_opaque[i] && mb.hidden_stamp == 0}
		if n := len(geometries); n > 0 {
			last := &geometries[n - 1]
			if last.opaque == g.opaque && last.first_triangle + last.triangle_count == g.first_triangle {
				last.triangle_count += g.triangle_count
				continue
			}
		}
		append(&geometries, g)
	}
	tm.rq_empty = len(geometries) == 0
	if tm.rq_empty do return true
	vertex_count := u32(len(src.positions))
	// A refit may only move vertices: anything else about the triangles is a new build.
	versions := [3]u64{mb.index_version, u64(mb.hidden_stamp), u64(vertex_count)}
	key := max(hash.fnv64a(slice.to_bytes(geometries[:]), hash.fnv64a(slice.to_bytes(versions[:]))), 1)
	if key == tm.blas_key && tm.blas_version == mb.version do return true
	refit := key == tm.blas_key && tm.blas != nil && tm.blas_refits < BLAS_REFITS_MAX
	blas := gpu_build_blas(cmd, mb.positions, mb.indices, vertex_count, geometries[:], tm.blas if refit else nil)
	if blas == nil {
		log.warn("ray queries: an acceleration structure could not be built; the view walks the app's own trees")
		return false
	}
	if blas == tm.blas {
		tm.blas_refits += 1
		tr.blas_refits += 1
	} else {
		gpu_release_accel(r.device, tm.blas)
		tm.blas_refits = 0
		tr.blas_builds += 1
	}
	tm.blas, tm.blas_key, tm.blas_version = blas, key, mb.version
	resize(&tm.geometries, len(geometries))
	copy(tm.geometries[:], geometries[:])
	if int(gpu_accel_bytes(blas)) > TRACE_BUFFER_MAX {
		log.warnf("ray queries: an acceleration structure of %d MB is more than the trace budget; the view walks the app's own trees", gpu_accel_bytes(blas) >> 20)
		return false
	}
	return true
}

// Whether each run's triangles all have three different corners, on the pool.
@(private = "file")
trace_opaque :: proc(pool: ^jobs.Pool, indices: []u32, ranges: []geom.Index_Range, opaque: []bool) {
	Job :: struct {
		indices: []u32,
		ranges:  []geom.Index_Range,
		opaque:  []bool,
	}
	job := Job{indices, ranges, opaque}
	jobs.parallel_for(pool, len(ranges), &job, proc(data: rawptr, i: int) {
		j := (^Job)(data)
		x := j.ranges[i]
		ok := true
		for t := x.first_index; t + 2 < x.first_index + x.index_count; t += 3 {
			a, b, c := j.indices[t], j.indices[t + 1], j.indices[t + 2]
			if a == b || b == c || a == c {
				ok = false
				break
			}
		}
		j.opaque[i] = ok
	})
}

// Writes the kernel's tables for the items trace_prepare_rq put in the top level, in
// the same order: each one's index buffer address and where its geometries' first
// triangles start.
@(private = "file")
trace_rq_tables :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, items: []Draw_Item) {
	instances := make([dynamic]Rq_Instance, context.temp_allocator)
	runs := make([dynamic]u32, context.temp_allocator)
	for item in items {
		if blended(&r.single, item) do continue
		tm := item.mesh.trace
		if tm == nil || tm.rq_empty do continue
		address := gpu_buffer_address(cmd, item.mesh.indices)
		append(&instances, Rq_Instance{indices = {u32(address), u32(address >> 32)}, runs = u32(len(runs))})
		for g in tm.geometries do append(&runs, g.first_triangle)
	}
	if len(instances) == 0 do append(&instances, Rq_Instance{})
	if len(runs) == 0 do append(&runs, 0)
	trace_rq_upload(r, tr, cmd, .Instances, slice.to_bytes(instances[:]))
	trace_rq_upload(r, tr, cmd, .Runs, slice.to_bytes(runs[:]))
}

// Copies a small table to the start of one of the tracer's ray query buffers, growing it
// first when it does not fit.
@(private = "file")
trace_rq_upload :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, which: Rq_Buffer, data: []u8) {
	if tr.rq_buffers[which] == nil || u32(len(data)) > tr.rq_capacity[which] {
		// The buffer goes once the samples that read it have run.
		if tr.rq_buffers[which] != nil do gpu_release_buffer(r.device, tr.rq_buffers[which])
		tr.rq_capacity[which] = u32(len(data) + len(data) / 4)
		tr.rq_buffers[which] = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = tr.rq_capacity[which]})
	}
	dst := gpu_map_transfer_buffer(r.device, tr.transfer, true)
	if dst == nil || tr.rq_buffers[which] == nil do return
	copy(([^]u8)(dst)[:len(data)], data)
	gpu_unmap_transfer_buffer(r.device, tr.transfer)
	pass := gpu_begin_copy_pass(cmd)
	gpu_upload_to_buffer(pass, {transfer_buffer = tr.transfer}, {buffer = tr.rq_buffers[which], size = u32(len(data))}, true)
	gpu_end_copy_pass(pass)
}

// The runs of an item's trees that are shown and not empty, and their boxes in mesh space,
// in temp memory: what the tree over its chunks is built from, here and in render mode.
@(private)
trace_shown :: proc(item: Draw_Item, tm: ^Trace_Mesh) -> (shown: [dynamic]u32, bounds: [dynamic]geom.Aabb) {
	shown = make([dynamic]u32, context.temp_allocator)
	bounds = make([dynamic]geom.Aabb, context.temp_allocator)
	for c, i in tm.chunk_of {
		b: geom.Aabb
		if c == max(u32) {
			b = tm.range_bounds[i]
		} else {
			if item.hidden != nil && int(c) < len(item.hidden) && item.hidden[c] do continue
			b = item.chunks[c].bounds
		}
		if b.lo.x > b.hi.x do continue
		append(&shown, u32(i))
		append(&bounds, b)
	}
	return
}

// Makes the next trace_mesh_update upload everything again after an upload failed part
// way, keeping the trees, which a run whose key is unchanged takes back.
@(private = "file")
trace_mesh_invalidate :: proc(tm: ^Trace_Mesh) {
	clear(&tm.ranges)
	tm.index_version, tm.refit_version, tm.tlas_key = 0, 0, 0
}

// Each run's key, on the pool: hashing every index of a large mesh takes a while.
@(private = "file")
trace_keys :: proc(pool: ^jobs.Pool, indices: []u32, ranges: []geom.Index_Range, keys: []u64) {
	Job :: struct {
		indices: []u32,
		ranges:  []geom.Index_Range,
		keys:    []u64,
	}
	job := Job{indices, ranges, keys}
	jobs.parallel_for(pool, len(ranges), &job, proc(data: rawptr, i: int) {
		j := (^Job)(data)
		j.keys[i] = geom.chunk_bvh_key(j.indices, j.ranges[i].first_index, j.ranges[i].index_count)
	})
}

// Lays the chunk trees out one after another and uploads them, with each chunk's offsets.
// A chunk's triangle offsets start on a word of their own.
@(private = "file")
trace_mesh_upload_trees :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, tm: ^Trace_Mesh) -> bool {
	node_count, word_count := 0, 0
	for tree in tm.trees {
		node_count += len(tree.nodes)
		word_count += (len(tree.order) + 1) / 2
	}
	heap := runtime.heap_allocator()
	nodes := make([]geom.Gpu_Bvh_Node, node_count, heap)
	defer delete(nodes, heap)
	words := make([]u32, word_count, heap)
	defer delete(words, heap)
	chunks := make([][4]u32, len(tm.trees), heap)
	defer delete(chunks, heap)
	node_at, word_at := 0, 0
	for tree, i in tm.trees {
		copy(nodes[node_at:], tree.nodes[:])
		for o, k in tree.order do words[word_at + k / 2] |= u32(o) << (16 * u32(k & 1))
		chunks[i] = {u32(node_at), u32(2 * word_at), tm.ranges[i].first_index / 3, u32(len(tree.nodes))}
		node_at += len(tree.nodes)
		word_at += (len(tree.order) + 1) / 2
	}
	return trace_buffer_upload(r, tr, cmd, tm, .Nodes, slice.to_bytes(nodes)) &&
		trace_buffer_upload(r, tr, cmd, tm, .Order, slice.to_bytes(words)) &&
		trace_buffer_upload(r, tr, cmd, tm, .Chunks, slice.to_bytes(chunks))
}

// Copies `data` to the start of one of the mesh's trace buffers, making it bigger first
// (by a quarter again) when it does not fit, through the tracer's transfer buffer one
// batch at a time. False when the device refused the buffer or it is too big to read.
@(private = "file")
trace_buffer_upload :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, tm: ^Trace_Mesh, which: Trace_Buffer, data: []u8) -> bool {
	size := max(len(data), size_of(geom.Gpu_Bvh_Node))
	if size > TRACE_BUFFER_MAX {
		log.warnf("traced studio: %d MB of trees is more than this device reads; the studio uses shadow maps", size >> 20)
		return false
	}
	if tm.buffers[which] == nil || u32(size) > tm.capacity[which] {
		if tm.buffers[which] != nil {
			_ = gpu_wait_for_idle(r.device)
			gpu_release_buffer(r.device, tm.buffers[which])
		}
		capacity := u32(min(size + size / 4, TRACE_BUFFER_MAX))
		usage := sdl.GPUBufferUsageFlags{.COMPUTE_STORAGE_READ}
		if which == .Nodes do usage += {.COMPUTE_STORAGE_WRITE}
		tm.buffers[which] = gpu_create_buffer(r.device, {usage = usage, size = capacity})
		tm.capacity[which] = capacity if tm.buffers[which] != nil else 0
		tm.bytes = 0
		for c in tm.capacity do tm.bytes += int(c)
		if tm.buffers[which] == nil {
			log.errorf("traced studio: a buffer of %d MB was refused (%s); the studio uses shadow maps", capacity >> 20, sdl.GetError())
			return false
		}
	}
	for offset := 0; offset < len(data); offset += TRACE_TRANSFER_SIZE {
		part := data[offset:min(offset + TRACE_TRANSFER_SIZE, len(data))]
		dst := gpu_map_transfer_buffer(r.device, tr.transfer, true)
		if dst == nil {
			log.errorf("traced studio: upload failed (%s)", sdl.GetError())
			return false
		}
		copy(([^]u8)(dst)[:len(part)], part)
		gpu_unmap_transfer_buffer(r.device, tr.transfer)
		pass := gpu_begin_copy_pass(cmd)
		gpu_upload_to_buffer(pass, {transfer_buffer = tr.transfer}, {buffer = tm.buffers[which], offset = u32(offset), size = u32(len(part))}, false)
		gpu_end_copy_pass(pass)
	}
	return true
}
