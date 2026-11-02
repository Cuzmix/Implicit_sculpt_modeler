package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// The brush kinds that can write into a detail skin (Brush.skin): those that move the
// surface along its normal, which is all a height can hold. The rest move vertices.
SKIN_KINDS :: bit_set[Brush_Kind]{.Draw, .Inflate, .Clay, .Flatten, .Crease, .Layer, .Smooth}

// How far a skin sample may move toward a plane in one dab, at most, for a surface that
// meets the plane's normal at a steep angle: the move along the sample's normal that
// reaches the plane grows as one over the cosine between them, so it is capped where
// that cosine falls under this.
@(private)
SKIN_PLANE_COS_MIN :: 0.25

// Gives the sculptor a detail skin of `segments` (a power of two, 2 to 16) with flat
// heights, replacing any it had, outside the undo history (a start-up's, a file's).
// Refuses (false, nothing changed) under dynamic topology, on an open or non-manifold
// mesh, or for other segments.
sculptor_skin_set :: proc(s: ^Sculptor, segments: u32) -> bool {
	if s.dyn != nil do return false
	sk, ok := skin_make(s, segments, s.history.allocator)
	if !ok do return false
	sculptor_skin_remove(s)
	s.skin = new_clone(sk, s.history.allocator)
	s.skin_stamp += 1
	return true
}

// Drops the sculptor's detail skin, if it has one, outside the undo history.
sculptor_skin_remove :: proc(s: ^Sculptor) {
	if s.skin == nil do return
	skin_free(s.skin, s.history.allocator)
	s.skin = nil
	s.skin_stamp += 1
}

// A skin replaced by an undo step (Undo_Step.skin_op): the one that is not live, nil for
// none, which undo and redo trade with the live one.
@(private)
Skin_Op :: struct {
	active: bool,
	skin:   ^Skin,
}

// Gives the sculptor a detail skin of `segments` (2, 4, 8 or 16) with flat heights, or
// with 0 takes its skin off, as an undo step of its own. Ends any stroke first. False,
// with nothing changed, under dynamic topology, on an open or non-manifold mesh, for
// other segments, or when the skin already has those segments.
sculptor_skin_change :: proc(s: ^Sculptor, segments: u32) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil do return false
	have := s.skin.segments if s.skin != nil else 0
	if segments == have do return false
	next: ^Skin
	if segments != 0 {
		sk, ok := skin_make(s, segments, s.history.allocator)
		if !ok do return false
		next = new_clone(sk, s.history.allocator)
	}
	sculptor_stroke_begin(s)
	s.history.current.skin_op = {active = true, skin = s.skin}
	s.skin = next
	s.skin_stamp += 1
	return sculptor_stroke_end(s)
}

// What sculptor_skin_stamp gives moves whenever the skin is added, replaced or taken off,
// by a command or by undo: a copy elsewhere (the GPU's) is then stale as a whole.
sculptor_skin_stamp :: proc(s: ^Sculptor) -> u32 {return s.skin_stamp}

// Undo or redo of a step that replaced the skin: the live skin and the step's trade
// places. The skin coming back was current with the surface when it left, which may have
// moved since, so all of its normals are worked out again at the next flush.
@(private)
skin_step_swap :: proc(s: ^Sculptor, step: ^Undo_Step) {
	op := &step.skin_op
	if !op.active do return
	s.skin, op.skin = op.skin, s.skin
	s.skin_stamp += 1
	if s.skin == nil do return
	skin_spheres_all(s, s.skin)
	for id in 0 ..< u32(len(s.nodes)) do skin_mark(s, id)
}

// The bytes a skin holds.
@(private)
skin_bytes :: proc(sk: ^Skin) -> int {
	if sk == nil do return 0
	bytes := size_of(Skin) + len(sk.heights) * size_of(f16) + len(sk.normals) * size_of([2]i16) + len(sk.layer) * size_of(Layer_Height)
	bytes += (len(sk.edge_first) + len(sk.near_first) + len(sk.near)) * size_of(u32) + len(sk.tri_edges) * size_of([3]u32)
	bytes += len(sk.redo_vert) + len(sk.redo_edge) + len(sk.redo_tri) + len(sk.dab_moved) + len(sk.node_edge) * size_of(f32)
	return bytes + len(sk.edges) * size_of(Skin_Edge) + len(sk.stale) * size_of(Skin_Stale)
}

// Destroys a skin made on the heap and frees it.
@(private)
skin_free :: proc(sk: ^Skin, allocator: runtime.Allocator) {
	if sk == nil do return
	skin_destroy(sk, allocator)
	free(sk, allocator)
}

// The sculptor's detail skin, nil for none.
sculptor_skin :: proc(s: ^Sculptor) -> ^Skin {return s.skin}

// The CPU bytes the sculptor's detail skin holds, 0 for none.
sculptor_skin_bytes :: proc(s: ^Sculptor) -> int {return skin_bytes(s.skin)}

// The sample ranges whose normals the last sculptor_flush recomputed, coalesced and
// sorted (none without a skin). Valid until the next flush.
sculptor_skin_ranges :: proc(s: ^Sculptor) -> []Skin_Range {
	if s.skin == nil do return nil
	return s.skin.ranges[:]
}

// Per triangle, the record the renderer draws the skin by (render.mesh_buffers_set_skin):
// its three edge references (Skin.tri_edges) and in the fourth number the corner it is
// drawn from (its polygroup lead corner, 0 without groups), in `allocator`.
sculptor_skin_tris :: proc(s: ^Sculptor, allocator := context.allocator) -> [][4]u32 {
	sk := s.skin
	if sk == nil do return nil
	out := make([][4]u32, len(sk.tri_edges), allocator)
	grouped := s.groups.tris != nil && len(s.groups.lead) == len(out)
	for e, t in sk.tri_edges {
		lead := u32(s.groups.lead[t]) if grouped else 0
		out[t] = {e[0], e[1], e[2], lead}
	}
	return out
}

