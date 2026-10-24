// Package sculpt applies brush strokes to a geom.Mesh. It knows nothing about the GPU
// or the UI: callers pass rays and brush settings in, and read back which vertex
// ranges changed so they can upload just those.
//
// The mesh is partitioned into nodes (the leaves of a coarse BVH, a few hundred to a
// thousand triangles each). Vertices are renumbered so each node owns one contiguous
// vertex range, which gives three things at once:
//   - a dab touches only the nodes its sphere overlaps, scanning their vertices linearly;
//   - nodes are independent units of parallel work, since each vertex has one owner;
//   - GPU updates are per-node contiguous ranges, not one wide dirty span.
package sculpt

import "base:runtime"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"

Vec3 :: geom.Vec3

NODE_TRIANGLES :: 1024
// Below this many candidate vertices a dab runs on the calling thread: waking workers
// costs more than the work itself.
PARALLEL_MIN_VERTS :: 2048
// Largest node whose face normals job_node_normals caches on the stack (48 KB).
MAX_CACHED_FACES :: 4096
// Normal cones held back during a stroke that a flush works out once the stroke has
// ended; the rest wait for the next flushes, so the frame a long stroke ends in stays
// short. Until then those chunks are just never back-face culled.
CONE_BATCH :: 512

Brush_Kind :: enum {
	Draw,    // push the surface out along the local average normal (inverted pulls in)
	Smooth,  // move vertices toward the average of their neighbours
	Clay,    // build up toward a plane just above the surface, filling dips first (inverted digs)
	Flatten, // pull toward the plane through the surface under the brush (inverted pushes away)
	Inflate, // push each vertex out along its own normal (inverted deflates)
	Pinch,   // pull along the surface toward the centre (inverted pushes away)
	Crease,  // cut a sharp groove: draw in with a narrow falloff and pinch (inverted: a ridge)
	Grab,    // drag what is under the brush with the pointer: sculptor_grab_begin and _move
	Mask,    // paint the mask, which shields vertices from every other brush (inverted erases)
}

Axis :: enum u8 {
	X,
	Y,
	Z,
}

// Planes through the origin of the mesh's space that dabs are mirrored across.
Symmetry :: bit_set[Axis;u8]

Brush :: struct {
	kind:     Brush_Kind,
	radius:   f32, // world units
	strength: f32, // 0..1
	invert:   bool,
	symmetry: Symmetry,
}

// How far dabs move the surface at full strength, in brush radii.
DRAW_HEIGHT :: 0.1
CLAY_HEIGHT :: 0.08 // where Clay's plane sits above the surface
// Share of the way to the target that Clay, Flatten and Pinch go per dab at full strength.
PLANE_RATE :: 0.5
PINCH_RATE :: 0.25
CREASE_PINCH :: 0.2

Node :: struct {
	tri_first:    u32, // triangles of this node (a BVH leaf), contiguous
	tri_count:    u32,
	vert_first:   u32, // owned vertices: the contiguous range this node alone writes
	vert_count:   u32,
	shared_first: u32, // into Sculptor.shared: vertices of this node's triangles owned by other nodes
	shared_count: u32,
	owner_first:  u32, // into Sculptor.owners: the nodes owning those shared vertices
	owner_count:  u32,
	leaf:         u32, // this node's BVH leaf
}

Vertex_Range :: geom.Vertex_Range

// How much of a node sculptor_flush has to bring up to date.
@(private)
Stale :: enum u8 {
	None,
	Paint, // only its mask changed: nothing to recompute, just its GPU data
	Edge,  // a neighbour's triangles moved: the normals of its vertices on that border
	Shape, // its own triangles moved: all its normals, its bounds and its normal cone
}

// Per-hit-leaf results of one dab phase, reduced on the calling thread.
@(private)
Partial :: struct {
	normal_sum: Vec3,
	center_sum: Vec3, // falloff-weighted positions inside the brush, and their weight
	weight_sum: f32,
	bounds:     geom.Aabb, // of the owned vertices after the move
	moved:      u32,  // owned vertices moved (or, for Mask, whose mask changed)
	touched:    bool, // a shared vertex lies inside the brush, so it moves too
}

