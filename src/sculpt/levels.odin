package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"

// Subdivision levels, as in ZBrush: a base mesh and finer copies of it, each made from
// the one below by one step of Loop subdivision (four triangles for each). Every level
// is a whole mesh with its own sculptor, so a brush on any level costs what it costs on
// a plain mesh of that size, and only the current level is shown and sculpted.
//
// Each vertex above the base stores its offset (its "detail") from the point Loop
// subdivision puts it at, in a frame that turns with the surface of the level below.
// When a level changes, levels_sync brings the others along:
//   - levels above are rebuilt from it with their detail, so fine detail rides on a
//     coarse change;
//   - levels below move each vertex by a local average of the change, so they follow
//     the large shapes of a fine edit, and what they cannot show stays as detail.
// Syncing visits only the nodes the edit reached and the nodes depending on those on
// the other levels, so it costs about what the edit covered.
MAX_LEVELS :: 8

// For each node of one level, a list of nodes of a neighbouring level.
Node_Lists :: struct {
	offsets: []u32, // node i's list is items[offsets[i]:offsets[i + 1]]
	items:   []u32,
}

Level :: struct {
	mesh:           geom.Mesh,
	sculptor:       Sculptor,
	node_of_vertex: []u32, // per vertex: the node owning it
	// How the level derives from the one below; empty on the base level.
	parents:        [][4]u32,   // per vertex: what its Loop point is made of (see frame_at)
	detail:         []Vec3,     // per vertex: its offset from that point, in that point's frame
	even_of:        []u32,      // per vertex of the level below: the vertex it became here
	deps:           Node_Lists, // per node: the nodes below whose vertices its Loop points read
	dependents:     Node_Lists, // per node below: the nodes here whose Loop points read its vertices
}

Levels :: struct {
	levels:         [dynamic]^Level, // base first; heap allocated, since sculptors point at their meshes
	current:        int,
	pool:           ^jobs.Pool,
	node_triangles: u32,
	allocator:      runtime.Allocator,
	// Sync scratch, kept between syncs: memory fresh from the system costs a page fault
	// on its first use, which made the first sync of a large edit several times slower.
	residual:       [dynamic]Vec3,
	hd:             Hd, // detail above the top level (hd.odin)
}

// parents[2] of a vertex that continues a vertex of the level below: {that vertex, a
// neighbour of it giving the tangent, EVEN, 0}. Other vertices sit on an edge a-b of
// the level below, between the triangles a-b-c and b-a-d: {a, b, c, d}.
@(private)
EVEN :: max(u32)

// Takes `mesh` as the base level and prepares it for sculpting (see sculptor_init).
levels_init :: proc(l: ^Levels, mesh: geom.Mesh, pool: ^jobs.Pool, node_triangles: u32 = NODE_TRIANGLES, allocator := context.allocator) {
	l.pool, l.node_triangles, l.allocator = pool, node_triangles, allocator
	l.levels = make([dynamic]^Level, 0, MAX_LEVELS, allocator)
	l.residual = make([dynamic]Vec3, allocator)
	base := new(Level, allocator)
	base.mesh = mesh
	sculptor_init(&base.sculptor, &base.mesh, pool, node_triangles, allocator = allocator)
	base.node_of_vertex = node_of_vertex_build(&base.sculptor, allocator)
	append(&l.levels, base)
	l.current = 0
}

levels_destroy :: proc(l: ^Levels) {
	levels_hd_delete(l)
	for lv in l.levels do level_free(l, lv)
	delete(l.levels)
	delete(l.residual)
	l^ = {}
}

levels_current :: proc(l: ^Levels) -> ^Level {
	return l.levels[l.current]
}

// Makes level `index` the one to sculpt and show, after bringing every level up to date
// with the edits on the current one. End any stroke, and leave any HD window, first.
levels_set_current :: proc(l: ^Levels, index: int) {
	assert(l.hd.window == nil, "leave the HD window first")
	target := clamp(index, 0, len(l.levels) - 1)
	if target == l.current do return
	levels_sync(l)
	levels_carry_mask(l, l.current, target)
	l.current = target
}

