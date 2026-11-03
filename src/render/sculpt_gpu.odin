package render

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:time"

import sdl "vendor:sdl3"

import "../geom"
import "../jobs"

// Sculpting on the GPU (README "Sculpt on the GPU"), its first stage: the vertex normals
// of a stroke. While a stroke runs with Sculpt on the GPU, the CPU still lays the dabs and
// uploads the positions they moved (12 bytes a vertex, no normals), and a kernel
// (shaders/node_normals.comp.slang) recomputes the normals of the vertex ranges the
// sculptor's flush reported, straight into the mesh's normal buffer, where the vertex
// shader reads them. The CPU's copy of those normals is brought up to date by a readback:
// the frame copies the ranges' packed normals into a slot of a ring of download buffers,
// the frame's command buffer is submitted with a fence, and a later frame (two on, as a
// rule) finds the fence signalled, decodes them and writes them into the mesh, so the dabs
// of a stroke read normals a frame or two older than the CPU path's. A sync waits for the
// readbacks of one mesh and applies them: the sculptor asks for it before it recomputes
// normals on the CPU and before a new stroke, so between strokes the CPU's normals are the
// GPU's, within the twelve bits the packing keeps.
//
// The kernel needs the mesh's vertex -> triangle lookup (geom.Vertex_Faces) beside the
// positions and indices it reads: 28 bytes a vertex, uploaded once per mesh on the first
// stroke that takes the GPU and kept with the mesh's buffers.

NODE_NORMALS_COMP_CODE :: #load("shaders/node_normals.comp" + SHADER_EXT, string)

// Vertices a workgroup takes; matches numthreads in node_normals.comp.slang.
SCULPT_SLAB :: 256
// More slots than frames may be in flight, so a slot's readback is done when it comes round.
SCULPT_SLOTS :: FRAMES_IN_FLIGHT_MAX + 1

// The widest dispatch every device must accept; more slabs spread over rows.
@(private = "file")
MAX_SLAB_GROUPS_X :: 65535

// What a Mesh_Buffers keeps for sculpting on the GPU.
Mesh_Sculpt :: struct {
	offsets, tris: ^sdl.GPUBuffer, // the vertex -> triangle lookup, as geom.Vertex_Faces holds it
	// Mesh_Buffers.index_version the lookup was uploaded for, so another set of triangles
	// (a regrown or remade mesh) uploads it again; 0 for none.
	lookup_version: u64,
	lookup_bytes:   int,
	// The device refused the lookup's buffers, or the kernel failed: this mesh's strokes
	// stay on the CPU.
	failed:  bool,
	// The vertex ranges whose normals this frame's dispatch recomputes and reads back, where
	// the read-back normals go, and whether they end the stroke.
	queued:  [dynamic]geom.Vertex_Range,
	normals: []geom.Vec3,
	last:    bool,
}

// One mesh's readback waiting in a slot: its ranges, where their normals go, and where in
// the slot's download buffer they start.
@(private = "file")
Sculpt_Entry :: struct {
	mesh:    ^Mesh_Buffers,
	normals: []geom.Vec3,
	ranges:  []geom.Vertex_Range,
	offset:  u32,
	bytes:   u32,
}

@(private = "file")
Sculpt_Slot :: struct {
	download:      ^sdl.GPUTransferBuffer,
	download_size: u32,
	fence:         ^sdl.GPUFence, // the frame that recorded the entries; nil once applied
	entries:       [dynamic]Sculpt_Entry,
	bytes:         u32, // of the download buffer used this frame
}

// What a run of sculpting on the GPU counts, for the exit stats and the Stats panel.
Sculpt_Gpu_Stats :: struct {
	strokes_gpu, strokes_cpu: int, // strokes whose normals the GPU took, and the rest
	dispatches: int, // frames that ran the kernel
	// The last frame's readbacks applied: packed normals read and the time to decode them.
	applied_kb: f64,
	apply_ms:   f64,
	applied:    bool, // the last frame applied some
}

Sculpt_Gpu :: struct {
	pipeline: ^sdl.GPUComputePipeline,
	failed:   bool, // the kernel could not be made: every stroke stays on the CPU
	// --gpu-sculpt-sync: a frame's readbacks are waited for and applied before the next
	// frame's dabs, so the CPU reads the normals the CPU path would have (for A/B of the
	// arithmetic alone).
	sync:     bool,
	slabs:            ^sdl.GPUBuffer,
	slabs_capacity:   u32, // bytes
	transfer:         ^sdl.GPUTransferBuffer, // the slabs on their way up
	transfer_size:    u32,
	slots:    [SCULPT_SLOTS]Sculpt_Slot,
	slot:     int,  // the slot this frame records into
	recorded: bool, // this frame's command buffer holds readbacks: submit it fenced (sculpt_gpu_submitted)
	stats:    Sculpt_Gpu_Stats,
}

