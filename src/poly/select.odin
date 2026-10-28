package poly

import "core:math/linalg"

// Model mode's selection: a flag per face (Mesh.selected) that actions with the Selection
// target work on, as Blender's edit mode selection and ZModeler's temporary polygroups do.
// Edits carry it to the faces that come from selected ones, and the cage's file and undo
// snapshots keep it.

Select_Op :: enum u8 {
	All,
	None,
	Invert,
	Grow, // add the faces sharing an edge with a selected one
	Shrink, // drop the selected faces with an edge on an unselected face or a border
}

// Selects (or with `on` false, deselects) `faces`; reports whether anything changed.
select_set :: proc(m: ^Mesh, faces: []u32, on: bool) -> (changed: bool) {
	for f in faces {
		if int(f) >= len(m.selected) || m.selected[f] == on do continue
		m.selected[f] = on
		changed = true
	}
	return
}

// The selected faces, ascending, into `out` (cleared first).
selected_faces :: proc(m: ^Mesh, out: ^[dynamic]u32) {
	clear(out)
	for x, f in m.selected do if x do append(out, u32(f))
}

// Changes the selection as `op` says; reports whether anything changed.
select_op :: proc(m: ^Mesh, op: Select_Op) -> (changed: bool) {
	was := make([]bool, len(m.selected), context.temp_allocator)
	copy(was, m.selected[:])
	switch op {
	case .All:
		for &x in m.selected do x = true
	case .None:
		for &x in m.selected do x = false
	case .Invert:
		for &x in m.selected do x = !x
	case .Grow, .Shrink:
		// Both look at the selection as it was, so the result does not depend on the order
		// faces are visited in.
		for f in 0 ..< u32(len(m.face_he)) {
			if was[f] == (op == .Grow) do continue
			w := face_walk(m, f)
			for h in face_walk_next(&w) {
				other := m.he_face[twin(h)]
				if op == .Grow && other != NONE && was[other] {
					m.selected[f] = true
					break
				}
				if op == .Shrink && (other == NONE || !was[other]) {
					m.selected[f] = false
					break
				}
			}
		}
	}
	for x, f in m.selected do if x != was[f] do return true
	return false
}

// The faces like face f, ascending, into `out` (cleared first): those with as many
// corners and an area within a tenth of its (Blender's Select similar by sides and area),
// such as every window of a facade once one is picked.
similar_faces :: proc(m: ^Mesh, f: u32, out: ^[dynamic]u32) {
	clear(out)
	n := face_size(m, f)
	area := linalg.length(face_area_vector(m, f))
	for g in 0 ..< u32(len(m.face_he)) {
		if face_size(m, g) != n do continue
		if abs(linalg.length(face_area_vector(m, g)) - area) <= area * 0.1 do append(out, g)
	}
}
