package geom

import "core:slice"

// Splitting a mesh into parts, as ZBrush's Split Hidden, Groups Split and Split To Parts
// do: each triangle names its part, and each part becomes a mesh of its own with the
// vertices its triangles use, numbered in the order they are first used, and zero
// normals for the sculptor to compute. A vertex on the border between parts goes to
// every part that uses it, so each keeps its side of the border. Both passes are
// serial, one look at each triangle and vertex, so the result depends on nothing but
// the mesh and the parts.

// One part of a split: its mesh, and where each of its vertices and triangles came from.
Split_Part :: struct {
	mesh:        Mesh,
	vertex_from: [dynamic]u32, // per vertex of `mesh`, its vertex in the source
	tri_from:    []u32,        // per triangle of `mesh`, its triangle in the source
}

// The parts of `m`, part[t] (below `count`) giving each triangle's, in part order; a part
// no triangle names is an empty mesh. Free them with split_parts_destroy.
mesh_split :: proc(m: Mesh, part: []u32, count: int, allocator := context.allocator) -> []Split_Part {
	tcount := len(m.indices) / 3
	assert(len(part) == tcount)
	// The triangles in part order (a counting sort, so in source order within a part).
	start := make([]int, count + 1, context.temp_allocator)
	for p in part do start[p + 1] += 1
	for k in 0 ..< count do start[k + 1] += start[k]
	order := make([]u32, tcount, context.temp_allocator)
	fill := slice.clone(start, context.temp_allocator)
	for p, t in part {
		order[fill[p]] = u32(t)
		fill[p] += 1
	}
	// Each source vertex's number in the part being built, put back to SPLIT_NONE after
	// each part through the part's own list, so the whole split looks at each vertex once
	// a part that uses it.
	slot := make([]u32, len(m.positions), context.temp_allocator)
	slice.fill(slot, SPLIT_NONE)
	parts := make([]Split_Part, count, allocator)
	for &out, k in parts {
		tris := order[start[k]:start[k + 1]]
		out.tri_from = make([]u32, len(tris), allocator)
		out.vertex_from = make([dynamic]u32, 0, len(tris) / 2 + 3, allocator)
		out.mesh.indices = make([dynamic]u32, 3 * len(tris), allocator)
		for t, i in tris {
			out.tri_from[i] = t
			for c in 0 ..< 3 {
				v := m.indices[3 * int(t) + c]
				if slot[v] == SPLIT_NONE {
					slot[v] = u32(len(out.vertex_from))
					append(&out.vertex_from, v)
				}
				out.mesh.indices[3 * i + c] = slot[v]
			}
		}
		out.mesh.positions = make([dynamic]Vec3, len(out.vertex_from), allocator)
		out.mesh.normals = make([dynamic]Vec3, len(out.vertex_from), allocator)
		for v, i in out.vertex_from {
			out.mesh.positions[i] = m.positions[v]
			slot[v] = SPLIT_NONE
		}
	}
	return parts
}

// What a source vertex maps to while it is in no part.
SPLIT_NONE :: max(u32)

split_parts_destroy :: proc(parts: []Split_Part, allocator := context.allocator) {
	for &p in parts {
		mesh_destroy(&p.mesh)
		delete(p.vertex_from)
		delete(p.tri_from, allocator)
	}
	delete(parts, allocator)
}

// Each triangle's connected part, as `part` for mesh_split, and how many parts there
// are: triangles that share a vertex are in one part. Parts are numbered in the order of
// their first triangle, so the numbering is the mesh's own.
mesh_components :: proc(m: Mesh, allocator := context.allocator) -> (part: []u32, count: int) {
	tcount := len(m.indices) / 3
	// A union-find over the vertices; each union keeps the smaller root, so the roots,
	// like the numbering, follow from the mesh alone.
	root := make([]u32, len(m.positions), context.temp_allocator)
	for &r, v in root do r = u32(v)
	find :: proc(root: []u32, v: u32) -> u32 {
		v := v
		for root[v] != v {
			root[v] = root[root[v]]
			v = root[v]
		}
		return v
	}
	for t in 0 ..< tcount {
		a := find(root, m.indices[3 * t])
		for c in 1 ..< 3 {
			b := find(root, m.indices[3 * t + c])
			if a < b {
				root[b] = a
			} else if b < a {
				root[a] = b
				a = b
			}
		}
	}
	label := make([]u32, len(m.positions), context.temp_allocator)
	slice.fill(label, SPLIT_NONE)
	part = make([]u32, tcount, allocator)
	for t in 0 ..< tcount {
		r := find(root, m.indices[3 * t])
		if label[r] == SPLIT_NONE {
			label[r] = u32(count)
			count += 1
		}
		part[t] = label[r]
	}
	return
}
