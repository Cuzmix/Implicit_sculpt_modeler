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
	for id in 0 ..< u32(len(s.nodes)) do skin_mark(s, id)
}

// The bytes a skin holds.
@(private)
skin_bytes :: proc(sk: ^Skin) -> int {
	if sk == nil do return 0
	bytes := size_of(Skin) + len(sk.heights) * size_of(f16) + len(sk.normals) * size_of([2]i16) + len(sk.layer) * size_of(Layer_Height)
	bytes += (len(sk.edge_first) + len(sk.near_first) + len(sk.near)) * size_of(u32) + len(sk.tri_edges) * size_of([3]u32)
	return bytes + len(sk.edges) * size_of(Skin_Edge) + len(sk.stale)
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

// Notes that node `id`'s heights changed: its normals and its neighbours' wait for the
// next sculptor_flush, which also takes its box into the redraw.
@(private)
skin_mark :: proc(s: ^Sculptor, id: u32) {
	sk := s.skin
	if !sk.stale[id] {
		sk.stale[id] = true
		append(&sk.stale_nodes, id)
	}
	mark_stale(s, id, .Skin)
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
	// A dab works through the hit leaves' samples, more of them than vertices.
	count := 0
	for leaf in s.hit do count += skin_node_count(s, sk, s.node_of[leaf])
	pool := pool if count >= PARALLEL_MIN_VERTS else nil
	switch brush.kind {
	case .Draw, .Inflate:
		d.amount = sign * brush.radius * brush.strength * DRAW_HEIGHT
		if brush.kind == .Draw {
			if once do jobs.parallel_for(pool, len(s.hit), d, job_skin_draw_once)
			else do jobs.parallel_for(pool, len(s.hit), d, job_skin_draw)
		} else {
			if once do jobs.parallel_for(pool, len(s.hit), d, job_skin_inflate_once)
			else do jobs.parallel_for(pool, len(s.hit), d, job_skin_inflate)
		}
	case .Clay:
		d.amount = sign
		d.plane += d.normal * (sign * brush.radius * CLAY_HEIGHT)
		jobs.parallel_for(pool, len(s.hit), d, job_skin_clay)
	case .Flatten:
		d.amount = sign
		jobs.parallel_for(pool, len(s.hit), d, job_skin_flatten)
	case .Crease:
		d.amount = -sign * brush.radius * brush.strength * DRAW_HEIGHT
		jobs.parallel_for(pool, len(s.hit), d, job_skin_crease)
	case .Layer:
		d.amount = sign * brush.radius * brush.strength * LAYER_HEIGHT
		jobs.parallel_for(pool, len(s.hit), d, job_skin_layer)
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
			jobs.parallel_for(pool, len(s.hit), d, job_skin_smooth_targets)
			jobs.parallel_for(pool, len(s.hit), d, job_skin_smooth_apply)
		}
	case .Grab, .Elastic, .Mask, .Paint, .Cloth, .Pinch, .Snake_Hook, .Morph, .History, .Clay_Strips, .Trim_Dynamic:
		unreachable()
	}
	changed := 0
	for p, i in s.partials {
		if p.moved == 0 do continue
		changed += int(p.moved)
		sk.height_max = max(sk.height_max, p.weight_sum)
		skin_mark(s, s.node_of[s.hit[i]])
	}
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

// Moves the heights of hit leaf i's samples inside the brush as brush kind K does, or for
// Smooth, works out their targets. The partial's `moved` counts the changed samples and
// its `weight_sum` holds the largest height it left.
@(private)
skin_displace :: #force_inline proc(d: ^Dab, i: int, $K: Brush_Kind, $ONCE: bool) {
	s := d.s
	sk := s.skin
	id := s.node_of[s.hit[i]]
	n := s.nodes[id]
	I := s.mesh.indices[:]
	P := s.mesh.positions[:]
	S := sk.segments
	reach := math.sqrt(d.r2) + sk.height_max
	moved: u32
	top: f32
	at := 0
	targets: []f32
	when K == .Smooth {
		// Every sample keeps its height unless the dab reaches it.
		targets = sk.smooth_to[sk.offsets[i]:][:skin_node_count(s, sk, id)]
		k := 0
		for r in skin_node_ranges(s, sk, id) {
			for x in r.first ..< r.first + r.count {
				targets[k] = f32(sk.heights[x])
				k += 1
			}
		}
	}

	// Vertex samples.
	for v in n.vert_first ..< n.vert_first + n.vert_count {
		f := faces_of(s, v)[0]
		c := skin_corner_of(I, f, v)
		fi: u32 = S if c == 1 else 0
		fj: u32 = S if c == 2 else 0
		skin_touch(d, v, f, fi, fj, K, ONCE, &moved, &top, targets, at)
		at += 1
	}
	// Edge samples, each edge from its owner triangle, skipped when the edge is far.
	e0 := sk.edge_first[n.tri_first]
	e1 := sk.edge_first[n.tri_first + n.tri_count]
	for e in e0 ..< e1 {
		edge := sk.edges[e]
		t := edge.tris[0]
		a, b := P[I[3 * t + edge.corner]], P[I[3 * t + (edge.corner + 1) % 3]]
		mid := (a + b) * 0.5
		if linalg.length(mid - d.center) > reach + linalg.length(b - a) * 0.5 {
			at += int(S - 1)
			continue
		}
		for k in u32(1) ..< S {
			fi, fj := skin_edge_place(S, edge.corner, k)
			skin_touch(d, sk.vert_count + e * (S - 1) + (k - 1), t, fi, fj, K, ONCE, &moved, &top, targets, at)
			at += 1
		}
	}
	// Inside samples, triangle by triangle, skipped when the triangle is far.
	F := skin_face_samples(sk)
	base := sk.vert_count + sk.edge_count * (S - 1)
	for t in n.tri_first ..< n.tri_first + n.tri_count {
		if F == 0 do continue
		a, b, c := P[I[3 * t]], P[I[3 * t + 1]], P[I[3 * t + 2]]
		mid := (a + b + c) * (1.0 / 3)
		span := max(linalg.length(a - mid), linalg.length(b - mid), linalg.length(c - mid))
		if linalg.length(mid - d.center) > reach + span {
			at += int(F)
			continue
		}
		x := base + t * F
		for j in u32(1) ..= S - 2 do for ii in u32(1) ..= S - 1 - j {
			skin_touch(d, x, t, ii, j, K, ONCE, &moved, &top, targets, at)
			x += 1
			at += 1
		}
	}
	when K != .Smooth {
		s.partials[i].moved = moved
		s.partials[i].weight_sum = top
	}
}

