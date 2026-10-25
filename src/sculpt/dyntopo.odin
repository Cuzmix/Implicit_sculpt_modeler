package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Dynamic topology, as in Sculptris and Blender's dyntopo: while it is on, each dab
// first splits the edges under the brush that are longer than the detail size (a
// share of the brush radius) and collapses the ones much shorter, so the brush makes
// triangles where it goes, about as many as it needs to show its detail.
//
// The sculptor keeps working the way it does for a fixed mesh: nodes own contiguous
// vertex and triangle ranges, and dabs, normals, bounds and GPU uploads work per node.
// What changes is the layout: each node gets a page of DYN_PAGE_VERTS vertex slots and
// DYN_PAGE_TRIS triangle slots, of which it uses the first vert_count and tri_count, so
// a node grows and shrinks in place. A node whose page fills up splits in two. Unused
// triangle slots hold (0, 0, 0), which draws nothing. Each vertex lists the triangles
// it is in (up to DYN_FACES), so the edits are local and cheap, and so are the normal
// and smoothing passes that read those lists.
//
// Undo saves a whole node (positions, triangles, masks) before an edit first touches
// it in a stroke, and swaps it back; what depends on the triangles (the lists above,
// the nodes' shared vertices, the BVH) is rebuilt for the nodes that changed.
//
// While dynamic, a sculptor has no subdivision levels, HD or simplified copies; turning
// it off packs the mesh again (sculptor_dyn_disable).

DYN_PAGE_TRIS :: 2048
DYN_PAGE_VERTS :: 1280
// Most triangles a vertex may be in. A mesh with more is refused, and an edit that
// would make more is skipped.
DYN_FACES :: 16
// Edges shorter than this share of the detail size collapse (as in Blender), so a
// split edge's halves never qualify.
DYN_COLLAPSE_SHARE :: 0.4
// A collapse may not make a triangle of lower quality than this (see
// triangle_quality; 0.3 is about a 12 degree corner) unless one as bad was there
// already: collapsing into midpoints with no such check leaves slivers when a fine area
// is coarsened.
DYN_MIN_QUALITY :: 0.3
// A collapse may not leave a vertex in more triangles than this, which keeps fans from
// building up where many edges collapse into one point.
DYN_MAX_VALENCE :: 12
// Edits per dab: a large brush over a coarse mesh carries on in the next dabs, so a
// single dab stays within a few milliseconds.
DYN_MAX_SPLITS :: 2048
DYN_MAX_COLLAPSES :: 2048

@(private)
DYN_NONE :: max(u32)

Dyn :: struct {
	allocator:      runtime.Allocator,
	node_triangles: u32, // the fixed layout's node size, for sculptor_dyn_disable
	pages:          int, // pages the mesh's arrays (and every per-node array) hold
	faces:          []u32, // per vertex slot: DYN_FACES triangle slots, face_count of them used
	face_count:     []u8,
	shared:         [][dynamic]u32, // per node: vertices of its triangles in other nodes' pages
	owners:         [][dynamic]u32, // per node: those pages' nodes
	free:           [dynamic]u32, // nodes that may be empty, for new nodes to reuse
	// Nodes whose triangles changed since the last flush, which reports their pages.
	topo:           []bool,
	topo_nodes:     [dynamic]u32,
	index_ranges:   [dynamic]geom.Index_Range,
	tree_stale:     bool, // a node gained its first triangle or lost its last: rebuild the BVH
	// Per node: its bounds, for nodes the BVH has no leaf for yet. Chunk bounds wait for
	// the flush, which needs them as they were for the partial redraw.
	bounds:         []geom.Aabb,
	// Edits of the dab in progress: nodes they changed, and how.
	affected:       [dynamic]u32,
	affect:         []u8, // per node: Affect bits, zero outside a dab's edits
	vstamp:         []u32, // per vertex slot, and per node, for de-duplicating
	nstamp:         []u32,
	stamp:          u32,
	max2, min2:     f32, // squared detail size and collapse length of the dab in progress
	collapse:       bool,
	long:           [dynamic]Dyn_Edge, // edges to split, longest first (a heap)
	short:          [dynamic]Dyn_Edge,
	cand_long:      [dynamic][dynamic]Dyn_Edge, // per hit leaf, filled in parallel
	cand_short:     [dynamic][dynamic]Dyn_Edge,
	splits:         int, // edits so far, for the stats
	collapses:      int,
}

@(private)
Dyn_Edge :: struct {
	l2:       f32,
	a, b:     u32,
	forced:   bool, // split first for a shorter one in the brush, wherever its middle is
	deferred: bool, // came back after a longer edge of its triangles went first
}

@(private)
Affect :: enum u8 {
	Topo,  // its triangles changed: shared vertices, GPU indices
	Shape, // its triangles moved or changed: bounds, normals
}

@(private)
Op :: enum u8 {
	Done,
	Gone, // the edge is no longer there, or no longer qualifies
	Skip, // it cannot be edited (valence, mask, a fold, an open edge)
	Full, // a page has no room: split the node `full` and try again
}

// The node whose page holds vertex slot v, and triangle slot t.
@(private)
vert_page :: #force_inline proc(v: u32) -> u32 {return v / DYN_PAGE_VERTS}
@(private)
tri_page :: #force_inline proc(t: u32) -> u32 {return t / DYN_PAGE_TRIS}

@(private)
dyn_faces :: #force_inline proc(d: ^Dyn, v: u32) -> []u32 {
	return d.faces[int(v) * DYN_FACES:][:d.face_count[v]]
}

@(private)
face_add :: #force_inline proc(d: ^Dyn, v, t: u32) {
	c := d.face_count[v]
	assert(c < DYN_FACES, "vertex in too many triangles")
	d.faces[int(v) * DYN_FACES + int(c)] = t
	d.face_count[v] = c + 1
}

@(private)
face_remove :: proc(d: ^Dyn, v, t: u32) {
	list := dyn_faces(d, v)
	for f, i in list {
		if f != t do continue
		list[i] = list[len(list) - 1]
		d.face_count[v] -= 1
		return
	}
	panic("triangle missing from its vertex's list")
}

@(private)
face_replace :: proc(d: ^Dyn, v, from, to: u32) {
	for &f in dyn_faces(d, v) {
		if f == from {
			f = to
			return
		}
	}
	panic("triangle missing from its vertex's list")
}

