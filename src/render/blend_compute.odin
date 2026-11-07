package render

import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "../geom"
import "../gpu"

// Smooth blend's projection on the GPU (shaders/blend_project.comp.slang): geom's
// project_vertex for every vertex of an instance's pages, written straight into its
// Blend_Pages. The host lays out what the kernel reads: the fields of the instance's group
// (spacing, hash table, samples and weights, as geom.Blend_Field holds them), the terms
// (each other instance's transform into its own space, its scale ratio, mean edge and id),
// which pair of terms is joined at what radius, and which pages to fill (the pages of the
// nodes near its field, with their table). A run here waits for the GPU and times its
// upload and its dispatch apart; the CPU's geom.blend_project stays the reference.

// The most terms (the instance and its group's others) a point's fold takes on the GPU,
// as the kernel's TERMS_MAX: a larger group is projected on the CPU.
BLEND_TERMS_MAX :: 8
// Threads per workgroup, a quarter of a page each: numthreads in the kernel.
BLEND_THREADS :: 256
#assert(BLEND_PROJECT_COMP.threadcount_x == BLEND_THREADS && BLEND_PAGE_VERTICES == 4 * BLEND_THREADS)

// The widest dispatch every device must accept; more workgroups spread over rows.
@(private = "file")
MAX_GROUPS_X :: 65535

// One term of the fold as the kernel reads it: the transform from the projected instance's
// space into the term's, the factor back, the term's mean edge in the instance's space,
// its id (the fold's tie order and the seam's owner) and its field among `fields`.
Blend_Term :: struct {
	into:  Mat4,
	ratio: f32,
	edge:  f32,
	id:    u32,
	field: u32,
}

Blend_Compute :: struct {
	pipeline: gpu.Compute_Pipeline,
	buffers:  [Blend_Project_Comp_Buffers]gpu.Buffer, // positions stays empty: it is the mesh's own
	capacity: [Blend_Project_Comp_Buffers]u32,
	failed:   bool, // the pipeline could not be made; the CPU projects
	// The fields kept on the GPU between jobs, each in a region of the samples' atlas
	// (brick_values, brick_extras) and of the tables (brick_table): a field only ever adds
	// bricks, so a job uploads those published since the last, and its table when it changed.
	resident:    [dynamic]Blend_Resident,
	atlas_slots: u32, // slots laid out in the atlas
	table_used:  u32, // table entries laid out
}

@(private)
Blend_Resident :: struct {
	field:          ^geom.Blend_Field,
	slot_first:     u32,
	slot_capacity:  u32,
	uploaded:       u32, // slots on the GPU
	table_first:    u32,
	table_capacity: u32,
	revision:       u64, // the table's revision on the GPU
	has_table:      bool,
}

// What one run cost, each part with its wait for the GPU.
Blend_Timing :: struct {
	upload_ms:  f64,
	compute_ms: f64,
	upload_kb:  f64,
}

// Matches Blend_Params in the kernel (std140).
@(private)
Blend_Params :: struct {
	vertex_count, slot_count, term_count, groups_x: u32,
	reach, self_edge:                               f32,
	slot_first:                                     u32,
	_:                                              u32,
	pair_table:                                     [BLEND_TERMS_MAX * BLEND_TERMS_MAX][4]f32,
	share_table:                                    [SHARE_VECTORS][4]f32,
}

// geom.BLEND_SHARES laid end to end, four floats a vector, as the kernel's share_table.
@(private = "file")
SHARE_VECTORS :: (len(geom.Blend_Opening) * (geom.BLEND_SHARE_STEPS + 1) + 3) / 4
#assert(SHARE_VECTORS == 97)
// The GPU layer pushes at most 4 KB a uniform block on every backend.
#assert(size_of(Blend_Params) <= 4096)

blend_compute_ready :: proc(r: ^Renderer, bc: ^Blend_Compute) -> bool {
	if bc.pipeline != 0 do return true
	if bc.failed || !r.has_device do return false
	// Exact (IEEE arithmetic, no fast maths), so the pages follow the CPU's reference.
	bc.pipeline = gpu.create_compute_pipeline_exact(BLEND_PROJECT_COMP)
	if bc.pipeline == 0 {
		log.errorf("blend compute: the pipeline could not be made (%s); Smooth blend projects on the CPU", gpu.last_error())
		bc.failed = true
		return false
	}
	return true
}

