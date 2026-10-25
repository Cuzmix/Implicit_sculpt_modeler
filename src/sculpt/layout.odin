package sculpt

import "base:runtime"
import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"

// A sculptor's node layout, as the native file keeps it so that opening a mesh does not
// partition and renumber it again: per node, in node order, how many triangles it has
// and how many vertices it owns. Both are contiguous runs in node order, so the sizes
// alone give every range; the shared vertices and the tree above the nodes are cheap
// to work out again from the mesh.
Node_Sizes :: struct {
	tris:  u32,
	verts: u32,
}

// The node sizes of `s`, which must not have dynamic topology on.
sculptor_layout :: proc(s: ^Sculptor, allocator := context.allocator) -> []Node_Sizes {
	assert(s.dyn == nil, "a dynamic mesh has no fixed layout")
	out := make([]Node_Sizes, len(s.nodes), allocator)
	for n, id in s.nodes do out[id] = {n.tri_count, n.vert_count}
	return out
}

// Prepares `mesh` as sculptor_init does, but keeps its order and takes the node layout
// from `layout` (from sculptor_layout on a sculptor over the same mesh), which skips the
// costly partition and renumbering. Returns false, leaving `s` empty, when the layout
// does not fit the mesh: wrong totals, a node over `node_triangles`, or a vertex shared
// with a node that is not the lowest using it. A file can be damaged, so every part of
// the layout is checked before anything indexes with it.
sculptor_init_laid_out :: proc(s: ^Sculptor, mesh: ^geom.Mesh, pool: ^jobs.Pool, layout: []Node_Sizes, node_triangles: u32 = NODE_TRIANGLES, allocator := context.allocator) -> bool {
	tcount, vcount := len(mesh.indices) / 3, len(mesh.positions)
	if len(layout) == 0 || len(layout) > tcount do return false
	tris, verts: int
	for n in layout {
		if n.tris == 0 || n.tris > node_triangles do return false
		tris += int(n.tris)
		verts += int(n.verts)
	}
	if tris != tcount || verts != vcount do return false

	Laid :: struct {
		s:              ^Sculptor,
		shared, owners: [][]u32, // per node, as in reorder_by_nodes
		boxes:          []geom.Aabb,
		bad:            bool,
		heap:           runtime.Allocator, // the lists are made and freed on different threads
	}
	s^ = {mesh = mesh, pool = pool}
	s.nodes = make([]Node, len(layout), allocator)
	tri_next, vert_next: u32
	for n, id in layout {
		s.nodes[id] = {tri_first = tri_next, tri_count = n.tris, vert_first = vert_next, vert_count = n.verts}
		tri_next += n.tris
		vert_next += n.verts
	}
	l := Laid {
		s      = s,
		shared = make([][]u32, len(layout), context.temp_allocator),
		owners = make([][]u32, len(layout), context.temp_allocator),
		boxes  = make([]geom.Aabb, len(layout), context.temp_allocator),
		heap   = runtime.heap_allocator(),
	}
	// Each node's corners outside its own range are its shared vertices, owned by the
	// node whose range holds them, which has to be a lower one.
	jobs.parallel_for(pool, len(layout), &l, proc(data: rawptr, id: int) {
		l := cast(^Laid)data
		s := l.s
		n := s.nodes[id]
		corners := s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count]
		outside := make([dynamic]u32, 0, 256, l.heap)
		defer delete(outside)
		box := geom.AABB_EMPTY
		for v in corners {
			geom.aabb_grow(&box, s.mesh.positions[v])
			if v - n.vert_first >= n.vert_count do append(&outside, v)
		}
		l.boxes[id] = box
		shared := distinct_in_order(outside[:], l.heap)
		owners := make([dynamic]u32, 0, 8, l.heap)
		for v in shared {
			owner := owner_of_vertex(s.nodes, v)
			if owner >= u32(id) {
				sync.atomic_store(&l.bad, true)
				break
			}
			if !slice.contains(owners[:], owner) do append(&owners, owner)
		}
		l.shared[id], l.owners[id] = shared, owners[:]
	})
	shared_total, owners_total := 0, 0
	for id in 0 ..< len(layout) {
		shared_total += len(l.shared[id])
		owners_total += len(l.owners[id])
	}
	if !l.bad {
		s.shared = make([dynamic]u32, 0, shared_total, allocator)
		s.owners = make([dynamic]u32, 0, owners_total, allocator)
	}
	for &n, id in s.nodes {
		if !l.bad {
			n.shared_first, n.shared_count = u32(len(s.shared)), u32(len(l.shared[id]))
			n.owner_first, n.owner_count = u32(len(s.owners)), u32(len(l.owners[id]))
			append(&s.shared, ..l.shared[id])
			append(&s.owners, ..l.owners[id])
		}
		delete(l.shared[id], l.heap)
		delete(l.owners[id], l.heap)
	}
	if l.bad {
		delete(s.nodes)
		s^ = {}
		return false
	}

	// The tree above the nodes, over their boxes; leaves are runs of triangles, which
	// with tri_order the identity is what a renumbered sculptor has too.
	first := make([]u32, len(layout), context.temp_allocator)
	count := make([]u32, len(layout), context.temp_allocator)
	leaf_of := make([]u32, len(layout), context.temp_allocator)
	for n, id in s.nodes do first[id], count[id] = n.tri_first, n.tri_count
	s.bvh = geom.bvh_build_over(l.boxes, first, count, leaf_of, allocator)
	s.bvh.leaf_size = node_triangles
	s.bvh.tri_order = make([]u32, tcount, allocator)
	s.bvh.tri_leaf = make([]u32, tcount, allocator)
	s.node_of = make([]u32, len(s.bvh.nodes), allocator)
	for &x in s.node_of do x = geom.BVH_NONE
	for leaf, id in leaf_of {
		s.node_of[leaf] = u32(id)
		s.nodes[id].leaf = leaf
	}
	jobs.parallel_for(pool, len(layout), s, proc(data: rawptr, id: int) {
		s := cast(^Sculptor)data
		n := s.nodes[id]
		for k in n.tri_first ..< n.tri_first + n.tri_count {
			s.bvh.tri_order[k] = k
			s.bvh.tri_leaf[k] = n.leaf
		}
	})
	sculptor_init_rest(s, allocator)
	return true
}

// The node owning vertex v: the last whose range starts at or before v, since nodes
// owning no vertices start where the next one does.
@(private = "file")
owner_of_vertex :: proc(nodes: []Node, v: u32) -> u32 {
	lo, hi := 0, len(nodes)
	for lo < hi {
		mid := (lo + hi) / 2
		if nodes[mid].vert_first <= v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return u32(lo - 1)
}