// The samples node `id` alone writes: its vertices' samples, its edges' samples (the edges
// its triangles number) and its triangles' inside samples, as three ranges in that order.
skin_node_ranges :: proc(s: ^Sculptor, sk: ^Skin, id: u32) -> [3]Skin_Range {
	n := s.nodes[id]
	S := sk.segments
	e0 := sk.edge_first[n.tri_first]
	e1 := sk.edge_first[n.tri_first + n.tri_count]
	F := skin_face_samples(sk)
	return {
		{n.vert_first, n.vert_count},
		{sk.vert_count + e0 * (S - 1), (e1 - e0) * (S - 1)},
		{sk.vert_count + sk.edge_count * (S - 1) + n.tri_first * F, n.tri_count * F},
	}
}

// How many samples node `id` writes.
@(private)
skin_node_count :: proc(s: ^Sculptor, sk: ^Skin, id: u32) -> int {
	r := skin_node_ranges(s, sk, id)
	return int(r[0].count + r[1].count + r[2].count)
}

// Lists, per node, the nodes whose triangles share a vertex with its own, itself first and
// the rest in ascending order.
@(private)
skin_near_build :: proc(s: ^Sculptor, sk: ^Skin, allocator: runtime.Allocator) {
	Build :: struct {
		s:     ^Sculptor,
		lists: [][dynamic]u32,
	}
	b := Build{s, make([][dynamic]u32, len(s.nodes), context.temp_allocator)}
	jobs.parallel_for(s.pool, len(s.nodes), &b, proc(data: rawptr, i: int) {
		b := cast(^Build)data
		s := b.s
		I := s.mesh.indices[:]
		n := s.nodes[i]
		list := make([dynamic]u32, 0, 16, runtime.heap_allocator())
		for t in n.tri_first ..< n.tri_first + n.tri_count {
			for c in u32(0) ..< 3 {
				for f in faces_of(s, I[3 * t + c]) {
					other := tri_node(s, f)
					if other != u32(i) && !slice.contains(list[:], other) do append(&list, other)
				}
			}
		}
		slice.sort(list[:])
		inject_at(&list, 0, u32(i))
		b.lists[i] = list
	})
	sk.near_first = make([]u32, len(s.nodes) + 1, allocator)
	total := 0
	for l, i in b.lists {
		sk.near_first[i] = u32(total)
		total += len(l)
	}
	sk.near_first[len(s.nodes)] = u32(total)
	sk.near = make([]u32, total, allocator)
	for &l, i in b.lists {
		copy(sk.near[sk.near_first[i]:], l[:])
		delete(l)
	}
}

// Notes that node `id`'s heights changed anywhere: all its normals and its neighbours'
// wait for the next sculptor_flush, which also takes its box into the redraw.
@(private)
skin_mark :: proc(s: ^Sculptor, id: u32) {
	skin_mark_as(s, id, .Whole)
}

// Notes that node `id`'s heights changed inside the dab boxes only (Skin.boxes): the
// next flush recomputes only the normals near them.
@(private)
skin_mark_dab :: proc(s: ^Sculptor, id: u32) {
	skin_mark_as(s, id, .Near_Dabs)
}

@(private)
skin_mark_as :: proc(s: ^Sculptor, id: u32, how: Skin_Stale) {
	sk := s.skin
	if sk.stale[id] == .Fresh do append(&sk.stale_nodes, id)
	sk.stale[id] = max(sk.stale[id], how)
	mark_stale(s, id, .Skin)
}

// Notes a dab's reach, a sphere about `center`: every sample it changed lies inside.
@(private)
skin_box_add :: proc(sk: ^Skin, center: Vec3, radius: f32) {
	box := [2]Vec3{center - radius, center + radius}
	if len(sk.boxes) < SKIN_BOXES_MAX {
		append(&sk.boxes, box)
		return
	}
	last := &sk.boxes[len(sk.boxes) - 1]
	last^ = {linalg.min(last[0], box[0]), linalg.max(last[1], box[1])}
}

// Whether a sample of triangle t can have changed by a dab since the last flush: the
// triangle's sphere, widened by the tallest height (a sample lies that far at most from
// its flat point), meets one of `boxes`.
@(private)
skin_tri_near :: #force_inline proc(sk: ^Skin, t: u32, boxes: [][2]Vec3, widen: f32) -> bool {
	sp := sk.spheres[t]
	r := sp.w + widen
	for box in boxes {
		d := linalg.max(box[0] - sp.xyz, sp.xyz - box[1])
		d = linalg.max(d, Vec3{})
		if linalg.length2(d) <= r * r do return true
	}
	return false
}

// The share of a split dab of `radius` the vertices take: none for a dab under one mean
// edge of the nodes it hits (the mesh could not show it), all of it over four, and a
// smooth step between (Brush.skin_split). Reads the hit leaves of the dab.
@(private)
skin_mesh_share :: proc(s: ^Sculptor, radius: f32) -> f32 {
	sum: f32
	for leaf in s.hit do sum += s.skin.node_edge[s.node_of[leaf]]
	edge := sum / f32(max(len(s.hit), 1))
	if edge <= 0 do return 1
	return smoothstep(SKIN_SPLIT_FROM, SKIN_SPLIT_TO, radius / edge)
}

// A split dab is all skin under SKIN_SPLIT_FROM mean edges across and all mesh over
// SKIN_SPLIT_TO.
@(private)
SKIN_SPLIT_FROM :: 1
@(private)
SKIN_SPLIT_TO :: 4