blend_compute_destroy :: proc(r: ^Renderer, bc: ^Blend_Compute) {
	if !r.has_device do return
	for b in bc.buffers do if b != 0 do gpu.release_buffer(b)
	if bc.pipeline != 0 do gpu.release_compute_pipeline(bc.pipeline)
	delete(bc.resident)
	bc^ = {}
}

// Lets go of the fields kept on the GPU (their owner is freeing them): the next job lays
// out and uploads its fields afresh.
blend_compute_forget :: proc(bc: ^Blend_Compute) {
	clear(&bc.resident)
	bc.atlas_slots, bc.table_used = 0, 0
}

// A projection laid out on the GPU (blend_compute_begin), dispatched a slice of its slots
// at a time (blend_compute_step), so a large one can spread over frames: the pages it
// fills are not shown until it is done. One job at a time per Blend_Compute.
Blend_Job :: struct {
	active:    bool,
	positions: gpu.Buffer,
	pages:     ^Blend_Pages,
	params:    Blend_Params,
	slots:     u32, // how many slots the job fills
	next:      u32, // the first slot not dispatched yet
	slot_ms:   f64, // the last slice's time per slot, for sizing the next
}

// blend_compute_begin then every slice at once: a whole projection, waited for.
blend_compute_run :: proc(
	r: ^Renderer,
	bc: ^Blend_Compute,
	positions: gpu.Buffer,
	vertex_count: u32,
	fields: []^geom.Blend_Field,
	terms: []Blend_Term,
	pairs: ^[BLEND_TERMS_MAX][BLEND_TERMS_MAX][3]f32,
	reach, self_edge: f32,
	page_table, page_list: []u32,
	bp: ^Blend_Pages,
) -> (
	timing: Blend_Timing,
	ok: bool,
) {
	job: Blend_Job
	timing = blend_compute_begin(r, bc, &job, positions, vertex_count, fields, terms, pairs, reach, self_edge, page_table, page_list, bp) or_return
	ms, done := blend_compute_step(r, bc, &job, job.slots) or_return
	timing.compute_ms = ms
	return timing, done
}

