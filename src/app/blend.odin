package main

import "base:intrinsics"
import "base:runtime"
import "core:hash"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"
import "../render"
import "../sculpt"

// Smooth blend in the app (the Live stack row being built; design in
// .claude/project-memory/notes/smooth-blend/design.md): each joined object's field, its
// drawn pages and the chunk boxes the pages grow. So far one way in, `--blend-test=R`:
// on the first frame after any start-up script, every shown sculpt object is joined with every other at radius R
// (world units, full strength), projected once on the CPU (geom.blend_project) and drawn
// moved from then on, so the drawing, the seam and the culling can be looked at before
// the row exists.

// One object's part: its surface (the shown level's mesh and vertex lists, borrowed,
// with a lookup tree of its own: the sculptor's leaves hold a node of triangles each, far
// too many for closest-point queries), its field, its pages, and what the pages need of
// the drawing: per chunk how far its vertices move at most (`pads`, found once per fill
// from each touched page's box through the sculptor's tree, whose leaves are the chunks),
// likewise per simplified-copy group, and the grown boxes drawn, made again only when the
// sculptor's chunks or the pads change.
Blend_Object :: struct {
	id:        int,
	level:     ^sculpt.Level, // the level the surface borrows; the part is dropped when it changes
	vertices:  int,
	surface:   geom.Blend_Surface,
	field:     geom.Blend_Field,
	pages:     render.Blend_Pages,
	reach:     f32,
	pads:      [dynamic]f32, // per chunk; 0 where nothing moves
	lod_pads:  [dynamic]f32, // per simplified-copy group, for the tree it was found for
	lod_tree:  rawptr,       // that tree's groups, so a rebuilt tree is padded afresh
	touched:   [dynamic]geom.Aabb, // each touched page's moved vertices at rest, grown by their reach
	chunks:    [dynamic]geom.Chunk,
	groups:    [dynamic]geom.Chunk,
	lod:       [dynamic]geom.Lod_Group,
	drawn_key: u64, // what the grown boxes were made from: the layout, stamps and pads
	pads_key:  u64,
	lod_key:   u64, // the pads_key lod_pads were found for
	// A projection under way (--blend-drag): the pages it fills, shown once complete, and
	// what they will need of the drawing then.
	back:         render.Blend_Pages,
	back_pads:    [dynamic]f32,
	back_touched: [dynamic]geom.Aabb,
	back_reach:   f32,
	stale:        bool,         // placed or filled since its last projection began
	marked_at:    Vec3,         // where it was when its bricks were last marked
	slot_ms:      f64,          // the GPU time a slot of 1024 of its vertices took in the slowest recent slice, decaying
}

Blend_State :: struct {
	objects:    [dynamic]Blend_Object,
	tested:     bool,
	// For the exit stats.
	moved:      int,
	bricks:     int,
	fill_ms:    f64,
	project_ms: f64,
	grows:      int,
	// The GPU's projection and --blend-check's comparison with the CPU's.
	gpu_ms:         f64,
	gpu_upload_ms:  f64,
	gpu_pages:      int,
	check_diff:     f32,
	check_mismatch: int,
	check_failed:   bool,
	check_missing:  int, // bricks a fresh marking wants that a settled drag's fields lack
	check_mismatch_most: f32, // the largest offset a vertex only one side moves takes
	// --blend-drag: the instances and pairs kept between frames, the projection under way,
	// and what the frames cost.
	instances:      [dynamic]geom.Blend_Instance,
	pairs:          [dynamic]geom.Blend_Pair,
	radius:         f32,
	job:            render.Blend_Job,
	job_object:     int,
	job_fresh:      bool, // begun this frame: its upload waits for this frame's submit
	drag_left:      int,
	frames:         int, // frames since the drag began, while anything is left to do
	settled_after:  int, // frames from the drag's end until nothing was left
	frame_cpu_most: f64,
	frame_gpu_most: f64,
	mark_most:      f64,
	mark:           ^Blend_Mark, // a marking under way on its own thread
	fill_most:      f64, // the most a frame's fills took
	begin_most:     f64, // the most a projection's start took (pages found, data laid out)
	upload_most:    f64, // of which the upload and its wait
	filler:         ^Blend_Filler, // made by the first drag that has bricks to fill
	drag_checked:   bool, // --blend-check compared the settled drag's pages
	// Slices recorded on the frames' command buffers, timed by the GPU's timestamps a few
	// frames later: each one's object and slots, oldest first, until its time comes back.
	untimed:        [8]Blend_Slice,
	untimed_count:  int,
}

Blend_Slice :: struct {
	object: int,
	slots:  u32,
}

// The Blend span's GPU time of a frame a few back (frame.odin): the oldest slice still
// untimed took it, which sizes the next slices of its object (a slot's cost differs between
// objects as much as within one).
blend_timed :: proc(app: ^App, ms: f64) {
	b := &app.blend
	if b.untimed_count == 0 do return
	sl := b.untimed[0]
	copy(b.untimed[:], b.untimed[1:b.untimed_count])
	b.untimed_count -= 1
	if sl.slots > 0 && sl.object < len(b.objects) {
		bo := &b.objects[sl.object]
		bo.slot_ms = max(ms / f64(sl.slots), bo.slot_ms * BLEND_SLOT_DECAY)
	}
	b.frame_gpu_most = max(b.frame_gpu_most, ms)
}

// A marking of the bricks the pairs need (geom.blend_pair_bricks), on a thread of its own:
// it walks both trees and queries the surfaces, which at 20M took longer than a frame may
// spend. It reads the surfaces, the trees and the fields' tables; the frame loop fills no
// field while it runs, and takes its lists when `done`.
Blend_Mark :: struct {
	thread:    ^thread.Thread,
	done:      bool, // atomic
	instances: []geom.Blend_Instance, // as placed when it began
	pairs:     []geom.Blend_Pair,
	want:      [][dynamic]u64, // per instance
	ms:        f64,
}