// Whether a split dab's skin pass can change anything worth keeping. With the vertices
// taking all of it, Draw, Inflate and Crease leave the skin only what the mesh's flat
// triangles miss of the brush's curve, about the height times (edge / radius)² over two,
// which is skipped under a quarter of the skin's step along an edge: a wide stroke then
// costs what it costs without a skin. Smooth always runs, to smooth the skin's detail too.
@(private)
skin_split_needs_skin :: proc(s: ^Sculptor, d: ^Dab, share: f32) -> bool {
	brush := d.brush
	if share < 1 || brush.kind == .Smooth do return true
	if brush.kind != .Draw && brush.kind != .Inflate && brush.kind != .Crease do return false
	if brush.no_accumulate do return false
	edge := skin_mesh_edge(s)
	ratio := edge / max(brush.radius, 1e-12)
	height := brush.radius * brush.strength * DRAW_HEIGHT
	return height * ratio * ratio * 0.5 >= edge / (4 * f32(s.skin.segments))
}

// The hit nodes' mean edge (skin_mesh_share's).
@(private)
skin_mesh_edge :: proc(s: ^Sculptor) -> f32 {
	sum: f32
	for leaf in s.hit do sum += s.skin.node_edge[s.node_of[leaf]]
	return sum / f32(max(len(s.hit), 1))
}

// Turns a copy of a split dab into its skin pass: Draw, Inflate and Crease take the brush
// less what the corners take (Dab.mesh_share); Clay, Flatten, Layer and Accumulate off
// take the skin's share of the strength; Smooth smooths the skin at full strength.
@(private)
skin_split_brush :: proc(d: ^Dab, share: f32) {
	switch d.brush.kind {
	case .Draw, .Inflate, .Crease:
		if !d.brush.no_accumulate {
			d.mesh_share = share
			return
		}
		d.brush.strength *= 1 - share
	case .Smooth:
	case .Grab, .Elastic, .Mask, .Paint, .Cloth, .Pinch, .Snake_Hook, .Morph, .History, .Clay_Strips, .Trim_Dynamic, .Clay, .Flatten, .Layer:
		d.brush.strength *= 1 - share
	}
}

// After a split dab's vertices moved: their nodes and the nodes that own their shared
// vertices need new skin normals only near the dab, an edge past its reach at most (a
// vertex normal turns only beside a moved vertex, and a triangle at that vertex holds it
// in its sphere, so the sphere comes within an edge, two sphere radii, of the reach), so
// they are marked as dabs mark, with a box that wide, instead of whole.
@(private)
skin_split_moved :: proc(s: ^Sculptor, d: ^Dab) {
	sk := s.skin
	for leaf in s.changed {
		id := s.node_of[leaf]
		sk.dab_moved[id] = true
		skin_mark_dab(s, id)
		for owner in node_owners(s, id) {
			sk.dab_moved[owner] = true
			skin_mark_dab(s, owner)
		}
	}
	skin_box_add(sk, d.center, math.sqrt(d.r2) + 2 * sk.sphere_max)
}

// One dab into the skin, called by dab_once once the area under the brush is known, in
// place of moving vertices. Returns how many samples changed.
@(private)
skin_dab :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool) -> int {
	sk := s.skin
	if s.history.recording do record_skin_hit(s)
	brush := d.brush
	sign: f32 = -1 if brush.invert else 1
	once := brush.no_accumulate && (brush.kind == .Draw || brush.kind == .Inflate)
	if brush.kind == .Layer || once do skin_layer_fit(sk, s.history.allocator)
	// A dab works through the hit leaves' samples, more of them than vertices, in runs of
	// triangles so that a few hit leaves still spread over every thread.
	count := 0
	clear(&sk.items)
	for leaf, i in s.hit {
		n := s.nodes[s.node_of[leaf]]
		count += skin_node_count(s, sk, s.node_of[leaf])
		end := n.tri_first + n.tri_count
		for lo := n.tri_first; lo < end; lo += SKIN_ITEM_TRIS {
			append(&sk.items, Skin_Item{hit = u32(i), tri_lo = lo, tri_hi = min(lo + SKIN_ITEM_TRIS, end), verts = lo == n.tri_first})
		}
		if n.tri_count == 0 do append(&sk.items, Skin_Item{hit = u32(i), tri_lo = end, tri_hi = end, verts = true})
	}
	pool := pool if count >= PARALLEL_MIN_VERTS else nil
	items := len(sk.items)
	switch brush.kind {
	case .Draw, .Inflate:
		d.amount = sign * brush.radius * brush.strength * DRAW_HEIGHT
		if brush.kind == .Draw {
			if once do jobs.parallel_for(pool, items, d, job_skin_draw_once)
			else do jobs.parallel_for(pool, items, d, job_skin_draw)
		} else {
			if once do jobs.parallel_for(pool, items, d, job_skin_inflate_once)
			else do jobs.parallel_for(pool, items, d, job_skin_inflate)
		}
	case .Clay:
		d.amount = sign
		d.plane += d.normal * (sign * brush.radius * CLAY_HEIGHT)
		jobs.parallel_for(pool, items, d, job_skin_clay)
	case .Flatten:
		d.amount = sign
		jobs.parallel_for(pool, items, d, job_skin_flatten)
	case .Crease:
		d.amount = -sign * brush.radius * brush.strength * DRAW_HEIGHT
		jobs.parallel_for(pool, items, d, job_skin_crease)
	case .Layer:
		d.amount = sign * brush.radius * brush.strength * LAYER_HEIGHT
		jobs.parallel_for(pool, items, d, job_skin_layer)
	case .Smooth:
		resize(&sk.offsets, len(s.hit))
		total: u32
		for leaf, i in s.hit {
			sk.offsets[i] = total
			total += u32(skin_node_count(s, sk, s.node_of[leaf]))
		}
		resize(&sk.smooth_to, int(total))
		for rate in smooth_passes(brush.strength) {
			d.rate = rate
			jobs.parallel_for(pool, items, d, job_skin_smooth_targets)
			jobs.parallel_for(pool, len(s.hit), d, job_skin_smooth_apply)
		}
	case .Grab, .Elastic, .Mask, .Paint, .Cloth, .Pinch, .Snake_Hook, .Morph, .History, .Clay_Strips, .Trim_Dynamic:
		unreachable()
	}
	if brush.kind != .Smooth {
		for &p in s.partials do p.moved, p.weight_sum = 0, 0
		for it in sk.items {
			p := &s.partials[it.hit]
			p.moved += it.moved
			p.weight_sum = max(p.weight_sum, it.top)
		}
	}
	changed := 0
	for p, i in s.partials {
		if p.moved == 0 do continue
		changed += int(p.moved)
		sk.height_max = max(sk.height_max, p.weight_sum)
		skin_mark_dab(s, s.node_of[s.hit[i]])
	}
	if changed > 0 do skin_box_add(sk, d.center, math.sqrt(d.r2))
	if changed > 0 && s.history.recording do s.history.current.skinned = true
	return changed
}

