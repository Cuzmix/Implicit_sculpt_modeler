package sculpt

// A morph target, as in ZBrush: a copy of the surface kept so the Morph brush can paint
// parts of later work away, back to it. It belongs to one sculptor (one subdivision
// level), is not saved with the scene, and is dropped when dynamic topology turns on,
// since that renumbers the vertices.

// Keeps the current positions as the morph target, replacing any earlier one. Refused
// (false) while dynamic topology is on: its strokes add and remove vertices.
sculptor_morph_store :: proc(s: ^Sculptor) -> bool {
	if s.dyn != nil do return false
	if len(s.morph) != len(s.mesh.positions) {
		delete(s.morph, s.history.allocator)
		s.morph = make([]Vec3, len(s.mesh.positions), s.history.allocator)
	}
	copy(s.morph, s.mesh.positions[:])
	return true
}

sculptor_morph_clear :: proc(s: ^Sculptor) {
	delete(s.morph, s.history.allocator)
	s.morph = nil
}

sculptor_has_morph :: proc(s: ^Sculptor) -> bool {return s.morph != nil}
