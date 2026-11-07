package sculpt

import "core:math/linalg"
import "core:slice"

import "../geom"

// Poseable symmetry, after ZBrush's Use Poseable Symmetry and Blender's topology mirror:
// each vertex's partner across the mirror is found once by the mesh's topology, so once
// the model is posed (an arm raised, the head turned) a dab on one side still lands on
// the same place of the other side, wherever that is now, rather than across a plane.
//
// The pairing walks the triangles outward from a seed pair, as a mirror reverses each
// triangle's winding: a triangle (a, b, c) whose a and b are paired with a' and b' pairs
// with the triangle holding the edge b' -> a', and its third corner with c. Geometry only
// chooses the seed: on each island the vertices whose mirror image lies nearest a vertex
// are tried, and of the walks that agree with themselves everywhere, the one covering the
// most with the smallest geometric mismatch is kept. A mesh whose topology is not
// symmetric gets no pairs on the islands where the walk disagrees with itself, and dabs
// there fall back to the mirror plane.

MIRROR_NONE :: max(u32)

// How many seeds an island tries, and how many of its vertices are scored as seeds.
@(private = "file")
MIRROR_SEEDS :: 8
@(private = "file")
MIRROR_SAMPLES :: 64

// Whether s has pairs for poseable symmetry that still fit its mesh.
sculptor_mirror_ready :: proc(s: ^Sculptor) -> bool {
	return s.mirror != nil && len(s.mirror) == len(s.mesh.positions) && s.dyn == nil
}

// Drops the pairs (a topology change, or poseable symmetry turned off).
sculptor_mirror_clear :: proc(s: ^Sculptor) {
	delete(s.mirror, s.history.allocator)
	s.mirror, s.mirror_paired = nil, 0
}

// Finds each vertex's partner across the plane through `center` normal to `axis`, by the
// mesh's topology, for poseable symmetry. Returns how many vertices were paired (a vertex
// on the mirror is its own partner); ok is false, with no pairs kept, when none were or
// the sculptor has dynamic topology on (its triangles change under every stroke).
sculptor_mirror_find :: proc(s: ^Sculptor, axis: Axis, center: Vec3) -> (paired: int, ok: bool) {
	sculptor_mirror_clear(s)
	if s.dyn != nil || len(s.faces.offsets) != len(s.mesh.positions) + 1 do return 0, false
	n := len(s.mesh.positions)
	if n == 0 do return 0, false
	t := context.temp_allocator
	w := Mirror_Walk {
		s       = s,
		axis    = int(axis),
		center  = center,
		pair    = make([]u32, n, s.history.allocator),
		tri_img = make([]u32, len(s.mesh.indices) / 3, t),
		set_verts = make([dynamic]u32, t),
		set_tris = make([dynamic]u32, t),
	}
	slice.fill(w.pair, MIRROR_NONE)
	slice.fill(w.tri_img, MIRROR_NONE)
	island := mirror_islands(s, t)
	// The vertices by island, each island's in ascending order, islands by their
	// smallest vertex.
	first := make([]u32, n + 1, t)
	for r in island do first[r + 1] += 1
	for i in 0 ..< n do first[i + 1] += first[i]
	order := make([]u32, n, t)
	for r, v in island {
		order[first[r]] = u32(v)
		first[r] += 1
	}
	for lo := 0; lo < n; {
		hi := lo + 1
		for hi < n && island[order[hi]] == island[order[lo]] do hi += 1
		// An island its partner's walk already paired is done.
		if w.pair[order[lo]] == MIRROR_NONE do mirror_island(&w, order[lo:hi])
		lo = hi
	}
	for p in w.pair do if p != MIRROR_NONE do paired += 1
	if paired == 0 {
		delete(w.pair, s.history.allocator)
		return 0, false
	}
	s.mirror, s.mirror_paired, s.mirror_axis = w.pair, paired, axis
	return paired, true
}

