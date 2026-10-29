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
import "core:math"
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
	Layer,   // raise a flat-topped layer of one height per stroke, however often it passes (inverted: lower)
	Snake_Hook, // pull the surface out after the pointer: each dab drags it by Brush.drag
	Morph,   // bring the surface back toward the stored morph target (morph.odin)
	Paint,   // polypaint: colour the surface with Brush.color (paint.odin; inverted takes the paint off)
	Cloth,   // the surface around the brush behaves as cloth for the stroke: sculptor_cloth_begin and _step (cloth.odin)
	History, // bring the surface back toward how it was before an earlier step (recall.odin)
	Elastic, // drag as an elastic solid pulled at the press would move: Grab's arrays, Kelvinlet weights (elastic.odin)
}

Axis :: enum u8 {
	X,
	Y,
	Z,
}

// Planes through the symmetry's centre (Brush.sym_center) that dabs are mirrored across.
Symmetry :: bit_set[Axis;u8]

// What a sculpting brush's dabs change, as the reference app's sculpt and colour switches:
// the zero value sculpts only, as every brush did before there was a choice.
Channel :: enum u8 {
	Sculpt, // move the surface
	Both,   // move it and paint it
	Color,  // paint it, moving nothing
}

// The most copies radial symmetry turns a dab into round its axis.
RADIAL_MAX :: 32

// One image of a dab under symmetry: how it is turned about the symmetry's centre, an
// orthogonal matrix (a rotation, with the mirrors' flips), and whether it is mirrored (an
// odd number of flips), which turns an alpha over.
Sym_Image :: struct {
	turn:    matrix[3, 3]f32,
	flipped: bool,
}

// Every image a dab has: 8 mirrors times RADIAL_MAX turns at most.
SYM_IMAGES_MAX :: 8 * RADIAL_MAX

Brush :: struct {
	kind:     Brush_Kind,
	radius:   f32, // world units
	strength: f32, // 0..1
	invert:   bool,
	symmetry: Symmetry,
	// Radial symmetry: this many copies of every dab evenly round `radial_axis` (each mirror
	// image's too); 0 or 1 for none. At most RADIAL_MAX.
	radial:      u8,
	radial_axis: Axis,
	// Where the mirror planes meet and the radial axis passes, in the mesh's space: the
	// origin for the usual symmetry, the object's own middle for local symmetry.
	sym_center:  Vec3,
	// Dynamic topology (dyntopo.odin), on a sculptor that has it on: edges in the brush
	// longer than this share of the radius are split first; 0 leaves the triangles be.
	detail:   f32,
	collapse: bool, // ...and edges much shorter than that collapse
	// Turns the direction the brush works along (the area normal: Draw's push, the
	// plane of Clay and Flatten, Pinch's and Crease's surface) before the dab moves
	// anything: a leaning pen's (camera.orbit_tilt). The zero matrix leaves it.
	tilt:     matrix[3, 3]f32,
	// Shapes each dab with this image instead of the round falloff (alpha.odin); nil
	// for none. Seen down the area normal, the image's top faces along `alpha_up` (in
	// the mesh's space), and it shows mirrored when `alpha_mirror` is set. Grab ignores it.
	alpha:        ^Alpha,
	alpha_up:     Vec3,
	alpha_mirror: bool,
	// Replaces the round falloff with this one (falloff_set_curve); nil keeps the
	// built-in smooth one. Every brush uses it, Grab included; an alpha replaces it.
	falloff_shape: ^Falloff,
	// Snake_Hook: how far this dab drags what is under it, in the mesh's space.
	drag:     Vec3,
	// Snake_Hook, as Blender's: Pinch draws what the hook drags in toward the line it is
	// pulled along, a share of the step a dab (-1 to 1; below 0 it magnifies instead,
	// fattening the tip); Rake turns what it drags by how far the hook turned since the
	// last dab (0 to 1 of `rake_angle` about `rake_axis`, in the mesh's space), so a
	// hook drawn round a bend twists with it instead of shearing; Elastic tip drags as
	// the Elastic brush does (a Kelvinlet out to ELASTIC_REACH radii, by `volume`).
	hook_pinch:   f32,
	hook_rake:    f32,
	rake_axis:    Vec3,
	rake_angle:   f32,
	hook_elastic: bool,
	// Front faces only, as ZBrush's BackfaceMask: the way toward the viewer in the
	// mesh's space, and vertices whose normal turns away from it are left alone (with a
	// short fade across the edge-on ones), so a stroke on a thin part leaves its far
	// side be. Zero works on every vertex. Grab ignores it.
	facing:   Vec3,
	// Paint: the colour it paints, sRGB; any other brush paints it too when `channel` says.
	color:    [3]u8,
	// Paint: even the colours out instead of laying `color`, as Smooth evens the surface:
	// each vertex mixes toward the average of its neighbours' paint (the inverted brush
	// still takes paint off). Paint's Smooth in the dial, as ZBrush's and Nomad's do.
	blur:     bool,
	// What a sculpting dab changes: the surface, as it always has; the surface and the
	// polypaint, painting `color` under the same falloff; or only the polypaint, moving
	// nothing (paint_channel_dab). Paint, Mask, Grab and Cloth keep to their own channel.
	channel:  Channel,
	// Keep the area the stroke's first dab found (filters.odin). Not Grab, Snake hook,
	// Smooth, Inflate, Layer or Morph, which do not work along it, unless with an alpha.
	lock_plane: bool,
	// Work only on what joins the dab's centre through the surface (filters.odin); for
	// Grab, what joins where the grab began (Move connected), unless `through` is set.
	connected:  bool,
	// Grab: the view direction in the mesh's space, along which the brush reaches through
	// the whole depth: a vertex is in it when it lies within the radius of the line through
	// the centre (Move all depth). Zero keeps the round reach.
	through:    Vec3,
	// Smooth: which vertices it evens out, all or only those in dents or on bumps.
	smooth_only: Smooth_Only,
	// Smooth: as many more passes as the mesh under it is denser than SMOOTH_STABLE_EDGES
	// edges a radius, up to SMOOTH_PASSES_MAX, so a dab evens out about the same share of
	// the brush whatever the density (smooth_passes).
	smooth_stable: bool,
	// Smooth: how it evens out (smooth_all.odin's modes): Relax only across the surface,
	// Polish keeping the volume by the HC Laplacian (where Smooth all's Polish is Taubin's).
	smooth_mode:   Smooth_Mode,
	// Grab: pick up only what faces the same way as the surface pressed (Nomad's Same
	// side), and move only what faces the way it is dragged out (Blender's Silhouette).
	same_side:  bool,
	silhouette: bool,
	// Grab: weigh by the distance along the surface from where the grab began, not the
	// straight one (ZBrush's Move Topological, Blender's geodesic falloff), so it picks up
	// only what joins the press and its falloff follows the surface round a fold. Unless
	// `through` is set; it wins over `connected`.
	topological: bool,
	// Elastic: how much of its volume the solid keeps as it stretches, 0 to 1, Poisson's
	// ratio over its physical limit of a half (elastic.odin).
	volume: f32,
	// Symmetry's feathering, as Blender's: where a dab and its images overlap near a plane
	// or the radial axis, each is weakened by how much they overlap (symmetry_feather), so
	// a stroke along the middle builds the height it builds elsewhere, not twice it.
	feather: bool,
}

