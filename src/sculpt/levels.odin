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
	// Under a Catmull-Clark rule, the level's own polygons and creases, which the level
	// above is made from (levels_cc.odin).
	polys:          Polys,
	sharp:          Sharp,
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
	faces:          Quad_Faces, // the base level's quads and UVs, for a retopologized object (levels_quads.odin)
	rule:           Subdivision_Rule, // how the levels above the base are made (levels_cc.odin)
	sets:           [dynamic]Selection_Set, // saved masks (selection_sets.odin)
	set_serial:     u32, // the last set id given
}

// parents[2] of a vertex that continues a vertex of the level below: {that vertex, a
// neighbour of it giving the tangent, EVEN, 0}. Other vertices sit on an edge a-b of
// the level below, between the triangles a-b-c and b-a-d: {a, b, c, d}.
@(private)
EVEN :: max(u32)

// Takes `mesh` as the base level and prepares it for sculpting (see sculptor_init,
// which renumbers the vertices and fills `old_to_new` when given one, and `tri_from`, per
// triangle its number before). With a `layout` that fits the mesh (see
// sculptor_init_laid_out), the mesh keeps its order instead. `progress` moves over its
// `share` as sculptor_init goes.
levels_init :: proc(l: ^Levels, mesh: geom.Mesh, pool: ^jobs.Pool, node_triangles: u32 = NODE_TRIANGLES, old_to_new: []u32 = nil, tri_from: []u32 = nil, allocator := context.allocator, layout: []Node_Sizes = nil, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}) {
	assert(tri_from == nil || len(tri_from) == len(mesh.indices) / 3)
	l.pool, l.node_triangles, l.allocator = pool, node_triangles, allocator
	l.levels = make([dynamic]^Level, 0, MAX_LEVELS, allocator)
	l.residual = make([dynamic]Vec3, allocator)
	l.sets = make([dynamic]Selection_Set, allocator)
	base := new(Level, allocator)
	base.mesh = mesh
	if layout != nil && sculptor_init_laid_out(&base.sculptor, &base.mesh, pool, layout, node_triangles, allocator) {
		for &v, i in old_to_new do v = u32(i)
		for &t, i in tri_from do t = u32(i)
	} else {
		sculptor_init(&base.sculptor, &base.mesh, pool, node_triangles, old_to_new, tri_from, allocator, progress, share)
	}
	base.node_of_vertex = node_of_vertex_build(&base.sculptor, allocator)
	append(&l.levels, base)
	l.current = 0
}

levels_destroy :: proc(l: ^Levels) {
	levels_drop_quads(l)
	levels_hd_delete(l)
	_ = levels_sets_clear(l)
	delete(l.sets)
	for lv in l.levels do level_free(l, lv)
	delete(l.levels)
	delete(l.residual)
	l^ = {}
}

// Gives the levels and every level's sculptor `pool` for their workers: levels prepared on
// a thread of its own, with its own pool, then taken by the frame thread.
levels_set_pool :: proc(l: ^Levels, pool: ^jobs.Pool) {
	l.pool = pool
	for lv in l.levels do lv.sculptor.pool = pool
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
	// A picked layer mask belongs to the level shown: the sculpt mask comes back first,
	// as the levels carry the sculpt mask between them.
	_ = sculptor_layer_mask_pick(&l.levels[l.current].sculptor, -1)
	levels_sync(l)
	levels_carry_mask(l, l.current, target)
	levels_carry_paint(l, target)
	l.current = target
}

// Carries the colours and groups of the current level to level `to` when they changed
// since it became current; otherwise every level keeps its own, so a look at a coarser
// level and back loses nothing.
@(private)
levels_carry_paint :: proc(l: ^Levels, to: int) {
	s := &l.levels[l.current].sculptor
	if s.color_edited do levels_carry_color(l, l.current, to)
	if s.groups.edited do levels_carry_groups(l, l.current, to)
	s.color_edited, s.groups.edited = false, false
}