@(private = "file")
blend_mark_thread :: proc(data: rawptr) {
	m := cast(^Blend_Mark)data
	// Temp memory of its own: the context came from the frame loop, whose temp allocator
	// is that thread's.
	arena: runtime.Arena
	context.temp_allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)
	t := time.tick_now()
	for p in m.pairs do geom.blend_pair_bricks(m.instances, p, &m.want[p.a], &m.want[p.b], nil)
	m.ms = time.duration_milliseconds(time.tick_since(t))
	sync.atomic_store(&m.done, true)
}

// Waits for a marking under way and frees it, its lists unread.
@(private = "file")
blend_mark_free :: proc(m: ^Blend_Mark) {
	thread.join(m.thread)
	thread.destroy(m.thread)
	for w in m.want do delete(w)
	delete(m.want)
	delete(m.instances)
	delete(m.pairs)
	free(m)
}

// --blend-drag's fill: the bricks a marking found missing, sampled on a few threads of their
// own at low priority so no frame waits on a query (one inside a dense sphere can take a
// quarter of a millisecond, and a brick is 729 of them); the frame loop only publishes the
// finished bricks into the fields. The threads read the surfaces, which nothing changes
// during the drag, and no field.
Blend_Filler :: struct {
	threads: [dynamic]^thread.Thread,
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	queue:   [dynamic]Blend_Fill_Task, // taken from the end
	done:    [dynamic]^Blend_Filled,
	taken:   [dynamic]^Blend_Filled, // the frame loop's: swapped with done, then published
	working: int, // tasks taken and not yet done
	stop:    bool,
}

Blend_Fill_Task :: struct {
	object:  int,
	key:     u64,
	h, band: f32,
	surface: ^geom.Blend_Surface,
}

Blend_Filled :: struct {
	object: int,
	brick:  geom.Blend_Brick,
}

// Threads a filler starts: a quarter of the pool's, so a drag's fills leave the frame and
// its pool most of the machine.
@(private = "file")
blend_filler_make :: proc(app: ^App) -> ^Blend_Filler {
	f := new(Blend_Filler)
	heap := runtime.heap_allocator()
	f.queue = make([dynamic]Blend_Fill_Task, heap)
	f.done = make([dynamic]^Blend_Filled, heap)
	f.taken = make([dynamic]^Blend_Filled, heap)
	for _ in 0 ..< clamp(len(app.pool.threads) / 4, 1, 8) {
		append(&f.threads, thread.create_and_start_with_data(f, blend_filler_thread, context, .Low, name = "blend fill"))
	}
	return f
}

@(private = "file")
blend_filler_thread :: proc(data: rawptr) {
	f := cast(^Blend_Filler)data
	// Temp memory of its own, as the marking's (blend_mark_thread).
	arena: runtime.Arena
	context.temp_allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)
	for {
		sync.mutex_lock(&f.mutex)
		for len(f.queue) == 0 && !f.stop do sync.cond_wait(&f.cond, &f.mutex)
		if f.stop {
			sync.mutex_unlock(&f.mutex)
			return
		}
		task := pop(&f.queue)
		f.working += 1
		sync.mutex_unlock(&f.mutex)
		out := new(Blend_Filled, runtime.heap_allocator())
		out.object = task.object
		geom.blend_brick_sample(task.h, task.band, task.surface, task.key, &out.brick)
		free_all(context.temp_allocator)
		sync.mutex_lock(&f.mutex)
		append(&f.done, out)
		f.working -= 1
		sync.mutex_unlock(&f.mutex)
	}
}

// Stops the threads (each finishes the brick it holds) and frees the filler with every
// brick not yet published.
@(private = "file")
blend_filler_free :: proc(f: ^Blend_Filler) {
	sync.mutex_lock(&f.mutex)
	f.stop = true
	sync.cond_broadcast(&f.cond)
	sync.mutex_unlock(&f.mutex)
	for t in f.threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(f.threads)
	heap := runtime.heap_allocator()
	for d in f.done do free(d, heap)
	for d in f.taken do free(d, heap)
	delete(f.queue)
	delete(f.done)
	delete(f.taken)
	free(f)
}

// Hands a finished marking's lists to the filler in place of the bricks an earlier one
// asked for and no thread has begun (those a thread holds are published if still wanted).
@(private = "file")
blend_filler_ask :: proc(b: ^Blend_State, m: ^Blend_Mark) {
	f := b.filler
	sync.mutex_lock(&f.mutex)
	clear(&f.queue)
	for w, i in m.want {
		bo := &b.objects[i]
		for k in w do if geom.blend_field_slot(&bo.field, k) < 0 do append(&f.queue, Blend_Fill_Task{object = i, key = k, h = bo.field.h, band = bo.field.band, surface = &bo.surface})
	}
	sync.cond_broadcast(&f.cond)
	sync.mutex_unlock(&f.mutex)
}

// Publishes the bricks the threads finished, in the order they finished (a field's slots
// may lie in any order; what is read by key is the same), and marks their objects stale.
// True when any brick was new to its field.
@(private = "file")
blend_filler_publish :: proc(b: ^Blend_State) -> bool {
	f := b.filler
	sync.mutex_lock(&f.mutex)
	f.done, f.taken = f.taken, f.done
	sync.mutex_unlock(&f.mutex)
	put := false
	for d in f.taken {
		if geom.blend_field_put(&b.objects[d.object].field, &d.brick) {
			b.objects[d.object].stale = true
			put = true
		}
		free(d, runtime.heap_allocator())
	}
	clear(&f.taken)
	return put
}

