package voxel

import "base:runtime"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// The surface: the triangles that show the clay, remeshed a node (16³ voxels) at a time
// by naive surface nets. Every node owns a slot of vertices and a slot of indices in one
// geom.Mesh, with headroom, so a remeshed node that still fits rewrites its slot in place
// and the frame uploads only those slots; a node that outgrows its slot moves to a free one
// or to the end. Unused index slots hold zeros, triangles on vertex 0 (a dummy at the
// origin), so drawing the whole index buffer shows nothing extra. The vertices on a node's
// border are duplicated by its neighbour: both compute them from the same voxels with the
// same proc, so they agree bit for bit and no seam shows.

Node :: struct {
	coord:      [3]i32,
	vert_first: u32,
	vert_cap:   u32,
	vert_count: u32,
	idx_first:  u32,
	idx_cap:    u32,
	idx_count:  u32,
	bounds:     geom.Aabb, // object space, AABB_EMPTY without triangles
	dirty:      bool,
}

Surface :: struct {
	mesh:         geom.Mesh,
	codes:        [dynamic]u32, // per vertex slot, beside mesh.positions: the vertex's code (below)
	nodes:        [dynamic]Node,
	chunks:       [dynamic]geom.Chunk, // one per node with triangles, sorted by first_index, for the Draw_Item
	free_verts:   [dynamic]geom.Vertex_Range, // holes, sorted and merged
	free_indices: [dynamic]geom.Index_Range,
	dirty:        [dynamic]u32, // node indices to remesh at the next flush
	regrow:       bool, // the arrays grew or were laid out again since the last flush: the GPU copy is remade
	// Scratch for the flush, kept between frames.
	results:      [dynamic]Mesh_Result,
	ranges:       [dynamic]geom.Vertex_Range,
	index_ranges: [dynamic]geom.Index_Range,
	allocator:    runtime.Allocator,
}

// What one frame uploads after clay_flush: the vertex and index slots that changed, or
// `regrow` when the GPU copy must be made afresh from the whole mesh.
Flush :: struct {
	ranges:  []geom.Vertex_Range,
	indices: []geom.Index_Range,
	regrow:  bool,
	damage:  geom.Aabb, // object space, before and after
}

// The meshing window: a node's 16 voxels and 2 more each side, for the −1 cell layer and
// the central differences.
MESH_WINDOW :: NODE + 4
MESH_WINDOW_VOXELS :: MESH_WINDOW * MESH_WINDOW * MESH_WINDOW
// The cells a node computes vertices for: its own and the layer before it.
MESH_CELLS :: NODE + 1
CELL_NONE :: max(u32)
// Slots are rounded up to these and given this much headroom, so a node that grows a
// little stays in place; the arrays grow by this much more than asked so that a run of
// growths is one reallocation.
VERT_ROUND :: 64
INDEX_ROUND :: 192
SLOT_HEADROOM :: 0.25
ARRAY_SLACK :: 0.125
// Compaction runs when more than this fraction of the arrays is holes, and only once the
// arrays are this long, so small clays never bother.
COMPACT_FRACTION :: 0.5
COMPACT_MIN_VERTS :: 1 << 16
// The free slots kept in reserve, as a fraction of the slots in use, so a stroke's growth
// is met from holes and the arrays grow (a new GPU copy) only at a stroke's end or a flush
// that remakes the copy anyway.
RESERVE_FRACTION :: 0.1

// One job's output: the node's new triangles, in the job's own arrays (the heap allocator,
// as jobs must), with indices local to the node.
Mesh_Result :: struct {
	node:      u32,
	positions: [dynamic]Vec3,
	normals:   [dynamic]Vec3,
	codes:     [dynamic]u32,
	indices:   [dynamic]u32,
	bounds:    geom.Aabb,
}

// A vertex's code names what it stands for: the cell, as the node that owns the cell
// indexes it (a node owns the cells 0 to 15 along each axis of its 16³; 12 bits), the loop
// of crossings in that cell (2 bits) and the axes along which this node sees the cell at
// −1 (3 bits: the owner is this node less one along each). A border vertex and its copy in
// the neighbour node thus carry the same cell and loop and name each other's owner, so the
// weld (convert.odin) matches them without comparing positions.
CODE_LOOP_SHIFT :: 12
CODE_OFFSET_SHIFT :: 14
CODE_KEY_MASK :: (1 << CODE_OFFSET_SHIFT) - 1
#assert(NODE == 16, "a cell's owner-local index takes four bits an axis")

