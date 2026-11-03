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
// positions and indices they read: 28 bytes a vertex, uploaded once per mesh a slice a
// frame before a stroke needs it (sculpt_gpu_prepare) and kept with the mesh's buffers.

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
	// The lookup goes up a slice a frame (sculpt_gpu_prepare): the bytes of the offsets,
	// triangles and shared vertices, in that order, each part's size when its buffers
	// were made, how many are up, and whether all are; the buffers' mappings while they
	// fill, where the device shares its memory; when it began, and over how many frames.
	lookup_sizes:  [3]int,
	lookup_done:   int,
	lookup_ready:  bool,
	lookup_maps:   [3]rawptr,
	lookup_start:  time.Tick,
	lookup_frames: int,
	lookup_ms:     f64, // the CPU's time in sculpt_gpu_prepare over those frames
	// A stroke has taken the GPU with this lookup: it stays when its object is no longer
	// selected, as the mesh may well be sculpted again (sculpt_gpu_unselected).
	lookup_served: bool,
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
	// The level's mask and an HD window's fade, a byte a vertex packed four to a uint
	// (dab.slang `mask` and `fade`), each for the vertices it was made for; nil while the
	// level has none or the GPU sculpts no stroke on it (sculpt_gpu_bytes_upload).
	bytes: [Sculpt_Bytes]Sculpt_Byte_Buffer,
}

// The per-vertex bytes that shield vertices from a dab (sculpt.shield): the mask, and the
// fade toward an HD window's border.
Sculpt_Bytes :: enum u8 {
	Mask,
	Fade,
}

// One kind of those bytes on the GPU, for `vertices` vertices (0 while none are up).
Sculpt_Byte_Buffer :: struct {
	buffer:   ^sdl.GPUBuffer,
	vertices: u32,
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
	masked:       bool, // the mesh's mask bytes shield the vertices (sculpt_gpu_bytes_upload)
	faded:        bool, // the HD window's fade bytes do too
	falloff:      []f32, // a drawn falloff's table (sculpt.FALLOFF_STEPS + 1 values), nil for the round one
	// An alpha's values (sculpt.Alpha.values, alpha_size a side, 0 to 1), nil for none, and
	// the way its top faces and whether it is mirrored (sculpt.alpha_frame).
	alpha:        []f32,
	alpha_size:   int,
	alpha_up:     geom.Vec3,
	alpha_mirror: bool,
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

// A table the dab kernels read from `tables`: an alpha's values or a drawn falloff's, and
// where they start there, in floats.
Sculpt_Table :: struct {
	values: []f32,
	first:  u32,
}

// A dab as dab.slang reads it: nine float4s.
@(private = "file")
Sculpt_Dab_Record :: struct {
	center_r2:     [4]f32,
	view_inv_r2:   [4]f32,
	facing_amount: [4]f32,
	tilt0:         [4]f32, // .w the strength
	tilt1:         [4]f32, // .w 1 / (the sample radius)²
	tilt2:         [4]f32, // .w Clay's plane offset
	misc:          [4]f32, // plane_short above and below, the radius, the alpha's or else the drawn falloff's first float in `tables`
	alpha_up:      [4]f32, // the alpha's up (FLAG_ALPHA), .w its size a side
	slabs:         [4]u32, // first slab, slab count, kind, flags
}

// The float4s a dab's area takes in `areas` (dab.slang AREA_ROWS): the normal, a point
// on the plane, and with an alpha its frame (sculpt.Dab's au, av and an).
@(private = "file")
SCULPT_AREA_ROWS :: 5

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
@(private = "file")
DAB_FLAG_MASK :: 32
@(private = "file")
DAB_FLAG_DRAWN :: 64
@(private = "file")
DAB_FLAG_FADE :: 128
@(private = "file")
DAB_FLAG_ALPHA :: 256
@(private = "file")
DAB_FLAG_MIRROR :: 512

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
	// The alphas and drawn falloffs' tables of the frame's dabs (dab.slang `tables`), and
	// what they were when last uploaded: the same values for the same stroke on the same
	// mesh are not sent again (an alpha is up to 1 MB, a stroke's brush keeps it).
	tables:               ^sdl.GPUBuffer,
	tables_held:          [dynamic]Sculpt_Table,
	tables_mesh:          ^Mesh_Buffers,
	tables_stroke:        u32,
	tables_capacity:      u32,
	tables_transfer:      ^sdl.GPUTransferBuffer,
	tables_transfer_size: u32,
	// The mask and fade bytes on their way up (sculpt_gpu_bytes_upload).
	bytes_transfer:       [Sculpt_Bytes]^sdl.GPUTransferBuffer,
	bytes_transfer_size:  [Sculpt_Bytes]u32,
	// A slice of a lookup on its way up (sculpt_gpu_prepare), released once it is all up.
	lookup_transfer:      ^sdl.GPUTransferBuffer,
	lookup_transfer_size: u32,
	lookup_rate:          f64, // how fast the CPU copied the slices so far, in bytes a millisecond
	slots:    [SCULPT_SLOTS]Sculpt_Slot,
	slot:     int,  // the slot this frame records into
	recorded: bool, // this frame's command buffer holds readbacks: submit it fenced (sculpt_gpu_submitted)
	landed:   [dynamic]Sculpt_Landed,
	stats:    Sculpt_Gpu_Stats,
}

