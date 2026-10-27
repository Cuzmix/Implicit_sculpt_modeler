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
// triangles change and refit on the GPU when only its vertices moved (blas_refit.comp),
// and a tree over its shown chunks, from the bounds the sculptor keeps. A sample clears
// `visible` to 1, runs studio_trace.comp once per item, each storing 0 where its
// triangles block the ray, and adds the result to the studio's accumulation target in
// the gather's encoding (studio_trace_add.frag), so the composite reads both alike.
// Anything the device refuses, or a mesh that cannot be traced, leaves that run on the
// shadow-map gather, which stays as it was.

STUDIO_TRACE_COMP_SPV :: #load("shaders/studio_trace.comp.spv")
STUDIO_TRACE_ADD_FRAG_SPV :: #load("shaders/studio_trace_add.frag.spv")
BLAS_REFIT_COMP_SPV :: #load("shaders/blas_refit.comp.spv")

// Matches local_size in studio_trace.comp and blas_refit.comp.
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
// which SDL gives no way to query: tablets keep to it, so a larger mesh stays on the
// gather there. Desktop GPUs read any buffer SDL can make.
TRACE_BUFFER_MAX :: 128 << 20 when ODIN_PLATFORM_SUBTARGET == .Android else int(max(u32))
// The least distance a ray starts off the surface, as a share of the scene's radius: well
// above a float's rounding at the scene's scale.
TRACE_EPSILON :: 1e-4
// Uploads go through a transfer buffer this big, cycled between batches.
@(private = "file")
TRACE_TRANSFER_SIZE :: 16 << 20

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
}

@(private = "file")
Trace_Buffer :: enum {
	Nodes,
	Order,
	Chunks,
	Tlas,
}

// Matches Trace_Uniforms in studio_trace.comp.
@(private = "file")
Trace_Uniforms :: struct {
	inv_view_proj: Mat4,
	to_mesh:       Mat4,
	key_base:      [4]f32,
	key_side:      [4]f32,
	key_up:        [4]f32,
	params:        [4]f32,
}

// One sample's light for trace_sample: around the key light, whose direction (world,
// toward it) is `base` and whose disc spans `side` and `up` out to `radius`, or all round
// the surface; and this sample's point of the R2 sequence.
Trace_Light :: struct {
	key:            bool,
	base, side, up: [3]f32,
	radius:         f32,
	r2:             [2]f32,
}