Sculptor :: struct {
	mesh:        ^geom.Mesh,
	pool:        ^jobs.Pool,
	faces:       geom.Vertex_Faces,
	bvh:         geom.Bvh,
	nodes:       []Node, // indexed by node id
	// Per node id, in index-buffer order: bounds and normal cone for view culling.
	// Kept current by sculptor_flush for every node it reports as changed, except that
	// during a stroke a changed node's cone is left open (never back-face culled) and
	// computed once the stroke ends.
	chunks:      []geom.Chunk,
	node_of:     []u32,  // BVH node index -> node id (only meaningful for leaves)
	shared:      [dynamic]u32,
	owners:      [dynamic]u32,

	// Per-dab scratch, reused.
	hit:         [dynamic]u32, // BVH leaves overlapping the brush
	changed:     [dynamic]u32, // hit leaves with a moved vertex
	partials:    [dynamic]Partial,
	offsets:     [dynamic]u32, // per hit leaf: start of its slots in smooth_to
	smooth_to:   [dynamic]Vec3,

	// Nodes whose vertex normals and GPU data are stale since the last sculptor_flush,
	// and how stale each node is.
	stale:       []Stale,
	dirty_nodes: [dynamic]u32,
	// Nodes whose normal cone waits for the end of the stroke.
	cone_waiting: []bool,
	waiting_cones: [dynamic]u32,
	ranges:      [dynamic]Vertex_Range,
	// Box around everything the last sculptor_flush reported as changed, before and
	// after the change (AABB_EMPTY when nothing changed), for partial redraws.
	changed_bounds: geom.Aabb,
	// Nodes whose triangles moved since sculptor_clear_edited last emptied the list:
	// what subdivision levels still have to carry to the levels above and below.
	edited:       []bool,
	edited_nodes: [dynamic]u32,

	history:     Undo_History,
	// Simplified copies for drawing while the view moves (lod.odin).
	lod:         Lod_State,
	// Per vertex: how far brushes move it, from 0 (not at all: an HD window's border,
	// which meets the level drawn around it) to 255 (fully); nil when all move fully.
	fade:        []u8,
	// Per vertex: how masked it is, from 0 (not at all) to 255 (brushes leave it alone);
	// nil until something is first masked (mask.odin).
	mask:        []u8,
	grab:        Grab, // the vertices a Grab stroke drags (grab.odin)
}

// Partitions and renumbers `mesh` in place (vertex order and triangle order change),
// then builds the acceleration structures. Upload the mesh to the GPU after this.
// With `old_to_new` (one entry per vertex), it receives each vertex's new number.
sculptor_init :: proc(s: ^Sculptor, mesh: ^geom.Mesh, pool: ^jobs.Pool, node_triangles: u32 = NODE_TRIANGLES, old_to_new: []u32 = nil, allocator := context.allocator) {
	s.mesh = mesh
	s.pool = pool
	s.bvh = geom.bvh_build_morton(mesh^, node_triangles, pool, allocator)
	reorder_by_nodes(s, old_to_new, allocator)
	s.faces = geom.vertex_faces_build(mesh^, pool, allocator)
	s.hit = make([dynamic]u32, 0, 256, allocator)
	s.changed = make([dynamic]u32, 0, 256, allocator)
	s.partials = make([dynamic]Partial, 0, 256, allocator)
	s.offsets = make([dynamic]u32, 0, 256, allocator)
	s.smooth_to = make([dynamic]Vec3, 0, 16384, allocator)
	s.stale = make([]Stale, len(s.nodes), allocator)
	s.dirty_nodes = make([dynamic]u32, 0, 256, allocator)
	s.cone_waiting = make([]bool, len(s.nodes), allocator)
	s.waiting_cones = make([dynamic]u32, 0, 256, allocator)
	s.ranges = make([dynamic]Vertex_Range, 0, 256, allocator)
	s.edited = make([]bool, len(s.nodes), allocator)
	s.edited_nodes = make([dynamic]u32, 0, 256, allocator)
	history_init(&s.history, len(s.nodes), allocator)
	s.changed_bounds = geom.AABB_EMPTY
	s.chunks = make([]geom.Chunk, len(s.nodes), allocator)
	jobs.parallel_for(s.pool, len(s.nodes), s, proc(data: rawptr, id: int) {
		update_chunk(cast(^Sculptor)data, u32(id), nil)
	})
	lod_init(s, allocator = allocator)
}

sculptor_destroy :: proc(s: ^Sculptor) {
	delete(s.mask, s.history.allocator)
	grab_destroy(&s.grab)
	history_destroy(&s.history)
	geom.vertex_faces_destroy(&s.faces)
	geom.bvh_destroy(&s.bvh)
	delete(s.nodes)
	delete(s.chunks)
	delete(s.node_of)
	delete(s.shared)
	delete(s.owners)
	delete(s.hit)
	delete(s.changed)
	delete(s.partials)
	delete(s.offsets)
	delete(s.smooth_to)
	delete(s.stale)
	delete(s.dirty_nodes)
	delete(s.cone_waiting)
	delete(s.waiting_cones)
	delete(s.ranges)
	delete(s.edited)
	delete(s.edited_nodes)
	lod_destroy(&s.lod)
	delete(s.fade)
	s^ = {}
}