// Whether the backend sculpts on the GPU at all: the own Vulkan backend, where the kernels
// and their readback are verified, on a device whose kernels may bind as many storage
// buffers as the dab kernels do; Metal waits for its own run on a device.
sculpt_gpu_offered :: proc(r: ^Renderer) -> bool {
	when VULKAN do return gpu_storage_buffers_per_stage(r.device) >= SCULPT_STORAGE_BUFFERS
	else do return false
}

// The most storage buffers a sculpt kernel binds: the dab kernels' nine read-only
// (dab.slang set 0) and five read-write (set 1).
SCULPT_STORAGE_BUFFERS :: 14

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

// How much of a lookup goes up a frame (sculpt_gpu_prepare): at 25M vertices the lookup
// is 667 MB, which in one go held the first stroke for 2.4 s on an RTX 3060 Ti. A slice
// is as much as the CPU copies in SCULPT_LOOKUP_MS, at the rate the slices before it were
// copied (fresh upload memory is written at a few GB/s where the pages are new), between
// a floor that keeps a slow machine from taking minutes and a ceiling the first slice,
// with no rate known yet, takes.
SCULPT_LOOKUP_SLICE :: 16 << 20
SCULPT_LOOKUP_SLICE_MIN :: 4 << 20
SCULPT_LOOKUP_MS :: 2.0

// Where a mesh's lookup stands, for the frame that uploads it (sculpt_gpu_prepare).
Sculpt_Lookup :: enum u8 {
	Off,       // the GPU does not sculpt this mesh: nothing to upload
	Uploading, // more slices to go
	Ready,     // all up: a stroke on the mesh can take the GPU
}