// Whether the backend sculpts on the GPU at all: the own Vulkan backend, where the kernel
// and its readback are verified; Metal waits for its own run on a device.
sculpt_gpu_offered :: proc() -> bool {
	when VULKAN do return true
	else do return false
}

// Starts a frame: applies every readback whose fence has signalled (all of them, waiting,
// in sync mode) and frees the slot this frame will record into. Call once a frame before
// anything is recorded.
sculpt_gpu_frame :: proc(r: ^Renderer) {
	sg := &r.sculpt_gpu
	sg.stats.applied_kb, sg.stats.apply_ms, sg.stats.applied = 0, 0, false
	for &s, i in sg.slots {
		if s.fence != nil && (sg.sync || i == sg.slot || gpu_query_fence(r.device, s.fence)) do sculpt_slot_apply(r, &s)
		// Entries with no fence were recorded by a frame that was never submitted: they
		// hold nothing to read.
		if s.fence == nil && i == sg.slot do sculpt_slot_drop(&s)
	}
}

// Whether the GPU takes the normals of a stroke on `mb` (vertex count `vertex_count`,
// triangles as `mb` holds them, lookup `faces`): makes the kernel and the mesh's lookup
// buffers on first use, and false (logged, and not asked again for that mesh) where the
// device refuses them.
sculpt_gpu_begin :: proc(r: ^Renderer, mb: ^Mesh_Buffers, faces: geom.Vertex_Faces) -> bool {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	if !r.caps.gpu_sculpt || sg.failed || ms.failed || !mb.storage do return false
	if sg.pipeline == nil {
		// Exact (IEEE 754 arithmetic, no fast maths), so the result can equal the CPU's.
		sg.pipeline = gpu_create_compute_pipeline_exact(r.device, {
			code_size                     = len(NODE_NORMALS_COMP_CODE),
			code                          = raw_data(NODE_NORMALS_COMP_CODE),
			entrypoint                    = SHADER_ENTRY,
			format                        = SHADER_FORMAT,
			num_readonly_storage_buffers  = 5,
			num_readwrite_storage_buffers = 1,
			num_uniform_buffers           = 1,
			threadcount_x                 = SCULPT_SLAB,
			threadcount_y                 = 1,
			threadcount_z                 = 1,
		})
		if sg.pipeline == nil {
			log.errorf("sculpt on the GPU: the normals kernel could not be made (%s); strokes stay on the CPU", sdl.GetError())
			sg.failed = true
			return false
		}
	}
	if ms.offsets != nil && ms.lookup_version == mb.index_version do return true
	if u32(len(faces.offsets)) != mb.vertex_capacity + 1 || u32(len(faces.tris)) != mb.index_count {
		// The lookup is another mesh's than the buffers hold: never dereference it on the GPU.
		return false
	}
	sculpt_lookup_release(r, mb)
	obytes, tbytes := u32(len(faces.offsets)) * size_of(u32), u32(len(faces.tris)) * size_of(u32)
	start := time.tick_now()
	info := sdl.GPUBufferCreateInfo{usage = {.COMPUTE_STORAGE_READ}, size = obytes}
	omap, tmap: rawptr
	if r.caps.shared_buffers {
		ms.offsets, omap = gpu_create_buffer_mapped(r.device, info)
		info.size = tbytes
		ms.tris, tmap = gpu_create_buffer_mapped(r.device, info)
	}
	if ms.offsets == nil do ms.offsets = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = obytes})
	if ms.tris == nil do ms.tris = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = tbytes})
	if ms.offsets == nil || ms.tris == nil {
		log.errorf("sculpt on the GPU: the lookup's %d MB were refused (%s); this mesh's strokes stay on the CPU", (obytes + tbytes) >> 20, sdl.GetError())
		sculpt_lookup_release(r, mb)
		ms.failed = true
		return false
	}
	gpu_set_buffer_name(r.device, ms.offsets, "sculpt lookup offsets")
	gpu_set_buffer_name(r.device, ms.tris, "sculpt lookup triangles")
	ok := true
	if omap != nil {
		copy(([^]u8)(omap)[:obytes], slice.to_bytes(faces.offsets))
		gpu_buffer_filled(r.device, ms.offsets)
	} else {
		ok = upload_blocking(r, mb, ms.offsets, slice.to_bytes(faces.offsets))
	}
	if tmap != nil {
		copy(([^]u8)(tmap)[:tbytes], slice.to_bytes(faces.tris))
		gpu_buffer_filled(r.device, ms.tris)
	} else {
		ok = ok && upload_blocking(r, mb, ms.tris, slice.to_bytes(faces.tris))
	}
	if !ok {
		log.errorf("sculpt on the GPU: the lookup's upload failed (%s); this mesh's strokes stay on the CPU", sdl.GetError())
		sculpt_lookup_release(r, mb)
		ms.failed = true
		return false
	}
	ms.lookup_version, ms.lookup_bytes = mb.index_version, int(obytes + tbytes)
	log.infof("sculpt on the GPU: %d MB lookup uploaded in %.0f ms", (obytes + tbytes) >> 20, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Queues `ranges` of `mb` (whose CPU normals are `normals`) for this frame's dispatch, the
// last of a stroke with `last`. The ranges are copied; the kernel and readback are recorded
// by sculpt_gpu_dispatch once the frame has uploaded the positions.
sculpt_gpu_queue :: proc(mb: ^Mesh_Buffers, ranges: []geom.Vertex_Range, normals: []geom.Vec3, last: bool) {
	ms := &mb.sculpt
	append(&ms.queued, ..ranges)
	ms.normals = normals
	ms.last = ms.last || last
}

// Whether a dispatch is queued for the mesh this frame, so its positions upload without
// normals.
sculpt_gpu_queued :: proc(mb: ^Mesh_Buffers) -> bool {
	return len(mb.sculpt.queued) > 0
}

// Records the queued ranges' normals kernel and their readback into `cmd`, after the frame
// uploaded the positions. False, with the queue dropped, where the device refused a
// buffer: neither copy of those ranges' normals is current then, so the caller has the CPU
// recompute and upload them (sculpt.sculptor_normals_stale).
sculpt_gpu_dispatch :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers) -> bool {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	if len(ms.queued) == 0 do return true
	defer {
		clear(&ms.queued)
		ms.last = false
	}
	if sg.pipeline == nil || ms.offsets == nil || ms.failed do return false

	// The slabs: each range cut into workgroups' worth.
	Slab :: [2]u32
	slabs := make([dynamic]Slab, 0, 256, context.temp_allocator)
	verts: u32
	for rg in ms.queued {
		verts += rg.count
		for first := rg.first; first < rg.first + rg.count; first += SCULPT_SLAB {
			append(&slabs, Slab{first, min(SCULPT_SLAB, rg.first + rg.count - first)})
		}
	}
	bytes := u32(len(slabs) * size_of(Slab))
	if sg.transfer == nil || sg.transfer_size < bytes {
		if sg.transfer != nil do gpu_release_transfer_buffer(r.device, sg.transfer)
		sg.transfer_size = bytes + bytes / 4
		sg.transfer = gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = sg.transfer_size})
		if sg.transfer == nil {
			sg.transfer_size = 0
			return sculpt_refused(sg, fmt.tprintf("an upload buffer of %d KB", bytes >> 10))
		}
	}
	if sg.slabs == nil || sg.slabs_capacity < bytes {
		// A dispatch of the last frame may still read the old one: it is released once the
		// GPU is idle, which the frame never waits for, so it goes with the next regrow or
		// the renderer.
		if sg.slabs != nil {
			_ = gpu_wait_for_idle(r.device)
			gpu_release_buffer(r.device, sg.slabs)
		}
		sg.slabs_capacity = bytes + bytes / 4
		sg.slabs = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = sg.slabs_capacity})
		if sg.slabs == nil {
			sg.slabs_capacity = 0
			return sculpt_refused(sg, fmt.tprintf("a slab buffer of %d KB", bytes >> 10))
		}
	}
	dst := gpu_map_transfer_buffer(r.device, sg.transfer, true)
	if dst == nil do return sculpt_refused(sg, "mapping the slabs")
	copy(([^]u8)(dst)[:bytes], slice.to_bytes(slabs[:]))
	gpu_unmap_transfer_buffer(r.device, sg.transfer)

	// The readback's place in this frame's slot, sized for it before anything is recorded.
	s := &sg.slots[sg.slot]
	rbytes := verts * size_of(Normal_Packed)
	if s.download == nil || s.download_size < s.bytes + rbytes {
		if s.download != nil do gpu_release_transfer_buffer(r.device, s.download)
		s.download_size = s.bytes + rbytes + (s.bytes + rbytes) / 4
		s.download = gpu_create_transfer_buffer(r.device, {usage = .DOWNLOAD, size = s.download_size})
		if s.download == nil {
			s.download_size = 0
			return sculpt_refused(sg, fmt.tprintf("a readback buffer of %d KB", (s.bytes + rbytes) >> 10))
		}
		if s.bytes > 0 {
			// An earlier mesh's readback this frame lived in the old buffer: its copies are
			// already recorded there, so it is applied from the fence's wait instead.
			log.warnf("sculpt on the GPU: a frame's readbacks outgrew their buffer; the frame's earlier ones are lost")
			clear(&s.entries)
			s.bytes = 0
		}
	}

	debug_group(cmd, "GPU normals", .Sculpt)
	// The slabs go up cycled: the last frame's dispatch may still read the buffer.
	pass := gpu_begin_copy_pass(cmd)
	gpu_upload_to_buffer(pass, {transfer_buffer = sg.transfer}, {buffer = sg.slabs, size = bytes}, true)
	gpu_end_copy_pass(pass)
	Params :: struct {
		slab_count: u32,
		groups_x:   u32,
		_:          [2]u32, // std140 rounds a uniform block up to 16 bytes
	}
	groups_x := min(len(slabs), MAX_SLAB_GROUPS_X)
	groups_y := (len(slabs) + groups_x - 1) / groups_x
	params := Params{slab_count = u32(len(slabs)), groups_x = u32(groups_x)}
	write := sdl.GPUStorageBufferReadWriteBinding{buffer = mb.normals}
	compute := gpu_begin_compute_pass(cmd, nil, 0, &write, 1)
	gpu_bind_compute_pipeline(compute, sg.pipeline)
	reads := [5]^sdl.GPUBuffer{mb.indices, ms.offsets, ms.tris, mb.positions, sg.slabs}
	gpu_bind_compute_storage_buffers(compute, 0, &reads[0], len(reads))
	gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
	gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
	gpu_end_compute_pass(compute)
	// The vertex shader reads the normals the kernel wrote, so the mesh is drawn afresh.
	r.last_version += 1
	mb.version = r.last_version

	entry := Sculpt_Entry{mesh = mb, normals = ms.normals, ranges = slice.clone(ms.queued[:]), offset = s.bytes, bytes = rbytes}
	pass = gpu_begin_copy_pass(cmd)
	at := s.bytes
	for rg in entry.ranges {
		size := rg.count * size_of(Normal_Packed)
		gpu_download_from_buffer(pass, {buffer = mb.normals, offset = rg.first * size_of(Normal_Packed), size = size}, {transfer_buffer = s.download, offset = at})
		at += size
	}
	gpu_end_copy_pass(pass)
	s.bytes = at
	append(&s.entries, entry)
	sg.recorded = true
	sg.stats.dispatches += 1
	return true
}

