package render

import "../gpu"
import "core:log"
import "core:mem"
import "core:time"

import "../geom"

// Whole-mesh smoothing on the GPU, as a compute shader (shaders/smooth_all.comp.slang),
// which Smooth all takes where the GPU offers it. A run uploads what the shader
// reads, dispatches one pass a step, ping-ponging between two position buffers, and
// downloads the result, waiting for the GPU after each part so each one can be timed.
// The mesh the viewport draws is not touched: the caller writes the result back to the
// CPU mesh, which uploads its changes the usual way.

SMOOTH_ALL_COMP_CODE :: #load("shaders/smooth_all.comp" + SHADER_EXT, string)

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
	pipeline:      gpu.Compute_Pipeline,
	buffers:       [Smooth_Buffer]gpu.Buffer,
	capacity:      [Smooth_Buffer]u32, // bytes each buffer holds
	upload:        gpu.Transfer_Buffer,
	upload_size:   u32,
	download:      gpu.Transfer_Buffer,
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
	sc.pipeline = gpu.create_compute_pipeline_exact({
		code                          = SMOOTH_ALL_COMP_CODE,
		entrypoint                    = SHADER_ENTRY,
		format                        = SHADER_FORMAT,
		num_readonly_storage_buffers  = 5,
		num_readwrite_storage_buffers = 1,
		num_uniform_buffers           = 1,
		threadcount_x                 = SMOOTH_THREADS,
		threadcount_y                 = 1,
		threadcount_z                 = 1,
	})
	if sc.pipeline == 0 {
		log.errorf("smooth compute: CreateGPUComputePipeline failed: %s", gpu.last_error())
		return false
	}
	return true
}