// Uploads the next slice of the vertex -> triangle lookup and the nodes' shared vertices
// (`faces`, `shared`) the kernels read for `mb`, recorded on the frame's `cmd` ahead of its
// dispatch, making their buffers on the first. The frame calls it for the object a stroke
// may begin on, while no stroke is under way, so no stroke waits for the whole: until it
// is up, sculpt_gpu_begin keeps strokes on the CPU.
sculpt_gpu_prepare :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, faces: geom.Vertex_Faces, shared: []u32) -> Sculpt_Lookup {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	if !r.caps.gpu_sculpt || sg.failed || ms.failed || !mb.storage do return .Off
	if sg.pipeline == nil && !sculpt_pipelines_make(r) do return .Off
	// The lookup is another mesh's than the buffers hold: never dereference it on the GPU.
	if u32(len(faces.offsets)) != mb.vertex_capacity + 1 || u32(len(faces.tris)) != mb.index_count do return .Off
	parts := [3][]u8{slice.to_bytes(faces.offsets), slice.to_bytes(faces.tris), slice.to_bytes(shared)}
	sizes := [3]int{len(parts[0]), len(parts[1]), len(parts[2])}
	// Other triangles (a regrown or remade mesh), or the nodes made again: up again from the start.
	if ms.offsets == nil || ms.lookup_version != mb.index_version || ms.lookup_sizes != sizes {
		if !sculpt_lookup_make(r, mb, sizes) do return .Off
	}
	if ms.lookup_ready do return .Ready
	slice_start := time.tick_now()
	defer ms.lookup_ms += time.duration_milliseconds(time.tick_since(slice_start))
	total := sizes[0] + sizes[1] + sizes[2]
	budget := SCULPT_LOOKUP_SLICE
	if sg.lookup_rate > 0 do budget = clamp(int(sg.lookup_rate * SCULPT_LOOKUP_MS), SCULPT_LOOKUP_SLICE_MIN, SCULPT_LOOKUP_SLICE)
	end := min(ms.lookup_done + budget, total)
	// The slice's pieces of the three, written straight into a buffer the CPU maps (a
	// device sharing its memory) or staged for a copy.
	Piece :: struct {
		part, at, size: int, // which buffer, from where in it, how many bytes
		staged:         int, // where in the transfer buffer
	}
	pieces: [3]Piece
	count, staged := 0, 0
	base := 0
	for p, i in parts {
		lo, hi := max(ms.lookup_done, base), min(end, base + len(p))
		if lo < hi {
			pieces[count] = {i, lo - base, hi - lo, staged}
			if ms.lookup_maps[i] == nil do staged += hi - lo
			count += 1
		}
		base += len(p)
	}
	transfer: [^]u8
	if staged > 0 {
		if !transfer_fit(r, &sg.lookup_transfer, &sg.lookup_transfer_size, u32(SCULPT_LOOKUP_SLICE)) do return sculpt_lookup_refused(r, mb, "an upload buffer of 16 MB")
		transfer = cast([^]u8)gpu_map_transfer_buffer(r.device, sg.lookup_transfer, true)
		if transfer == nil do return sculpt_lookup_refused(r, mb, "the lookup's upload")
	}
	copy_start := time.tick_now()
	for pc in pieces[:count] {
		src := parts[pc.part][pc.at:][:pc.size]
		if m := ms.lookup_maps[pc.part]; m != nil do copy(([^]u8)(m)[pc.at:][:pc.size], src)
		else do copy(transfer[pc.staged:][:pc.size], src)
	}
	// Bytes a millisecond, the last slices weighing most.
	if copy_ms := time.duration_milliseconds(time.tick_since(copy_start)); copy_ms > 0 {
		rate := f64(end - ms.lookup_done) / copy_ms
		sg.lookup_rate = rate if sg.lookup_rate == 0 else 0.5 * (sg.lookup_rate + rate)
	}
	if staged > 0 {
		gpu_unmap_transfer_buffer(r.device, sg.lookup_transfer)
		buffers := [3]^sdl.GPUBuffer{ms.offsets, ms.tris, ms.shared}
		pass := gpu_begin_copy_pass(cmd)
		for pc in pieces[:count] {
			if ms.lookup_maps[pc.part] != nil do continue
			gpu_upload_to_buffer(pass, {transfer_buffer = sg.lookup_transfer, offset = u32(pc.staged)}, {buffer = buffers[pc.part], offset = u32(pc.at), size = u32(pc.size)}, false)
		}
		gpu_end_copy_pass(pass)
	}
	ms.lookup_done = end
	ms.lookup_frames += 1
	if end < total do return .Uploading
	sculpt_lookup_unmap(r, mb)
	ms.lookup_ready = true
	// The staging buffer's backings go once the GPU has copied from them: another mesh's
	// lookup makes it again.
	if sg.lookup_transfer != nil do gpu_release_transfer_buffer(r.device, sg.lookup_transfer)
	sg.lookup_transfer, sg.lookup_transfer_size = nil, 0
	log.infof("sculpt on the GPU: %d MB lookup uploaded over %d frames, %.0f ms after it began, %.1f ms a frame on the CPU", total >> 20, ms.lookup_frames, time.duration_milliseconds(time.tick_since(ms.lookup_start)), (ms.lookup_ms + time.duration_milliseconds(time.tick_since(slice_start))) / f64(ms.lookup_frames))
	return .Ready
}