// Which vertices the Smooth brush moves: a vertex lies in a valley when the average of
// its neighbours is above it along its normal, and on a peak when below.
Smooth_Only :: enum u8 {
	All,
	Valleys,
	Peaks,
}

// Polish's HC Laplacian weights (Vollmer, Mencl and Muller 1999), as Blender's Surface
// Smooth's defaults: how far each step is pulled back toward where the dab began
// (alpha) and how much of that pull is the vertex's own rather than its neighbours'
// (beta).
POLISH_ALPHA :: 0.5
POLISH_BETA :: 0.5

// A vertex's Layer height, and the stroke it belongs to (0: none).
Layer_Height :: struct {
	stroke: u32,
	height: f32,
}

// How far dabs move the surface at full strength, in brush radii.
DRAW_HEIGHT :: 0.1
CLAY_HEIGHT :: 0.08 // where Clay's plane sits above the surface
// Share of the way to the target that Clay, Flatten and Pinch go per dab at full strength.
PLANE_RATE :: 0.5
PINCH_RATE :: 0.25
CREASE_PINCH :: 0.2
LAYER_HEIGHT :: 0.15 // Layer's height at full strength, in brush radii
LAYER_RATE :: 0.5    // share of the way to that height a dab goes where the falloff is full
MORPH_RATE :: 0.5    // share of the way back to the morph target a dab goes at full strength

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
	// Per geom.CHUNK_GROUP chunks: bounds and a cone holding theirs, for culling a group
	// at a time (sculptor_chunk_groups), and whether a chunk changed since it was made.
	chunk_groups: [dynamic]geom.Chunk,
	group_stale:  [dynamic]bool,
	node_of:     []u32,  // BVH node index -> node id (only meaningful for leaves)
	shared:      [dynamic]u32,
	owners:      [dynamic]u32,

	// Per-dab scratch, reused.
	hit:         [dynamic]u32, // BVH leaves overlapping the brush
	changed:     [dynamic]u32, // hit leaves with a moved vertex
	partials:    [dynamic]Partial,
	offsets:     [dynamic]u32, // per hit leaf: start of its slots in smooth_to
	smooth_to:   [dynamic]Vec3,
	// Polish: per slot, where each vertex was when the dab began and its HC push-back.
	smooth_from: [dynamic]Vec3,
	smooth_b:    [dynamic]Vec3,
	// Polish: the hit leaves' owned ranges sorted by their first vertex, to find a
	// neighbour's slot (smooth_slot).
	smooth_ranges: [dynamic]Smooth_Range,
	blur_to:     [dynamic][4]f32, // Paint's blur: the colour each slot mixes toward

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
	// which meets the level drawn around it, or a hidden vertex) to 255 (fully); nil
	// when all move fully.
	fade:        []u8,
	// Per vertex: how masked it is, from 0 (not at all) to 255 (brushes leave it alone);
	// nil until something is first masked (mask.odin).
	mask:        []u8,
	grab:        Grab, // the vertices a Grab stroke drags (grab.odin)
	cloth:       Cloth, // the region a Cloth stroke simulates (cloth.odin)
	// Per vertex: how far the Layer brush has raised it this stroke, valid where its
	// stroke number is layer_stroke; nil until the brush is first used.
	layer:        []Layer_Height,
	layer_stroke: u32,
	// The positions sculptor_morph_store kept, which the Morph brush brings vertices
	// back to; nil when none is stored.
	morph:        []Vec3,
	// The History brush's target (recall.odin): the positions from before the step with
	// id recall_step, and whether the user chose that point; nil when none is built.
	recall:        []Vec3,
	recall_step:   u64,
	recall_pinned: bool,
	// The hidden triangles (hide.odin).
	hide:        Hide,
	// Per vertex: its polypaint (paint.odin); nil until something is first painted.
	color:        []Color,
	color_edited: bool, // painted since the level became current, so a level change carries the colours
	paint_stamp:  u32,  // see sculptor_paint_stamp
	// The polygroups per triangle, and what drawing them needs (groups.odin).
	groups:       Groups,
	// The sculpt layers (sculpt_layers.odin).
	layers:       Sculpt_Layers,
	// A pose under way (pose.odin).
	pose:         Pose_State,
	// Where the vertices were when a lattice was made (lattice.odin).
	lattice:      Lattice_Rest,
	// The topological mask under way (topo_mask.odin).
	topo:         Topo_State,
	// Lock plane's plane for the stroke under way, and Connected's flood (filters.odin).
	locked:       Locked_Plane,
	connected:    Connected_State,
	// Set while dynamic topology is on (dyntopo.odin): the mesh is laid out in pages,
	// `faces` and the shared lists above are replaced, and there are no LOD copies.
	dyn:         ^Dyn,
}

// Partitions and renumbers `mesh` in place (vertex order and triangle order change),
// then builds the acceleration structures. Upload the mesh to the GPU after this.
// With `old_to_new` (one entry per vertex), it receives each vertex's new number, and
// with `tri_from` (one entry per triangle), each new triangle's number before.
sculptor_init :: proc(s: ^Sculptor, mesh: ^geom.Mesh, pool: ^jobs.Pool, node_triangles: u32 = NODE_TRIANGLES, old_to_new: []u32 = nil, tri_from: []u32 = nil, allocator := context.allocator) {
	s.mesh = mesh
	s.pool = pool
	s.bvh = geom.bvh_build_morton(mesh^, node_triangles, pool, allocator)
	reorder_by_nodes(s, old_to_new, tri_from, allocator)
	sculptor_init_rest(s, allocator)
}

