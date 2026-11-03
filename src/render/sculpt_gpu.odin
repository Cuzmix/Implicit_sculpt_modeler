package render

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:time"

import sdl "vendor:sdl3"

import "../geom"
import "../jobs"

// Sculpting on the GPU (README "Sculpt on the GPU"): a stroke's dabs and vertex normals
// on compute kernels. While a stroke runs with Sculpt on the GPU, the sculptor records
// each dab instead of moving its vertices (sculpt/stroke_gpu.odin), and the frame runs
// the records in order through the dab kernels (shaders/dab_*.comp.slang: the area under
// the brush, its reduction, the move; Smooth's targets and step), each over the slabs of
// its hit nodes' vertex ranges, straight in the mesh's position buffer; then a kernel
// (shaders/node_normals.comp.slang) recomputes the normals of the vertex ranges the
// sculptor's flush reported, in the mesh's normal buffer, where the vertex shader reads
// them. A stroke the GPU takes for its normals alone keeps the CPU's dabs, whose positions
// the frame uploads (12 bytes a vertex, no normals).
//
// The CPU's copy of the mesh is brought up to date by a readback: the frame copies the
// ranges' positions and packed normals into a slot of a ring of download buffers, the
// frame's command buffer is submitted with a fence, and a later frame (two on, as a rule)
// finds the fence signalled, copies and decodes them into the mesh, so the CPU's mesh is a
// mirror a frame or two behind the GPU's while a stroke runs. The slots are applied in the
// order they were submitted, so an older readback never lands over a newer one. A sync
// waits for the readbacks of one mesh and applies them: the sculptor asks for it before
// anything reads or writes the positions or normals outside the dab path, so between
// strokes the CPU's mesh is the GPU's, within the twelve bits the packing keeps.
//
// The kernels need the mesh's vertex -> triangle lookup (geom.Vertex_Faces) beside the
// positions and indices they read: 28 bytes a vertex, uploaded once per mesh on the first
// stroke that takes the GPU and kept with the mesh's buffers.

NODE_NORMALS_COMP_CODE :: #load("shaders/node_normals.comp" + SHADER_EXT, string)
DAB_AREA_COMP_CODE :: #load("shaders/dab_area.comp" + SHADER_EXT, string)
DAB_REDUCE_COMP_CODE :: #load("shaders/dab_reduce.comp" + SHADER_EXT, string)
DAB_MOVE_COMP_CODE :: #load("shaders/dab_move.comp" + SHADER_EXT, string)
DAB_SMOOTH_TARGETS_COMP_CODE :: #load("shaders/dab_smooth_targets.comp" + SHADER_EXT, string)
DAB_SMOOTH_APPLY_COMP_CODE :: #load("shaders/dab_smooth_apply.comp" + SHADER_EXT, string)
NODE_BOUNDS_COMP_CODE :: #load("shaders/node_bounds.comp" + SHADER_EXT, string)

// Vertices a workgroup takes; matches numthreads in the kernels.
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
	// The device refused the lookup's buffers, or a kernel failed: this mesh's strokes
	// stay on the CPU.
	failed:  bool,
	// The dabs this frame's dispatch runs, in order, their ranges in `dab_ranges`.
	dabs:       [dynamic]Sculpt_Dab,
	dab_ranges: [dynamic]geom.Vertex_Range,
	// The vertex ranges whose normals this frame's dispatch recomputes and reads back, where
	// the read-back normals go, and whether they end the stroke; and where the read-back
	// positions go, nil when the dabs ran on the CPU (nothing to read back of them), and
	// the stroke heights too, nil when no dab of the stroke keeps them.
	queued:    [dynamic]geom.Vertex_Range,
	// The ranges whose normals the frame reads back as the kernels left them, with
	// nothing recomputed (sculpt_gpu_queue_back), and where they go.
	back:         [dynamic]geom.Vertex_Range,
	back_normals: []geom.Vec3,
	normals:   []geom.Vec3,
	positions: []geom.Vec3,
	heights:   []Sculpt_Height,
	last:      bool,
	// A vertex's stroke height for the kernels (dab.slang `heights`), 8 bytes a vertex of
	// the mesh's capacity, made at the first dab that keeps them; its contents outlive a
	// stroke as the sculptor's do, told apart by the stroke number.
	heights_buffer:   ^sdl.GPUBuffer,
	heights_capacity: u32,
	// Every node's shared vertices (sculpt.sculptor_gpu_shared), uploaded with the lookup,
	// for the bounds kernel; and the nodes of the queued ranges whose bounds the frame
	// finds and reads back with their positions.
	shared:       ^sdl.GPUBuffer,
	queued_nodes: [dynamic]Sculpt_Node,
}

// A node for the bounds kernel (node_bounds.comp.slang; sculpt.Gpu_Node, the same bytes).
Sculpt_Node :: struct {
	vert_first, vert_count, shared_first, shared_count: u32,
}

// A vertex's stroke height as the kernels keep it and the sculptor reads it back
// (sculpt.Layer_Height, the same bytes): the stroke's number and how far it raised the
// vertex, which Draw and Inflate with Accumulate off cap their moves by.
Sculpt_Height :: struct {
	stroke: u32,
	height: f32,
}

// A dab for the kernels, in the sculptor's terms (sculpt.Gpu_Dab, which the app
// translates): the layout the kernels read is Sculpt_Dab_Record.
Sculpt_Dab :: struct {
	kind:         Sculpt_Dab_Kind,
	center:       geom.Vec3,
	r2:           f32, // the squared reach
	inv_r2:       f32, // 1 / radius²
	inv_sample2:  f32, // 1 / (the sample radius)²
	amount:       f32, // signed, the kind's own meaning
	strength:     f32,
	radius:       f32,
	plane_offset: f32, // Clay: its plane's height along the normal, signed
	tilt:         matrix[3, 3]f32, // turns the area normal; the zero matrix leaves it
	view:         geom.Vec3, // Projected: the view direction over the radius, zero for Sphere
	facing:       geom.Vec3, // front faces only: the way toward the viewer, zero for off
	plane_short:  [2]f32, // Flatten's reach short of a radius above and below its plane
	rates:        [8]f32, // Smooth: each pass's share of the step toward the neighbours
	passes:       int,
	relax:        bool, // Smooth: only across the surface
	valleys:      bool, // Smooth: only vertices below their neighbours' mean
	peaks:        bool, // Smooth: only vertices above it
	once:         bool, // Draw, Inflate: Accumulate off, the stroke's heights cap the move
	stroke:       u32,  // the stroke's number for the heights
	// The hit nodes' owned vertex ranges, coalesced and sorted: what the kernels work on.
	ranges:       []geom.Vertex_Range,
}