// Reorders triangles so each BVH leaf's triangles are contiguous, then renumbers
// vertices so each leaf owns a contiguous vertex range. A vertex used by several
// leaves is owned by the one with the lowest node id; the others list it as shared.
// Every step is parallel over triangles, vertices or nodes.
@(private)
reorder_by_nodes :: proc(s: ^Sculptor, old_to_new: []u32, allocator := context.allocator) {
	Reorder :: struct {
		s:           ^Sculptor,
		leaves:      []u32,   // node id -> BVH leaf
		indices:     [dynamic]u32,  // triangles in node order (replaces the mesh's)
		positions:   [dynamic]Vec3, // vertex data in new numbering (replaces the mesh's)
		normals:     [dynamic]Vec3,
		unique:      [][]u32, // per node: distinct old vertices of its triangles
		owner:       []u32,   // per old vertex: lowest node id using it
		old_to_new:  []u32,
		shared:      [][]u32, // per node: new indices of shared vertices
		owners:      [][]u32, // per node: owner node ids of those, deduplicated
		// Per-node lists are made and freed on different threads, so they use the
		// thread-safe heap rather than whatever allocator each thread's context has.
		heap:        runtime.Allocator,
	}
	m := s.mesh
	b := &s.bvh
	tcount := len(m.indices) / 3
	vcount := len(m.positions)
	r := Reorder {
		s           = s,
		heap        = runtime.heap_allocator(),
		indices     = make([dynamic]u32, len(m.indices), m.indices.allocator),
		owner       = make([]u32, vcount, context.temp_allocator),
		old_to_new  = make([]u32, vcount, context.temp_allocator),
	}

	// Triangles: position k in tri_order becomes triangle k.
	jobs.parallel_ranges(s.pool, tcount, &r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Reorder)data
		m, b := r.s.mesh, &r.s.bvh
		for k in lo ..< hi {
			t := b.tri_order[k]
			r.indices[3 * k + 0] = m.indices[3 * t + 0]
			r.indices[3 * k + 1] = m.indices[3 * t + 1]
			r.indices[3 * k + 2] = m.indices[3 * t + 2]
			b.tri_order[k] = u32(k)
		}
	}, geom.RANGE_GRAIN)
	delete(m.indices)
	m.indices = r.indices

	// Leaves in triangle order, so node ids follow memory order.
	leaves := make([dynamic]u32, 0, tcount / int(b.leaf_size) + 1, context.temp_allocator)
	for node, i in b.nodes {
		if node.count > 0 do append(&leaves, u32(i))
	}
	sort_leaves_by_first(b, leaves[:])
	r.leaves = leaves[:]
	nodes := len(leaves)
	s.nodes = make([]Node, nodes, allocator)
	s.node_of = make([]u32, len(b.nodes), allocator)
	for &x in s.node_of do x = geom.BVH_NONE
	for leaf, id in leaves {
		s.node_of[leaf] = u32(id)
		s.nodes[id] = {tri_first = b.nodes[leaf].first, tri_count = b.nodes[leaf].count, leaf = leaf}
	}
	for &x in r.owner do x = geom.BVH_NONE
	r.unique = make([][]u32, nodes, context.temp_allocator)
	r.shared = make([][]u32, nodes, context.temp_allocator)
	r.owners = make([][]u32, nodes, context.temp_allocator)

	// Each node's distinct vertices in order of first use; the lowest node id claims
	// each vertex.
	jobs.parallel_for(s.pool, nodes, &r, proc(data: rawptr, id: int) {
		r := cast(^Reorder)data
		s := r.s
		n := s.nodes[id]
		corners := s.mesh.indices[3 * n.tri_first:][:3 * n.tri_count]
		r.unique[id] = distinct_in_order(corners, r.heap)
		for k in n.tri_first ..< n.tri_first + n.tri_count do s.bvh.tri_leaf[k] = r.leaves[id]
		for v in r.unique[id] do atomic_min_u32(&r.owner[v], u32(id))
	})
	jobs.parallel_for(s.pool, nodes, &r, proc(data: rawptr, id: int) {
		r := cast(^Reorder)data
		count: u32
		for v in r.unique[id] do count += u32(r.owner[v] == u32(id))
		r.s.nodes[id].vert_count = count
	})
	next: u32
	for &n in s.nodes {
		n.vert_first = next
		next += n.vert_count
	}
	assert(int(next) == vcount, "mesh has vertices no triangle uses")
	jobs.parallel_for(s.pool, nodes, &r, proc(data: rawptr, id: int) {
		r := cast(^Reorder)data
		next := r.s.nodes[id].vert_first
		for v in r.unique[id] {
			if r.owner[v] != u32(id) do continue
			r.old_to_new[v] = next
			next += 1
		}
	})
	// Shared vertices in new numbering, and the nodes owning them.
	jobs.parallel_for(s.pool, nodes, &r, proc(data: rawptr, id: int) {
		r := cast(^Reorder)data
		shared := make([dynamic]u32, 0, 64, r.heap)
		owners := make([dynamic]u32, 0, 8, r.heap)
		for v in r.unique[id] {
			owner := r.owner[v]
			if owner == u32(id) do continue
			append(&shared, r.old_to_new[v])
			if !slice.contains(owners[:], owner) do append(&owners, owner)
		}
		delete(r.unique[id], r.heap)
		r.shared[id], r.owners[id] = shared[:], owners[:]
	})
	shared_total, owners_total := 0, 0
	for id in 0 ..< nodes {
		shared_total += len(r.shared[id])
		owners_total += len(r.owners[id])
	}
	s.shared = make([dynamic]u32, 0, shared_total, allocator)
	s.owners = make([dynamic]u32, 0, owners_total, allocator)
	for &n, id in s.nodes {
		n.shared_first, n.shared_count = u32(len(s.shared)), u32(len(r.shared[id]))
		n.owner_first, n.owner_count = u32(len(s.owners)), u32(len(r.owners[id]))
		append(&s.shared, ..r.shared[id])
		append(&s.owners, ..r.owners[id])
		delete(r.shared[id], r.heap)
		delete(r.owners[id], r.heap)
	}

	// Move vertex data to the new numbering and remap the triangles.
	// Fresh arrays rather than copies of the old ones: the threads fill them directly.
	r.positions = make([dynamic]Vec3, vcount, m.positions.allocator)
	r.normals = make([dynamic]Vec3, vcount, m.normals.allocator)
	jobs.parallel_ranges(s.pool, vcount, &r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Reorder)data
		m := r.s.mesh
		for old in lo ..< hi {
			new_index := r.old_to_new[old]
			r.positions[new_index] = m.positions[old]
			r.normals[new_index] = m.normals[old]
		}
	}, geom.RANGE_GRAIN)
	delete(m.positions)
	delete(m.normals)
	m.positions, m.normals = r.positions, r.normals
	jobs.parallel_ranges(s.pool, len(m.indices), &r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Reorder)data
		for &i in r.s.mesh.indices[lo:hi] do i = r.old_to_new[i]
	}, geom.RANGE_GRAIN)
	if old_to_new != nil do copy(old_to_new, r.old_to_new)
}

