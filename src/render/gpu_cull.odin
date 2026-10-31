package render

import "core:log"
import "core:slice"

import sdl "vendor:sdl3"

import "../geom"

// GPU culling (native GPU plan 2.4 and 2.5; design notes/native-gpu/gpu-culling-design.md):
// where Gpu_Caps.gpu_cull and Renderer.gpu_cull, prepare_draws hands an object's chunks
// to two kernels (cull.slang) instead of walking them, for an object with chunk groups,
// nothing hidden and no simplified drawing in this pass. The kernels make the same tests
// as geom.cull_chunks_grouped and write one indirect command a drawn chunk, in the chunks'
// order, with their number in a header the draw reads its count from: the CPU neither
// walks the chunks nor uploads commands, and culled chunks cost the GPU nothing.
//
// Each Mesh_Buffers keeps a copy of the chunks and groups on the GPU, made again for
// another layout and otherwise only for the groups stamped since (sculptor_chunk_stamps),
// so a stroke uploads a few groups. Its indirect buffer holds the header (the command
// count, the drawn triangles and the chunks left out of the view and facing away), then
// the commands.
//
// The stats come back late: each pass's headers are copied to a ring of download buffers
// and read CULL_SLOTS frames on, by when that frame is done, and added to the pass with the
// same number in its frame (cull_call); the numbers are those of a few frames back.

// Vulkan only, so no Metal source is made for them.
when ODIN_OS != .Darwin {
	CULL_COUNT_COMP_CODE :: #load("shaders/cull_count.comp.spv")
	CULL_WRITE_COMP_CODE :: #load("shaders/cull_write.comp.spv")
}

// Words of the indirect buffer's header: one command's size, so the commands after it
// keep their stride.
CULL_HEADER :: size_of(sdl.GPUIndexedIndirectDrawCommand)
// More slots than frames may be in flight, so a slot's frame is done when it comes round.
CULL_SLOTS :: FRAMES_IN_FLIGHT_MAX + 1
// Headers one frame reads back, and passes whose stats it keeps apart.
CULL_ENTRIES :: 256
CULL_CALLS :: 32

#assert(size_of(geom.Chunk) == 48) // twelve words, as cull.slang reads a record

Cull_Uniforms :: struct {
	planes: [6][4]f32,
	eye:    [4]f32,
	counts: [4]u32,
}

// One pass's late stats: commands, drawn triangles, chunks out of the view, facing away.
Cull_Late :: [4]u64

Cull_Slot :: struct {
	download: ^sdl.GPUTransferBuffer,
	calls:    [CULL_ENTRIES]u8, // the pass each header belongs to
	count:    int,
}

Gpu_Cull :: struct {
	count_pipeline, write_pipeline: ^sdl.GPUComputePipeline,
	failed:        bool, // the kernels or the ring could not be made: the CPU culls
	transfer:      ^sdl.GPUTransferBuffer, // chunk records on their way up
	transfer_size: u32,
	slots:         [CULL_SLOTS]Cull_Slot,
	slot:          int,
	call:          int, // passes this frame that culled on the GPU
	late:          [CULL_CALLS]Cull_Late,
	culls:         int, // objects culled on the GPU, for the exit stats
	// --dump-cull: every mesh culled on the GPU checks its last commands against the CPU's
	// culling at exit (gpu_cull_check).
	check:         bool,
	checked:       [dynamic]^Mesh_Buffers,
}

// What a Mesh_Buffers keeps for GPU culling.
Mesh_Cull :: struct {
	records, groups, totals: ^sdl.GPUBuffer,
	chunk_capacity, group_capacity: u32,
	layout: u64, // the sculptor's chunk layout `records` holds; 0 for none
	stamp:  u64, // the newest group stamp uploaded
	culled: bool, // this pass's commands came from the kernels
	// --dump-cull: the last commands, read back at exit, and the CPU's runs for that pass.
	download: ^sdl.GPUTransferBuffer,
	download_size: u32,
	expect:   [dynamic]geom.Index_Range,
}

// Starts a frame's GPU culling: reads the headers of the frame CULL_SLOTS back into the
// late stats. Call once a frame, before anything draws.
gpu_cull_frame :: proc(r: ^Renderer) {
	g := &r.gpu_culling
	g.slot = (g.slot + 1) % CULL_SLOTS
	g.call = 0
	g.late = {}
	s := &g.slots[g.slot]
	if s.count == 0 || s.download == nil do return
	defer s.count = 0
	words := ([^][5]u32)(gpu_map_transfer_buffer(r.device, s.download, false))
	if words == nil do return
	for e in 0 ..< s.count {
		h := words[e]
		g.late[s.calls[e]] += {u64(h[0]), u64(h[1]), u64(h[2]), u64(h[3])}
	}
	gpu_unmap_transfer_buffer(r.device, s.download)
}