// The largest byte upload whose upload buffer is kept for the next.
SCULPT_BYTES_KEEP :: 4 << 20

// Keeps the level's bytes of one `kind` (`values`, a byte a vertex, nil for none) on the
// GPU for the dab kernels while the mesh has a lookup (sculpt_gpu_prepare): all of them
// when the level first has them or the buffers grew, else the bytes of the vertex
// `ranges` the frame uploads, which hold every vertex whose bytes changed (a mask change
// marks its nodes for the flush; an HD window's fade is set when the window is made and
// changes only under dynamic topology, which changes the vertex count). Recorded on the
// frame's `cmd` before its dispatch. Bytes, for the stats.
sculpt_gpu_bytes_upload :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, mb: ^Mesh_Buffers, kind: Sculpt_Bytes, values: []u8, ranges: []geom.Vertex_Range) -> int {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	held := &ms.bytes[kind]
	what := "mask" if kind == .Mask else "fade"
	if values == nil || ms.offsets == nil || ms.failed {
		if held.buffer != nil do gpu_release_buffer(r.device, held.buffer)
		held^ = {}
		return 0
	}
	count := u32(len(values))
	// A stroke whose dabs run on the GPU changes no mask or fade (whatever changes one
	// ends the stroke first): its frames' ranges are the dabs' and copy nothing.
	if held.buffer != nil && held.vertices == count && sculpt_gpu_upload(mb) == .None do return 0
	start := time.tick_now()
	// Four vertices a uint: a range is copied out to whole uints, its neighbours' bytes
	// as the CPU holds them.
	padded := (count + 3) &~ 3
	Span :: struct {
		first, count: u32, // in bytes, multiples of four
	}
	spans := make([dynamic]Span, 0, len(ranges) + 1, context.temp_allocator)
	if held.buffer == nil || held.vertices != count {
		if held.buffer != nil do gpu_release_buffer(r.device, held.buffer)
		held^ = {}
		held.buffer = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = max(padded, 4)})
		if held.buffer == nil {
			log.errorf("sculpt on the GPU: the %s's %d MB were refused (%s); its strokes stay on the CPU", what, padded >> 20, sdl.GetError())
			return 0
		}
		gpu_set_buffer_name(r.device, held.buffer, "sculpt mask" if kind == .Mask else "sculpt fade")
		append(&spans, Span{0, padded})
	} else {
		for rg in ranges {
			lo := rg.first &~ 3
			hi := min((rg.first + rg.count + 3) &~ 3, padded)
			if lo >= hi do continue
			if n := len(spans); n > 0 && spans[n - 1].first + spans[n - 1].count >= lo {
				last := &spans[n - 1]
				last.count = max(last.first + last.count, hi) - last.first
			} else {
				append(&spans, Span{lo, hi - lo})
			}
		}
	}
	total: u32
	for sp in spans do total += sp.count
	if total == 0 do return 0
	transfer, transfer_size := &sg.bytes_transfer[kind], &sg.bytes_transfer_size[kind]
	if !transfer_fit(r, transfer, transfer_size, total) {
		log.errorf("sculpt on the GPU: an upload buffer of %d KB for the %s was refused (%s)", total >> 10, what, sdl.GetError())
		gpu_release_buffer(r.device, held.buffer)
		held^ = {}
		return 0
	}
	dst := cast([^]u8)gpu_map_transfer_buffer(r.device, transfer^, true)
	if dst == nil {
		gpu_release_buffer(r.device, held.buffer)
		held^ = {}
		return 0
	}
	at: u32
	for sp in spans {
		// The last uint's bytes past the mesh's end are zero (never read).
		have := min(sp.first + sp.count, count) - sp.first
		copy(dst[at:][:have], values[sp.first:][:have])
		for k in have ..< sp.count do dst[at + k] = 0
		at += sp.count
	}
	gpu_unmap_transfer_buffer(r.device, transfer^)
	pass := gpu_begin_copy_pass(cmd)
	at = 0
	for sp in spans {
		gpu_upload_to_buffer(pass, {transfer_buffer = transfer^, offset = at}, {buffer = held.buffer, offset = sp.first, size = sp.count}, false)
		at += sp.count
	}
	gpu_end_copy_pass(pass)
	// A large upload buffer (a whole mask, 25 MB at 25M, a window's fade, or a layer
	// mask's pick, which changes every vertex) goes once the GPU has copied from it: the
	// ranges of a mask stroke need a sliver of it.
	if total >= SCULPT_BYTES_KEEP {
		gpu_release_transfer_buffer(r.device, transfer^)
		transfer^, transfer_size^ = nil, 0
	}
	if held.vertices == 0 {
		log.infof("sculpt on the GPU: the %d MB %s went up in %.1f ms", total >> 20, what, time.duration_milliseconds(time.tick_since(start)))
	}
	held.vertices = count
	return int(total)
}