// Switches the sculptor to dynamic topology: lays the mesh out in pages and builds
// what the edits need. Clears the undo history. Returns false, changing nothing, when
// a vertex is in more than DYN_FACES triangles, or an edge is in more than two
// triangles or in two that run it the same way (remesh such a mesh first). Edges with
// one triangle, on the border of an open mesh, stay as they are.
sculptor_dyn_enable :: proc(s: ^Sculptor, allocator := context.allocator) -> bool {
	if s.dyn != nil do return true
	m := s.mesh
	for v in 0 ..< len(m.positions) {
		if len(geom.vertex_faces_of(s.faces, u32(v))) > DYN_FACES do return false
	}
	if !edges_manifold(s) do return false
	sculptor_clear_history(s)
	hide_drop(s) // triangles are about to be split and collapsed
	sculptor_morph_clear(s) // the vertices are about to be renumbered
	// Bounds, cones and shared lists carry over from the fixed layout: bring them up
	// to date first.
	_ = sculptor_flush(s)
	nodes := len(s.nodes)
	d := new(Dyn, allocator)
	d.allocator = allocator
	d.node_triangles = s.bvh.leaf_size
	// Each node fills about half its page; a few spare pages for the first splits, and
	// more come as needed (dyn_grow).
	d.pages = nodes + nodes / 8 + 16
	Convert :: struct {
		s:          ^Sculptor,
		d:          ^Dyn,
		old_to_new: []u32,
		positions:  [dynamic]Vec3,
		normals:    [dynamic]Vec3,
		indices:    [dynamic]u32,
		mask:       []u8,
	}
	c := Convert {
		s          = s,
		d          = d,
		old_to_new = make([]u32, len(m.positions), context.temp_allocator),
		positions  = make([dynamic]Vec3, d.pages * DYN_PAGE_VERTS, m.positions.allocator),
		normals    = make([dynamic]Vec3, d.pages * DYN_PAGE_VERTS, m.normals.allocator),
		indices    = make([dynamic]u32, d.pages * DYN_PAGE_TRIS * 3, m.indices.allocator),
	}
	if s.mask != nil do c.mask = make([]u8, d.pages * DYN_PAGE_VERTS, s.history.allocator)
	d.faces = make([]u32, d.pages * DYN_PAGE_VERTS * DYN_FACES, allocator)
	d.face_count = make([]u8, d.pages * DYN_PAGE_VERTS, allocator)
	d.shared = make([][dynamic]u32, d.pages, allocator)
	d.owners = make([][dynamic]u32, d.pages, allocator)
	for id in 0 ..< d.pages {
		d.shared[id] = make([dynamic]u32, runtime.heap_allocator())
		d.owners[id] = make([dynamic]u32, runtime.heap_allocator())
	}
	// Vertices and triangles keep their order within their node.
	jobs.parallel_for(s.pool, nodes, &c, proc(data: rawptr, id: int) {
		c := cast(^Convert)data
		s, m := c.s, c.s.mesh
		n := s.nodes[id]
		assert(n.vert_count <= DYN_PAGE_VERTS && n.tri_count <= DYN_PAGE_TRIS)
		first := u32(id) * DYN_PAGE_VERTS
		for k in 0 ..< n.vert_count {
			old := n.vert_first + k
			c.old_to_new[old] = first + k
			c.positions[first + k] = m.positions[old]
			c.normals[first + k] = m.normals[old]
			if c.mask != nil do c.mask[first + k] = s.mask[old]
		}
	})
	jobs.parallel_for(s.pool, nodes, &c, proc(data: rawptr, id: int) {
		c := cast(^Convert)data
		s, m := c.s, c.s.mesh
		n := s.nodes[id]
		page := u32(id) * DYN_PAGE_TRIS
		for k in 0 ..< 3 * n.tri_count do c.indices[3 * page + k] = c.old_to_new[m.indices[3 * n.tri_first + k]]
		// The triangles of each vertex, in the order the fixed layout lists them.
		for k in 0 ..< n.vert_count {
			old := n.vert_first + k
			v := c.old_to_new[old]
			for f in geom.vertex_faces_of(s.faces, old) {
				owner := s.node_of[s.bvh.tri_leaf[f]]
				face_add(c.d, v, owner * DYN_PAGE_TRIS + (f - s.nodes[owner].tri_first))
			}
		}
		// The same vertices of other nodes, and the same nodes, under the new numbers.
		shared := &c.d.shared[id]
		resize(shared, int(n.shared_count))
		for v, k in s.shared[n.shared_first:][:n.shared_count] do shared[k] = c.old_to_new[v]
		append(&c.d.owners[id], ..s.owners[n.owner_first:][:n.owner_count])
	})
	delete(m.positions)
	delete(m.normals)
	delete(m.indices)
	m.positions, m.normals, m.indices = c.positions, c.normals, c.indices
	if s.mask != nil {
		delete(s.mask, s.history.allocator)
		s.mask = c.mask
	}

	// Nodes: one per page, the rest of the pages free. A node keeps its leaf's bounds,
	// for the new tree, and its chunk, with its triangles where the page has them.
	old_nodes := s.nodes
	s.nodes = make([]Node, d.pages, allocator)
	d.bounds = make([]geom.Aabb, d.pages, allocator)
	for &n, id in s.nodes {
		n = {vert_first = u32(id) * DYN_PAGE_VERTS, tri_first = u32(id) * DYN_PAGE_TRIS, leaf = geom.BVH_NONE}
		d.bounds[id] = geom.AABB_EMPTY
		if id >= nodes do continue
		n.vert_count, n.tri_count = old_nodes[id].vert_count, old_nodes[id].tri_count
		d.bounds[id] = s.bvh.nodes[old_nodes[id].leaf].bounds
		s.chunks[id].first_index = 3 * n.tri_first
	}
	delete(old_nodes)
	geom.vertex_faces_destroy(&s.faces)
	delete(s.shared)
	delete(s.owners)
	s.shared, s.owners = {}, {}
	lod_destroy(&s.lod)
	s.lod = {}
	s.dyn = d
	d.topo = make([]bool, d.pages, allocator)
	d.affect = make([]u8, d.pages, allocator)
	d.nstamp = make([]u32, d.pages, allocator)
	d.vstamp = make([]u32, d.pages * DYN_PAGE_VERTS, allocator)
	d.topo_nodes = make([dynamic]u32, 0, 256, allocator)
	d.index_ranges = make([dynamic]geom.Index_Range, 0, 256, allocator)
	d.free = make([dynamic]u32, 0, d.pages, allocator)
	d.affected = make([dynamic]u32, 0, 256, allocator)
	d.long = make([dynamic]Dyn_Edge, 0, 1024, allocator)
	d.short = make([dynamic]Dyn_Edge, 0, 1024, allocator)
	d.cand_long = make([dynamic][dynamic]Dyn_Edge, allocator)
	d.cand_short = make([dynamic][dynamic]Dyn_Edge, allocator)
	for id := d.pages - 1; id >= nodes; id -= 1 do append(&d.free, u32(id))
	resize_node_arrays(s, d.pages)
	for id in nodes ..< d.pages do s.chunks[id] = {bounds = geom.AABB_EMPTY, first_index = 3 * u32(id) * DYN_PAGE_TRIS}
	rebuild_tree(s)
	return true
}

// Packs the mesh back into the fixed layout and prepares it as sculptor_init does,
// keeping the mask. Clears the undo history.
sculptor_dyn_disable :: proc(s: ^Sculptor, allocator := context.allocator) {
	d := s.dyn
	if d == nil do return
	mesh, mask := sculptor_compact_mesh(s, s.mesh.positions.allocator)
	pool := s.pool
	node_triangles := d.node_triangles
	m := s.mesh
	sculptor_destroy(s)
	geom.mesh_destroy(m)
	m^ = mesh
	old_to_new: []u32
	if mask != nil do old_to_new = make([]u32, len(m.positions), context.temp_allocator)
	sculptor_init(s, m, pool, node_triangles, old_to_new, allocator)
	if mask != nil {
		s.mask = make([]u8, len(m.positions), s.history.allocator)
		for k, old in mask do s.mask[old_to_new[old]] = k
		delete(mask)
	}
}

