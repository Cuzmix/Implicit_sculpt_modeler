package voxel

import "base:runtime"
import "core:slice"

import "../geom"
import "../jobs"

// A plain mesh of the clay's surface: every node's triangles, with the vertices the nodes
// hold twice or more (their borders) welded into one and the unused index slots left out.
// For export and for turning the object into a mesh. The weld goes by the vertices' codes
// (mesh.odin): a border vertex names the cell and loop it stands for in the node that owns
// the cell, so each node finds the owners of its copies on its own, every pass runs a node
// a job and one thread and many give the same mesh. A copy whose owner node does not exist
// (its cell lies on the domain's edge) keeps its own vertex.
clay_to_mesh :: proc(c: ^Clay, allocator := context.allocator) -> (m: geom.Mesh) {
	s := &c.surface
	// Flush first, so the mesh is the clay as it is now.
	_ = clay_flush(c)
	heap := runtime.heap_allocator()
	Weld :: struct {
		c:      ^Clay,
		sorted: []u64, // per node, in its vertex slot: the codes of the vertices it owns over their indices, sorted
		owned:  []u32, // per node: how many vertices it owns
		target: []u32, // per vertex: the vertex it is welded into (itself for an owner or an orphan)
		remap:  []u32, // per vertex: its index in the mesh
		kept:   []u32, // per node: the vertices it keeps (owned and orphans), then where they start
		tris:   []u32, // per node: the triangles it keeps, then where they start
		m:      ^geom.Mesh,
	}
	n := len(s.nodes)
	total := len(s.mesh.positions)
	w := Weld {
		c      = c,
		sorted = make([]u64, total, heap),
		owned  = make([]u32, n, heap),
		target = make([]u32, total, heap),
		remap  = make([]u32, total, heap),
		kept   = make([]u32, n + 1, heap),
		tris   = make([]u32, n + 1, heap),
		m      = &m,
	}
	defer {
		delete(w.sorted, heap)
		delete(w.owned, heap)
		delete(w.target, heap)
		delete(w.remap, heap)
		delete(w.kept, heap)
		delete(w.tris, heap)
	}
	// Each node sorts the codes of the vertices it owns, so its neighbours can look theirs up.
	jobs.parallel_for(c.pool, n, &w, proc(data: rawptr, i: int) {
		w := cast(^Weld)data
		s := &w.c.surface
		node := s.nodes[i]
		count := 0
		for k in node.vert_first ..< node.vert_first + node.vert_count {
			code := s.codes[k]
			if code >> CODE_OFFSET_SHIFT != 0 do continue
			w.sorted[int(node.vert_first) + count] = u64(code) << 32 | u64(k)
			count += 1
		}
		slice.sort(w.sorted[node.vert_first:][:count])
		w.owned[i] = u32(count)
	})
	// Each copy finds its owner's vertex; a copy without one is an orphan and kept.
	jobs.parallel_for(c.pool, n, &w, proc(data: rawptr, i: int) {
		w := cast(^Weld)data
		s := &w.c.surface
		node := s.nodes[i]
		kept := u32(0)
		for k in node.vert_first ..< node.vert_first + node.vert_count {
			code := s.codes[k]
			w.target[k] = k
			offset := code >> CODE_OFFSET_SHIFT
			if offset == 0 {
				kept += 1
				continue
			}
			owner_coord := node.coord - {i32(offset & 1), i32(offset >> 1 & 1), i32(offset >> 2 & 1)}
			found := false
			if j, ok := surface_node_find(w.c, owner_coord); ok {
				owner := s.nodes[j]
				keys := w.sorted[owner.vert_first:][:w.owned[j]]
				want := u64(code & CODE_KEY_MASK)
				// The first key at or above the code, if it is the code.
				lo, hi := 0, len(keys)
				for lo < hi {
					mid := (lo + hi) / 2
					if keys[mid] >> 32 < want {
						lo = mid + 1
					} else {
						hi = mid
					}
				}
				if lo < len(keys) && keys[lo] >> 32 == want {
					w.target[k] = u32(keys[lo])
					found = true
				}
			}
			if !found do kept += 1
		}
		w.kept[i] = kept
	})
	vertices := u32(0)
	for i in 0 ..< n {
		k := w.kept[i]
		w.kept[i] = vertices
		vertices += k
	}
	w.kept[n] = vertices
	m.positions = make([dynamic]Vec3, int(vertices), allocator)
	m.normals = make([dynamic]Vec3, int(vertices), allocator)
	// The kept vertices go into the mesh in node order, then slot order.
	jobs.parallel_for(c.pool, n, &w, proc(data: rawptr, i: int) {
		w := cast(^Weld)data
		s := &w.c.surface
		node := s.nodes[i]
		at := w.kept[i]
		for k in node.vert_first ..< node.vert_first + node.vert_count {
			if w.target[k] != k do continue
			w.remap[k] = at
			w.m.positions[at] = s.mesh.positions[k]
			w.m.normals[at] = s.mesh.normals[k]
			at += 1
		}
	})
	// The copies follow their owners, which every node has placed by now; then each node
	// counts the triangles it keeps (a welded triangle with two corners the same has no area).
	jobs.parallel_for(c.pool, n, &w, proc(data: rawptr, i: int) {
		w := cast(^Weld)data
		s := &w.c.surface
		node := s.nodes[i]
		for k in node.vert_first ..< node.vert_first + node.vert_count {
			if w.target[k] != k do w.remap[k] = w.remap[w.target[k]]
		}
		w.tris[i] = u32(weld_triangles(w.remap, s.mesh.indices[node.idx_first:][:node.idx_count], nil))
	})
	triangles := u32(0)
	for i in 0 ..< n {
		k := w.tris[i]
		w.tris[i] = triangles
		triangles += k
	}
	w.tris[n] = triangles
	m.indices = make([dynamic]u32, int(triangles) * 3, allocator)
	jobs.parallel_for(c.pool, n, &w, proc(data: rawptr, i: int) {
		w := cast(^Weld)data
		s := &w.c.surface
		node := s.nodes[i]
		out := w.m.indices[w.tris[i] * 3:][:(w.tris[i + 1] - w.tris[i]) * 3]
		_ = weld_triangles(w.remap, s.mesh.indices[node.idx_first:][:node.idx_count], out)
	})
	return
}