// What sculptor_init does once the mesh is laid out in nodes.
@(private)
sculptor_init_rest :: proc(s: ^Sculptor, allocator: runtime.Allocator) {
	mesh := s.mesh
	s.faces = geom.vertex_faces_build(mesh^, s.pool, allocator)
	s.hit = make([dynamic]u32, 0, 256, allocator)
	s.changed = make([dynamic]u32, 0, 256, allocator)
	s.partials = make([dynamic]Partial, 0, 256, allocator)
	s.offsets = make([dynamic]u32, 0, 256, allocator)
	s.smooth_to = make([dynamic]Vec3, 0, 16384, allocator)
	s.smooth_from = make([dynamic]Vec3, 0, 0, allocator)
	s.smooth_b = make([dynamic]Vec3, 0, 0, allocator)
	s.smooth_ranges = make([dynamic]Smooth_Range, 0, 0, allocator)
	s.blur_to = make([dynamic][4]f32, 0, 0, allocator)
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
	dyn_destroy(s)
	hide_destroy(s)
	groups_destroy(s)
	layers_destroy(s)
	delete(s.color, s.history.allocator)
	delete(s.mask, s.history.allocator)
	delete(s.layer, s.history.allocator)
	delete(s.morph, s.history.allocator)
	delete(s.recall, s.history.allocator)
	grab_destroy(&s.grab)
	cloth_destroy(&s.cloth)
	pose_free(s)
	sculptor_lattice_clear(s)
	topo_free(s)
	connected_free(s)
	history_destroy(&s.history)
	geom.vertex_faces_destroy(&s.faces)
	geom.bvh_destroy(&s.bvh)
	delete(s.nodes)
	delete(s.chunks)
	delete(s.chunk_groups)
	delete(s.group_stale)
	delete(s.node_of)
	delete(s.shared)
	delete(s.owners)
	delete(s.hit)
	delete(s.changed)
	delete(s.partials)
	delete(s.offsets)
	delete(s.smooth_to)
	delete(s.smooth_from)
	delete(s.smooth_b)
	delete(s.smooth_ranges)
	delete(s.blur_to)
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
reorder_by_nodes :: proc(s: ^Sculptor, old_to_new: []u32, tri_from: []u32, allocator := context.allocator) {
	Reorder :: struct {
		s:           ^Sculptor,
		leaves:      []u32,   // node id -> BVH leaf
		indices:     [dynamic]u32,  // triangles in node order (replaces the mesh's)
		positions:   [dynamic]Vec3, // vertex data in new numbering (replaces the mesh's)
		normals:     [dynamic]Vec3,
		unique:      [][]u32, // per node: distinct old vertices of its triangles
		owner:       []u32,   // per old vertex: lowest node id using it
		old_to_new:  []u32,
		tri_from:    []u32,   // per new triangle: its number before, when asked for
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
		tri_from    = tri_from,
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
			if r.tri_from != nil do r.tri_from[k] = t
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

// Brings the vertex normals of everything changed since the last sculptor_flush up to
// date without taking it off what the next sculptor_flush reports, which works the same
// normals out again. For running several frames' worth of dabs in one frame (an instant
// stroke replay): a dab reads the normals, so each frame's dabs need the ones before
// them reflected, as a frame-by-frame flush would have done.
sculptor_refresh_normals :: proc(s: ^Sculptor) {
	if len(s.dirty_nodes) == 0 do return
	verts: u32
	for id in s.dirty_nodes do verts += s.nodes[id].vert_count
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.dirty_nodes), s, job_node_normals)
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

	if d := s.dyn; d != nil {
		clear(&d.index_ranges)
		slice.sort(d.topo_nodes[:])
		for id in d.topo_nodes {
			d.topo[id] = false
			s.chunks[id].index_count = 3 * s.nodes[id].tri_count
			chunk_touched(s, id)
			first := 3 * s.nodes[id].tri_first
			if n := len(d.index_ranges); n > 0 && d.index_ranges[n - 1].first_index + d.index_ranges[n - 1].index_count == first {
				d.index_ranges[n - 1].index_count += 3 * DYN_PAGE_TRIS
			} else {
				append(&d.index_ranges, geom.Index_Range{first, 3 * DYN_PAGE_TRIS})
			}
		}
		clear(&d.topo_nodes)
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

FALLOFF_STEPS :: 256

// The most a straight row of dabs `spacing` radii apart piles up anywhere along its middle
// line, with the falloff `shape` (nil: the built-in one), as Blender's
// paint_stroke_integrate_overlap measures it: the sum of the dabs' weights at a point,
// taken at OVERLAP_PHASES points between two dabs, and the largest kept. A stroke's
// strength over the overlap at its spacing builds the same height at every spacing.
dab_overlap :: proc(shape: ^Falloff, spacing: f32) -> f32 {
	s := max(spacing, 0.01)
	reach := int(math.ceil(1 / s))
	top: f32
	for phase in 0 ..< OVERLAP_PHASES {
		x := s * f32(phase) / OVERLAP_PHASES
		sum: f32
		for k in -reach ..= reach {
			d := x + f32(k) * s
			x2 := d * d
			sum += falloff_drawn(shape, x2) if shape != nil else falloff(x2)
		}
		top = max(top, sum)
	}
	return top
}

OVERLAP_PHASES :: 16

// A brush falloff drawn by the user: the weight at squared distances 0, 1/256, ... 1 in
// radii², read between the entries linearly. Indexing by the squared distance spares a
// square root per vertex, as falloff does.
Falloff :: struct {
	table: [FALLOFF_STEPS + 1]f32,
}

// Fills the table from a response curve read from the rim in: the weight at distance d
// radii from the centre is geom.curve_at(curve, 1 - d), so the linear curve is a cone,
// and every curve is 0 at the rim and 1 at the centre.
falloff_set_curve :: proc(f: ^Falloff, curve: geom.Curve) {
	falloff_set_shaped(f, curve, 0)
}

// The focal shift's range, as the reference app's Focal Shift: positive pulls the weight in
// toward the centre, negative pushes it out toward the rim.
FOCAL_MIN :: -100
FOCAL_MAX :: 100

// Fills the table with the falloff `curve` (nil: the built-in falloff) reshaped by `focal`
// (FOCAL_MIN to FOCAL_MAX): the weight at distance d radii is the base's at d^p, with
// p = 2^(-focal/50), so focal 0 is the base itself, 100 reads it at d^(1/4), a point, and
// -100 at d^4, a plateau with a hard edge. Every shape stays 1 at the centre and 0 at the
// rim, and falls as d grows. A strong positive shift is steeper at the very tip than the
// table can follow: inside its first cell (a sixteenth of the radius) the point is rounded
// off, which a dab never shows, where more entries would only round it a little less.
falloff_set_shaped :: proc(f: ^Falloff, curve: Maybe(geom.Curve), focal: f32) {
	p := math.pow(2, -clamp(focal, FOCAL_MIN, FOCAL_MAX) / 50)
	for &w, i in f.table {
		// Squared distances stay as they are where nothing reshapes them, so the built-in
		// table matches falloff itself exactly.
		x2 := f32(i) / FALLOFF_STEPS
		if focal != 0 do x2 = math.pow(x2, p)
		if c, drawn := curve.?; drawn {
			w = geom.curve_at(c, 1 - math.sqrt(x2))
		} else {
			w = falloff(x2)
		}
	}
}

// The drawn falloff at squared distance x2 in radii².
falloff_drawn :: #force_inline proc(f: ^Falloff, x2: f32) -> f32 {
	if x2 >= 1 do return 0
	x := x2 * FALLOFF_STEPS
	i := int(x)
	a := f.table[i]
	return a + (f.table[i + 1] - a) * (x - f32(i))
}

// Lays the brush's alpha on the plane across the dab's area normal, its top toward
// alpha_up (or, when that runs along the normal, any way).
@(private)
alpha_frame :: proc(d: ^Dab) {
	n := d.normal
	if n == {} do n = {0, 0, 1} // no surface under the middle: face any way
	up := d.brush.alpha_up - n * linalg.dot(d.brush.alpha_up, n)
	if linalg.dot(up, up) < 1e-12 {
		helper := Vec3{1, 0, 0} if abs(n.x) < 0.9 else Vec3{0, 1, 0}
		up = linalg.cross(n, helper)
	}
	v := linalg.normalize(up)
	// Seen from the side the normal points to, right is up × toward the viewer.
	u := linalg.cross(v, n)
	if d.brush.alpha_mirror do u = -u
	inv_r := 1 / d.brush.radius
	d.alpha, d.au, d.av, d.an = d.brush.alpha, u * inv_r, v * inv_r, n * inv_r
}

// How strongly a dab works on a vertex `delta` from its centre, `d2` = |delta|²: the
// round falloff, or with an alpha the image's value where the vertex falls on it,
// fading as the vertex lies further off its plane (gone a radius off). The loops call
// it only inside the reach.
@(private)
dab_weight :: #force_inline proc(d: ^Dab, delta: Vec3, d2: f32) -> f32 {
	if d.alpha == nil {
		if d.brush.falloff_shape != nil do return falloff_drawn(d.brush.falloff_shape, d2 * d.inv_r2)
		return falloff(d2 * d.inv_r2)
	}
	h := linalg.dot(delta, d.an)
	return alpha_sample(d.alpha, linalg.dot(delta, d.au), linalg.dot(delta, d.av)) * falloff(h * h)
}

// Everything a dab phase needs, shared read-only by the worker threads.
@(private)
Dab :: struct {
	s:        ^Sculptor,
	brush:    Brush,
	center:   Vec3,
	r2:       f32, // squared reach: the radius, or with an alpha its Alpha.reach
	inv_r2:   f32, // 1 / radius²
	// With an alpha: the image's right and up and the area normal, each over the
	// radius, so a vertex's offset dotted with them gives its place on the image and
	// its height off it in radii (dab_weight).
	alpha:    ^Alpha,
	au, av, an: Vec3,
	connected: bool, // Connected's flood ran for this dab (connected_weight)
	rate:     f32, // Smooth: this pass's share of the step toward the neighbours (smooth_passes)
	normal:   Vec3, // area normal: the falloff-weighted normals inside the brush
	plane:    Vec3, // Clay, Flatten: a point on the plane they pull toward
	amount:   f32,  // signed: displacement at the centre (Draw, Inflate, Crease), plane
	                // side (Clay), direction (Flatten, Pinch), or mask added (Mask)
	// Snake_Hook: its Elastic tip's constants, how much this dab pinches (Brush.hook_pinch
	// times the step over the radius) and the way it drags (unit length).
	kelvin:   Kelvinlet,
	pinch:    f32,
	drag_dir: Vec3,
}

// Applies one dab centred on `center`, and its mirror images across the brush's
// symmetry planes. Returns how many vertices moved (for Mask: how many changed their
// mask). Positions and BVH bounds are current when it returns; vertex normals catch up
// in sculptor_flush. Grab strokes go through sculptor_grab_begin instead.
apply_dab :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> int {
	if brush.kind == .Grab || brush.kind == .Elastic || brush.kind == .Cloth do return 0
	moved := 0
	images := symmetry_images(brush)
	b := brush
	b.strength /= symmetry_feather(brush, images[:], center)
	for img, i in images {
		moved += dab_once(s, sym_brush(b, img), sym_point(img, b.sym_center, center), img, i == 0)
	}
	return moved
}

// How much a dab at `center` and its images `images` (the dab itself first) overlap, by
// Blender's measure: 1 for the dab, and for each image whose centre is within two radii
// of the dab's, how far within as a share of two radii. A dab's strength is divided by it
// when the brush feathers, and it is 1 where no image comes near, or without feathering.
symmetry_feather :: proc(brush: Brush, images: []Sym_Image, center: Vec3) -> f32 {
	if !brush.feather || len(images) < 2 || brush.radius <= 0 do return 1
	overlap: f32 = 1
	reach := 2 * brush.radius
	for img in images[1:] {
		d := linalg.length(sym_point(img, brush.sym_center, center) - center)
		if d < reach do overlap += (reach - d) / reach
	}
	return overlap
}

// The images of a dab under the brush's symmetry, the dab itself first: each mirror image
// (mirrors) turned by each step of the radial symmetry. Mirror images alone are exact sign
// flips, so a dab and its images land on bit-identical places either side of a plane.
symmetry_images :: proc(brush: Brush) -> (images: [dynamic; SYM_IMAGES_MAX]Sym_Image) {
	turns := int(clamp(brush.radial, 1, RADIAL_MAX))
	for sign in mirrors(brush.symmetry) {
		flip := matrix[3, 3]f32{sign.x, 0, 0, 0, sign.y, 0, 0, 0, sign.z}
		for k in 0 ..< turns {
			img := Sym_Image{turn = flip, flipped = sign.x * sign.y * sign.z < 0}
			if k > 0 do img.turn = radial_turn(brush.radial_axis, f32(k) / f32(turns)) * flip
			append(&images, img)
		}
	}
	return
}

// The turn by `fraction` of a whole turn about `axis`.
@(private)
radial_turn :: proc(axis: Axis, fraction: f32) -> matrix[3, 3]f32 {
	a := fraction * 2 * math.PI
	c, s := math.cos(a), math.sin(a)
	switch axis {
	case .X: return {1, 0, 0, 0, c, -s, 0, s, c}
	case .Y: return {c, 0, s, 0, 1, 0, -s, 0, c}
	case .Z: return {c, -s, 0, s, c, 0, 0, 0, 1}
	}
	return 1
}

// Where image `img` takes point `p`, turning about `center`.
sym_point :: #force_inline proc(img: Sym_Image, center, p: Vec3) -> Vec3 {
	return center + img.turn * (p - center)
}

