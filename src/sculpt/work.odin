package sculpt

// How much a sculptor's dabs and flushes did, counted in vertices, so the bench and the
// exit stats can show how close the per-node work comes to the vertices that moved:
// a dab scans every owned vertex of the nodes its reach overlaps, the flush recomputes
// the normals of whole nodes, and undo saves whole nodes, while only the vertices
// inside the brush move. Counts only what the CPU lays; dabs the GPU takes count their
// scan and their undo saves but not their moves or normals.
Work_Counts :: struct {
	dabs:         u64, // dabs laid, each symmetry image one
	scanned:      u64, // owned vertices of the hit nodes, which the dab tests one by one
	moved:        u64, // vertices the dabs moved (a vertex moved by two dabs counts twice)
	renormalised: u64, // vertex normals the flushes recomputed
	saved:        u64, // vertex positions the stroke undo saved (not dynamic topology's whole pages)
}

// The counts since the last call, which starts them again from zero.
sculptor_work_take :: proc(s: ^Sculptor) -> Work_Counts {
	w := s.work
	s.work = {}
	return w
}
