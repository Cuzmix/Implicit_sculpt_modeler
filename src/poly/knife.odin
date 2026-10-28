package poly

import "core:math/linalg"
import "core:slice"

// The knife (ZModeler's Slice, Blender's Knife as a pen stroke): a cut is a chain of
// points on edges, in the order the stroke crossed them. Each point goes into its edge,
// and each face two points running on from each other share is split between them, so a
// stroke across the cage leaves a new edge path where it went. Points closer along an
// edge than a millionth of it are one point, so chains that cross at an edge (a cut and
// its mirror image on the plane) meet there.

// A point of a cut: on edge `edge`, a share `at` of the way from its first end (0 or 1
// for that end itself).
Knife_Point :: struct {
	edge: u32,
	at:   f32,
}

// The knife point that is vertex v.
knife_at_point :: proc(m: ^Mesh, v: u32) -> Knife_Point {
	h := m.vert_he[v]
	return {edge_of(h), 0 if h & 1 == 0 else 1}
}

knife_cut :: proc(m: ^Mesh, chains: [][]Knife_Point, allocator := context.allocator) -> (r: Edit_Result, err: Build_Error) {
	ed := edit_begin(m, context.temp_allocator)
	// Per edge its points, sorted along it; each chain point's new vertex.
	Along :: struct {
		at: f32,
		id: u32,
	}
	on_edge := make(map[u32][dynamic]Along, allocator = context.temp_allocator)
	ids := make([][]u32, len(chains), context.temp_allocator)
	for chain, c in chains {
		ids[c] = make([]u32, len(chain), context.temp_allocator)
		for p, i in chain {
			if int(p.edge) >= len(m.crease) do return {}, .Degenerate_Face
			at := clamp(p.at, 0, 1)
			// At an end, the point is that end: a cut may start or stop at a corner.
			if at == 0 || at == 1 {
				a, b := edge_verts(m, p.edge)
				ids[c][i] = a if at == 0 else b
				continue
			}
			list, ok := on_edge[p.edge]
			if !ok do list = make([dynamic]Along, context.temp_allocator)
			found := NONE
			for x in list do if abs(x.at - at) < 1e-6 do found = x.id
			if found == NONE {
				a, b := edge_verts(m, p.edge)
				found = edit_vertex(&ed, linalg.lerp(m.positions[a], m.positions[b], at))
				append(&list, Along{at, found})
			}
			on_edge[p.edge] = list
			ids[c][i] = found
		}
	}
	for e, &list in on_edge {
		slice.sort_by(list[:], proc(x, y: Along) -> bool {return x.at < y.at})
		// The pieces of a creased edge keep its crease.
		if c := m.crease[e]; c > 0 {
			a, b := edge_verts(m, e)
			from := a
			for x in list {
				ed.creases[edit_key(from, x.id)] = c
				from = x.id
			}
			ed.creases[edit_key(from, b)] = c
		}
	}

	// Every face takes the points on its edges, in order round it.
	for &f in ed.faces {
		clear(&f.verts)
		w := face_walk(m, f.from)
		for h in face_walk_next(&w) {
			append(&f.verts, m.he_vert[h])
			list, ok := on_edge[edge_of(h)]
			if !ok do continue
			if h & 1 == 0 {
				for x in list do append(&f.verts, x.id)
			} else {
				#reverse for x in list do append(&f.verts, x.id)
			}
		}
	}
	// Then each pair of points running on from each other splits the face they share. A
	// pair a cut before it parted (a cut and its mirror image across one face) meets that
	// cut at a new point, and each half splits on its own side.
	for chain in ids {
		for i in 0 ..< len(chain) - 1 {
			a, b := chain[i], chain[i + 1]
			if a == b do continue
			if f := knife_face_of(&ed, a, b); f >= 0 {
				knife_split(&ed, f, a, b)
				continue
			}
			knife_cross(&ed, a, b)
		}
	}
	return edit_end(m, &ed, allocator)
}