@(private = "file")
Mirror_Walk :: struct {
	s:       ^Sculptor,
	axis:    int,
	center:  Vec3,
	pair:    []u32, // per vertex its partner, MIRROR_NONE while unpaired
	tri_img: []u32, // per triangle its mirror triangle
	// What the walk under way set, to take back if it disagrees with itself.
	set_verts: [dynamic]u32,
	set_tris:  [dynamic]u32,
	clash:     bool,
}

@(private = "file")
Mirror_Step :: struct {
	t:          u32, // a triangle holding the edge a -> b
	a, b:       u32,
	a_img, b_img: u32,
}

// Per vertex, the smallest vertex of its island (vertices joined by triangles).
@(private = "file")
mirror_islands :: proc(s: ^Sculptor, allocator := context.allocator) -> []u32 {
	n := len(s.mesh.positions)
	root := make([]u32, n, allocator)
	for &r, i in root do r = u32(i)
	find :: proc(root: []u32, v: u32) -> u32 {
		v := v
		for root[v] != v {
			root[v] = root[root[v]]
			v = root[v]
		}
		return v
	}
	idx := s.mesh.indices[:]
	for k := 0; k + 2 < len(idx); k += 3 {
		a := find(root, idx[k])
		for c in idx[k + 1:k + 3] {
			b := find(root, c)
			if a < b do root[b] = a
			else if b < a {
				root[a] = b
				a = b
			}
		}
	}
	for v in 0 ..< n do root[v] = find(root, u32(v))
	return root
}

// The triangle holding the directed edge a -> b, or MIRROR_NONE.
@(private = "file")
tri_with :: proc(s: ^Sculptor, a, b: u32) -> u32 {
	idx := s.mesh.indices[:]
	for f in s.faces.tris[s.faces.offsets[a]:s.faces.offsets[a + 1]] {
		c := idx[3 * f:3 * f + 3]
		for k in 0 ..< 3 do if c[k] == a && c[(k + 1) % 3] == b do return f
	}
	return MIRROR_NONE
}

// The corner of triangle f that is neither a nor b.
@(private = "file")
tri_third :: proc(s: ^Sculptor, f, a, b: u32) -> u32 {
	for c in s.mesh.indices[3 * f:3 * f + 3] do if c != a && c != b do return c
	return MIRROR_NONE
}

@(private = "file")
reflect :: proc(w: ^Mirror_Walk, p: Vec3) -> Vec3 {
	q := p
	q[w.axis] = 2 * w.center[w.axis] - p[w.axis]
	return q
}

// Pairs v with v_img (and v_img with v); a vertex already paired otherwise is a clash.
@(private = "file")
pair_set :: proc(w: ^Mirror_Walk, v, v_img: u32) {
	if w.pair[v] == v_img && w.pair[v_img] == v do return
	if w.pair[v] != MIRROR_NONE || w.pair[v_img] != MIRROR_NONE {
		w.clash = true
		return
	}
	w.pair[v], w.pair[v_img] = v_img, v
	append(&w.set_verts, v, v_img)
}

// Walks outward from the seed step, pairing triangles and their corners, until it runs
// out of triangles or clashes.
@(private = "file")
mirror_walk :: proc(w: ^Mirror_Walk, seed: Mirror_Step) {
	s := w.s
	queue := make([dynamic]Mirror_Step, 0, 1024, context.temp_allocator)
	append(&queue, seed)
	for head := 0; head < len(queue) && !w.clash; head += 1 {
		st := queue[head]
		// A triangle reached again is not looked up again: its corners were paired when it
		// was first reached, and pair_set catches a walk that disagrees with them.
		if st.t == MIRROR_NONE || w.tri_img[st.t] != MIRROR_NONE do continue
		img := tri_with(s, st.b_img, st.a_img)
		if img == MIRROR_NONE do continue
		if w.tri_img[img] != MIRROR_NONE && w.tri_img[img] != st.t {
			w.clash = true
			continue
		}
		w.tri_img[st.t], w.tri_img[img] = img, st.t
		append(&w.set_tris, st.t, img)
		c, c_img := tri_third(s, st.t, st.a, st.b), tri_third(s, img, st.a_img, st.b_img)
		pair_set(w, st.a, st.a_img)
		pair_set(w, st.b, st.b_img)
		pair_set(w, c, c_img)
		// Each edge's other triangle, with the edge as it runs there, while not yet paired.
		next := [3]Mirror_Step{{tri_with(s, st.b, st.a), st.b, st.a, st.b_img, st.a_img}, {tri_with(s, c, st.b), c, st.b, c_img, st.b_img}, {tri_with(s, st.a, c), st.a, c, st.a_img, c_img}}
		for n in next do if n.t != MIRROR_NONE && w.tri_img[n.t] == MIRROR_NONE do append(&queue, n)
	}
}