// Releases the lookup of a mesh no longer selected (or no longer its object's current
// level) that no stroke has taken the GPU with: the frames upload one for whatever is
// selected, and 700 MB at 25M for each object clicked through would fill the device.
sculpt_gpu_unselected :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	if mb.sculpt.offsets != nil && !mb.sculpt.lookup_served do sculpt_lookup_release(r, mb)
}

// Makes `mb`'s lookup buffers, empty, for sculpt_gpu_prepare to fill: false (logged, and
// the mesh's strokes left to the CPU) where the device refuses them.
@(private = "file")
sculpt_lookup_make :: proc(r: ^Renderer, mb: ^Mesh_Buffers, sizes: [3]int) -> bool {
	sculpt_lookup_release(r, mb)
	ms := &mb.sculpt
	names := [3]cstring{"sculpt lookup offsets", "sculpt lookup triangles", "sculpt shared vertices"}
	buffers: [3]^sdl.GPUBuffer
	for size, i in sizes {
		// Never empty, for the binding's sake (a mesh with no shared vertices).
		info := sdl.GPUBufferCreateInfo{usage = {.COMPUTE_STORAGE_READ}, size = u32(max(size, 4))}
		if r.caps.shared_buffers do buffers[i], ms.lookup_maps[i] = gpu_create_buffer_mapped(r.device, info)
		if buffers[i] == nil do buffers[i] = gpu_create_buffer(r.device, info)
		if buffers[i] != nil do gpu_set_buffer_name(r.device, buffers[i], names[i])
	}
	ms.offsets, ms.tris, ms.shared = buffers[0], buffers[1], buffers[2]
	if ms.offsets == nil || ms.tris == nil || ms.shared == nil {
		log.errorf("sculpt on the GPU: the lookup's %d MB were refused (%s); this mesh's strokes stay on the CPU", (sizes[0] + sizes[1] + sizes[2]) >> 20, sdl.GetError())
		sculpt_lookup_release(r, mb)
		ms.failed = true
		return false
	}
	ms.lookup_version, ms.lookup_sizes = mb.index_version, sizes
	ms.lookup_bytes = max(sizes[0], 4) + max(sizes[1], 4) + max(sizes[2], 4)
	ms.lookup_done, ms.lookup_ready, ms.lookup_frames, ms.lookup_ms, ms.lookup_start = 0, false, 0, 0, time.tick_now()
	return true
}