// Adds a level above the top one and makes it current. Returns false, changing
// nothing, when MAX_LEVELS are in use, the top level is not a closed manifold mesh, or
// there is an HD level (whose detail is tied to the top level as it is).
levels_subdivide :: proc(l: ^Levels) -> bool {
	if len(l.levels) >= MAX_LEVELS || l.hd.steps > 0 || levels_dynamic(l) do return false
	levels_sync(l)
	lv, ok := level_above(l, l.levels[len(l.levels) - 1])
	if !ok do return false
	append(&l.levels, lv)
	levels_carry_mask(l, l.current, len(l.levels) - 1)
	l.current = len(l.levels) - 1
	return true
}

// Turns dynamic topology (dyntopo.odin) on for the only level. Returns false, changing
// nothing, when there are other levels or an HD level, or the mesh has a vertex in more
// than DYN_FACES triangles. Clears the undo history.
levels_dyn_enable :: proc(l: ^Levels) -> bool {
	if len(l.levels) != 1 || l.hd.steps > 0 do return false
	lv := l.levels[0]
	if !sculptor_dyn_enable(&lv.sculptor, l.allocator) do return false
	delete(lv.node_of_vertex, l.allocator)
	lv.node_of_vertex = nil
	return true
}

// Turns dynamic topology off again, packing the mesh. Clears the undo history.
levels_dyn_disable :: proc(l: ^Levels) {
	lv := l.levels[0]
	if lv.sculptor.dyn == nil do return
	sculptor_dyn_disable(&lv.sculptor, l.allocator)
	lv.node_of_vertex = node_of_vertex_build(&lv.sculptor, l.allocator)
}

levels_dynamic :: proc(l: ^Levels) -> bool {return l.levels[0].sculptor.dyn != nil}

// Vertices, triangles and CPU bytes of the level levels_subdivide would add.
levels_subdivide_estimate :: proc(l: ^Levels) -> (vertices, triangles, bytes: int) {
	top := l.levels[len(l.levels) - 1]
	v, t := len(top.mesh.positions), len(top.mesh.indices) / 3
	vertices, triangles = v + 3 * t / 2, 4 * t // a closed mesh has 3/2 edges per triangle
	return vertices, triangles, level_estimate_bytes(vertices, triangles, v)
}

// CPU bytes of a level of that many vertices and triangles over a level of `below`
// vertices. Per vertex: position, normal, face list offset, owner node, parents,
// detail. Per triangle: indices, face list entries, BVH order and leaf, simplified
// copies. Per vertex below: the vertex it became.
level_estimate_bytes :: proc(vertices, triangles, below: int) -> int {
	return vertices * (12 + 12 + 4 + 4 + 16 + 12) + triangles * (12 + 12 + 8 + 5) + below * 4
}

// Deletes every level above the current one, and with the top level any HD level.
levels_delete_higher :: proc(l: ^Levels) {
	assert(l.hd.window == nil, "leave the HD window first")
	if len(l.levels) > l.current + 1 do levels_hd_delete(l)
	for len(l.levels) > l.current + 1 do level_free(l, pop(&l.levels))
	levels_sync(l)
}

// Deletes every level below the current one, which becomes the base.
levels_delete_lower :: proc(l: ^Levels) {
	assert(l.hd.window == nil, "leave the HD window first")
	k := l.current
	if k == 0 do return
	sync_levels(l, down = false)
	for lv in l.levels[:k] do level_free(l, lv)
	level_unlink(l, l.levels[k])
	copy(l.levels[:], l.levels[k:])
	resize(&l.levels, len(l.levels) - k)
	l.current = 0
}

// CPU bytes of the meshes, sculptors (without undo history, with simplified copies),
// level links and HD detail, with any HD window.
levels_bytes :: proc(l: ^Levels) -> int {
	total := 0
	for lv in l.levels do total += level_bytes(lv)
	hd := levels_hd_stats(l)
	return total + hd.stored_bytes + hd.window_bytes
}