surface_init :: proc(s: ^Surface, allocator: runtime.Allocator) {
	s.allocator = allocator
	s.mesh.positions = make([dynamic]Vec3, allocator)
	s.mesh.normals = make([dynamic]Vec3, allocator)
	s.mesh.indices = make([dynamic]u32, allocator)
	s.codes = make([dynamic]u32, allocator)
	// Vertex 0 is the dummy every unused index slot points at.
	append(&s.mesh.positions, Vec3{})
	append(&s.mesh.normals, Vec3{})
	append(&s.codes, 0)
	s.nodes = make([dynamic]Node, allocator)
	s.chunks = make([dynamic]geom.Chunk, allocator)
	s.free_verts = make([dynamic]geom.Vertex_Range, allocator)
	s.free_indices = make([dynamic]geom.Index_Range, allocator)
	s.dirty = make([dynamic]u32, allocator)
	s.results = make([dynamic]Mesh_Result, allocator)
	s.ranges = make([dynamic]geom.Vertex_Range, allocator)
	s.index_ranges = make([dynamic]geom.Index_Range, allocator)
	s.regrow = true
}

surface_destroy :: proc(s: ^Surface) {
	geom.mesh_destroy(&s.mesh)
	delete(s.codes)
	delete(s.nodes)
	delete(s.chunks)
	delete(s.free_verts)
	delete(s.free_indices)
	delete(s.dirty)
	delete(s.results)
	delete(s.ranges)
	delete(s.index_ranges)
	s^ = {}
}

// Bytes held by the mesh arrays (slack included), the codes and the nodes.
surface_bytes :: proc(s: ^Surface) -> int {
	return len(s.mesh.positions) * (2 * size_of(Vec3) + size_of(u32)) + len(s.mesh.indices) * size_of(u32) + len(s.nodes) * size_of(Node)
}

// Vertices in use (the dummy left out) and triangles in use.
surface_counts :: proc(s: ^Surface) -> (vertices, triangles: int) {
	for n in s.nodes {
		vertices += int(n.vert_count)
		triangles += int(n.idx_count) / 3
	}
	return
}

// The index of the node at `nc`, if there is one.
@(private)
surface_node_find :: proc(c: ^Clay, nc: [3]i32) -> (index: u32, ok: bool) {
	if nc.x < 0 || nc.y < 0 || nc.z < 0 || nc.x >= MAX_NODES || nc.y >= MAX_NODES || nc.z >= MAX_NODES do return 0, false
	table := volume_table(&c.volume, nc * NODE_BRICKS)
	if table == nil do return 0, false
	index = table.nodes[node_slot_in_chunk(nc)]
	return index, index != NODE_NONE
}

// The index of the node at `nc`, made (empty, clean) when there was none.
@(private)
surface_node_make :: proc(c: ^Clay, nc: [3]i32) -> u32 {
	table := volume_table_make(&c.volume, nc * NODE_BRICKS)
	at := node_slot_in_chunk(nc)
	s := &c.surface
	if i := table.nodes[at]; i != NODE_NONE do return i
	table.nodes[at] = u32(len(s.nodes))
	append(&s.nodes, Node{coord = nc, bounds = geom.AABB_EMPTY})
	return u32(len(s.nodes) - 1)
}

// Queues node `nc` for meshing at the next flush.
@(private)
surface_mark_node :: proc(c: ^Clay, nc: [3]i32) {
	if nc.x < 0 || nc.y < 0 || nc.z < 0 || nc.x >= MAX_NODES || nc.y >= MAX_NODES || nc.z >= MAX_NODES do return
	i := surface_node_make(c, nc)
	n := &c.surface.nodes[i]
	if n.dirty do return
	n.dirty = true
	append(&c.surface.dirty, i)
}

// Queues the nodes whose meshing window covers brick `bc`: its own node and, per axis, the
// neighbour on the side the brick sits (the window reaches two voxels past the node), so
// eight nodes at most.
surface_mark_brick :: proc(c: ^Clay, bc: [3]i32) {
	n := shr3(bc, 1) // NODE_BRICKS is 2
	other := n
	for a in 0 ..< 3 do other[a] += -1 if bc[a] & 1 == 0 else 1
	for k in 0 ..< 8 {
		nc := n
		if k & 1 != 0 do nc.x = other.x
		if k & 2 != 0 do nc.y = other.y
		if k & 4 != 0 do nc.z = other.z
		surface_mark_node(c, nc)
	}
}