@(private)
sort_leaves_by_first :: proc(b: ^geom.Bvh, leaves: []u32) {
	Keyed :: struct {
		first: u32,
		leaf:  u32,
	}
	keyed := make([]Keyed, len(leaves), context.temp_allocator)
	for leaf, i in leaves do keyed[i] = {b.nodes[leaf].first, leaf}
	slice.sort_by_key(keyed, proc(k: Keyed) -> u32 {return k.first})
	for k, i in keyed do leaves[i] = k.leaf
}

// Distinct values of `values` in order of first appearance, using an open-addressing
// set (sorting a few thousand values per node is several times slower).
@(private)
distinct_in_order :: proc(values: []u32, allocator: runtime.Allocator) -> []u32 {
	EMPTY :: max(u32)
	size := 64
	for size < 2 * len(values) do size *= 2
	stack: [8192]u32 = ---
	table := stack[:size] if size <= len(stack) else make([]u32, size, allocator)
	defer if size > len(stack) do delete(table, allocator)
	slice.fill(table, EMPTY)
	out := make([dynamic]u32, 0, len(values) / 2 + 16, allocator)
	for v in values {
		slot := int((v * 0x9E3779B1) >> 7) & (size - 1)
		for table[slot] != EMPTY && table[slot] != v do slot = (slot + 1) & (size - 1)
		if table[slot] == EMPTY {
			table[slot] = v
			append(&out, v)
		}
	}
	return out[:]
}

@(private)
atomic_min_u32 :: proc(p: ^u32, v: u32) {
	current := sync.atomic_load(p)
	for v < current {
		ok: bool
		if current, ok = sync.atomic_compare_exchange_weak(p, current, v); ok do return
	}
}

// Node owning vertex v: binary search over the nodes' contiguous ranges.
@(private)
owner_node :: proc(nodes: []Node, v: u32) -> u32 {
	lo, hi := 0, len(nodes) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if nodes[mid].vert_first <= v {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return u32(lo)
}

// Finishes the deferred work of every dab since the last call, then returns the vertex
// ranges whose positions or normals changed, coalesced and sorted. Call once per frame
// before uploading; the slice is valid until the next call.
//
// Vertex normals are recomputed here rather than per dab: a fast stroke lands several
// overlapping dabs per frame, and each region's normals only need computing once.
// Normal cones, which only back-face culling uses, wait for the end of a stroke: until
// then a changed chunk is never back-face culled, which costs the GPU little since the
// brush works on what faces the camera.
sculptor_flush :: proc(s: ^Sculptor) -> []Vertex_Range {
	clear(&s.ranges)
	s.changed_bounds = geom.AABB_EMPTY
	if len(s.dirty_nodes) > 0 {
		slice.sort(s.dirty_nodes[:])
		for id in s.dirty_nodes do s.changed_bounds = geom.aabb_union(s.changed_bounds, s.chunks[id].bounds)
		if s.history.recording {
			for id in s.dirty_nodes {
				if s.stale[id] != .Shape || s.cone_waiting[id] do continue
				s.cone_waiting[id] = true
				append(&s.waiting_cones, id)
			}
		}
		verts: u32
		for id in s.dirty_nodes do verts += s.nodes[id].vert_count
		jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.dirty_nodes), s, job_node_normals)
	}
	if !s.history.recording && len(s.waiting_cones) > 0 {
		count := min(len(s.waiting_cones), CONE_BATCH)
		jobs.parallel_for(s.pool, count, s, job_waiting_cone)
		for id in s.waiting_cones[len(s.waiting_cones) - count:] do s.cone_waiting[id] = false
		resize(&s.waiting_cones, len(s.waiting_cones) - count)
	}

	for id in s.dirty_nodes {
		s.changed_bounds = geom.aabb_union(s.changed_bounds, s.chunks[id].bounds)
		s.stale[id] = .None
		n := s.nodes[id]
		if len(s.ranges) > 0 {
			last := &s.ranges[len(s.ranges) - 1]
			if last.first + last.count == n.vert_first {
				last.count += n.vert_count
				continue
			}
		}
		append(&s.ranges, Vertex_Range{n.vert_first, n.vert_count})
	}
	clear(&s.dirty_nodes)
	return s.ranges[:]
}

