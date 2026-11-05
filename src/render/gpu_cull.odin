package render

import "../gpu"
import "core:log"
import "core:mem"
import "core:slice"

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
// The stats come back late: each pass's header is read back (gpu.download_buffer) into a
// ring of slots and read CULL_SLOTS frames on, by when that frame is done, and added to the pass with the
// same number in its frame (cull_call); the numbers are those of a few frames back.

// The kernels, CULL_COUNT_COMP and CULL_WRITE_COMP, are Vulkan's only, so no Metal source is
// made for them; their groups are the chunk groups.
when gpu.VULKAN do #assert(CULL_COUNT_COMP.threadcount_x == geom.CHUNK_GROUP && CULL_WRITE_COMP.threadcount_x == geom.CHUNK_GROUP)

// Words of the indirect buffer's header: one command's size, so the commands after it
// keep their stride.
CULL_HEADER :: size_of(gpu.Indexed_Indirect_Draw)
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
	headers: [CULL_ENTRIES]gpu.Readback,
	calls:   [CULL_ENTRIES]u8, // the pass each header belongs to
	count:   int,
}

Gpu_Cull :: struct {
	count_pipeline, write_pipeline: gpu.Compute_Pipeline,
	failed:        bool, // the kernels or the ring could not be made: the CPU culls
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
	records, groups, totals: gpu.Buffer,
	chunk_capacity, group_capacity: u32,
	layout: u64, // the sculptor's chunk layout `records` holds; 0 for none
	stamp:  u64, // the newest group stamp uploaded
	culled: bool, // this pass's commands came from the kernels
	// --dump-cull: the last commands, read back at exit, and the CPU's runs for that pass.
	download: gpu.Readback,
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
	defer s.count = 0
	for e in 0 ..< s.count {
		// A frame still on the GPU this late keeps its stats out rather than wait.
		if bytes, ready := gpu.readback(s.headers[e]); ready && len(bytes) == CULL_HEADER {
			h := ([^]u32)(raw_data(bytes))
			g.late[s.calls[e]] += {u64(h[0]), u64(h[1]), u64(h[2]), u64(h[3])}
		}
		gpu.release_readback(s.headers[e])
		s.headers[e] = 0
	}
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
gpu_cull_item :: proc(r: ^Renderer, cmd: gpu.Cmd, item: Draw_Item, clip: Mat4, eye: [3]f32) -> bool {
	g := &r.gpu_culling
	mb, c := item.mesh, &item.mesh.cull
	chunks, groups := u32(len(item.chunks)), u32(len(item.chunk_groups))
	if !gpu_cull_kernels(r) || !indirect_ensure(r, mb, chunks + 1) || !gpu_cull_buffers(r, mb, chunks, groups) || !gpu_cull_upload(r, cmd, item) {
		return false
	}
	u := Cull_Uniforms{planes = geom.frustum_planes(clip), eye = {eye.x, eye.y, eye.z, 0}, counts = {chunks, groups, 1 if r.caps.barycentric else 0, 0}}
	debug_group(cmd, "GPU culling")
	totals := [Cull_Count_Comp_Write_Buffers]gpu.Storage_Buffer_Binding{.totals = {buffer = c.totals}}
	pass := begin_compute(cmd, &totals)
	gpu.bind_compute_pipeline(pass, g.count_pipeline)
	counted := [Cull_Count_Comp_Buffers]gpu.Buffer{.chunks = c.records, .groups = c.groups}
	bind_compute_storage(pass, &counted)
	push_compute(cmd, Cull_Count_Comp_Uniforms.Cull_Uniforms, &u)
	gpu.dispatch_compute(pass, groups, 1, 1)
	gpu.end_compute_pass(pass)
	commands := [Cull_Write_Comp_Write_Buffers]gpu.Storage_Buffer_Binding{.commands = {buffer = mb.indirect}}
	pass = begin_compute(cmd, &commands)
	gpu.bind_compute_pipeline(pass, g.write_pipeline)
	written := [Cull_Write_Comp_Buffers]gpu.Buffer{.chunks = c.records, .groups = c.groups, .totals = c.totals}
	bind_compute_storage(pass, &written)
	push_compute(cmd, Cull_Write_Comp_Uniforms.Cull_Uniforms, &u)
	gpu.dispatch_compute(pass, groups, 1, 1)
	gpu.end_compute_pass(pass)
	c.culled = true
	g.culls += 1

	// The header, for this pass's stats a few frames on.
	s := &g.slots[g.slot]
	if s.count < CULL_ENTRIES && g.call < CULL_CALLS {
		if rb := gpu.download_buffer(cmd, mb.indirect, 0, CULL_HEADER); rb != 0 {
			s.headers[s.count], s.calls[s.count] = rb, u8(g.call)
			s.count += 1
		}
	}
	if g.check do gpu_cull_keep(r, cmd, item, clip, eye)
	return true
}

// The two kernels, made on first use; false (and the CPU culls from then on) where the
// device refuses them.
@(private = "file")
gpu_cull_kernels :: proc(r: ^Renderer) -> bool {
	g := &r.gpu_culling
	if g.count_pipeline != 0 && g.write_pipeline != 0 do return true
	when gpu.VULKAN {
		g.count_pipeline = gpu.create_compute_pipeline(CULL_COUNT_COMP)
		g.write_pipeline = gpu.create_compute_pipeline(CULL_WRITE_COMP)
	}
	if g.count_pipeline == 0 || g.write_pipeline == 0 {
		log.warnf("GPU culling: the kernels could not be made (%s); the CPU culls", gpu.last_error())
		g.failed = true
		return false
	}
	return true
}

// The mesh's copy of the chunks and groups, and the groups' totals, for `chunks` chunks.
@(private = "file")
gpu_cull_buffers :: proc(r: ^Renderer, mb: ^Mesh_Buffers, chunks, groups: u32) -> bool {
	c := &mb.cull
	if c.records != 0 && c.chunk_capacity >= chunks && c.group_capacity >= groups do return true
	gpu_cull_release(r, mb)
	c.records = gpu.create_buffer({usage = {.Storage_Read}, size = chunks * size_of(geom.Chunk)})
	c.groups = gpu.create_buffer({usage = {.Storage_Read}, size = groups * size_of(geom.Chunk)})
	c.totals = gpu.create_buffer({usage = {.Storage_Read, .Storage_Write}, size = groups * size_of([4]u32)})
	if c.records == 0 || c.groups == 0 || c.totals == 0 {
		log.errorf("GPU culling: buffers for %d chunks were refused (%s)", chunks, gpu.last_error())
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
	if c.records != 0 do gpu.release_buffer(c.records)
	if c.groups != 0 do gpu.release_buffer(c.groups)
	if c.totals != 0 do gpu.release_buffer(c.totals)
	c.records, c.groups, c.totals, c.chunk_capacity, c.group_capacity, c.layout, c.stamp = 0, 0, 0, 0, 0, 0, 0
}

// Brings the mesh's copy of the chunks up to date: all of them for another layout, else
// the groups stamped after the newest it has.
@(private = "file")
gpu_cull_upload :: proc(r: ^Renderer, cmd: gpu.Cmd, item: Draw_Item) -> bool {
	c := &item.mesh.cull
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
	// In place: the kernels of an earlier pass read the copy before this, in order.
	for run in runs {
		lo, hi := run[0] * geom.CHUNK_GROUP, min((run[0] + run[1]) * geom.CHUNK_GROUP, len(item.chunks))
		if !gpu.upload(cmd, c.records, u32(lo * size_of(geom.Chunk)), mem.slice_to_bytes(item.chunks[lo:hi])) || !gpu.upload(cmd, c.groups, u32(run[0] * size_of(geom.Chunk)), mem.slice_to_bytes(item.chunk_groups[run[0]:][:run[1]])) {
			log.errorf("GPU culling: the chunks' upload was refused (%s)", gpu.last_error())
			return false
		}
	}
	c.layout, c.stamp = item.chunk_layout, newest
	return true
}

// --dump-cull: keeps what the CPU's culling gives for this pass and copies the kernels'
// commands down, for gpu_cull_check at exit.
@(private = "file")
gpu_cull_keep :: proc(r: ^Renderer, cmd: gpu.Cmd, item: Draw_Item, clip: Mat4, eye: [3]f32) {
	mb, c := item.mesh, &item.mesh.cull
	size := u32(CULL_HEADER * (len(item.chunks) + 1))
	gpu.release_readback(c.download)
	c.download = gpu.download_buffer(cmd, mb.indirect, 0, size)
	if c.download == 0 do return
	if !slice.contains(r.gpu_culling.checked[:], mb) do append(&r.gpu_culling.checked, mb)
	clear(&c.expect)
	_ = geom.cull_chunks_grouped(item.chunks, item.chunk_groups, clip, eye, &c.expect)
}

// --dump-cull, at exit: compares each mesh's last commands with the CPU's runs for the
// same pass. Returns the meshes checked, the commands, and the triangles the two disagree
// on (drawn by one and not the other).
gpu_cull_check :: proc(r: ^Renderer) -> (meshes, commands, mismatch: int) {
	_ = gpu.wait_for_idle()
	for mb in r.gpu_culling.checked {
		c := &mb.cull
		bytes, _ := gpu.readback(c.download)
		if bytes == nil do continue
		words := ([^][5]u32)(raw_data(bytes))
		got := make([dynamic]geom.Index_Range, context.temp_allocator)
		n := int(words[0][0])
		for k in 1 ..= n do geom.append_range(&got, words[k][2], words[k][0])
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

// Releases the kernels and the ring.
gpu_cull_destroy :: proc(r: ^Renderer) {
	g := &r.gpu_culling
	if g.count_pipeline != 0 do gpu.release_compute_pipeline(g.count_pipeline)
	if g.write_pipeline != 0 do gpu.release_compute_pipeline(g.write_pipeline)
	for &s in g.slots do for rb in s.headers[:s.count] do gpu.release_readback(rb)
	delete(g.checked)
	g^ = {culls = g.culls, check = g.check}
}