@(private)
level_bytes :: proc(lv: ^Level) -> int {
	m, s := &lv.mesh, &lv.sculptor
	total := len(m.positions) * 2 * size_of(Vec3) + len(m.indices) * size_of(u32)
	total += (len(s.faces.offsets) + len(s.faces.tris) + len(s.bvh.tri_order) + len(s.bvh.tri_leaf)) * size_of(u32)
	total += len(s.bvh.nodes) * size_of(geom.Bvh_Node) + len(s.nodes) * (size_of(Node) + size_of(geom.Chunk))
	total += (len(s.shared) + len(s.owners) + len(lv.node_of_vertex) + len(lv.even_of)) * size_of(u32)
	total += len(lv.parents) * size_of([4]u32) + len(lv.detail) * size_of(Vec3)
	total += (len(lv.deps.offsets) + len(lv.deps.items) + len(lv.dependents.offsets) + len(lv.dependents.items)) * size_of(u32)
	total += cap(s.lod.indices) * size_of(u32) + len(s.lod.tree.groups) * size_of(geom.Lod_Group) + len(s.lod.parent) * size_of(u32)
	return total + sculptor_dyn_bytes(s)
}

// Brings every level up to date with the edits made on the current level since the
// last sync. levels_set_current, levels_subdivide and the deletes call it.
levels_sync :: proc(l: ^Levels) {
	sync_levels(l, down = true)
}

// Phase 1 passes the edits down, level by level, as moves of the vertices below.
// Phase 2 re-encodes the detail of every vertex on the current level and below whose
// position or Loop point moved, so those levels decode to what they show (to within
// rounding: positions there are kept as they are). Phase 3 rebuilds the levels above
// the current one from their detail. Without `down`, only phase 3 runs. The current
// level itself does not move, so it needs no new normals or upload afterwards.
@(private)
sync_levels :: proc(l: ^Levels, down: bool) {
	k := l.current
	edited := &l.levels[k].sculptor.edited_nodes
	if len(edited) == 0 do return
	n := len(l.levels)
	changed := make([][]u32, n, context.temp_allocator) // per level: nodes whose vertices moved
	changed[k] = slice.clone(edited[:], context.temp_allocator)
	if down {
		for j := k; j >= 1; j -= 1 do changed[j - 1] = push_down(l, j, changed[j])
		for j in 1 ..= k do recode_level(l, j, with_dependents(l.levels[j], changed[j], changed[j - 1]), encode = true)
	}
	for j in k + 1 ..< n {
		changed[j] = with_dependents(l.levels[j], nil, changed[j - 1])
		recode_level(l, j, changed[j], encode = false)
	}
	for j in 0 ..< n {
		if j != k do sculptor_nodes_moved(&l.levels[j].sculptor, changed[j])
		sculptor_clear_edited(&l.levels[j].sculptor)
	}
}

// Shared by the push_down jobs.
@(private)
Push :: struct {
	fine, coarse: ^Level,
	base:         Loop_Base, // the coarse level's
	changed:      []u32,  // nodes of the fine level
	slot:         []u32,  // per fine node: where its vertices' residuals start, or NO_SLOT
	residual:     []Vec3, // per vertex of a changed node: its position minus its decoded position
	targets:      []u32,  // nodes of the coarse level that may move
	moved:        []bool, // per target
}

@(private)
NO_SLOT :: max(u32)