// Logs a refusal during the lookup's upload, releases what was made and leaves the
// mesh's strokes to the CPU.
@(private = "file")
sculpt_lookup_refused :: proc(r: ^Renderer, mb: ^Mesh_Buffers, what: string) -> Sculpt_Lookup {
	log.errorf("sculpt on the GPU: %s was refused (%s); this mesh's strokes stay on the CPU", what, sdl.GetError())
	sculpt_lookup_release(r, mb)
	mb.sculpt.failed = true
	return .Off
}

// Ends the fill of the lookup's mapped buffers, if any.
@(private = "file")
sculpt_lookup_unmap :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	ms := &mb.sculpt
	buffers := [3]^sdl.GPUBuffer{ms.offsets, ms.tris, ms.shared}
	for m, i in ms.lookup_maps do if m != nil && buffers[i] != nil do gpu_buffer_filled(r.device, buffers[i])
	ms.lookup_maps = {}
}

// Whether the GPU takes a stroke on `mb` (triangles as `mb` holds them, lookup `faces`,
// shared vertices `shared`): only once the frames have uploaded the mesh's lookup
// (sculpt_gpu_prepare). Under --gpu-sculpt-sync, which compares the paths stroke for
// stroke, the rest of the lookup goes up here instead, waited for.
sculpt_gpu_begin :: proc(r: ^Renderer, mb: ^Mesh_Buffers, faces: geom.Vertex_Faces, shared: []u32) -> bool {
	sg, ms := &r.sculpt_gpu, &mb.sculpt
	if !r.caps.gpu_sculpt || sg.failed || ms.failed || !mb.storage do return false
	sizes := [3]int{len(faces.offsets) * size_of(u32), len(faces.tris) * size_of(u32), len(shared) * size_of(u32)}
	if ms.lookup_ready && ms.lookup_version == mb.index_version && ms.lookup_sizes == sizes {
		ms.lookup_served = true
		return true
	}
	if !sg.sync {
		total := sizes[0] + sizes[1] + sizes[2]
		log.infof("sculpt on the GPU: the lookup is %d%% up; this stroke stays on the CPU", ms.lookup_done * 100 / max(total, 1) if ms.offsets != nil else 0)
		return false
	}
	for {
		cmd := gpu_acquire_command_buffer(r.device)
		if cmd == nil do return false
		state := sculpt_gpu_prepare(r, cmd, mb, faces, shared)
		if !gpu_submit_command_buffer(cmd) || !gpu_wait_for_idle(r.device) {
			_ = sculpt_lookup_refused(r, mb, "the lookup's upload")
			return false
		}
		if state == .Ready do ms.lookup_served = true
		if state != .Uploading do return state == .Ready
	}
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
		sg.dab_pipelines[stage] = make_one(r, codes[stage], 9, 5, names[stage])
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
	once, masked, faded: bool
	// The alphas and drawn falloffs' tables, each once (a stroke has one of each), one
	// after another.
	table_of := make([dynamic]Sculpt_Table, 0, context.temp_allocator)
	table_count: u32
	table_at :: proc(table_of: ^[dynamic]Sculpt_Table, count: ^u32, values: []f32) -> u32 {
		for t in table_of do if raw_data(t.values) == raw_data(values) && len(t.values) == len(values) do return t.first
		append(table_of, Sculpt_Table{values, count^})
		count^ += u32(len(values))
		return count^ - u32(len(values))
	}
	for d, i in ms.dabs {
		first := u32(len(slabs))
		_ = cut(&slabs, d.ranges)
		count := u32(len(slabs)) - first
		widest = max(widest, count)
		once ||= d.once
		masked ||= d.masked
		faded ||= d.faded
		// An alpha's weight leaves the drawn falloff out (sculpt.dab_weight), so a dab
		// reads one table.
		table_first: u32
		if d.alpha != nil do table_first = table_at(&table_of, &table_count, d.alpha)
		else if d.falloff != nil do table_first = table_at(&table_of, &table_count, d.falloff)
		records[i] = dab_record(d, first, count, table_first)
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
		if !storage_fit(r, &sg.areas, &sg.areas_capacity, u32(len(records)) * SCULPT_AREA_ROWS * 16, {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, "an areas buffer")
		if !storage_fit(r, &sg.scratch, &sg.scratch_capacity, max(widest * SCULPT_SLAB * 16, 16), {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}) do return sculpt_refused(sg, fmt.tprintf("a scratch buffer of %d KB", (widest * SCULPT_SLAB * 16) >> 10))
		// A masked or faded dab reads the mesh's mask or fade bytes, which the app keeps
		// on the GPU (sculpt_gpu_bytes_upload); without them (their buffer was refused,
		// logged there) the CPU lays this stroke's dabs, and the GPU keeps sculpting
		// everything else.
		if masked && ms.bytes[.Mask].vertices < mb.vertex_capacity do return false
		if faded && ms.bytes[.Fade].vertices < mb.vertex_capacity do return false
		if table_count > 0 {
			tbytes := table_count * size_of(f32)
			if !transfer_fit(r, &sg.tables_transfer, &sg.tables_transfer_size, tbytes) do return sculpt_refused(sg, "an alpha and falloff upload buffer")
			held := sg.tables
			if !storage_fit(r, &sg.tables, &sg.tables_capacity, tbytes, {.COMPUTE_STORAGE_READ}) do return sculpt_refused(sg, "an alpha and falloff buffer")
			// A new buffer holds nothing yet.
			if sg.tables != held do clear(&sg.tables_held)
		}
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
	// The tables go up unless the buffer holds them already: the same values (by where
	// they live) for the same stroke on the same mesh, which a stroke's brush keeps.
	tables_up := table_count > 0 && len(records) > 0
	if tables_up && sg.tables_mesh == mb && len(ms.dabs) > 0 && sg.tables_stroke == ms.dabs[0].stroke && len(sg.tables_held) == len(table_of) {
		same := true
		for t, k in table_of {
			h := sg.tables_held[k]
			if raw_data(h.values) != raw_data(t.values) || len(h.values) != len(t.values) || h.first != t.first do same = false
		}
		tables_up = !same
	}
	if tables_up {
		dst = gpu_map_transfer_buffer(r.device, sg.tables_transfer, true)
		if dst == nil do return sculpt_refused(sg, "mapping the alphas and falloffs")
		out := ([^]f32)(dst)
		for t in table_of do copy(out[t.first:][:len(t.values)], t.values)
		gpu_unmap_transfer_buffer(r.device, sg.tables_transfer)
		clear(&sg.tables_held)
		append(&sg.tables_held, ..table_of[:])
		sg.tables_mesh, sg.tables_stroke = mb, ms.dabs[0].stroke
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
	// Not cycled: a frame that skips the upload reads what the last one sent.
	if tables_up do gpu_upload_to_buffer(pass, {transfer_buffer = sg.tables_transfer}, {buffer = sg.tables, size = table_count * size_of(f32)}, false)
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
		// A stroke with no mask, drawn falloff or fade binds the slabs in their place,
		// which no kernel then reads (the record's flags say).
		mask := ms.bytes[.Mask].buffer if masked else sg.slabs
		falloffs := sg.tables if table_count > 0 else sg.slabs
		fade := ms.bytes[.Fade].buffer if faded else sg.slabs
		reads := [9]^sdl.GPUBuffer{mb.indices, ms.offsets, ms.tris, sg.slabs, sg.dabs, mb.normals, mask, falloffs, fade}
		gpu_bind_compute_storage_buffers(compute, 0, &reads[0], len(reads))
		for d, i in ms.dabs {
			count := int(records[i].slabs[1])
			groups_x := max(min(count, MAX_SLAB_GROUPS_X), 1)
			groups_y := (count + groups_x - 1) / groups_x
			params := Params{dab = u32(i), groups_x = u32(groups_x), stroke = d.stroke}
			// The area, for the kinds that work along it and for any dab with an alpha,
			// which lies on its plane (sculpt.dab_lay), Smooth's and Inflate's too.
			if (d.kind != .Inflate && d.kind != .Smooth) || d.alpha != nil {
				gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Area])
				gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
				gpu_dispatch_compute(compute, u32(groups_x), u32(groups_y), 1)
				gpu_bind_compute_pipeline(compute, sg.dab_pipelines[.Reduce])
				gpu_push_compute_uniform_data(cmd, 0, &params, size_of(params))
				gpu_dispatch_compute(compute, 1, 1, 1)
			}
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
dab_record :: proc(d: Sculpt_Dab, first_slab, slab_count, table_first: u32) -> Sculpt_Dab_Record {
	flags: u32
	if d.relax do flags |= DAB_FLAG_RELAX
	if d.once do flags |= DAB_FLAG_ONCE
	if d.valleys do flags |= DAB_FLAG_VALLEYS
	if d.peaks do flags |= DAB_FLAG_PEAKS
	if d.tilt != {} do flags |= DAB_FLAG_TILT
	if d.masked do flags |= DAB_FLAG_MASK
	if d.falloff != nil && d.alpha == nil do flags |= DAB_FLAG_DRAWN
	if d.faded do flags |= DAB_FLAG_FADE
	if d.alpha != nil do flags |= DAB_FLAG_ALPHA
	if d.alpha_mirror do flags |= DAB_FLAG_MIRROR
	t := d.tilt
	return {
		center_r2     = {d.center.x, d.center.y, d.center.z, d.r2},
		view_inv_r2   = {d.view.x, d.view.y, d.view.z, d.inv_r2},
		facing_amount = {d.facing.x, d.facing.y, d.facing.z, d.amount},
		tilt0         = {t[0, 0], t[0, 1], t[0, 2], d.strength},
		tilt1         = {t[1, 0], t[1, 1], t[1, 2], d.inv_sample2},
		tilt2         = {t[2, 0], t[2, 1], t[2, 2], d.plane_offset},
		misc          = {d.plane_short[0], d.plane_short[1], d.radius, f32(table_first)},
		alpha_up      = {d.alpha_up.x, d.alpha_up.y, d.alpha_up.z, f32(d.alpha_size)},
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
	// Buffers made later in the same place start their strokes again from 1, and a brush's
	// tables may change between strokes: they go up afresh.
	if sg.tables_mesh == mb {
		clear(&sg.tables_held)
		sg.tables_mesh = nil
	}
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
	sculpt_lookup_unmap(r, mb)
	ms := &mb.sculpt
	if ms.offsets != nil do gpu_release_buffer(r.device, ms.offsets)
	if ms.tris != nil do gpu_release_buffer(r.device, ms.tris)
	if ms.heights_buffer != nil do gpu_release_buffer(r.device, ms.heights_buffer)
	if ms.shared != nil do gpu_release_buffer(r.device, ms.shared)
	ms.shared = nil
	for &held in ms.bytes {
		if held.buffer != nil do gpu_release_buffer(r.device, held.buffer)
		held = {}
	}
	ms.offsets, ms.tris, ms.lookup_version, ms.lookup_bytes = nil, nil, 0, 0
	ms.lookup_sizes, ms.lookup_done, ms.lookup_ready, ms.lookup_frames, ms.lookup_served = {}, 0, false, 0, false
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
	if sg.lookup_transfer != nil do gpu_release_transfer_buffer(r.device, sg.lookup_transfer)
	if sg.tables != nil do gpu_release_buffer(r.device, sg.tables)
	delete(sg.tables_held)
	if sg.tables_transfer != nil do gpu_release_transfer_buffer(r.device, sg.tables_transfer)
	for t in sg.bytes_transfer do if t != nil do gpu_release_transfer_buffer(r.device, t)
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