// Queues the nodes that can see a change in brick `bc` within the box [lo, hi] of its
// voxels (surface_mark_brick's rule, but a neighbour only when the box reaches the two
// voxels on its side); nothing for an empty box.
surface_mark_box :: proc(c: ^Clay, bc: [3]i32, lo, hi: [3]i8) {
	if lo.x > hi.x do return
	n := shr3(bc, 1) // NODE_BRICKS is 2
	other := n
	for a in 0 ..< 3 {
		if bc[a] & 1 == 0 {
			if lo[a] < 2 do other[a] -= 1
		} else {
			if hi[a] >= BRICK - 2 do other[a] += 1
		}
	}
	for k in 0 ..< 8 {
		nc := n
		if k & 1 != 0 do nc.x = other.x
		if k & 2 != 0 do nc.y = other.y
		if k & 4 != 0 do nc.z = other.z
		if nc != n || k == 0 do surface_mark_node(c, nc)
	}
}

// Queues every node that any brick touches: after a fill or a read.
surface_mark_all :: proc(c: ^Clay) {
	for coord in c.volume.coords do if coord != BRICK_FREE do surface_mark_brick(c, coord)
}

// Remeshes the dirty nodes and lays their triangles into the mesh. Once a frame, before the
// upload; the result's slices live until the next flush.
clay_flush :: proc(c: ^Clay) -> (f: Flush) {
	s := &c.surface
	f.damage = geom.AABB_EMPTY
	clear(&s.ranges)
	clear(&s.index_ranges)
	if len(s.dirty) == 0 {
		f.regrow = s.regrow
		s.regrow = false
		return
	}
	// Slot assignment must not depend on the order dabs landed in.
	slice.sort_by(s.dirty[:], proc(a, b: u32) -> bool {return a < b})
	resize(&s.results, len(s.dirty))
	for d, i in s.dirty {
		s.results[i] = Mesh_Result {
			node = d,
		}
		f.damage = geom.aabb_union(f.damage, s.nodes[d].bounds)
	}
	jobs.parallel_for(c.pool, len(s.dirty), c, proc(data: rawptr, i: int) {
		c := cast(^Clay)data
		mesh_node(c, &c.surface.results[i])
	})
	// Slots: a node that still fits keeps its slot; the others move. What the movers need
	// beyond the holes is grown once, up front, rather than a node at a time.
	need_verts, need_idx := 0, 0
	for &r in s.results {
		n := &s.nodes[r.node]
		verts, idx := u32(len(r.positions)), u32(len(r.indices))
		if verts > n.vert_cap || idx > n.idx_cap {
			need_verts += int(slot_cap(verts, SLOT_HEADROOM, VERT_ROUND))
			need_idx += int(slot_cap(idx, SLOT_HEADROOM, INDEX_ROUND))
		}
	}
	surface_make_room(s, need_verts, need_idx)
	for &r in s.results {
		n := &s.nodes[r.node]
		verts, idx := u32(len(r.positions)), u32(len(r.indices))
		if verts > n.vert_cap || idx > n.idx_cap || (verts == 0 && n.vert_cap > 0) {
			surface_free_slot(s, n)
			if verts > 0 {
				n.vert_cap = slot_cap(verts, SLOT_HEADROOM, VERT_ROUND)
				n.idx_cap = slot_cap(idx, SLOT_HEADROOM, INDEX_ROUND)
				n.vert_first = surface_alloc_verts(s, n.vert_cap)
				n.idx_first = surface_alloc_indices(s, n.idx_cap)
			}
		}
		n.vert_count, n.idx_count = verts, idx
		n.bounds = r.bounds
		n.dirty = false
		f.damage = geom.aabb_union(f.damage, r.bounds)
		if n.vert_cap > 0 {
			append(&s.ranges, geom.Vertex_Range{n.vert_first, n.vert_cap})
			append(&s.index_ranges, geom.Index_Range{n.idx_first, n.idx_cap})
		}
	}
	jobs.parallel_for(c.pool, len(s.results), c, proc(data: rawptr, i: int) {
		s := &(cast(^Clay)data).surface
		r := &s.results[i]
		n := s.nodes[r.node]
		copy(s.mesh.positions[n.vert_first:][:n.vert_count], r.positions[:])
		copy(s.mesh.normals[n.vert_first:][:n.vert_count], r.normals[:])
		copy(s.codes[n.vert_first:][:n.vert_count], r.codes[:])
		out := s.mesh.indices[n.idx_first:][:n.idx_cap]
		for k, j in r.indices do out[j] = n.vert_first + k
		slice.zero(out[n.idx_count:])
		mesh_result_destroy(r)
	})
	clear(&s.dirty)
	surface_chunks_rebuild(s)
	// A flush that remakes the GPU copy may as well top the reserve up first.
	if s.regrow do surface_reserve(s)
	f.regrow = s.regrow
	s.regrow = false
	if !f.regrow {
		coalesce_vertex_ranges(&s.ranges)
		coalesce_index_ranges(&s.index_ranges)
		f.ranges = s.ranges[:]
		f.indices = s.index_ranges[:]
	}
	return
}