// Whether the filler has bricks queued, being sampled or waiting to be published.
@(private = "file")
blend_filler_busy :: proc(f: ^Blend_Filler) -> bool {
	if f == nil do return false
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	return len(f.queue) > 0 || f.working > 0 || len(f.done) > 0
}

// --blend-drag: what a slice of a projection may take of a frame's GPU time, so a dragged
// object never makes a frame hitch. The CPU's share needs no budget: the marking and the
// fills run on threads of their own, and the frame only publishes bricks and lays out a
// projection.
@(private = "file")
BLEND_FRAME_GPU_MS :: 1.5
// How fast the slowest recent slice's time a slot is forgotten, a timed slice at a time:
// a slot's cost varies over an object (the slots at the contact march longest), so slices
// are sized by the slowest lately, not the last.
@(private = "file")
BLEND_SLOT_DECAY :: 0.9
// --blend-drag's step a frame: a millimetre at the scale of a unit sphere.
@(private = "file")
BLEND_DRAG_STEP :: Vec3{0, 0.004, 0}

// A chunk layout no sculptor gives, mixed into a blended item's: the GPU's copy of its
// chunks then takes the grown boxes whole once, and later only the groups a stroke stamps.
@(private = "file")
BLEND_LAYOUT_MIX :: u64(0x5bd1e9955bd1e995)

blend_destroy :: proc(app: ^App) {
	if app.blend.mark != nil do blend_mark_free(app.blend.mark)
	app.blend.mark = nil
	if app.blend.filler != nil do blend_filler_free(app.blend.filler)
	app.blend.filler = nil
	for &bo in app.blend.objects do blend_object_free(&bo)
	render.blend_compute_destroy(&app.renderer, &app.blend_gpu)
	delete(app.blend.objects)
	delete(app.blend.instances)
	delete(app.blend.pairs)
	app.blend.objects, app.blend.instances, app.blend.pairs = {}, {}, {}
}

@(private = "file")
blend_object_free :: proc(bo: ^Blend_Object) {
	geom.bvh_destroy(&bo.surface.bvh)
	geom.blend_field_destroy(&bo.field)
	render.blend_pages_destroy(&bo.pages)
	delete(bo.pads)
	delete(bo.lod_pads)
	delete(bo.touched)
	delete(bo.chunks)
	delete(bo.groups)
	delete(bo.lod)
	render.blend_pages_destroy(&bo.back)
	delete(bo.back_pads)
	delete(bo.back_touched)
}

// Whether an object can take part: a shown sculpt mesh, no cage or clay, no dynamic
// topology (its vertices move between pages as it splits) and no HD window (drawn apart).
@(private = "file")
blend_fits :: proc(app: ^App, obj: ^Object) -> bool {
	if !object_shown(app, obj) || obj.voxel != nil || obj.cage != nil do return false
	if obj.levels.hd.window != nil do return false
	lv := sculpt.levels_current(&obj.levels)
	return lv.sculptor.dyn == nil && len(lv.mesh.positions) > 0
}

// --blend-test: joins every shown sculpt object with every other at `radius` and fills
// their pages, once. Logs what it did; the exit stats say it again.
@(private = "file")
blend_test_run :: proc(app: ^App, cmd: render.Cmd, radius: f32) {
	app.blend.tested = true
	app.blend.radius = radius
	for obj in app.scene.objects {
		if !blend_fits(app, obj) do continue
		lv := sculpt.levels_current(&obj.levels)
		scale := max(obj.transform.scale, 1e-6)
		h := geom.blend_spacing(radius / scale)
		append(&app.blend.objects, Blend_Object{id = obj.id, level = lv, vertices = len(lv.mesh.positions)})
		bo := &app.blend.objects[len(app.blend.objects) - 1]
		bo.surface = {mesh = lv.mesh, bvh = geom.bvh_build_morton(lv.mesh, geom.LOOKUP_LEAF, &app.pool), faces = lv.sculptor.faces, edge = geom.blend_surface_edge(lv.mesh)}
		geom.blend_field_init(&bo.field, h, geom.blend_band(h, radius / scale))
	}
	// The instances point into the objects, which no longer move in memory.
	for &bo in app.blend.objects {
		obj := object_by_id(app, bo.id)
		append(&app.blend.instances, geom.Blend_Instance{surface = &bo.surface, field = &bo.field, place = transform_matrix(obj.transform), scale = max(obj.transform.scale, 1e-6), id = u32(obj.id)})
		bo.marked_at = obj.transform.position
	}
	instances, pairs := app.blend.instances[:], &app.blend.pairs
	for i in 0 ..< len(instances) do for j in i + 1 ..< len(instances) do append(pairs, geom.Blend_Pair{a = i, b = j, radius = radius, strength = 1})
	t0 := time.tick_now()
	for p in pairs^ {
		want_a := make([dynamic]u64, context.temp_allocator)
		want_b := make([dynamic]u64, context.temp_allocator)
		geom.blend_pair_bricks(instances, p, &want_a, &want_b, &app.pool)
		geom.blend_field_fill(&app.blend.objects[p.a].field, &app.blend.objects[p.a].surface, want_a[:], &app.pool)
		geom.blend_field_fill(&app.blend.objects[p.b].field, &app.blend.objects[p.b].surface, want_b[:], &app.pool)
		log.infof("blend test: objects %d and %d want %d and %d bricks", app.blend.objects[p.a].id, app.blend.objects[p.b].id, len(want_a), len(want_b))
	}
	app.blend.fill_ms = time.duration_milliseconds(time.tick_since(t0))
	t1 := time.tick_now()
	for &bo, i in app.blend.objects {
		app.blend.bricks += len(bo.field.keys)
		if !app.blend_cpu && blend_project_gpu(app, instances, pairs[:], i) {
			if app.blend_check do blend_check(app, instances, pairs[:], i)
			continue
		}
		moves := make([dynamic]geom.Blend_Move, context.temp_allocator)
		_ = geom.blend_project(instances, pairs[:], i, &moves, &app.pool)
		blend_pages_fill(app, cmd, &bo, moves[:])
		app.blend.moved += len(moves)
		log.infof("blend test: object %d moved %d vertices on the CPU, the furthest by %v, through %d pages", bo.id, len(moves), bo.reach, len(bo.touched))
	}
	app.blend.project_ms = time.duration_milliseconds(time.tick_since(t1))
	render.viewport_invalidate(&app.target)
}

