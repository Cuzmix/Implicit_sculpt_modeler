package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"

// The topological mask, as ZBrush's Gizmo 3D topology masking and 3DCoat's Pose tool:
// from a point on the surface the mask grows along the surface, not through space, as
// far as a reach the pointer sets. Near the point stays free, a soft band follows (from
// TOPO_SOFT of the reach to all of it) and everything further is masked; inverted, the
// other way round. Distances are along the triangles' edges, found by Dijkstra's search
// from the corners of the triangle pressed, so a finger the other side of a thin gap stays
// masked however near it is in space. The search runs a budget of vertices a frame and
// carries on as the reach grows; the vertices it settled are kept nearest first, so a new
// reach rewrites only the ones whose value can change. The whole gesture is one stroke,
// one mask undo step. Hidden vertices keep their mask, though the search crosses them.
// Changing the reach rewrites the vertices from the soft band of the smaller reach on,
// so its cost follows the band's width rather than the budget.

// The part of the reach that stays free before the soft band starts.
TOPO_SOFT :: f32(0.75)

@(private)
Topo_State :: struct {
	active:  bool,
	invert:  bool,
	dist:    []f32, // per vertex: the shortest way found so far, max(f32) for none
	slot:    []i32, // per vertex: its place in heap, TOPO_NEW before it is found, TOPO_SETTLED after
	heap:    [dynamic]u32, // the vertices found and not settled, a binary heap nearest first
	order:   [dynamic]u32, // the vertices settled, nearest first
	node:    []u32, // per vertex: the node owning it, max(u32) for a free slot
	written: f32, // the reach the mask was last written for
}

@(private = "file")
TOPO_NEW :: i32(-1)
@(private = "file")
TOPO_SETTLED :: i32(-2)

@(private)
topo_free :: proc(s: ^Sculptor) {
	t := &s.topo
	delete(t.dist)
	delete(t.slot)
	delete(t.heap)
	delete(t.order)
	delete(t.node)
	t^ = {}
}

// Whether a topological mask is under way.
sculptor_topo_masking :: proc(s: ^Sculptor) -> bool {return s.topo.active}

// Starts a topological mask where the ray (in the mesh's own space) meets the shown
// surface, masking everything shown (with `invert`, freeing it) until a reach is set.
// False, starting nothing, when the ray misses or a stroke is being recorded.
sculptor_topo_mask_begin :: proc(s: ^Sculptor, origin, dir: Vec3, invert: bool) -> bool {
	if s.history.recording do return false
	t_hit, tri, ok := geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir, sculptor_hidden_tris(s))
	if !ok do return false
	hit := origin + dir * t_hit
	topo_free(s)
	mask_ensure(s)
	n := len(s.mesh.positions)
	t := &s.topo
	t.active, t.invert = true, invert
	t.dist = make([]f32, n)
	slice.fill(t.dist, max(f32))
	t.slot = make([]i32, n)
	slice.fill(t.slot, TOPO_NEW)
	t.node = make([]u32, n)
	slice.fill(t.node, max(u32))
	for nd, id in s.nodes do slice.fill(t.node[nd.vert_first:][:nd.vert_count], u32(id))
	sculptor_stroke_begin(s)
	// Everything shown starts as far away, a node at a time.
	far := topo_value(max(f32), 1, invert)
	for nd, id in s.nodes {
		values := s.mask[nd.vert_first:][:nd.vert_count]
		changes := false
		for k, i in values do changes ||= k != far && !topo_frozen(s, nd.vert_first + u32(i))
		if !changes do continue
		record_mask(s, u32(id))
		record_painted(s, u32(id))
		mark_stale(s, u32(id), .Paint)
		if s.fade == nil do slice.fill(values, far)
		else do for &k, i in values do if !topo_frozen(s, nd.vert_first + u32(i)) do k = far
	}
	idx := s.mesh.indices
	for c in 0 ..< u32(3) {
		v := idx[3 * tri + c]
		topo_found(t, v, linalg.length(s.mesh.positions[v] - hit))
	}
	return true
}