@(private)
mesh_result_destroy :: proc(r: ^Mesh_Result) {
	delete(r.positions)
	delete(r.normals)
	delete(r.codes)
	delete(r.indices)
	r.positions, r.normals, r.codes, r.indices = nil, nil, nil, nil
}

@(private)
round_up :: #force_inline proc(n, to: u32) -> u32 {
	return (n + to - 1) / to * to
}

// A slot for `count` entries with the headroom, rounded.
@(private)
slot_cap :: #force_inline proc(count: u32, headroom: f32, round: u32) -> u32 {
	return round_up(u32(f32(count) * (1 + headroom)), round)
}

// Grows the arrays so that the holes hold at least `verts` vertices and `idx` indices,
// as one growth each (a hole at the end, which the allocations then take).
@(private)
surface_make_room :: proc(s: ^Surface, verts, idx: int) {
	holes := 0
	for h in s.free_verts do holes += int(h.count)
	if holes < verts {
		first := surface_alloc_verts(s, u32(verts - holes))
		free_insert_verts(&s.free_verts, {first, u32(verts - holes)})
	}
	holes = 0
	for h in s.free_indices do holes += int(h.index_count)
	if holes < idx {
		first := surface_alloc_indices(s, u32(idx - holes))
		free_insert_indices(&s.free_indices, {first, u32(idx - holes)})
	}
}

// Returns a node's slots to the free lists; the index slot is zeroed and uploaded, since
// the GPU copy still holds its triangles.
@(private)
surface_free_slot :: proc(s: ^Surface, n: ^Node) {
	if n.vert_cap == 0 do return
	free_insert_verts(&s.free_verts, {n.vert_first, n.vert_cap})
	free_insert_indices(&s.free_indices, {n.idx_first, n.idx_cap})
	slice.zero(s.mesh.indices[n.idx_first:][:n.idx_cap])
	append(&s.index_ranges, geom.Index_Range{n.idx_first, n.idx_cap})
	n.vert_first, n.vert_cap, n.vert_count = 0, 0, 0
	n.idx_first, n.idx_cap, n.idx_count = 0, 0, 0
}

// Inserts a hole, merging it with the holes it touches, so first fit sees the largest runs.
@(private)
free_insert_verts :: proc(list: ^[dynamic]geom.Vertex_Range, r: geom.Vertex_Range) {
	at := 0
	for at < len(list) && list[at].first < r.first do at += 1
	inject_at(list, at, r)
	if at + 1 < len(list) && list[at].first + list[at].count == list[at + 1].first {
		list[at].count += list[at + 1].count
		ordered_remove(list, at + 1)
	}
	if at > 0 && list[at - 1].first + list[at - 1].count == list[at].first {
		list[at - 1].count += list[at].count
		ordered_remove(list, at)
	}
}

@(private)
free_insert_indices :: proc(list: ^[dynamic]geom.Index_Range, r: geom.Index_Range) {
	at := 0
	for at < len(list) && list[at].first_index < r.first_index do at += 1
	inject_at(list, at, r)
	if at + 1 < len(list) && list[at].first_index + list[at].index_count == list[at + 1].first_index {
		list[at].index_count += list[at + 1].index_count
		ordered_remove(list, at + 1)
	}
	if at > 0 && list[at - 1].first_index + list[at - 1].index_count == list[at].first_index {
		list[at - 1].index_count += list[at].index_count
		ordered_remove(list, at)
	}
}