// The kinds the dab kernels lay, numbered as dab.slang's DAB_* constants.
Sculpt_Dab_Kind :: enum u32 {
	Draw,
	Inflate,
	Clay,
	Flatten,
	Pinch,
	Crease,
	Smooth,
}

// A dab as dab.slang reads it: eight float4s.
@(private = "file")
Sculpt_Dab_Record :: struct {
	center_r2:     [4]f32,
	view_inv_r2:   [4]f32,
	facing_amount: [4]f32,
	tilt0:         [4]f32, // .w the strength
	tilt1:         [4]f32, // .w 1 / (the sample radius)²
	tilt2:         [4]f32, // .w Clay's plane offset
	misc:          [4]f32, // plane_short above and below, the radius, 0
	slabs:         [4]u32, // first slab, slab count, kind, flags
}

// dab.slang's FLAG_* bits.
@(private = "file")
DAB_FLAG_RELAX :: 1
@(private = "file")
DAB_FLAG_VALLEYS :: 2
@(private = "file")
DAB_FLAG_PEAKS :: 4
@(private = "file")
DAB_FLAG_TILT :: 8
@(private = "file")
DAB_FLAG_ONCE :: 16

// The dab kernels, in the order a dab runs them.
Sculpt_Dab_Stage :: enum {
	Area,
	Reduce,
	Move,
	Smooth_Targets,
	Smooth_Apply,
}

// One mesh's readback waiting in a slot: its ranges, where their positions (when read),
// normals and stroke heights (when read) go, and where in its download buffer they start:
// the positions first, then the packed normals, then the heights.
@(private = "file")
Sculpt_Entry :: struct {
	mesh:      ^Mesh_Buffers,
	positions: []geom.Vec3,
	normals:   []geom.Vec3,
	heights:   []Sculpt_Height,
	ranges:    []geom.Vertex_Range,
	download:  ^sdl.GPUTransferBuffer,
	offset:    u32,
	pbytes:    u32, // of positions; 0 when none were read
	nbytes:    u32, // of packed normals; 0 when none were read
	hbytes:    u32, // of heights; 0 when none were read
	nodes:     []Sculpt_Node, // whose bounds follow, 32 bytes each, when the positions were read
}

@(private = "file")
Sculpt_Slot :: struct {
	download:      ^sdl.GPUTransferBuffer,
	download_size: u32,
	// Download buffers a regrow mid-frame replaced, whose entries still read from them;
	// released once the slot is applied.
	retired:       [dynamic]^sdl.GPUTransferBuffer,
	fence:         ^sdl.GPUFence, // the frame that recorded the entries; nil once applied
	entries:       [dynamic]Sculpt_Entry,
	bytes:         u32, // of the download buffer used this frame
}

// A readback of positions that landed in a mesh, for the app to refit the sculptor's
// bounds with (sculpt.sculptor_positions_landed): drained by sculpt_gpu_landed.
Sculpt_Landed :: struct {
	mesh:   ^Mesh_Buffers,
	ranges: []geom.Vertex_Range,
	// The nodes of `ranges` and their bounds as the GPU found them over the positions
	// that landed; empty where it found none.
	nodes:  []Sculpt_Node,
	bounds: []geom.Aabb,
}

// What a run of sculpting on the GPU counts, for the exit stats and the Stats panel.
Sculpt_Gpu_Stats :: struct {
	strokes_gpu, strokes_cpu: int, // strokes the GPU took (normals or dabs), and the rest
	strokes_dabs: int, // of the GPU's, those whose dabs ran there
	dabs:       int, // dabs the kernels laid
	dispatches: int, // frames that ran a kernel
	// The last frame's readbacks applied: bytes read and the time to copy and decode them.
	applied_kb: f64,
	apply_ms:   f64,
	applied:    bool, // the last frame applied some
}

Sculpt_Gpu :: struct {
	pipeline:      ^sdl.GPUComputePipeline, // the normals kernel
	dab_pipelines: [Sculpt_Dab_Stage]^sdl.GPUComputePipeline,
	failed:   bool, // a kernel could not be made: every stroke stays on the CPU
	// --gpu-sculpt-sync: a frame's readbacks are waited for and applied before the next
	// frame's dabs, so the CPU reads the positions and normals the CPU path would have (for
	// A/B of the arithmetic alone).
	sync:     bool,
	slabs:            ^sdl.GPUBuffer,
	slabs_capacity:   u32, // bytes
	transfer:         ^sdl.GPUTransferBuffer, // the slabs on their way up
	transfer_size:    u32,
	dabs:             ^sdl.GPUBuffer, // the frame's dab records
	dabs_capacity:    u32,
	dabs_transfer:    ^sdl.GPUTransferBuffer,
	dabs_transfer_size: u32,
	partials:         ^sdl.GPUBuffer, // a slab's area sums, 32 bytes each
	partials_capacity: u32,
	areas:            ^sdl.GPUBuffer, // a dab's area, 32 bytes each
	areas_capacity:   u32,
	scratch:          ^sdl.GPUBuffer, // Smooth's targets, 16 bytes a slot of the largest dab
	scratch_capacity: u32,
	bounds_pipeline:  ^sdl.GPUComputePipeline,
	nodes:            ^sdl.GPUBuffer, // the frame's Sculpt_Nodes
	nodes_capacity:   u32,
	nodes_transfer:   ^sdl.GPUTransferBuffer,
	nodes_transfer_size: u32,
	bounds:           ^sdl.GPUBuffer, // two float4 a node: lowest, highest
	bounds_capacity:  u32,
	slots:    [SCULPT_SLOTS]Sculpt_Slot,
	slot:     int,  // the slot this frame records into
	recorded: bool, // this frame's command buffer holds readbacks: submit it fenced (sculpt_gpu_submitted)
	landed:   [dynamic]Sculpt_Landed,
	stats:    Sculpt_Gpu_Stats,
}

// Whether the backend sculpts on the GPU at all: the own Vulkan backend, where the kernels
// and their readback are verified; Metal waits for its own run on a device.
sculpt_gpu_offered :: proc() -> bool {
	when VULKAN do return true
	else do return false
}

// The slots from the oldest submitted to the one this frame records into: the readbacks
// land in the order they were submitted, so a newer never lands before an older.
@(private = "file")
slot_order :: proc(sg: ^Sculpt_Gpu) -> [SCULPT_SLOTS]int {
	order: [SCULPT_SLOTS]int
	for k in 0 ..< SCULPT_SLOTS do order[k] = (sg.slot + 1 + k) % SCULPT_SLOTS
	return order
}

