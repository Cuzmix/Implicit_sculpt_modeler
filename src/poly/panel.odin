package poly

// Panel loops, as ZBrush's Panel Loops makes armour plates and hull panels of polygroups:
// the faces are inset by `width`, leaving a ring round each region that becomes the
// panel's chamfer, and then raised by `depth` along their normals (sunk into a groove
// when it is negative) on a wall of new faces in a polygroup of their own. The region's
// old outline, the foot of the wall and the panel's top outline are creased fully, so
// Smooth rounds the panel's faces and keeps those three loops crisp, as ZBrush's loops
// do. Each region of touching faces makes one panel. Returns the top faces (new ids) with
// the edit's result, the old faces' new ids in it; the cage is as it was when refused.
Panel :: struct {
	edit: Edit_Result, // from the cage before to the cage after
	top:  []u32, // the panels' faces, new ids
}

panel_destroy :: proc(p: ^Panel) {
	edit_result_destroy(&p.edit)
	delete(p.top)
	p^ = {}
}

panel_loops :: proc(m: ^Mesh, faces: []u32, width, depth: f32, allocator := context.allocator) -> (p: Panel, err: Build_Error) {
	if len(faces) == 0 || len(faces) == len(m.face_he) do return {}, .Degenerate_Face
	// The cage as it was, put back if the second step is refused after the first changed it.
	before := mesh_clone(m^, context.temp_allocator)
	// The inset's ring, its faces staying in the region's own polygroups.
	inset, d1 := inset_faces(m, faces, false, context.temp_allocator) or_return
	drag_apply(m, &d1, width)
	ring := make([]bool, len(m.face_he), context.temp_allocator)
	for f in inset.sides do ring[f] = true
	// The wall, in a polygroup of its own, as ZModeler's grouped extrude makes it.
	raise, d2, raise_err := extrude_faces(m, inset.faces, false, true, context.temp_allocator)
	if raise_err != .None {
		mesh_destroy(m)
		m^ = mesh_clone(before)
		return {}, raise_err
	}
	drag_apply(m, &d2, depth)
	// Which part of the panel each face is now: the ring (by where it came from), the wall
	// (new) or the top.
	Part :: enum u8 {Other, Ring, Wall, Top}
	part := make([]Part, len(m.face_he), context.temp_allocator)
	for from, f in raise.edit.face_from {
		switch {
		case from == NONE: part[f] = .Wall
		case ring[from]: part[f] = .Ring
		}
	}
	for f in raise.faces do part[f] = .Top
	// The loops: ring against the rest (the old outline), ring against wall (the foot) and
	// wall against top (the top outline).
	for e in 0 ..< u32(len(m.crease)) {
		if edge_border(m, e) do continue
		a, b := part[m.he_face[2 * e]], part[m.he_face[2 * e + 1]]
		if a > b do a, b = b, a
		if (a == .Other && b == .Ring) || (a == .Ring && b == .Wall) || (a == .Wall && b == .Top) do m.crease[e] = INFINITE_SHARP
	}
	// The two edits' maps chained: each final face to the first cage's face, or NONE.
	p.edit.vert = make([]u32, len(inset.edit.vert), allocator)
	for v, i in inset.edit.vert do p.edit.vert[i] = raise.edit.vert[v] if v != NONE else NONE
	p.edit.face_from = make([]u32, len(raise.edit.face_from), allocator)
	for from, f in raise.edit.face_from do p.edit.face_from[f] = inset.edit.face_from[from] if from != NONE else NONE
	p.top = make([]u32, len(raise.faces), allocator)
	copy(p.top, raise.faces)
	return p, .None
}
