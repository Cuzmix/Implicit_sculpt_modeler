package render

import "core:log"
import "core:mem"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"

// Whole-mesh smoothing on the GPU, as a compute shader (shaders/smooth_all.comp.slang): the
// trial of moving one heavy sculpt operation off the CPU. A run uploads what the shader
// reads, dispatches one pass a step, ping-ponging between two position buffers, and
// downloads the result, waiting for the GPU after each part so each one can be timed.
// The mesh the viewport draws is not touched: the caller writes the result back to the
// CPU mesh, which uploads its changes the usual way.

SMOOTH_ALL_COMP_CODE :: #load("shaders/smooth_all.comp" + SHADER_EXT)

// Threads per workgroup; matches local_size_x in smooth_all.comp.slang.
SMOOTH_THREADS :: 256

// The widest dispatch every device must accept; larger meshes spread over rows.
@(private = "file")
MAX_GROUPS_X :: 65535

// The read-only buffers, in the shader's binding order, then the two position buffers.
@(private = "file")
Smooth_Buffer :: enum {
	Indices,
	Offsets,
	Tris,
	Weights,
	Pos_A,
	Pos_B,
}

Smooth_Compute :: struct {
	pipeline:      ^sdl.GPUComputePipeline,
	buffers:       [Smooth_Buffer]^sdl.GPUBuffer,
	capacity:      [Smooth_Buffer]u32, // bytes each buffer holds
	upload:        ^sdl.GPUTransferBuffer,
	upload_size:   u32,
	download:      ^sdl.GPUTransferBuffer,
	download_size: u32,
	// Identifies the triangles and lookup the topology buffers hold (the caller's key),
	// 0 when they hold nothing to reuse.
	topology:      u64,
}

// What one run cost, part by part, each including its wait for the GPU.
Smooth_Timing :: struct {
	upload_ms:   f64, // filling the transfer buffer and copying it to the GPU
	compute_ms:  f64, // the dispatches
	readback_ms: f64, // copying the result back and into the CPU mesh
	upload_mb:   f64,
	topology:    bool, // the triangles and lookup were uploaded this run
}

smooth_timing_total :: proc(t: Smooth_Timing) -> f64 {
	return t.upload_ms + t.compute_ms + t.readback_ms
}

smooth_compute_init :: proc(r: ^Renderer, sc: ^Smooth_Compute) -> bool {
	// Exact (IEEE 754 arithmetic, no fast maths), so the result can equal the CPU's.
	sc.pipeline = gpu_create_compute_pipeline_exact(r.device, {
		code_size                     = len(SMOOTH_ALL_COMP_CODE),
		code                          = raw_data(SMOOTH_ALL_COMP_CODE),
		entrypoint                    = SHADER_ENTRY,
		format                        = SHADER_FORMAT,
		num_readonly_storage_buffers  = 5,
		num_readwrite_storage_buffers = 1,
		num_uniform_buffers           = 1,
		threadcount_x                 = SMOOTH_THREADS,
		threadcount_y                 = 1,
		threadcount_z                 = 1,
	})
	if sc.pipeline == nil {
		log.errorf("smooth compute: CreateGPUComputePipeline failed: %s", sdl.GetError())
		return false
	}
	return true
}

// Waits for the GPU, then releases every buffer and the pipeline.
smooth_compute_destroy :: proc(r: ^Renderer, sc: ^Smooth_Compute) {
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	for b in sc.buffers do if b != nil do gpu_release_buffer(r.device, b)
	if sc.upload != nil do gpu_release_transfer_buffer(r.device, sc.upload)
	if sc.download != nil do gpu_release_transfer_buffer(r.device, sc.download)
	if sc.pipeline != nil do gpu_release_compute_pipeline(r.device, sc.pipeline)
	sc^ = {}
}