// Logs a refusal and gives every stroke from now on to the CPU.
@(private = "file")
sculpt_refused :: proc(sg: ^Sculpt_Gpu, what: string) -> bool {
	log.errorf("sculpt on the GPU: %s was refused (%s); strokes stay on the CPU", what, sdl.GetError())
	sg.failed = true
	return false
}

// Takes the fence of the frame's command buffer, once submitted, for the readbacks it
// recorded; nil says the GPU has already finished it (a frame that waited for it), and the
// readbacks apply now. Call once a frame after the submit, when sculpt_gpu_recorded.
sculpt_gpu_submitted :: proc(r: ^Renderer, fence: ^sdl.GPUFence) {
	sg := &r.sculpt_gpu
	s := &sg.slots[sg.slot]
	sg.recorded = false
	if len(s.entries) == 0 {
		if fence != nil do gpu_release_fence(r.device, fence)
		return
	}
	s.fence = fence
	if fence == nil do sculpt_slot_apply(r, s, waited = true)
	sg.slot = (sg.slot + 1) % SCULPT_SLOTS
}

// Whether this frame's command buffer holds readbacks, which the frame then submits with a
// fence for sculpt_gpu_submitted.
sculpt_gpu_recorded :: proc(r: ^Renderer) -> bool {
	return r.sculpt_gpu.recorded
}