// Takes back what the last walk set.
@(private = "file")
walk_undo :: proc(w: ^Mirror_Walk) {
	for v in w.set_verts do w.pair[v] = MIRROR_NONE
	for f in w.set_tris do w.tri_img[f] = MIRROR_NONE
	clear(&w.set_verts)
	clear(&w.set_tris)
	w.clash = false
}

// The vertex nearest p within `reach`, or MIRROR_NONE.
@(private = "file")
vertex_near :: proc(s: ^Sculptor, p: Vec3, reach: f32) -> u32 {
	tri, bary, _, ok := geom.bvh_closest(s.bvh, s.mesh^, p, reach)
	if !ok do return MIRROR_NONE
	k := 0
	for j in 1 ..< 3 do if bary[j] > bary[k] do k = j
	return s.mesh.indices[3 * tri + u32(k)]
}

// Pairs one island (and the island it mirrors onto) from the best of its seeds.
@(private = "file")
mirror_island :: proc(w: ^Mirror_Walk, members: []u32) {
	s := w.s
	pos := s.mesh.positions[:]
	box := geom.AABB_EMPTY
	for v in members do geom.aabb_grow(&box, pos[v])
	reach := linalg.length(box.hi - box.lo)
	if reach <= 0 do return
	Seed :: struct {
		v, v_img: u32,
		miss:     f32,
	}
	seeds := make([dynamic]Seed, 0, MIRROR_SAMPLES, context.temp_allocator)
	stride := max(1, len(members) / MIRROR_SAMPLES)
	for i := 0; i < len(members); i += stride {
		v := members[i]
		p := reflect(w, pos[v])
		v_img := vertex_near(s, p, reach)
		if v_img == MIRROR_NONE do continue
		append(&seeds, Seed{v, v_img, linalg.length(pos[v_img] - p)})
	}
	slice.sort_by(seeds[:], proc(a, b: Seed) -> bool {return a.miss < b.miss || (a.miss == b.miss && a.v < b.v)})
	best_pairs, best_tris: [dynamic]u32
	best_pairs.allocator, best_tris.allocator = context.temp_allocator, context.temp_allocator
	best_count, best_miss := 0, max(f32)
	for seed in seeds[:min(len(seeds), MIRROR_SEEDS)] {
		// The seed's edge: v to its first neighbour, and its image to the image's
		// neighbour nearest that neighbour's mirror image.
		f := s.faces.tris[s.faces.offsets[seed.v]]
		u := s.mesh.indices[3 * f + (u32(slice.linear_search(s.mesh.indices[3 * f:3 * f + 3], seed.v) or_else 0) + 1) % 3]
		u_mirror := reflect(w, pos[u])
		u_img, near := MIRROR_NONE, max(f32)
		for g in s.faces.tris[s.faces.offsets[seed.v_img]:s.faces.offsets[seed.v_img + 1]] {
			for c in s.mesh.indices[3 * g:3 * g + 3] {
				if c == seed.v_img do continue
				d := linalg.length(pos[c] - u_mirror)
				if d < near || (d == near && c < u_img) do u_img, near = c, d
			}
		}
		if u_img == MIRROR_NONE do continue
		mirror_walk(w, {tri_with(s, seed.v, u), seed.v, u, seed.v_img, u_img})
		count := len(w.set_verts)
		miss: f32
		for k := 0; k < len(w.set_verts); k += 2 do miss += linalg.length(reflect(w, pos[w.set_verts[k]]) - pos[w.set_verts[k + 1]])
		if count > 0 do miss /= f32(count)
		// A walk that pairs the whole island and lands on average within a tenth of its
		// size of the mirror image is kept as it is, without trying the other seeds (each
		// costs a whole walk): only another of the mesh's own symmetries, a turn rather
		// than this mirror, pairs a whole island too, and lands far from the mirror image.
		if !w.clash && count >= len(members) && miss < 0.1 * reach {
			clear(&w.set_verts)
			clear(&w.set_tris)
			return
		}
		if !w.clash && count > 0 && (count > best_count || (count == best_count && miss < best_miss)) {
			best_count, best_miss = count, miss
			clear(&best_pairs)
			clear(&best_tris)
			append(&best_pairs, ..w.set_verts[:])
			append(&best_tris, ..w.set_tris[:])
		}
		walk_undo(w)
	}
	for k := 0; k < len(best_pairs); k += 2 {
		a, b := best_pairs[k], best_pairs[k + 1]
		w.pair[a], w.pair[b] = b, a
	}
	for k := 0; k < len(best_tris); k += 2 {
		a, b := best_tris[k], best_tris[k + 1]
		w.tri_img[a], w.tri_img[b] = b, a
	}
}