// Moves each vertex of level j-1 by half the change of the vertex it became on level j
// plus half the average change of that vertex's neighbours, where the change is how
// far the changed nodes of level j are from what level j-1 and their detail decode to.
// A move common to a whole area thus passes down in full and a single spike by half.
// Returns the nodes of level j-1 that moved.
@(private)
push_down :: proc(l: ^Levels, j: int, changed: []u32) -> []u32 {
	p := Push{fine = l.levels[j], coarse = l.levels[j - 1], changed = changed}
	p.base = level_base(p.coarse)
	fine_nodes := p.fine.sculptor.nodes
	p.slot = make([]u32, len(fine_nodes), context.temp_allocator)
	slice.fill(p.slot, NO_SLOT)
	total: u32
	for id in changed {
		p.slot[id] = total
		total += fine_nodes[id].vert_count
	}
	if int(total) > len(l.residual) do non_zero_resize(&l.residual, int(total))
	p.residual = l.residual[:total]
	pool := l.pool if total >= PARALLEL_MIN_VERTS else nil
	jobs.parallel_for(pool, len(changed), &p, proc(data: rawptr, i: int) {
		p := cast(^Push)data
		lv := p.fine
		n := lv.sculptor.nodes[p.changed[i]]
		out := p.residual[p.slot[p.changed[i]]:]
		for u in n.vert_first ..< n.vert_first + n.vert_count {
			out[u - n.vert_first] = lv.mesh.positions[u] - frame_point(frame_at(&p.base, lv.parents[u]), lv.detail[u])
		}
	})

	// A coarse vertex moves only if it became a changed vertex or one of their
	// neighbours, and every such vertex is among the parents of a changed vertex.
	listed := make([]bool, len(p.coarse.sculptor.nodes), context.temp_allocator)
	targets := make([dynamic]u32, 0, 4 * len(changed), context.temp_allocator)
	verts: u32
	for id in changed {
		for c in node_list(p.fine.deps, id) {
			if listed[c] do continue
			listed[c] = true
			append(&targets, c)
			verts += p.coarse.sculptor.nodes[c].vert_count
		}
	}
	p.targets = targets[:]
	p.moved = make([]bool, len(targets), context.temp_allocator)
	jobs.parallel_for(l.pool if verts >= PARALLEL_MIN_VERTS else nil, len(targets), &p, proc(data: rawptr, i: int) {
		p := cast(^Push)data
		fine := p.fine
		n := p.coarse.sculptor.nodes[p.targets[i]]
		moved := false
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			e := fine.even_of[v]
			// Around a vertex of a closed mesh, each neighbour comes first in one triangle.
			faces := geom.vertex_faces_of(fine.sculptor.faces, e)
			ring: Vec3
			for f in faces {
				o1, _ := others(fine.mesh.indices[:], f, e)
				ring += residual_at(p, o1)
			}
			delta := residual_at(p, e) * 0.5 + ring * (0.5 / f32(len(faces)))
			if delta == {} do continue
			p.coarse.mesh.positions[v] += delta
			moved = true
		}
		p.moved[i] = moved
	})
	out := make([dynamic]u32, 0, len(targets), context.temp_allocator)
	for id, i in targets do if p.moved[i] do append(&out, id)
	return out[:]
}

@(private)
residual_at :: #force_inline proc(p: ^Push, u: u32) -> Vec3 {
	id := p.fine.node_of_vertex[u]
	slot := p.slot[id]
	if slot == NO_SLOT do return {}
	return p.residual[slot + u - p.fine.sculptor.nodes[id].vert_first]
}

// `nodes`, plus the nodes of lv whose Loop points read a node of `below_nodes`, each once.
@(private)
with_dependents :: proc(lv: ^Level, nodes, below_nodes: []u32) -> []u32 {
	listed := make([]bool, len(lv.sculptor.nodes), context.temp_allocator)
	out := make([dynamic]u32, 0, len(nodes) + 4 * len(below_nodes), context.temp_allocator)
	for id in nodes {
		if listed[id] do continue
		listed[id] = true
		append(&out, id)
	}
	for c in below_nodes {
		for id in node_list(lv.dependents, c) {
			if listed[id] do continue
			listed[id] = true
			append(&out, id)
		}
	}
	return out[:]
}