// Waits for every readback of `mb` still under way and writes its normals into the mesh,
// so the CPU's normals are the GPU's.
sculpt_gpu_sync :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	sg := &r.sculpt_gpu
	for &s in sg.slots {
		// A slot with entries and no fence is this frame's, not yet submitted: nothing to
		// wait for, and the next frame applies it.
		if s.fence == nil do continue
		for e in s.entries do if e.mesh == mb {
			sculpt_slot_apply(r, &s)
			break
		}
	}
}

// Drops everything a mesh's buffers hold for sculpting on the GPU, readbacks under way
// included (their CPU mesh may be going with them). The caller has waited for the GPU, as
// mesh_buffers_destroy has.
@(private)
sculpt_gpu_forget :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	sg := &r.sculpt_gpu
	for &s in sg.slots {
		for i := len(s.entries) - 1; i >= 0; i -= 1 {
			if s.entries[i].mesh != mb do continue
			delete(s.entries[i].ranges)
			unordered_remove(&s.entries, i)
		}
	}
	sculpt_lookup_release(r, mb)
	delete(mb.sculpt.queued)
	mb.sculpt = {}
}

@(private = "file")
sculpt_lookup_release :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	ms := &mb.sculpt
	if ms.offsets != nil do gpu_release_buffer(r.device, ms.offsets)
	if ms.tris != nil do gpu_release_buffer(r.device, ms.tris)
	ms.offsets, ms.tris, ms.lookup_version, ms.lookup_bytes = nil, nil, 0, 0
}