// Readies every item's trees for this still view: builds the chunk trees whose triangles
// changed (on the pool), refits the boxes of meshes whose vertices moved, and rebuilds
// the tree over the chunks where they moved or were hidden. Returns false, with nothing
// left half done, when this view cannot be traced and the studio should use its gather:
// tracing is off, the device refused it, or an item cannot be traced.
trace_prepare :: proc(r: ^Renderer, tr: ^Tracer, cmd: ^sdl.GPUCommandBuffer, vt: ^Viewport_Target, items: []Draw_Item, pool: ^jobs.Pool) -> bool {
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
	clear := sdl.GPUColorTargetInfo {
		texture     = tr.visible,
		clear_color = {1, 1, 1, 1},
		load_op     = .CLEAR,
		store_op    = .STORE,
		cycle       = true,
	}
	sdl.EndGPURenderPass(sdl.BeginGPURenderPass(cmd, &clear, 1, nil))

	// Every item's dispatch only stores 0, so one pass holds them all, unordered.
	binding := sdl.GPUStorageTextureReadWriteBinding{texture = tr.visible}
	pass := sdl.BeginGPUComputePass(cmd, &binding, 1, nil, 0)
	sdl.BindGPUComputePipeline(pass, tr.trace_pipeline)
	depth := sdl.GPUTextureSamplerBinding{texture = view_depth, sampler = sampler}
	sdl.BindGPUComputeSamplers(pass, 0, &depth, 1)
	u := Trace_Uniforms {
		inv_view_proj = linalg.inverse(proj * view),
		key_base      = {light.base.x, light.base.y, light.base.z, 1 if light.key else 0},
		key_side      = {light.side.x, light.side.y, light.side.z, light.radius},
		key_up        = {light.up.x, light.up.y, light.up.z, 0},
		params        = {light.r2.x, light.r2.y, epsilon, 0},
	}
	for item in items {
		if blended(&r.single, item) do continue
		tm := item.mesh.trace
		if tm == nil || tm.tlas_empty do continue
		reads := [6]^sdl.GPUBuffer{item.mesh.positions, item.mesh.indices, tm.buffers[.Nodes], tm.buffers[.Order], tm.buffers[.Chunks], tm.buffers[.Tlas]}
		sdl.BindGPUComputeStorageBuffers(pass, 0, raw_data(reads[:]), len(reads))
		u.to_mesh = linalg.inverse(item.model)
		sdl.PushGPUComputeUniformData(cmd, 0, &u, size_of(u))
		sdl.DispatchGPUCompute(pass, (tr.width + TRACE_GROUP - 1) / TRACE_GROUP, (tr.height + TRACE_GROUP - 1) / TRACE_GROUP, 1)
	}
	sdl.EndGPUComputePass(pass)

	target := sdl.GPUColorTargetInfo {
		texture  = accum,
		load_op  = .CLEAR if first else .LOAD,
		store_op = .STORE,
	}
	add := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	sdl.BindGPUGraphicsPipeline(add, tr.add_pipeline)
	samplers := [2]sdl.GPUTextureSamplerBinding{{texture = tr.visible, sampler = sampler}, {texture = view_depth, sampler = sampler}}
	sdl.BindGPUFragmentSamplers(add, 0, &samplers[0], 2)
	params := [4]f32{1 if light.key else 0, 0, 0, 0}
	sdl.PushGPUFragmentUniformData(cmd, 0, &params, size_of(params))
	sdl.DrawGPUPrimitives(add, 3, 1, 0, 0)
	sdl.EndGPURenderPass(add)
	tr.samples += 1
}