// Brings the top level's colours and groups up to date with edits on the current one,
// for reading the top level (a bake) without leaving the current level. The edits stay
// marked, so a later change of level still carries them wherever it goes.
levels_paint_to_top :: proc(l: ^Levels) {levels_paint_to(l, len(l.levels) - 1)}

// levels_paint_to_top for level `to`: the base's groups, say, for the cage Edit cage
// takes from it.
levels_paint_to :: proc(l: ^Levels, to: int) {
	if l.current == to do return
	s := &l.levels[l.current].sculptor
	if s.color_edited do levels_carry_color(l, l.current, to)
	if s.groups.edited do levels_carry_groups(l, l.current, to)
}

// Adds a level above the top one and makes it current. Returns false, changing
// nothing, when MAX_LEVELS are in use, the top level is not a closed manifold mesh, or
// there is an HD level (whose detail is tied to the top level as it is). With
// `carry_layers`, the top level's sculpt layers move up to the new one
// (levels_carry_layers_up); that changes what the old top's undo steps refer to, so the
// caller clears the histories. Opening a file subdivides without.
levels_subdivide :: proc(l: ^Levels, carry_layers := false) -> bool {
	if !levels_can_subdivide(l) do return false
	levels_sync(l)
	lv, ok := levels_subdivide_build(l)
	if !ok do return false
	levels_subdivide_add(l, lv, carry_layers)
	return true
}

// Whether levels_subdivide may add a level: fewer than MAX_LEVELS, no HD level and no
// dynamic topology (the top level must also be closed and manifold, which only building
// the level finds out).
levels_can_subdivide :: proc(l: ^Levels) -> bool {
	return len(l.levels) < MAX_LEVELS && l.hd.steps == 0 && !levels_dynamic(l)
}

// The level levels_subdivide adds, built from the top level without changing the levels,
// so it can be built on a thread of its own while the levels are only read: with `pool`
// for its workers (the new level's sculptor then keeps the levels' own) and `progress` moved
// through the build's stages. Sync the levels and check levels_can_subdivide first. Returns
// nil and false for a top level that is not closed and manifold, or when the progress was
// cancelled, with what it made freed; levels_subdivide_add takes the level.
levels_subdivide_build :: proc(l: ^Levels, pool: ^jobs.Pool = nil, progress: ^jobs.Progress = nil) -> (^Level, bool) {
	// level_above reads only the rule, pool, allocator and node size of the levels.
	work := l^
	if pool != nil do work.pool = pool
	lv, ok := level_above(&work, l.levels[len(l.levels) - 1], progress)
	if !ok do return nil, false
	lv.sculptor.pool = l.pool
	if jobs.progress_cancelled(progress) {
		level_free(l, lv)
		return nil, false
	}
	jobs.progress_set(progress, 0, 1, 1)
	return lv, true
}

// Frees `lv`, from levels_subdivide_build on these levels, when it is not to be added.
levels_subdivide_discard :: proc(l: ^Levels, lv: ^Level) {
	if lv != nil do level_free(l, lv)
}

// Adds `lv`, from levels_subdivide_build on these levels, above the top level and makes it
// current, carrying the mask, colours and groups up (and the top level's sculpt layers,
// with `carry_layers`, as levels_subdivide says).
levels_subdivide_add :: proc(l: ^Levels, lv: ^Level, carry_layers := false) {
	append(&l.levels, lv)
	levels_carry_mask(l, l.current, len(l.levels) - 1)
	// The new level takes its colours and groups from the one below, once that has the
	// current level's.
	top := len(l.levels) - 2
	levels_carry_paint(l, top)
	levels_carry_color(l, top, top + 1)
	levels_carry_groups(l, top, top + 1)
	if carry_layers do _ = levels_carry_layers_up(l)
	l.current = len(l.levels) - 1
}