// Counts the triangles of `tris` that keep three different corners under `remap`, and
// writes them to `out` when it is given.
@(private = "file")
weld_triangles :: proc(remap: []u32, tris: []u32, out: []u32) -> (count: int) {
	for t := 0; t + 2 < len(tris); t += 3 {
		a, b, cc := remap[tris[t]], remap[tris[t + 1]], remap[tris[t + 2]]
		if a == b || b == cc || a == cc do continue
		if out != nil {
			out[count * 3] = a
			out[count * 3 + 1] = b
			out[count * 3 + 2] = cc
		}
		count += 1
	}
	return
}

// The same mesh welded by exact position on one thread: the border copies agree bit for
// bit with their owners (mesh.odin), so sorting the vertices by position puts them side by
// side. The oracle the code weld is tested against.
@(private)
clay_to_mesh_by_position :: proc(c: ^Clay, allocator := context.allocator) -> (m: geom.Mesh) {
	s := &c.surface
	_ = clay_flush(c)
	total := 0
	for n in s.nodes do total += int(n.vert_count)
	Key :: struct {
		pos:  Vec3,
		from: u32,
	}
	keys := make([]Key, total, context.temp_allocator)
	at := 0
	for n in s.nodes do for k in 0 ..< n.vert_count {
		from := n.vert_first + k
		keys[at] = {s.mesh.positions[from], from}
		at += 1
	}
	slice.sort_by(keys, proc(a, b: Key) -> bool {
		if a.pos.x != b.pos.x do return a.pos.x < b.pos.x
		if a.pos.y != b.pos.y do return a.pos.y < b.pos.y
		if a.pos.z != b.pos.z do return a.pos.z < b.pos.z
		return a.from < b.from
	})
	remap := make([]u32, len(s.mesh.positions), context.temp_allocator)
	m.positions = make([dynamic]Vec3, 0, total, allocator)
	m.normals = make([dynamic]Vec3, 0, total, allocator)
	m.indices = make([dynamic]u32, allocator)
	for key, i in keys {
		if i == 0 || key.pos != keys[i - 1].pos {
			append(&m.positions, key.pos)
			append(&m.normals, s.mesh.normals[key.from])
		}
		remap[key.from] = u32(len(m.positions) - 1)
	}
	for n in s.nodes {
		tris := s.mesh.indices[n.idx_first:][:n.idx_count]
		for t := 0; t + 2 < len(tris); t += 3 {
			a, b, cc := remap[tris[t]], remap[tris[t + 1]], remap[tris[t + 2]]
			if a == b || b == cc || a == cc do continue
			append(&m.indices, a, b, cc)
		}
	}
	return
}

// The vertices the nodes hold twice or more: a border count, for the seam test.
@(private)
clay_duplicate_vertices :: proc(c: ^Clay) -> int {
	m := clay_to_mesh(c)
	defer geom.mesh_destroy(&m)
	vertices, _ := surface_counts(&c.surface)
	return vertices - len(m.positions)
}