tracer_destroy :: proc(r: ^Renderer, tr: ^Tracer) {
	if r.device == nil do return
	_ = sdl.WaitForGPUIdle(r.device)
	if tr.trace_pipeline != nil do sdl.ReleaseGPUComputePipeline(r.device, tr.trace_pipeline)
	if tr.refit_pipeline != nil do sdl.ReleaseGPUComputePipeline(r.device, tr.refit_pipeline)
	if tr.add_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, tr.add_pipeline)
	if tr.visible != nil do sdl.ReleaseGPUTexture(r.device, tr.visible)
	if tr.transfer != nil do sdl.ReleaseGPUTransferBuffer(r.device, tr.transfer)
	// The counters outlive the device's objects, for the exit stats.
	tr^ = {samples = tr.samples, build_ms = tr.build_ms, chunks_built = tr.chunks_built, failed = tr.failed}
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
	for b in tm.buffers do if b != nil do sdl.ReleaseGPUBuffer(r.device, b)
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
		if !sdl.GPUTextureSupportsFormat(r.device, .R32_FLOAT, .D2, visible_usage) {
			log.warn("traced studio: this device cannot write R32_FLOAT from compute; the studio uses shadow maps")
			return false
		}
		tr.trace_pipeline = sdl.CreateGPUComputePipeline(r.device, {
			code_size = len(STUDIO_TRACE_COMP_SPV), code = raw_data(STUDIO_TRACE_COMP_SPV), entrypoint = "main",
			format = {.SPIRV}, num_samplers = 1, num_readonly_storage_buffers = 6, num_readwrite_storage_textures = 1,
			num_uniform_buffers = 1, threadcount_x = TRACE_GROUP, threadcount_y = TRACE_GROUP, threadcount_z = 1,
		})
		tr.refit_pipeline = sdl.CreateGPUComputePipeline(r.device, {
			code_size = len(BLAS_REFIT_COMP_SPV), code = raw_data(BLAS_REFIT_COMP_SPV), entrypoint = "main",
			format = {.SPIRV}, num_readonly_storage_buffers = 4, num_readwrite_storage_buffers = 1,
			num_uniform_buffers = 1, threadcount_x = REFIT_THREADS, threadcount_y = 1, threadcount_z = 1,
		})
		tr.add_pipeline = create_fullscreen_pipeline(r, STUDIO_TRACE_ADD_FRAG_SPV, STUDIO_ACCUM_FORMAT, samplers = 2, additive = true)
		tr.transfer = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = TRACE_TRANSFER_SIZE})
		if tr.trace_pipeline == nil || tr.refit_pipeline == nil || tr.add_pipeline == nil || tr.transfer == nil {
			log.errorf("traced studio: setup failed (%s); the studio uses shadow maps", sdl.GetError())
			return false
		}
	}
	if tr.visible != nil && tr.width == vt.width && tr.height == vt.height do return true
	if tr.visible != nil do sdl.ReleaseGPUTexture(r.device, tr.visible)
	tr.visible = sdl.CreateGPUTexture(r.device, {
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
	mb, src := item.mesh, item.source
	if mb.trace == nil do mb.trace = new(Trace_Mesh)
	tm := mb.trace

	// The runs the trees cover: the item's chunks, split where one is too long for 16-bit
	// offsets, or fixed runs over the whole mesh for an item without chunks.
	ranges := make([dynamic]geom.Index_Range, context.temp_allocator)
	chunk_of := make([dynamic]u32, context.temp_allocator)
	if len(item.chunks) > 0 {
		for c, i in item.chunks {
			for at := u32(0); at < c.index_count; at += 3 * geom.CHUNK_BVH_MAX_TRIANGLES {
				append(&ranges, geom.Index_Range{c.first_index + at, min(c.index_count - at, 3 * geom.CHUNK_BVH_MAX_TRIANGLES)})
				append(&chunk_of, u32(i))
			}
		}
	} else {
		count := u32(len(src.indices))
		for at := u32(0); at < count; at += 3 * TRACE_RANGE_TRIANGLES {
			append(&ranges, geom.Index_Range{at, min(count - at, 3 * TRACE_RANGE_TRIANGLES)})
			append(&chunk_of, max(u32))
		}
	}

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
		sdl.PushGPUComputeUniformData(cmd, 0, &params, size_of(params))
		binding := sdl.GPUStorageBufferReadWriteBinding{buffer = tm.buffers[.Nodes]}
		pass := sdl.BeginGPUComputePass(cmd, nil, 0, &binding, 1)
		sdl.BindGPUComputePipeline(pass, tr.refit_pipeline)
		reads := [4]^sdl.GPUBuffer{mb.positions, mb.indices, tm.buffers[.Order], tm.buffers[.Chunks]}
		sdl.BindGPUComputeStorageBuffers(pass, 0, raw_data(reads[:]), len(reads))
		if groups > 0 do sdl.DispatchGPUCompute(pass, groups_x, groups_y, 1)
		sdl.EndGPUComputePass(pass)
		tm.refit_version = mb.version
	}

	// The tree over the shown chunks, from their boxes, wherever those moved or the
	// hidden ones changed.
	shown := make([dynamic]u32, context.temp_allocator)
	bounds := make([dynamic]geom.Aabb, context.temp_allocator)
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
			_ = sdl.WaitForGPUIdle(r.device)
			sdl.ReleaseGPUBuffer(r.device, tm.buffers[which])
		}
		capacity := u32(min(size + size / 4, TRACE_BUFFER_MAX))
		usage := sdl.GPUBufferUsageFlags{.COMPUTE_STORAGE_READ}
		if which == .Nodes do usage += {.COMPUTE_STORAGE_WRITE}
		tm.buffers[which] = sdl.CreateGPUBuffer(r.device, {usage = usage, size = capacity})
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
		dst := sdl.MapGPUTransferBuffer(r.device, tr.transfer, true)
		if dst == nil {
			log.errorf("traced studio: upload failed (%s)", sdl.GetError())
			return false
		}
		copy(([^]u8)(dst)[:len(part)], part)
		sdl.UnmapGPUTransferBuffer(r.device, tr.transfer)
		pass := sdl.BeginGPUCopyPass(cmd)
		sdl.UploadToGPUBuffer(pass, {transfer_buffer = tr.transfer}, {buffer = tm.buffers[which], offset = u32(offset), size = u32(len(part))}, false)
		sdl.EndGPUCopyPass(pass)
	}
	return true
}