// Waits for the GPU, then releases every buffer and the pipeline.
smooth_compute_destroy :: proc(r: ^Renderer, sc: ^Smooth_Compute) {
	if !r.has_device do return
	_ = gpu.wait_for_idle()
	for b in sc.buffers do if b != 0 do gpu.release_buffer(b)
	if sc.upload != 0 do gpu.release_transfer_buffer(sc.upload)
	if sc.download != 0 do gpu.release_transfer_buffer(sc.download)
	if sc.pipeline != 0 do gpu.release_compute_pipeline(sc.pipeline)
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
	if sc.pipeline == 0 || steps < 1 || len(positions) == 0 do return
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
		if sc.buffers[kind] != 0 {
			_ = gpu.wait_for_idle()
			gpu.release_buffer(sc.buffers[kind])
		}
		usage := gpu.Buffer_Usages{.Storage_Read}
		if kind >= .Pos_A do usage += {.Storage_Write}
		sc.buffers[kind] = gpu.create_buffer({usage = usage, size = u32(sizes[kind])})
		sc.capacity[kind] = u32(sizes[kind]) if sc.buffers[kind] != 0 else 0
		if sc.buffers[kind] == 0 {
			log.errorf("smooth compute: CreateGPUBuffer of %d MB failed: %s", sizes[kind] >> 20, gpu.last_error())
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
	if !transfer_reserve(r, &sc.upload, &sc.upload_size, total, .Upload) do return
	mapped := cast([^]u8)gpu.map_transfer_buffer(sc.upload, false)
	if mapped == nil {
		log.errorf("smooth compute: MapGPUTransferBuffer failed: %s", gpu.last_error())
		return
	}
	cmd := gpu.acquire_command_buffer()
	if cmd == nil {
		gpu.unmap_transfer_buffer(sc.upload)
		log.errorf("smooth compute: AcquireGPUCommandBuffer failed: %s", gpu.last_error())
		return
	}
	copy_pass := gpu.begin_copy_pass(cmd)
	at := 0
	for kind in Smooth_Buffer {
		src := sources[kind]
		if len(src) == 0 || (kind <= .Tris && !timing.topology) do continue
		mem.copy_non_overlapping(mapped[at:], raw_data(src), len(src))
		gpu.upload_to_buffer(copy_pass, {transfer_buffer = sc.upload, offset = u32(at)}, {buffer = sc.buffers[kind], size = u32(len(src))}, false)
		at += len(src)
	}
	gpu.unmap_transfer_buffer(sc.upload)
	gpu.end_copy_pass(copy_pass)
	if !submit_and_wait(r, cmd) do return
	timing.upload_mb = f64(total) / (1 << 20)
	timing.upload_ms = time.duration_milliseconds(time.tick_since(start))
	if timing.topology do sc.topology = topology_key

	start = time.tick_now()
	cmd = gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("smooth compute: AcquireGPUCommandBuffer failed: %s", gpu.last_error())
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
	gpu.push_compute_uniform_data(cmd, 0, &params, size_of(params))
	for step in 0 ..< steps {
		src, dst := Smooth_Buffer.Pos_A, Smooth_Buffer.Pos_B
		if step % 2 == 1 do src, dst = dst, src
		// One pass a step: the backends order separate passes, so each step sees the last one's writes.
		binding := gpu.Storage_Buffer_Binding{buffer = sc.buffers[dst]}
		pass := gpu.begin_compute_pass(cmd, nil, 0, &binding, 1)
		gpu.bind_compute_pipeline(pass, sc.pipeline)
		reads := [5]gpu.Buffer{sc.buffers[.Indices], sc.buffers[.Offsets], sc.buffers[.Tris], sc.buffers[.Weights], sc.buffers[src]}
		gpu.bind_compute_storage_buffers(pass, 0, raw_data(reads[:]), len(reads))
		gpu.dispatch_compute(pass, u32(groups_x), u32(groups_y), 1)
		gpu.end_compute_pass(pass)
	}
	if !submit_and_wait(r, cmd) do return
	timing.compute_ms = time.duration_milliseconds(time.tick_since(start))

	start = time.tick_now()
	result := Smooth_Buffer.Pos_B if steps % 2 == 1 else Smooth_Buffer.Pos_A
	bytes := len(sources[.Pos_A])
	if !transfer_reserve(r, &sc.download, &sc.download_size, bytes, .Download) do return
	cmd = gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("smooth compute: AcquireGPUCommandBuffer failed: %s", gpu.last_error())
		return
	}
	copy_pass = gpu.begin_copy_pass(cmd)
	gpu.download_from_buffer(copy_pass, {buffer = sc.buffers[result], size = u32(bytes)}, {transfer_buffer = sc.download})
	gpu.end_copy_pass(copy_pass)
	if !submit_and_wait(r, cmd) do return
	back := cast([^]u8)gpu.map_transfer_buffer(sc.download, false)
	if back == nil {
		log.errorf("smooth compute: MapGPUTransferBuffer failed: %s", gpu.last_error())
		return
	}
	mem.copy_non_overlapping(raw_data(positions), back, bytes)
	gpu.unmap_transfer_buffer(sc.download)
	timing.readback_ms = time.duration_milliseconds(time.tick_since(start))
	return timing, true
}

// Makes `tb` hold at least `size` bytes, replacing a smaller one.
@(private = "file")
transfer_reserve :: proc(r: ^Renderer, tb: ^gpu.Transfer_Buffer, capacity: ^u32, size: int, usage: gpu.Transfer_Usage) -> bool {
	if size <= int(capacity^) && tb^ != 0 do return true
	if tb^ != 0 {
		_ = gpu.wait_for_idle()
		gpu.release_transfer_buffer(tb^)
	}
	tb^ = gpu.create_transfer_buffer({usage = usage, size = u32(size)})
	capacity^ = u32(size) if tb^ != 0 else 0
	if tb^ == 0 {
		log.errorf("smooth compute: CreateGPUTransferBuffer of %d MB failed: %s", size >> 20, gpu.last_error())
		return false
	}
	return true
}

// Submits `cmd` and waits until the GPU has finished it.
@(private = "file")
submit_and_wait :: proc(r: ^Renderer, cmd: gpu.Cmd) -> bool {
	fence := gpu.submit_command_buffer_and_acquire_fence(cmd)
	if fence == nil {
		log.errorf("smooth compute: submit failed: %s", gpu.last_error())
		return false
	}
	defer gpu.release_fence(fence)
	if !gpu.wait_for_fences(true, &fence, 1) {
		log.errorf("smooth compute: WaitForGPUFences failed: %s", gpu.last_error())
		return false
	}
	return true
}
