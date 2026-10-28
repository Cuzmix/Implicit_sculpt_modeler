package poly

import "core:math"

// What one pass over a cage found, as numbers, so a test or a refused action says what
// broke. A sound cage has no broken links, no degenerate faces and no NaN (check_ok).
Check :: struct {
	vertices, edges, faces: int,
	border_edges:  int,
	triangles:     int,
	quads:         int,
	ngons:         int, // faces of five or more corners
	poles:         int, // inner vertices where other than four edges meet
	// Links that disagree: a next whose prev is not this, a face loop that does not close
	// or changes face, a twin on another vertex pair, a vertex whose half-edge does not
	// start at it, or a border vertex whose half-edge is not the border one.
	broken_links:  int,
	degenerate:    int, // faces of fewer than three corners or with a repeated corner
	nan_count:     int,
	euler:         int, // V - E + F: 2 for each closed shell of genus 0
}

// Checks every element's links. It allocates nothing but temp memory.
mesh_check :: proc(m: ^Mesh) -> (c: Check) {
	for v in 0 ..< u32(len(m.positions)) {
		c.vertices += 1
		p := m.positions[v]
		if math.is_nan(p.x) || math.is_nan(p.y) || math.is_nan(p.z) || math.is_inf(p.x) || math.is_inf(p.y) || math.is_inf(p.z) do c.nan_count += 1
		h := m.vert_he[v]
		if h == NONE || int(h) >= len(m.he_vert) || m.he_vert[h] != v {
			c.broken_links += 1
			continue
		}
		border := false
		n := 0
		w := vertex_walk(m, v)
		for o in vertex_walk_next(&w) {
			if m.he_vert[o] != v {
				c.broken_links += 1
				break
			}
			if m.he_face[o] == NONE do border = true
			n += 1
			if n > len(m.he_vert) {
				c.broken_links += 1
				break
			}
		}
		if border && m.he_face[h] != NONE do c.broken_links += 1
		if !border && n != 4 do c.poles += 1
	}
	for e in 0 ..< u32(len(m.crease)) {
		c.edges += 1
		if edge_border(m, e) do c.border_edges += 1
		if m.he_face[2 * e] == NONE && m.he_face[2 * e + 1] == NONE do c.broken_links += 1
		for h in ([2]u32{2 * e, 2 * e + 1}) {
			if m.he_prev[m.he_next[h]] != h || m.he_next[m.he_prev[h]] != h do c.broken_links += 1
			// A half-edge runs into the one that leaves where it ends, on the same face.
			if m.he_vert[m.he_next[h]] != he_tip(m, h) do c.broken_links += 1
			if m.he_face[m.he_next[h]] != m.he_face[h] do c.broken_links += 1
		}
	}
	corners := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< u32(len(m.face_he)) {
		c.faces += 1
		h := m.face_he[f]
		if m.he_face[h] != f {
			c.broken_links += 1
			continue
		}
		clear(&corners)
		w := face_walk(m, f)
		for o in face_walk_next(&w) {
			if m.he_face[o] != f {
				c.broken_links += 1
				break
			}
			append(&corners, m.he_vert[o])
			if len(corners) > len(m.he_vert) {
				c.broken_links += 1
				break
			}
		}
		repeated := false
		for v, i in corners do for u in corners[i + 1:] do if u == v do repeated = true
		switch {
		case len(corners) < 3 || repeated: c.degenerate += 1
		case len(corners) == 3:            c.triangles += 1
		case len(corners) == 4:            c.quads += 1
		case:                              c.ngons += 1
		}
	}
	c.euler = c.vertices - c.edges + c.faces
	return
}

check_ok :: proc(c: Check) -> bool {return c.broken_links == 0 && c.degenerate == 0 && c.nan_count == 0}
