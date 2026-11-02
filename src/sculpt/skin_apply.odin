package sculpt

import "core:math/bits"
import "core:math/linalg"

import "../geom"
import "../jobs"

// Apply: the detail skin turned into subdivision levels. A skin of S segments is log2(S)
// Loop levels above the level it lies on, whose top level has a vertex at every sample, so
// each top vertex rises from its Loop point by its sample's height along the Loop
// surface's normal and the skin goes. The skin raises flat triangles, but shades them
// with the mesh's smooth normals, so it looks like heights on a smooth surface: raising
// the Loop surface keeps that look, where the flat points would show every facet of the
// level below. The levels between keep their Loop points, and the level the skin lay on
// does not move, so the skin's detail becomes the top level's detail alone, as if it had
// been sculpted there.

// Where a vertex of a level above the skinned one lies on the skinned level's flat
// triangles: as weights on up to three of its vertices, adding up to 2^steps on a level
// `steps` above it. Every vertex above lies inside one triangle of the skinned level (a
// Loop step cuts triangles, never across them), so three are always enough.
@(private = "file")
Skin_Place :: struct {
	verts:   [3]u32,
	weights: [3]u8, // 0 for an unused slot
}

// How many levels Apply adds for the top level's skin, 0 when it has none.
levels_skin_apply_steps :: proc(l: ^Levels) -> int {
	sk := levels_skin(l)
	if sk == nil do return 0
	return int(bits.trailing_zeros(sk.segments))
}

// What the levels Apply adds would hold in all, as levels_subdivide_estimate gives for
// one: vertices and triangles of the new top level, and the bytes of every new level.
levels_skin_apply_estimate :: proc(l: ^Levels) -> (vertices, triangles, bytes: int) {
	top := l.levels[len(l.levels) - 1]
	v, t := len(top.mesh.positions), len(top.mesh.indices) / 3
	for _ in 0 ..< levels_skin_apply_steps(l) {
		// A closed mesh has 3/2 edges per triangle.
		next_v, next_t := v + 3 * t / 2, 4 * t
		bytes += level_estimate_bytes(next_v, next_t, v)
		v, t = next_v, next_t
	}
	return v, t, bytes + 4 * sculptor_layers_bytes(&top.sculptor) * levels_skin_apply_steps(l)
}

// Whether Apply may run: a skin on the top level, which is current, with room for its
// levels, no HD level and no dynamic topology.
levels_skin_can_apply :: proc(l: ^Levels) -> bool {
	steps := levels_skin_apply_steps(l)
	return steps > 0 && l.current == len(l.levels) - 1 && len(l.levels) + steps <= MAX_LEVELS && levels_can_subdivide(l) && l.rule == .Loop
}