// The first hole of `count` vertices, or new vertices at the end, with slack behind them
// so the next growth finds a hole. Growth sets `regrow`.
@(private)
surface_alloc_verts :: proc(s: ^Surface, count: u32) -> u32 {
	for &h, i in s.free_verts {
		if h.count < count do continue
		first := h.first
		h.first += count
		h.count -= count
		if h.count == 0 do ordered_remove(&s.free_verts, i)
		return first
	}
	first := u32(len(s.mesh.positions))
	slack := u32(f32(first + count) * ARRAY_SLACK)
	// Growing writes the new elements here, on one thread: fresh pages fault on first
	// touch, and four threads faulting the same mapping in the copy pass run slower than one.
	non_zero_resize(&s.mesh.positions, int(first + count + slack))
	non_zero_resize(&s.mesh.normals, int(first + count + slack))
	non_zero_resize(&s.codes, int(first + count + slack))
	slice.zero(s.mesh.positions[first:])
	slice.zero(s.mesh.normals[first:])
	slice.zero(s.codes[first:])
	if slack > 0 do free_insert_verts(&s.free_verts, {first + count, slack})
	s.regrow = true
	return first
}

@(private)
surface_alloc_indices :: proc(s: ^Surface, count: u32) -> u32 {
	for &h, i in s.free_indices {
		if h.index_count < count do continue
		first := h.first_index
		h.first_index += count
		h.index_count -= count
		if h.index_count == 0 do ordered_remove(&s.free_indices, i)
		return first
	}
	first := u32(len(s.mesh.indices))
	slack := u32(f32(first + count) * ARRAY_SLACK)
	// New indices are zero: triangles on the dummy vertex; written here for the same reason.
	non_zero_resize(&s.mesh.indices, int(first + count + slack))
	slice.zero(s.mesh.indices[first:])
	if slack > 0 do free_insert_indices(&s.free_indices, {first + count, slack})
	s.regrow = true
	return first
}

// Sorts the ranges and joins the ones that touch or overlap.
@(private)
coalesce_vertex_ranges :: proc(list: ^[dynamic]geom.Vertex_Range) {
	if len(list) < 2 do return
	slice.sort_by(list[:], proc(a, b: geom.Vertex_Range) -> bool {return a.first < b.first})
	out := 0
	for r in list[1:] {
		end := list[out].first + list[out].count
		if r.first <= end {
			list[out].count = max(end, r.first + r.count) - list[out].first
		} else {
			out += 1
			list[out] = r
		}
	}
	resize(list, out + 1)
}

@(private)
coalesce_index_ranges :: proc(list: ^[dynamic]geom.Index_Range) {
	if len(list) < 2 do return
	slice.sort_by(list[:], proc(a, b: geom.Index_Range) -> bool {return a.first_index < b.first_index})
	out := 0
	for r in list[1:] {
		end := list[out].first_index + list[out].index_count
		if r.first_index <= end {
			list[out].index_count = max(end, r.first_index + r.index_count) - list[out].first_index
		} else {
			out += 1
			list[out] = r
		}
	}
	resize(list, out + 1)
}

// One chunk per node with triangles, in index order, as the renderer's culling needs.
@(private)
surface_chunks_rebuild :: proc(s: ^Surface) {
	clear(&s.chunks)
	for n in s.nodes {
		if n.idx_count == 0 do continue
		// A cutoff of 1 means the chunk is never back-face culled: nodes have no normal cone yet.
		append(&s.chunks, geom.Chunk{bounds = n.bounds, cone_cutoff = 1, first_index = n.idx_first, index_count = n.idx_count})
	}
	slice.sort_by(s.chunks[:], proc(a, b: geom.Chunk) -> bool {return a.first_index < b.first_index})
}

// Grows the arrays when the holes are below the reserve. Growth sets `regrow`.
@(private)
surface_reserve :: proc(s: ^Surface) {
	holes_v, holes_i := 0, 0
	for h in s.free_verts do holes_v += int(h.count)
	for h in s.free_indices do holes_i += int(h.index_count)
	used_v := len(s.mesh.positions) - holes_v
	used_i := len(s.mesh.indices) - holes_i
	surface_make_room(s, int(f32(used_v) * RESERVE_FRACTION), int(f32(used_i) * RESERVE_FRACTION))
}

// Lays every slot out again, in node order, when the holes have grown past the fraction,
// and tops the reserve up. At a stroke's end only, since the GPU copy is remade after it.
surface_compact_if_needed :: proc(c: ^Clay) {
	s := &c.surface
	defer surface_reserve(s)
	if len(s.mesh.positions) < COMPACT_MIN_VERTS do return
	holes := 0
	for h in s.free_verts do holes += int(h.count)
	if f32(holes) < f32(len(s.mesh.positions)) * COMPACT_FRACTION do return
	surface_compact(s)
}