// The brush for one image of a dab: every direction it carries turned as the image is (the
// tilt by the turn, then itself, then the turn back), and its alpha turned over when the
// image is mirrored.
@(private)
sym_brush :: proc(brush: Brush, img: Sym_Image) -> Brush {
	b := brush
	m := img.turn
	if b.tilt != {} do b.tilt = m * b.tilt * linalg.transpose(m)
	b.alpha_up = m * b.alpha_up
	b.drag = m * b.drag
	// A mirror turns a rotation the other way about its mirrored axis.
	b.rake_axis = m * b.rake_axis
	if img.flipped do b.rake_axis = -b.rake_axis
	b.facing = m * b.facing
	if img.flipped do b.alpha_mirror = !b.alpha_mirror
	return b
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

// How much a dab may move vertex v for facing the way it does (Brush.facing): 1 when
// front faces only is off or the vertex faces the viewer, 0 when it faces away, a short
// ramp between; and 0 where Connected's flood did not reach it.
@(private)
facing_weight :: #force_inline proc(d: ^Dab, normals: []Vec3, v: u32) -> f32 {
	w := connected_weight(d, v)
	if d.brush.facing == {} do return w
	return clamp(linalg.dot(normals[v], d.brush.facing) * 5 + 0.5, 0, 1) * w
}