// Bakes the top level's skin into log2(segments) new Loop levels and takes the skin off,
// leaving the new top level current. The skin's level and those below do not move. With
// `carry_layers`, the top level's sculpt layers move up as levels_subdivide moves them.
// False when it cannot (levels_skin_can_apply, or a level that would not build), with any
// levels it added taken off again and the skin kept. Under a Catmull-Clark rule the levels
// above would not put a vertex at every sample, so it refuses those.
levels_skin_apply :: proc(l: ^Levels, carry_layers := false) -> bool {
	if !levels_skin_can_apply(l) do return false
	levels_sync(l)
	from := len(l.levels) - 1
	steps := levels_skin_apply_steps(l)
	skinned := &l.levels[from].sculptor
	sk := skinned.skin

	// The skinned level's own vertices first, then each level's from the one below.
	places := make([]Skin_Place, len(l.levels[from].mesh.positions), context.temp_allocator)
	for &p, v in places do p = {verts = {u32(v), 0, 0}, weights = {1, 0, 0}}
	for _ in 0 ..< steps {
		if !levels_subdivide(l, carry_layers) {
			for len(l.levels) - 1 > from do _ = levels_delete_top(l)
			return false
		}
		lv := l.levels[len(l.levels) - 1]
		Up :: struct {
			below, above: []Skin_Place,
			parents:      [][4]u32,
			bad:          bool,
		}
		u := Up{below = places, above = make([]Skin_Place, len(lv.mesh.positions), context.temp_allocator), parents = lv.parents}
		jobs.parallel_ranges(l.pool, len(u.above), &u, proc(data: rawptr, lo, hi: int) {
			u := cast(^Up)data
			for i in lo ..< hi {
				par := u.parents[i]
				a := u.below[par[0]]
				if par[2] == EVEN {
					for &w in a.weights do w *= 2
					u.above[i] = a
					continue
				}
				// The middle of an edge: both ends' weights, in one triangle's corners.
				for w, k in u.below[par[1]].weights {
					if w == 0 do continue
					v := u.below[par[1]].verts[k]
					placed := false
					for slot in 0 ..< 3 {
						if a.weights[slot] != 0 && a.verts[slot] == v {
							a.weights[slot] += w
							placed = true
							break
						}
					}
					for slot in 0 ..< 3 {
						if placed do break
						if a.weights[slot] == 0 {
							a.verts[slot], a.weights[slot] = v, w
							placed = true
						}
					}
					// Only ever set to true, by any job.
					if !placed do u.bad = true
				}
				u.above[i] = a
			}
		}, geom.RANGE_GRAIN)
		if u.bad {
			for len(l.levels) - 1 > from do _ = levels_delete_top(l)
			return false
		}
		places = u.above
	}

	// Each top vertex rises by its sample's height along its normal, which the new level
	// worked out over its Loop points.
	top := l.levels[len(l.levels) - 1]
	Bake :: struct {
		s:       ^Sculptor,
		sk:      ^Skin,
		places:  []Skin_Place,
		out:     []Vec3,
		normals: []Vec3,
		bad:     bool,
	}
	b := Bake{s = skinned, sk = sk, places = places, out = top.mesh.positions[:], normals = top.mesh.normals[:]}
	jobs.parallel_ranges(l.pool, len(places), &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Bake)data
		for i in lo ..< hi {
			t, ci, cj, ok := skin_place_sample(b.s, b.places[i])
			if !ok {
				b.bad = true
				continue
			}
			h := f32(b.sk.heights[skin_sample(b.sk, b.s.mesh.indices[:], t, ci, cj)])
			b.out[i] += linalg.normalize0(b.normals[i]) * h
		}
	}, geom.RANGE_GRAIN)
	if b.bad {
		for len(l.levels) - 1 > from do _ = levels_delete_top(l)
		return false
	}
	all := make([]u32, len(top.sculptor.nodes), context.temp_allocator)
	for &id, i in all do id = u32(i)
	recode_level(l, len(l.levels) - 1, all, encode = true)
	sculptor_nodes_moved(&top.sculptor, all)
	sculptor_recompute_all(&top.sculptor)
	history_seal(&top.sculptor.history)
	sculptor_skin_remove(skinned)
	return true
}

// The triangle of the skinned sculptor and the grid place in it of a place: a triangle at
// whose corners its weights lie, with i and j the weights of its second and third corners.
@(private = "file")
skin_place_sample :: proc(s: ^Sculptor, p: Skin_Place) -> (t, i, j: u32, ok: bool) {
	I := s.mesh.indices[:]
	search: for f in faces_of(s, p.verts[0]) {
		for k in 0 ..< 3 {
			if p.weights[k] == 0 do continue
			if I[3 * f] != p.verts[k] && I[3 * f + 1] != p.verts[k] && I[3 * f + 2] != p.verts[k] do continue search
		}
		i, j = 0, 0
		for k in 0 ..< 3 {
			if p.weights[k] == 0 do continue
			switch p.verts[k] {
			case I[3 * f + 1]: i = u32(p.weights[k])
			case I[3 * f + 2]: j = u32(p.weights[k])
			}
		}
		return f, i, j, true
	}
	return 0, 0, 0, false
}

// Takes the top level off, as when Apply cannot finish; the level below becomes top and
// current again. False when there is only the base.
@(private = "file")
levels_delete_top :: proc(l: ^Levels) -> bool {
	if len(l.levels) <= 1 do return false
	l.current = len(l.levels) - 2
	_, _ = levels_delete_higher(l)
	return true
}