// The mesh as a plain one, every used vertex and triangle in page order, and its mask
// (nil when it has none). For a fixed layout, a copy.
sculptor_compact_mesh :: proc(s: ^Sculptor, allocator := context.allocator) -> (out: geom.Mesh, mask: []u8) {
	m := s.mesh
	if s.dyn == nil {
		out.positions = make([dynamic]Vec3, len(m.positions), allocator)
		out.normals = make([dynamic]Vec3, len(m.normals), allocator)
		out.indices = make([dynamic]u32, len(m.indices), allocator)
		copy(out.positions[:], m.positions[:])
		copy(out.normals[:], m.normals[:])
		copy(out.indices[:], m.indices[:])
		if s.mask != nil do mask = slice.clone(s.mask, allocator)
		return
	}
	Compact :: struct {
		s:            ^Sculptor,
		out:          ^geom.Mesh,
		mask:         []u8,
		vfirst, tfirst: []u32, // per node: where its vertices and triangles go
	}
	c := Compact {
		s      = s,
		out    = &out,
		vfirst = make([]u32, len(s.nodes) + 1, context.temp_allocator),
		tfirst = make([]u32, len(s.nodes) + 1, context.temp_allocator),
	}
	for n, id in s.nodes {
		c.vfirst[id + 1] = c.vfirst[id] + n.vert_count
		c.tfirst[id + 1] = c.tfirst[id] + n.tri_count
	}
	vertices, triangles := int(c.vfirst[len(s.nodes)]), int(c.tfirst[len(s.nodes)])
	out.positions = make([dynamic]Vec3, vertices, allocator)
	out.normals = make([dynamic]Vec3, vertices, allocator)
	out.indices = make([dynamic]u32, 3 * triangles, allocator)
	if s.mask != nil do mask = make([]u8, vertices, allocator)
	c.mask = mask
	jobs.parallel_for(s.pool, len(s.nodes), &c, proc(data: rawptr, id: int) {
		c := cast(^Compact)data
		s, m, out := c.s, c.s.mesh, c.out
		n := s.nodes[id]
		to := c.vfirst[id]
		copy(out.positions[to:][:n.vert_count], m.positions[n.vert_first:][:n.vert_count])
		copy(out.normals[to:][:n.vert_count], m.normals[n.vert_first:][:n.vert_count])
		if c.mask != nil do copy(c.mask[to:][:n.vert_count], s.mask[n.vert_first:][:n.vert_count])
		// A vertex's new number follows from its page's place in the order.
		for k in 0 ..< 3 * n.tri_count {
			v := m.indices[3 * n.tri_first + k]
			page := vert_page(v)
			out.indices[3 * c.tfirst[id] + k] = c.vfirst[page] + (v - page * DYN_PAGE_VERTS)
		}
	})
	return
}

// Vertices and triangles in use: the mesh's sizes for a fixed layout.
sculptor_vertex_count :: proc(s: ^Sculptor) -> int {
	if s.dyn == nil do return len(s.mesh.positions)
	total := 0
	for n in s.nodes do total += int(n.vert_count)
	return total
}

sculptor_triangle_count :: proc(s: ^Sculptor) -> int {
	if s.dyn == nil do return len(s.mesh.indices) / 3
	total := 0
	for n in s.nodes do total += int(n.tri_count)
	return total
}

sculptor_is_dynamic :: proc(s: ^Sculptor) -> bool {return s.dyn != nil}

// Bytes the dynamic layout adds: the triangle lists and per-node data (the mesh's
// arrays, unused slots included, count as the mesh's own).
sculptor_dyn_bytes :: proc(s: ^Sculptor) -> int {
	d := s.dyn
	if d == nil do return 0
	total := len(d.faces) * size_of(u32) + len(d.face_count) + len(d.vstamp) * size_of(u32)
	for id in 0 ..< d.pages do total += (cap(d.shared[id]) + cap(d.owners[id])) * size_of(u32)
	return total
}

// Pages the mesh holds: its arrays are this many pages long.
sculptor_dyn_pages :: proc(s: ^Sculptor) -> int {return s.dyn.pages if s.dyn != nil else 0}

// Edges split and collapsed since dynamic topology was turned on, for the stats.
sculptor_dyn_edits :: proc(s: ^Sculptor) -> (splits, collapses: int) {
	if s.dyn == nil do return
	return s.dyn.splits, s.dyn.collapses
}

// Triangle slots the last sculptor_flush reported as changed, coalesced: upload these
// indices along with the vertex ranges. Always empty for a fixed layout.
sculptor_index_ranges :: proc(s: ^Sculptor) -> []geom.Index_Range {
	if s.dyn == nil do return nil
	return s.dyn.index_ranges[:]
}

@(private)
dyn_destroy :: proc(s: ^Sculptor) {
	d := s.dyn
	if d == nil do return
	a := d.allocator
	delete(d.faces, a)
	delete(d.face_count, a)
	for &l in d.shared do delete(l)
	for &l in d.owners do delete(l)
	delete(d.shared, a)
	delete(d.owners, a)
	delete(d.free)
	delete(d.topo, a)
	delete(d.topo_nodes)
	delete(d.index_ranges)
	delete(d.affected)
	delete(d.affect, a)
	delete(d.vstamp, a)
	delete(d.nstamp, a)
	delete(d.bounds, a)
	delete(d.long)
	delete(d.short)
	for &l in d.cand_long do delete(l)
	for &l in d.cand_short do delete(l)
	delete(d.cand_long)
	delete(d.cand_short)
	free(d, a)
	s.dyn = nil
}

// Grows every per-node array to `count` nodes; new entries are empty.
@(private)
resize_node_arrays :: proc(s: ^Sculptor, count: int) {
	grow :: proc(x: ^[]$T, n: int, allocator: runtime.Allocator) {
		if len(x) >= n do return
		y := make([]T, n, allocator)
		copy(y, x^)
		delete(x^, allocator)
		x^ = y
	}
	a := s.dyn.allocator
	grow(&s.chunks, count, a)
	grow(&s.stale, count, a)
	grow(&s.cone_waiting, count, a)
	grow(&s.edited, count, a)
	h := &s.history
	grow(&h.saved, count, h.allocator)
	grow(&h.changed, count, h.allocator)
	grow(&h.mask_saved, count, h.allocator)
	grow(&h.mask_changed, count, h.allocator)
}

// Makes room for `pages` pages in the mesh and every per-vertex and per-node array.
// New slots are zero.
@(private)
dyn_grow :: proc(s: ^Sculptor, pages: int) {
	d := s.dyn
	m := s.mesh
	old := d.pages
	if pages <= old do return
	resize(&m.positions, pages * DYN_PAGE_VERTS)
	resize(&m.normals, pages * DYN_PAGE_VERTS)
	resize(&m.indices, pages * DYN_PAGE_TRIS * 3)
	grow :: proc(x: ^[]$T, n: int, allocator: runtime.Allocator) {
		y := make([]T, n, allocator)
		copy(y, x^)
		delete(x^, allocator)
		x^ = y
	}
	a := d.allocator
	grow(&d.faces, pages * DYN_PAGE_VERTS * DYN_FACES, a)
	grow(&d.face_count, pages * DYN_PAGE_VERTS, a)
	grow(&d.vstamp, pages * DYN_PAGE_VERTS, a)
	if s.mask != nil do grow(&s.mask, pages * DYN_PAGE_VERTS, s.history.allocator)
	if s.fade != nil do grow(&s.fade, pages * DYN_PAGE_VERTS, a)
	nodes := make([]Node, pages, a)
	copy(nodes, s.nodes)
	delete(s.nodes, a)
	s.nodes = nodes
	for id in old ..< pages {
		s.nodes[id] = {vert_first = u32(id) * DYN_PAGE_VERTS, tri_first = u32(id) * DYN_PAGE_TRIS, leaf = geom.BVH_NONE}
	}
	grow(&d.shared, pages, a)
	grow(&d.owners, pages, a)
	for id in old ..< pages {
		d.shared[id] = make([dynamic]u32, runtime.heap_allocator())
		d.owners[id] = make([dynamic]u32, runtime.heap_allocator())
	}
	grow(&d.topo, pages, a)
	grow(&d.affect, pages, a)
	grow(&d.nstamp, pages, a)
	grow(&d.bounds, pages, a)
	for id in old ..< pages do d.bounds[id] = geom.AABB_EMPTY
	d.pages = pages
	resize_node_arrays(s, pages)
	for id := pages - 1; id >= old; id -= 1 do append(&d.free, u32(id))
	for id in old ..< pages do s.chunks[id] = {bounds = geom.AABB_EMPTY, first_index = 3 * u32(id) * DYN_PAGE_TRIS}
}