// Whether prepare_draws may cull `item` on the GPU in this pass.
@(private)
gpu_cull_wanted :: proc(r: ^Renderer, item: Draw_Item, simplify: bool) -> bool {
	groups := len(item.chunk_groups)
	return r.gpu_cull && r.caps.gpu_cull && !r.gpu_culling.failed && !simplify && item.hidden == nil &&
		groups > 0 && groups <= 65535 && len(item.group_stamps) == groups && item.chunk_layout != 0
}

// Culls one item on the GPU into its indirect buffer, recording into `cmd` outside any
// pass; false, with nothing recorded, where a buffer or kernel was refused (the caller
// culls it on the CPU).
@(private)
gpu_cull_item :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, item: Draw_Item, clip: Mat4, eye: [3]f32) -> bool {
	g := &r.gpu_culling
	mb, c := item.mesh, &item.mesh.cull
	chunks, groups := u32(len(item.chunks)), u32(len(item.chunk_groups))
	if !gpu_cull_kernels(r) || !indirect_ensure(r, mb, chunks + 1) || !gpu_cull_buffers(r, mb, chunks, groups) || !gpu_cull_upload(r, cmd, item) {
		return false
	}
	u := Cull_Uniforms{planes = geom.frustum_planes(clip), eye = {eye.x, eye.y, eye.z, 0}, counts = {chunks, groups, 0, 0}}
	debug_group(cmd, "GPU culling")
	write := sdl.GPUStorageBufferReadWriteBinding{buffer = c.totals}
	pass := gpu_begin_compute_pass(cmd, nil, 0, &write, 1)
	gpu_bind_compute_pipeline(pass, g.count_pipeline)
	reads := [3]^sdl.GPUBuffer{c.records, c.groups, c.totals}
	gpu_bind_compute_storage_buffers(pass, 0, &reads[0], 2)
	gpu_push_compute_uniform_data(cmd, 0, &u, size_of(u))
	gpu_dispatch_compute(pass, groups, 1, 1)
	gpu_end_compute_pass(pass)
	write = {buffer = mb.indirect}
	pass = gpu_begin_compute_pass(cmd, nil, 0, &write, 1)
	gpu_bind_compute_pipeline(pass, g.write_pipeline)
	gpu_bind_compute_storage_buffers(pass, 0, &reads[0], 3)
	gpu_push_compute_uniform_data(cmd, 0, &u, size_of(u))
	gpu_dispatch_compute(pass, groups, 1, 1)
	gpu_end_compute_pass(pass)
	c.culled = true
	g.culls += 1

	// The header, for this pass's stats a few frames on.
	s := &g.slots[g.slot]
	copy_pass: ^sdl.GPUCopyPass
	if s.download == nil do s.download = gpu_create_transfer_buffer(r.device, {usage = .DOWNLOAD, size = CULL_ENTRIES * CULL_HEADER})
	if s.download != nil && s.count < CULL_ENTRIES && g.call < CULL_CALLS {
		copy_pass = gpu_begin_copy_pass(cmd)
		gpu_download_from_buffer(copy_pass, {buffer = mb.indirect, size = CULL_HEADER}, {transfer_buffer = s.download, offset = u32(s.count * CULL_HEADER)})
		s.calls[s.count] = u8(g.call)
		s.count += 1
	}
	if g.check do gpu_cull_keep(r, cmd, &copy_pass, item, clip, eye)
	if copy_pass != nil do gpu_end_copy_pass(copy_pass)
	return true
}

// The two kernels, made on first use; false (and the CPU culls from then on) where the
// device refuses them.
@(private = "file")
gpu_cull_kernels :: proc(r: ^Renderer) -> bool {
	g := &r.gpu_culling
	if g.count_pipeline != nil && g.write_pipeline != nil do return true
	when ODIN_OS != .Darwin {
		info := sdl.GPUComputePipelineCreateInfo {
			code_size = len(CULL_COUNT_COMP_CODE), code = raw_data(CULL_COUNT_COMP_CODE), entrypoint = SHADER_ENTRY, format = SHADER_FORMAT,
			num_readonly_storage_buffers = 2, num_readwrite_storage_buffers = 1, num_uniform_buffers = 1,
			threadcount_x = geom.CHUNK_GROUP, threadcount_y = 1, threadcount_z = 1,
		}
		g.count_pipeline = gpu_create_compute_pipeline(r.device, info)
		info.code_size, info.code, info.num_readonly_storage_buffers = len(CULL_WRITE_COMP_CODE), raw_data(CULL_WRITE_COMP_CODE), 3
		g.write_pipeline = gpu_create_compute_pipeline(r.device, info)
	}
	if g.count_pipeline == nil || g.write_pipeline == nil {
		log.warnf("GPU culling: the kernels could not be made (%s); the CPU culls", sdl.GetError())
		g.failed = true
		return false
	}
	return true
}