// The image of a dab at `center` under poseable symmetry: from the vertex nearest it to
// that vertex's partner, the surface's frame there (its normal, and the way to a paired
// neighbour) taken onto the partner's, turned over as a mirror turns it. Not ok where no
// paired vertex is within the radius.
mirror_image :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> (img: Sym_Image, ok: bool) {
	v := vertex_near(s, center, max(radius, 1e-6))
	if v == MIRROR_NONE || s.mirror[v] == MIRROR_NONE do return {}, false
	v_img := s.mirror[v]
	u := MIRROR_NONE
	idx := s.mesh.indices[:]
	pos := s.mesh.positions[:]
	search: for f in s.faces.tris[s.faces.offsets[v]:s.faces.offsets[v + 1]] {
		for c in idx[3 * f:3 * f + 3] do if c != v && s.mirror[c] != MIRROR_NONE {
			u = c
			break search
		}
	}
	if u == MIRROR_NONE do return {}, false
	frame :: proc(n, to: Vec3) -> (t, b, nn: Vec3, ok: bool) {
		nn = linalg.normalize0(n)
		t = linalg.normalize0(to - nn * linalg.dot(to, nn))
		if nn == {} || t == {} do return
		return t, linalg.cross(nn, t), nn, true
	}
	t0, b0, n0, ok0 := frame(s.mesh.normals[v], pos[u] - pos[v])
	t1, b1, n1, ok1 := frame(s.mesh.normals[v_img], pos[s.mirror[u]] - pos[v_img])
	if !ok0 || !ok1 do return {}, false
	from := matrix[3, 3]f32{t0.x, b0.x, n0.x, t0.y, b0.y, n0.y, t0.z, b0.z, n0.z}
	to := matrix[3, 3]f32{t1.x, -b1.x, n1.x, t1.y, -b1.y, n1.y, t1.z, -b1.z, n1.z}
	return {turn = to * linalg.transpose(from), flipped = true, from = pos[v], to = pos[v_img]}, true
}

// The images of a dab at `center`, the dab itself first: with poseable symmetry and
// pairs that fit, the dab's partner across the mirror alone (none where it has none);
// otherwise the brush's planes and radial copies (symmetry_images).
dab_images :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> (images: [dynamic; SYM_IMAGES_MAX]Sym_Image) {
	if !brush.poseable || !sculptor_mirror_ready(s) do return symmetry_images(brush)
	append(&images, Sym_Image{turn = 1})
	if img, ok := mirror_image(s, center, brush.radius); ok do append(&images, img)
	return
}