@(private)
dab_once :: proc(s: ^Sculptor, brush: Brush, center: Vec3, img: Sym_Image, own: bool) -> int {
	// An alpha may reach past the round brush, up to its square's corners; a Snake hook's
	// Elastic tip reaches as the Elastic brush does.
	reach := brush.radius * (brush.alpha.reach if brush.alpha != nil else 1)
	if brush.kind == .Snake_Hook && brush.hook_elastic do reach = ELASTIC_REACH * brush.radius
	d := Dab {
		s      = s,
		brush  = brush,
		center = center,
		r2     = reach * reach,
		inv_r2 = 1 / (brush.radius * brush.radius),
	}
	clear(&s.hit)
	geom.bvh_query_leaves(&s.bvh, center, reach, &s.hit)
	if len(s.hit) == 0 do return 0
	candidates: u32
	for leaf in s.hit do candidates += s.nodes[s.node_of[leaf]].vert_count
	pool := s.pool if candidates >= PARALLEL_MIN_VERTS else nil
	if s.dyn != nil && brush.kind != .Mask && brush.kind != .Paint && brush.detail > 0 {
		if s.history.recording do record_hit(s, masks = false)
		if dyn_dab_topology(s, &d, pool) {
			clear(&s.hit)
			geom.bvh_query_leaves(&s.bvh, center, reach, &s.hit)
			if len(s.hit) == 0 do return 0
		}
	}
	resize(&s.partials, len(s.hit))
	slice.zero(s.partials[:])
	if brush.connected do connected_flood(s, &d, pool)
	// The area under the brush: what most kinds work along, and the plane an alpha
	// lies on.
	if (brush.kind != .Smooth && brush.kind != .Mask && brush.kind != .Paint && brush.kind != .Snake_Hook && brush.kind != .Morph && brush.kind != .History) || brush.alpha != nil {
		jobs.parallel_for(pool, len(s.hit), &d, job_area)
		weight: f32
		for p in s.partials {
			d.normal += p.normal_sum
			d.plane += p.center_sum
			weight += p.weight_sum
		}
		d.normal = linalg.normalize0(d.normal)
		if weight > 0 do d.plane /= weight
		if brush.lock_plane && brush_locks_plane(brush.kind, brush.alpha != nil) do lock_plane_apply(s, &d, img, own, weight)
		if brush.tilt != {} do d.normal = linalg.normalize0(brush.tilt * d.normal)
		if brush.alpha != nil do alpha_frame(&d)
	}
	if brush.kind == .Mask do return mask_dab(s, &d, pool)
	if brush.kind == .Paint do return paint_dab(s, &d, pool)
	painted := 0
	if brush.channel != .Sculpt {
		painted = paint_channel_dab(s, &d, pool)
		if brush.channel == .Color do return painted
	}
	if s.history.recording do record_hit(s, masks = false)

	sign: f32 = -1 if brush.invert else 1
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
	case .Layer:
		if len(s.layer) < len(s.mesh.positions) {
			// Dynamic topology adds vertices; the new entries belong to no stroke.
			grown := make([]Layer_Height, len(s.mesh.positions) + len(s.mesh.positions) / 4, s.history.allocator)
			copy(grown, s.layer)
			delete(s.layer, s.history.allocator)
			s.layer = grown
		}
		d.amount = sign * brush.radius * brush.strength * LAYER_HEIGHT
		jobs.parallel_for(pool, len(s.hit), &d, job_layer)
	case .Snake_Hook:
		if brush.drag == {} do return painted
		if brush.hook_elastic do d.kelvin = kelvinlet_make(brush.radius, brush.volume)
		step := linalg.length(brush.drag)
		d.pinch = clamp(brush.hook_pinch, -1, 1) * step / brush.radius
		d.drag_dir = brush.drag / step
		jobs.parallel_for(pool, len(s.hit), &d, job_snake_hook)
	case .Morph:
		if len(s.morph) != len(s.mesh.positions) do return painted
		jobs.parallel_for(pool, len(s.hit), &d, job_morph)
	case .History:
		if len(s.recall) != len(s.mesh.positions) do return painted
		jobs.parallel_for(pool, len(s.hit), &d, job_history)
	case .Grab, .Elastic, .Mask, .Paint, .Cloth:
		unreachable()
	case .Smooth:
		// Jacobi steps: every target of a pass is computed from that pass's unmoved
		// positions first.
		resize(&s.offsets, len(s.hit))
		total: u32
		for leaf, i in s.hit {
			s.offsets[i] = total
			total += s.nodes[s.node_of[leaf]].vert_count
		}
		resize(&s.smooth_to, int(total))
		scale: f32 = 1
		if brush.smooth_stable {
			jobs.parallel_for(pool, len(s.hit), &d, job_smooth_edges)
			length, edges: f64
			for p in s.partials {
				length += f64(p.weight_sum)
				edges += f64(p.moved)
			}
			slice.zero(s.partials[:])
			if edges > 0 do scale = smooth_stable_scale(brush.radius, f32(length / edges))
		}
		rates := smooth_passes(brush.strength * scale)
		if brush.smooth_mode == .Polish && len(rates) > 0 {
			resize(&s.smooth_from, int(total))
			resize(&s.smooth_b, int(total))
			clear(&s.smooth_ranges)
			for leaf, i in s.hit {
				first, last := owned(s, leaf)
				append(&s.smooth_ranges, Smooth_Range{first, last, s.offsets[i]})
				copy(s.smooth_from[s.offsets[i]:][:last - first], s.mesh.positions[first:last])
			}
			slice.sort_by(s.smooth_ranges[:], proc(a, b: Smooth_Range) -> bool {return a.first < b.first})
		}
		for rate in rates {
			d.rate = rate
			jobs.parallel_for(pool, len(s.hit), &d, job_smooth_targets)
			if brush.smooth_mode == .Polish do jobs.parallel_for(pool, len(s.hit), &d, job_polish_targets)
			jobs.parallel_for(pool, len(s.hit), &d, job_smooth_apply)
		}
	}
	return painted + finish_move(s, &d, pool)
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
	for owner in node_owners(s, id) do mark_stale(s, owner, .Edge)
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
	return node_shared(s, s.node_of[leaf])
}