// Gives every sample a Layer height entry, all from no stroke.
@(private)
skin_layer_fit :: proc(sk: ^Skin, allocator: runtime.Allocator) {
	if len(sk.layer) == len(sk.heights) do return
	delete(sk.layer, allocator)
	sk.layer = make([]Layer_Height, len(sk.heights), allocator)
}

@(private) job_skin_draw :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Draw, false)}
@(private) job_skin_draw_once :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Draw, true)}
@(private) job_skin_inflate :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Inflate, false)}
@(private) job_skin_inflate_once :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Inflate, true)}
@(private) job_skin_clay :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Clay, false)}
@(private) job_skin_flatten :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Flatten, false)}
@(private) job_skin_crease :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Crease, false)}
@(private) job_skin_layer :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Layer, false)}
@(private) job_skin_smooth_targets :: proc(data: rawptr, i: int) {skin_displace(cast(^Dab)data, i, Brush_Kind.Smooth, false)}

// Moves the heights of run k's samples (Skin.items) inside the brush as brush kind K does,
// or for Smooth, works out their targets. The run's `moved` counts the changed samples and
// its `top` holds the largest height it left.
@(private)
skin_displace :: #force_inline proc(d: ^Dab, k: int, $K: Brush_Kind, $ONCE: bool) {
	s := d.s
	sk := s.skin
	item := &sk.items[k]
	i := int(item.hit)
	id := s.node_of[s.hit[i]]
	n := s.nodes[id]
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	S := sk.segments
	reach := math.sqrt(d.r2) + sk.height_max
	own2 := reach * reach
	// A split dab's skin pass also reaches the samples of every triangle with a corner the
	// vertices' pass moves, which lie an edge (two sphere radii) past the brush at most.
	if d.mesh_share > 0 do reach += 2 * sk.sphere_max
	reach2 := reach * reach
	inv_s := 1 / f32(S)
	split := d.mesh_share > 0
	N := s.mesh.normals[:]
	moved: u32
	top: f32
	// Where this run's samples sit among its node's (vertices, edges, then triangles'
	// insides), for Smooth's targets.
	F := skin_face_samples(sk)
	node_edges := sk.edge_first[n.tri_first + n.tri_count] - sk.edge_first[n.tri_first]
	e0 := sk.edge_first[item.tri_lo]
	e1 := sk.edge_first[item.tri_hi]
	edges_at := int(n.vert_count + (e0 - sk.edge_first[n.tri_first]) * (S - 1))
	faces_at := int(n.vert_count + node_edges * (S - 1) + (item.tri_lo - n.tri_first) * F)
	targets: []f32
	when K == .Smooth {
		// Every sample keeps its height unless the dab reaches it: this run's own.
		targets = sk.smooth_to[sk.offsets[i]:][:skin_node_count(s, sk, id)]
		if item.verts do for v in n.vert_first ..< n.vert_first + n.vert_count do targets[v - n.vert_first] = f32(sk.heights[v])
		edge_samples := sk.heights[sk.vert_count + e0 * (S - 1):][:(e1 - e0) * (S - 1)]
		for h, x in edge_samples do targets[edges_at + x] = f32(h)
		face_samples := sk.heights[sk.vert_count + sk.edge_count * (S - 1) + item.tri_lo * F:][:(item.tri_hi - item.tri_lo) * F]
		for h, x in face_samples do targets[faces_at + x] = f32(h)
	}

	// Vertex samples, skipped when the vertex is far: a sample lies at most the tallest
	// height from its flat point.
	at := 0
	if item.verts do for v in n.vert_first ..< n.vert_first + n.vert_count {
		if linalg.length2(P[v] - d.center) > reach * reach {
			at += 1
			continue
		}
		f := faces_of(s, v)[0]
		c := skin_corner_of(I, f, v)
		fi: u32 = S if c == 1 else 0
		fj: u32 = S if c == 2 else 0
		corners: [3]f32
		if split do corners = skin_corner_weights(d, f, K)
		skin_touch(d, v, f, fi, fj, corners, K, ONCE, &moved, &top, targets, at)
		at += 1
	}
	// Edge samples, each edge from its owner triangle, skipped when the edge is far.
	at = edges_at
	for e in e0 ..< e1 {
		edge := sk.edges[e]
		t := edge.tris[0]
		// The edge lies in its owner triangle, so inside that triangle's sphere.
		if !skin_sphere_near(sk, t, d.center, reach) {
			at += int(S - 1)
			continue
		}
		corners: [3]f32
		if split do corners = skin_corner_weights(d, t, K)
		for k in u32(1) ..< S {
			fi, fj := skin_edge_place(S, edge.corner, k)
			skin_touch(d, sk.vert_count + e * (S - 1) + (k - 1), t, fi, fj, corners, K, ONCE, &moved, &top, targets, at)
			at += 1
		}
	}
	// Inside samples, triangle by triangle, skipped when the triangle is far.
	at = faces_at
	base := sk.vert_count + sk.edge_count * (S - 1)
	for t in item.tri_lo ..< item.tri_hi {
		if F == 0 do continue
		if !skin_sphere_near(sk, t, d.center, reach) {
			at += int(F)
			continue
		}
		// The inside places' flat points and normals as skin_base works them out (the same
		// bits: S is a power of two, so times 1/S is over S), from the corners loaded once,
		// and a place whose flat point is beyond the reach is skipped before its height or
		// its normal's length.
		a, b, c := P[I[3 * t]], P[I[3 * t + 1]], P[I[3 * t + 2]]
		na, nb, nc := N[I[3 * t]], N[I[3 * t + 1]], N[I[3 * t + 2]]
		corners: [3]f32
		if split do corners = skin_corner_weights(d, t, K)
		// Only a triangle whose corners the vertices' pass moves needs its samples past the
		// brush; the rest keep to the brush's own reach.
		limit := reach2 if corners != {} else own2
		x := base + t * F
		for j in u32(1) ..= S - 2 do for ii in u32(1) ..= S - 1 - j {
			b1, b2 := f32(ii) * inv_s, f32(j) * inv_s
			b0 := 1 - b1 - b2
			p := a * b0 + b * b1 + c * b2
			if linalg.length2(p - d.center) < limit {
				skin_touch_at(d, x, t, ii, j, p, na * b0 + nb * b1 + nc * b2, corners, K, ONCE, &moved, &top, targets, at)
			}
			x += 1
			at += 1
		}
	}
	item.moved, item.top = moved, top
}

