package poly

import "core:math"
import "core:math/linalg"

// Creases: how sharp an edge or a corner stays when the cage is smoothed (subdivide.odin),
// from 0 (smooth) up to INFINITE_SHARP, as OpenSubdiv's and Blender's do. A sharpness of
// n keeps the edge sharp for n smoothing steps and then lets it round, which reads as a
// soft edge; INFINITE_SHARP never rounds. None of these change the cage's topology.

// Sets edges `edges` to `sharpness` (0 removes their crease). Returns whether any changed.
crease_edges :: proc(m: ^Mesh, edges: []u32, sharpness: f32) -> (changed: bool) {
	s := clamp(sharpness, 0, INFINITE_SHARP)
	for e in edges {
		if int(e) >= len(m.crease) || m.crease[e] == s do continue
		m.crease[e] = s
		changed = true
	}
	return
}

// Sets points `verts` to corner sharpness `sharpness` (0 removes it): a corner stays where
// it is while the faces round it smooth. Returns whether any changed.
crease_points :: proc(m: ^Mesh, verts: []u32, sharpness: f32) -> (changed: bool) {
	s := clamp(sharpness, 0, INFINITE_SHARP)
	for v in verts {
		if int(v) >= len(m.corner) || m.corner[v] == s do continue
		m.corner[v] = s
		changed = true
	}
	return
}

// Creases fully every inner edge whose two faces bend more than `degrees` from each other,
// as ZModeler's Crease by angle and Blender's Mark sharp by angle do. Returns how many
// edges it creased that were not already.
crease_by_angle :: proc(m: ^Mesh, degrees: f32) -> (count: int) {
	limit := math.cos(degrees * math.RAD_PER_DEG)
	for e in 0 ..< u32(len(m.crease)) {
		if edge_border(m, e) || m.crease[e] >= INFINITE_SHARP do continue
		f1, f2 := m.he_face[2 * e], m.he_face[2 * e + 1]
		if linalg.dot(face_normal(m, f1), face_normal(m, f2)) < limit {
			m.crease[e] = INFINITE_SHARP
			count += 1
		}
	}
	return
}

// Creases fully every edge between two polygroups, as ZModeler's Crease polygroups does.
// Returns how many edges it creased that were not already.
crease_group_borders :: proc(m: ^Mesh) -> (count: int) {
	for e in 0 ..< u32(len(m.crease)) {
		if edge_border(m, e) || m.crease[e] >= INFINITE_SHARP do continue
		if m.group[m.he_face[2 * e]] != m.group[m.he_face[2 * e + 1]] {
			m.crease[e] = INFINITE_SHARP
			count += 1
		}
	}
	return
}

// Removes every crease and corner. Returns how many edges and points had one.
crease_clear :: proc(m: ^Mesh) -> (count: int) {
	for &c in m.crease do if c != 0 {
		c = 0
		count += 1
	}
	for &c in m.corner do if c != 0 {
		c = 0
		count += 1
	}
	return
}

// How many edges have a crease and how many points a corner.
crease_count :: proc(m: ^Mesh) -> (edges, points: int) {
	for c in m.crease do if c > 0 do edges += 1
	for c in m.corner do if c > 0 do points += 1
	return
}