// Projects instance `which` on the GPU into its object's pages: the pages are those of the
// nodes whose chunk box meets a brick of its own field (a vertex anywhere else cannot
// move), and each such chunk is padded by how far a vertex can move, as the moves stay on
// the GPU. False when the GPU cannot take it (no compute, a mesh whose positions it cannot
// read, a group past render.BLEND_TERMS_MAX): the caller projects on the CPU.
@(private = "file")
blend_project_gpu :: proc(app: ^App, instances: []geom.Blend_Instance, pairs: []geom.Blend_Pair, which: int) -> bool {
	bo := &app.blend.objects[which]
	job: render.Blend_Job
	timing, ok := blend_job_begin(app, instances, pairs, which, &job, &bo.pages, &bo.pads, &bo.touched, &bo.reach) or_return
	bo.pads_key += 1
	if !ok do return true // nothing near: no pages
	ms, done, stepped := render.blend_compute_step(&app.renderer, &app.blend_gpu, &job, job.slots)
	if !stepped || !done do return false
	app.blend.gpu_ms += ms
	app.blend.gpu_upload_ms += timing.upload_ms
	app.blend.gpu_pages += int(job.slots)
	log.infof("blend test: object %d projected on the GPU through %d pages in %.2f ms (upload %.2f ms, %.0f KB)", bo.id, job.slots, ms, timing.upload_ms, timing.upload_kb)
	return true
}

// Lays out instance `which`'s projection on the GPU into `pages`: the terms and pairs, and
// the candidate pages (those of the nodes whose chunk box meets a brick of its own field
// and of a partner's), whose chunks it pads in `pads` and boxes in `touched` by how far a
// vertex can move. `taken` is false when the GPU cannot take it (no compute, positions it
// cannot read, a group past render.BLEND_TERMS_MAX): the caller projects on the CPU; `ok`
// false with `taken` when no page is near anything.
@(private = "file")
blend_job_begin :: proc(app: ^App, instances: []geom.Blend_Instance, pairs: []geom.Blend_Pair, which: int, job: ^render.Blend_Job, pages: ^render.Blend_Pages, pads: ^[dynamic]f32, touched: ^[dynamic]geom.Aabb, pad_out: ^f32, frame: render.Cmd = nil) -> (timing: render.Blend_Timing, ok: bool, taken: bool) {
	bo := &app.blend.objects[which]
	obj := object_by_id(app, bo.id)
	mb := &obj.gpu[obj.levels.current]
	if !mb.storage || !render.blend_compute_ready(&app.renderer, &app.blend_gpu) do return
	self := &instances[which]
	views, reach := geom.blend_views(instances, pairs, which, context.temp_allocator)
	if reach <= 0 || len(views) + 1 > render.BLEND_TERMS_MAX do return
	// The terms: the instance itself first, then its group's others, each with its field.
	terms := make([dynamic]render.Blend_Term, 0, len(views) + 1, context.temp_allocator)
	fields := make([dynamic]^geom.Blend_Field, 0, len(views) + 1, context.temp_allocator)
	index := make([dynamic]int, 0, len(views) + 1, context.temp_allocator)
	append(&terms, render.Blend_Term{into = 1, ratio = 1, edge = self.surface.edge, id = self.id, field = 0})
	append(&fields, self.field)
	append(&index, which)
	for v in views {
		append(&terms, render.Blend_Term{into = v.into, ratio = v.ratio, edge = v.inst.surface.edge * v.ratio, id = v.inst.id, field = u32(len(fields))})
		append(&fields, v.inst.field)
		append(&index, v.index)
	}
	term_pairs: [render.BLEND_TERMS_MAX][render.BLEND_TERMS_MAX][3]f32
	for a in 0 ..< len(terms) do for b in 0 ..< len(terms) {
		if a == b do continue
		radius, strength, opening := geom.blend_pair_between(pairs, index[a], index[b], self.scale)
		term_pairs[a][b] = {radius, strength, f32(opening)}
	}
	// The candidate pages, from the nodes near the field.
	s := &bo.level.sculptor
	table := make([]u32, (bo.vertices + render.BLEND_PAGE_VERTICES - 1) / render.BLEND_PAGE_VERTICES, context.temp_allocator)
	for &w in table do w = render.BLEND_PAGE_NONE
	page_list := make([dynamic]u32, context.temp_allocator)
	resize(pads, len(s.chunks))
	for &p in pads do p = 0
	clear(touched)
	// A vertex moves at most about the radius (the Newton steps are clamped and the
	// projection lands on the union within the radius of where it started), plus the
	// seam's lift: the pad for culling the moved parts.
	pad := reach * 1.25
	// Which nodes are near on the pool (a dense mesh has tens of thousands), then their
	// pages in node order, the same whatever the threads.
	Near :: struct {
		s:     ^sculpt.Sculptor,
		field: ^geom.Blend_Field,
		box:   geom.Aabb,
		views: []geom.Blend_View,
		near:  []bool,
	}
	near := Near{s = s, field = &bo.field, box = field_bounds(&bo.field), views = views, near = make([]bool, len(s.nodes), context.temp_allocator)}
	jobs.parallel_ranges(&app.pool, len(s.nodes), &near, proc(data: rawptr, lo, hi: int) {
		n := (^Near)(data)
		for k in lo ..< hi {
			bounds := n.s.chunks[k].bounds
			// The field's box first, so most chunks are passed over with one test.
			if n.s.nodes[k].vert_count == 0 || !box_meets(bounds, n.box) || !field_meets(n.field, bounds) do continue
			// And near a partner: its field holds a brick where the chunk lies in its space.
			for v in n.views {
				if v.joined && field_meets(v.inst.field, box_into(bounds, v.into)) {
					n.near[k] = true
					break
				}
			}
		}
	}, 512)
	for node, k in s.nodes {
		if !near.near[k] do continue
		pads[k] = pad
		append(touched, geom.Aabb{s.chunks[k].bounds.lo - pad, s.chunks[k].bounds.hi + pad})
		for page in node.vert_first / render.BLEND_PAGE_VERTICES ..= (node.vert_first + node.vert_count - 1) / render.BLEND_PAGE_VERTICES {
			if table[page] != render.BLEND_PAGE_NONE do continue
			table[page] = u32(len(page_list))
			append(&page_list, page)
		}
	}
	pad_out^ = pad
	if len(page_list) == 0 do return timing, false, true
	blend_pages_spread(table, page_list[:])
	timing, ok = render.blend_compute_begin(&app.renderer, &app.blend_gpu, job, mb.positions, u32(bo.vertices), fields[:], terms[:], &term_pairs, reach, self.surface.edge, table, page_list[:], pages, frame)
	return timing, ok, ok
}