// Lays every slot out again, in node order, with no holes between them (the weld test
// compacts on purpose; the surface otherwise compacts when it has to, above).
@(private)
surface_compact :: proc(s: ^Surface) {
	holes := 0
	for h in s.free_verts do holes += int(h.count)
	positions := make([dynamic]Vec3, 1, len(s.mesh.positions) - holes, s.allocator)
	normals := make([dynamic]Vec3, 1, len(s.mesh.positions) - holes, s.allocator)
	codes := make([dynamic]u32, 1, len(s.mesh.positions) - holes, s.allocator)
	indices := make([dynamic]u32, s.allocator)
	for &n in s.nodes {
		if n.vert_cap == 0 do continue
		vf, ifi := u32(len(positions)), u32(len(indices))
		append(&positions, ..s.mesh.positions[n.vert_first:][:n.vert_count])
		append(&normals, ..s.mesh.normals[n.vert_first:][:n.vert_count])
		append(&codes, ..s.codes[n.vert_first:][:n.vert_count])
		resize(&positions, int(vf + n.vert_cap))
		resize(&normals, int(vf + n.vert_cap))
		resize(&codes, int(vf + n.vert_cap))
		resize(&indices, int(ifi + n.idx_cap))
		for k, j in s.mesh.indices[n.idx_first:][:n.idx_count] do indices[int(ifi) + j] = k - n.vert_first + vf
		n.vert_first, n.idx_first = vf, ifi
	}
	delete(s.mesh.positions)
	delete(s.mesh.normals)
	delete(s.codes)
	delete(s.mesh.indices)
	s.mesh.positions, s.mesh.normals, s.codes, s.mesh.indices = positions, normals, codes, indices
	clear(&s.free_verts)
	clear(&s.free_indices)
	surface_chunks_rebuild(s)
	s.regrow = true
}

// Meshes one node: surface nets over its 16³ voxel cells and the cell layer before them,
// with a vertex per loop of edge crossings in each cell the surface crosses, at the mean of
// the loop's crossings, and a quad per crossed edge the node owns (the edge's lower voxel
// is in the node) joining the vertices of the loops holding that edge in the four cells
// around it. The field has no saddle faces (saddle.odin), so every cell face has two
// crossings or none and the crossings of a cell fall into loops; a quad side then lies in
// exactly two quads and a vertex's quads form one cycle: the surface is closed and
// manifold.
@(private)
mesh_node :: proc(c: ^Clay, r: ^Mesh_Result) {
	heap := runtime.heap_allocator()
	n := c.surface.nodes[r.node]
	lo := n.coord * NODE - 2
	window := make([]i16, MESH_WINDOW_VOXELS, heap)
	defer delete(window, heap)
	gather_window(&c.volume, lo, MESH_WINDOW, window)
	cells := make([]Cell_Verts, MESH_CELLS * MESH_CELLS * MESH_CELLS, heap)
	defer delete(cells, heap)
	for &cell in cells do cell.first = CELL_NONE
	r.positions = make([dynamic]Vec3, heap)
	r.normals = make([dynamic]Vec3, heap)
	r.codes = make([dynamic]u32, heap)
	r.indices = make([dynamic]u32, heap)
	r.bounds = geom.AABB_EMPTY
	for axis in 0 ..< 3 {
		b, cc := (axis + 1) % 3, (axis + 2) % 3
		for z in 0 ..< NODE do for y in 0 ..< NODE do for x in 0 ..< NODE {
			g := [3]int{x, y, z}
			i0 := window_index(g + 2)
			h := g
			h[axis] += 1
			d0, d1 := window[i0], window[window_index(h + 2)]
			if (d0 < 0) == (d1 < 0) do continue
			// The four cells around the edge, counter-clockwise about +axis; in each the
			// edge starts at the corner offset by what the cell was moved.
			quad: [4]u32
			for k in 0 ..< 4 {
				cell := g
				corner := 0
				if k == 1 || k == 2 {
					cell[b] -= 1
					corner |= 1 << uint(b)
				}
				if k == 2 || k == 3 {
					cell[cc] -= 1
					corner |= 1 << uint(cc)
				}
				quad[k] = cell_vertex(c, r, window, cells, n.coord, cell, cell_edge(axis, corner))
			}
			// Outward is toward the positive value.
			if d0 >= 0 do quad[1], quad[3] = quad[3], quad[1]
			append(&r.indices, quad[0], quad[1], quad[2], quad[0], quad[2], quad[3])
		}
	}
	// A cell on the node's far faces (15 along an axis) may be crossed only through edges
	// whose lower voxel is at 16 along another axis, which the next node owns and the loop
	// above never visits; those edges are checked here and the far cells around them get
	// their vertices all the same, since this node owns the cells and the weld
	// (convert.odin) sends the neighbours' copies to it.
	for axis in 0 ..< 3 {
		b, cc := (axis + 1) % 3, (axis + 2) % 3
		for pass in 0 ..< 2 {
			o := b if pass == 0 else cc // the axis at 16
			p := cc if pass == 0 else b // and the other
			for i in 0 ..< NODE do for j in 0 ..< NODE + 1 - pass { // the corner edge (both at 16) once
				g: [3]int
				g[axis], g[o], g[p] = i, NODE, j
				i0 := window_index(g + 2)
				h := g
				h[axis] += 1
				if (window[i0] < 0) == (window[window_index(h + 2)] < 0) do continue
				for side in 0 ..< 2 {
					cell := g
					cell[o] -= 1
					cell[p] -= side
					if cell[p] < 0 || cell[p] >= NODE do continue
					if cells[((cell.z + 1) * MESH_CELLS + cell.y + 1) * MESH_CELLS + cell.x + 1].first != CELL_NONE do continue
					corner := 1 << uint(o) | side << uint(p)
					_ = cell_vertex(c, r, window, cells, n.coord, cell, cell_edge(axis, corner))
				}
			}
		}
	}
	for p in r.positions do geom.aabb_grow(&r.bounds, p)
}