// Lays a projection out for `job`: the vertices of the pages `page_list` names (the table `page_table`, one word per
// BLEND_PAGE_VERTICES vertices, gives each its slot) of a mesh whose positions are the
// storage buffer `positions`, into `bp`. `terms[0]` is the instance itself (identity, ratio
// 1, its own field 0); `pairs[a][b]` is the radius (in its space) and fullness joining
// terms a and b, and its opening function (geom.Blend_Opening) as a float. Uploads what
// the kernel reads, on `frame` when given (the frame's command buffer: nothing waits, and
// the job's first slice must wait for a later frame, once that buffer is submitted), else
// on a command buffer of its own, waited for. Nothing is dispatched yet. False, with `bp`
// released, when the GPU refuses something; the caller then projects on the CPU.
blend_compute_begin :: proc(
	r: ^Renderer,
	bc: ^Blend_Compute,
	job: ^Blend_Job,
	positions: gpu.Buffer,
	vertex_count: u32,
	fields: []^geom.Blend_Field,
	terms: []Blend_Term,
	pairs: ^[BLEND_TERMS_MAX][BLEND_TERMS_MAX][3]f32,
	reach, self_edge: f32,
	page_table, page_list: []u32,
	bp: ^Blend_Pages,
	frame: Cmd = nil,
) -> (
	timing: Blend_Timing,
	ok: bool,
) {
	if !blend_compute_ready(r, bc) || positions == 0 || len(terms) == 0 || len(terms) > BLEND_TERMS_MAX || len(page_list) == 0 do return
	start := time.tick_now()
	// Each field's region of the atlas and of the tables, laid out afresh when one outgrows
	// its region and the buffers cannot take a new one.
	residents := make([]^Blend_Resident, len(fields), context.temp_allocator)
	for attempt in 0 ..< 2 {
		for f, i in fields {
			residents[i] = resident_of(bc, f)
			rs := residents[i]
			if need := u32(len(f.keys)); need > rs.slot_capacity {
				rs.slot_first, rs.slot_capacity, rs.uploaded = bc.atlas_slots, grown_pow2(2 * need), 0
				bc.atlas_slots += rs.slot_capacity
			}
			if size := u32(len(f.table)); size > rs.table_capacity {
				rs.table_first, rs.table_capacity, rs.has_table = bc.table_used, size, false
				bc.table_used += size
			}
		}
		fits := bc.atlas_slots * geom.BLEND_SAMPLES * 4 <= bc.capacity[.brick_values] && bc.table_used * 16 <= bc.capacity[.brick_table]
		if fits || attempt == 1 do break
		// Larger buffers next, every field laid out and uploaded again in them.
		blend_compute_forget(bc)
		for kind in ([]Blend_Project_Comp_Buffers{.brick_values, .brick_extras, .brick_table}) {
			if bc.buffers[kind] != 0 do gpu.release_buffer(bc.buffers[kind])
			bc.buffers[kind], bc.capacity[kind] = 0, 0
		}
	}
	atlas_bytes := grown_pow2(bc.atlas_slots * geom.BLEND_SAMPLES * 4)
	table_bytes := grown_pow2(bc.table_used * 16)
	for kind in ([]Blend_Project_Comp_Buffers{.brick_values, .brick_extras, .brick_table}) {
		size := table_bytes if kind == .brick_table else atlas_bytes
		if bc.buffers[kind] != 0 && size <= bc.capacity[kind] do continue
		if bc.buffers[kind] != 0 do gpu.release_buffer(bc.buffers[kind])
		bc.buffers[kind] = gpu.create_buffer({usage = {.Storage_Read}, size = size})
		bc.capacity[kind] = size if bc.buffers[kind] != 0 else 0
		if bc.buffers[kind] == 0 {
			log.errorf("blend compute: a buffer of %d KB could not be made: %s", size >> 10, gpu.last_error())
			blend_compute_forget(bc)
			return
		}
	}
	descs := make([][4]u32, len(fields), context.temp_allocator)
	for f, i in fields do descs[i] = {transmute(u32)f.h, residents[i].table_first, u32(len(f.table) - 1), residents[i].slot_first}
	rows := make([][4][4]f32, len(terms), context.temp_allocator)
	for t, i in terms {
		for r in 0 ..< 3 do rows[i][r] = {t.into[r, 0], t.into[r, 1], t.into[r, 2], t.into[r, 3]}
		rows[i][3] = {t.ratio, t.edge, transmute(f32)t.id, transmute(f32)t.field}
	}
	sources := #partial [Blend_Project_Comp_Buffers][]u8 {
		.page_list     = mem.slice_to_bytes(page_list),
		.fields        = mem.slice_to_bytes(descs),
		.terms         = mem.slice_to_bytes(rows),
	}
	for kind in Blend_Project_Comp_Buffers {
		if kind == .positions || kind == .brick_values || kind == .brick_extras || kind == .brick_table do continue
		size := u32(max(len(sources[kind]), 16))
		if size <= bc.capacity[kind] do continue
		if bc.buffers[kind] != 0 do gpu.release_buffer(bc.buffers[kind])
		bc.buffers[kind] = gpu.create_buffer({usage = {.Storage_Read}, size = size})
		bc.capacity[kind] = size if bc.buffers[kind] != 0 else 0
		if bc.buffers[kind] == 0 {
			log.errorf("blend compute: a buffer of %d KB could not be made: %s", size >> 10, gpu.last_error())
			return
		}
	}
	if !blend_pages_reserve(r, bp, u32(len(page_table)), u32(len(page_list))) do return
	cmd := gpu.Cmd(frame) if frame != nil else gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("blend compute: no command buffer: %s", gpu.last_error())
		return
	}
	uploaded := len(page_table) * size_of(u32)
	upload_ok := gpu.upload(cmd, bp.table, 0, mem.slice_to_bytes(page_table))
	for kind in Blend_Project_Comp_Buffers {
		src := sources[kind]
		if len(src) == 0 do continue
		upload_ok = upload_ok && gpu.upload(cmd, bc.buffers[kind], 0, src)
		uploaded += len(src)
	}
	// Each field's bricks published since its last upload, and its table when it moved on.
	for f, i in fields {
		rs := residents[i]
		published := u32(len(f.keys))
		if published > rs.uploaded {
			lo, hi := int(rs.uploaded) * geom.BLEND_SAMPLES, int(published) * geom.BLEND_SAMPLES
			at := (rs.slot_first + rs.uploaded) * geom.BLEND_SAMPLES * 4
			upload_ok = upload_ok && gpu.upload(cmd, bc.buffers[.brick_values], at, mem.slice_to_bytes(f.values[lo:hi]))
			upload_ok = upload_ok && gpu.upload(cmd, bc.buffers[.brick_extras], at, mem.slice_to_bytes(f.extras[lo:hi]))
			uploaded += (hi - lo) * 8
			rs.uploaded = published
		}
		if !rs.has_table || rs.revision != f.revision {
			entries := make([][4]u32, len(f.table), context.temp_allocator)
			for k, j in f.table do entries[j] = {u32(k), u32(k >> 32), u32(f.slots[j]), 0}
			upload_ok = upload_ok && gpu.upload(cmd, bc.buffers[.brick_table], rs.table_first * 16, mem.slice_to_bytes(entries))
			uploaded += len(entries) * 16
			rs.revision, rs.has_table = f.revision, true
		}
	}
	if !upload_ok {
		log.errorf("blend compute: upload failed: %s", gpu.last_error())
		if frame == nil do _ = gpu.cancel_command_buffer(cmd)
		return
	}
	if frame == nil && !blend_submit_wait(cmd) do return
	timing.upload_ms = time.duration_milliseconds(time.tick_since(start))
	timing.upload_kb = f64(uploaded) / 1024
	params := Blend_Params {
		vertex_count = vertex_count,
		term_count   = u32(len(terms)),
		reach        = reach,
		self_edge    = self_edge,
	}
	for o in geom.Blend_Opening {
		for share, i in geom.BLEND_SHARES[o] {
			at := int(o) * (geom.BLEND_SHARE_STEPS + 1) + i
			params.share_table[at >> 2][at & 3] = share
		}
	}
	for a in 0 ..< BLEND_TERMS_MAX do for b in 0 ..< BLEND_TERMS_MAX {
		params.pair_table[a * BLEND_TERMS_MAX + b] = {pairs[a][b][0], pairs[a][b][1], pairs[a][b][2], 0}
	}
	job^ = {active = true, positions = positions, pages = bp, params = params, slots = u32(len(page_list))}
	return timing, true
}