// Starts a frame: applies every readback whose fence has signalled, oldest first and no
// further than the first still running (all of them, waiting, in sync mode), and frees
// the slot this frame will record into. Call once a frame before anything is recorded.
sculpt_gpu_frame :: proc(r: ^Renderer) {
	sg := &r.sculpt_gpu
	sg.stats.applied_kb, sg.stats.apply_ms, sg.stats.applied = 0, 0, false
	blocked := false
	for i in slot_order(sg) {
		s := &sg.slots[i]
		if s.fence != nil {
			if !blocked && (sg.sync || i == sg.slot || gpu_query_fence(r.device, s.fence)) do sculpt_slot_apply(r, s)
			else do blocked = true
		}
		// Entries with no fence were recorded by a frame that was never submitted: they
		// hold nothing to read.
		if s.fence == nil && i == sg.slot do sculpt_slot_drop(r, s)
	}
}

// The readbacks of positions that landed since the last clear (a frame's start, or a
// sync), for the app to refit their sculptors' bounds with.
@(private = "file")
sculpt_landed_free :: proc(l: Sculpt_Landed) {
	delete(l.ranges)
	delete(l.nodes)
	delete(l.bounds)
}

sculpt_gpu_landed :: proc(r: ^Renderer) -> []Sculpt_Landed {
	return r.sculpt_gpu.landed[:]
}

sculpt_gpu_landed_clear :: proc(r: ^Renderer) {
	for l in r.sculpt_gpu.landed do sculpt_landed_free(l)
	clear(&r.sculpt_gpu.landed)
}