// Vertices of the node's triangles owned by other nodes, and those nodes.
@(private)
node_shared :: #force_inline proc(s: ^Sculptor, id: u32) -> []u32 {
	if s.dyn != nil do return s.dyn.shared[id][:]
	n := s.nodes[id]
	return s.shared[n.shared_first:][:n.shared_count]
}

@(private)
node_owners :: #force_inline proc(s: ^Sculptor, id: u32) -> []u32 {
	if s.dyn != nil do return s.dyn.owners[id][:]
	n := s.nodes[id]
	return s.owners[n.owner_first:][:n.owner_count]
}

// The triangles vertex v is in.
@(private)
faces_of :: #force_inline proc(s: ^Sculptor, v: u32) -> []u32 {
	if s.dyn != nil do return dyn_faces(s.dyn, v)
	return geom.vertex_faces_of(s.faces, v)
}

// The node triangle f belongs to.
@(private)
tri_node :: #force_inline proc(s: ^Sculptor, f: u32) -> u32 {
	if s.dyn != nil do return tri_page(f)
	return s.node_of[s.bvh.tri_leaf[f]]
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
			w := falloff(d2 * d.inv_r2) * connected_weight(d, v)
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
@(private) job_layer :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Layer)}
@(private) job_morph :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.Morph)}
@(private) job_history :: proc(data: rawptr, i: int) {displace(cast(^Dab)data, i, Brush_Kind.History)}

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
			w := dab_weight(d, delta, d2) * shield(fade, mask, v) * facing_weight(d, m.normals[:], v)
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
				} else when K == .Layer {
					// Toward the stroke's height along the vertex's own normal: once there,
					// passing again adds nothing.
					l := &s.layer[v]
					h := l.height if l.stroke == s.layer_stroke else 0
					next := h + (d.amount - h) * min(w * LAYER_RATE, 1)
					p += m.normals[v] * (next - h)
					l^ = {s.layer_stroke, next}
				} else when K == .Morph {
					p = linalg.lerp(p, s.morph[v], min(d.brush.strength * w * MORPH_RATE, 1))
				} else when K == .History {
					p = linalg.lerp(p, s.recall[v], min(d.brush.strength * w * MORPH_RATE, 1))
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

// How many passes a Smooth dab of `strength` takes, and each one's share of the step
// toward the neighbours: SMOOTH_PASSES_MAX at full strength, as Blender's smooth turns its
// strength into up to four whole passes (iteration_strengths), whole passes first and a
// part of one last. Over 1 (Stable on a dense mesh) it takes more, up to SMOOTH_PASSES_HARD.
smooth_passes :: proc(strength: f32) -> []f32 {
	n := clamp(strength, 0, f32(SMOOTH_PASSES_HARD) / SMOOTH_PASSES_MAX) * SMOOTH_PASSES_MAX
	whole := int(n)
	out := make([dynamic]f32, 0, whole + 1, context.temp_allocator)
	for _ in 0 ..< whole do append(&out, 1)
	if part := n - f32(whole); part > 0 do append(&out, part)
	return out[:]
}

// Smooth's passes at full strength, and the most Stable may take.
SMOOTH_PASSES_MAX :: 4
SMOOTH_PASSES_HARD :: 8
// Stable's reference density: a dab over this many edges a radius smooths as without it.
SMOOTH_STABLE_EDGES :: 8

// How many times as many passes Stable gives a dab of `radius` over edges `edge` long on
// average: a smoothing pass spreads a bump by about an edge, so evening out the same
// share of the brush takes passes as the square of the edges across it.
smooth_stable_scale :: proc(radius, edge: f32) -> f32 {
	if edge <= 0 do return 1
	r := radius / (edge * SMOOTH_STABLE_EDGES)
	return r * r
}

// The edges from each vertex inside the brush to its triangles' other corners, summed
// into the leaf's partial (weight_sum the lengths, moved the count), for Stable.
@(private)
job_smooth_edges :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	length: f32
	count: u32
	for v in first ..< last {
		p := m.positions[v]
		delta := p - d.center
		if linalg.dot(delta, delta) >= d.r2 do continue
		for f in faces_of(s, v) {
			for k in u32(0) ..< 3 {
				w := m.indices[3 * f + k]
				if w == v do continue
				length += linalg.length(m.positions[w] - p)
				count += 1
			}
		}
	}
	s.partials[i].weight_sum, s.partials[i].moved = length, count
}