// Lays the candidate pages (found in node order) into slots in bit-reversed order, and the
// table to match: a slice of a projection, a run of slots, then takes pages from all over
// the list, so the pages at the contact, which cost some fifty times the others, spread
// evenly over the slices and one slice's time a slot sizes the next.
@(private = "file")
blend_pages_spread :: proc(table, page_list: []u32) {
	n := len(page_list)
	if n < 2 do return
	order := make([]u32, n, context.temp_allocator)
	copy(order, page_list)
	bits := uint(0)
	for (1 << bits) < n do bits += 1
	at := 0
	for r in 0 ..< (1 << bits) {
		j := int(intrinsics.reverse_bits(u32(r)) >> (32 - bits))
		if j >= n do continue
		page_list[at] = order[j]
		table[order[j]] = u32(at)
		at += 1
	}
}

// The box of every brick a field holds, in its space.
@(private = "file")
field_bounds :: proc(f: ^geom.Blend_Field) -> geom.Aabb {
	out := geom.AABB_EMPTY
	size := f.h * geom.BLEND_BRICK
	for k in f.keys {
		b := geom.blend_unkey(k)
		lo := geom.Vec3{f32(b.x), f32(b.y), f32(b.z)} * size
		geom.aabb_grow(&out, lo)
		geom.aabb_grow(&out, lo + size)
	}
	return out
}