// For every vertex of `nodes` on level j: with `encode`, stores its offset from its
// Loop point as its detail; without, moves it to where its detail puts it.
@(private)
recode_level :: proc(l: ^Levels, j: int, nodes: []u32, encode: bool) {
	Recode :: struct {
		lv:     ^Level,
		below:  Loop_Base,
		nodes:  []u32,
		encode: bool,
	}
	r := Recode{l.levels[j], level_base(l.levels[j - 1]), nodes, encode}
	verts: u32
	for id in nodes do verts += r.lv.sculptor.nodes[id].vert_count
	jobs.parallel_for(l.pool if verts >= PARALLEL_MIN_VERTS else nil, len(nodes), &r, proc(data: rawptr, i: int) {
		r := cast(^Recode)data
		lv := r.lv
		n := lv.sculptor.nodes[r.nodes[i]]
		for u in n.vert_first ..< n.vert_first + n.vert_count {
			f := frame_at(&r.below, lv.parents[u])
			if r.encode {
				off := lv.mesh.positions[u] - f.origin
				lv.detail[u] = {linalg.dot(f.t, off), linalg.dot(f.b, off), linalg.dot(f.n, off)}
			} else {
				lv.mesh.positions[u] = frame_point(f, lv.detail[u])
			}
		}
	})
}

// A point and orthonormal axes: normal n, tangent t, and b = n × t.
@(private)
Frame :: struct {
	origin, t, b, n: Vec3,
}

// The mesh Loop points and their frames are read from: the level below, or for HD
// detail a patch of a finer subdivision of the top level (hd.odin).
@(private)
Loop_Base :: struct {
	positions: []Vec3,
	indices:   []u32,
	faces:     geom.Vertex_Faces,
}

@(private)
level_base :: proc(lv: ^Level) -> Loop_Base {
	return {lv.mesh.positions[:], lv.mesh.indices[:], lv.sculptor.faces}
}

// Where Loop subdivision puts a vertex given its parents on the level below, with a
// frame there from the surface below: its normal, and a tangent along one of its edges.
// Never inlined, nor is frame_point, so every caller gets the same bits for the same
// inputs, whatever the compiler does around the call.
@(private)
frame_at :: #force_no_inline proc(below: ^Loop_Base, par: [4]u32) -> Frame {
	P := below.positions
	origin, normal, tangent: Vec3
	if par[2] == EVEN {
		v := par[0]
		p := P[v]
		ring: Vec3
		faces := geom.vertex_faces_of(below.faces, v)
		for f in faces {
			o1, o2 := others(below.indices, f, v)
			q1, q2 := P[o1], P[o2]
			ring += q1 + q2 // each neighbour twice
			normal += linalg.cross(q1 - p, q2 - p)
		}
		beta := loop_beta(len(faces))
		origin = p * (1 - f32(len(faces)) * beta) + ring * (0.5 * beta)
		tangent = P[par[1]] - p
	} else {
		a, b, c, d := P[par[0]], P[par[1]], P[par[2]], P[par[3]]
		origin = (a + b) * 0.375 + (c + d) * 0.125
		normal = linalg.cross(b - a, c - d)
		tangent = b - a
	}
	n := normal
	if len2 := linalg.dot(n, n); len2 > 1e-30 {
		n *= 1 / math.sqrt(len2)
	} else {
		n = {0, 0, 1}
	}
	t := tangent - n * linalg.dot(n, tangent)
	if len2 := linalg.dot(t, t); len2 > 1e-30 {
		t *= 1 / math.sqrt(len2)
	} else {
		t = linalg.normalize(linalg.cross(n, Vec3{1, 0, 0} if abs(n.x) < 0.9 else Vec3{0, 1, 0}))
	}
	return {origin, t, linalg.cross(n, t), n}
}

@(private)
frame_point :: #force_no_inline proc(f: Frame, d: Vec3) -> Vec3 {
	return f.origin + f.t * d.x + f.b * d.y + f.n * d.z
}