// Dispatches the job's next `max_slots` slots and waits for them, timing it. `done` once
// every slot is filled: the job ends and its pages' version moves on. False, with the job
// ended, when the GPU refuses it.
blend_compute_step :: proc(r: ^Renderer, bc: ^Blend_Compute, job: ^Blend_Job, max_slots: u32, frame: Cmd = nil) -> (ms: f64, done: bool, ok: bool) {
	if !job.active do return 0, true, true
	start := time.tick_now()
	count := min(max(max_slots, 1), job.slots - job.next)
	cmd := frame
	if cmd == nil do cmd = gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("blend compute: no command buffer: %s", gpu.last_error())
		job.active = false
		return
	}
	// On the frame's command buffer the slice is timed by the GPU's own timestamps, read a
	// few frames late (the Blend span), and nothing waits for it.
	if frame != nil {
		gpu.push_debug_group(cmd, "Smooth blend")
		span_begin(cmd, .Blend)
	}
	groups := int(count) * (BLEND_PAGE_VERTICES / BLEND_THREADS)
	groups_x := min(groups, MAX_GROUPS_X)
	groups_y := (groups + groups_x - 1) / groups_x
	params := job.params
	params.slot_first = job.next
	params.slot_count = job.next + count
	params.groups_x = u32(groups_x)
	push_compute(cmd, Blend_Project_Comp_Uniforms.Blend_Params, &params)
	writes := [Blend_Project_Comp_Write_Buffers]gpu.Storage_Buffer_Binding{.pages = {buffer = job.pages.pages}}
	pass := begin_compute(cmd, &writes)
	gpu.bind_compute_pipeline(pass, bc.pipeline)
	reads := bc.buffers
	reads[.positions] = job.positions
	bind_compute_storage(pass, &reads)
	gpu.dispatch_compute(pass, u32(groups_x), u32(groups_y), 1)
	gpu.end_compute_pass(pass)
	if frame != nil {
		span_end(cmd, .Blend)
		gpu.pop_debug_group(cmd)
	} else {
		if !blend_submit_wait(cmd) {
			job.active = false
			return
		}
		ms = time.duration_milliseconds(time.tick_since(start))
		job.slot_ms = ms / f64(count)
	}
	job.next += count
	if job.next < job.slots do return ms, false, true
	job.active = false
	r.last_version += 1
	job.pages.version = r.last_version
	return ms, true, true
}