// An empty node for new triangles, from the free list or a new page. Saved for undo
// as empty, when a stroke is being recorded.
@(private)
new_node :: proc(s: ^Sculptor) -> u32 {
	d := s.dyn
	for {
		if len(d.free) == 0 do dyn_grow(s, d.pages + d.pages / 2 + 16)
		id := pop(&d.free)
		n := s.nodes[id]
		if n.vert_count == 0 && n.tri_count == 0 {
			touch(s, id)
			return id
		}
	}
}

// Before an edit changes a node: saves it for undo once per stroke.
@(private)
touch :: #force_inline proc(s: ^Sculptor, id: u32) {
	if s.history.recording do record_full(s, id)
}

// Notes that an edit changed the node.
@(private)
mark :: #force_inline proc(s: ^Sculptor, id: u32, what: bit_set[Affect;u8]) {
	d := s.dyn
	bits := transmute(u8)what
	if d.affect[id] == 0 do append(&d.affected, id)
	d.affect[id] |= bits
}

@(private)
add_vertex :: proc(s: ^Sculptor, id: u32, p, normal: Vec3, mask: u8) -> u32 {
	n := &s.nodes[id]
	v := n.vert_first + n.vert_count
	n.vert_count += 1
	s.mesh.positions[v] = p
	s.mesh.normals[v] = normal
	if s.mask != nil do s.mask[v] = mask
	s.dyn.face_count[v] = 0
	return v
}

@(private)
add_triangle :: proc(s: ^Sculptor, id: u32, a, b, c: u32) -> u32 {
	n := &s.nodes[id]
	t := n.tri_first + n.tri_count
	n.tri_count += 1
	idx := s.mesh.indices[:]
	idx[3 * t], idx[3 * t + 1], idx[3 * t + 2] = a, b, c
	return t
}

// Removes triangle t, already gone from its vertices' lists, by moving the page's
// last triangle into its slot.
@(private)
remove_triangle :: proc(s: ^Sculptor, t: u32) {
	d := s.dyn
	id := tri_page(t)
	n := &s.nodes[id]
	last := n.tri_first + n.tri_count - 1
	idx := s.mesh.indices[:]
	if t != last {
		for k in u32(0) ..< 3 {
			v := idx[3 * last + k]
			idx[3 * t + k] = v
			face_replace(d, v, last, t)
		}
	}
	idx[3 * last], idx[3 * last + 1], idx[3 * last + 2] = 0, 0, 0
	n.tri_count -= 1
	if n.tri_count == 0 {
		d.tree_stale = true
		append(&d.free, id)
	}
}

// Removes vertex v, in no triangle any more, by moving the page's last vertex into its
// slot and renumbering it in its triangles.
@(private)
remove_vertex :: proc(s: ^Sculptor, v: u32) {
	d := s.dyn
	m := s.mesh
	id := vert_page(v)
	n := &s.nodes[id]
	assert(d.face_count[v] == 0)
	last := n.vert_first + n.vert_count - 1
	if v != last {
		for f in dyn_faces(d, last) {
			touch(s, tri_page(f))
			mark(s, tri_page(f), {.Topo, .Shape})
			for k in u32(0) ..< 3 do if m.indices[3 * f + k] == last do m.indices[3 * f + k] = v
		}
		m.positions[v] = m.positions[last]
		m.normals[v] = m.normals[last]
		if s.mask != nil do s.mask[v] = s.mask[last]
		copy(d.faces[int(v) * DYN_FACES:][:DYN_FACES], d.faces[int(last) * DYN_FACES:][:DYN_FACES])
		d.face_count[v] = d.face_count[last]
		d.face_count[last] = 0
	}
	n.vert_count -= 1
}

// The triangle with the directed edge a -> b, and the corner of a in it.
// Whether an edge of v's triangles has no triangle running it the other way: v is on
// the border of an open mesh.
@(private = "file")
on_border :: proc(s: ^Sculptor, v: u32) -> bool {
	idx := s.mesh.indices[:]
	faces := dyn_faces(s.dyn, v)
	edges: for f in faces {
		w, _ := others(idx, f, v)
		for g in faces {
			if _, back := others(idx, g, v); back == w do continue edges
		}
		return true
	}
	return false
}

// Whether, on the fixed layout, each edge is run once by a triangle in each direction,
// or once in one direction on a border; the edits find an edge's triangles by its
// direction (find_edge).
@(private = "file")
edges_manifold :: proc(s: ^Sculptor) -> bool {
	Check :: struct {
		s:   ^Sculptor,
		bad: []bool, // per range
	}
	c := Check{s, make([]bool, (len(s.mesh.positions) + geom.RANGE_GRAIN - 1) / geom.RANGE_GRAIN, context.temp_allocator)}
	jobs.parallel_ranges(s.pool, len(s.mesh.positions), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Check)data
		idx := c.s.mesh.indices[:]
		for v in u32(lo) ..< u32(hi) {
			faces := geom.vertex_faces_of(c.s.faces, v)
			for f in faces {
				w, _ := others(idx, f, v)
				same, back := 0, 0
				for g in faces {
					g1, g2 := others(idx, g, v)
					same += int(g1 == w)
					back += int(g2 == w)
				}
				if same != 1 || back > 1 {
					c.bad[lo / geom.RANGE_GRAIN] = true
					return
				}
			}
		}
	}, geom.RANGE_GRAIN)
	return !slice.contains(c.bad, true)
}

@(private)
find_edge :: #force_inline proc(s: ^Sculptor, a, b: u32) -> (t, corner: u32) {
	idx := s.mesh.indices[:]
	for f in dyn_faces(s.dyn, a) {
		for k in u32(0) ..< 3 {
			if idx[3 * f + k] == a && idx[3 * f + (k + 1) % 3] == b do return f, k
		}
	}
	return DYN_NONE, 0
}