// --blend-drag's frame: moves the second object a step while the drag lasts, then works the
// blend toward the new place within the frame's budgets: bricks marked again once an
// object has moved half a brick, queued bricks filled, and a projection begun or carried
// on a slice at a time into each object's back pages, shown once whole. Records the
// largest CPU and GPU share any frame took and how many frames after the drag the blend
// took to settle.
blend_drag_frame :: proc(app: ^App, cmd: render.Cmd) {
	b := &app.blend
	if len(b.objects) < 2 || len(b.instances) != len(b.objects) do return
	start := time.tick_now()
	moving := b.drag_left > 0
	if moving {
		b.drag_left -= 1
		obj := object_by_id(app, b.objects[1].id)
		obj.transform.position += BLEND_DRAG_STEP
		b.objects[1].stale = true
		b.objects[0].stale = true
	}
	for &bo, i in b.objects {
		obj := object_by_id(app, bo.id)
		b.instances[i].place = transform_matrix(obj.transform)
	}
	worked := false
	// A finished marking's lists queued; a new one begun once an object has moved half a
	// brick from where it was last marked, or at all once it stops.
	if m := b.mark; m != nil && sync.atomic_load(&m.done) {
		if b.filler == nil do b.filler = blend_filler_make(app)
		blend_filler_ask(b, m)
		b.mark_most = max(b.mark_most, m.ms)
		blend_mark_free(m)
		b.mark = nil
		worked = true
	}
	if b.mark == nil {
		for &bo in b.objects {
			obj := object_by_id(app, bo.id)
			// Half a brick while it moves; once it stops, any way at all, so the settled
			// fields hold every brick its place needs.
			moved := linalg.length(obj.transform.position - bo.marked_at)
			if moved == 0 || (moving && moved < 0.5 * bo.field.h * geom.BLEND_BRICK) do continue
			m := new(Blend_Mark)
			m.instances = make([]geom.Blend_Instance, len(b.instances))
			copy(m.instances, b.instances[:])
			m.pairs = make([]geom.Blend_Pair, len(b.pairs))
			copy(m.pairs, b.pairs[:])
			m.want = make([][dynamic]u64, len(b.instances))
			m.thread = thread.create_and_start_with_data(m, blend_mark_thread, context, .Low, name = "blend mark")
			b.mark = m
			for &o in b.objects do o.marked_at = object_by_id(app, o.id).transform.position
			worked = true
			break
		}
	}
	// A projection begun for the next stale object, or the one under way carried on below.
	gpu_ms: f64
	if !b.job.active {
		// The next stale object after the last one projected, so none waits behind another
		// that keeps moving.
		for step in 1 ..= len(b.objects) {
			i := (b.job_object + step) % len(b.objects)
			bo := &b.objects[i]
			if !bo.stale do continue
			bo.stale = false
			worked = true
			t := time.tick_now()
			// The upload goes on this frame's command buffer, waiting for nothing. The
			// first slice follows it there, or next frame, once this one is submitted, when
			// slices go on command buffers of their own.
			timing, ok, taken := blend_job_begin(app, b.instances[:], b.pairs[:], i, &b.job, &bo.back, &bo.back_pads, &bo.back_touched, &bo.back_reach, cmd)
			b.job_fresh = ok && !app.renderer.caps.timestamps
			begin := time.duration_milliseconds(time.tick_since(t))
			b.begin_most = max(b.begin_most, begin)
			b.upload_most = max(b.upload_most, timing.upload_ms)
			if taken && !ok do blend_back_show(bo) // nothing near any more: no pages
			b.job_object = i
			break
		}
	}
	// The bricks the filler finished published, never while a marking reads the fields'
	// tables; their objects project again.
	fill_start := time.tick_now()
	if b.filler != nil && b.mark == nil && blend_filler_publish(b) do worked = true
	b.fill_most = max(b.fill_most, time.duration_milliseconds(time.tick_since(fill_start)))
	if b.job.active && b.job_fresh {
		b.job_fresh = false
	} else if b.job.active {
		// A small first slice until one of the object's is measured (a page at the contact,
		// every vertex marching, takes about a tenth of a millisecond on an integrated GPU,
		// fifty times one away from it), then as many as the share holds. Where
		// the GPU writes timestamps the slice goes on the frame's command buffer and nothing
		// waits for it; elsewhere it is submitted alone and waited for, which times it.
		timed := app.renderer.caps.timestamps
		slot_ms := b.objects[b.job_object].slot_ms if timed else b.job.slot_ms
		slots := u32(8)
		if slot_ms > 0 do slots = max(u32(BLEND_FRAME_GPU_MS / slot_ms), 1)
		slots = min(slots, b.job.slots - b.job.next)
		ms, done, ok := render.blend_compute_step(&app.renderer, &app.blend_gpu, &b.job, slots, cmd if timed else nil)
		gpu_ms = ms
		if timed && ok {
			if b.untimed_count == len(b.untimed) {
				copy(b.untimed[:], b.untimed[1:])
				b.untimed_count -= 1
			}
			b.untimed[b.untimed_count] = {object = b.job_object, slots = slots}
			b.untimed_count += 1
		}
		worked = true
		if ok && done {
			blend_back_show(&b.objects[b.job_object])
			// The new pages change what is drawn under the same frame key.
			render.viewport_invalidate(&app.target)
		}
	}
	// The frame's whole blend work on the CPU: the markings handed over, the projection
	// begun, the fills and the slice recorded.
	b.frame_cpu_most = max(b.frame_cpu_most, time.duration_milliseconds(time.tick_since(start)))
	b.frame_gpu_most = max(b.frame_gpu_most, gpu_ms)
	busy := b.job.active || b.mark != nil
	busy ||= blend_filler_busy(b.filler)
	for bo in b.objects do busy ||= bo.stale
	if moving || busy || worked {
		b.frames += 1
		if !moving do b.settled_after += 1
	} else if app.blend_check && !b.drag_checked {
		// Settled: what is shown against the CPU's projection where the objects now are.
		b.drag_checked = true
		for p in b.pairs {
			want := [2][dynamic]u64{make([dynamic]u64, context.temp_allocator), make([dynamic]u64, context.temp_allocator)}
			geom.blend_pair_bricks(b.instances[:], p, &want[0], &want[1], &app.pool)
			for w, j in want do for k in w do if geom.blend_field_slot(&b.objects[p.a if j == 0 else p.b].field, k) < 0 do b.check_missing += 1
		}
		for _, i in b.objects do blend_check(app, b.instances[:], b.pairs[:], i)
	}
}

// A finished projection's pages shown: the back pages and their pads become the shown ones.
@(private = "file")
blend_back_show :: proc(bo: ^Blend_Object) {
	bo.pages, bo.back = bo.back, bo.pages
	bo.pads, bo.back_pads = bo.back_pads, bo.pads
	bo.touched, bo.back_touched = bo.back_touched, bo.touched
	bo.reach = bo.back_reach
	bo.pads_key += 1
}

// The box round a box's eight corners placed by m.
@(private = "file")
box_into :: proc(b: geom.Aabb, m: matrix[4, 4]f32) -> geom.Aabb {
	out := geom.AABB_EMPTY
	for k in 0 ..< 8 {
		c := geom.Vec3{b.hi.x if k & 1 != 0 else b.lo.x, b.hi.y if k & 2 != 0 else b.lo.y, b.hi.z if k & 4 != 0 else b.lo.z}
		geom.aabb_grow(&out, (m * [4]f32{c.x, c.y, c.z, 1}).xyz)
	}
	return out
}

// Whether any brick of the field lies in the box (in the field's space).
@(private = "file")
field_meets :: proc(f: ^geom.Blend_Field, box: geom.Aabb) -> bool {
	lo, hi := geom.blend_brick_of(f.h, box.lo), geom.blend_brick_of(f.h, box.hi)
	for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
		if geom.blend_brick_fits({x, y, z}) && geom.blend_field_slot(f, geom.blend_key({x, y, z})) >= 0 do return true
	}
	return false
}

