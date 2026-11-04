package quadmesh

import "base:runtime"
import "core:math"
import "core:slice"

import "../geom"
import "../jobs"

// The first stage in Odin (Core.Odin), as qm_stage_thin does it in C++: the feature
// chains too short to follow dropped, then an island far denser than its share of the
// target thinned by geom.mesh_decimate. That decimation refuses the collapses that would
// pinch the surface, so the C++'s split of pinched vertices after meshoptimizer goes; a
// pinch the input itself has is split by the isotropic remesh (mesh.odin). Everything is
// allocated with runtime.heap_allocator(), as the stages' outputs are.

// An island at more than THIN_TRIGGER times its share of the target triangle count is
// decimated to THIN_TARGET times it first (the core's own ratios, decimateIfTooDense).
@(private = "file")
THIN_TRIGGER :: 8.0
@(private = "file")
THIN_TARGET :: 4.0

// The decimation's parallel rounds go on down to this many times the goal (the app's
// Decimate stops them at geom.DECIMATE_SLACK): the isotropic remesh that follows evens
// out what the whole-mesh round would have chosen more finely, and a million triangles
// thin in about a third of the time.
@(private = "file")
THIN_SLACK :: 1

// How much dearer moving a vertex on an edge sharper than the stage's angle is, as
// meshoptimizer's priority flag makes it: the quadrics already hold a crease, and this
// keeps its vertices to the last.
@(private = "file")
THIN_SHARP_WEIGHT :: 10

// The thinned island and whether it was decimated. `pool` (nil for none) runs the
// decimation's rounds in parallel.
odin_thin :: proc(island: Island, voxel_size, quad_edge, sharp_degrees: f64, pool: ^jobs.Pool) -> (out: Island, decimated: bool, err: Stage_Error) {
	heap := runtime.heap_allocator()
	features := drop_short_feature_chains(island.positions, island.features, quad_edge)
	out.features = features
	out.positions = slice.clone(island.positions, heap)
	out.triangles = slice.clone(island.triangles, heap)
	if len(island.density) == len(island.positions) do out.density = slice.clone(island.density, heap)
	if len(island.refine) == len(island.positions) do out.refine = slice.clone(island.refine, heap)
	if len(out.positions) == 0 || len(out.triangles) == 0 || !(voxel_size > 0) do return out, false, .None

	// Where the density asks for smaller quads, or the refinement for finer triangles, the
	// isotropic remesh wants smaller triangles, so the count kept follows the weighted area.
	wanted := thin_weighted_area(out) / (voxel_size * voxel_size * EQUILATERAL_AREA)
	if !(wanted >= 1.0) || f64(len(out.triangles)) < wanted * THIN_TRIGGER do return out, false, .None
	goal := int(wanted * THIN_TARGET)

	source := geom.Mesh {
		positions = make([dynamic]geom.Vec3, len(out.positions), heap),
		indices   = make([dynamic]u32, 3 * len(out.triangles), heap),
	}
	defer delete(source.positions)
	defer delete(source.indices)
	for p, v in out.positions do source.positions[v] = {f32(p.x), f32(p.y), f32(p.z)}
	for t, f in out.triangles do for k in 0 ..< 3 do source.indices[3 * f + k] = t[k]

	// The feature edges' vertices stay where they are, so the edges survive between them;
	// the vertices of an edge sharper than the stage's angle go last.
	weight := make([]f32, len(out.positions), heap)
	defer delete(weight, heap)
	for &w in weight do w = 1
	if sharp_degrees > 0 {
		creases := sharp_edges(out.positions, out.triangles, sharp_degrees * math.PI / 180)
		defer delete(creases, heap)
		for e in creases do weight[e[0]], weight[e[1]] = THIN_SHARP_WEIGHT, THIN_SHARP_WEIGHT
	}
	for e in features do weight[e[0]], weight[e[1]] = math.INF_F32, math.INF_F32

	from := make([dynamic]u32, heap)
	defer delete(from)
	thinned, _, ok := geom.mesh_decimate(source, goal, pool, heap, from = &from, guide = {weight = weight}, slack = THIN_SLACK)
	if !ok do return out, false, .None
	defer geom.mesh_destroy(&thinned)
	if len(thinned.indices) < 3 || len(thinned.indices) >= len(source.indices) do return out, false, .None

	// The kept vertices are the island's own (`from`), so their f64 positions and values
	// come across as they were, and each feature edge whose two ends are kept and still
	// joined by an edge is renumbered; one the decimation took out is dropped.
	positions := make([][3]f64, len(from), heap)
	for v, i in from do positions[i] = out.positions[v]
	triangles := make([][3]u32, len(thinned.indices) / 3, heap)
	for &t, f in triangles do t = {thinned.indices[3 * f], thinned.indices[3 * f + 1], thinned.indices[3 * f + 2]}
	renumber := make([]u32, len(out.positions), heap)
	defer delete(renumber, heap)
	for &r in renumber do r = NONE
	for v, i in from do renumber[v] = u32(i)
	if len(features) > 0 {
		kept := make([]u64, 3 * len(triangles), heap)
		defer delete(kept, heap)
		for t, f in triangles do for k in 0 ..< 3 do kept[3 * f + k] = edge_key(t[k], t[(k + 1) % 3])
		slice.sort(kept)
		n := 0
		for e in features {
			a, b := renumber[e[0]], renumber[e[1]]
			if a == NONE || b == NONE || a == b do continue
			if _, found := slice.binary_search(kept, edge_key(a, b)); !found do continue
			features[n] = {a, b}
			n += 1
		}
		out.features = features[:n]
	}
	carry :: proc(values: []f64, from: []u32, heap: runtime.Allocator) -> []f64 {
		if values == nil do return nil
		out := make([]f64, len(from), heap)
		for v, i in from do out[i] = values[v]
		return out
	}
	density, refine := carry(out.density, from[:], heap), carry(out.refine, from[:], heap)
	delete(out.positions, heap)
	delete(out.triangles, heap)
	delete(out.density, heap)
	delete(out.refine, heap)
	out.positions, out.triangles, out.density, out.refine = positions, triangles, density, refine
	return out, true, .None
}