// Loop's weight for each neighbour of a vertex with `valence` neighbours.
@(private)
loop_beta :: proc(valence: int) -> f32 {
	if valence == 6 do return 1.0 / 16 // the regular case, exactly
	n := f64(valence)
	c := 0.375 + 0.25 * math.cos(2 * math.PI / n)
	return f32((0.625 - c * c) / n)
}

// The other two corners of triangle f, in order, so v, o1, o2 runs counter-clockwise.
@(private)
others :: #force_inline proc(indices: []u32, f, v: u32) -> (o1, o2: u32) {
	i0, i1, i2 := indices[3 * f], indices[3 * f + 1], indices[3 * f + 2]
	if v == i0 do return i1, i2
	if v == i1 do return i2, i0
	return i0, i1
}

// Which corner (0, 1 or 2) of triangle f is vertex v.
@(private)
corner_of :: #force_inline proc(indices: []u32, f, v: u32) -> u32 {
	if indices[3 * f] == v do return 0
	if indices[3 * f + 1] == v do return 1
	return 2
}

// One step of Loop subdivision of `below`: a vertex for each of its vertices and one on
// each edge, four triangles for each of its triangles, all with zero detail. Returns
// false for a mesh with an edge not shared by exactly two triangles, consistently
// oriented (an open or non-manifold mesh).
@(private)
level_above :: proc(l: ^Levels, below: ^Level) -> (^Level, bool) {
	Build :: struct {
		below:       ^Level,
		base:        Loop_Base, // below's
		edge_first:  []u32,    // per vertex below: its first edge; an edge is numbered at its lower end
		corner_edge: []u32,    // per triangle corner below: the edge from it to the next corner
		parents:     [][4]u32, // per new vertex, numbered as built: vertices below first, then edges
		mesh:        ^geom.Mesh,
		old_to_new:  []u32,    // from sculptor_init's renumbering of the new vertices
		parents_out: [][4]u32, // the new level's parents, renumbered
		detail_out:  []Vec3,
		bad:         bool,     // atomic: the mesh below is not closed and manifold
	}
	vcount, tcount := len(below.mesh.positions), len(below.mesh.indices) / 3
	b := Build{below = below, base = level_base(below)}
	b.edge_first = make([]u32, vcount + 1, context.temp_allocator)
	b.corner_edge = make([]u32, 3 * tcount, context.temp_allocator)

	// Each neighbour w > v of a vertex v gives an edge, in the order of v's triangles.
	jobs.parallel_ranges(l.pool, vcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		for v in u32(lo) ..< u32(hi) {
			count: u32
			for f in geom.vertex_faces_of(b.below.sculptor.faces, v) {
				o1, _ := others(b.below.mesh.indices[:], f, v)
				count += u32(o1 > v)
			}
			b.edge_first[v + 1] = count
		}
	}, geom.RANGE_GRAIN)
	for v in 0 ..< vcount do b.edge_first[v + 1] += b.edge_first[v]
	fine_count := vcount + int(b.edge_first[vcount])
	b.parents = make([][4]u32, fine_count, context.temp_allocator)

	jobs.parallel_ranges(l.pool, vcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		indices := b.below.mesh.indices[:]
		vcount := u32(len(b.below.mesh.positions))
		for v in u32(lo) ..< u32(hi) {
			faces := geom.vertex_faces_of(b.below.sculptor.faces, v)
			if len(faces) < 3 {
				sync.atomic_store(&b.bad, true)
				continue
			}
			first, _ := others(indices, faces[0], v)
			b.parents[v] = {v, first, EVEN, 0}
			next := b.edge_first[v]
			for f in faces {
				w, c := others(indices, f, v)
				// The triangle v-w-c must be the only one with v followed by w, and exactly
				// one other, w-v-d, must have w followed by v. Checked for every edge at
				// both ends, this rules out open and non-manifold meshes.
				d: u32
				same, twins := 0, 0
				for g in faces {
					g1, g2 := others(indices, g, v)
					same += int(g1 == w)
					if g2 == w {
						d = g1
						twins += 1
					}
				}
				if w == v || same != 1 || twins != 1 do sync.atomic_store(&b.bad, true)
				if w < v do continue
				b.corner_edge[3 * f + corner_of(indices, f, v)] = next
				b.parents[vcount + next] = {v, w, c, d}
				next += 1
			}
		}
	}, geom.RANGE_GRAIN)
	if sync.atomic_load(&b.bad) do return nil, false
	// The edges numbered at the other end.
	jobs.parallel_ranges(l.pool, vcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		indices := b.below.mesh.indices[:]
		for v in u32(lo) ..< u32(hi) {
			for f in geom.vertex_faces_of(b.below.sculptor.faces, v) {
				w, _ := others(indices, f, v)
				if w > v do continue
				for g in geom.vertex_faces_of(b.below.sculptor.faces, w) {
					if g1, _ := others(indices, g, w); g1 == v {
						b.corner_edge[3 * f + corner_of(indices, f, v)] = b.corner_edge[3 * g + corner_of(indices, g, w)]
						break
					}
				}
			}
		}
	}, geom.RANGE_GRAIN)

	lv := new(Level, l.allocator)
	m := &lv.mesh
	m.positions = make([dynamic]Vec3, fine_count, l.allocator)
	m.normals = make([dynamic]Vec3, fine_count, l.allocator)
	m.indices = make([dynamic]u32, 12 * tcount, l.allocator)
	b.mesh = m
	jobs.parallel_ranges(l.pool, fine_count, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		for i in lo ..< hi do b.mesh.positions[i] = frame_point(frame_at(&b.base, b.parents[i]), {})
	}, geom.RANGE_GRAIN)
	jobs.parallel_ranges(l.pool, tcount, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		indices := b.below.mesh.indices[:]
		vcount := u32(len(b.below.mesh.positions))
		for t in lo ..< hi {
			i0, i1, i2 := indices[3 * t], indices[3 * t + 1], indices[3 * t + 2]
			e01 := vcount + b.corner_edge[3 * t]
			e12 := vcount + b.corner_edge[3 * t + 1]
			e20 := vcount + b.corner_edge[3 * t + 2]
			out := b.mesh.indices[12 * t:]
			out[0], out[1], out[2] = i0, e01, e20
			out[3], out[4], out[5] = i1, e12, e01
			out[6], out[7], out[8] = i2, e20, e12
			out[9], out[10], out[11] = e01, e12, e20
		}
	}, geom.RANGE_GRAIN)

	old_to_new := make([]u32, fine_count, context.temp_allocator)
	sculptor_init(&lv.sculptor, m, l.pool, l.node_triangles, old_to_new, l.allocator)
	lv.parents = make([][4]u32, fine_count, l.allocator)
	lv.detail = make([]Vec3, fine_count, l.allocator)
	lv.even_of = make([]u32, vcount, l.allocator)
	b.old_to_new, b.parents_out, b.detail_out = old_to_new, lv.parents, lv.detail
	jobs.parallel_ranges(l.pool, fine_count, &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Build)data
		for i in lo ..< hi {
			b.parents_out[b.old_to_new[i]] = b.parents[i]
			// Already zero, but written so its pages are mapped now rather than during
			// the first syncs (see Levels.residual).
			b.detail_out[b.old_to_new[i]] = {}
		}
	}, geom.RANGE_GRAIN)
	copy(lv.even_of, old_to_new[:vcount])
	lv.node_of_vertex = node_of_vertex_build(&lv.sculptor, l.allocator)
	link_levels(l, below, lv)
	sculptor_recompute_all(&lv.sculptor)
	return lv, true
}