// One sample: index x, at grid place (i, j) of triangle t, at position `at` among its
// node's samples (for Smooth's targets).
@(private)
skin_touch :: #force_inline proc(d: ^Dab, x, t, i, j: u32, corners: [3]f32, $K: Brush_Kind, $ONCE: bool, moved: ^u32, top: ^f32, targets: []f32, at: int) {
	p, nn := skin_base(d.s, d.s.skin, t, i, j)
	skin_touch_at(d, x, t, i, j, p, nn, corners, K, ONCE, moved, top, targets, at)
}

// What a split dab's vertices' pass gives each corner of triangle t, as its weight (the
// vertex path's dab_weight, shield and facing, at the corner before it moves), squared
// for Crease, which moves a vertex by the square. Zero for corners out of reach.
@(private)
skin_corner_weights :: #force_inline proc(d: ^Dab, t: u32, $K: Brush_Kind) -> (w: [3]f32) {
	s := d.s
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	for c in 0 ..< 3 {
		v := I[3 * t + u32(c)]
		delta := P[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 >= d.r2 do continue
		w[c] = dab_weight(d, delta, d2) * shield(s.fade, s.mask, v) * facing_weight(d, s.mesh.normals[:], v)
		when K == .Crease do w[c] *= w[c]
	}
	return
}

// skin_touch with the sample's flat point and interpolated normal already worked out.
@(private)
skin_touch_at :: #force_inline proc(d: ^Dab, x, t, i, j: u32, p, nn: Vec3, corners: [3]f32, $K: Brush_Kind, $ONCE: bool, moved: ^u32, top: ^f32, targets: []f32, at: int) {
	s := d.s
	sk := s.skin
	nu := linalg.normalize0(nn)
	h := f32(sk.heights[x])
	q := p + nu * h
	delta := q - d.center
	d2 := linalg.dot(delta, delta)
	// A split dab's Draw, Inflate and Crease: what the moved corners give the sample,
	// mixed by where it lies between them, which its own share leaves out.
	given: f32
	when K == .Draw || K == .Inflate || K == .Crease {
		if d.mesh_share > 0 {
			S := f32(sk.segments)
			b1, b2 := f32(i) / S, f32(j) / S
			given = d.mesh_share * ((1 - b1 - b2) * corners[0] + b1 * corners[1] + b2 * corners[2])
		}
	}
	w: f32
	if d2 < d.r2 {
		w = dab_weight(d, delta, d2) * skin_gate(d, t, i, j)
		if d.brush.facing != {} do w *= clamp(linalg.dot(nu, d.brush.facing) * 5 + 0.5, 0, 1)
	}
	if w <= 0 && given == 0 do return
	next := h
	when ONCE {
		l := &sk.layer[x]
		was := l.height if l.stroke == s.layer_stroke else 0
		want := d.amount * w
		to := max(was, want) if d.amount > 0 else min(was, want)
		along: f32 = linalg.dot(d.normal, nu) if K == .Draw else 1
		next = h + (to - was) * along
		l^ = {s.layer_stroke, to}
	} else when K == .Draw {
		next = h + d.amount * (w - given) * linalg.dot(d.normal, nu)
	} else when K == .Inflate {
		next = h + d.amount * (w - given)
	} else when K == .Clay {
		above := linalg.dot(q - d.plane, d.normal)
		if above * d.amount < 0 do next = h - above * min(d.brush.strength * w * PLANE_RATE, 1) / max(linalg.dot(nu, d.normal), SKIN_PLANE_COS_MIN)
	} else when K == .Flatten {
		above := linalg.dot(q - d.plane, d.normal)
		reach := d.brush.radius * (1 - clamp(d.brush.plane_short[0 if above > 0 else 1], 0, 1))
		if abs(above) <= reach do next = h - above * d.amount * min(d.brush.strength * w * PLANE_RATE, 1) / max(linalg.dot(nu, d.normal), SKIN_PLANE_COS_MIN)
	} else when K == .Crease {
		next = h + d.amount * (w * w - given)
	} else when K == .Layer {
		l := &sk.layer[x]
		was := l.height if l.stroke == s.layer_stroke else 0
		to := was + (d.amount - was) * min(w * LAYER_RATE, 1)
		next = h + (to - was)
		l^ = {s.layer_stroke, to}
	} else when K == .Smooth {
		targets[at] = h + (skin_height_mean(s, sk, t, i, j) - h) * min(d.rate * w, 1)
		return
	} else {
		#panic("not a skin brush")
	}
	stored := f16(next)
	if stored == sk.heights[x] do return
	sk.heights[x] = stored
	moved^ += 1
	top^ = max(top^, abs(f32(stored)))
}