// The mirror images of a cut under `axes` (the cut itself not among them): each point
// goes to the image of its edge, at the same share from the image of the same end. An
// image whose edges are not all there is left out.
knife_images :: proc(m: ^Mesh, chain: []Knife_Point, axes: Mirror_Axes, allocator := context.allocator) -> [][]Knife_Point {
	signs := mirror_signs(axes)
	out := make([dynamic][]Knife_Point, 0, len(signs), allocator)
	if len(signs) < 2 do return out[:]
	slack := mirror_slack(m)
	g := point_grid_make(m, slack)
	for s in signs[1:] {
		image := make([]Knife_Point, len(chain), allocator)
		whole := true
		for p, i in chain {
			a, b := edge_verts(m, p.edge)
			ia := nearest_point(m, &g, m.positions[a] * s, slack)
			ib := nearest_point(m, &g, m.positions[b] * s, slack)
			h := find_half_edge(m, ia, ib) if ia != NONE && ib != NONE else NONE
			if h == NONE {
				whole = false
				break
			}
			image[i] = {edge_of(h), p.at if h & 1 == 0 else 1 - p.at}
		}
		if whole {
			append(&out, image)
		} else {
			delete(image, allocator)
		}
	}
	return out[:]
}

// The face of an edit holding both a and b, or -1.
@(private = "file")
knife_face_of :: proc(ed: ^Edit, a, b: u32) -> int {
	for f, i in ed.faces {
		if slice.contains(f.verts[:], a) && slice.contains(f.verts[:], b) do return i
	}
	return -1
}

// Splits face f of an edit between its corners a and b; side by side round it (on one
// edge, or a corner apart by an edge) there is nothing to split.
@(private = "file")
knife_split :: proc(ed: ^Edit, f: int, a, b: u32) {
	verts := ed.faces[f].verts[:]
	ia, _ := slice.linear_search(verts, a)
	ib, _ := slice.linear_search(verts, b)
	n := len(verts)
	if (ia + 1) % n == ib || (ib + 1) % n == ia do return
	first := make([dynamic]u32, context.temp_allocator)
	second := make([dynamic]u32, context.temp_allocator)
	for k := ia; ; k = (k + 1) % n {
		append(&first, verts[k])
		if k == ib do break
	}
	for k := ib; ; k = (k + 1) % n {
		append(&second, verts[k])
		if k == ia do break
	}
	group, from := ed.faces[f].group, ed.faces[f].from
	clear(&ed.faces[f].verts)
	append(&ed.faces[f].verts, ..first[:])
	_ = edit_face(ed, second[:], group, from)
}

// A pair of points an earlier cut parted: the faces either side of that cut that hold a
// and b, and the cut's edge between them that segment a-b crosses. A new point goes on
// that edge where the two lines pass nearest, and each face splits to it. A pair with no
// such edge is left uncut.
@(private = "file")
knife_cross :: proc(ed: ^Edit, a, b: u32) {
	pa, pb := ed.positions[a], ed.positions[b]
	for fa in 0 ..< len(ed.faces) {
		va := ed.faces[fa].verts[:]
		if !slice.contains(va, a) do continue
		n := len(va)
		for k in 0 ..< n {
			c, d := va[k], va[(k + 1) % n]
			if c == a || d == a do continue
			// The face across edge c-d, which runs d to c there, must hold b.
			fb := -1
			for g, j in ed.faces {
				if j == fa || !slice.contains(g.verts[:], b) do continue
				m := len(g.verts)
				for q in 0 ..< m do if g.verts[q] == d && g.verts[(q + 1) % m] == c do fb = j
				if fb >= 0 do break
			}
			if fb < 0 do continue
			// Where the lines a-b and c-d pass nearest, as a share along c-d.
			pc, pd := ed.positions[c], ed.positions[d]
			u, w := pb - pa, pd - pc
			r := pa - pc
			uu, uw, ww := linalg.dot(u, u), linalg.dot(u, w), linalg.dot(w, w)
			den := uu * ww - uw * uw
			if den <= 1e-12 * uu * ww do continue
			t := (uu * linalg.dot(w, r) - uw * linalg.dot(u, r)) / den
			if t <= 0.001 || t >= 0.999 do continue
			x := edit_vertex(ed, linalg.lerp(pc, pd, t))
			// Into both faces between c and d, then each splits to it.
			inject_at(&ed.faces[fa].verts, k + 1, x)
			vb := &ed.faces[fb].verts
			for q in 0 ..< len(vb) {
				if vb[q] == d && vb[(q + 1) % len(vb)] == c {
					inject_at(vb, q + 1, x)
					break
				}
			}
			knife_split(ed, fa, a, x)
			knife_split(ed, fb, x, b)
			return
		}
	}
}