// Smooths `positions` `steps` times on the GPU, in place: the step smooth_all_cpu takes,
// with each vertex's weight in `weights` and its triangles in `offsets`/`tris` (the CSR
// lookup of geom.Vertex_Faces) over `indices`. With a nonzero `topology_key` equal to
// the last run's, the triangles and lookup already on the GPU are reused, so only
// positions and weights travel; 0 always uploads them. Returns false, leaving
// `positions` as they were, when the GPU refuses something.
smooth_compute_run :: proc(
	r: ^Renderer,
	sc: ^Smooth_Compute,
	positions: []geom.Vec3,
	indices, offsets, tris: []u32,
	weights: []f32,
	steps: int,
	topology_key: u64,
) -> (
	timing: Smooth_Timing,
	ok: bool,
) {
	if sc.pipeline == nil || steps < 1 || len(positions) == 0 do return
	vcount := len(positions)
	assert(len(offsets) == vcount + 1 && len(weights) == vcount, "smooth compute: lookup and weights must cover every vertex")
	sizes := [Smooth_Buffer]int {
		.Indices = len(indices) * size_of(u32),
		.Offsets = len(offsets) * size_of(u32),
		.Tris    = len(tris) * size_of(u32),
		.Weights = vcount * size_of(f32),
		.Pos_A   = vcount * size_of(geom.Vec3),
		.Pos_B   = vcount * size_of(geom.Vec3),
	}
	sources := #partial [Smooth_Buffer][]u8 {
		.Indices = mem.slice_to_bytes(indices),
		.Offsets = mem.slice_to_bytes(offsets),
		.Tris    = mem.slice_to_bytes(tris),
		.Weights = mem.slice_to_bytes(weights),
		.Pos_A   = mem.slice_to_bytes(positions),
	}
	for size in sizes {
		if size > int(max(u32)) {
			log.errorf("smooth compute: %d bytes is past what a GPU buffer holds", size)
			return
		}
	}

	start := time.tick_now()
	timing.topology = topology_key == 0 || topology_key != sc.topology
	for kind in Smooth_Buffer {
		if u32(sizes[kind]) <= sc.capacity[kind] do continue
		if sc.buffers[kind] != nil {
			_ = gpu_wait_for_idle(r.device)
			gpu_release_buffer(r.device, sc.buffers[kind])
		}
		usage := sdl.GPUBufferUsageFlags{.COMPUTE_STORAGE_READ}
		if kind >= .Pos_A do usage += {.COMPUTE_STORAGE_WRITE}
		sc.buffers[kind] = gpu_create_buffer(r.device, {usage = usage, size = u32(sizes[kind])})
		sc.capacity[kind] = u32(sizes[kind]) if sc.buffers[kind] != nil else 0
		if sc.buffers[kind] == nil {
			log.errorf("smooth compute: CreateGPUBuffer of %d MB failed: %s", sizes[kind] >> 20, sdl.GetError())
			sc.topology = 0
			return
		}
		if kind <= .Tris do timing.topology = true
	}
	sc.topology = 0 // until the upload below lands

	// Every upload goes through one transfer buffer, kept between runs.
	total := 0
	for kind in Smooth_Buffer {
		if kind <= .Tris && !timing.topology do continue
		total += len(sources[kind])
	}
	if !transfer_reserve(r, &sc.upload, &sc.upload_size, total, .UPLOAD) do return
	mapped := cast([^]u8)gpu_map_transfer_buffer(r.device, sc.upload, false)
	if mapped == nil {
		log.errorf("smooth compute: MapGPUTransferBuffer failed: %s", sdl.GetError())
		return
	}
	cmd := gpu_acquire_command_buffer(r.device)
	if cmd == nil {
		gpu_unmap_transfer_buffer(r.device, sc.upload)
		log.errorf("smooth compute: AcquireGPUCommandBuffer failed: %s", sdl.GetError())
		return
	}
	copy_pass := gpu_begin_copy_pass(cmd)
	at := 0
	for kind in Smooth_Buffer {
		src := sources[kind]
		if len(src) == 0 || (kind <= .Tris && !timing.topology) do continue
		mem.copy_non_overlapping(mapped[at:], raw_data(src), len(src))
		gpu_upload_to_buffer(copy_pass, {transfer_buffer = sc.upload, offset = u32(at)}, {buffer = sc.buffers[kind], size = u32(len(src))}, false)
		at += len(src)
	}
	gpu_unmap_transfer_buffer(r.device, sc.upload)
	gpu_end_copy_pass(copy_pass)
	if !submit_and_wait(r, cmd) do return
	timing.upload_mb = f64(total) / (1 << 20)
	timing.upload_ms = time.duration_milliseconds(time.tick_since(start))
	if timing.topology do sc.topology = topology_key

	start = time.tick_now()
	cmd = gpu_acquire_command_buffer(r.device)
	if cmd == nil {
		log.errorf("smooth compute: AcquireGPUCommandBuffer failed: %s", sdl.GetError())
		return
	}
	groups := (vcount + SMOOTH_THREADS - 1) / SMOOTH_THREADS
	groups_x := min(groups, MAX_GROUPS_X)
	groups_y := (groups + groups_x - 1) / groups_x
	Params :: struct {
		vertex_count: u32,
		groups_x:     u32,
		_:            [2]u32, // std140 rounds a uniform block up to 16 bytes
	}
	params := Params{vertex_count = u32(vcount), groups_x = u32(groups_x)}
	gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
	for step in 0 ..< steps {
		src, dst := Smooth_Buffer.Pos_A, Smooth_Buffer.Pos_B
		if step % 2 == 1 do src, dst = dst, src
		// One pass a step: the backends order separate passes, so each step sees the last one's writes.
		binding := sdl.GPUStorageBufferReadWriteBinding{buffer = sc.buffers[dst]}
		pass := gpu_begin_compute_pass(cmd, nil, 0, &binding, 1)
		gpu_bind_compute_pipeline(pass, sc.pipeline)
		reads := [5]^sdl.GPUBuffer{sc.buffers[.Indices], sc.buffers[.Offsets], sc.buffers[.Tris], sc.buffers[.Weights], sc.buffers[src]}
		gpu_bind_compute_storage_buffers(pass, 0, raw_data(reads[:]), len(reads))
		gpu_dispatch_compute(pass, u32(groups_x), u32(groups_y), 1)
		gpu_end_compute_pass(pass)
	}
	if !submit_and_wait(r, cmd) do return
	timing.compute_ms = time.duration_milliseconds(time.tick_since(start))

	start = time.tick_now()
	result := Smooth_Buffer.Pos_B if steps % 2 == 1 else Smooth_Buffer.Pos_A
	bytes := len(sources[.Pos_A])
	if !transfer_reserve(r, &sc.download, &sc.download_size, bytes, .DOWNLOAD) do return
	cmd = gpu_acquire_command_buffer(r.device)
	if cmd == nil {
		log.errorf("smooth compute: AcquireGPUCommandBuffer failed: %s", sdl.GetError())
		return
	}
	copy_pass = gpu_begin_copy_pass(cmd)
	gpu_download_from_buffer(copy_pass, {buffer = sc.buffers[result], size = u32(bytes)}, {transfer_buffer = sc.download})
	gpu_end_copy_pass(copy_pass)
	if !submit_and_wait(r, cmd) do return
	back := cast([^]u8)gpu_map_transfer_buffer(r.device, sc.download, false)
	if back == nil {
		log.errorf("smooth compute: MapGPUTransferBuffer failed: %s", sdl.GetError())
		return
	}
	mem.copy_non_overlapping(raw_data(positions), back, bytes)
	gpu_unmap_transfer_buffer(r.device, sc.download)
	timing.readback_ms = time.duration_milliseconds(time.tick_since(start))
	return timing, true
}