// One sample: index x, at grid place (i, j) of triangle t, at position `at` among its
// node's samples (for Smooth's targets).
@(private)
skin_touch :: #force_inline proc(d: ^Dab, x, t, i, j: u32, $K: Brush_Kind, $ONCE: bool, moved: ^u32, top: ^f32, targets: []f32, at: int) {
	s := d.s
	sk := s.skin
	p, nn := skin_base(s, sk, t, i, j)
	nu := linalg.normalize0(nn)
	h := f32(sk.heights[x])
	q := p + nu * h
	delta := q - d.center
	d2 := linalg.dot(delta, delta)
	if d2 >= d.r2 do return
	w := dab_weight(d, delta, d2) * skin_gate(d, t, i, j)
	if d.brush.facing != {} do w *= clamp(linalg.dot(nu, d.brush.facing) * 5 + 0.5, 0, 1)
	if w <= 0 do return
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
		next = h + d.amount * w * linalg.dot(d.normal, nu)
	} else when K == .Inflate {
		next = h + d.amount * w
	} else when K == .Clay {
		above := linalg.dot(q - d.plane, d.normal)
		if above * d.amount < 0 do next = h - above * min(d.brush.strength * w * PLANE_RATE, 1) / max(linalg.dot(nu, d.normal), SKIN_PLANE_COS_MIN)
	} else when K == .Flatten {
		above := linalg.dot(q - d.plane, d.normal)
		reach := d.brush.radius * (1 - clamp(d.brush.plane_short[0 if above > 0 else 1], 0, 1))
		if abs(above) <= reach do next = h - above * d.amount * min(d.brush.strength * w * PLANE_RATE, 1) / max(linalg.dot(nu, d.normal), SKIN_PLANE_COS_MIN)
	} else when K == .Crease {
		next = h + d.amount * w * w
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
// ranges for uploading.
@(private)
skin_flush :: proc(s: ^Sculptor) {
	sk := s.skin
	clear(&sk.ranges)
	// The nodes whose samples' normals are stale: those whose heights changed and those
	// whose vertices or vertex normals did, and every node near one of them.
	base := make([dynamic]u32, 0, len(sk.stale_nodes) + len(s.dirty_nodes), context.temp_allocator)
	for id in sk.stale_nodes do append(&base, id)
	for id in s.dirty_nodes do if s.stale[id] == .Shape || s.stale[id] == .Edge do append(&base, id)
	for id in sk.stale_nodes do sk.stale[id] = false
	clear(&sk.stale_nodes)
	if len(base) == 0 do return
	todo := make([dynamic]u32, 0, 4 * len(base), context.temp_allocator)
	for id in base {
		for other in sk.near[sk.near_first[id]:sk.near_first[id + 1]] {
			if sk.stale[other] do continue
			sk.stale[other] = true
			append(&todo, other)
		}
	}
	for id in todo do sk.stale[id] = false
	slice.sort(todo[:])
	Job :: struct {
		s:     ^Sculptor,
		nodes: []u32,
	}
	job := Job{s, todo[:]}
	samples := 0
	for id in todo do samples += skin_node_count(s, sk, id)
	jobs.parallel_for(s.pool if samples >= PARALLEL_MIN_VERTS else nil, len(todo), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		skin_node_normals(job.s, job.s.skin, job.nodes[i])
	})
	// The three kinds of sample lie in three blocks, and each node's range in a block
	// follows the node before it, so each block coalesces on its own.
	for kind in 0 ..< 3 {
		for id in todo {
			r := skin_node_ranges(s, sk, id)[kind]
			if r.count == 0 do continue
			if k := len(sk.ranges); k > 0 && sk.ranges[k - 1].first + sk.ranges[k - 1].count == r.first {
				sk.ranges[k - 1].count += r.count
			} else {
				append(&sk.ranges, r)
			}
		}
	}
}