// --blend-check: the GPU's pages of instance `which` against the CPU's projection of it,
// vertex by vertex: how many vertices one moves and the other does not, and the largest
// difference of the offsets both make, for the exit stats.
@(private = "file")
blend_check :: proc(app: ^App, instances: []geom.Blend_Instance, pairs: []geom.Blend_Pair, which: int) {
	bo := &app.blend.objects[which]
	moves := make([dynamic]geom.Blend_Move, context.temp_allocator)
	_ = geom.blend_project(instances, pairs, which, &moves, &app.pool)
	table := make([]u32, (bo.vertices + render.BLEND_PAGE_VERTICES - 1) / render.BLEND_PAGE_VERTICES, context.temp_allocator)
	for &w in table do w = render.BLEND_PAGE_NONE
	// The same table blend_job_begin laid, found again from the pads it left.
	page_list := make([dynamic]u32, context.temp_allocator)
	s := &bo.level.sculptor
	for node, k in s.nodes {
		if node.vert_count == 0 || bo.pads[k] == 0 do continue
		for page in node.vert_first / render.BLEND_PAGE_VERTICES ..= (node.vert_first + node.vert_count - 1) / render.BLEND_PAGE_VERTICES {
			if table[page] != render.BLEND_PAGE_NONE do continue
			table[page] = u32(len(page_list))
			append(&page_list, page)
		}
	}
	blend_pages_spread(table, page_list[:])
	slots := u32(len(page_list))
	entries := render.blend_pages_read(&app.renderer, &bo.pages, slots, context.temp_allocator)
	if entries == nil {
		app.blend.check_failed = true
		return
	}
	moved := make([]bool, bo.vertices, context.temp_allocator)
	for m in moves {
		moved[m.vertex] = true
		page := table[m.vertex / render.BLEND_PAGE_VERTICES]
		if page == render.BLEND_PAGE_NONE {
			app.blend.check_mismatch += 1
			app.blend.check_mismatch_most = max(app.blend.check_mismatch_most, linalg.length(m.offset))
			continue
		}
		e := entries[int(page) * render.BLEND_PAGE_VERTICES + int(m.vertex % render.BLEND_PAGE_VERTICES)]
		if e == {} {
			app.blend.check_mismatch += 1
			app.blend.check_mismatch_most = max(app.blend.check_mismatch_most, linalg.length(m.offset))
			continue
		}
		app.blend.check_diff = max(app.blend.check_diff, linalg.length(e.offset - m.offset))
	}
	for slot, page in table {
		if slot == render.BLEND_PAGE_NONE do continue
		for k in 0 ..< render.BLEND_PAGE_VERTICES {
			v := page * render.BLEND_PAGE_VERTICES + k
			e := entries[int(slot) * render.BLEND_PAGE_VERTICES + k]
			if v < bo.vertices && !moved[v] && e != {} {
				app.blend.check_mismatch += 1
				app.blend.check_mismatch_most = max(app.blend.check_mismatch_most, linalg.length(e.offset))
			}
		}
	}
	app.blend.moved += len(moves)
}

// Lays an object's moves into pages of render.BLEND_PAGE_VERTICES vertices, in vertex
// order, notes the box they rest in and the furthest move, and uploads them.
@(private = "file")
blend_pages_fill :: proc(app: ^App, cmd: render.Cmd, bo: ^Blend_Object, moves: []geom.Blend_Move) {
	table := make([]u32, (bo.vertices + render.BLEND_PAGE_VERTICES - 1) / render.BLEND_PAGE_VERTICES, context.temp_allocator)
	for &w in table do w = render.BLEND_PAGE_NONE
	entries := make([dynamic]render.Blend_Entry, context.temp_allocator)
	// Each touched page's moved vertices as they rest, and how far they move at most.
	Page_Box :: struct {
		box:   geom.Aabb,
		reach: f32,
	}
	boxes := make([dynamic]Page_Box, context.temp_allocator)
	bo.reach = 0
	for m in moves {
		page := m.vertex / render.BLEND_PAGE_VERTICES
		if table[page] == render.BLEND_PAGE_NONE {
			table[page] = u32(len(entries) / render.BLEND_PAGE_VERTICES)
			resize(&entries, len(entries) + render.BLEND_PAGE_VERTICES)
			append(&boxes, Page_Box{box = geom.AABB_EMPTY})
		}
		entries[int(table[page]) * render.BLEND_PAGE_VERTICES + int(m.vertex % render.BLEND_PAGE_VERTICES)] = render.blend_entry_pack(m.offset, m.normal, m.amount, m.own)
		pb := &boxes[table[page]]
		geom.aabb_grow(&pb.box, bo.level.mesh.positions[m.vertex])
		pb.reach = max(pb.reach, linalg.length(m.offset))
		bo.reach = max(bo.reach, pb.reach)
	}
	// The chunks a moved vertex touches are those whose triangles use it, whose boxes all
	// hold its rest position: the sculptor's leaves within a touched page's box.
	s := &bo.level.sculptor
	resize(&bo.pads, len(s.chunks))
	for &p in bo.pads do p = 0
	leaves := make([dynamic]u32, context.temp_allocator)
	for pb in boxes {
		clear(&leaves)
		middle := (pb.box.lo + pb.box.hi) * 0.5
		geom.bvh_query_leaves(&s.bvh, middle, linalg.length(pb.box.hi - pb.box.lo) * 0.5, &leaves)
		for leaf in leaves {
			node := s.node_of[leaf]
			if int(node) < len(bo.pads) && box_meets(s.chunks[node].bounds, pb.box) do bo.pads[node] = max(bo.pads[node], pb.reach)
		}
	}
	bo.pads_key += 1
	padded := 0
	for p in bo.pads do if p > 0 do padded += 1
	log.infof("blend test: object %d pads %d of %d chunks", bo.id, padded, len(bo.pads))
	clear(&bo.lod_pads)
	bo.lod_tree = nil
	clear(&bo.touched)
	for pb in boxes do append(&bo.touched, geom.Aabb{pb.box.lo - pb.reach, pb.box.hi + pb.reach})
	if len(moves) == 0 {
		render.blend_pages_destroy(&bo.pages)
		return
	}
	_ = render.blend_pages_set(&app.renderer, cmd, &bo.pages, table, entries[:])
}