// Splits edge a-b at its middle into four triangles, or on the border of an open mesh
// its one triangle into two. When a page has no room, says which node to split first.
// c and d are the vertices across the edge (the same one on a border).
@(private)
split_edge :: proc(s: ^Sculptor, a, b: u32) -> (res: Op, full, m, c, d: u32) {
	dy := s.dyn
	mesh := s.mesh
	idx := mesh.indices[:]
	a, b := a, b
	t1, k1 := find_edge(s, a, b)
	if t1 == DYN_NONE {
		// A border edge run the other way.
		a, b = b, a
		t1, k1 = find_edge(s, a, b)
		if t1 == DYN_NONE do return .Gone, 0, 0, 0, 0
	}
	t2, k2 := find_edge(s, b, a)
	if t2 == DYN_NONE do return split_border_edge(s, a, b, t1, k1)
	c = idx[3 * t1 + (k1 + 2) % 3]
	d = idx[3 * t2 + (k2 + 2) % 3]
	if c == d || dy.face_count[c] >= DYN_FACES || dy.face_count[d] >= DYN_FACES do return .Skip, 0, 0, 0, 0
	n1, n2 := tri_page(t1), tri_page(t2)
	if s.nodes[n1].vert_count >= DYN_PAGE_VERTS do return .Full, n1, 0, 0, 0
	if s.nodes[n1].tri_count + (2 if n1 == n2 else 1) > DYN_PAGE_TRIS do return .Full, n1, 0, 0, 0
	if s.nodes[n2].tri_count >= DYN_PAGE_TRIS do return .Full, n2, 0, 0, 0
	touch(s, n1)
	touch(s, n2)
	mask: u8
	if s.mask != nil do mask = u8((u32(s.mask[a]) + u32(s.mask[b]) + 1) / 2)
	p := (mesh.positions[a] + mesh.positions[b]) * 0.5
	m = add_vertex(s, n1, p, linalg.normalize0(mesh.normals[a] + mesh.normals[b]), mask)
	if s.fade != nil do s.fade[m] = max(s.fade[a], s.fade[b])
	idx[3 * t1 + (k1 + 1) % 3] = m // a m c
	idx[3 * t2 + (k2 + 1) % 3] = m // b m d
	t3 := add_triangle(s, n1, m, b, c)
	t4 := add_triangle(s, n2, m, a, d)
	face_remove(dy, a, t2)
	face_add(dy, a, t4)
	face_remove(dy, b, t1)
	face_add(dy, b, t3)
	face_add(dy, c, t3)
	face_add(dy, d, t4)
	face_add(dy, m, t1)
	face_add(dy, m, t3)
	face_add(dy, m, t2)
	face_add(dy, m, t4)
	mark(s, n1, {.Topo, .Shape})
	mark(s, n2, {.Topo, .Shape})
	for v in ([4]u32{a, b, c, d}) do mark(s, vert_page(v), {.Shape})
	dy.splits += 1
	return .Done, 0, m, c, d
}

// Splits a border edge a-b (run a to b by its one triangle t1, from its corner k1)
// into two triangles, so that a triangle along the border is cut across its longest
// side like any other; the border keeps its shape, since the new vertex is on it.
@(private = "file")
split_border_edge :: proc(s: ^Sculptor, a, b, t1, k1: u32) -> (res: Op, full, m, c, d: u32) {
	dy := s.dyn
	mesh := s.mesh
	idx := mesh.indices[:]
	c = idx[3 * t1 + (k1 + 2) % 3]
	if dy.face_count[c] >= DYN_FACES do return .Skip, 0, 0, 0, 0
	n1 := tri_page(t1)
	if s.nodes[n1].vert_count >= DYN_PAGE_VERTS || s.nodes[n1].tri_count >= DYN_PAGE_TRIS do return .Full, n1, 0, 0, 0
	touch(s, n1)
	mask: u8
	if s.mask != nil do mask = u8((u32(s.mask[a]) + u32(s.mask[b]) + 1) / 2)
	p := (mesh.positions[a] + mesh.positions[b]) * 0.5
	m = add_vertex(s, n1, p, linalg.normalize0(mesh.normals[a] + mesh.normals[b]), mask)
	if s.fade != nil do s.fade[m] = max(s.fade[a], s.fade[b])
	idx[3 * t1 + (k1 + 1) % 3] = m // a m c
	t3 := add_triangle(s, n1, m, b, c)
	face_remove(dy, b, t1)
	face_add(dy, b, t3)
	face_add(dy, c, t3)
	face_add(dy, m, t1)
	face_add(dy, m, t3)
	mark(s, n1, {.Topo, .Shape})
	for v in ([3]u32{a, b, c}) do mark(s, vert_page(v), {.Shape})
	dy.splits += 1
	return .Done, 0, m, c, c
}

// How close to equilateral a triangle is: 1 for an equilateral one, 0 for one with no
// area (4√3 times the area over the sum of the squared edge lengths).
@(private = "file")
triangle_quality :: #force_inline proc(q: [3]Vec3) -> f32 {
	e0, e1, e2 := q[1] - q[0], q[2] - q[1], q[0] - q[2]
	sum := linalg.dot(e0, e0) + linalg.dot(e1, e1) + linalg.dot(e2, e2)
	if sum <= 0 do return 0
	return 2 * math.SQRT_THREE * linalg.length(linalg.cross(e0, -e2)) / sum
}

// Collapses edge a-b into its middle, keeping a. Refused where it would fold the
// surface over, change its topology, crowd a vertex or make an edge too long to keep.
@(private)
collapse_edge :: proc(s: ^Sculptor, a, b: u32) -> Op {
	dy := s.dyn
	mesh := s.mesh
	idx := mesh.indices[:]
	t1, k1 := find_edge(s, a, b)
	if t1 == DYN_NONE do return .Gone
	t2, k2 := find_edge(s, b, a)
	if t2 == DYN_NONE do return .Skip
	c := idx[3 * t1 + (k1 + 2) % 3]
	d := idx[3 * t2 + (k2 + 2) % 3]
	if c == d || dy.face_count[c] <= 3 || dy.face_count[d] <= 3 do return .Skip
	if int(dy.face_count[a]) + int(dy.face_count[b]) - 4 > DYN_MAX_VALENCE do return .Skip
	// Collapsing toward a border would pull it in, or pinch two borders into one vertex.
	if on_border(s, a) || on_border(s, b) do return .Skip
	if s.mask != nil && (s.mask[a] > 0 || s.mask[b] > 0) do return .Skip
	if s.fade != nil && (s.fade[a] < 255 || s.fade[b] < 255) do return .Skip
	// Only c and d may neighbour both, or the surface would pinch into a non-manifold
	// edge.
	ring: [2 * DYN_FACES]u32
	rn := 0
	for f in dyn_faces(dy, a) {
		for k in u32(0) ..< 3 {
			w := idx[3 * f + k]
			if w != a && w != b do ring[rn], rn = w, rn + 1
		}
	}
	p := (mesh.positions[a] + mesh.positions[b]) * 0.5
	for f in dyn_faces(dy, b) {
		for k in u32(0) ..< 3 {
			w := idx[3 * f + k]
			if w == a || w == b || w == c || w == d do continue
			if slice.contains(ring[:rn], w) do return .Skip
			if l := mesh.positions[w] - p; linalg.dot(l, l) > dy.max2 do return .Skip
		}
	}
	for w in ring[:rn] {
		if l := mesh.positions[w] - p; linalg.dot(l, l) > dy.max2 do return .Skip
	}
	// No triangle may turn over, nor become a sliver worse than any there was.
	worst_before, worst_after: f32 = 1, 1
	for v in ([2]u32{a, b}) {
		for f in dyn_faces(dy, v) {
			if f == t1 || f == t2 do continue
			q, o: [3]Vec3
			for k in u32(0) ..< 3 {
				w := idx[3 * f + k]
				o[k] = mesh.positions[w]
				q[k] = p if w == a || w == b else o[k]
			}
			before := face_normal(mesh, f)
			after := linalg.cross(q[1] - q[0], q[2] - q[0])
			if linalg.dot(before, after) <= 0 do return .Skip
			worst_before = min(worst_before, triangle_quality(o))
			worst_after = min(worst_after, triangle_quality(q))
		}
	}
	if worst_after < DYN_MIN_QUALITY && worst_after < worst_before do return .Skip

	// Save everything this changes for undo before changing any of it.
	touch(s, vert_page(a))
	touch(s, vert_page(b))
	for f in dyn_faces(dy, b) do touch(s, tri_page(f))
	face_remove(dy, a, t1)
	face_remove(dy, a, t2)
	face_remove(dy, b, t1)
	face_remove(dy, b, t2)
	face_remove(dy, c, t1)
	face_remove(dy, d, t2)
	for f in dyn_faces(dy, b) {
		for k in u32(0) ..< 3 do if idx[3 * f + k] == b do idx[3 * f + k] = a
		face_add(dy, a, f)
		mark(s, tri_page(f), {.Topo, .Shape})
	}
	dy.face_count[b] = 0
	mesh.positions[a] = p
	mark(s, tri_page(t1), {.Topo, .Shape})
	mark(s, tri_page(t2), {.Topo, .Shape})
	remove_triangle(s, max(t1, t2))
	remove_triangle(s, min(t1, t2))
	mark(s, vert_page(b), {.Shape})
	remove_vertex(s, b)
	// a moved: everything around it needs new bounds and normals. If it was the last
	// vertex of b's page, it now has b's slot.
	kept := a
	if a == vert_page(b) * DYN_PAGE_VERTS + s.nodes[vert_page(b)].vert_count do kept = b
	mark(s, vert_page(kept), {.Shape})
	for f in dyn_faces(dy, kept) {
		mark(s, tri_page(f), {.Shape})
		for k in u32(0) ..< 3 do mark(s, vert_page(idx[3 * f + k]), {.Shape})
	}
	dy.collapses += 1
	return .Done
}