// How much a dab may change a sample at grid place (i, j) of triangle t: its corners'
// HD fade, mask and Connected weights, mixed by where it lies between them.
@(private)
skin_gate :: #force_inline proc(d: ^Dab, t, i, j: u32) -> f32 {
	s := d.s
	if s.fade == nil && s.mask == nil && !d.connected do return 1
	I := s.mesh.indices[:]
	S := f32(s.skin.segments)
	b1, b2 := f32(i) / S, f32(j) / S
	b := [3]f32{1 - b1 - b2, b1, b2}
	w: f32
	for c in 0 ..< 3 {
		if b[c] <= 0 do continue
		v := I[3 * t + u32(c)]
		w += b[c] * shield(s.fade, s.mask, v) * connected_weight(d, v)
	}
	return w
}

// Smooth's second half: every target of the pass was worked out from the heights before
// it, and now they all land.
@(private)
job_skin_smooth_apply :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	sk := s.skin
	id := s.node_of[s.hit[i]]
	targets := sk.smooth_to[sk.offsets[i]:]
	moved := s.partials[i].moved
	top := s.partials[i].weight_sum
	at := 0
	for r in skin_node_ranges(s, sk, id) {
		for x in r.first ..< r.first + r.count {
			stored := f16(targets[at])
			at += 1
			if stored == sk.heights[x] do continue
			sk.heights[x] = stored
			moved += 1
			top = max(top, abs(f32(stored)))
		}
	}
	s.partials[i].moved = moved
	s.partials[i].weight_sum = top
}

// The mean height of the samples next to grid place (i, j) of triangle t on the grid, in
// every triangle the sample lies on, in a fixed order.
@(private)
skin_height_mean :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> f32 {
	sum: f32
	count: int
	S := sk.segments
	I := s.mesh.indices[:]
	around :: proc(s: ^Sculptor, sk: ^Skin, f, i, j: u32, sum: ^f32, count: ^int) {
		I := s.mesh.indices[:]
		S := int(sk.segments)
		steps := [6][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, -1}, {-1, 1}}
		for st in steps {
			a, b := int(i) + st.x, int(j) + st.y
			if a < 0 || b < 0 || a + b > S do continue
			sum^ += f32(sk.heights[skin_sample(sk, I, f, u32(a), u32(b))])
			count^ += 1
		}
	}
	switch {
	case (i == 0 && j == 0) || i == S || j == S:
		v := I[3 * t] if i == 0 && j == 0 else (I[3 * t + 1] if i == S else I[3 * t + 2])
		for f in faces_of(s, v) {
			c := skin_corner_of(I, f, v)
			fi: u32 = S if c == 1 else 0
			fj: u32 = S if c == 2 else 0
			around(s, sk, f, fi, fj, &sum, &count)
		}
	case j == 0 || i + j == S || i == 0:
		c: u32 = 0 if j == 0 else (1 if i + j == S else 2)
		k := i if c == 0 else (j if c == 1 else S - j)
		ref := sk.tri_edges[t][c]
		e := sk.edges[ref >> 1]
		along := k if ref & 1 == 0 else S - k
		for f in e.tris {
			fc := e.corner if f == e.tris[0] else skin_corner_of(I, f, I[3 * e.tris[0] + (e.corner + 1) % 3])
			fk := along if f == e.tris[0] else S - along
			fi, fj := skin_edge_place(S, fc, fk)
			around(s, sk, f, fi, fj, &sum, &count)
		}
	case:
		around(s, sk, t, i, j, &sum, &count)
	}
	return sum / f32(max(count, 1))
}

// Called by sculptor_flush once the vertex normals are current: recomputes the normals of
// every sample whose heights or mesh changed and of their neighbours', and lists their
// ranges for uploading. A node whose vertices moved, or whose heights changed anywhere
// (undo), has all its normals and its neighbours' recomputed; after dabs alone, only the
// samples of triangles near the dabs' boxes, since a sample's normal reads only heights
// in the triangles it lies in.
@(private)
skin_flush :: proc(s: ^Sculptor) {
	sk := s.skin
	clear(&sk.ranges)
	// Moved vertices move their triangles' spheres too.
	for id in s.dirty_nodes {
		if s.stale[id] != .Shape && s.stale[id] != .Edge do continue
		skin_mark_as(s, id, .Near_Dabs if sk.dab_moved[id] else .Whole)
		sk.dab_moved[id] = false
		n := s.nodes[id]
		for t in n.tri_first ..< n.tri_first + n.tri_count {
			skin_sphere(s, sk, t)
			sk.sphere_max = max(sk.sphere_max, sk.spheres[t].w)
		}
		skin_node_edge(s, sk, id)
	}
	if len(sk.stale_nodes) == 0 {
		clear(&sk.boxes)
		return
	}
	// Each stale node passes its staleness to the nodes near it, the stronger kind winning.
	base := make([]Skin_Stale, len(sk.stale_nodes), context.temp_allocator)
	for id, i in sk.stale_nodes do base[i] = sk.stale[id]
	listed := make([]bool, len(s.nodes), context.temp_allocator)
	todo := make([dynamic]u32, 0, 4 * len(base), context.temp_allocator)
	for id, i in sk.stale_nodes {
		for other in sk.near[sk.near_first[id]:sk.near_first[id + 1]] {
			if !listed[other] {
				listed[other] = true
				append(&todo, other)
			}
			sk.stale[other] = max(sk.stale[other], base[i])
		}
	}
	clear(&sk.stale_nodes)
	slice.sort(todo[:])
	Job :: struct {
		s:     ^Sculptor,
		nodes: []u32,
		widen: f32,
	}
	job := Job{s, todo[:], sk.height_max}
	samples := 0
	for id in todo do samples += skin_node_count(s, sk, id)
	jobs.parallel_for(s.pool if samples >= PARALLEL_MIN_VERTS else nil, len(todo), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		id := job.nodes[i]
		sk := job.s.skin
		if sk.stale[id] == .Whole do skin_node_normals(job.s, sk, id)
		else do skin_node_normals_near(job.s, sk, id, job.widen)
	})
	// The three kinds of sample lie in three blocks, and each node's range in a block
	// follows the node before it, so each block coalesces on its own.
	add :: proc(ranges: ^[dynamic]Skin_Range, r: Skin_Range) {
		if r.count == 0 do return
		if k := len(ranges); k > 0 && ranges[k - 1].first + ranges[k - 1].count == r.first {
			ranges[k - 1].count += r.count
		} else {
			append(ranges, r)
		}
	}
	S := sk.segments
	F := skin_face_samples(sk)
	for kind in 0 ..< 3 {
		for id in todo {
			if sk.stale[id] == .Whole {
				add(&sk.ranges, skin_node_ranges(s, sk, id)[kind])
				continue
			}
			n := s.nodes[id]
			switch kind {
			case 0:
				for v in n.vert_first ..< n.vert_first + n.vert_count {
					if !sk.redo_vert[v] do continue
					sk.redo_vert[v] = false
					add(&sk.ranges, {v, 1})
				}
			case 1:
				for e in sk.edge_first[n.tri_first] ..< sk.edge_first[n.tri_first + n.tri_count] {
					if !sk.redo_edge[e] do continue
					sk.redo_edge[e] = false
					add(&sk.ranges, {sk.vert_count + e * (S - 1), S - 1})
				}
			case 2:
				for t in n.tri_first ..< n.tri_first + n.tri_count {
					if !sk.redo_tri[t] do continue
					sk.redo_tri[t] = false
					add(&sk.ranges, {sk.vert_count + sk.edge_count * (S - 1) + t * F, F})
				}
			}
		}
	}
	for id in todo do sk.stale[id] = .Fresh
	clear(&sk.boxes)
}