// Turns dynamic topology (dyntopo.odin) on for the only level. Returns false, changing
// nothing, when there are other levels or an HD level, or the mesh has a vertex in more
// than DYN_FACES triangles. Clears the undo history, and drops the selection sets, since
// it renumbers the vertices they are kept by.
levels_dyn_enable :: proc(l: ^Levels) -> bool {
	if len(l.levels) != 1 || l.hd.steps > 0 do return false
	lv := l.levels[0]
	if !sculptor_dyn_enable(&lv.sculptor, l.allocator) do return false
	levels_drop_quads(l) // its edits change the base's triangles
	// So do its polygons: the levels made later are Loop's.
	polys_destroy(&lv.polys, l.allocator)
	sharp_destroy(&lv.sharp, l.allocator)
	l.rule = .Loop
	_ = levels_sets_clear(l)
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

// Vertices, triangles and CPU bytes of the level levels_subdivide would add. The top
// level's sculpt layers move up with it, each about four times the size on a level of
// four times the triangles.
levels_subdivide_estimate :: proc(l: ^Levels) -> (vertices, triangles, bytes: int) {
	top := l.levels[len(l.levels) - 1]
	v, t := len(top.mesh.positions), len(top.mesh.indices) / 3
	vertices, triangles = v + 3 * t / 2, 4 * t // a closed mesh has 3/2 edges per triangle
	// Catmull-Clark: a point per edge (half a corner each) and per polygon, two
	// triangles per corner.
	if p := &top.polys; l.rule != .Loop && p.first != nil do vertices, triangles = v + len(p.corners) / 2 + len(p.first) - 1, 2 * len(p.corners)
	return vertices, triangles, level_estimate_bytes(vertices, triangles, v) + 4 * sculptor_layers_bytes(&top.sculptor)
}

// CPU bytes of a level of that many vertices and triangles over a level of `below`
// vertices. Per vertex: position, normal, face list offset, owner node, parents,
// detail. Per triangle: indices, face list entries, BVH order and leaf, simplified
// copies. Per vertex below: the vertex it became.
level_estimate_bytes :: proc(vertices, triangles, below: int) -> int {
	return vertices * (12 + 12 + 4 + 4 + 16 + 12) + triangles * (12 + 12 + 8 + 5) + below * 4
}

// Deletes every level above the current one, and with the top level any HD level. The
// selection sets kept by those levels are carried down to the current one, and so are
// their sculpt layers (levels_carry_layers_down): returns how many layers it carried and
// how many went for want of room.
levels_delete_higher :: proc(l: ^Levels) -> (carried, dropped: int) {
	assert(l.hd.window == nil, "leave the HD window first")
	levels_sets_carry(l, {l.current + 1, len(l.levels)}, l.current)
	carried, dropped = levels_carry_layers_down(l)
	if len(l.levels) > l.current + 1 do levels_hd_delete(l)
	for len(l.levels) > l.current + 1 do level_free(l, pop(&l.levels))
	levels_sync(l)
	return
}

// Deletes every level below the current one, which becomes the base. The selection
// sets kept by those levels are carried up to it first.
levels_delete_lower :: proc(l: ^Levels) {
	assert(l.hd.window == nil, "leave the HD window first")
	k := l.current
	if k == 0 do return
	sync_levels(l, down = false)
	levels_sets_carry(l, {0, k}, k)
	for &set in l.sets do set.level -= k
	levels_drop_quads(l) // the base's triangles are a level above's now
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
	return total + hd.stored_bytes + hd.window_bytes + levels_sets_bytes(l)
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
	total += (len(s.morph) + len(s.recall)) * size_of(Vec3)
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
		if j != k && len(changed[j]) > 0 {
			sculptor_nodes_moved(&l.levels[j].sculptor, changed[j])
			history_seal(&l.levels[j].sculptor.history)
		}
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
	p.base = level_base(p.coarse, l.rule)
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
	r := Recode{l.levels[j], level_base(l.levels[j - 1], l.rule), nodes, encode}
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
	// Under a Catmull-Clark rule, the level's polygons (nil for Loop, and for HD, which
	// stays Loop), each triangle's polygon, and its creases.
	polys:     ^Polys,
	tri_poly:  []u32,
	sharp:     ^Sharp,
	rule:      Subdivision_Rule,
}

@(private)
level_base :: proc(lv: ^Level, rule := Subdivision_Rule.Loop) -> Loop_Base {
	if rule == .Loop || lv.polys.first == nil do return {positions = lv.mesh.positions[:], indices = lv.mesh.indices[:], faces = lv.sculptor.faces}
	return {lv.mesh.positions[:], lv.mesh.indices[:], lv.sculptor.faces, &lv.polys, lv.polys.tri_poly, &lv.sharp, rule}
}

// Where Loop subdivision puts a vertex given its parents on the level below, with a
// frame there from the surface below: its normal, and a tangent along one of its edges.
// Never inlined, nor is frame_point, so every caller gets the same bits for the same
// inputs, whatever the compiler does around the call.
@(private)
frame_at :: #force_no_inline proc(below: ^Loop_Base, par: [4]u32) -> Frame {
	if below.polys != nil do return frame_cc(below, par)
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
	return frame_make(origin, normal, tangent)
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
// oriented (an open or non-manifold mesh), and when `progress` was cancelled (checked
// between the stages, each moving it a share measured at 2.5M vertices below, in a release build).
@(private)
level_above :: proc(l: ^Levels, below: ^Level, progress: ^jobs.Progress = nil) -> (^Level, bool) {
	// A Catmull-Clark step moves the progress only when it is done.
	if l.rule != .Loop && below.polys.first != nil do return level_above_cc(l, below)
	STAGES :: [?]f32{0, 0.01, 0.04, 0.06, 0.09, 0.10, 0.82, 0.93, 0.95, 0.97, 1}
	stage := 0
	next :: proc(progress: ^jobs.Progress, stage: ^int) -> bool {
		stages := STAGES
		stage^ += 1
		jobs.progress_set(progress, 0, 1, stages[stage^])
		return !jobs.progress_cancelled(progress)
	}
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
	if !next(progress, &stage) do return nil, false
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
	if sync.atomic_load(&b.bad) || !next(progress, &stage) do return nil, false
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
	if !next(progress, &stage) do return nil, false

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
	_ = next(progress, &stage)
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
	if !next(progress, &stage) {
		geom.mesh_destroy(m)
		free(lv, l.allocator)
		return nil, false
	}

	old_to_new := make([]u32, fine_count, context.temp_allocator)
	{
		stages := STAGES
		sculptor_init(&lv.sculptor, m, l.pool, l.node_triangles, old_to_new, allocator = l.allocator, progress = progress, share = {stages[stage], stages[stage + 1]})
	}
	if !next(progress, &stage) {
		level_free(l, lv)
		return nil, false
	}
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
	_ = next(progress, &stage)
	lv.node_of_vertex = node_of_vertex_build(&lv.sculptor, l.allocator)
	_ = next(progress, &stage)
	link_levels(l, below, lv)
	_ = next(progress, &stage)
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
		polys:     ^Polys, // below's, under a Catmull-Clark rule
	}
	k := Link{below = below, lv = lv, heap = runtime.heap_allocator(), polys = &below.polys if l.rule != .Loop && below.polys.first != nil else nil}
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
			// A Catmull-Clark point reads every corner of the polygons it is made from,
			// a quad's far corner too, which is in no triangle at the vertex.
			if p := k.polys; p != nil {
				switch par[2] {
				case EVEN:
					for f in geom.vertex_faces_of(k.below.sculptor.faces, par[0]) {
						for v in poly_corners(p, p.tri_poly[f]) do add(&found, &last, k.below.node_of_vertex[v])
					}
				case FACE:
					for v in poly_corners(p, par[3]) do add(&found, &last, k.below.node_of_vertex[v])
				case:
					for v in poly_corners(p, par[2]) do add(&found, &last, k.below.node_of_vertex[v])
					for v in poly_corners(p, par[3]) do add(&found, &last, k.below.node_of_vertex[v])
				}
				continue
			}
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
	polys_destroy(&lv.polys, l.allocator)
	sharp_destroy(&lv.sharp, l.allocator)
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