// Smooth bump over the squared distance from the centre in radii: 1 at the centre, 0
// at the rim, zero slope at both ends. Taking the squared distance spares a square
// root per vertex.
falloff :: #force_inline proc(x2: f32) -> f32 {
	if x2 >= 1 do return 0
	t := 1 - x2
	return t * t
}

// Everything a dab phase needs, shared read-only by the worker threads.
@(private)
Dab :: struct {
	s:        ^Sculptor,
	brush:    Brush,
	center:   Vec3,
	r2:       f32,
	inv_r2:   f32,
	normal:   Vec3, // area normal: the falloff-weighted normals inside the brush
	plane:    Vec3, // Clay, Flatten: a point on the plane they pull toward
	amount:   f32,  // signed: displacement at the centre (Draw, Inflate, Crease), plane
	                // side (Clay), direction (Flatten, Pinch), or mask added (Mask)
}

// Applies one dab centred on `center`, and its mirror images across the brush's
// symmetry planes. Returns how many vertices moved (for Mask: how many changed their
// mask). Positions and BVH bounds are current when it returns; vertex normals catch up
// in sculptor_flush. Grab strokes go through sculptor_grab_begin instead.
apply_dab :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> int {
	if brush.kind == .Grab do return 0
	moved := 0
	for sign in mirrors(brush.symmetry) do moved += dab_once(s, brush, center * sign)
	return moved
}

// The sign flips that take a point to its mirror images: {1, 1, 1} first, then one
// for each combination of the planes in `symmetry`.
mirrors :: proc(symmetry: Symmetry) -> (signs: [dynamic; 8]Vec3) {
	append(&signs, Vec3{1, 1, 1})
	for axis in Axis {
		if axis not_in symmetry do continue
		count := len(signs)
		for k in 0 ..< count {
			flipped := signs[k]
			flipped[int(axis)] = -flipped[int(axis)]
			append(&signs, flipped)
		}
	}
	return
}

// How much brushes may move vertex v: its HD fade and what the mask leaves of it.
@(private)
shield :: #force_inline proc(fade, mask: []u8, v: u32) -> f32 {
	w: f32 = 1
	if fade != nil do w = f32(fade[v]) * (1.0 / 255)
	if mask != nil do w *= f32(255 - mask[v]) * (1.0 / 255)
	return w
}

@(private)
dab_once :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> int {
	d := Dab {
		s      = s,
		brush  = brush,
		center = center,
		r2     = brush.radius * brush.radius,
		inv_r2 = 1 / (brush.radius * brush.radius),
	}
	clear(&s.hit)
	geom.bvh_query_leaves(&s.bvh, center, brush.radius, &s.hit)
	if len(s.hit) == 0 do return 0
	resize(&s.partials, len(s.hit))
	slice.zero(s.partials[:])
	candidates: u32
	for leaf in s.hit do candidates += s.nodes[s.node_of[leaf]].vert_count
	pool := s.pool if candidates >= PARALLEL_MIN_VERTS else nil
	if brush.kind == .Mask do return mask_dab(s, &d, pool)
	if s.history.recording do record_hit(s, masks = false)

	sign: f32 = -1 if brush.invert else 1
	if brush.kind != .Smooth {
		jobs.parallel_for(pool, len(s.hit), &d, job_area)
		weight: f32
		for p in s.partials {
			d.normal += p.normal_sum
			d.plane += p.center_sum
			weight += p.weight_sum
		}
		d.normal = linalg.normalize0(d.normal)
		if weight > 0 do d.plane /= weight
	}
	switch brush.kind {
	case .Draw:
		d.amount = sign * brush.radius * brush.strength * DRAW_HEIGHT
		jobs.parallel_for(pool, len(s.hit), &d, job_draw)
	case .Inflate:
		d.amount = sign * brush.radius * brush.strength * DRAW_HEIGHT
		jobs.parallel_for(pool, len(s.hit), &d, job_inflate)
	case .Clay:
		d.amount = sign
		d.plane += d.normal * (sign * brush.radius * CLAY_HEIGHT)
		jobs.parallel_for(pool, len(s.hit), &d, job_clay)
	case .Flatten:
		d.amount = sign
		jobs.parallel_for(pool, len(s.hit), &d, job_flatten)
	case .Pinch:
		d.amount = sign
		jobs.parallel_for(pool, len(s.hit), &d, job_pinch)
	case .Crease:
		// Cuts in by default, like ZBrush's and Blender's crease brushes.
		d.amount = -sign * brush.radius * brush.strength * DRAW_HEIGHT
		jobs.parallel_for(pool, len(s.hit), &d, job_crease)
	case .Grab, .Mask:
		unreachable()
	case .Smooth:
		// Jacobi step: every target is computed from unmoved positions first.
		resize(&s.offsets, len(s.hit))
		total: u32
		for leaf, i in s.hit {
			s.offsets[i] = total
			total += s.nodes[s.node_of[leaf]].vert_count
		}
		resize(&s.smooth_to, int(total))
		jobs.parallel_for(pool, len(s.hit), &d, job_smooth_targets)
		jobs.parallel_for(pool, len(s.hit), &d, job_smooth_apply)
	}
	return finish_move(s, &d, pool)
}

