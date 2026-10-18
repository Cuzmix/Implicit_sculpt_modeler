package sculpt

import "base:runtime"
import "core:math/linalg"
import "core:time"

import "../geom"
import "../jobs"

// Simplified copies of the mesh for drawing it while the view moves. Chunks are grouped
// along the BVH into a tree; each group holds a copy of the triangles under it with
// about a quarter of them, made from its children's copies, with every vertex on the
// group's border kept. The renderer draws a group's copy instead of its children when
// the copy strays less than about a pixel from the full mesh (geom.cull_lod).
//
// Copies are built a batch at a time, between strokes: an edit marks the groups above
// what it moved stale, and sculptor_lod_update rebuilds them, lowest first. A stale
// group is never drawn, only its children, so what is drawn always matches the mesh.

// Meshes with fewer triangles get no copies: drawing them in full costs little.
LOD_MIN_TRIANGLES :: 1 << 18
// A group forms over a BVH node once this many chunks or smaller groups lie under it.
LOD_FANOUT :: 4
// A copy aims for this fraction of the triangles it is made from.
LOD_REDUCTION :: 4
// geom.simplify's error runs below the largest distance between a copy and what it
// stands for, by up to 1.4 times on a bumpy sphere; this keeps the estimate above it.
LOD_ERROR_SCALE :: 1.5
// Time one sculptor_lod_update call spends building copies when not asked to finish
// (at least one batch): they are built a little each frame.
LOD_FRAME_BUDGET :: 4 * time.Millisecond
// Triangles a batch reads per thread: one or two groups each, so a batch takes a
// millisecond or two whatever the pool's size.
LOD_BATCH_TRIANGLES :: 8192

LOD_NO_PARENT :: max(u32)

Lod_State :: struct {
	tree:      geom.Lod,
	parent:    []u32, // per unit: the group it belongs to, or LOD_NO_PARENT
	height:    []u8,  // per group: 1 + its tallest child group's height (chunks count 0)
	capacity:  []u32, // per group: indices its slot holds; 0 until first built
	indices:   [dynamic]u32, // every group's copy, each in its slot
	wasted:    int,          // indices in slots their groups have outgrown
	stale:     [dynamic]u32, // groups waiting to be rebuilt
	uploads:   [dynamic]geom.Index_Range, // slots rewritten by the last update
	moved:     bool,         // slots moved since the last update: upload everything
	allocator: runtime.Allocator,
}

// Builds the tree with every group stale, so the copies get built by later updates.
@(private)
lod_init :: proc(s: ^Sculptor, min_triangles := LOD_MIN_TRIANGLES, allocator := context.allocator) {
	if len(s.mesh.indices) / 3 < min_triangles || len(s.nodes) < 2 do return
	l := &s.lod
	l.allocator = allocator
	nodes := len(s.nodes)
	Build :: struct {
		s:      ^Sculptor,
		groups: [dynamic]geom.Lod_Group,
		units:  [dynamic]u32,
		stack:  [dynamic]u32, // units not yet in a group
	}
	b := Build {
		s      = s,
		groups = make([dynamic]geom.Lod_Group, 0, nodes / 3 + 1, context.temp_allocator),
		units  = make([dynamic]u32, 0, nodes + nodes / 3 + 1, context.temp_allocator),
		stack  = make([dynamic]u32, 0, 64, context.temp_allocator),
	}
	group :: proc(b: ^Build, start: int) {
		children := b.stack[start:]
		append(&b.groups, geom.Lod_Group{child_first = u32(len(b.units)), child_count = u32(len(children)), error = geom.LOD_NONE, stale = true})
		append(&b.units, ..children)
		resize(&b.stack, start)
		append(&b.stack, u32(len(b.s.nodes) + len(b.groups) - 1))
	}
	// Bottom up: a BVH node takes the units its two halves left ungrouped, and groups
	// them once there are LOD_FANOUT, so groups have 4 to 6 children.
	collect :: proc(b: ^Build, bvh_node: u32, group: proc(b: ^Build, start: int)) {
		n := b.s.bvh.nodes[bvh_node]
		if n.count > 0 {
			append(&b.stack, b.s.node_of[bvh_node])
			return
		}
		start := len(b.stack)
		collect(b, n.first, group)
		collect(b, n.first + 1, group)
		if len(b.stack) - start >= LOD_FANOUT do group(b, start)
	}
	collect(&b, 0, group)
	if len(b.stack) > 1 do group(&b, 0)

	l.tree.groups = make([]geom.Lod_Group, len(b.groups), allocator)
	copy(l.tree.groups, b.groups[:])
	l.tree.units = make([]u32, len(b.units), allocator)
	copy(l.tree.units, b.units[:])
	l.tree.roots = make([]u32, len(b.stack), allocator)
	copy(l.tree.roots, b.stack[:])
	l.parent = make([]u32, nodes + len(b.groups), allocator)
	for &p in l.parent do p = LOD_NO_PARENT
	l.height = make([]u8, len(b.groups), allocator)
	// Children are created before their group, so heights fill in one pass.
	for g, i in l.tree.groups {
		for unit in l.tree.units[g.child_first:][:g.child_count] {
			l.parent[unit] = u32(i)
			if int(unit) >= nodes do l.height[i] = max(l.height[i], l.height[int(unit) - nodes] + 1)
		}
		l.height[i] = max(l.height[i], 1)
	}
	l.capacity = make([]u32, len(b.groups), allocator)
	l.indices = make([dynamic]u32, allocator)
	l.stale = make([dynamic]u32, len(b.groups), allocator)
	for &g, i in l.stale do g = u32(i)
	l.uploads = make([dynamic]geom.Index_Range, 0, 64, allocator)
}

