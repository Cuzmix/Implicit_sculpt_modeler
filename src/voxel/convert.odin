package voxel

import "core:slice"

import "../geom"

// A plain mesh of the clay's surface: every node's triangles with the border vertices the
// nodes duplicate welded into one, by exact position (they agree bit for bit, mesh.odin),
// and the unused index slots left out. For export and for turning the object into a mesh.
clay_to_mesh :: proc(c: ^Clay, allocator := context.allocator) -> (m: geom.Mesh) {
	s := &c.surface
	// Flush first, so the mesh is the clay as it is now.
	_ = clay_flush(c)
	total := 0
	for n in s.nodes do total += int(n.vert_count)
	// Sorting the vertices by position puts the copies side by side; a vertex's new index
	// is its run's. The sort key is the three floats' bits, which equal positions share.
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
			// A welded triangle with two corners the same has no area.
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