// Makes `tb` hold at least `size` bytes, replacing a smaller one.
@(private = "file")
transfer_reserve :: proc(r: ^Renderer, tb: ^^sdl.GPUTransferBuffer, capacity: ^u32, size: int, usage: sdl.GPUTransferBufferUsage) -> bool {
	if size <= int(capacity^) && tb^ != nil do return true
	if tb^ != nil {
		_ = gpu_wait_for_idle(r.device)
		gpu_release_transfer_buffer(r.device, tb^)
	}
	tb^ = gpu_create_transfer_buffer(r.device, {usage = usage, size = u32(size)})
	capacity^ = u32(size) if tb^ != nil else 0
	if tb^ == nil {
		log.errorf("smooth compute: CreateGPUTransferBuffer of %d MB failed: %s", size >> 20, sdl.GetError())
		return false
	}
	return true
}

// Submits `cmd` and waits until the GPU has finished it.
@(private = "file")
submit_and_wait :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer) -> bool {
	fence := gpu_submit_command_buffer_and_acquire_fence(cmd)
	if fence == nil {
		log.errorf("smooth compute: submit failed: %s", sdl.GetError())
		return false
	}
	defer gpu_release_fence(r.device, fence)
	if !gpu_wait_for_fences(r.device, true, &fence, 1) {
		log.errorf("smooth compute: WaitForGPUFences failed: %s", sdl.GetError())
		return false
	}
	return true
}