// Waits for the GPU, then releases the ring, the slabs and the kernel.
sculpt_gpu_destroy :: proc(r: ^Renderer) {
	sg := &r.sculpt_gpu
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	for &s in sg.slots {
		if s.fence != nil do gpu_release_fence(r.device, s.fence)
		if s.download != nil do gpu_release_transfer_buffer(r.device, s.download)
		for e in s.entries do delete(e.ranges)
		delete(s.entries)
	}
	if sg.slabs != nil do gpu_release_buffer(r.device, sg.slabs)
	if sg.transfer != nil do gpu_release_transfer_buffer(r.device, sg.transfer)
	if sg.pipeline != nil do gpu_release_compute_pipeline(r.device, sg.pipeline)
	stats := sg.stats
	sg^ = {}
	sg.stats = stats
}

// Waits for a slot's frame (or takes the caller's word, `waited`, that it is done),
// decodes every entry's packed normals into its mesh and frees the slot.
@(private = "file")
sculpt_slot_apply :: proc(r: ^Renderer, s: ^Sculpt_Slot, waited := false) {
	sg := &r.sculpt_gpu
	if s.fence != nil {
		_ = gpu_wait_for_fences(r.device, true, &s.fence, 1)
		gpu_release_fence(r.device, s.fence)
		s.fence = nil
	} else if !waited {
		sculpt_slot_drop(s)
		return
	}
	defer sculpt_slot_drop(s)
	if len(s.entries) == 0 do return
	start := time.tick_now()
	src := ([^]Normal_Packed)(gpu_map_transfer_buffer(r.device, s.download, false))
	if src == nil {
		log.errorf("sculpt on the GPU: mapping a readback failed (%s)", sdl.GetError())
		return
	}
	for e in s.entries {
		Decode :: struct {
			src:     [^]Normal_Packed,
			normals: []geom.Vec3,
			ranges:  []geom.Vertex_Range,
			starts:  []u32, // each range's first packed normal in src
		}
		job := Decode{src = src[e.offset / size_of(Normal_Packed):], normals = e.normals, ranges = e.ranges}
		job.starts = make([]u32, len(e.ranges), context.temp_allocator)
		at: u32
		for rg, i in e.ranges {
			job.starts[i] = at
			at += rg.count
		}
		jobs.parallel_for(r.pool, len(e.ranges), &job, proc(data: rawptr, i: int) {
			job := cast(^Decode)data
			rg := job.ranges[i]
			packed := job.src[job.starts[i]:][:rg.count]
			for p, k in packed do job.normals[rg.first + u32(k)] = unpack_normal(p)
		})
		sg.stats.applied_kb += f64(e.bytes) / 1024
	}
	gpu_unmap_transfer_buffer(r.device, s.download)
	sg.stats.apply_ms += time.duration_milliseconds(time.tick_since(start))
	sg.stats.applied = true
}

// Frees a slot's entries without reading them.
@(private = "file")
sculpt_slot_drop :: proc(s: ^Sculpt_Slot) {
	for e in s.entries do delete(e.ranges)
	clear(&s.entries)
	s.bytes = 0
}

// The normal a packed value holds, without its mask nibbles: geom.oct_decode of its top
// twelve bits, as the vertex shader reads it.
unpack_normal :: proc(e: Normal_Packed) -> geom.Vec3 {
	p := [2]f32{max(f32(e.x &~ 15) / 32767, -1), max(f32(e.y &~ 15) / 32767, -1)}
	v := geom.Vec3{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
	if v.z < 0 {
		sx: f32 = 1 if v.x >= 0 else -1
		sy: f32 = 1 if v.y >= 0 else -1
		v.x, v.y = (1 - abs(p.y)) * sx, (1 - abs(p.x)) * sy
	}
	return linalg.normalize0(v)
}