// Makes or grows an instance's page buffers to hold a table of `table_words` words and
// `pages` pages, by powers of two; false, with them released, when the GPU refuses.
@(private)
blend_pages_reserve :: proc(r: ^Renderer, bp: ^Blend_Pages, table_words, pages: u32) -> bool {
	usage := gpu.Buffer_Usages{.Graphics_Storage_Read, .Storage_Read, .Storage_Write}
	if bp.table == 0 || bp.table_words < table_words {
		if bp.table != 0 do gpu.release_buffer(bp.table)
		bp.table_words = grown_pow2(table_words)
		bp.table = gpu.create_buffer({usage = usage, size = bp.table_words * size_of(u32)})
		gpu.set_buffer_name(bp.table, "Blend page table")
	}
	if bp.pages == 0 || bp.page_capacity < max(pages, 1) {
		if bp.pages != 0 do gpu.release_buffer(bp.pages)
		bp.page_capacity = grown_pow2(max(pages, 1))
		bp.pages = gpu.create_buffer({usage = usage, size = bp.page_capacity * BLEND_PAGE_VERTICES * size_of(Blend_Entry)})
		gpu.set_buffer_name(bp.pages, "Blend pages")
	}
	if bp.table == 0 || bp.pages == 0 {
		log.errorf("blend pages: buffer creation failed: %s", gpu.last_error())
		blend_pages_destroy(bp)
		return false
	}
	return true
}

@(private)
grown_pow2 :: proc(n: u32) -> u32 {
	c := u32(64)
	for c < n do c *= 2
	return c
}

// The first `slots` pages of `bp` read back, waiting for the GPU: for checking the kernel
// against the CPU. Nil when the GPU refuses. Allocates with `allocator`.
blend_pages_read :: proc(r: ^Renderer, bp: ^Blend_Pages, slots: u32, allocator := context.allocator) -> []Blend_Entry {
	if bp.pages == 0 || slots == 0 do return nil
	cmd := gpu.acquire_command_buffer()
	if cmd == nil do return nil
	rb := gpu.download_buffer(cmd, bp.pages, 0, slots * BLEND_PAGE_VERTICES * size_of(Blend_Entry))
	defer gpu.release_readback(rb)
	if !blend_submit_wait(cmd) do return nil
	bytes, ready := gpu.readback(rb)
	if !ready || len(bytes) == 0 do return nil
	return slice.clone(slice.reinterpret([]Blend_Entry, bytes), allocator)
}

@(private = "file")
blend_submit_wait :: proc(cmd: gpu.Cmd) -> bool {
	ticket, ok := gpu.submit(cmd)
	if !ok {
		log.errorf("blend compute: submit failed: %s", gpu.last_error())
		return false
	}
	if !gpu.wait(ticket) {
		log.errorf("blend compute: the wait failed: %s", gpu.last_error())
		return false
	}
	return true
}

// The field's region on the GPU, made (empty) the first time a job names the field.
@(private = "file")
resident_of :: proc(bc: ^Blend_Compute, f: ^geom.Blend_Field) -> ^Blend_Resident {
	for &rs in bc.resident do if rs.field == f do return &rs
	append(&bc.resident, Blend_Resident{field = f})
	return &bc.resident[len(bc.resident) - 1]
}
