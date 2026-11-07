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
}

// What one run cost, each part with its wait for the GPU.
Blend_Timing :: struct {
	upload_ms:  f64,
	compute_ms: f64,
	upload_kb:  f64,
}

// Matches Blend_Params in the kernel (std140).
@(private = "file")
Blend_Params :: struct {
	vertex_count, slot_count, term_count, groups_x: u32,
	reach, self_edge:                               f32,
	_:                                              [2]u32,
	pair_table:                                     [BLEND_TERMS_MAX * BLEND_TERMS_MAX][4]f32,
}

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
	bc^ = {}
}

// Projects the vertices of the pages `page_list` names (the table `page_table`, one word per
// BLEND_PAGE_VERTICES vertices, gives each its slot) of a mesh whose positions are the
// storage buffer `positions`, into `bp`. `terms[0]` is the instance itself (identity, ratio
// 1, its own field 0); `pairs[a][b]` is the radius (in its space) and fullness joining
// terms a and b, and its opening function (geom.Blend_Opening) as a float. Waits for the GPU. False, with nothing changed but `bp` released, when
// the GPU refuses something; the caller then projects on the CPU.
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
	if !blend_compute_ready(r, bc) || positions == 0 || len(terms) == 0 || len(terms) > BLEND_TERMS_MAX || len(page_list) == 0 do return
	start := time.tick_now()
	// The fields, laid end to end: each one's table, slots and samples after the last's.
	descs := make([][4]u32, len(fields), context.temp_allocator)
	table := make([dynamic][4]u32, context.temp_allocator)
	values := make([dynamic]f32, context.temp_allocator)
	extras := make([dynamic]u32, context.temp_allocator)
	slot_first := 0
	for f, i in fields {
		descs[i] = {transmute(u32)f.h, u32(len(table)), u32(len(f.table) - 1), u32(slot_first)}
		for k, j in f.table do append(&table, [4]u32{u32(k), u32(k >> 32), u32(f.slots[j]), 0})
		append(&values, ..f.values[:])
		append(&extras, ..f.extras[:])
		slot_first += len(f.keys)
	}
	rows := make([][4][4]f32, len(terms), context.temp_allocator)
	for t, i in terms {
		for r in 0 ..< 3 do rows[i][r] = {t.into[r, 0], t.into[r, 1], t.into[r, 2], t.into[r, 3]}
		rows[i][3] = {t.ratio, t.edge, transmute(f32)t.id, transmute(f32)t.field}
	}
	sources := #partial [Blend_Project_Comp_Buffers][]u8 {
		.page_list     = mem.slice_to_bytes(page_list),
		.fields        = mem.slice_to_bytes(descs),
		.brick_table   = mem.slice_to_bytes(table[:]),
		.brick_values  = mem.slice_to_bytes(values[:]),
		.brick_extras  = mem.slice_to_bytes(extras[:]),
		.terms         = mem.slice_to_bytes(rows),
	}
	for kind in Blend_Project_Comp_Buffers {
		if kind == .positions do continue
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
	cmd := gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("blend compute: no command buffer: %s", gpu.last_error())
		return
	}
	uploaded := len(page_table) * size_of(u32)
	upload_ok := gpu.upload(cmd, bp.table, 0, mem.slice_to_bytes(page_table))
	for kind in Blend_Project_Comp_Buffers {
		src := sources[kind]
		if kind == .positions || len(src) == 0 do continue
		upload_ok = upload_ok && gpu.upload(cmd, bc.buffers[kind], 0, src)
		uploaded += len(src)
	}
	if !upload_ok {
		log.errorf("blend compute: upload failed: %s", gpu.last_error())
		_ = gpu.cancel_command_buffer(cmd)
		return
	}
	if !blend_submit_wait(cmd) do return
	timing.upload_ms = time.duration_milliseconds(time.tick_since(start))
	timing.upload_kb = f64(uploaded) / 1024

	start = time.tick_now()
	cmd = gpu.acquire_command_buffer()
	if cmd == nil {
		log.errorf("blend compute: no command buffer: %s", gpu.last_error())
		return
	}
	groups := len(page_list) * (BLEND_PAGE_VERTICES / BLEND_THREADS)
	groups_x := min(groups, MAX_GROUPS_X)
	groups_y := (groups + groups_x - 1) / groups_x
	params := Blend_Params {
		vertex_count = vertex_count,
		slot_count   = u32(len(page_list)),
		term_count   = u32(len(terms)),
		groups_x     = u32(groups_x),
		reach        = reach,
		self_edge    = self_edge,
	}
	for a in 0 ..< BLEND_TERMS_MAX do for b in 0 ..< BLEND_TERMS_MAX {
		params.pair_table[a * BLEND_TERMS_MAX + b] = {pairs[a][b][0], pairs[a][b][1], pairs[a][b][2], 0}
	}
	push_compute(cmd, Blend_Project_Comp_Uniforms.Blend_Params, &params)
	writes := [Blend_Project_Comp_Write_Buffers]gpu.Storage_Buffer_Binding{.pages = {buffer = bp.pages}}
	pass := begin_compute(cmd, &writes)
	gpu.bind_compute_pipeline(pass, bc.pipeline)
	reads := bc.buffers
	reads[.positions] = positions
	bind_compute_storage(pass, &reads)
	gpu.dispatch_compute(pass, u32(groups_x), u32(groups_y), 1)
	gpu.end_compute_pass(pass)
	if !blend_submit_wait(cmd) do return
	timing.compute_ms = time.duration_milliseconds(time.tick_since(start))
	r.last_version += 1
	bp.version = r.last_version
	return timing, true
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
