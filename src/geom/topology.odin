package geom

import "core:slice"
import "core:sync"

import "../jobs"

// Vertex -> incident triangle lookup in compressed (CSR) form: the triangles around
// vertex v are tris[offsets[v]:offsets[v+1]]. Valid until the mesh topology changes.
Vertex_Faces :: struct {
	offsets: []u32,
	tris:    []u32,
}

// Builds the lookup in parallel when given a pool. Each vertex's triangles are listed
// in ascending order either way, so results do not depend on thread timing.
vertex_faces_build :: proc(m: Mesh, pool: ^jobs.Pool = nil, allocator := context.allocator) -> Vertex_Faces {
	vcount := len(m.positions)
	Build :: struct {
		m:      Mesh,
		vf:     Vertex_Faces,
		cursor: []u32,
	}
	bd := Build {
		m = m,
		vf = {offsets = make([]u32, vcount + 1, allocator), tris = make([]u32, len(m.indices), allocator)},
	}
	jobs.parallel_ranges(pool, len(m.indices), &bd, proc(data: rawptr, lo, hi: int) {
		bd := cast(^Build)data
		for i in bd.m.indices[lo:hi] do sync.atomic_add_explicit(&bd.vf.offsets[i + 1], 1, .Relaxed)
	}, RANGE_GRAIN)
	for v in 0 ..< vcount {
		bd.vf.offsets[v + 1] += bd.vf.offsets[v]
	}
	bd.cursor = make([]u32, vcount, context.temp_allocator)
	copy(bd.cursor, bd.vf.offsets[:vcount])
	jobs.parallel_ranges(pool, len(m.indices), &bd, proc(data: rawptr, lo, hi: int) {
		bd := cast(^Build)data
		for corner in lo ..< hi {
			slot := sync.atomic_add_explicit(&bd.cursor[bd.m.indices[corner]], 1, .Relaxed)
			bd.vf.tris[slot] = u32(corner / 3)
		}
	}, RANGE_GRAIN)
	if pool != nil {
		// Threads filled each list in arbitrary order; restore ascending order.
		jobs.parallel_ranges(pool, vcount, &bd, proc(data: rawptr, lo, hi: int) {
			bd := cast(^Build)data
			for v in lo ..< hi {
				list := bd.vf.tris[bd.vf.offsets[v]:bd.vf.offsets[v + 1]]
				for i in 1 ..< len(list) {
					x, j := list[i], i
					for j > 0 && list[j - 1] > x {
						list[j] = list[j - 1]
						j -= 1
					}
					list[j] = x
				}
			}
		}, RANGE_GRAIN)
	}
	return bd.vf
}

vertex_faces_destroy :: proc(vf: ^Vertex_Faces, allocator := context.allocator) {
	delete(vf.offsets, allocator)
	delete(vf.tris, allocator)
	vf^ = {}
}

vertex_faces_of :: #force_inline proc(vf: Vertex_Faces, v: u32) -> []u32 {
	return vf.tris[vf.offsets[v]:vf.offsets[v + 1]]
}

// Reorders vertices along a Morton (Z-order) curve so that vertices close in space are
// close in memory. A brush dab then touches a narrow index range, which keeps GPU
// uploads small and cache use good. Indices are remapped; triangles are unchanged.
mesh_sort_vertices_spatially :: proc(m: ^Mesh) {
	vcount := len(m.positions)
	if vcount == 0 do return
	lo, hi := m.positions[0], m.positions[0]
	for p in m.positions {
		lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
		hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
	}
	extent := hi - lo
	scale := 1023 / max(extent.x, extent.y, extent.z, 1e-12)

	Keyed :: struct {
		key: u32,
		old: u32,
	}
	keyed := make([]Keyed, vcount, context.temp_allocator)
	for p, i in m.positions {
		q := (p - lo) * scale
		keyed[i] = {morton3(u32(q.x), u32(q.y), u32(q.z)), u32(i)}
	}
	slice.sort_by_key(keyed, proc(k: Keyed) -> u32 {return k.key})

	old_to_new := make([]u32, vcount, context.temp_allocator)
	positions := make([]Vec3, vcount, context.temp_allocator)
	normals := make([]Vec3, vcount, context.temp_allocator)
	for k, new_index in keyed {
		old_to_new[k.old] = u32(new_index)
		positions[new_index] = m.positions[k.old]
		normals[new_index] = m.normals[k.old]
	}
	copy(m.positions[:], positions)
	copy(m.normals[:], normals)
	for &i in m.indices {
		i = old_to_new[i]
	}
}

@(private)
morton3 :: proc(x, y, z: u32) -> u32 {
	spread :: proc(bits: u32) -> u32 {
		v := bits & 0x3ff
		v = (v | v << 16) & 0x030000ff
		v = (v | v << 8) & 0x0300f00f
		v = (v | v << 4) & 0x030c30c3
		v = (v | v << 2) & 0x09249249
		return v
	}
	return spread(x) | spread(y) << 1 | spread(z) << 2
}