// The mesh's copy of the chunks and groups, and the groups' totals, for `chunks` chunks.
@(private = "file")
gpu_cull_buffers :: proc(r: ^Renderer, mb: ^Mesh_Buffers, chunks, groups: u32) -> bool {
	c := &mb.cull
	if c.records != nil && c.chunk_capacity >= chunks && c.group_capacity >= groups do return true
	gpu_cull_release(r, mb)
	c.records = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = chunks * size_of(geom.Chunk)})
	c.groups = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ}, size = groups * size_of(geom.Chunk)})
	c.totals = gpu_create_buffer(r.device, {usage = {.COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE}, size = groups * size_of([4]u32)})
	if c.records == nil || c.groups == nil || c.totals == nil {
		log.errorf("GPU culling: buffers for %d chunks were refused (%s)", chunks, sdl.GetError())
		gpu_cull_release(r, mb)
		return false
	}
	c.chunk_capacity, c.group_capacity = chunks, groups
	return true
}

// Lets go of a mesh's GPU culling buffers; it uploads everything again on its next cull.
@(private)
gpu_cull_release :: proc(r: ^Renderer, mb: ^Mesh_Buffers) {
	c := &mb.cull
	if c.records != nil do gpu_release_buffer(r.device, c.records)
	if c.groups != nil do gpu_release_buffer(r.device, c.groups)
	if c.totals != nil do gpu_release_buffer(r.device, c.totals)
	c.records, c.groups, c.totals, c.chunk_capacity, c.group_capacity, c.layout, c.stamp = nil, nil, nil, 0, 0, 0, 0
}

// Brings the mesh's copy of the chunks up to date: all of them for another layout, else
// the groups stamped after the newest it has.
@(private = "file")
gpu_cull_upload :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, item: Draw_Item) -> bool {
	g, c := &r.gpu_culling, &item.mesh.cull
	all := c.layout != item.chunk_layout
	// Runs of groups to send, each a first group and how many.
	runs := make([dynamic][2]int, context.temp_allocator)
	newest := c.stamp
	for stamp, k in item.group_stamps {
		newest = max(newest, stamp)
		if !all && stamp <= c.stamp do continue
		if n := len(runs); n > 0 && runs[n - 1][0] + runs[n - 1][1] == k {
			runs[n - 1][1] += 1
		} else {
			append(&runs, [2]int{k, 1})
		}
	}
	if len(runs) == 0 do return true
	bytes := 0
	for run in runs {
		lo, hi := run[0] * geom.CHUNK_GROUP, min((run[0] + run[1]) * geom.CHUNK_GROUP, len(item.chunks))
		bytes += (hi - lo + run[1]) * size_of(geom.Chunk)
	}
	if g.transfer == nil || g.transfer_size < u32(bytes) {
		if g.transfer != nil do gpu_release_transfer_buffer(r.device, g.transfer)
		g.transfer_size = u32(bytes + bytes / 4)
		g.transfer = gpu_create_transfer_buffer(r.device, {usage = .UPLOAD, size = g.transfer_size})
		if g.transfer == nil {
			log.errorf("GPU culling: an upload buffer of %d KB was refused (%s)", g.transfer_size >> 10, sdl.GetError())
			g.transfer_size = 0
			return false
		}
	}
	dst := ([^]geom.Chunk)(gpu_map_transfer_buffer(r.device, g.transfer, true))
	if dst == nil do return false
	at := 0
	for run in runs {
		lo, hi := run[0] * geom.CHUNK_GROUP, min((run[0] + run[1]) * geom.CHUNK_GROUP, len(item.chunks))
		copy(dst[at:][:hi - lo], item.chunks[lo:hi])
		at += hi - lo
		copy(dst[at:][:run[1]], item.chunk_groups[run[0]:][:run[1]])
		at += run[1]
	}
	gpu_unmap_transfer_buffer(r.device, g.transfer)
	// In place: the kernels of an earlier pass read the copy before this, in order.
	pass := gpu_begin_copy_pass(cmd)
	at = 0
	for run in runs {
		lo, hi := run[0] * geom.CHUNK_GROUP, min((run[0] + run[1]) * geom.CHUNK_GROUP, len(item.chunks))
		gpu_upload_to_buffer(pass, {transfer_buffer = g.transfer, offset = u32(at * size_of(geom.Chunk))}, {buffer = c.records, offset = u32(lo * size_of(geom.Chunk)), size = u32((hi - lo) * size_of(geom.Chunk))}, false)
		at += hi - lo
		gpu_upload_to_buffer(pass, {transfer_buffer = g.transfer, offset = u32(at * size_of(geom.Chunk))}, {buffer = c.groups, offset = u32(run[0] * size_of(geom.Chunk)), size = u32(run[1] * size_of(geom.Chunk))}, false)
		at += run[1]
	}
	gpu_end_copy_pass(pass)
	c.layout, c.stamp = item.chunk_layout, newest
	return true
}