// Whether the GPU takes a stroke on `mb` (triangles as `mb` holds them, lookup `faces`):
// makes the kernels and the mesh's lookup buffers on first use, and false (logged, and
// not asked again for that mesh) where the device refuses them.
sculpt_gpu_begin :: proc(r: ^Renderer, mb: ^Mesh_Buffers, faces: geom.Vertex_Faces, shared: []u32) -> bool {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	if !r.caps.gpu_sculpt || sg.failed || ms.failed || !mb.storage do return false
	if sg.pipeline == nil && !sculpt_pipelines_make(r) do return false
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
	// The nodes' shared vertices, never empty for the binding's sake.
	sbytes := max(u32(len(shared)) * size_of(u32), 4)
	ms.shared = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = sbytes})
	if ms.shared == nil {
		log.errorf("sculpt on the GPU: the shared vertices' %d MB were refused (%s); this mesh's strokes stay on the CPU", sbytes >> 20, sdl.GetError())
		sculpt_lookup_release(r, mb)
		ms.failed = true
		return false
	}
	gpu_set_buffer_name(r.device, ms.shared, "sculpt shared vertices")
	if ok && len(shared) > 0 do ok = upload_blocking(r, mb, ms.shared, slice.to_bytes(shared))
	if !ok {
		log.errorf("sculpt on the GPU: the lookup's upload failed (%s); this mesh's strokes stay on the CPU", sdl.GetError())
		sculpt_lookup_release(r, mb)
		ms.failed = true
		return false
	}
	ms.lookup_version, ms.lookup_bytes = mb.index_version, int(obytes + tbytes + sbytes)
	log.infof("sculpt on the GPU: %d MB lookup uploaded in %.0f ms", (obytes + tbytes) >> 20, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Makes the six kernels, exact (IEEE 754 arithmetic, no fast maths), so a result can
// equal the CPU's. False, with every stroke left to the CPU, where one cannot be made.
@(private = "file")
sculpt_pipelines_make :: proc(r: ^Renderer) -> bool {
	sg := &r.sculpt_gpu
	make_one :: proc(r: ^Renderer, code: string, readonly, readwrite: u32, what: string) -> ^sdl.GPUComputePipeline {
		p := gpu_create_compute_pipeline_exact(r.device, {
			code_size                     = len(code),
			code                          = raw_data(code),
			entrypoint                    = SHADER_ENTRY,
			format                        = SHADER_FORMAT,
			num_readonly_storage_buffers  = readonly,
			num_readwrite_storage_buffers = readwrite,
			num_uniform_buffers           = 1,
			threadcount_x                 = SCULPT_SLAB,
			threadcount_y                 = 1,
			threadcount_z                 = 1,
		})
		if p == nil do log.errorf("sculpt on the GPU: the %s kernel could not be made (%s); strokes stay on the CPU", what, sdl.GetError())
		return p
	}
	sg.pipeline = make_one(r, NODE_NORMALS_COMP_CODE, 5, 1, "normals")
	sg.bounds_pipeline = make_one(r, NODE_BOUNDS_COMP_CODE, 3, 1, "bounds")
	if sg.bounds_pipeline == nil {
		sg.failed = true
		return false
	}
	codes := [Sculpt_Dab_Stage]string{.Area = DAB_AREA_COMP_CODE, .Reduce = DAB_REDUCE_COMP_CODE, .Move = DAB_MOVE_COMP_CODE, .Smooth_Targets = DAB_SMOOTH_TARGETS_COMP_CODE, .Smooth_Apply = DAB_SMOOTH_APPLY_COMP_CODE}
	names := [Sculpt_Dab_Stage]string{.Area = "dab area", .Reduce = "dab reduce", .Move = "dab move", .Smooth_Targets = "smooth targets", .Smooth_Apply = "smooth apply"}
	ok := sg.pipeline != nil
	for stage in Sculpt_Dab_Stage {
		sg.dab_pipelines[stage] = make_one(r, codes[stage], 6, 5, names[stage])
		ok = ok && sg.dab_pipelines[stage] != nil
	}
	if !ok do sg.failed = true
	return ok
}

// Queues the frame's dabs of `mb` for this frame's dispatch, in order, before its normals:
// the records and their ranges are copied.
sculpt_gpu_queue_dabs :: proc(mb: ^Mesh_Buffers, dabs: []Sculpt_Dab) {
	ms := &mb.sculpt
	// Room for every range first: a record's slice into the arena must outlive the
	// appends of the records after it.
	total := len(ms.dab_ranges)
	for d in dabs do total += len(d.ranges)
	reserve(&ms.dab_ranges, total)
	for d in dabs {
		first := len(ms.dab_ranges)
		append(&ms.dab_ranges, ..d.ranges)
		rec := d
		rec.ranges = ms.dab_ranges[first:][:len(d.ranges)]
		append(&ms.dabs, rec)
	}
}

// Queues `ranges` of `mb` (whose CPU normals are `normals`, positions `positions`) for this
// frame's dispatch, the last of a stroke with `last`. The ranges are copied; the kernels and
// the readback are recorded by sculpt_gpu_dispatch once the frame has uploaded what the
// CPU moved. With `positions` nil only the normals are read back (the CPU laid the dabs);
// else the positions too, into it, and the stroke heights into `heights` when not nil.
sculpt_gpu_queue :: proc(mb: ^Mesh_Buffers, ranges: []geom.Vertex_Range, nodes: []Sculpt_Node, normals: []geom.Vec3, positions: []geom.Vec3, heights: []Sculpt_Height, last: bool) {
	ms := &mb.sculpt
	append(&ms.queued, ..ranges)
	if positions != nil do append(&ms.queued_nodes, ..nodes)
	ms.normals = normals
	ms.positions = positions
	ms.heights = heights if positions != nil else nil
	ms.last = ms.last || last
}

// Queues `ranges` to have their normals read back with the frame's readbacks into
// `normals`, as the GPU holds them (after a stroke whose dabs ran there, whose readbacks
// carried the positions alone).
sculpt_gpu_queue_back :: proc(mb: ^Mesh_Buffers, ranges: []geom.Vertex_Range, normals: []geom.Vec3) {
	append(&mb.sculpt.back, ..ranges)
	mb.sculpt.back_normals = normals
}

// The vertices a worker takes at a time copying or unpacking a readback.
@(private = "file")
SCULPT_PIECE :: 4096

// Whether the frame calls sculpt_gpu_dispatch for the mesh: kernels or readbacks queued.
sculpt_gpu_wanted :: proc(mb: ^Mesh_Buffers) -> bool {
	return sculpt_gpu_upload(mb) != .Full || len(mb.sculpt.back) > 0
}

// Reads the normals of `ranges` back into `normals` now, as the GPU holds them after the
// work submitted so far, waiting for it: for a sync that needs every normal a stroke on
// the GPU left there. False where the device refuses something.
sculpt_gpu_read_normals :: proc(r: ^Renderer, mb: ^Mesh_Buffers, ranges: []geom.Vertex_Range, normals: []geom.Vec3) -> bool {
	verts: u32
	for rg in ranges do verts += rg.count
	if verts == 0 do return true
	if mb.normals == nil do return false
	size := verts * size_of(Normal_Packed)
	download := gpu_create_transfer_buffer(r.device, {usage = .DOWNLOAD, size = size})
	if download == nil {
		log.errorf("sculpt on the GPU: a readback buffer of %d KB was refused (%s)", size >> 10, sdl.GetError())
		return false
	}
	defer gpu_release_transfer_buffer(r.device, download)
	cmd := gpu_acquire_command_buffer(r.device)
	if cmd == nil do return false
	pass := gpu_begin_copy_pass(cmd)
	at: u32
	for rg in ranges {
		bytes := rg.count * size_of(Normal_Packed)
		gpu_download_from_buffer(pass, {buffer = mb.normals, offset = rg.first * size_of(Normal_Packed), size = bytes}, {transfer_buffer = download, offset = at})
		at += bytes
	}
	gpu_end_copy_pass(pass)
	fence := gpu_submit_command_buffer_and_acquire_fence(cmd)
	if fence == nil do return false
	defer gpu_release_fence(r.device, fence)
	if !gpu_wait_for_fences(r.device, true, &fence, 1) do return false
	src := ([^]Normal_Packed)(gpu_map_transfer_buffer(r.device, download, false))
	if src == nil do return false
	sculpt_unpack_normals(r, src, ranges, normals)
	gpu_unmap_transfer_buffer(r.device, download)
	return true
}

// Unpacks packed normals, `ranges` one after another in `src`, into `normals`, on the
// workers in pieces (the ranges come coalesced, often one long run).
@(private = "file")
sculpt_unpack_normals :: proc(r: ^Renderer, src: [^]Normal_Packed, ranges: []geom.Vertex_Range, normals: []geom.Vec3) {
	Unpack :: struct {
		src:     [^]Normal_Packed,
		normals: []geom.Vec3,
		pieces:  []geom.Vertex_Range,
		starts:  []u32,
	}
	pieces := make([dynamic]geom.Vertex_Range, 0, 64, context.temp_allocator)
	starts := make([dynamic]u32, 0, 64, context.temp_allocator)
	at: u32
	for rg in ranges {
		for first := rg.first; first < rg.first + rg.count; first += SCULPT_PIECE {
			count := min(SCULPT_PIECE, rg.first + rg.count - first)
			append(&pieces, geom.Vertex_Range{first, count})
			append(&starts, at)
			at += count
		}
	}
	job := Unpack{src = src, normals = normals, pieces = pieces[:], starts = starts[:]}
	jobs.parallel_for(r.pool, len(pieces), &job, proc(data: rawptr, i: int) {
		job := cast(^Unpack)data
		rg := job.pieces[i]
		for p, k in job.src[job.starts[i]:][:rg.count] do job.normals[rg.first + u32(k)] = unpack_normal(p)
	})
}

// What the frame uploads of the mesh's flushed ranges: everything, as when the CPU
// sculpts; the positions alone, the normals being the kernel's; or nothing, the dabs
// having run on the GPU, whose positions an upload would overwrite.
Sculpt_Upload :: enum {
	Full,
	Positions,
	None,
}

sculpt_gpu_upload :: proc(mb: ^Mesh_Buffers) -> Sculpt_Upload {
	ms := &mb.sculpt
	if len(ms.queued) == 0 do return .Full
	return .None if ms.positions != nil else .Positions
}

// Records the queued dabs' kernels, the queued ranges' normals kernel and their readback
// into `cmd`, after the frame uploaded what the CPU moved. False, with the queue dropped
// and nothing recorded, where the device refused a buffer: the caller then has the CPU
// lay the dabs and recompute the normals (sculpt.sculptor_gpu_refused).
sculpt_gpu_dispatch :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers) -> bool {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	if len(ms.queued) == 0 && len(ms.dabs) == 0 && len(ms.back) == 0 do return true
	defer {
		clear(&ms.back)
		ms.back_normals = nil
		clear(&ms.queued)
		clear(&ms.queued_nodes)
		clear(&ms.dabs)
		clear(&ms.dab_ranges)
		ms.last = false
		ms.positions, ms.heights = nil, nil
	}
	back_bytes: u32
	for rg in ms.back do back_bytes += rg.count * size_of(Normal_Packed)
	if len(ms.queued) == 0 && len(ms.dabs) == 0 {
		s := &sg.slots[sg.slot]
		if !sculpt_slot_fit(r, s, back_bytes) do return sculpt_refused(sg, fmt.tprintf("a readback buffer of %d KB", (s.bytes + back_bytes) >> 10))
		sculpt_back_record(r, cmd, mb, s)
		return true
	}
	if sg.pipeline == nil || ms.offsets == nil || ms.failed do return false

	// The slabs: each dab's ranges, then the normals' ranges, cut into workgroups' worth.
	Slab :: [2]u32
	slabs := make([dynamic]Slab, 0, 256, context.temp_allocator)
	cut :: proc(slabs: ^[dynamic]Slab, ranges: []geom.Vertex_Range) -> (verts: u32) {
		for rg in ranges {
			verts += rg.count
			for first := rg.first; first < rg.first + rg.count; first += SCULPT_SLAB {
				append(slabs, Slab{first, min(SCULPT_SLAB, rg.first + rg.count - first)})
			}
		}
		return
	}
	records := make([]Sculpt_Dab_Record, len(ms.dabs), context.temp_allocator)
	widest: u32
	once: bool
	for d, i in ms.dabs {
		first := u32(len(slabs))
		_ = cut(&slabs, d.ranges)
		count := u32(len(slabs)) - first
		widest = max(widest, count)
		once ||= d.once
		records[i] = dab_record(d, first, count)
	}
	dab_slabs := u32(len(slabs))
	normals_first := u32(len(slabs))
	verts := cut(&slabs, ms.queued[:])
	normals_count := u32(len(slabs)) - normals_first

	// Every buffer the frame needs, sized before anything is recorded, so a refusal
	// leaves nothing half done on the GPU.
	sbytes := u32(len(slabs) * size_of(Slab))
	if !transfer_fit(r, &sg.transfer, &sg.transfer_size, sbytes) do return sculpt_refused(sg, fmt.tprintf("an upload buffer of %d KB", sbytes >> 10))
	if !storage_fit(r, &sg.slabs, &sg.slabs_capacity, sbytes, {.COMPUTE_STORAGE_READ}) do return sculpt_refused(sg, fmt.tprintf("a slab buffer of %d KB", sbytes >> 10))
	dbytes := u32(len(records) * size_of(Sculpt_Dab_Record))
	if len(records) > 0 {
		if !transfer_fit(r, &sg.dabs_transfer, &sg.dabs_transfer_size, dbytes) do return sculpt_refused(sg, fmt.tprintf("a dab upload buffer of %d KB", dbytes >> 10))
		if !storage_fit(r, &sg.dabs, &sg.dabs_capacity, dbytes, {.COMPUTE_STORAGE_READ}) do return sculpt_refused(sg, fmt.tprintf("a dab buffer of %d KB", dbytes >> 10))
		if !storage_fit(r, &sg.partials, &sg.partials_capacity, dab_slabs * 32, {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, fmt.tprintf("a partials buffer of %d KB", (dab_slabs * 32) >> 10))
		if !storage_fit(r, &sg.areas, &sg.areas_capacity, u32(len(records)) * 32, {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, "an areas buffer")
		if !storage_fit(r, &sg.scratch, &sg.scratch_capacity, max(widest * SCULPT_SLAB * 16, 16), {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, fmt.tprintf("a scratch buffer of %d KB", (widest * SCULPT_SLAB * 16) >> 10))
		hbytes := mb.vertex_capacity * size_of(Sculpt_Height)
		if (once || ms.heights != nil) && !storage_fit(r, &ms.heights_buffer, &ms.heights_capacity, hbytes, {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, fmt.tprintf("a heights buffer of %d MB", hbytes >> 20))
	}
	if ms.heights != nil && ms.heights_buffer == nil do ms.heights = nil // no dab of the stroke has kept a height yet
	// The readback's place in this frame's slot.
	s := &sg.slots[sg.slot]
	pbytes := verts * size_of(geom.Vec3) if ms.positions != nil else 0
	// With the dabs on the GPU the positions come back alone: nothing on the CPU reads a
	// stroke's normals before it ends, and unpacking them was nearly all the readback's
	// time (2.0 of 2.1 ms a frame at 5M); they follow after the stroke (Mesh_Sculpt.back).
	nbytes := verts * size_of(Normal_Packed) if ms.positions == nil else 0
	hbytes := verts * size_of(Sculpt_Height) if ms.heights != nil else 0
	// With the positions, the nodes' bounds: the landing then reads none of them again.
	node_count := u32(len(ms.queued_nodes)) if pbytes > 0 && ms.shared != nil else 0
	bbytes := node_count * 2 * size_of([4]f32)
	if node_count > 0 {
		nbytes_up := node_count * size_of(Sculpt_Node)
		if !transfer_fit(r, &sg.nodes_transfer, &sg.nodes_transfer_size, nbytes_up) do return sculpt_refused(sg, fmt.tprintf("a node upload buffer of %d KB", nbytes_up >> 10))
		if !storage_fit(r, &sg.nodes, &sg.nodes_capacity, nbytes_up, {.COMPUTE_STORAGE_READ}) do return sculpt_refused(sg, fmt.tprintf("a node buffer of %d KB", nbytes_up >> 10))
		if !storage_fit(r, &sg.bounds, &sg.bounds_capacity, bbytes, {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, fmt.tprintf("a bounds buffer of %d KB", bbytes >> 10))
	}
	if !sculpt_slot_fit(r, s, pbytes + nbytes + hbytes + bbytes + back_bytes) do return sculpt_refused(sg, fmt.tprintf("a readback buffer of %d KB", (s.bytes + pbytes + nbytes + hbytes + bbytes + back_bytes) >> 10))
	dst := gpu_map_transfer_buffer(r.device, sg.transfer, true)
	if dst == nil do return sculpt_refused(sg, "mapping the slabs")
	copy(([^]u8)(dst)[:sbytes], slice.to_bytes(slabs[:]))
	gpu_unmap_transfer_buffer(r.device, sg.transfer)
	if len(records) > 0 {
		dst = gpu_map_transfer_buffer(r.device, sg.dabs_transfer, true)
		if dst == nil do return sculpt_refused(sg, "mapping the dabs")
		copy(([^]u8)(dst)[:dbytes], slice.to_bytes(records))
		gpu_unmap_transfer_buffer(r.device, sg.dabs_transfer)
	}
	if node_count > 0 {
		dst = gpu_map_transfer_buffer(r.device, sg.nodes_transfer, true)
		if dst == nil do return sculpt_refused(sg, "mapping the nodes")
		copy(([^]u8)(dst)[:node_count * size_of(Sculpt_Node)], slice.to_bytes(ms.queued_nodes[:]))
		gpu_unmap_transfer_buffer(r.device, sg.nodes_transfer)
	}

	debug_group(cmd, "GPU sculpt", .Sculpt)
	// The slabs and dabs go up cycled: the last frame's dispatch may still read the buffers.
	pass := gpu_begin_copy_pass(cmd)
	gpu_upload_to_buffer(pass, {transfer_buffer = sg.transfer}, {buffer = sg.slabs, size = sbytes}, true)
	if len(records) > 0 do gpu_upload_to_buffer(pass, {transfer_buffer = sg.dabs_transfer}, {buffer = sg.dabs, size = dbytes}, true)
	if node_count > 0 do gpu_upload_to_buffer(pass, {transfer_buffer = sg.nodes_transfer}, {buffer = sg.nodes, size = node_count * size_of(Sculpt_Node)}, true)
	gpu_end_copy_pass(pass)

	Params :: struct {
		dab:      u32,
		groups_x: u32,
		rate:     f32,
		stroke:   u32,
	}
	if len(records) > 0 {
		// The dabs, in order, in one pass: the backend puts a barrier after every
		// dispatch (vk_dispatch_compute), so each reads what the one before wrote. A
		// stroke that keeps no heights binds the areas in their place, which no kernel
		// then touches.
		heights := ms.heights_buffer if ms.heights_buffer != nil else sg.areas
		writes := [5]sdl.GPUStorageBufferReadWriteBinding{{buffer = mb.positions}, {buffer = sg.partials}, {buffer = sg.areas}, {buffer = sg.scratch}, {buffer = heights}}
		compute := gpu_begin_compute_pass(cmd, nil, 0, &writes[0], len(writes))
		reads := [6]^sdl.GPUBuffer{mb.indices, ms.offsets, ms.tris, sg.slabs, sg.dabs, mb.normals}
		gpu_bind_compute_storage_buffers(compute, 0, &reads[0], len(reads))
		for d, i in ms.dabs {
			count := int(records[i].slabs[1])
			groups_x := max(min(count, MAX_SLAB_GROUPS_X), 1)
			groups_y := (count + groups_x - 1) / groups_x
			params := Params{dab = u32(i), groups_x = u32(groups_x), stroke = d.stroke}
			if d.kind == .Smooth {
				for pass_index in 0 ..< d.passes {
					params.rate = d.rates[pass_index]
					gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Smooth_Targets])
					gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
					gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
					gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Smooth_Apply])
					gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
					gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
				}
				continue
			}
			if d.kind != .Inflate {
				gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Area])
				gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
				gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
				gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Reduce])
				gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
				gpu_dispatch_compute(compute, 1, 1, 1)
			}
			gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Move])
			gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
			gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
		}
		gpu_end_compute_pass(compute)
		sg.stats.dabs += len(ms.dabs)
	}
	if normals_count > 0 {
		Normals_Params :: struct {
			slab_count: u32,
			groups_x:   u32,
			first:      u32,
			_:          u32,
		}
		groups_x := min(int(normals_count), MAX_SLAB_GROUPS_X)
		groups_y := (int(normals_count) + groups_x - 1) / groups_x
		params := Normals_Params{slab_count = normals_count, groups_x = u32(groups_x), first = normals_first}
		write := sdl.GPUStorageBufferReadWriteBinding{buffer = mb.normals}
		compute := gpu_begin_compute_pass(cmd, nil, 0, &write, 1)
		gpu_bind_compute_pipeline(compute, sg.pipeline)
		reads := [5]^sdl.GPUBuffer{mb.indices, ms.offsets, ms.tris, mb.positions, sg.slabs}
		gpu_bind_compute_storage_buffers(compute, 0, &reads[0], len(reads))
		gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
		gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
		gpu_end_compute_pass(compute)
	}
	if node_count > 0 {
		// The nodes' bounds over the positions the dabs left, one workgroup a node.
		Bounds_Params :: struct {
			node_count: u32,
			groups_x:   u32,
			_:          [2]u32,
		}
		groups_x := min(int(node_count), MAX_SLAB_GROUPS_X)
		groups_y := (int(node_count) + groups_x - 1) / groups_x
		params := Bounds_Params{node_count = node_count, groups_x = u32(groups_x)}
		write := sdl.GPUStorageBufferReadWriteBinding{buffer = sg.bounds}
		compute := gpu_begin_compute_pass(cmd, nil, 0, &write, 1)
		gpu_bind_compute_pipeline(compute, sg.bounds_pipeline)
		reads := [3]^sdl.GPUBuffer{mb.positions, sg.nodes, ms.shared}
		gpu_bind_compute_storage_buffers(compute, 0, &reads[0], len(reads))
		gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
		gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
		gpu_end_compute_pass(compute)
	}
	// The vertex shader reads what the kernels wrote, so the mesh is drawn afresh.
	r.last_version += 1
	mb.version = r.last_version

	if verts > 0 {
		entry := Sculpt_Entry{nodes = slice.clone(ms.queued_nodes[:node_count]), mesh = mb, positions = ms.positions, normals = ms.normals, heights = ms.heights, ranges = slice.clone(ms.queued[:]), download = s.download, offset = s.bytes, pbytes = pbytes, nbytes = nbytes, hbytes = hbytes}
		pass = gpu_begin_copy_pass(cmd)
		at := s.bytes
		if pbytes > 0 {
			for rg in entry.ranges {
				size := rg.count * size_of(geom.Vec3)
				gpu_download_from_buffer(pass, {buffer = mb.positions, offset = rg.first * size_of(geom.Vec3), size = size}, {transfer_buffer = s.download, offset = at})
				at += size
			}
		}
		if nbytes > 0 {
			for rg in entry.ranges {
				size := rg.count * size_of(Normal_Packed)
				gpu_download_from_buffer(pass, {buffer = mb.normals, offset = rg.first * size_of(Normal_Packed), size = size}, {transfer_buffer = s.download, offset = at})
				at += size
			}
		}
		if hbytes > 0 {
			for rg in entry.ranges {
				size := rg.count * size_of(Sculpt_Height)
				gpu_download_from_buffer(pass, {buffer = ms.heights_buffer, offset = rg.first * size_of(Sculpt_Height), size = size}, {transfer_buffer = s.download, offset = at})
				at += size
			}
		}
		if bbytes > 0 {
			gpu_download_from_buffer(pass, {buffer = sg.bounds, size = bbytes}, {transfer_buffer = s.download, offset = at})
			at += bbytes
		}
		gpu_end_copy_pass(pass)
		s.bytes = at
		append(&s.entries, entry)
		sg.recorded = true
	}
	// After the kernels, which may have just written them.
	if len(ms.back) > 0 do sculpt_back_record(r, cmd, mb, s)
	sg.stats.dispatches += 1
	return true
}

