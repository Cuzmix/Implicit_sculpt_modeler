package poly

import "core:slice"

// How actions change topology: the cage goes out as a list of polygons (edit_begin), the
// action removes, adds and rewires polygons in that list, and edit_end builds the cage
// again from it. Rebuilding is linear in the cage's size, which for the low-polygon cages
// Model mode edits is a fraction of a millisecond to a few milliseconds, and it means no
// action can leave a broken link: the result is a valid cage or the action is refused
// with the reason, and the cage is left as it was.
//
// Ids: vertices keep their numbers (new ones are appended; unused ones are dropped at
// the end, which the returned Remap reports), faces keep their order (removed faces drop
// out, new ones follow), and edges are numbered afresh in the order the faces meet them.
// Creases ride on the vertex pair, so they survive any rewiring that keeps the pair.
Edit :: struct {
	positions: [dynamic]Vec3,
	corner:    [dynamic]f32,
	faces:     [dynamic]Edit_Face,
	creases:   map[u64]f32, // by edit_key of the edge's two vertices
}

// One polygon of an edit: its corners in order (counter-clockwise outward), its group,
// and the face it came from (NONE for a new face), so actions and the app can follow it.
Edit_Face :: struct {
	verts: [dynamic]u32,
	group: u16,
	from:  u32,
}

edit_key :: #force_inline proc "contextless" (a, b: u32) -> u64 {return u64(min(a, b)) << 32 | u64(max(a, b))}

edit_destroy :: proc(e: ^Edit) {
	delete(e.positions)
	delete(e.corner)
	for &f in e.faces do delete(f.verts)
	delete(e.faces)
	delete(e.creases)
	e^ = {}
}

// The cage as an editable list of polygons, in face order.
edit_begin :: proc(m: ^Mesh, allocator := context.allocator) -> (e: Edit) {
	e.positions = make([dynamic]Vec3, 0, len(m.positions), allocator)
	e.corner = make([dynamic]f32, 0, len(m.positions), allocator)
	e.faces = make([dynamic]Edit_Face, 0, len(m.face_he), allocator)
	e.creases = make(map[u64]f32, allocator = allocator)
	append(&e.positions, ..m.positions[:])
	append(&e.corner, ..m.corner[:])
	for f in 0 ..< u32(len(m.face_he)) {
		ef := Edit_Face{verts = make([dynamic]u32, allocator), group = m.group[f], from = f}
		face_verts(m, f, &ef.verts)
		append(&e.faces, ef)
	}
	for c, i in m.crease {
		if c == 0 do continue
		a, b := edge_verts(m, u32(i))
		e.creases[edit_key(a, b)] = c
	}
	return
}

// Adds a vertex to the edit and returns its id.
edit_vertex :: proc(e: ^Edit, p: Vec3, corner: f32 = 0) -> u32 {
	append(&e.positions, p)
	append(&e.corner, corner)
	return u32(len(e.positions) - 1)
}

// Adds a polygon (the slice is copied) and returns its place in the edit.
edit_face :: proc(e: ^Edit, verts: []u32, group: u16, from: u32 = NONE) -> int {
	f := Edit_Face{verts = make([dynamic]u32, 0, len(verts), e.faces.allocator), group = group, from = from}
	append(&f.verts, ..verts)
	append(&e.faces, f)
	return len(e.faces) - 1
}

// Where face f of the cage sits in the edit, or -1 when it was removed.
edit_find :: proc(e: ^Edit, f: u32) -> int {
	for ef, i in e.faces do if ef.from == f do return i
	return -1
}

// What edit_end made: the old vertex ids to the new (NONE for a dropped vertex), and for
// each new face the edit face it was built from.
Edit_Result :: struct {
	vert: []u32,
	face_from: []u32, // per new face: the cage face it came from, or NONE when new
}

edit_result_destroy :: proc(r: ^Edit_Result) {
	delete(r.vert)
	delete(r.face_from)
	r^ = {}
}

// Builds the cage again from the edit, dropping vertices no face uses. On an error the
// cage is untouched and the result empty.
edit_end :: proc(m: ^Mesh, e: ^Edit, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	used := make([]bool, len(e.positions), context.temp_allocator)
	sizes := make([dynamic]int, 0, len(e.faces), context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, 0, len(e.faces), context.temp_allocator)
	for f in e.faces {
		append(&sizes, len(f.verts))
		for v in f.verts {
			if int(v) >= len(e.positions) do return {}, .Degenerate_Face
			used[v] = true
		}
		append(&groups, f.group)
	}
	vert := make([]u32, len(e.positions), allocator)
	positions := make([dynamic]Vec3, context.temp_allocator)
	next: u32
	for u, v in used {
		if !u {
			vert[v] = NONE
			continue
		}
		vert[v] = next
		next += 1
		append(&positions, e.positions[v])
	}
	for f in e.faces do for v in f.verts do append(&corners, vert[v])
	built, b_err := mesh_from_polygons(positions[:], sizes[:], corners[:], groups[:], m.positions.allocator)
	if b_err != .None {
		delete(vert, allocator)
		return {}, b_err
	}
	for v in 0 ..< len(e.positions) do if vert[v] != NONE do built.corner[vert[v]] = e.corner[v]
	for key, c in e.creases {
		a, b := u32(key >> 32), u32(key & 0xffff_ffff)
		if int(a) >= len(vert) || int(b) >= len(vert) || vert[a] == NONE || vert[b] == NONE do continue
		if h := find_half_edge(&built, vert[a], vert[b]); h != NONE do built.crease[edge_of(h)] = c
	}
	// A face keeps the selection of the face it came from; new faces start unselected.
	for f, i in e.faces do if f.from != NONE && int(f.from) < len(m.selected) do built.selected[i] = m.selected[f.from]
	mesh_destroy(m)
	m^ = built
	r.vert = vert
	r.face_from = make([]u32, len(e.faces), allocator)
	for f, i in e.faces do r.face_from[i] = f.from
	return r, .None
}

// Removes faces `faces` (cage ids), leaving holes, as ZModeler's Delete does. Vertices
// left with no face go. Refused, with the cage as it was, when what is left cannot be a
// cage (two pieces left touching at a single point).
delete_faces :: proc(m: ^Mesh, faces: []u32, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	gone := make([]bool, len(m.face_he), context.temp_allocator)
	for f in faces do gone[f] = true
	e := edit_begin(m, context.temp_allocator)
	kept := make([dynamic]Edit_Face, 0, len(e.faces), context.temp_allocator)
	for f in e.faces do if !gone[f.from] do append(&kept, f)
	e.faces = kept
	return edit_end(m, &e, allocator)
}

// Sorted, without repeats: how actions take a target's ids.
@(private)
unique :: proc(ids: []u32) -> []u32 {
	slice.sort(ids)
	return slice.unique(ids)
}