@(private)
job_smooth_targets :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	out := s.smooth_to[s.offsets[i]:]
	polish := d.brush.smooth_mode == .Polish
	for v in first ..< last {
		delta := m.positions[v] - d.center
		if linalg.dot(delta, delta) >= d.r2 {
			// Outside the brush a vertex stays, so it pushes nothing back.
			if polish do s.smooth_b[s.offsets[i] + v - first] = {}
			continue
		}
		q := smooth_target(s, v)
		out[v - first] = q
		if polish {
			slot := s.offsets[i] + v - first
			s.smooth_b[slot] = q - (POLISH_ALPHA * s.smooth_from[slot] + (1 - POLISH_ALPHA) * m.positions[v])
		}
	}
	s.partials[i].touched = shared_inside(d, s.hit[i])
}

// A hit leaf's owned vertices and where their slots start.
Smooth_Range :: struct {
	first, last, offset: u32,
}

// The slot of vertex `v` among the hit leaves' owned vertices, or false when no hit leaf
// owns it.
@(private)
smooth_slot :: proc(s: ^Sculptor, v: u32) -> (u32, bool) {
	r := s.smooth_ranges[:]
	lo, hi := 0, len(r)
	for lo < hi {
		mid := (lo + hi) / 2
		if r[mid].last <= v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(r) && r[lo].first <= v do return r[lo].offset + v - r[lo].first, true
	return 0, false
}

// Polish's second step: each target pulled back by its own push-back and its
// neighbours', so the surface keeps its volume (Smooth_Mode.Polish).
@(private)
job_polish_targets :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	for v in first ..< last {
		delta := m.positions[v] - d.center
		if linalg.dot(delta, delta) >= d.r2 do continue
		around: Vec3
		n: f32
		for f in faces_of(s, v) {
			for k in u32(0) ..< 3 {
				w := m.indices[3 * f + k]
				if w == v do continue
				if slot, ok := smooth_slot(s, w); ok do around += s.smooth_b[slot]
				n += 1
			}
		}
		slot := s.offsets[i] + v - first
		if n > 0 do around /= n
		s.smooth_to[slot] -= POLISH_BETA * s.smooth_b[slot] + (1 - POLISH_BETA) * around
	}
}

// Where Smooth moves vertex `v` toward: the middle of its triangles' corners, or on an
// open border the middle of its neighbours along the border, as Blender and SculptGL do,
// so a hole's edge evens out along itself instead of shrinking into the surface.
@(private)
smooth_target :: #force_inline proc(s: ^Sculptor, v: u32) -> Vec3 {
	m := s.mesh
	faces := faces_of(s, v)
	sum: Vec3
	n: f32
	// Inside a closed fan every neighbour is a corner of two of its triangles, so the
	// exclusive or of the other corners is zero; on a border the two border neighbours
	// are corners once and leave it non-zero (or, past a rare non-manifold tie, this
	// keeps the plain middle).
	odd: u32
	for f in faces {
		for k in u32(0) ..< 3 {
			w := m.indices[3 * f + k]
			sum += m.positions[w]
			if w != v do odd ~= w
		}
		n += 3
	}
	if odd == 0 || len(faces) > 32 do return sum / n
	// The neighbours that are corners of only one of its triangles lie along the border.
	seen: [64]u32
	times: [64]u8
	count := 0
	for f in faces {
		for k in u32(0) ..< 3 {
			w := m.indices[3 * f + k]
			if w == v do continue
			j := 0
			for j < count && seen[j] != w do j += 1
			if j == count {
				seen[j] = w
				count += 1
			}
			times[j] += 1
		}
	}
	border: Vec3
	b: f32
	for j in 0 ..< count do if times[j] == 1 {
		border += m.positions[seen[j]]
		b += 1
	}
	return border / b if b > 0 else sum / n
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
			if w := shield(fade, mask, v) * facing_weight(d, m.normals[:], v); w > 0 && smooth_takes(d.brush.smooth_only, targets[v - first] - m.positions[v], m.normals[v]) {
				t := clamp(d.rate * dab_weight(d, delta, d2), 0, 1) * w
				step := targets[v - first] - m.positions[v]
				if d.brush.smooth_mode == .Relax {
					// Only across the surface: the part along the normal would change the shape.
					n := linalg.normalize0(m.normals[v])
					step -= n * linalg.dot(step, n)
				}
				m.positions[v] += step * t
				moved += 1
			}
		}
		geom.aabb_grow(&bounds, m.positions[v])
	}
	// Over several passes the leaf moved what any of them moved; the last bounds hold.
	s.partials[i].moved = max(s.partials[i].moved, moved)
	s.partials[i].bounds = bounds
}