// Makes the slot's readback buffer hold `bytes` more than it holds; false where the device
// refuses it.
@(private = "file")
sculpt_slot_fit :: proc(r: ^Renderer, s: ^Sculpt_Slot, bytes: u32) -> bool {
	if s.download != nil && s.download_size >= s.bytes + bytes do return true
	// An earlier mesh's readback this frame lives in the old buffer, whose copies are
	// recorded: it stays until the slot is applied.
	if s.download != nil && s.bytes > 0 do append(&s.retired, s.download)
	else if s.download != nil do gpu_release_transfer_buffer(r.device, s.download)
	want := s.bytes + bytes
	s.download_size = want + want / 4
	s.download = gpu_create_transfer_buffer(r.device, {usage = .DOWNLOAD, size = s.download_size})
	if s.download == nil {
		s.download_size = 0
		return false
	}
	return true
}

// Records the copies of the normals queued to come back (Mesh_Sculpt.back) into the
// slot, whose buffer sculpt_slot_fit has made room in, as an entry of normals alone.
@(private = "file")
sculpt_back_record :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, s: ^Sculpt_Slot) {
	ms := &mb.sculpt
	entry := Sculpt_Entry{mesh = mb, normals = ms.back_normals, ranges = slice.clone(ms.back[:]), download = s.download, offset = s.bytes}
	pass := gpu_begin_copy_pass(cmd)
	at := s.bytes
	for rg in entry.ranges {
		size := rg.count * size_of(Normal_Packed)
		gpu_download_from_buffer(pass, {buffer = mb.normals, offset = rg.first * size_of(Normal_Packed), size = size}, {transfer_buffer = s.download, offset = at})
		at += size
	}
	gpu_end_copy_pass(pass)
	entry.nbytes = at - s.bytes
	s.bytes = at
	append(&s.entries, entry)
	r.sculpt_gpu.recorded = true
}