// After the vertices of the hit leaves moved: marks what changed, records it for undo
// and refits the BVH. Returns how many vertices moved.
@(private)
finish_move :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool) -> int {
	// A leaf changed if one of its triangles has a moved vertex, owned or shared. Every
	// such triangle is in a hit leaf: its leaf's bounds held the vertex before the move.
	moved: int
	clear(&s.changed)
	for p, i in s.partials {
		moved += int(p.moved)
		if p.moved == 0 && !p.touched do continue
		leaf := s.hit[i]
		append(&s.changed, leaf)
		mark_shape_changed(s, s.node_of[leaf])
	}
	if len(s.changed) == 0 do return 0
	if s.history.recording do record_changed(s)
	jobs.parallel_for(pool, len(s.hit), d, job_hit_bounds)
	geom.bvh_refit_leaves(&s.bvh, s.mesh^, s.changed[:], recompute_leaves = false)
	return moved
}

// The node's triangles moved: all its normals are stale, and so are those of the
// vertices it shares with the nodes that own them.
@(private)
mark_shape_changed :: proc(s: ^Sculptor, id: u32) {
	mark_stale(s, id, .Shape)
	lod_mark_stale(s, id)
	if !s.edited[id] {
		s.edited[id] = true
		append(&s.edited_nodes, id)
	}
	n := s.nodes[id]
	for owner in s.owners[n.owner_first:][:n.owner_count] do mark_stale(s, owner, .Edge)
}

@(private)
mark_stale :: #force_inline proc(s: ^Sculptor, id: u32, level: Stale) {
	if s.stale[id] == .None do append(&s.dirty_nodes, id)
	if level > s.stale[id] do s.stale[id] = level
}

@(private)
owned :: #force_inline proc(s: ^Sculptor, leaf: u32) -> (first, last: u32) {
	n := s.nodes[s.node_of[leaf]]
	return n.vert_first, n.vert_first + n.vert_count
}

@(private)
shared_of :: #force_inline proc(s: ^Sculptor, leaf: u32) -> []u32 {
	n := s.nodes[s.node_of[leaf]]
	return s.shared[n.shared_first:][:n.shared_count]
}

// Whether any of the leaf's shared vertices lies inside the brush. Called before the
// move, since afterwards their owners may have moved them.
@(private)
shared_inside :: #force_inline proc(d: ^Dab, leaf: u32) -> bool {
	m := d.s.mesh
	for v in shared_of(d.s, leaf) {
		delta := m.positions[v] - d.center
		if linalg.dot(delta, delta) < d.r2 do return true
	}
	return false
}

// The area under the brush: falloff-weighted sums of the normals and positions inside it.
@(private)
job_area :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	normals, centers: Vec3
	weight: f32
	for v in first ..< last {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < d.r2 {
			w := falloff(d2 * d.inv_r2)
			normals += m.normals[v] * w
			centers += m.positions[v] * w
			weight += w
		}
	}
	p := &s.partials[i]
	p.normal_sum, p.center_sum, p.weight_sum = normals, centers, weight
	p.touched = shared_inside(d, s.hit[i])
}

@(private) job_draw :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Draw)}
@(private) job_inflate :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Inflate)}
@(private) job_clay :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Clay)}
@(private) job_flatten :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Flatten)}
@(private) job_pinch :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Pinch)}
@(private) job_crease :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Crease)}