// Splits a node whose page is full: the triangles on one side of its middle, along its
// longest axis, go to a new node, with the vertices only they use.
@(private)
split_node :: proc(s: ^Sculptor, id: u32) -> bool {
	d := s.dyn
	if s.nodes[id].tri_count < 2 do return false
	other := new_node(s) // may grow the arrays: take slices afterwards
	touch(s, id)
	m := s.mesh
	idx := m.indices[:]
	n := s.nodes[id]
	tris := make([][3]u32, n.tri_count, context.temp_allocator)
	bounds := geom.AABB_EMPTY
	for &t, k in tris {
		f := n.tri_first + u32(k)
		t = {idx[3 * f], idx[3 * f + 1], idx[3 * f + 2]}
		for v in t do geom.aabb_grow(&bounds, m.positions[v])
	}
	extent := bounds.hi - bounds.lo
	axis := 0
	if extent.y > extent[axis] do axis = 1
	if extent.z > extent[axis] do axis = 2
	keys := make([]f32, len(tris), context.temp_allocator)
	for t, k in tris do keys[k] = m.positions[t[0]][axis] + m.positions[t[1]][axis] + m.positions[t[2]][axis]
	sorted := slice.clone(keys, context.temp_allocator)
	slice.sort(sorted)
	middle := sorted[len(sorted) / 2]
	moving := 0
	for key in keys do moving += int(key >= middle)
	if moving == 0 || moving == len(keys) do return false

	// Triangles: off every list, into their new slots, back onto the lists.
	for t, k in tris do for v in t do face_remove(d, v, n.tri_first + u32(k))
	kept: u32
	moved: u32
	o := &s.nodes[other]
	for t, k in tris {
		slot: u32
		if keys[k] >= middle {
			slot = o.tri_first + moved
			moved += 1
		} else {
			slot = n.tri_first + kept
			kept += 1
		}
		idx[3 * slot], idx[3 * slot + 1], idx[3 * slot + 2] = t[0], t[1], t[2]
		for v in t do face_add(d, v, slot)
	}
	for k in 3 * (n.tri_first + kept) ..< 3 * (n.tri_first + n.tri_count) do idx[k] = 0
	s.nodes[id].tri_count = kept
	o.tri_count = moved

	// Vertices: one goes with the new node if most of its triangles did and all of
	// them are in the two nodes. Stayers past the end of the kept range fill the slots
	// leavers left below it.
	New_Slot :: struct {
		from, to: u32,
	}
	moves := make([dynamic]New_Slot, 0, n.vert_count, context.temp_allocator)
	goes := make([]bool, n.vert_count, context.temp_allocator)
	for k in 0 ..< n.vert_count {
		in_old, in_new := 0, 0
		elsewhere := false
		for f in dyn_faces(d, n.vert_first + k) {
			switch tri_page(f) {
			case id:
				in_old += 1
			case other:
				in_new += 1
			case:
				elsewhere = true
			}
		}
		goes[k] = in_new > in_old && !elsewhere
	}
	stay: u32
	for g in goes do stay += u32(!g)
	holes := make([dynamic]u32, 0, n.vert_count, context.temp_allocator)
	for k in 0 ..< stay do if goes[k] do append(&holes, k)
	filled := 0
	for k in 0 ..< n.vert_count {
		v := n.vert_first + k
		if goes[k] {
			append(&moves, New_Slot{v, o.vert_first + o.vert_count})
			o.vert_count += 1
		} else if k >= stay {
			append(&moves, New_Slot{v, n.vert_first + holes[filled]})
			filled += 1
		}
	}
	s.nodes[id].vert_count = stay
	// Renumber in two passes, marking new numbers with the top bit, so a vertex taking
	// the slot of one not yet renumbered is never mistaken for it.
	TOP :: u32(1) << 31
	for mv in moves {
		for f in dyn_faces(d, mv.from) {
			touch(s, tri_page(f))
			mark(s, tri_page(f), {.Topo, .Shape})
			for k in u32(0) ..< 3 do if idx[3 * f + k] == mv.from do idx[3 * f + k] = mv.to | TOP
		}
	}
	for mv in moves {
		for f in dyn_faces(d, mv.from) {
			for k in u32(0) ..< 3 do idx[3 * f + k] &~= TOP
		}
	}
	// Then the vertex data, through copies, since slots are both read and written.
	Vertex :: struct {
		p, n:  Vec3,
		mask:  u8,
		count: u8,
		faces: [DYN_FACES]u32,
	}
	saved := make([]Vertex, len(moves), context.temp_allocator)
	for mv, i in moves {
		saved[i] = {p = m.positions[mv.from], n = m.normals[mv.from], count = d.face_count[mv.from]}
		if s.mask != nil do saved[i].mask = s.mask[mv.from]
		copy(saved[i].faces[:], d.faces[int(mv.from) * DYN_FACES:][:DYN_FACES])
		d.face_count[mv.from] = 0
	}
	for mv, i in moves {
		x := saved[i]
		m.positions[mv.to], m.normals[mv.to] = x.p, x.n
		if s.mask != nil do s.mask[mv.to] = x.mask
		copy(d.faces[int(mv.to) * DYN_FACES:][:DYN_FACES], x.faces[:])
		d.face_count[mv.to] = x.count
	}
	mark(s, id, {.Topo, .Shape})
	mark(s, other, {.Topo, .Shape})
	d.tree_stale = true
	return true
}

// Lists the vertices of a node's triangles that live in other pages, and those pages.
@(private)
refresh_shared :: proc(s: ^Sculptor, id: u32) {
	d := s.dyn
	n := s.nodes[id]
	shared, owners := &d.shared[id], &d.owners[id]
	clear(shared)
	clear(owners)
	d.stamp += 1
	if d.stamp == 0 {
		slice.zero(d.vstamp)
		slice.zero(d.nstamp)
		d.stamp = 1
	}
	for v in s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count] {
		owner := vert_page(v)
		if owner == id || d.vstamp[v] == d.stamp do continue
		d.vstamp[v] = d.stamp
		append(shared, v)
		if d.nstamp[owner] != d.stamp {
			d.nstamp[owner] = d.stamp
			append(owners, owner)
		}
	}
}