// The island's area, each triangle weighted by its corners' density over the square of
// their refinement (the triangles the isotropic remesh will make there).
@(private = "file")
thin_weighted_area :: proc(m: Island) -> f64 {
	dense, refined := len(m.density) == len(m.positions), len(m.refine) == len(m.positions)
	weight :: #force_inline proc(m: Island, dense, refined: bool, v: u32) -> f64 {
		d := m.density[v] if dense else 1
		r := m.refine[v] if refined else 1
		return d / (r * r)
	}
	area := f64(0)
	for t in m.triangles {
		a := triangle_area(m.positions[t[0]], m.positions[t[1]], m.positions[t[2]])
		if dense || refined do a *= (weight(m, dense, refined, t[0]) + weight(m, dense, refined, t[1]) + weight(m, dense, refined, t[2])) / 3
		area += a
	}
	return area
}

// The edges of exactly two triangles that meet at `radians` or more (the creases), each
// once, by their lower vertex and then the triangle that has them first. The sides are
// filed under their lower vertex by a count, so the pairs are found in time linear in
// the triangles. From the heap.
@(private)
sharp_edges :: proc(positions: [][3]f64, triangles: [][3]u32, radians: f64) -> [][2]u32 {
	heap := runtime.heap_allocator()
	out := make([dynamic][2]u32, heap)
	n := u32(len(positions))
	first := make([]u32, n + 1, heap)
	defer delete(first, heap)
	for t in triangles {
		if t[0] >= n || t[1] >= n || t[2] >= n do continue
		for k in 0 ..< 3 do first[min(t[k], t[(k + 1) % 3]) + 1] += 1
	}
	for v in 0 ..< n do first[v + 1] += first[v]
	Side :: struct {
		other: u32,
		face:  u32,
	}
	sides := make([]Side, first[n], heap)
	defer delete(sides, heap)
	at := make([]u32, n, heap)
	defer delete(at, heap)
	copy(at, first[:n])
	for t, f in triangles {
		if t[0] >= n || t[1] >= n || t[2] >= n do continue
		for k in 0 ..< 3 {
			a, b := t[k], t[(k + 1) % 3]
			lo := min(a, b)
			sides[at[lo]] = {max(a, b), u32(f)}
			at[lo] += 1
		}
	}
	normal :: proc(positions: [][3]f64, t: [3]u32) -> [3]f64 {
		return cross3(positions[t[1]] - positions[t[0]], positions[t[2]] - positions[t[0]])
	}
	limit := math.cos(radians)
	for v in 0 ..< n {
		here := sides[first[v]:first[v + 1]]
		for s, i in here {
			// The edge's sides in this vertex's list: the pair is the edge's first two, and
			// an edge of one triangle or of three or more is no crease.
			count, other := 0, u32(0)
			seen := false
			for r, j in here {
				if r.other != s.other do continue
				if j < i do seen = true
				if count == 1 do other = r.face
				count += 1
			}
			if seen || count != 2 do continue
			p, q := normal(positions, triangles[s.face]), normal(positions, triangles[other])
			lp, lq := math.sqrt(dot3(p, p)), math.sqrt(dot3(q, q))
			if !(lp > 0) || !(lq > 0) do continue
			if dot3(p, q) / (lp * lq) > limit do continue
			append(&out, [2]u32{v, s.other})
		}
	}
	return out[:]
}

// The feature edges less the chains too short to follow (the core's
// dropShortFeatureChains): a chain (edges joined end to end through vertices of two
// feature edges, apart from the rest at junctions and loose ends) shorter than two quad
// edges would give the quads nothing to run along, only a kink; a tiny group's border is
// such a chain. A new slice, from the heap.
@(private = "file")
drop_short_feature_chains :: proc(positions: [][3]f64, features: [][2]u32, quad_edge: f64) -> [][2]u32 {
	heap := runtime.heap_allocator()
	out := make([dynamic][2]u32, 0, len(features), heap)
	if len(features) == 0 do return out[:]
	degree := make([]u32, len(positions), heap)
	defer delete(degree, heap)
	for e in features do degree[e[0]], degree[e[1]] = degree[e[0]] + 1, degree[e[1]] + 1
	parent := make([]u32, len(features), heap)
	defer delete(parent, heap)
	for &p, e in parent do p = u32(e)
	find :: proc(parent: []u32, e: u32) -> u32 {
		e := e
		for parent[e] != e {
			parent[e] = parent[parent[e]]
			e = parent[e]
		}
		return e
	}
	through := make([]u32, len(positions), heap)
	defer delete(through, heap)
	for &t in through do t = NONE
	for e, i in features {
		for v in e {
			if degree[v] != 2 do continue
			if through[v] == NONE {
				through[v] = u32(i)
			} else {
				parent[find(parent, through[v])] = find(parent, u32(i))
			}
		}
	}
	length := make([]f64, len(features), heap)
	defer delete(length, heap)
	for e, i in features {
		d := positions[e[0]] - positions[e[1]]
		length[find(parent, u32(i))] += math.sqrt(dot3(d, d))
	}
	for e, i in features do if length[find(parent, u32(i))] >= 2 * quad_edge do append(&out, e)
	return out[:]
}