// Moves the owned vertices of hit leaf i that lie inside the brush, as brush kind K
// does; specialised per kind so each loop has no branch on the kind.
@(private)
displace :: #force_inline proc(d: ^Dab, i: int, $K: Brush_Kind) {
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	fade, mask := s.fade, s.mask
	moved: u32
	bounds := geom.AABB_EMPTY
	for v in first ..< last {
		p := m.positions[v]
		delta := p - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < d.r2 {
			w := falloff(d2 * d.inv_r2) * shield(fade, mask, v)
			if w > 0 {
				when K == .Draw {
					p += d.normal * (d.amount * w)
				} else when K == .Inflate {
					p += m.normals[v] * (d.amount * w)
				} else when K == .Clay {
					// Only what lies on the near side of the plane moves, up to the plane.
					h := linalg.dot(p - d.plane, d.normal)
					if h * d.amount < 0 do p -= d.normal * (h * min(d.brush.strength * w * PLANE_RATE, 1))
				} else when K == .Flatten {
					h := linalg.dot(p - d.plane, d.normal)
					p -= d.normal * (h * d.amount * min(d.brush.strength * w * PLANE_RATE, 1))
				} else when K == .Pinch {
					to := d.center - p
					to -= d.normal * linalg.dot(to, d.normal)
					p += to * (d.amount * min(d.brush.strength * w * PINCH_RATE, 1))
				} else when K == .Crease {
					to := d.center - p
					to -= d.normal * linalg.dot(to, d.normal)
					p += d.normal * (d.amount * w * w) + to * min(d.brush.strength * w * CREASE_PINCH, 1)
				} else {
					#panic("not a displacing brush")
				}
				m.positions[v] = p
				moved += 1
			}
		}
		geom.aabb_grow(&bounds, p)
	}
	s.partials[i].moved = moved
	s.partials[i].bounds = bounds
}

@(private)
job_smooth_targets :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	out := s.smooth_to[s.offsets[i]:]
	for v in first ..< last {
		delta := m.positions[v] - d.center
		if linalg.dot(delta, delta) >= d.r2 do continue
		sum: Vec3
		n: f32
		for f in geom.vertex_faces_of(s.faces, v) {
			sum += m.positions[m.indices[3 * f]] + m.positions[m.indices[3 * f + 1]] + m.positions[m.indices[3 * f + 2]]
			n += 3
		}
		out[v - first] = sum / n
	}
	s.partials[i].touched = shared_inside(d, s.hit[i])
}

@(private)
job_smooth_apply :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	targets := s.smooth_to[s.offsets[i]:]
	fade, mask := s.fade, s.mask
	moved: u32
	bounds := geom.AABB_EMPTY
	for v in first ..< last {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < d.r2 {
			if w := shield(fade, mask, v); w > 0 {
				t := clamp(d.brush.strength * falloff(d2 * d.inv_r2), 0, 1) * w
				m.positions[v] = linalg.lerp(m.positions[v], targets[v - first], t)
				moved += 1
			}
		}
		geom.aabb_grow(&bounds, m.positions[v])
	}
	s.partials[i].moved = moved
	s.partials[i].bounds = bounds
}

// A leaf's triangles use exactly its owned vertices plus its shared ones, so their
// bounds are the leaf's bounds, without touching the triangles. After a dab the owned
// vertices are already bounded by the pass that moved them; their shared ones, moved
// by other leaves' owners, are added here.
@(private)
job_hit_bounds :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	p := s.partials[i]
	if p.moved == 0 && !p.touched do return
	bounds := p.bounds
	for v in shared_of(s, s.hit[i]) do geom.aabb_grow(&bounds, s.mesh.positions[v])
	s.bvh.nodes[s.hit[i]].bounds = bounds
}

// The same for leaves an undo or redo changed, from scratch.
@(private)
job_leaf_bounds :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	leaf := s.changed[i]
	first, last := owned(s, leaf)
	bounds := geom.AABB_EMPTY
	for v in first ..< last do geom.aabb_grow(&bounds, m.positions[v])
	for v in shared_of(s, leaf) do geom.aabb_grow(&bounds, m.positions[v])
	s.bvh.nodes[leaf].bounds = bounds
}

// Brings the BVH and the next flush up to date after the owned positions of `nodes`
// changed outside a dab (subdivision levels moving one level to match another). As
// after a dab, every node with a triangle on a moved vertex counts as changed.
sculptor_nodes_moved :: proc(s: ^Sculptor, nodes: []u32) {
	if len(nodes) == 0 do return
	moved := make([]bool, len(s.nodes), context.temp_allocator)
	for id in nodes do moved[id] = true
	clear(&s.changed)
	verts: u32
	for n, id in s.nodes {
		hit := moved[id]
		if !hit {
			for owner in s.owners[n.owner_first:][:n.owner_count] {
				if moved[owner] {
					hit = true
					break
				}
			}
		}
		if !hit do continue
		append(&s.changed, n.leaf)
		verts += n.vert_count
	}
	d := Dab{s = s}
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.changed), &d, job_leaf_bounds)
	geom.bvh_refit_leaves(&s.bvh, s.mesh^, s.changed[:], recompute_leaves = false)
	for leaf in s.changed do mark_shape_changed(s, s.node_of[leaf])
}

// Recomputes every normal, bound and normal cone, for a mesh that arrived without
// normals (a new subdivision level).
sculptor_recompute_all :: proc(s: ^Sculptor) {
	for id in 0 ..< len(s.nodes) do mark_stale(s, u32(id), .Shape)
	_ = sculptor_flush(s)
}

// Empties the list of edited nodes, once subdivision levels have carried the edits over.
sculptor_clear_edited :: proc(s: ^Sculptor) {
	for id in s.edited_nodes do s.edited[id] = false
	clear(&s.edited_nodes)
}