// Bounds of a node's owned and shared vertices: of its triangles, as long as every
// vertex it owns is in one of them or a neighbour's.
@(private)
node_bounds :: proc(s: ^Sculptor, id: u32) -> geom.Aabb {
	m := s.mesh
	n := s.nodes[id]
	b := geom.AABB_EMPTY
	if n.tri_count == 0 do return b
	for v in n.vert_first ..< n.vert_first + n.vert_count do geom.aabb_grow(&b, m.positions[v])
	for v in node_shared(s, id) do geom.aabb_grow(&b, m.positions[v])
	return b
}

// Recomputes a node's bounds, and its BVH leaf's (the caller refits or rebuilds).
@(private)
set_node_bounds :: proc(s: ^Sculptor, id: u32) {
	d := s.dyn
	n := s.nodes[id]
	b := node_bounds(s, id)
	d.bounds[id] = b
	if (n.tri_count == 0) != (n.leaf == geom.BVH_NONE) do d.tree_stale = true
	if n.leaf != geom.BVH_NONE && n.tri_count > 0 {
		s.bvh.nodes[n.leaf].bounds = b
		s.bvh.nodes[n.leaf].count = n.tri_count
	}
}

// Rebuilds the BVH over the nodes with triangles, keeping each one's bounds.
@(private)
rebuild_tree :: proc(s: ^Sculptor) {
	d := s.dyn
	count := len(s.nodes)
	boxes := make([]geom.Aabb, count, context.temp_allocator)
	first := make([]u32, count, context.temp_allocator)
	tris := make([]u32, count, context.temp_allocator)
	leaf_of := make([]u32, count, context.temp_allocator)
	for n, id in s.nodes {
		boxes[id] = s.bvh.nodes[n.leaf].bounds if n.leaf != geom.BVH_NONE else d.bounds[id]
		first[id], tris[id] = n.tri_first, n.tri_count
	}
	geom.bvh_destroy(&s.bvh)
	s.bvh = geom.bvh_build_over(boxes, first, tris, leaf_of, d.allocator)
	delete(s.node_of)
	s.node_of = make([]u32, len(s.bvh.nodes), d.allocator)
	for &x in s.node_of do x = geom.BVH_NONE
	for &n, id in s.nodes {
		n.leaf = leaf_of[id]
		if n.leaf != geom.BVH_NONE do s.node_of[n.leaf] = u32(id)
	}
	d.tree_stale = false
}

// Called by dab_once before a dab moves anything, with the hit leaves found: splits the
// edges in the brush longer than its detail size, longest first, then collapses the
// ones shorter than DYN_COLLAPSE_SHARE of it, shortest first. Returns true when the
// mesh changed, so the caller finds the hit leaves again.
@(private)
dyn_dab_topology :: proc(s: ^Sculptor, dab: ^Dab, pool: ^jobs.Pool) -> bool {
	d := s.dyn
	detail := dab.brush.radius * dab.brush.detail
	if detail <= 0 do return false
	d.max2 = detail * detail
	d.min2 = d.max2 * DYN_COLLAPSE_SHARE * DYN_COLLAPSE_SHARE
	d.collapse = dab.brush.collapse
	for len(d.cand_long) < len(s.hit) {
		append(&d.cand_long, make([dynamic]Dyn_Edge, runtime.heap_allocator()))
		append(&d.cand_short, make([dynamic]Dyn_Edge, runtime.heap_allocator()))
	}
	jobs.parallel_for(pool, len(s.hit), dab, job_edge_candidates)
	clear(&d.long)
	clear(&d.short)
	for i in 0 ..< len(s.hit) {
		for e in d.cand_long[i] do heap_push(&d.long, e)
		append(&d.short, ..d.cand_short[i][:])
	}
	if len(d.long) == 0 && len(d.short) == 0 do return false

	inside :: #force_inline proc(s: ^Sculptor, dab: ^Dab, a, b: u32) -> (l2: f32, ok: bool) {
		pa, pb := s.mesh.positions[a], s.mesh.positions[b]
		mid := (pa + pb) * 0.5 - dab.center
		if linalg.dot(mid, mid) >= dab.r2 do return
		l := pa - pb
		return linalg.dot(l, l), true
	}
	// Each edge goes back at most once (deferred), and only for a longer one: the pops
	// stay within a few times the splits.
	for splits, pops := 0, 0; len(d.long) > 0 && splits < DYN_MAX_SPLITS && pops < 4 * DYN_MAX_SPLITS; pops += 1 {
		e := heap_pop(&d.long)
		l2, ok := inside(s, dab, e.a, e.b)
		if e.forced do l2, ok = length2(s, e.a, e.b), true
		if !ok || l2 <= d.max2 do continue // moved by a node split
		// Longest-edge bisection (Rivara): when a triangle on either side has a longer
		// edge, that one splits first, even outside the brush. Cutting a triangle across
		// a shorter side would leave a sliver, and slivers of slivers.
		if !e.deferred {
			if a, b, longer, found := longer_edge(s, e.a, e.b, l2); found {
				heap_push(&d.long, Dyn_Edge{l2, e.a, e.b, e.forced, true})
				heap_push(&d.long, Dyn_Edge{longer, a, b, true, false})
				continue
			}
		}
		res, full, m, c, cd := split_edge(s, e.a, e.b)
		if res == .Full && split_node(s, full) do res, full, m, c, cd = split_edge(s, e.a, e.b)
		if res != .Done do continue
		splits += 1
		for w in ([4]u32{e.a, e.b, c, cd}) {
			half, in_brush := inside(s, dab, w, m)
			if in_brush && half > d.max2 do heap_push(&d.long, Dyn_Edge{l2 = half, a = w, b = m})
			// A vertex across the edge right by its middle: the new edge to it is too
			// short to keep, so it collapses below.
			if w != e.a && w != e.b && d.collapse && length2(s, w, m) < d.min2 do append(&d.short, Dyn_Edge{l2 = length2(s, w, m), a = w, b = m})
		}
	}
	if d.collapse && len(d.short) > 0 {
		slice.sort_by(d.short[:], proc(x, y: Dyn_Edge) -> bool {return x.l2 < y.l2})
		collapses := 0
		for e in d.short {
			if collapses >= DYN_MAX_COLLAPSES do break
			l2, ok := inside(s, dab, e.a, e.b)
			if !ok || l2 >= d.min2 do continue
			if collapse_edge(s, e.a, e.b) == .Done do collapses += 1
		}
	}
	if len(d.affected) == 0 do return false
	after_edits(s)
	return true
}

@(private = "file")
length2 :: #force_inline proc(s: ^Sculptor, a, b: u32) -> f32 {
	l := s.mesh.positions[a] - s.mesh.positions[b]
	return linalg.dot(l, l)
}

// The longest edge of the triangles on either side of edge a-b, when it is longer than
// a-b (squared length l2) by more than rounding, and either end of it can move.
@(private = "file")
longer_edge :: proc(s: ^Sculptor, a, b: u32, l2: f32) -> (x, y: u32, longer: f32, found: bool) {
	idx := s.mesh.indices[:]
	longer = l2 * 1.0001
	t1, _ := find_edge(s, a, b)
	t2, _ := find_edge(s, b, a)
	for t in ([2]u32{t1, t2}) {
		if t == DYN_NONE do continue
		for k in u32(0) ..< 3 {
			p, q := idx[3 * t + k], idx[3 * t + (k + 1) % 3]
			if l := length2(s, p, q); l > longer && (shield(s.fade, s.mask, p) > 0 || shield(s.fade, s.mask, q) > 0) {
				x, y, longer, found = p, q, l, true
			}
		}
	}
	return
}