@(private)
lod_destroy :: proc(l: ^Lod_State) {
	if l.allocator.procedure == nil do return
	delete(l.tree.groups, l.allocator)
	delete(l.tree.units, l.allocator)
	delete(l.tree.roots, l.allocator)
	delete(l.parent, l.allocator)
	delete(l.height, l.allocator)
	delete(l.capacity, l.allocator)
	delete(l.indices)
	delete(l.stale)
	delete(l.uploads)
}

// Marks every group above node `id` stale. Groups above a stale group are stale too,
// so the walk stops at the first one.
@(private)
lod_mark_stale :: proc(s: ^Sculptor, id: u32) {
	l := &s.lod
	if len(l.parent) == 0 do return
	for p := l.parent[id]; p != LOD_NO_PARENT; p = l.parent[len(s.nodes) + int(p)] {
		g := &l.tree.groups[p]
		if g.stale do return
		g.stale = true
		append(&l.stale, p)
	}
}

// Groups whose copies are still to be built.
sculptor_lod_pending :: proc(s: ^Sculptor) -> int {
	return len(s.lod.stale)
}

// Rebuilds the copies of stale groups, lowest first (a group is made from its
// children's copies), in batches while another as long as the last one still fits in
// LOD_FRAME_BUDGET, or until none is left with `finish`. Does nothing during a stroke, while its groups keep changing.
// Returns the ranges of `lod.indices` it rewrote, for upload; `all` when slots moved
// and all of `lod.indices` needs uploading.
sculptor_lod_update :: proc(s: ^Sculptor, finish := false) -> (ranges: []geom.Index_Range, all: bool) {
	l := &s.lod
	clear(&l.uploads)
	start := time.tick_now()
	last: time.Duration // the previous batch's time
	threads := jobs.pool_size(s.pool) if s.pool != nil else 1
	batch := make([dynamic]u32, 0, len(l.stale), context.temp_allocator)
	for len(l.stale) > 0 && !s.history.recording && (finish || time.tick_since(start) + last <= LOD_FRAME_BUDGET) {
		batch_start := time.tick_now()
		lowest := max(u8)
		for g in l.stale do lowest = min(lowest, l.height[g])
		clear(&batch)
		budget := LOD_BATCH_TRIANGLES * threads
		kept := 0
		for g in l.stale {
			if l.height[g] == lowest && budget > 0 {
				append(&batch, g)
				budget -= lod_input_triangles(s, g)
			} else {
				l.stale[kept] = g
				kept += 1
			}
		}
		resize(&l.stale, kept)
		lod_rebuild(s, batch[:])
		last = time.tick_since(batch_start)
	}
	all = l.moved
	l.moved = false
	return l.uploads[:], all
}

@(private)
lod_input_triangles :: proc(s: ^Sculptor, group: u32) -> int {
	l := &s.lod
	g := l.tree.groups[group]
	total := 0
	for unit in l.tree.units[g.child_first:][:g.child_count] {
		if int(unit) < len(s.nodes) {
			total += int(s.nodes[unit].tri_count)
		} else {
			total += int(l.tree.groups[int(unit) - len(s.nodes)].index_count / 3)
		}
	}
	return total
}