// A dab's record for dab.slang: the tilt's rows, for the kernel's row-major matrix.
@(private = "file")
dab_record :: proc(d: Sculpt_Dab, first_slab, slab_count: u32) -> Sculpt_Dab_Record {
	flags: u32
	if d.relax do flags |= DAB_FLAG_RELAX
	if d.once do flags |= DAB_FLAG_ONCE
	if d.valleys do flags |= DAB_FLAG_VALLEYS
	if d.peaks do flags |= DAB_FLAG_PEAKS
	if d.tilt != {} do flags |= DAB_FLAG_TILT
	t := d.tilt
	return {
		center_r2     = {d.center.x, d.center.y, d.center.z, d.r2},
		view_inv_r2   = {d.view.x, d.view.y, d.view.z, d.inv_r2},
		facing_amount = {d.facing.x, d.facing.y, d.facing.z, d.amount},
		tilt0         = {t[0, 0], t[0, 1], t[0, 2], d.strength},
		tilt1         = {t[1, 0], t[1, 1], t[1, 2], d.inv_sample2},
		tilt2         = {t[2, 0], t[2, 1], t[2, 2], d.plane_offset},
		misc          = {d.plane_short[0], d.plane_short[1], d.radius, 0},
		slabs         = {first_slab, slab_count, u32(d.kind), flags},
	}
}