// Whether Smooth moves a vertex whose step toward its neighbours' average is `step`:
// along its normal it rises out of a valley, against it it comes down off a peak.
@(private)
smooth_takes :: #force_inline proc(only: Smooth_Only, step, normal: Vec3) -> bool {
	switch only {
	case .All:     return true
	case .Valleys: return linalg.dot(step, normal) > 0
	case .Peaks:   return linalg.dot(step, normal) < 0
	}
	return true
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
// after a dab, every node with a triangle on a moved vertex counts as changed. A move
// that no undo step records must also history_seal, or a History brush target would be
// built back through it (recall.odin).
sculptor_nodes_moved :: proc(s: ^Sculptor, nodes: []u32) {
	if len(nodes) == 0 do return
	moved := make([]bool, len(s.nodes), context.temp_allocator)
	for id in nodes do moved[id] = true
	clear(&s.changed)
	verts: u32
	for n, id in s.nodes {
		hit := moved[id]
		if !hit {
			for owner in node_owners(s, u32(id)) {
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

// Puts vertices `verts` at `positions` and brings the BVH and the next flush up to date,
// for an edit made outside the brushes on a mesh it does not rebuild (Model mode moving a
// cage's points, whose undo step the app records as a swap). Seals the history, since no
// sculpt undo step records the move.
sculptor_place_vertices :: proc(s: ^Sculptor, verts: []u32, positions: []Vec3) {
	assert(len(verts) == len(positions))
	if len(verts) == 0 do return
	// The nodes in the order of their vertex ranges, to find each vertex's owner by halves.
	order := make([][2]u32, len(s.nodes), context.temp_allocator)
	for n, id in s.nodes do order[id] = {n.vert_first, u32(id)}
	slice.sort_by(order, proc(a, b: [2]u32) -> bool {return a[0] < b[0]})
	moved := make([]bool, len(s.nodes), context.temp_allocator)
	for v, i in verts {
		s.mesh.positions[v] = positions[i]
		// The last node whose range starts at or before v.
		lo, hi := 0, len(order)
		for lo < hi {
			mid := (lo + hi) / 2
			if order[mid][0] <= v do lo = mid + 1
			else do hi = mid
		}
		if lo == 0 do continue
		id := order[lo - 1][1]
		if n := s.nodes[id]; v < n.vert_first + n.vert_count do moved[id] = true
	}
	ids := make([dynamic]u32, context.temp_allocator)
	for m, id in moved do if m do append(&ids, u32(id))
	sculptor_nodes_moved(s, ids[:])
	history_seal(&s.history)
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
		for f in faces_of(s, v) {
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
		s.chunks[id].bounds = s.bvh.nodes[n.leaf].bounds if n.leaf != geom.BVH_NONE else geom.AABB_EMPTY
		s.chunks[id].cone_cutoff = 1
		s.chunks[id].index_count = 3 * n.tri_count
		chunk_touched(s, id)
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
		faces := faces_of(s, v)
		stale := false
		for f in faces {
			if f - n.tri_first < n.tri_count do continue // its own triangle
			if s.stale[tri_node(s, f)] == .Shape {
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
		bounds      = s.bvh.nodes[n.leaf].bounds if n.leaf != geom.BVH_NONE else geom.AABB_EMPTY,
		cone_axis   = axis,
		cone_cutoff = cutoff,
		first_index = 3 * n.tri_first,
		index_count = 3 * n.tri_count,
	}
	chunk_touched(s, id)
}

// Marks the group of chunk `id` for making again. Chunks of one group may be updated on
// different threads; each only ever sets the flag.
@(private)
chunk_touched :: #force_inline proc(s: ^Sculptor, id: u32) {
	if g := int(id) / geom.CHUNK_GROUP; g < len(s.group_stale) do s.group_stale[g] = true
}

// The chunk groups for geom.cull_chunks_grouped, made again where a chunk changed; nil
// under dynamic topology, whose chunks come and go (cull them one by one then). Call
// after sculptor_flush.
sculptor_chunk_groups :: proc(s: ^Sculptor) -> []geom.Chunk {
	if s.dyn != nil {
		clear(&s.chunk_groups)
		clear(&s.group_stale)
		return nil
	}
	count := (len(s.chunks) + geom.CHUNK_GROUP - 1) / geom.CHUNK_GROUP
	if len(s.chunk_groups) != count {
		resize(&s.chunk_groups, count)
		resize(&s.group_stale, count)
		for &x in s.group_stale do x = true
	}
	for &stale, g in s.group_stale {
		if !stale do continue
		lo := g * geom.CHUNK_GROUP
		s.chunk_groups[g] = geom.chunk_group(s.chunks[lo:min(lo + geom.CHUNK_GROUP, len(s.chunks))])
		stale = false
	}
	return s.chunk_groups[:]
}

// Unnormalized: its length is twice the triangle's area, which weights vertex normals.
@(private)
face_normal :: #force_inline proc(m: ^geom.Mesh, f: u32) -> Vec3 {
	p0 := m.positions[m.indices[3 * f]]
	p1 := m.positions[m.indices[3 * f + 1]]
	p2 := m.positions[m.indices[3 * f + 2]]
	return linalg.cross(p1 - p0, p2 - p0)
}

// Closest intersection of a ray with the sculpted mesh, using the BVH. Hidden
// triangles are passed through.
sculptor_raycast :: proc(s: ^Sculptor, origin, dir: Vec3) -> (hit: Vec3, ok: bool) {
	t: f32
	t, _, ok = geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir, sculptor_hidden_tris(s))
	if ok do hit = origin + dir * t
	return
}

// sculptor_raycast with the triangle hit, in the sculptor's numbering.
sculptor_raycast_triangle :: proc(s: ^Sculptor, origin, dir: Vec3) -> (hit: Vec3, tri: u32, ok: bool) {
	t: f32
	t, tri, ok = geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir, sculptor_hidden_tris(s))
	if ok do hit = origin + dir * t
	return
}

// The most vertices sculptor_area_normal looks at: past this it takes every k-th one, so a
// brush ring as wide as the screen over a dense mesh still costs a small part of a frame
// (a 300 pixel ring over 10M vertices, release: 0.3 ms, half what 16384 cost, with the
// normal the same to four places).
AREA_NORMAL_MAX_VERTS :: 4096

// The way the surface faces under a brush of `radius` at `center` (local space), as the
// brushes work it out: vertex normals inside the sphere, weighted by the falloff. For the
// brush ring, which lies on the surface. Normals facing away from `facing` (the normal of
// the triangle under the pointer) are left out, so the far side of a thin part does not
// tip the ring over. Reads only; serial, on the calling thread, in the leaves' order, so
// it is the same every time for the same mesh.
sculptor_area_normal :: proc(s: ^Sculptor, center: Vec3, radius: f32, facing: Vec3) -> (normal: Vec3, ok: bool) {
	if radius <= 0 do return
	leaves := make([dynamic]u32, context.temp_allocator)
	geom.bvh_query_leaves(&s.bvh, center, radius, &leaves)
	total: u32
	for leaf in leaves {
		first, last := owned(s, leaf)
		total += last - first
	}
	stride := max((total + AREA_NORMAL_MAX_VERTS - 1) / AREA_NORMAL_MAX_VERTS, 1)
	m := s.mesh
	r2, inv_r2 := radius * radius, 1 / (radius * radius)
	sum: Vec3
	// Counted over every leaf's vertices in turn: the next one to look at, and how many
	// the leaves before this one hold.
	next, seen: u32
	for leaf in leaves {
		first, last := owned(s, leaf)
		count := last - first
		for ; next < seen + count; next += stride {
			v := first + (next - seen)
			delta := m.positions[v] - center
			d2 := linalg.dot(delta, delta)
			if d2 >= r2 do continue
			n := m.normals[v]
			if linalg.dot(n, facing) <= 0 do continue
			sum += n * falloff(d2 * inv_r2)
		}
		seen += count
	}
	if sum == {} do return
	return linalg.normalize(sum), true
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