@(private)
Lod_Result :: struct {
	indices: [dynamic]u32,
	error:   f32,
	bounds:  geom.Aabb,
	axis:    Vec3,
	cutoff:  f32,
}

@(private)
Lod_Job :: struct {
	s:       ^Sculptor,
	batch:   []u32,
	results: []Lod_Result,
}

// Builds the batch's copies in parallel, then stores each in its group's slot, moving
// it to a new slot at the end when it outgrew the old one.
@(private)
lod_rebuild :: proc(s: ^Sculptor, batch: []u32) {
	job := Lod_Job{s = s, batch = batch, results = make([]Lod_Result, len(batch), context.temp_allocator)}
	jobs.parallel_for(s.pool, len(batch), &job, job_lod_group)
	l := &s.lod
	// Copies come to about a third of the mesh's triangles, plus room to grow.
	if cap(l.indices) == 0 do reserve(&l.indices, len(s.mesh.indices) / 12 * 5 + 1024)
	for id, i in batch {
		r := &job.results[i]
		defer delete(r.indices)
		g := &l.tree.groups[id]
		count := u32(len(r.indices))
		if count > l.capacity[id] {
			l.wasted += int(l.capacity[id])
			l.capacity[id] = count + count / 4
			g.first_index = u32(len(l.indices))
			// resize alone grows to the exact length, copying everything per slot.
			size := len(l.indices) + int(l.capacity[id])
			if size > cap(l.indices) do reserve(&l.indices, max(size, 2 * cap(l.indices)))
			non_zero_resize(&l.indices, size)
		}
		copy(l.indices[g.first_index:], r.indices[:])
		g.index_count = count
		g.error = r.error
		g.bounds = r.bounds
		g.cone_axis, g.cone_cutoff = r.axis, r.cutoff
		g.stale = false
		append(&l.uploads, geom.Index_Range{g.first_index, count})
	}
	if l.wasted > len(l.indices) / 2 do lod_compact(l)
}

// Packs the slots, dropping the space of outgrown ones.
@(private)
lod_compact :: proc(l: ^Lod_State) {
	packed := make([dynamic]u32, 0, len(l.indices) - l.wasted + 1024, l.allocator)
	for &g, i in l.tree.groups {
		if l.capacity[i] == 0 do continue
		first := u32(len(packed))
		append(&packed, ..l.indices[g.first_index:][:l.capacity[i]])
		g.first_index = first
	}
	delete(l.indices)
	l.indices = packed
	l.wasted = 0
	l.moved = true
}

// Simplifies one group of the batch from its children: chunks' full triangles and
// child groups' copies.
@(private)
job_lod_group :: proc(data: rawptr, i: int) {
	job := cast(^Lod_Job)data
	s := job.s
	l := &s.lod
	heap := runtime.heap_allocator()
	g := l.tree.groups[job.batch[i]]
	r := &job.results[i]
	r.bounds = geom.AABB_EMPTY
	below: f32 // the largest error of the copies it is made from
	input := make([dynamic]u32, 0, 3 * lod_input_triangles(s, job.batch[i]), heap)
	defer delete(input)
	for unit in l.tree.units[g.child_first:][:g.child_count] {
		if int(unit) < len(s.nodes) {
			n := s.nodes[unit]
			append(&input, ..s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count])
			r.bounds = geom.aabb_union(r.bounds, s.chunks[unit].bounds)
		} else {
			c := l.tree.groups[int(unit) - len(s.nodes)]
			append(&input, ..l.indices[c.first_index:][:c.index_count])
			r.bounds = geom.aabb_union(r.bounds, c.bounds)
			below = max(below, c.error)
		}
	}
	r.indices = make([dynamic]u32, 0, len(input) / LOD_REDUCTION + 64, heap)
	error := geom.simplify(s.mesh.positions[:], input[:], len(input) / 3 / LOD_REDUCTION, &r.indices, heap)
	r.error = geom.LOD_NONE if below == geom.LOD_NONE else LOD_ERROR_SCALE * error + below

	normals := make([]Vec3, len(r.indices) / 3, heap)
	defer delete(normals, heap)
	p := s.mesh.positions
	for &n, k in normals {
		p0, p1, p2 := p[r.indices[3 * k]], p[r.indices[3 * k + 1]], p[r.indices[3 * k + 2]]
		n = linalg.cross(p1 - p0, p2 - p0)
	}
	r.axis, r.cutoff = geom.normal_cone(normals)
}
