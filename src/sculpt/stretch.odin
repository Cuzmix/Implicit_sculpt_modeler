package sculpt

// Stretch repair under dynamic topology: splitting what a pull stretched down to the detail
// size and evening the new vertices out along the surface. Grab and Elastic do it at the
// release (sculptor_grab_refine), Snake hook and Cloth at the stroke's end
// (sculptor_stretch_repair), and Remove stretching over the whole object
// (sculptor_remove_stretching).

import "core:math/linalg"
import "core:slice"

import "../geom"

// How many capped rounds of splits a refinement may take (each at most DYN_MAX_SPLITS):
// after a pull, and over a whole object.
GRAB_REFINE_ROUNDS :: 32
REMOVE_STRETCH_ROUNDS :: 512
// Remove stretching splits the edges longer than this many times the object's median edge.
STRETCH_RATIO :: 2.0
// How many edges Remove stretching measures for the median at most, spread evenly.
STRETCH_SAMPLES :: 65536

// Where a stroke stretched the surface, and the detail size it had there; detail 0 is none.
@(private)
Stretch :: struct {
	bounds: geom.Aabb,
	detail: f32,
}

// Notes that a dab at `center` reaching `reach` may have stretched the surface out to
// `drag` past it, at detail size `detail`; the smallest detail of the stroke's is kept.
@(private)
stretch_note :: proc(s: ^Sculptor, center: Vec3, reach: f32, drag: Vec3, detail: f32) {
	if s.dyn == nil || detail <= 0 do return
	st := &s.stretch
	if st.detail <= 0 {
		st.bounds, st.detail = geom.AABB_EMPTY, detail
	}
	st.detail = min(st.detail, detail)
	for at in ([2]Vec3{center, center + drag}) {
		geom.aabb_grow(&st.bounds, at - reach)
		geom.aabb_grow(&st.bounds, at + reach)
	}
}

// Under dynamic topology, at the end of a Snake hook or Cloth stroke: splits the edges
// where it pulled that are longer than its detail size and evens the new vertices out, as
// sculptor_grab_refine does after a grab. A hook splits as it goes, but each dab splits
// before it moves, so its last pulls leave long edges behind; Cloth splits nothing while it
// simulates. Call inside the stroke, before sculptor_cloth_end, so one undo takes it back
// with the stroke. Returns how many edges split.
sculptor_stretch_repair :: proc(s: ^Sculptor) -> int {
	st := &s.stretch
	defer st^ = {}
	if s.dyn == nil || st.detail <= 0 do return 0
	// Cloth's vertices may have been carried past the sphere it began in.
	for v in s.cloth.verts do geom.aabb_grow(&st.bounds, s.mesh.positions[v])
	return refine_region(s, st.bounds, st.detail, GRAB_REFINE_ROUNDS)
}

// Under dynamic topology: splits every edge of the object longer than STRETCH_RATIO times
// its median edge, longest first, and evens the new vertices out, so the slivers a pull
// left behind become triangles of the size around them. Masked parts keep theirs. Call
// inside a stroke for one undo step. Returns how many edges split and the length it split
// down to.
sculptor_remove_stretching :: proc(s: ^Sculptor) -> (splits: int, detail: f32) {
	if s.dyn == nil do return
	m := s.mesh
	triangles := 0
	for n in s.nodes do triangles += int(n.tri_count)
	if triangles == 0 do return
	// The median of an even spread of edges, one of each sampled triangle's in turn,
	// taken in node order so the same mesh measures the same.
	stride := max(1, triangles / STRETCH_SAMPLES)
	lengths := make([dynamic]f32, 0, min(triangles, STRETCH_SAMPLES + 1), context.temp_allocator)
	bounds := geom.AABB_EMPTY
	k := 0
	for n in s.nodes {
		for v in n.vert_first ..< n.vert_first + n.vert_count do geom.aabb_grow(&bounds, m.positions[v])
		for f in n.tri_first ..< n.tri_first + n.tri_count {
			defer k += 1
			if k % stride != 0 do continue
			e := u32(k / stride % 3)
			a, b := m.indices[3 * f + e], m.indices[3 * f + (e + 1) % 3]
			append(&lengths, linalg.length(m.positions[a] - m.positions[b]))
		}
	}
	slice.sort(lengths[:])
	detail = lengths[len(lengths) / 2] * STRETCH_RATIO
	if detail <= 0 do return
	splits = refine_region(s, bounds, detail, REMOVE_STRETCH_ROUNDS)
	return
}

// Splits the edges within the sphere round `bounds` longer than `detail`, evens the new
// vertices out along the surface, then splits again what evening them stretched. Never
// collapses: that would remove vertices the fresh list holds, and a pull only stretches.
@(private)
refine_region :: proc(s: ^Sculptor, bounds: geom.Aabb, detail: f32, rounds: int) -> int {
	d := s.dyn
	center := (bounds.lo + bounds.hi) * 0.5
	radius := max(linalg.length(bounds.hi - bounds.lo) * 0.5, detail)
	fresh := Dyn_Fresh {
		verts = make([dynamic]u32, context.temp_allocator),
		at    = make(map[u32]int, allocator = context.temp_allocator),
	}
	d.fresh = &fresh
	splits_before := d.splits
	dab := Dab {
		s      = s,
		brush  = {radius = radius, detail = detail / radius},
		center = center,
		r2     = radius * radius,
		inv_r2 = 1 / (radius * radius),
	}
	refine_rounds(s, &dab, rounds)
	// Evening out the new vertices can stretch an edge past the detail again, which a
	// second pass splits (those new vertices stay where the split put them).
	d.fresh = nil
	relax_fresh(s, fresh.verts[:])
	refine_rounds(s, &dab, rounds)
	return d.splits - splits_before
}

// Splits in capped rounds until a round changes nothing, finding the leaves again each
// round since splits can split nodes.
@(private = "file")
refine_rounds :: proc(s: ^Sculptor, dab: ^Dab, rounds: int) {
	for _ in 0 ..< rounds {
		clear(&s.hit)
		geom.bvh_query_leaves(&s.bvh, dab.center, dab.brush.radius, &s.hit)
		if len(s.hit) == 0 do return
		count: u32
		for leaf in s.hit do count += s.nodes[s.node_of[leaf]].vert_count
		if !dyn_dab_topology(s, dab, s.pool if count >= PARALLEL_MIN_VERTS else nil) do return
	}
}

// Two Jacobi steps moving each of `verts` toward the middle of its neighbours, across
// the surface only (the normal part taken out), which spaces the new vertices evenly
// along a stretch without flattening its shape.
@(private = "file")
relax_fresh :: proc(s: ^Sculptor, verts: []u32) {
	if len(verts) == 0 do return
	d := s.dyn
	m := s.mesh
	to := make([]Vec3, len(verts), context.temp_allocator)
	for v in verts do touch(s, vert_page(v))
	for _ in 0 ..< 2 {
		for v, i in verts {
			p := m.positions[v]
			sum: Vec3
			n: f32
			for f in dyn_faces(d, v) {
				for k in u32(0) ..< 3 {
					w := m.indices[3 * f + k]
					if w == v do continue
					sum += m.positions[w]
					n += 1
				}
			}
			to[i] = p
			if n == 0 do continue
			move := sum / n - p
			normal := linalg.normalize0(m.normals[v])
			to[i] = p + move - normal * linalg.dot(move, normal)
		}
		for v, i in verts do m.positions[v] = to[i]
	}
	for v in verts {
		mark(s, vert_page(v), {.Shape})
		for f in dyn_faces(d, v) do mark(s, tri_page(f), {.Shape})
	}
	after_edits(s)
}