@(private)
node_of_vertex_build :: proc(s: ^Sculptor, allocator: runtime.Allocator) -> []u32 {
	Fill :: struct {
		s:   ^Sculptor,
		out: []u32,
	}
	f := Fill{s, make([]u32, len(s.mesh.positions), allocator)}
	jobs.parallel_for(s.pool, len(s.nodes), &f, proc(data: rawptr, id: int) {
		f := cast(^Fill)data
		n := f.s.nodes[id]
		slice.fill(f.out[n.vert_first:][:n.vert_count], u32(id))
	})
	return f.out
}

// Fills lv.deps and lv.dependents.
@(private)
link_levels :: proc(l: ^Levels, below, lv: ^Level) {
	Link :: struct {
		below, lv: ^Level,
		lists:     [][]u32,
		heap:      runtime.Allocator, // lists are made on worker threads
	}
	k := Link{below = below, lv = lv, heap = runtime.heap_allocator()}
	k.lists = make([][]u32, len(lv.sculptor.nodes), context.temp_allocator)
	jobs.parallel_for(l.pool, len(lv.sculptor.nodes), &k, proc(data: rawptr, id: int) {
		k := cast(^Link)data
		n := k.lv.sculptor.nodes[id]
		indices := k.below.mesh.indices[:]
		found := make([dynamic]u32, 0, 16, k.heap)
		last := NO_SLOT
		add :: #force_inline proc(found: ^[dynamic]u32, last: ^u32, node: u32) {
			if node == last^ do return // neighbouring vertices mostly share a node
			last^ = node
			if !slice.contains(found[:], node) do append(found, node)
		}
		for u in n.vert_first ..< n.vert_first + n.vert_count {
			par := k.lv.parents[u]
			if par[2] == EVEN {
				for f in geom.vertex_faces_of(k.below.sculptor.faces, par[0]) {
					for c in 0 ..< u32(3) do add(&found, &last, k.below.node_of_vertex[indices[3 * f + c]])
				}
			} else {
				for v in par do add(&found, &last, k.below.node_of_vertex[v])
			}
		}
		k.lists[id] = found[:]
	})
	lv.deps.offsets = make([]u32, len(k.lists) + 1, l.allocator)
	for list, id in k.lists do lv.deps.offsets[id + 1] = lv.deps.offsets[id] + u32(len(list))
	lv.deps.items = make([]u32, lv.deps.offsets[len(k.lists)], l.allocator)
	for list, id in k.lists {
		copy(lv.deps.items[lv.deps.offsets[id]:], list)
		delete(list, k.heap)
	}

	// The same pairs the other way round.
	below_nodes := len(below.sculptor.nodes)
	dep := &lv.dependents
	dep.offsets = make([]u32, below_nodes + 1, l.allocator)
	dep.items = make([]u32, len(lv.deps.items), l.allocator)
	for c in lv.deps.items do dep.offsets[c + 1] += 1
	for c in 0 ..< below_nodes do dep.offsets[c + 1] += dep.offsets[c]
	cursor := slice.clone(dep.offsets[:below_nodes], context.temp_allocator)
	for id in 0 ..< len(lv.sculptor.nodes) {
		for c in node_list(lv.deps, u32(id)) {
			dep.items[cursor[c]] = u32(id)
			cursor[c] += 1
		}
	}
}

@(private)
node_list :: #force_inline proc(nl: Node_Lists, id: u32) -> []u32 {
	return nl.items[nl.offsets[id]:nl.offsets[id + 1]]
}

@(private)
level_free :: proc(l: ^Levels, lv: ^Level) {
	sculptor_destroy(&lv.sculptor)
	geom.mesh_destroy(&lv.mesh)
	delete(lv.node_of_vertex, l.allocator)
	level_unlink(l, lv)
	free(lv, l.allocator)
}

// Drops what ties a level to the one below, when it becomes the base.
@(private)
level_unlink :: proc(l: ^Levels, lv: ^Level) {
	delete(lv.parents, l.allocator)
	delete(lv.detail, l.allocator)
	delete(lv.even_of, l.allocator)
	delete(lv.deps.offsets, l.allocator)
	delete(lv.deps.items, l.allocator)
	delete(lv.dependents.offsets, l.allocator)
	delete(lv.dependents.items, l.allocator)
	lv.parents, lv.detail, lv.even_of, lv.deps, lv.dependents = nil, nil, nil, {}, {}
}