// --dump-cull: keeps what the CPU's culling gives for this pass and copies the kernels'
// commands down, for gpu_cull_check at exit.
@(private = "file")
gpu_cull_keep :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, copy_pass: ^^sdl.GPUCopyPass, item: Draw_Item, clip: Mat4, eye: [3]f32) {
	mb, c := item.mesh, &item.mesh.cull
	size := u32(CULL_HEADER * (len(item.chunks) + 1))
	if c.download == nil || c.download_size < size {
		if c.download != nil do gpu_release_transfer_buffer(r.device, c.download)
		c.download = gpu_create_transfer_buffer(r.device, {usage = .DOWNLOAD, size = size})
		c.download_size = size if c.download != nil else 0
		if c.download == nil do return
	}
	if !slice.contains(r.gpu_culling.checked[:], mb) do append(&r.gpu_culling.checked, mb)
	clear(&c.expect)
	_ = geom.cull_chunks_grouped(item.chunks, item.chunk_groups, clip, eye, &c.expect)
	if copy_pass^ == nil do copy_pass^ = gpu_begin_copy_pass(cmd)
	gpu_download_from_buffer(copy_pass^, {buffer = mb.indirect, size = size}, {transfer_buffer = c.download})
}

// --dump-cull, at exit: compares each mesh's last commands with the CPU's runs for the
// same pass. Returns the meshes checked, the commands, and the triangles the two disagree
// on (drawn by one and not the other).
gpu_cull_check :: proc(r: ^Renderer) -> (meshes, commands, mismatch: int) {
	_ = gpu_wait_for_idle(r.device)
	for mb in r.gpu_culling.checked {
		c := &mb.cull
		words := ([^][5]u32)(gpu_map_transfer_buffer(r.device, c.download, false))
		if words == nil do continue
		got := make([dynamic]geom.Index_Range, context.temp_allocator)
		n := int(words[0][0])
		for k in 1 ..= n do geom.append_range(&got, words[k][2], words[k][0])
		gpu_unmap_transfer_buffer(r.device, c.download)
		meshes += 1
		commands += n
		mismatch += ranges_apart(got[:], c.expect[:]) / 3
	}
	return
}

// Indices covered by one sorted list of ranges and not the other.
@(private = "file")
ranges_apart :: proc(a, b: []geom.Index_Range) -> int {
	Edge :: struct {
		at:    u32,
		delta: int,
	}
	edges := make([dynamic]Edge, context.temp_allocator)
	for x in a do append(&edges, Edge{x.first_index, 1}, Edge{x.first_index + x.index_count, -1})
	for x in b do append(&edges, Edge{x.first_index, 2}, Edge{x.first_index + x.index_count, -2})
	slice.sort_by(edges[:], proc(p, q: Edge) -> bool {return p.at < q.at})
	apart, depth_a, depth_b, last := 0, 0, 0, u32(0)
	for e in edges {
		if (depth_a > 0) != (depth_b > 0) do apart += int(e.at - last)
		last = e.at
		if e.delta == 1 || e.delta == -1 do depth_a += e.delta
		else do depth_b += e.delta / 2
	}
	return apart
}

// Releases the kernels, the upload buffer and the ring.
gpu_cull_destroy :: proc(r: ^Renderer) {
	g := &r.gpu_culling
	if g.count_pipeline != nil do gpu_release_compute_pipeline(r.device, g.count_pipeline)
	if g.write_pipeline != nil do gpu_release_compute_pipeline(r.device, g.write_pipeline)
	if g.transfer != nil do gpu_release_transfer_buffer(r.device, g.transfer)
	for s in g.slots do if s.download != nil do gpu_release_transfer_buffer(r.device, s.download)
	delete(g.checked)
	g^ = {culls = g.culls, check = g.check}
}
