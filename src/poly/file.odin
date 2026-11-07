package poly

import "../geom"

// The cage in a scene file and in undo snapshots, as a tagged record (geom/record.odin):
// its polygons, corner sharpness, creases, selected faces and picked points, which
// mesh_from_polygons turns back into the same half-edges (edges are numbered by the order
// faces meet them, so writing and reading give the same ids). Damaged or impossible bytes
// are refused, never asserted on.

// Tags are never reused or retyped.
@(private = "file")
Cage_Tag :: enum u16 {
	Positions   = 1, // Vec3 per point, required
	Corner      = 2, // f32 per point: its corner sharpness
	Sizes       = 3, // u32 per face: its corner count, required
	Corners     = 4, // u32 per face corner: its point, required
	Groups      = 5, // u16 per face
	Crease_Ends = 6, // [2]u32 per creased edge: its points
	Crease      = 7, // f32 per creased edge
	Selected    = 8, // u32 per selected face, ascending
	Picked      = 9, // u32 per picked point, ascending
}

mesh_write :: proc(m: ^Mesh, out: ^[dynamic]u8) {
	p := mesh_polygons(m, context.temp_allocator)
	rec := geom.record_begin(out)
	defer geom.record_end(out, rec)
	geom.rec_put_slice(out, Cage_Tag.Positions, p.positions[:])
	geom.rec_put_slice(out, Cage_Tag.Corner, m.corner[:])
	sizes := make([]u32, len(p.sizes), context.temp_allocator)
	for s, i in p.sizes do sizes[i] = u32(s)
	geom.rec_put_slice(out, Cage_Tag.Sizes, sizes)
	geom.rec_put_slice(out, Cage_Tag.Corners, p.corners[:])
	geom.rec_put_slice(out, Cage_Tag.Groups, p.groups[:])
	ends := make([dynamic][2]u32, context.temp_allocator)
	creases := make([dynamic]f32, context.temp_allocator)
	for c, e in m.crease {
		if c == 0 do continue
		a, b := edge_verts(m, u32(e))
		append(&ends, [2]u32{a, b})
		append(&creases, c)
	}
	if len(creases) > 0 {
		geom.rec_put_slice(out, Cage_Tag.Crease_Ends, ends[:])
		geom.rec_put_slice(out, Cage_Tag.Crease, creases[:])
	}
	chosen := make([dynamic]u32, context.temp_allocator)
	for x, f in m.selected do if x do append(&chosen, u32(f))
	if len(chosen) > 0 do geom.rec_put_slice(out, Cage_Tag.Selected, chosen[:])
	picked := make([dynamic]u32, context.temp_allocator)
	for x, v in m.picked do if x do append(&picked, u32(v))
	if len(picked) > 0 do geom.rec_put_slice(out, Cage_Tag.Picked, picked[:])
}

// Reads a cage mesh_write wrote. ok is false, with nothing allocated, for damaged bytes
// or polygons that do not make a cage.
mesh_read :: proc(r: ^geom.Byte_Reader, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	rec := geom.record_take(r)
	if !rec.ok do return {}, false
	if known, _ := geom.record_known(&rec, Cage_Tag); !known do return {}, false
	t := context.temp_allocator
	if !geom.rec_has(&rec, Cage_Tag.Positions) || !geom.rec_has(&rec, Cage_Tag.Sizes) || !geom.rec_has(&rec, Cage_Tag.Corners) do return {}, false
	positions := geom.rec_get_slice(&rec, Cage_Tag.Positions, Vec3, t)
	sized := geom.rec_get_slice(&rec, Cage_Tag.Sizes, u32, t)
	corners := geom.rec_get_slice(&rec, Cage_Tag.Corners, u32, t)
	nv, nf, nc := len(positions), len(sized), len(corners)
	corner := make([]f32, nv, t)
	groups := make([]u16, nf, t)
	if geom.rec_has(&rec, Cage_Tag.Corner) do geom.rec_get_into(&rec, Cage_Tag.Corner, corner)
	if geom.rec_has(&rec, Cage_Tag.Groups) do geom.rec_get_into(&rec, Cage_Tag.Groups, groups)
	ends := geom.rec_get_slice(&rec, Cage_Tag.Crease_Ends, [2]u32, t)
	creases := geom.rec_get_slice(&rec, Cage_Tag.Crease, f32, t)
	chosen := geom.rec_get_slice(&rec, Cage_Tag.Selected, u32, t)
	picked := geom.rec_get_slice(&rec, Cage_Tag.Picked, u32, t)
	if !rec.ok || nf == 0 || nc < 3 * nf || len(ends) != len(creases) || len(chosen) > nf || len(picked) > nv do return {}, false
	sizes := make([]int, nf, t)
	total := 0
	for s, i in sized {
		sizes[i] = int(s)
		total += int(s)
	}
	if total != nc do return {}, false
	built, err := mesh_from_polygons(positions, sizes, corners, groups, allocator)
	if err != .None do return {}, false
	fits := true
	for c in corner do fits &&= c >= 0 && c <= INFINITE_SHARP // NaN too
	if fits do copy(built.corner[:], corner)
	for e, i in ends {
		c := creases[i]
		h := NONE
		if int(e[0]) < nv && int(e[1]) < nv do h = find_half_edge(&built, e[0], e[1])
		fits &&= h != NONE && c >= 0 && c <= INFINITE_SHARP
		if fits do built.crease[edge_of(h)] = c
	}
	for f in chosen {
		fits &&= int(f) < nf
		if fits do built.selected[f] = true
	}
	for v in picked {
		fits &&= int(v) < len(built.picked)
		if fits do built.picked[v] = true
	}
	if !fits {
		mesh_destroy(&built)
		return {}, false
	}
	return built, true
}