// Grows (or shrinks) the mask to `reach_wanted` along the surface, settling at most `budget`
// more vertices. Returns true when every vertex within the reach is settled, so the mask
// is what that reach makes; false while the search has more to do, when the caller asks
// again next frame.
sculptor_topo_mask_reach :: proc(s: ^Sculptor, reach_wanted: f32, budget: int) -> (settled: bool) {
	t := &s.topo
	if !t.active do return true
	reach := max(reach_wanted, 0)
	m := s.mesh
	done := 0
	settled_before := len(t.order)
	for len(t.heap) > 0 && done < budget {
		v := t.heap[0]
		if t.dist[v] > reach do break
		topo_pop(t)
		t.slot[v] = TOPO_SETTLED
		append(&t.order, v)
		done += 1
		for f in faces_of(s, v) {
			for c in 0 ..< u32(3) {
				u := m.indices[3 * f + c]
				if u == v || t.slot[u] == TOPO_SETTLED do continue
				topo_found(t, u, t.dist[v] + linalg.length(m.positions[u] - m.positions[v]))
			}
		}
	}
	settled = len(t.heap) == 0 || t.dist[t.heap[0]] > reach
	// Below the soft band of the smaller of the two reaches a vertex written before was
	// free and stays free: only those from there on can change, and the ones settled
	// now, still written as far away.
	from := TOPO_SOFT * min(t.written, reach)
	// With the reach as it was, only the ones settled now: a still pointer, or the search
	// finishing after the release, costs no more than the budget.
	first := settled_before if reach == t.written else min(topo_lower(t, from), settled_before)
	for v in t.order[first:] {
		if topo_frozen(s, v) || t.node[v] == max(u32) do continue
		k := topo_value(t.dist[v], reach, t.invert)
		if s.mask[v] != k do topo_write(s, v, t.node[v], k)
	}
	t.written = reach
	return
}

// Ends the topological mask. True when it changed the mask and became an undo step.
sculptor_topo_mask_end :: proc(s: ^Sculptor) -> bool {
	if !s.topo.active do return false
	topo_free(s)
	return sculptor_stroke_end(s)
}

// Puts the mask back as it was before the topological mask began, with no undo step.
sculptor_topo_mask_cancel :: proc(s: ^Sculptor) {
	if !s.topo.active do return
	topo_free(s)
	// It saves masks only, so it always discards.
	ok := sculptor_stroke_discard(s)
	assert(ok)
}

// The mask a vertex `d` along the surface takes for `reach`: free within TOPO_SOFT of
// it, masked beyond it, a smooth step between; the other way round with `invert`.
@(private = "file")
topo_value :: proc(d, reach: f32, invert: bool) -> u8 {
	k: u8 = 255
	if reach > 0 {
		x := clamp((d / reach - TOPO_SOFT) / (1 - TOPO_SOFT), 0, 1)
		k = u8(math.round(255 * x * x * (3 - 2 * x)))
	}
	return 255 - k if invert else k
}

// Whether vertex v keeps its mask: hidden, or outside an HD window's editable part (its
// fade 0 without anything hidden), as masks brushed there are.
@(private = "file")
topo_frozen :: #force_inline proc(s: ^Sculptor, v: u32) -> bool {
	return s.fade != nil && s.fade[v] == 0
}

// Sets vertex v's mask, saving its node's mask first and listing it to upload.
@(private = "file")
topo_write :: proc(s: ^Sculptor, v, node: u32, k: u8) {
	record_mask(s, node)
	s.mask[v] = k
	record_painted(s, node)
	mark_stale(s, node, .Paint)
}

// The first settled vertex at least `d` along the surface; they are kept nearest first.
@(private = "file")
topo_lower :: proc(t: ^Topo_State, d: f32) -> int {
	lo, hi := 0, len(t.order)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.dist[t.order[mid]] < d do lo = mid + 1
		else do hi = mid
	}
	return lo
}

// Whether a comes before b in the heap: nearer, or as near and with the lower index, so
// the search settles in the same order every time.
@(private = "file")
topo_less :: #force_inline proc(t: ^Topo_State, a, b: u32) -> bool {
	return t.dist[a] < t.dist[b] || (t.dist[a] == t.dist[b] && a < b)
}

// Notes a way to v of length d, keeping it when it is shorter than any found before.
@(private = "file")
topo_found :: proc(t: ^Topo_State, v: u32, d: f32) {
	if t.slot[v] == TOPO_SETTLED || d >= t.dist[v] do return
	t.dist[v] = d
	if t.slot[v] == TOPO_NEW {
		append(&t.heap, v)
		t.slot[v] = i32(len(t.heap) - 1)
	}
	topo_up(t, int(t.slot[v]))
}

@(private = "file")
topo_up :: proc(t: ^Topo_State, at: int) {
	i := at
	v := t.heap[i]
	for i > 0 {
		parent := (i - 1) / 2
		p := t.heap[parent]
		if !topo_less(t, v, p) do break
		t.heap[i] = p
		t.slot[p] = i32(i)
		i = parent
	}
	t.heap[i] = v
	t.slot[v] = i32(i)
}

// Takes the nearest vertex off the heap.
@(private = "file")
topo_pop :: proc(t: ^Topo_State) {
	last := pop(&t.heap)
	if len(t.heap) == 0 do return
	i := 0
	n := len(t.heap)
	for {
		child := 2 * i + 1
		if child >= n do break
		if child + 1 < n && topo_less(t, t.heap[child + 1], t.heap[child]) do child += 1
		if !topo_less(t, t.heap[child], last) do break
		t.heap[i] = t.heap[child]
		t.slot[t.heap[i]] = i32(i)
		i = child
	}
	t.heap[i] = last
	t.slot[last] = i32(i)
}