@(private)
window_index :: #force_inline proc(g: [3]int) -> int {
	return (g.z * MESH_WINDOW + g.y) * MESH_WINDOW + g.x
}

// A cell's edges, as corner pairs: along x, then y, then z, each in corner order. Corner k
// is at (k & 1, k >> 1 & 1, k >> 2 & 1).
CELL_EDGES :: [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
// Each face's four edges (indices into CELL_EDGES): the faces square to x at x = 0 and 1,
// then y, then z.
CELL_FACES :: [6][4]int{{4, 6, 8, 10}, {5, 7, 9, 11}, {0, 2, 8, 9}, {1, 3, 10, 11}, {0, 1, 4, 5}, {2, 3, 6, 7}}
// The most loops a cell can have: with no saddle face, two (the inside corners form at
// most two groups); four is what twelve edges in loops of three would allow.
CELL_LOOPS :: 4
LOOP_NONE :: i8(-1)
// What a zero voxel value is read as where a crossing is placed: a quarter of a quantum.
ZERO_OUTSIDE :: f32(0.25)

// A cell's vertices: the index of the first (CELL_NONE until the cell is met) and, per
// edge, which of its loops the edge is in.
Cell_Verts :: struct {
	first: u32,
	loop:  [12]i8,
}

// The index in CELL_EDGES of the edge along `axis` starting at `corner` (whose bit for
// the axis is clear).
@(private)
cell_edge :: #force_inline proc(axis, corner: int) -> int {
	switch axis {
	case 0:
		return corner >> 1
	case 1:
		return 4 + (corner & 1) + (corner >> 2 & 1) * 2
	}
	return 8 + (corner & 3)
}