// Grows an upload transfer buffer to hold `bytes` (with a quarter's slack); false where
// the device refuses it.
@(private = "file")
transfer_fit :: proc(r: ^Renderer, buffer: ^^sdl.GPUTransferBuffer, size: ^u32, bytes: u32) -> bool {
	if buffer^ != nil && size^ >= bytes do return true
	if buffer^ != nil do gpu_release_transfer_buffer(r.device, buffer^)
	size^ = bytes + bytes / 4
	buffer^ = gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = size^})
	if buffer^ == nil do size^ = 0
	return buffer^ != nil
}

// Grows a storage buffer to hold `bytes` (with a quarter's slack). A dispatch of the last
// frame may still read the old one: it is released once the GPU is idle, which is rare
// (the slack) and never inside a stroke's steady state.
@(private = "file")
storage_fit :: proc(r: ^Renderer, buffer: ^^sdl.GPUBuffer, capacity: ^u32, bytes: u32, usage: sdl.GPUBufferUsageFlags) -> bool {
	if buffer^ != nil && capacity^ >= bytes do return true
	if buffer^ != nil {
		_ = gpu_wait_for_idle(r.device)
		gpu_release_buffer(r.device, buffer^)
	}
	capacity^ = bytes + bytes / 4
	buffer^ = gpu_create_buffer(r.device, {usage = usage, size = capacity^})
	if buffer^ == nil do capacity^ = 0
	return buffer^ != nil
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

// Waits for every submitted readback of `mb` and writes it into the mesh, the older
// slots (of every mesh) first so nothing lands out of order. False where a readback of
// `mb` is recorded this frame and not yet submitted: the mesh still lags by it.
sculpt_gpu_sync :: proc(r: ^Renderer, mb: ^Mesh_Buffers) -> bool {
	sg := &r.sculpt_gpu
	order := slot_order(sg)
	newest := -1
	for i, k in order {
		s := &sg.slots[i]
		if s.fence == nil do continue
		for e in s.entries do if e.mesh == mb {
			newest = k
			break
		}
	}
	for i, k in order {
		if k > newest do break
		if s := &sg.slots[i]; s.fence != nil do sculpt_slot_apply(r, s)
	}
	current := &sg.slots[sg.slot]
	if current.fence == nil do for e in current.entries do if e.mesh == mb do return false
	return true
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
			delete(s.entries[i].nodes)
			unordered_remove(&s.entries, i)
		}
	}
	for i := len(sg.landed) - 1; i >= 0; i -= 1 {
		if sg.landed[i].mesh != mb do continue
		sculpt_landed_free(sg.landed[i])
		unordered_remove(&sg.landed, i)
	}
	sculpt_lookup_release(r, mb)
	delete(mb.sculpt.queued)
	delete(mb.sculpt.queued_nodes)
	delete(mb.sculpt.back)
	delete(mb.sculpt.dabs)
	delete(mb.sculpt.dab_ranges)
	mb.sculpt = {}
}

@(private = "file")
sculpt_lookup_release :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	ms := &mb.sculpt
	if ms.offsets != nil do gpu_release_buffer(r.device, ms.offsets)
	if ms.tris != nil do gpu_release_buffer(r.device, ms.tris)
	if ms.heights_buffer != nil do gpu_release_buffer(r.device, ms.heights_buffer)
	if ms.shared != nil do gpu_release_buffer(r.device, ms.shared)
	ms.shared = nil
	ms.offsets, ms.tris, ms.lookup_version, ms.lookup_bytes = nil, nil, 0, 0
	ms.heights_buffer, ms.heights_capacity = nil, 0
}