// The parts of the node's own triangles at their borders (skin_grid_pass), worked out
// once for every vertex and edge sample of the node that needs them, where each would
// otherwise take its look-ups again for every sample along an edge.
@(private)
Skin_Borders :: struct {
	s:     ^Sculptor,
	sk:    ^Skin,
	first: u32, // the node's first triangle
	slot:  []u32, // by the node's triangles: 1 + where its parts start in parts, 0 for none yet
	parts: [dynamic]Skin_Partial, // 3 * segments for each triangle passed
}

@(private)
skin_borders_make :: proc(s: ^Sculptor, sk: ^Skin, n: Node) -> Skin_Borders {
	return {s = s, sk = sk, first = n.tri_first, slot = make([]u32, n.tri_count, runtime.heap_allocator()), parts = make([dynamic]Skin_Partial, runtime.heap_allocator())}
}

@(private)
skin_borders_delete :: proc(b: ^Skin_Borders) {
	delete(b.slot, runtime.heap_allocator())
	delete(b.parts)
}

// Room for triangle t's parts, when it is one of the node's; nil for another node's.
@(private)
skin_borders_room :: proc(b: ^Skin_Borders, t: u32) -> []Skin_Partial {
	if t < b.first || int(t - b.first) >= len(b.slot) do return nil
	S := int(b.sk.segments)
	at := len(b.parts)
	// Every part is written by the pass before it is read, so the room need not be cleared.
	non_zero_resize(&b.parts, at + 3 * S)
	b.slot[t - b.first] = u32(at) + 1
	return b.parts[at:][:3 * S]
}

// Runs triangle t's grid pass, writing its inside normals with `inside`, and keeps its
// border parts when it is one of the node's.
@(private)
skin_borders_pass :: proc(b: ^Skin_Borders, t: u32, inside: bool) {
	skin_grid_pass(b.s, b.sk, t, inside, skin_borders_room(b, t))
}

// Triangle f's part at corner c's edge, k steps along it: from the node's kept parts,
// with a pass for a triangle of the node not passed yet when `pass`, or else looked up
// on its own.
@(private)
skin_borders_part :: proc(b: ^Skin_Borders, f, c, k: u32, pass: bool) -> Skin_Partial {
	S := b.sk.segments
	inside := f >= b.first && int(f - b.first) < len(b.slot)
	if inside && b.slot[f - b.first] == 0 && pass do skin_borders_pass(b, f, false)
	if !inside || b.slot[f - b.first] == 0 {
		i, j := skin_edge_place(S, c, k)
		return skin_partial(b.s, b.sk, f, i, j)
	}
	return b.parts[b.slot[f - b.first] - 1 + skin_border_index(S, c, k)]
}

// Vertex v's sample normal, as skin_normal gives it from v's first triangle.
@(private)
skin_borders_vertex :: proc(b: ^Skin_Borders, v: u32) -> Vec3 {
	I := b.s.mesh.indices[:]
	S := b.sk.segments
	faces := faces_of(b.s, v)
	c := skin_corner_of(I, faces[0], v)
	fi: u32 = S if c == 1 else 0
	fj: u32 = S if c == 2 else 0
	_, base := skin_base(b.s, b.sk, faces[0], fi, fj)
	sum: Skin_Partial
	for f in faces {
		p := skin_borders_part(b, f, skin_corner_of(I, f, v), 0, pass = false)
		sum.turn += p.turn
		sum.area += p.area
	}
	return skin_normal_from(base, sum)
}

// Writes edge e's inside sample normals, as skin_normal gives them from its first
// triangle.
@(private)
skin_borders_edge :: proc(b: ^Skin_Borders, e: u32) {
	I := b.s.mesh.indices[:]
	S := b.sk.segments
	edge := b.sk.edges[e]
	ref := b.sk.tri_edges[edge.tris[0]][edge.corner]
	other := skin_corner_of(I, edge.tris[1], I[3 * edge.tris[0] + (edge.corner + 1) % 3])
	for k in u32(1) ..< S {
		fi, fj := skin_edge_place(S, edge.corner, k)
		_, base := skin_base(b.s, b.sk, edge.tris[0], fi, fj)
		along := k if ref & 1 == 0 else S - k
		sum: Skin_Partial
		for f in edge.tris {
			p := skin_borders_part(b, f, edge.corner, along, true) if f == edge.tris[0] else skin_borders_part(b, f, other, S - along, true)
			sum.turn += p.turn
			sum.area += p.area
		}
		b.sk.normals[b.sk.vert_count + e * (S - 1) + (k - 1)] = geom.oct_encode(skin_normal_from(base, sum))
	}
}