// Recomputes the stale normals of a dirty node from its vertices' adjacent faces: all
// of them if its own triangles moved, otherwise only those on its border with a node
// whose triangles moved. For a moved node, most faces are its own, so their normals
// are computed once up front instead of once per corner.
@(private)
job_node_normals :: proc(data: rawptr, i: int) {
	s := cast(^Sculptor)data
	m := s.mesh
	id := s.dirty_nodes[i]
	n := s.nodes[id]
	switch s.stale[id] {
	case .None, .Paint:
		return
	case .Edge:
		edge_normals(s, n)
		return
	case .Shape:
	}
	face_n: [MAX_CACHED_FACES]Vec3 = ---
	cached := n.tri_count if n.tri_count <= MAX_CACHED_FACES else 0
	for k in 0 ..< cached do face_n[k] = face_normal(m, n.tri_first + k)
	for v in n.vert_first ..< n.vert_first + n.vert_count {
		sum: Vec3
		for f in geom.vertex_faces_of(s.faces, v) {
			if local := f - n.tri_first; local < cached {
				sum += face_n[local]
			} else {
				sum += face_normal(m, f)
			}
		}
		m.normals[v] = linalg.normalize0(sum)
	}
	if s.history.recording {
		// Bounds stay current for frustum culling; the cone waits for the end of the stroke.
		s.chunks[id].bounds = s.bvh.nodes[n.leaf].bounds
		s.chunks[id].cone_cutoff = 1
	} else {
		update_chunk(s, id, face_n[:cached])
	}
}

// A node whose own triangles did not move: a vertex's normal is stale only if one of
// its faces belongs to a node whose triangles moved.
@(private)
edge_normals :: proc(s: ^Sculptor, n: Node) {
	m := s.mesh
	for v in n.vert_first ..< n.vert_first + n.vert_count {
		faces := geom.vertex_faces_of(s.faces, v)
		stale := false
		for f in faces {
			if f - n.tri_first < n.tri_count do continue // its own triangle
			if s.stale[s.node_of[s.bvh.tri_leaf[f]]] == .Shape {
				stale = true
				break
			}
		}
		if !stale do continue
		sum: Vec3
		for f in faces do sum += face_normal(m, f)
		m.normals[v] = linalg.normalize0(sum)
	}
}

// The cone of a node whose shape changed during a stroke that has ended, unless this
// flush already recomputed it. Takes the newest waiting nodes first.
@(private)
job_waiting_cone :: proc(data: rawptr, i: int) {
	s := cast(^Sculptor)data
	id := s.waiting_cones[len(s.waiting_cones) - 1 - i]
	if s.stale[id] != .Shape do update_chunk(s, id, nil)
}

// Refreshes a node's chunk from its BVH leaf bounds and its face normals, given in
// `face_n` when the caller already has them (computed here otherwise). Overwrites
// `face_n` with the unit normals.
@(private)
update_chunk :: proc(s: ^Sculptor, id: u32, face_n: []Vec3) {
	n := s.nodes[id]
	normals := face_n
	scratch: [MAX_CACHED_FACES]Vec3 = ---
	heap: []Vec3
	defer delete(heap, runtime.heap_allocator())
	if u32(len(normals)) != n.tri_count {
		if n.tri_count <= MAX_CACHED_FACES {
			normals = scratch[:n.tri_count]
		} else {
			heap = make([]Vec3, n.tri_count, runtime.heap_allocator())
			normals = heap
		}
		for k in 0 ..< n.tri_count do normals[k] = face_normal(s.mesh, n.tri_first + k)
	}
	axis, cutoff := geom.normal_cone(normals)
	s.chunks[id] = {
		bounds      = s.bvh.nodes[n.leaf].bounds,
		cone_axis   = axis,
		cone_cutoff = cutoff,
		first_index = 3 * n.tri_first,
		index_count = 3 * n.tri_count,
	}
}

// Unnormalized: its length is twice the triangle's area, which weights vertex normals.
@(private)
face_normal :: #force_inline proc(m: ^geom.Mesh, f: u32) -> Vec3 {
	p0 := m.positions[m.indices[3 * f]]
	p1 := m.positions[m.indices[3 * f + 1]]
	p2 := m.positions[m.indices[3 * f + 2]]
	return linalg.cross(p1 - p0, p2 - p0)
}

// Closest intersection of a ray with the sculpted mesh, using the BVH.
sculptor_raycast :: proc(s: ^Sculptor, origin, dir: Vec3) -> (hit: Vec3, ok: bool) {
	t: f32
	t, _, ok = geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir)
	if ok do hit = origin + dir * t
	return
}

// Brute-force reference for sculptor_raycast: tests every triangle. Kept for tests.
raycast :: proc(m: geom.Mesh, origin, dir: Vec3) -> (hit: Vec3, ok: bool) {
	best := max(f32)
	for tri in 0 ..< u32(len(m.indices) / 3) {
		if d, h := geom.ray_triangle(m, tri, origin, dir); h && d < best {
			best, ok = d, true
		}
	}
	if ok do hit = origin + dir * best
	return
}