// Waits for the GPU, then releases the ring, the buffers and the kernels.
sculpt_gpu_destroy :: proc(r: ^Renderer) {
	sg := &r.sculpt_gpu
	if r.device == nil do return
	_ = gpu_wait_for_idle(r.device)
	for &s in sg.slots {
		if s.fence != nil do gpu_release_fence(r.device, s.fence)
		if s.download != nil do gpu_release_transfer_buffer(r.device, s.download)
		for b in s.retired do gpu_release_transfer_buffer(r.device, b)
		delete(s.retired)
		for e in s.entries {
			delete(e.ranges)
			delete(e.nodes)
		}
		delete(s.entries)
	}
	sculpt_gpu_landed_clear(r)
	delete(sg.landed)
	if sg.slabs != nil do gpu_release_buffer(r.device, sg.slabs)
	if sg.transfer != nil do gpu_release_transfer_buffer(r.device, sg.transfer)
	if sg.dabs != nil do gpu_release_buffer(r.device, sg.dabs)
	if sg.dabs_transfer != nil do gpu_release_transfer_buffer(r.device, sg.dabs_transfer)
	if sg.partials != nil do gpu_release_buffer(r.device, sg.partials)
	if sg.areas != nil do gpu_release_buffer(r.device, sg.areas)
	if sg.scratch != nil do gpu_release_buffer(r.device, sg.scratch)
	if sg.nodes != nil do gpu_release_buffer(r.device, sg.nodes)
	if sg.nodes_transfer != nil do gpu_release_transfer_buffer(r.device, sg.nodes_transfer)
	if sg.bounds != nil do gpu_release_buffer(r.device, sg.bounds)
	if sg.bounds_pipeline != nil do gpu_release_compute_pipeline(r.device, sg.bounds_pipeline)
	if sg.pipeline != nil do gpu_release_compute_pipeline(r.device, sg.pipeline)
	for p in sg.dab_pipelines do if p != nil do gpu_release_compute_pipeline(r.device, p)
	stats := sg.stats
	sg^ = {}
	sg.stats = stats
}

// Waits for a slot's frame (or takes the caller's word, `waited`, that it is done), copies
// every entry's positions and decodes its packed normals into its mesh, lists the
// positions that landed for the app, and frees the slot.
@(private = "file")
sculpt_slot_apply :: proc(r: ^Renderer, s: ^Sculpt_Slot, waited := false) {
	sg := &r.sculpt_gpu
	if s.fence != nil {
		_ = gpu_wait_for_fences(r.device, true, &s.fence, 1)
		gpu_release_fence(r.device, s.fence)
		s.fence = nil
	} else if !waited {
		sculpt_slot_drop(r, s)
		return
	}
	defer sculpt_slot_drop(r, s)
	if len(s.entries) == 0 do return
	start := time.tick_now()
	for e in s.entries {
		src := ([^]u8)(gpu_map_transfer_buffer(r.device, e.download, false))
		if src == nil {
			log.errorf("sculpt on the GPU: mapping a readback failed (%s)", sdl.GetError())
			continue
		}
		Decode :: struct {
			positions_src: [^]geom.Vec3,
			normals_src:   [^]Normal_Packed,
			heights_src:   [^]Sculpt_Height,
			positions:     []geom.Vec3,
			normals:       []geom.Vec3,
			heights:       []Sculpt_Height,
			ranges:        []geom.Vertex_Range,
			starts:        []u32, // each range's first vertex in the sources
		}
		job := Decode{positions = e.positions, normals = e.normals, heights = e.heights, ranges = e.ranges}
		if e.pbytes > 0 do job.positions_src = ([^]geom.Vec3)(src[e.offset:])
		if e.nbytes > 0 do job.normals_src = ([^]Normal_Packed)(src[e.offset + e.pbytes:])
		if e.hbytes > 0 do job.heights_src = ([^]Sculpt_Height)(src[e.offset + e.pbytes + e.nbytes:])
		// The ranges come coalesced, often one long run, so they are cut into pieces for
		// the workers (a 200k-vertex run on one thread took 6 ms at 25M).
		pieces := make([dynamic]geom.Vertex_Range, 0, 64, context.temp_allocator)
		starts := make([dynamic]u32, 0, 64, context.temp_allocator)
		at: u32
		for rg in e.ranges {
			for first := rg.first; first < rg.first + rg.count; first += SCULPT_PIECE {
				count := min(SCULPT_PIECE, rg.first + rg.count - first)
				append(&pieces, geom.Vertex_Range{first, count})
				append(&starts, at)
				at += count
			}
		}
		job.ranges, job.starts = pieces[:], starts[:]
		jobs.parallel_for(r.pool, len(pieces), &job, proc(data: rawptr, i: int) {
			job := cast(^Decode)data
			rg := job.ranges[i]
			if job.positions_src != nil do copy(job.positions[rg.first:][:rg.count], job.positions_src[job.starts[i]:][:rg.count])
			if job.heights_src != nil do copy(job.heights[rg.first:][:rg.count], job.heights_src[job.starts[i]:][:rg.count])
			if job.normals_src == nil do return
			packed := job.normals_src[job.starts[i]:][:rg.count]
			for p, k in packed do job.normals[rg.first + u32(k)] = unpack_normal(p)
		})
		// The nodes' bounds, after the heights: two float4 a node, lowest then highest.
		bounds: []geom.Aabb
		if len(e.nodes) > 0 {
			corners := ([^][4]f32)(src[e.offset + e.pbytes + e.nbytes + e.hbytes:])[:2 * len(e.nodes)]
			bounds = make([]geom.Aabb, len(e.nodes))
			for &b, k in bounds do b = {corners[2 * k].xyz, corners[2 * k + 1].xyz}
		}
		gpu_unmap_transfer_buffer(r.device, e.download)
		if e.pbytes > 0 do append(&sg.landed, Sculpt_Landed{mesh = e.mesh, ranges = slice.clone(e.ranges), nodes = slice.clone(e.nodes), bounds = bounds})
		sg.stats.applied_kb += f64(e.pbytes + e.nbytes + e.hbytes + u32(len(e.nodes)) * 32) / 1024
	}
	sg.stats.apply_ms += time.duration_milliseconds(time.tick_since(start))
	sg.stats.applied = true
}

// Frees a slot's entries without reading them, and the download buffers a regrow retired.
@(private = "file")
sculpt_slot_drop :: proc(r: ^Renderer, s: ^Sculpt_Slot) {
	for e in s.entries {
		delete(e.ranges)
		delete(e.nodes)
	}
	clear(&s.entries)
	for b in s.retired do gpu_release_transfer_buffer(r.device, b)
	clear(&s.retired)
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