// Recomputes the normals of the samples node `id` writes that lie in a triangle near the
// dab boxes (skin_tri_near): a vertex's when any triangle at it is, an edge's when either
// of its triangles is, a triangle's inside samples when it is. Marks what it redid in the
// redo lists, which only this node's job writes at these places.
@(private)
skin_node_normals_near :: proc(s: ^Sculptor, sk: ^Skin, id: u32, widen: f32) {
	n := s.nodes[id]
	// Only the boxes that reach the node's own box (its leaf's, around its triangles),
	// widened by the tallest height and by the widest triangle, since a triangle of
	// another node at one of its vertices or edges lies within that of the box; usually
	// one or two.
	bounds := s.bvh.nodes[n.leaf].bounds
	reach := widen + 2 * sk.sphere_max
	kept := make([dynamic][2]Vec3, 0, len(sk.boxes), runtime.heap_allocator())
	defer delete(kept)
	for box in sk.boxes {
		if bounds.lo.x - reach <= box[1].x && bounds.hi.x + reach >= box[0].x && bounds.lo.y - reach <= box[1].y && bounds.hi.y + reach >= box[0].y && bounds.lo.z - reach <= box[1].z && bounds.hi.z + reach >= box[0].z do append(&kept, box)
	}
	if len(kept) == 0 do return
	boxes := kept[:]
	b := skin_borders_make(s, sk, n)
	defer skin_borders_delete(&b)
	// The near triangles first, whose passes also give their inside normals.
	for t in n.tri_first ..< n.tri_first + n.tri_count {
		if !skin_tri_near(sk, t, boxes, widen) do continue
		skin_borders_pass(&b, t, true)
		sk.redo_tri[t] = true
	}
	// Then the edges, which pass a far triangle of the node beside a near one, and the
	// vertices last, which only look up the parts of triangles not passed by then.
	for e in sk.edge_first[n.tri_first] ..< sk.edge_first[n.tri_first + n.tri_count] {
		edge := sk.edges[e]
		if !skin_tri_near(sk, edge.tris[0], boxes, widen) && !skin_tri_near(sk, edge.tris[1], boxes, widen) do continue
		skin_borders_edge(&b, e)
		sk.redo_edge[e] = true
	}
	for v in n.vert_first ..< n.vert_first + n.vert_count {
		near := false
		for f in faces_of(s, v) do if skin_tri_near(sk, f, boxes, widen) {near = true; break}
		if !near do continue
		sk.normals[v] = geom.oct_encode(skin_borders_vertex(&b, v))
		sk.redo_vert[v] = true
	}
}

// Recomputes the normals of the samples node `id` writes.
@(private)
skin_node_normals :: proc(s: ^Sculptor, sk: ^Skin, id: u32) {
	n := s.nodes[id]
	b := skin_borders_make(s, sk, n)
	defer skin_borders_delete(&b)
	for t in n.tri_first ..< n.tri_first + n.tri_count do skin_borders_pass(&b, t, true)
	for e in sk.edge_first[n.tri_first] ..< sk.edge_first[n.tri_first + n.tri_count] do skin_borders_edge(&b, e)
	for v in n.vert_first ..< n.vert_first + n.vert_count do sk.normals[v] = geom.oct_encode(skin_borders_vertex(&b, v))
}

// Called by skin_dab before the dab changes anything: saves the heights of every hit node
// this stroke has not saved yet.
@(private)
record_skin_hit :: proc(s: ^Sculptor) {
	h := &s.history
	sk := s.skin
	for leaf in s.hit {
		id := s.node_of[leaf]
		if h.skin_saved[id] == h.stamp do continue
		h.skin_saved[id] = h.stamp
		heights := make([]f16, skin_node_count(s, sk, id), h.allocator)
		skin_node_copy(s, sk, id, heights, out = true)
		append(&h.current.saved, Saved_Node{node = id, heights = heights})
	}
}

// Copies node `id`'s heights into `buf` (out) or from it (not out).
@(private)
skin_node_copy :: proc(s: ^Sculptor, sk: ^Skin, id: u32, buf: []f16, out: bool) {
	at := 0
	for r in skin_node_ranges(s, sk, id) {
		live := sk.heights[r.first:][:r.count]
		if out do copy(buf[at:], live)
		else do copy(live, buf[at:][:r.count])
		at += int(r.count)
	}
}

// Trades a saved node's heights with the live ones, for undo and redo; nothing when the
// skin they were saved from is gone or has other segments.
@(private)
skin_saved_swap :: proc(s: ^Sculptor, sv: ^Saved_Node) {
	sk := s.skin
	if sk == nil || int(sv.node) >= len(s.nodes) || skin_node_count(s, sk, sv.node) != len(sv.heights) do return
	at := 0
	for r in skin_node_ranges(s, sk, sv.node) {
		live := sk.heights[r.first:][:r.count]
		for &x, k in live {
			x, sv.heights[at + k] = sv.heights[at + k], x
			sk.height_max = max(sk.height_max, abs(f32(x)))
		}
		at += int(r.count)
	}
	skin_mark(s, sv.node)
}

// Puts a saved node's heights back, for a stroke restored or discarded.
@(private)
skin_saved_restore :: proc(s: ^Sculptor, sv: Saved_Node) {
	sk := s.skin
	if sk == nil || skin_node_count(s, sk, sv.node) != len(sv.heights) do return
	skin_node_copy(s, sk, sv.node, sv.heights, out = false)
	skin_mark(s, sv.node)
}