// Recomputes the normals of the samples node `id` writes.
@(private)
skin_node_normals :: proc(s: ^Sculptor, sk: ^Skin, id: u32) {
	n := s.nodes[id]
	I := s.mesh.indices[:]
	S := sk.segments
	for v in n.vert_first ..< n.vert_first + n.vert_count {
		f := faces_of(s, v)[0]
		c := skin_corner_of(I, f, v)
		fi: u32 = S if c == 1 else 0
		fj: u32 = S if c == 2 else 0
		sk.normals[v] = geom.oct_encode(skin_normal(s, sk, f, fi, fj))
	}
	for e in sk.edge_first[n.tri_first] ..< sk.edge_first[n.tri_first + n.tri_count] {
		edge := sk.edges[e]
		for k in u32(1) ..< S {
			fi, fj := skin_edge_place(S, edge.corner, k)
			sk.normals[sk.vert_count + e * (S - 1) + (k - 1)] = geom.oct_encode(skin_normal(s, sk, edge.tris[0], fi, fj))
		}
	}
	x := sk.vert_count + sk.edge_count * (S - 1) + n.tri_first * skin_face_samples(sk)
	for t in n.tri_first ..< n.tri_first + n.tri_count {
		for j in u32(1) ..= S - 2 do for i in u32(1) ..= S - 1 - j {
			sk.normals[x] = geom.oct_encode(skin_normal(s, sk, t, i, j))
			x += 1
		}
	}
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