// The part of the object `obj` an item draws, or nil: an item of its shown level (not
// the HD window's, the boolean preview's or a copy's) whose level is still the one the
// part was made from.
@(private = "file")
blend_part_of :: proc(app: ^App, obj: ^Object, item: render.Draw_Item) -> ^Blend_Object {
	if obj == nil || item.copy != 0 do return nil
	for &bo in app.blend.objects {
		if bo.id != obj.id do continue
		lv := sculpt.levels_current(&obj.levels)
		if lv != bo.level || len(lv.mesh.positions) != bo.vertices || item.source != &lv.mesh do return nil
		return &bo
	}
	return nil
}

// Runs --blend-test once the scene is set up, then gives each item of a blended object its
// pages and boxes grown by its vertices' furthest move where they move, with cones opened
// there, so neither culling nor the simplified copies drop a moved part. The grown boxes
// are made again only when the sculptor's chunks, its simplified copies or the pads
// change. Before the live stack's copies are made: a copy draws the object without pages.
blend_draw_items :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item, froms: []Item_From) {
	// Once a start-up script has set the scene up, so it blends the objects the script made.
	if app.blend_test > 0 && !app.blend.tested && !app.script.running {
		blend_test_run(app, cmd, app.blend_test)
		app.blend.drag_left = app.blend_drag
	}
	if len(app.blend.objects) == 0 do return
	if app.blend_drag > 0 do blend_drag_frame(app, cmd)
	for &d, i in draws {
		bo := blend_part_of(app, froms[i].obj, d)
		if bo == nil || bo.pages.table == 0 || len(bo.pads) != len(d.chunks) do continue
		d.blend = &bo.pages
		if key := drawn_key(bo, d); key != bo.drawn_key {
			blend_grow(bo, d)
			bo.drawn_key = key
			app.blend.grows += 1
		}
		d.chunks = bo.chunks[:]
		if d.chunk_groups != nil do d.chunk_groups = bo.groups[:]
		// Changed with the pads too, so the GPU's copy takes the boxes they grow.
		d.chunk_layout ~= BLEND_LAYOUT_MIX ~ bo.pads_key * 0x9e3779b97f4a7c15
		if len(d.lod.groups) > 0 {
			blend_grow_lod(bo, d.lod.groups)
			d.lod.groups = bo.lod[:]
		}
	}
}

// What the grown chunk and group boxes are made from: the chunk layout and stamps and the
// pads.
@(private = "file")
drawn_key :: proc(bo: ^Blend_Object, d: render.Draw_Item) -> u64 {
	Key :: struct {
		layout, pads, chunks: u64,
	}
	k := Key{d.chunk_layout, bo.pads_key, u64(len(d.chunks))}
	h := hash.fnv64a(mem.ptr_to_bytes(&k))
	if len(d.group_stamps) > 0 do h = hash.fnv64a(mem.slice_to_bytes(d.group_stamps), h)
	return h
}

// Makes the item's grown chunk and group boxes from the sculptor's.
@(private = "file")
blend_grow :: proc(bo: ^Blend_Object, d: render.Draw_Item) {
	resize(&bo.chunks, len(d.chunks))
	copy(bo.chunks[:], d.chunks)
	for &c, k in bo.chunks do if bo.pads[k] > 0 do open_box(&c.bounds, &c.cone_cutoff, bo.pads[k])
	resize(&bo.groups, len(d.chunk_groups))
	for &g, k in bo.groups {
		lo := k * geom.CHUNK_GROUP
		hi := min(lo + geom.CHUNK_GROUP, len(bo.chunks))
		padded := false
		for p in bo.pads[lo:hi] do padded ||= p > 0
		g = geom.chunk_group(bo.chunks[lo:hi]) if padded else d.chunk_groups[k]
	}
}

// The simplified copies' groups with the moved parts' boxes grown, every frame: the
// sculptor builds its copies a few groups a frame in place (their bounds, errors and stale
// marks change under the same tree), and the groups are few. Which groups are padded is
// found once per tree and pads: those whose box meets a touched page's.
@(private = "file")
blend_grow_lod :: proc(bo: ^Blend_Object, groups: []geom.Lod_Group) {
	if bo.lod_tree != raw_data(groups) || len(bo.lod_pads) != len(groups) || bo.lod_key != bo.pads_key {
		resize(&bo.lod_pads, len(groups))
		for g, k in groups {
			bo.lod_pads[k] = 0
			for t in bo.touched do if box_meets(g.bounds, t) {
				bo.lod_pads[k] = bo.reach
				break
			}
		}
		bo.lod_tree, bo.lod_key = raw_data(groups), bo.pads_key
	}
	resize(&bo.lod, len(groups))
	copy(bo.lod[:], groups)
	for &g, k in bo.lod do if bo.lod_pads[k] > 0 do open_box(&g.bounds, &g.cone_cutoff, bo.lod_pads[k])
}

// Grows a box by `reach` and opens its normal cone (a cutoff of 1 or more is never culled
// as facing away): what a moved part's chunk needs.
@(private = "file")
open_box :: proc(b: ^geom.Aabb, cutoff: ^f32, reach: f32) {
	b.lo -= reach
	b.hi += reach
	cutoff^ = 2
}

@(private = "file")
box_meets :: proc(a, b: geom.Aabb) -> bool {
	return a.lo.x <= b.hi.x && a.hi.x >= b.lo.x && a.lo.y <= b.hi.y && a.hi.y >= b.lo.y && a.lo.z <= b.hi.z && a.hi.z >= b.lo.z
}