// The vertex of `cell` (node-local, from −1) for the loop holding its edge `edge`; the
// cell's loops and their vertices are made the first time the cell is met. Every node that
// shares the cell runs this same proc on the same voxel values, so the copies agree bit for
// bit: never inline it, or the compiler may fold the arithmetic differently per caller.
@(private)
cell_vertex :: #force_no_inline proc(c: ^Clay, r: ^Mesh_Result, window: []i16, cells: []Cell_Verts, nc: [3]i32, cell: [3]int, edge: int) -> u32 {
	at := ((cell.z + 1) * MESH_CELLS + cell.y + 1) * MESH_CELLS + cell.x + 1
	cv := &cells[at]
	if cv.first != CELL_NONE do return cv.first + u32(cv.loop[edge])
	// Corner k is at cell + (k & 1, k >> 1 & 1, k >> 2 & 1); window index of the cell's
	// first corner is cell + 2.
	base := window_index(cell + 2)
	corner: [8]f32
	for k in 0 ..< 8 {
		corner[k] = f32(window[base + (k & 1) + (k >> 1 & 1) * MESH_WINDOW + (k >> 2 & 1) * MESH_WINDOW * MESH_WINDOW])
	}
	// The crossed edges, joined into loops through the faces: a face's two crossed edges
	// are in one loop (a face with four, a saddle the field should not hold, pairs them in
	// edge order rather than fail).
	crossed: [12]bool
	group: [12]int // union-find over the edges
	for e, i in CELL_EDGES {
		crossed[i] = (corner[e[0]] < 0) != (corner[e[1]] < 0)
		group[i] = i
	}
	find :: proc(group: ^[12]int, i: int) -> int {
		j := i
		for group[j] != j do j = group[j]
		return j
	}
	for face in CELL_FACES {
		last := -1
		for e in face {
			if !crossed[e] do continue
			if last < 0 {
				last = e
				continue
			}
			a, b := find(&group, last), find(&group, e)
			group[max(a, b)] = min(a, b)
			last = -1
		}
	}
	// Loops numbered in the order of their first edge.
	count := 0
	loop_of_root: [12]i8
	for i in 0 ..< 12 {
		cv.loop[i] = LOOP_NONE
		if !crossed[i] do continue
		root := find(&group, i)
		if root == i {
			loop_of_root[i] = i8(count)
			count += 1
		}
		cv.loop[i] = loop_of_root[root]
	}
	assert(count >= 1 && count <= CELL_LOOPS, "a crossed cell has one to four loops")
	cv.first = u32(len(r.positions))
	// The cell's code: its index in the node that owns it, and the axes it is at −1 along.
	code := u32(0)
	for a in 0 ..< 3 {
		coord := cell[a]
		if coord < 0 {
			code |= 1 << uint(CODE_OFFSET_SHIFT + a)
			coord = NODE - 1
		}
		code |= u32(coord) << uint(4 * a)
	}
	v := &c.volume
	for l in 0 ..< count {
		// The mean of the loop's crossings.
		sum: Vec3
		n: f32
		for e, i in CELL_EDGES {
			if cv.loop[i] != i8(l) do continue
			a, b := corner[e[0]], corner[e[1]]
			// A voxel exactly on the surface (0, which counts as outside) would put the
			// crossing on the lattice point, where every cell around the point would set
			// its vertex, one on top of another; it is read as a hair outside instead.
			if a == 0 do a = ZERO_OUTSIDE
			if b == 0 do b = ZERO_OUTSIDE
			t := a / (a - b)
			p0 := Vec3{f32(e[0] & 1), f32(e[0] >> 1 & 1), f32(e[0] >> 2 & 1)}
			p1 := Vec3{f32(e[1] & 1), f32(e[1] >> 1 & 1), f32(e[1] >> 2 & 1)}
			sum += p0 + (p1 - p0) * t
			n += 1
		}
		local := sum / n
		// The normal: the central-difference gradient at each corner, blended at the vertex.
		grad: [8]Vec3
		for k in 0 ..< 8 {
			i := base + (k & 1) + (k >> 1 & 1) * MESH_WINDOW + (k >> 2 & 1) * MESH_WINDOW * MESH_WINDOW
			grad[k] = {
				f32(window[i + 1]) - f32(window[i - 1]),
				f32(window[i + MESH_WINDOW]) - f32(window[i - MESH_WINDOW]),
				f32(window[i + MESH_WINDOW * MESH_WINDOW]) - f32(window[i - MESH_WINDOW * MESH_WINDOW]),
			}
		}
		gx0 := linalg.lerp(grad[0], grad[1], local.x)
		gx1 := linalg.lerp(grad[2], grad[3], local.x)
		gx2 := linalg.lerp(grad[4], grad[5], local.x)
		gx3 := linalg.lerp(grad[6], grad[7], local.x)
		gy0 := linalg.lerp(gx0, gx1, local.y)
		gy1 := linalg.lerp(gx2, gx3, local.y)
		normal := linalg.normalize0(linalg.lerp(gy0, gy1, local.z))
		vox := Vec3{f32(nc.x * NODE + i32(cell.x)), f32(nc.y * NODE + i32(cell.y)), f32(nc.z * NODE + i32(cell.z))} + local
		append(&r.positions, v.origin + vox * v.voxel)
		append(&r.normals, normal)
		append(&r.codes, code | u32(l) << CODE_LOOP_SHIFT)
	}
	return cv.first + u32(cv.loop[edge])
}