// Brings everything that depends on the triangles up to date for the nodes the edits
// changed: shared vertices, bounds, the BVH, and what the next flush and undo need.
@(private)
after_edits :: proc(s: ^Sculptor) {
	d := s.dyn
	for id in d.affected {
		if Affect.Topo in transmute(bit_set[Affect;u8])d.affect[id] {
			refresh_shared(s, id)
			if !d.topo[id] {
				d.topo[id] = true
				append(&d.topo_nodes, id)
			}
		}
	}
	clear(&s.changed)
	for id in d.affected {
		set_node_bounds(s, id)
		n := s.nodes[id]
		if n.leaf != geom.BVH_NONE && n.tri_count > 0 do append(&s.changed, n.leaf)
	}
	if d.tree_stale {
		rebuild_tree(s)
	} else {
		geom.bvh_refit_leaves(&s.bvh, s.mesh^, s.changed[:], recompute_leaves = false)
	}
	for id in d.affected {
		mark_shape_changed(s, id)
		if s.history.recording do record_changed_node(s, id)
		d.affect[id] = 0
	}
	clear(&d.affected)
}

// Collects the hit leaf's edges with their middle in the brush that are too long, or
// too short, each once (from the triangle where it runs from the lower vertex number).
@(private = "file")
job_edge_candidates :: proc(data: rawptr, i: int) {
	dab := cast(^Dab)data
	s := dab.s
	d := s.dyn
	m := s.mesh
	n := s.nodes[s.node_of[s.hit[i]]]
	long, short := &d.cand_long[i], &d.cand_short[i]
	clear(long)
	clear(short)
	idx := m.indices[3 * n.tri_first:][:3 * n.tri_count]
	for t := 0; t < len(idx); t += 3 {
		for k in 0 ..< 3 {
			a, b := idx[t + k], idx[t + (k + 1) % 3]
			if a > b do continue
			pa, pb := m.positions[a], m.positions[b]
			mid := (pa + pb) * 0.5 - dab.center
			if linalg.dot(mid, mid) >= dab.r2 do continue
			l := pa - pb
			l2 := linalg.dot(l, l)
			if l2 > d.max2 {
				if shield(s.fade, s.mask, a) > 0 || shield(s.fade, s.mask, b) > 0 do append(long, Dyn_Edge{l2 = l2, a = a, b = b})
			} else if l2 < d.min2 && d.collapse {
				append(short, Dyn_Edge{l2 = l2, a = a, b = b})
			}
		}
	}
}

@(private = "file")
heap_push :: proc(h: ^[dynamic]Dyn_Edge, e: Dyn_Edge) {
	append(h, e)
	i := len(h) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if h[parent].l2 >= h[i].l2 do break
		h[parent], h[i] = h[i], h[parent]
		i = parent
	}
}

@(private = "file")
heap_pop :: proc(h: ^[dynamic]Dyn_Edge) -> Dyn_Edge {
	top := h[0]
	last := pop(h)
	if len(h) == 0 do return top
	h[0] = last
	i := 0
	for {
		l, r := 2 * i + 1, 2 * i + 2
		big := i
		if l < len(h) && h[l].l2 > h[big].l2 do big = l
		if r < len(h) && h[r].l2 > h[big].l2 do big = r
		if big == i do break
		h[i], h[big] = h[big], h[i]
		i = big
	}
	return top
}

// Undo and redo of a step that saved whole nodes: swaps their saved contents in, then
// rebuilds the triangle lists, shared vertices, bounds and BVH around them.
@(private)
dyn_step_swap :: proc(s: ^Sculptor, step: ^Undo_Step) {
	d := s.dyn
	m := s.mesh
	idx := m.indices[:]
	full := false
	for sv in step.saved do full ||= sv.full
	if !full do return
	around := make([dynamic]u32, 0, 4 * len(step.saved), context.temp_allocator)
	note :: proc(s: ^Sculptor, around: ^[dynamic]u32, id: u32) {
		d := s.dyn
		if d.affect[id] != 0 do return
		d.affect[id] = 1
		append(around, id)
	}
	for sv in step.saved {
		if !sv.full do continue
		note(s, &around, sv.node)
		for owner in d.owners[sv.node] do note(s, &around, owner)
		n := s.nodes[sv.node]
		for t in n.tri_first ..< n.tri_first + n.tri_count {
			for k in u32(0) ..< 3 do face_remove(d, idx[3 * t + k], t)
		}
	}
	for &sv in step.saved {
		if !sv.full do continue
		n := &s.nodes[sv.node]
		positions := slice.clone(m.positions[n.vert_first:][:n.vert_count], s.history.allocator)
		indices := slice.clone(idx[3 * n.tri_first:][:3 * n.tri_count], s.history.allocator)
		masks: []u8
		if s.mask != nil do masks = slice.clone(s.mask[n.vert_first:][:n.vert_count], s.history.allocator)
		for k in 3 * n.tri_first ..< 3 * (n.tri_first + n.tri_count) do idx[k] = 0
		n.vert_count, n.tri_count = sv.vert_count, sv.tri_count
		copy(m.positions[n.vert_first:][:n.vert_count], sv.positions)
		copy(idx[3 * n.tri_first:][:3 * n.tri_count], sv.indices)
		if s.mask != nil {
			if sv.masks != nil {
				copy(s.mask[n.vert_first:][:n.vert_count], sv.masks)
			} else {
				slice.zero(s.mask[n.vert_first:][:n.vert_count])
			}
		}
		delete(sv.positions, s.history.allocator)
		delete(sv.indices, s.history.allocator)
		delete(sv.masks, s.history.allocator)
		sv.positions, sv.indices, sv.masks = positions, indices, masks
		sv.vert_count, sv.tri_count = u32(len(positions)), u32(len(indices) / 3)
		if n.vert_count == 0 && n.tri_count == 0 do append(&d.free, sv.node)
	}
	for sv in step.saved {
		if !sv.full do continue
		n := s.nodes[sv.node]
		for t in n.tri_first ..< n.tri_first + n.tri_count {
			for k in u32(0) ..< 3 do face_add(d, idx[3 * t + k], t)
		}
	}
	for sv in step.saved {
		if !sv.full do continue
		refresh_shared(s, sv.node)
		for owner in d.owners[sv.node] do note(s, &around, owner)
		if !d.topo[sv.node] {
			d.topo[sv.node] = true
			append(&d.topo_nodes, sv.node)
		}
	}
	for id in step.nodes do note(s, &around, id)
	for id in around {
		set_node_bounds(s, id)
		d.affect[id] = 0
	}
	rebuild_tree(s)
	for id in around do mark_shape_changed(s, id)
}

// Before the stroke first changes a node of a dynamic sculptor: saves all of it.
@(private)
record_full :: proc(s: ^Sculptor, id: u32) {
	h := &s.history
	if h.saved[id] == h.stamp do return
	h.saved[id] = h.stamp
	n := s.nodes[id]
	sv := Saved_Node {
		node       = id,
		full       = true,
		vert_count = n.vert_count,
		tri_count  = n.tri_count,
		positions  = slice.clone(s.mesh.positions[n.vert_first:][:n.vert_count], h.allocator),
		indices    = slice.clone(s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count], h.allocator),
	}
	if s.mask != nil do sv.masks = slice.clone(s.mask[n.vert_first:][:n.vert_count], h.allocator)
	append(&h.current.saved, sv)
}
