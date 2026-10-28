package poly

import "../geom"

// The cage in a scene file and in undo snapshots: its polygons, corner sharpness,
// creases and (from version 2) its selected faces, which mesh_from_polygons turns back into the same half-edges (edges are
// numbered by the order faces meet them, so writing and reading give the same ids).
// Damaged or impossible bytes are refused, never asserted on.

@(private = "file")
CAGE_MAGIC :: u32(0x4547_4143) // "CAGE"
@(private = "file")
CAGE_FILE_VERSION :: u32(2) // 2: the selected faces

mesh_write :: proc(m: ^Mesh, out: ^[dynamic]u8) {
	p := mesh_polygons(m, context.temp_allocator)
	geom.byte_put(out, CAGE_MAGIC)
	geom.byte_put(out, CAGE_FILE_VERSION)
	geom.byte_put(out, u32(len(p.positions)))
	geom.byte_put(out, u32(len(p.sizes)))
	geom.byte_put(out, u32(len(p.corners)))
	geom.byte_put_slice(out, p.positions[:])
	geom.byte_put_slice(out, m.corner[:])
	for s in p.sizes do geom.byte_put(out, u32(s))
	geom.byte_put_slice(out, p.corners[:])
	geom.byte_put_slice(out, p.groups[:])
	creased: u32
	for c in m.crease do if c != 0 do creased += 1
	geom.byte_put(out, creased)
	for c, e in m.crease {
		if c == 0 do continue
		a, b := edge_verts(m, u32(e))
		geom.byte_put(out, a)
		geom.byte_put(out, b)
		geom.byte_put(out, c)
	}
	chosen: u32
	for x in m.selected do if x do chosen += 1
	geom.byte_put(out, chosen)
	for x, f in m.selected do if x do geom.byte_put(out, u32(f))
}

// Reads a cage mesh_write wrote. ok is false, with nothing allocated, for damaged bytes
// or polygons that do not make a cage.
mesh_read :: proc(r: ^geom.Byte_Reader, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	if geom.byte_get(r, u32) != CAGE_MAGIC do return {}, false
	version := geom.byte_get(r, u32)
	if version < 1 || version > CAGE_FILE_VERSION do return {}, false
	nv := int(geom.byte_get(r, u32))
	nf := int(geom.byte_get(r, u32))
	nc := int(geom.byte_get(r, u32))
	// Each count must fit in what is left before anything is made that large.
	left := len(r.data) - r.at
	if !r.ok || nv * 16 + nf * 6 + nc * 4 > left || nc < 3 * nf || nf == 0 do return {}, false
	positions := make([]Vec3, nv, context.temp_allocator)
	corner := make([]f32, nv, context.temp_allocator)
	sizes := make([]int, nf, context.temp_allocator)
	corners := make([]u32, nc, context.temp_allocator)
	groups := make([]u16, nf, context.temp_allocator)
	geom.byte_get_slice(r, positions)
	geom.byte_get_slice(r, corner)
	total := 0
	for &s in sizes {
		s = int(geom.byte_get(r, u32))
		total += s
	}
	geom.byte_get_slice(r, corners)
	geom.byte_get_slice(r, groups)
	creased := int(geom.byte_get(r, u32))
	if !r.ok || total != nc || creased * 12 > len(r.data) - r.at do return {}, false
	built, err := mesh_from_polygons(positions, sizes, corners, groups, allocator)
	if err != .None do return {}, false
	for c in corner {
		if !(c >= 0 && c <= INFINITE_SHARP) {
			mesh_destroy(&built)
			return {}, false
		}
	}
	copy(built.corner[:], corner)
	for _ in 0 ..< creased {
		a := geom.byte_get(r, u32)
		b := geom.byte_get(r, u32)
		c := geom.byte_get(r, f32)
		h := NONE
		if int(a) < nv && int(b) < nv do h = find_half_edge(&built, a, b)
		if !r.ok || h == NONE || !(c >= 0 && c <= INFINITE_SHARP) {
			mesh_destroy(&built)
			return {}, false
		}
		built.crease[edge_of(h)] = c
	}
	if version >= 2 {
		chosen := int(geom.byte_get(r, u32))
		if !r.ok || chosen > nf || chosen * 4 > len(r.data) - r.at {
			mesh_destroy(&built)
			return {}, false
		}
		for _ in 0 ..< chosen {
			f := geom.byte_get(r, u32)
			if !r.ok || int(f) >= nf {
				mesh_destroy(&built)
				return {}, false
			}
			built.selected[f] = true
		}
	}
	return built, true
}
