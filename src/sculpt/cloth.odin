package sculpt

import "core:math"
import "core:math/linalg"
import "base:runtime"
import "core:slice"

import "../geom"
import "../jobs"

// The cloth solver: for the length of a stroke, the surface in and around the brush
// behaves like a sheet of cloth. Its edges keep their lengths (position-based dynamics:
// Verlet steps, then rounds of edge constraints), so what the brush drags, pulls in or
// lets sag gathers into folds and wrinkles instead of stretching, as Blender's cloth brush
// and ZBrush's Dynamics do. Unlike Blender's, which solves one constraint list serially
// (Gauss-Seidel), every round here is a Jacobi round: each vertex reads only the last
// round's positions, so the result is bit for bit the same on any number of threads.
//
// Everything is simulated in the mesh's space, in a region (Cloth_Region) around the
// brush; the region's rim and masked or hidden vertices are held where they were, so the
// cloth stays sewn to the rest of the mesh. Under symmetry the region is the union of the
// regions round every image of the brush, and each vertex follows the images it lies in,
// blended by their falloff, so the two halves move as mirror images and the seam between
// them stays smooth.
Cloth_Mode :: enum u8 {
	Drag,       // what is under the brush follows the pointer; the rest of the region follows as cloth
	Push,       // the brush presses the cloth in along the surface's normal, so it buckles round the dent
	Pinch,      // the brush pulls the cloth toward its centre: it bunches into folds
	Pinch_Line, // the brush pulls the cloth toward a line along the stroke: one fold runs with it
	Inflate,    // the cloth under the brush swells out along its own normals, puckering round the edge
	Expand,     // the brush pushes the cloth out from its centre: it buckles into ridges
	Twist,      // the cloth under the brush turns about the surface's normal: it wrings into a spiral
	Wind,       // gusts blow the cloth along the stroke and let it flutter back
}

// Which part of the mesh a cloth stroke simulates.
Cloth_Region :: enum u8 {
	Local,   // CLOTH_REACH brush radii round where the stroke began, for the whole stroke
	Follows, // the same reach round the brush as it moves, gathered again every half radius
	Whole,   // every vertex of the mesh, held only by the mask and hiding
}

// How the cloth behaves, the same for every mode. The defaults are the cloth the brush
// has always made.
Cloth_Settings :: struct {
	region:       Cloth_Region,
	stiffness:    f32, // 0..1: how firmly edges keep their length (ZBrush's Strength)
	firmness:     f32, // 0..1: how much the cloth resists bending, so folds grow wider and fewer
	damping:      f32, // 0..1: the share of its velocity the cloth loses a step
	gravity:      f32, // 0..1: how hard it is pulled `down` (sculptor_cloth_step) in any mode
	// Keep area: edges keep the lengths of the stored morph target (sculptor_morph_store)
	// rather than of where the stroke began, so a stretched part shrinks back as it moves.
	keep_area:    bool,
	allow_shrink: bool, // edges may grow shorter freely: the cloth crumples without pushing back
	allow_expand: bool, // edges may grow longer freely: the cloth stretches like rubber
	// What it collides with (cloth_collide.odin): the floor and the other objects, which
	// the app gives it (sculptor_cloth_collide), and its own far parts.
	floor:        bool,
	objects:      bool,
	self_collide: bool,
	// On masked (ZBrush's): the mask picks the cloth instead of holding it, so the masked
	// part moves and the rest stays; hiding still holds what it hides.
	on_masked:    bool,
}

// What runs the cloth: a brush stroke or Physics (the Cloth brush's modes, or targets the
// tool sets), Settle (nothing but gravity and the collisions, ZBrush's Run Simulation) or
// a filter (sculptor_filter_begin), whose targets are the model inflated, expanded or
// scaled.
Cloth_Run :: enum u8 {
	Brush,
	Settle,
	Filter,
}

// The Physics card's filters, as Blender's cloth filter: the free part is pulled toward
// the shape the filter makes of it, and stays cloth on the way, so it folds instead of
// stretching.
Cloth_Filter_Kind :: enum u8 {
	Inflate, // out along the normals (in for a negative amount)
	Expand,  // away from the free part's middle (toward it for a negative amount)
	Scale,   // scaled about the middle along the chosen axes, from half to twice the size
}

Cloth_Filter :: struct {
	kind:   Cloth_Filter_Kind,
	frame:  matrix[3, 3]f32, // Scale: the axes it scales along, as columns in the mesh's space
	axes:   bit_set[Axis],   // Scale: which of them
	middle: Vec3,            // the free part's mean, which Expand and Scale go about
}

CLOTH_DEFAULTS :: Cloth_Settings {
	region    = .Local,
	stiffness = 1,
	firmness  = 0.5,
	damping   = 0.08,
}

Cloth :: struct {
	mode:       Cloth_Mode,
	settings:   Cloth_Settings,
	invert:     bool,
	center:     Vec3, // where the stroke began
	gathered:   Vec3, // where the brush was when the region was last gathered
	normal_at:  Vec3, // the surface's normal under the brush when the stroke began
	dir:        Vec3, // the way the stroke is going, smoothed: Pinch line and Wind
	last:       Vec3, // the offset the last step reached, for substeps and the stroke's way
	radius:     f32,
	strength:   f32,
	link_mean:  f32, // the mean link length: substeps keep each move under a link
	reach:      f32, // how far the region reaches round the brush, in radii
	// Physics (sculptor_physics_begin): how hard each round pulls a vertex toward where
	// the tool driving it put it (its target), or 0 for the Cloth brush's own modes.
	follow:     f32,
	// Physics on a pose (sculptor_pose_physics): a vertex keeps its last target through
	// frames the pose did not set it, as a pose holds still while the pointer does.
	hold:       bool,
	run:        Cloth_Run,
	filter:     Cloth_Filter,
	// The largest move a vertex made in the last step, in mean links, which tells Settle
	// when the cloth has come to rest.
	motion:     f32,
	steps:      int, // steps taken this stroke, which ease the target modes in
	brush:      Brush, // for the falloff shape and the symmetry, as the stroke began
	images:     [dynamic; SYM_IMAGES_MAX]Sym_Image,
	leaves:     [dynamic]u32, // BVH leaves of the region, sorted
	nodes:      [dynamic]u32, // ...their nodes, for sculptor_nodes_moved
	verts:      [dynamic]u32, // the simulated vertices, ascending
	pos:        [dynamic]Vec3, // ...where they are
	prev:       [dynamic]Vec3, // ...where they were a step ago (their velocity is the difference)
	next:       [dynamic]Vec3, // scratch for the step under way
	rest:       [dynamic]Vec3, // ...where they were when they joined the region
	normal:     [dynamic]Vec3, // ...their normals then: the way squeezed cloth buckles
	base:       [dynamic]Vec3, // ...the stroke's offset then, from which Drag measures
	pin:        [dynamic]f32, // how firmly each is held at rest: 1 at the rim, where masked or hidden
	drive:      [dynamic]f32, // the brush's falloff weight on each, 0 outside it
	turn:       [dynamic]matrix[3, 3]f32, // the images it lies in, their turns blended by falloff
	focus:      [dynamic]Vec3, // ...their centres, blended the same way
	target:     [dynamic]Vec3, // Physics: where the driving tool put each vertex this frame
	first:      [dynamic]u32, // per vertex: where its edge links start; one more at the end
	links:      [dynamic]u32, // a neighbour's index in verts, or CLOTH_FIXED for one outside the region
	length:     [dynamic]f32, // each link's rest length
	anchor:     [dynamic]Vec3, // each link's neighbour position when that neighbour is outside the region
	bend_first: [dynamic]u32, // the same for the bend links, across each edge to the far corner
	bend:       [dynamic]u32,
	bend_len:   [dynamic]f32,
	bend_at:    [dynamic]Vec3,
	collide:    Cloth_Collisions, // what it collides with this stroke
	// Self collision's grid (cloth_self_grid): the cell size, each vertex's slot, and the
	// vertices by slot.
	self_cell:  f32,
	self_slot:  [dynamic]u32,
	self_first: [dynamic]u32,
	self_order: [dynamic]u32,
}

// How far around the brush the cloth reaches, in brush radii: far enough for folds to
// form around what the brush moves, small enough that a 10M-vertex mesh steps in a few
// milliseconds.
CLOTH_REACH :: 1.6
// Share of the region's radius from which vertices are increasingly held at rest, so
// the cloth's edge blends into the fixed mesh instead of creasing at the rim.
CLOTH_PIN_FROM :: 0.7
// Constraint rounds a step. More stiffen the cloth (folds get larger and smoother) at a
// proportional cost.
CLOTH_ITERATIONS :: 5
// How far each Jacobi round moves a vertex toward satisfying its links: above 1 over-
// relaxes, which converges faster; below 2 stays stable.
CLOTH_RELAX :: 1.4
// Gravity a step at full Gravity, in brush radii. Each vertex is also sprung back toward
// where it began by CLOTH_RESTORE of the way while anything pulls it, so the cloth hangs
// at about CLOTH_GRAVITY / CLOTH_RESTORE radii instead of falling for ever.
CLOTH_GRAVITY :: 0.012
// Settle's gravity a step at full Gravity, in mean links: the cloth falls at most about
// CLOTH_SETTLE_GRAVITY / damping links a step, a few, which the substeps keep from
// tunnelling through a collider.
CLOTH_SETTLE_GRAVITY :: 0.15
// How hard a filter's targets pull the cloth each round: low enough that the cloth folds
// on the way rather than snapping to the filtered shape.
CLOTH_FILTER_FOLLOW :: 0.05
CLOTH_RESTORE :: 0.02
// The target modes move what is under the brush up to this share of the way (of the
// distance to the centre, or of the radius), times strength, eased in over
// CLOTH_EASE_STEPS steps, so a held stroke settles instead of crushing the region.
CLOTH_PINCH_MAX :: 0.55
CLOTH_EASE_STEPS :: 40
// Push and Inflate at full strength move the surface this share of the radius.
CLOTH_PUSH :: 0.5
// Twist at full strength turns the middle of the brush this far.
CLOTH_TWIST :: math.PI / 2
// Wind a step at full strength, in brush radii, and how its gusts come and go: a wave
// across the region in steps and in radii.
CLOTH_WIND :: 0.02
CLOTH_GUST_STEPS :: 0.35
CLOTH_GUST_WAVES :: 2.5
// How far squeezed cloth puffs out along its normal, per unit of average compression of
// its links, in link lengths: squeezed cloth then folds outward together instead of
// crumpling either way at random.
CLOTH_BUCKLE :: 1.5
// Bending from Firmness 0.5 up: each round moves a vertex's displacement this share of
// the way toward its neighbours' average (less below 0.5), which keeps folds smooth rather
// than jagged at high resolution without flattening the shape underneath. At Firmness 1
// the bend links (to the far corner across each edge) are pulled to their lengths this
// share as hard as the edges too, fading in from 0.5; they are gathered only for a stroke
// that begins above 0.5, so the default costs no more than the edges alone.
CLOTH_BEND :: 0.3
CLOTH_BEND_LINKS :: 0.5
// Substeps a step at most, when the pointer moves further than a link a step, and the
// fewest constraint rounds each takes.
CLOTH_SUBSTEPS :: 4
CLOTH_SUBSTEP_ROUNDS :: 2
// How quickly the stroke's way follows the pointer: the share of a new move it takes.
CLOTH_DIR_FOLLOW :: 0.3
// The reach that takes in every vertex of a mesh.
CLOTH_WHOLE_REACH :: 1e18
// A link whose neighbour is outside the region and stays put.
CLOTH_FIXED :: max(u32)
// Links a vertex keeps, far more than any vertex of a sculpted mesh has neighbours.
CLOTH_MAX_LINKS :: 64
// Simulated vertices a job takes.
CLOTH_CHUNK :: 4096

@(private)
Cloth_Job :: struct {
	s:       ^Sculptor,
	offset:  Vec3, // how far the brush has dragged from where it started
	center:  Vec3, // where the brush is now
	force:   Vec3, // gravity added to each free vertex's position a step
	wind:    Vec3, // the way the wind blows, times its strength a step
	keep:    f32, // velocity kept a step
	ease:    f32, // how far the target modes have eased in
	restore: f32, // the spring back toward rest while a force pulls
	pull:    f32, // Physics: how far each round pulls a driven vertex toward its target
	moves:   []f32, // Physics: each chunk's largest move by the tool this frame
	// Gathering, for the region's arrays to come from the last region's.
	old_verts: []u32,
	old_pos, old_prev, old_rest, old_normal, old_base: []Vec3,
	morph:   []Vec3, // Keep area's rest shape, or nil
	found:   []Cloth_Found, // each chunk's links, while the region is gathered
	bends:   bool, // ...and whether to gather the bend links: the stroke began firm
}

// One link as gathering finds it (cloth_link).
@(private)
Cloth_Link :: struct {
	link:   u32,
	anchor: Vec3,
	length: f32,
}

// A chunk's links, in its vertices' order.
@(private)
Cloth_Found :: struct {
	edges, bends: [dynamic]Cloth_Link,
}

// Starts a cloth stroke around `center` (mesh space) in `mode`, with the brush's radius,
// strength, invert, falloff and symmetry and the cloth's settings. Call inside a stroke
// (sculptor_stroke_begin) for it to be undoable. Returns how many vertices it simulates.
sculptor_cloth_begin :: proc(s: ^Sculptor, brush: Brush, center: Vec3, mode: Cloth_Mode, settings := CLOTH_DEFAULTS) -> int {
	return cloth_start(s, brush, center, mode, settings, CLOTH_REACH, 0)
}

@(private = "file")
cloth_start :: proc(s: ^Sculptor, brush: Brush, center: Vec3, mode: Cloth_Mode, settings: Cloth_Settings, reach, follow: f32, run := Cloth_Run.Brush) -> int {
	c := &s.cloth
	if c.leaves == nil do cloth_init(c, s.history.allocator)
	sculptor_cloth_end(s)
	c.run = run
	c.mode, c.settings, c.invert = mode, settings, brush.invert
	c.reach, c.follow = reach, clamp(follow, 0, 1)
	c.center, c.radius, c.strength, c.brush = center, brush.radius, brush.strength, brush
	c.images = symmetry_images(brush)
	normal, ok := sculptor_area_normal(s, center, brush.radius, brush.facing)
	if !ok do normal = nearest_normal(s, center, brush.radius)
	c.normal_at = linalg.normalize0(normal)
	if c.normal_at == {} do c.normal_at = {0, 0, 1}
	// Until the stroke goes anywhere, its way is across the surface.
	side := Vec3{1, 0, 0} if abs(c.normal_at.x) < 0.9 else Vec3{0, 1, 0}
	c.dir = linalg.normalize(linalg.cross(c.normal_at, side))
	return cloth_gather(s, center, {})
}

// Gathers the region round `at` (where the brush is, the stroke `offset` from where it
// began): its leaves, recorded for undo, its vertices with their pins, drives and
// images, and its links. Vertices that were in the last region keep where they are,
// their velocity and their rest; new ones join where they are.
@(private = "file")
cloth_gather :: proc(s: ^Sculptor, at, offset: Vec3) -> int {
	c := &s.cloth
	set := c.settings
	reach := c.radius * c.reach if set.region != .Whole else CLOTH_WHOLE_REACH
	c.gathered = at
	clear(&c.leaves)
	for img in c.images {
		centre := sym_point(img, c.brush.sym_center, at)
		if set.region != .Whole do stretch_note(s, centre, reach, {}, c.brush.radius * c.brush.detail)
		geom.bvh_query_leaves(&s.bvh, centre, reach, &c.leaves)
		if set.region == .Whole do break
	}
	slice.sort(c.leaves[:])
	resize(&c.leaves, len(slice.unique(c.leaves[:])))
	if len(c.leaves) == 0 do return cloth_abandon(s)
	clear(&c.nodes)
	for leaf in c.leaves do append(&c.nodes, s.node_of[leaf])
	slice.sort(c.nodes[:])
	resize(&c.nodes, len(slice.unique(c.nodes[:])))

	// What the last region held, to carry over; copies, as the arrays are refilled.
	j := Cloth_Job{s = s, offset = offset, center = at}
	if len(c.verts) > 0 {
		j.old_verts = slice.clone(c.verts[:], context.temp_allocator)
		j.old_pos = slice.clone(c.pos[:], context.temp_allocator)
		j.old_prev = slice.clone(c.prev[:], context.temp_allocator)
		j.old_rest = slice.clone(c.rest[:], context.temp_allocator)
		j.old_normal = slice.clone(c.normal[:], context.temp_allocator)
		j.old_base = slice.clone(c.base[:], context.temp_allocator)
	}
	for a in ([?]^[dynamic]Vec3{&c.pos, &c.prev, &c.rest, &c.normal, &c.base, &c.focus, &c.target}) do clear(a)
	clear(&c.verts)
	clear(&c.pin)
	clear(&c.drive)
	clear(&c.turn)

	// Nodes own ascending, contiguous vertex ranges, so walking them in id order lists
	// the region's vertices in ascending order, which the link lookup below relies on.
	m := s.mesh
	reach2 := reach * reach
	old := 0
	kept := 0 // nodes holding a simulated vertex, moved to the front of c.nodes
	for id in c.nodes {
		n := s.nodes[id]
		joined := len(c.verts)
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			p := m.positions[v]
			near2 := f32(math.F32_MAX)
			for img in c.images {
				near2 = min(near2, linalg.length2(p - sym_point(img, c.brush.sym_center, at)))
				if set.region == .Whole do break
			}
			if near2 >= reach2 do continue
			w := cloth_weight(s, v)
			// Over the whole model a masked or hidden vertex is held where it is, which
			// its neighbours' links see as well outside the region as in it, so it stays
			// out: a pose of a small free part simulates that part alone.
			if set.region == .Whole && w <= 0 do continue
			pin := 1 - w
			if set.region != .Whole do pin = max(smoothstep(CLOTH_PIN_FROM, 1, linalg.sqrt(near2) / reach), pin)
			for old < len(j.old_verts) && j.old_verts[old] < v do old += 1
			append(&c.verts, v)
			append(&c.pin, pin)
			append(&c.drive, 0)
			append(&c.turn, 1)
			append(&c.focus, at)
			append(&c.target, {})
			if old < len(j.old_verts) && j.old_verts[old] == v {
				append(&c.pos, j.old_pos[old])
				append(&c.prev, j.old_prev[old])
				append(&c.rest, j.old_rest[old])
				append(&c.normal, j.old_normal[old])
				append(&c.base, j.old_base[old])
			} else {
				append(&c.pos, p)
				append(&c.prev, p)
				append(&c.rest, p)
				append(&c.normal, m.normals[v] if int(v) < len(m.normals) else Vec3{})
				append(&c.base, offset)
			}
		}
		if len(c.verts) > joined {
			c.nodes[kept] = id
			kept += 1
		}
	}
	resize(&c.nodes, kept)
	if !slice.is_sorted(c.verts[:]) || kept == 0 do return cloth_abandon(s)
	// Only what the cloth can move is recorded for undo and refreshed each step.
	clear(&s.hit)
	for id in c.nodes do append(&s.hit, s.nodes[id].leaf)
	if s.history.recording do record_hit(s, masks = false)
	n := len(c.verts)
	resize(&c.next, n)
	cloth_drives(s, at)

	// Keep area measures the links on the morph target, when there is one for this mesh.
	if set.keep_area && len(s.morph) == len(m.positions) do j.morph = s.morph
	j.bends = set.firmness > 0.5

	// Links: every other corner of every triangle around each vertex, once, and every far
	// corner across those triangles' outer edges (the bend links). One pass finds them a
	// chunk of vertices per job into the chunk's own lists, a second copies the lists into
	// place once the counts are summed; at 10M vertices a region holds a few hundred
	// thousand.
	resize(&c.first, n + 1)
	resize(&c.bend_first, n + 1)
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	chunks := (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK
	j.found = make([]Cloth_Found, chunks, context.temp_allocator)
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		s := j.s
		c := &s.cloth
		f := &j.found[k]
		f.edges = make([dynamic]Cloth_Link, 0, CLOTH_CHUNK * 7, runtime.heap_allocator())
		f.bends = make([dynamic]Cloth_Link, 0, CLOTH_CHUNK * 7, runtime.heap_allocator())
		near, far: [dynamic; CLOTH_MAX_LINKS]u32
		lo, hi := cloth_range(c, k)
		for i in lo ..< hi {
			v := c.verts[i]
			cloth_near(s, v, &near, &far, j.bends)
			c.first[i + 1] = u32(len(near))
			c.bend_first[i + 1] = u32(len(far))
			for u in near do append(&f.edges, cloth_link(j, i, v, u))
			for u in far do append(&f.bends, cloth_link(j, i, v, u))
		}
	})
	c.first[0], c.bend_first[0] = 0, 0
	for i in 0 ..< n {
		c.first[i + 1] += c.first[i]
		c.bend_first[i + 1] += c.bend_first[i]
	}
	resize(&c.links, int(c.first[n]))
	resize(&c.length, int(c.first[n]))
	resize(&c.anchor, int(c.first[n]))
	resize(&c.bend, int(c.bend_first[n]))
	resize(&c.bend_len, int(c.bend_first[n]))
	resize(&c.bend_at, int(c.bend_first[n]))
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		c := &j.s.cloth
		f := &j.found[k]
		lo, _ := cloth_range(c, k)
		at := int(c.first[lo])
		for l, e in f.edges do c.links[at + e], c.anchor[at + e], c.length[at + e] = l.link, l.anchor, l.length
		at = int(c.bend_first[lo])
		for l, e in f.bends do c.bend[at + e], c.bend_at[at + e], c.bend_len[at + e] = l.link, l.anchor, l.length
		delete(f.edges)
		delete(f.bends)
	})
	total: f64
	for l in c.length do total += f64(l)
	c.link_mean = f32(total / f64(max(len(c.length), 1)))
	return n
}

// One link from vertex `v` (index `i` in the region) to `u`: `u`'s index in the region, or
// CLOTH_FIXED and where it stays; and its rest length, measured between where both rest
// (or on the morph target, under Keep area).
@(private = "file")
cloth_link :: proc(j: ^Cloth_Job, i: int, v, u: u32) -> Cloth_Link {
	c := &j.s.cloth
	at, found := slice.binary_search(c.verts[:], u)
	there := c.rest[at] if found else j.s.mesh.positions[u]
	length := linalg.length(there - c.rest[i])
	if j.morph != nil do length = linalg.length(j.morph[u] - j.morph[v])
	if found do return {u32(at), {}, length}
	return {CLOTH_FIXED, j.s.mesh.positions[u], length}
}

// The other corners of the triangles around `v`, each once (`near`), and the corners
// across those triangles' far edges, each once and not already near (`far`), at most
// CLOTH_MAX_LINKS each (`far` only when `bends`); under dynamic topology from its own triangle lists, which the
// stroke keeps as they are until the repair at its end.
@(private = "file")
cloth_near :: proc(s: ^Sculptor, v: u32, near, far: ^[dynamic; CLOTH_MAX_LINKS]u32, bends: bool) {
	clear(near)
	clear(far)
	ids := s.mesh.indices
	tris := dyn_faces(s.dyn, v) if s.dyn != nil else geom.vertex_faces_of(s.faces, v)
	for tri in tris {
		for k in 0 ..< 3 {
			u := ids[3 * tri + u32(k)]
			if u == v || slice.contains(near[:], u) do continue
			if len(near) == CLOTH_MAX_LINKS do return
			append(near, u)
		}
	}
	if !bends do return
	for tri in tris {
		// The edge of this triangle that faces away from v, and the triangle across it.
		k := 0
		for k < 3 && ids[3 * tri + u32(k)] != v do k += 1
		if k == 3 do continue
		a, b := ids[3 * tri + u32((k + 1) % 3)], ids[3 * tri + u32((k + 2) % 3)]
		across := dyn_faces(s.dyn, a) if s.dyn != nil else geom.vertex_faces_of(s.faces, a)
		for other in across {
			if other == tri do continue
			w := CLOTH_FIXED
			has_b := false
			for q in 0 ..< 3 {
				x := ids[3 * other + u32(q)]
				if x == b do has_b = true
				else if x != a do w = x
			}
			if !has_b || w == CLOTH_FIXED || w == v || slice.contains(near[:], w) || slice.contains(far[:], w) do continue
			if len(far) == CLOTH_MAX_LINKS do return
			append(far, w)
		}
	}
}

// The brush's weight on every vertex of the region with the brush at `at`, and the images
// each follows: every image's falloff (times what the mask and hiding leave), the turns
// and centres blended by it, the weight itself the strongest image's.
@(private = "file")
cloth_drives :: proc(s: ^Sculptor, at: Vec3) {
	c := &s.cloth
	n := len(c.verts)
	j := Cloth_Job{s = s, center = at}
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	jobs.parallel_for(pool, (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		s := j.s
		c := &s.cloth
		r2 := c.radius * c.radius
		lo, hi := cloth_range(c, k)
		for i in lo ..< hi {
			p := c.rest[i]
			total, strongest: f32
			turn: matrix[3, 3]f32
			focus: Vec3
			for img in c.images {
				centre := sym_point(img, c.brush.sym_center, j.center)
				d2 := linalg.length2(p - centre) / r2
				w := falloff_drawn(c.brush.falloff_shape, d2) if c.brush.falloff_shape != nil else falloff(d2)
				if w <= 0 do continue
				total += w
				strongest = max(strongest, w)
				turn += img.turn * (matrix[3, 3]f32)(w) // a scalar as a matrix is its diagonal
				focus += centre * w
			}
			if total > 0 {
				c.turn[i], c.focus[i] = turn * (matrix[3, 3]f32)(1 / total), focus / total
			} else {
				c.turn[i], c.focus[i] = 1, j.center
			}
			c.drive[i] = strongest * shield(s.fade, s.mask, c.verts[i])
			// Settle and the filters drive nothing by a brush: Settle pulls only by gravity,
			// and a filter sets its targets each step.
			if c.run != .Brush do c.turn[i], c.focus[i], c.drive[i] = 1, j.center, 0
		}
	})
}

// One step of the cloth: Verlet with the mode's pull and gravity, then the edge and bend
// constraints, then the positions written back. `offset` is how far the pointer has
// dragged from where the stroke began and `down` the way gravity pulls (unit length),
// both in the mesh's space. A step whose pointer moved more than a link runs as up
// to CLOTH_SUBSTEPS smaller steps, so a fast drag neither tears nor overshoots. Returns
// how many vertices it simulates. Like apply_dab, it leaves positions and BVH bounds
// current and normals to sculptor_flush.
sculptor_cloth_step :: proc(s: ^Sculptor, offset, down: Vec3) -> int {
	c := &s.cloth
	n := len(c.verts)
	if n == 0 || len(c.first) != n + 1 do return 0
	set := c.settings
	moved := offset - c.last
	if linalg.length(moved) > c.radius * 1e-3 {
		c.dir = linalg.normalize0(linalg.lerp(c.dir, linalg.normalize(moved), CLOTH_DIR_FOLLOW))
		if c.dir == {} do c.dir = linalg.normalize(moved)
	}
	// The Follows region keeps up with the brush, which is where the pointer has dragged.
	at := c.center + offset if set.region == .Follows else c.center
	if set.region == .Follows && linalg.length(at - c.gathered) > c.radius * 0.5 {
		if cloth_gather(s, at, offset) == 0 do return 0
		n = len(c.verts)
	} else if set.region == .Follows {
		cloth_drives(s, at)
	}
	return cloth_advance(s, at, offset, linalg.length(moved), down)
}

// Starts physics on what a tool moves (the Physics switch): the surface round `center`
// becomes cloth the tool drives. Each frame the tool moves vertices as it always does,
// then sculptor_physics_step takes where it put them as targets, puts the cloth back
// where it was and lets each round pull the cloth toward them by `follow` (0..1), so
// the moved part carries the surface round it along in folds, swings past and settles,
// as Blender's cloth deformation and ZBrush's Dynamics brushes do. `reach` is in brush
// radii; Follows gathers again round where each step says the tool is. Gravity and the
// rest come from `settings`. Call inside a stroke, before the tool first moves anything.
sculptor_physics_begin :: proc(s: ^Sculptor, brush: Brush, center: Vec3, follow: f32, reach: f32 = CLOTH_REACH, settings := CLOTH_DEFAULTS) -> int {
	b := brush
	b.invert = false
	return cloth_start(s, b, center, .Drag, settings, reach, max(follow, 1e-3))
}

// One step of physics after the tool has moved this frame: every vertex of the region the
// tool moved (its position no longer the cloth's) takes where it went as its target, and
// the cloth steps toward the targets and writes itself back. `at` is where the tool is now
// (mesh space), which a Follows region keeps up with; `down` is the way gravity pulls.
// Returns how many vertices it simulates.
sculptor_physics_step :: proc(s: ^Sculptor, at, down: Vec3) -> int {
	c := &s.cloth
	if c.follow <= 0 || len(c.verts) == 0 || len(c.first) != len(c.verts) + 1 do return 0
	offset := at - c.center
	if c.settings.region == .Follows && linalg.length(at - c.gathered) > c.radius * 0.5 {
		if cloth_gather(s, at, offset) == 0 do return 0
	}
	n := len(c.verts)
	j := Cloth_Job{s = s}
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	chunks := (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK
	j.moves = make([]f32, chunks, context.temp_allocator)
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		c := &j.s.cloth
		m := j.s.mesh
		lo, hi := cloth_range(c, k)
		most: f32
		for i in lo ..< hi {
			p := m.positions[c.verts[i]]
			if p == c.pos[i] {
				if !c.hold do c.drive[i] = 0
				continue
			}
			c.target[i], c.drive[i] = p, 1
			most = max(most, linalg.length(p - c.pos[i]))
		}
		j.moves[k] = most
	})
	most: f32
	for x in j.moves do most = max(most, x)
	return cloth_advance(s, at, offset, most, down)
}

// Steps the cloth with the brush at `at` (the stroke `offset` from where it began) after
// it moved `moved` this frame, in substeps when that is over a link, and writes the
// positions back.
@(private = "file")
cloth_advance :: proc(s: ^Sculptor, at, offset: Vec3, moved: f32, down: Vec3) -> int {
	c := &s.cloth
	set := c.settings
	n := len(c.verts)
	sub := 1
	if c.link_mean > 0 do sub = clamp(int(math.ceil(moved / c.link_mean)), 1, CLOTH_SUBSTEPS)
	// Small steps (Macklin et al. 2019): substeps converge better than rounds, so each
	// takes fewer, and a fast drag costs at most CLOTH_SUBSTEPS * CLOTH_SUBSTEP_ROUNDS.
	rounds := CLOTH_ITERATIONS if sub == 1 else max(CLOTH_ITERATIONS / sub, CLOTH_SUBSTEP_ROUNDS)
	// Verlet in substeps of a share 1/sub of a step: forces scale with the step squared,
	// damping by its power, so the cloth moves the same however many substeps it took.
	dt := 1 / f32(sub)
	sign: f32 = -1 if c.invert else 1
	j := Cloth_Job{s = s, center = at}
	j.keep = math.pow(1 - clamp(set.damping, 0, 1), dt)
	j.ease = min(f32(c.steps + 1) / CLOTH_EASE_STEPS, 1) * c.strength * CLOTH_PINCH_MAX
	if set.gravity > 0 && c.run == .Settle {
		// Settle lets the cloth fall freely, as far as the collisions and what holds it
		// let it, at a pace of links so a dense mesh falls no faster than a coarse one.
		j.force = down * (c.link_mean * clamp(set.gravity, 0, 1) * CLOTH_SETTLE_GRAVITY * dt * dt)
	} else if set.gravity > 0 && c.run == .Brush {
		g := c.radius * clamp(set.gravity, 0, 1) * CLOTH_GRAVITY * dt * dt
		// Inverting a Drag stroke lets the cloth float up rather than sag.
		if c.mode == .Drag do g *= sign
		j.force = down * g
		j.restore = CLOTH_RESTORE * dt
	}
	if c.mode == .Wind && c.follow == 0 {
		j.wind = c.dir * (c.radius * c.strength * CLOTH_WIND * sign * dt * dt)
		j.restore = CLOTH_RESTORE * dt
	}
	// Physics pulls toward the targets each round, by Follow shared over the substeps.
	j.pull = 1 - math.pow(1 - c.follow, dt)
	c.steps += 1
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	chunks := (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK
	for k in 1 ..= sub {
		j.offset = linalg.lerp(c.last, offset, f32(k) / f32(sub))
		jobs.parallel_for(pool, chunks, &j, job_cloth_integrate)
		c.pos, c.next = c.next, c.pos
		for _ in 0 ..< rounds {
			jobs.parallel_for(pool, chunks, &j, job_cloth_constrain)
			c.pos, c.next = c.next, c.pos
		}
		if cloth_collides(c) {
			cloth_collide_pass(s, pool)
			c.pos, c.next = c.next, c.pos
		}
	}
	c.last = offset
	j.moves = make([]f32, chunks, context.temp_allocator)
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		c := &j.s.cloth
		m := j.s.mesh
		lo, hi := cloth_range(c, k)
		most: f32
		for i in lo ..< hi {
			v := c.verts[i]
			most = max(most, linalg.length2(c.pos[i] - m.positions[v]))
			m.positions[v] = c.pos[i]
		}
		j.moves[k] = most
	})
	most: f32
	for x in j.moves do most = max(most, x)
	c.motion = linalg.sqrt(most) / c.link_mean if c.link_mean > 0 else 0
	sculptor_nodes_moved(s, c.nodes[:])
	if s.history.recording do for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
	return n
}

// The cloth's settings for the stroke under way, which the next step uses: the sliders a
// panel shows can move while the button is held. The region only takes effect at the
// next stroke.
sculptor_cloth_settings :: proc(s: ^Sculptor, settings: Cloth_Settings) {
	region := s.cloth.settings.region
	s.cloth.settings = settings
	s.cloth.settings.region = region
}

// Forgets the simulation; the next cloth stroke starts afresh.
sculptor_cloth_end :: proc(s: ^Sculptor) {
	c := &s.cloth
	for a in ([?]^[dynamic]Vec3{&c.pos, &c.prev, &c.next, &c.rest, &c.normal, &c.base, &c.focus, &c.target, &c.anchor, &c.bend_at}) do clear(a)
	for a in ([?]^[dynamic]u32{&c.leaves, &c.nodes, &c.verts, &c.first, &c.links, &c.bend_first, &c.bend}) do clear(a)
	for a in ([?]^[dynamic]f32{&c.pin, &c.drive, &c.length, &c.bend_len}) do clear(a)
	clear(&c.turn)
	clear(&c.images)
	c.steps, c.last, c.link_mean, c.hold, c.run, c.motion = 0, {}, 0, false, .Brush, 0
	clear(&c.collide.colliders)
	c.collide = {colliders = c.collide.colliders}
}

// Nodes not in ascending vertex order cannot be looked up; that never happens for a
// sculptor's own partition, but a stroke on a mesh that breaks it moves nothing rather
// than tearing the cloth. A region with nothing in it ends the same way.
@(private = "file")
cloth_abandon :: proc(s: ^Sculptor) -> int {
	sculptor_cloth_end(s)
	return 0
}

@(private = "file")
cloth_range :: #force_inline proc(c: ^Cloth, k: int) -> (lo, hi: int) {
	return k * CLOTH_CHUNK, min((k + 1) * CLOTH_CHUNK, len(c.verts))
}

// How far the mode moves vertex `i` from where it rests, at full drive. Each is worked
// out for the brush itself and turned into the images the vertex follows: centres and
// the stroke's way through the blended turn, twists the other way in a mirror (the
// turn's determinant, which also fades them out on a mirror's plane, where the halves
// meet).
@(private = "file")
cloth_target :: #force_inline proc(j: ^Cloth_Job, c: ^Cloth, i: int, sign: f32) -> Vec3 {
	rest, turn, focus := c.rest[i], c.turn[i], c.focus[i]
	switch c.mode {
	case .Drag:
		return turn * (j.offset - c.base[i])
	case .Push:
		return linalg.normalize0(turn * c.normal_at) * (-sign * j.ease / CLOTH_PINCH_MAX * c.radius * CLOTH_PUSH)
	case .Pinch:
		return (focus - rest) * (j.ease * sign)
	case .Expand:
		return (rest - focus) * (j.ease * sign)
	case .Pinch_Line:
		side := linalg.normalize0(turn * linalg.cross(c.normal_at, c.dir))
		return -side * (linalg.dot(rest - focus, side) * j.ease * sign)
	case .Inflate:
		return c.normal[i] * (sign * j.ease / CLOTH_PINCH_MAX * c.radius * CLOTH_PUSH)
	case .Twist:
		axis := linalg.normalize0(turn * c.normal_at)
		if axis == {} do return {}
		angle := j.ease / CLOTH_PINCH_MAX * CLOTH_TWIST * sign * linalg.determinant(turn)
		arm := rest - focus
		return linalg.mul(linalg.quaternion_angle_axis(angle, axis), arm) - arm
	case .Wind:
	}
	return {}
}

// Verlet: each vertex carries on with its damped velocity plus gravity and the wind, the
// part under the brush goes where the mode puts it, and pinned vertices are held at rest.
@(private = "file")
job_cloth_integrate :: proc(data: rawptr, k: int) {
	j := cast(^Cloth_Job)data
	c := &j.s.cloth
	sign: f32 = -1 if c.invert else 1
	lo, hi := cloth_range(c, k)
	for i in lo ..< hi {
		p, rest, w, pin := c.pos[i], c.rest[i], c.drive[i], c.pin[i]
		q := p + (p - c.prev[i]) * j.keep
		pull := j.force
		if c.follow > 0 {
			// Physics: the targets pull in the rounds, and the tool's moves are not
			// velocity: the cloth carries on from where it was.
		} else if c.mode == .Wind {
			// Gusts: a wave that runs across the region, the same on every thread.
			phase := f32(c.steps) * CLOTH_GUST_STEPS + linalg.dot(rest - c.center, c.dir) / c.radius * CLOTH_GUST_WAVES
			wind := c.turn[i] * j.wind
			pull += wind * (w * (0.75 + 0.25 * math.sin(phase)))
		} else {
			q = linalg.lerp(q, rest + cloth_target(j, c, i, sign), w)
		}
		if j.restore > 0 do pull += (rest - p) * j.restore
		q += pull * (1 - pin)
		c.next[i] = linalg.lerp(q, rest, pin)
		c.prev[i] = p
	}
}

// One Jacobi round of the constraints: each vertex moves by the average of what its edge
// links ask, by what its bend links ask times Firmness (each only as far as Allow shrink
// and Allow expand leave), puffs out along its normal as far as its links are squeezed, and
// evens its displacement with its neighbours' (bending), all scaled by how free it is (not
// pinned, and not held by the brush). It reads only the previous round's positions, so
// the result is the same on any number of threads.
@(private = "file")
job_cloth_constrain :: proc(data: rawptr, k: int) {
	j := cast(^Cloth_Job)data
	c := &j.s.cloth
	set := c.settings
	// The brush holds what it drives in its own modes; Wind and Physics only pull it.
	held: f32 = 0 if c.mode == .Wind || c.follow > 0 else 1
	stiff := clamp(set.stiffness, 0, 1)
	// Firmness to a half evens displacements with the neighbours'; above it the bend links
	// take over as well, so the default costs nothing more than the edges.
	firm := clamp(set.firmness, 0, 1)
	even := min(firm * 2, 1) * CLOTH_BEND
	bends := max(firm * 2 - 1, 0) * CLOTH_BEND_LINKS
	lo, hi := cloth_range(c, k)
	for i in lo ..< hi {
		p := c.pos[i]
		free := (1 - c.pin[i]) * (1 - c.drive[i] * held)
		first, last := c.first[i], c.first[i + 1]
		if free <= 0 || last == first {
			c.next[i] = p
			continue
		}
		pull, moved: Vec3
		squeeze, span: f32
		for l in first ..< last {
			u := c.links[l]
			q, shift := c.anchor[l], Vec3{}
			if u != CLOTH_FIXED do q, shift = c.pos[u], c.pos[u] - c.rest[u]
			d := q - p
			dist := linalg.length(d)
			rest := c.length[l]
			short := dist < rest
			if dist > 1e-12 && !(short && set.allow_shrink) && !(!short && set.allow_expand) {
				pull += d * ((dist - rest) / dist)
				if rest > 0 do squeeze += max(rest - dist, 0) / rest
			}
			span += rest
			moved += shift
		}
		count := f32(last - first)
		// Each link's correction is shared by its two ends, hence the half.
		step := pull * (0.5 * CLOTH_RELAX * stiff / count)
		if b0, b1 := c.bend_first[i], c.bend_first[i + 1]; b1 > b0 && bends > 0 {
			bend: Vec3
			for l in b0 ..< b1 {
				u := c.bend[l]
				q := c.bend_at[l] if u == CLOTH_FIXED else c.pos[u]
				d := q - p
				dist, rest := linalg.length(d), c.bend_len[l]
				short := dist < rest
				if dist > 1e-12 && !(short && set.allow_shrink) && !(!short && set.allow_expand) do bend += d * ((dist - rest) / dist)
			}
			step += bend * (0.5 * CLOTH_RELAX * bends * stiff / f32(b1 - b0))
		}
		step += c.normal[i] * (squeeze / count * (span / count) * CLOTH_BUCKLE)
		step += (moved / count - (p - c.rest[i])) * even
		if j.pull > 0 && c.drive[i] > 0 do step += (c.target[i] - p) * j.pull
		c.next[i] = p + step * free
	}
}

@(private)
smoothstep :: #force_inline proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private)
cloth_init :: proc(c: ^Cloth, allocator := context.allocator) {
	for a in ([?]^[dynamic]Vec3{&c.pos, &c.prev, &c.next, &c.rest, &c.normal, &c.base, &c.focus, &c.target, &c.anchor, &c.bend_at}) do a^ = make([dynamic]Vec3, 0, 1024, allocator)
	for a in ([?]^[dynamic]u32{&c.leaves, &c.nodes, &c.verts, &c.first, &c.links, &c.bend_first, &c.bend}) do a^ = make([dynamic]u32, 0, 1024, allocator)
	for a in ([?]^[dynamic]f32{&c.pin, &c.drive, &c.length, &c.bend_len}) do a^ = make([dynamic]f32, 0, 1024, allocator)
	c.turn = make([dynamic]matrix[3, 3]f32, 0, 1024, allocator)
	c.collide.colliders = make([dynamic]Cloth_Collider, allocator)
	for a in ([?]^[dynamic]u32{&c.self_slot, &c.self_first, &c.self_order}) do a^ = make([dynamic]u32, allocator)
}

@(private)
cloth_destroy :: proc(c: ^Cloth) {
	for a in ([?]^[dynamic]Vec3{&c.pos, &c.prev, &c.next, &c.rest, &c.normal, &c.base, &c.focus, &c.target, &c.anchor, &c.bend_at}) do delete(a^)
	for a in ([?]^[dynamic]u32{&c.leaves, &c.nodes, &c.verts, &c.first, &c.links, &c.bend_first, &c.bend}) do delete(a^)
	for a in ([?]^[dynamic]f32{&c.pin, &c.drive, &c.length, &c.bend_len}) do delete(a^)
	delete(c.turn)
	delete(c.collide.colliders)
	for a in ([?]^[dynamic]u32{&c.self_slot, &c.self_first, &c.self_order}) do delete(a^)
	c^ = {}
}

// How free the cloth leaves vertex `v`: what the mask and hiding leave (shield), or with
// On masked what the mask covers, still held where hidden.
@(private)
cloth_weight :: #force_inline proc(s: ^Sculptor, v: u32) -> f32 {
	return cloth_free(s, v, s.cloth.settings.on_masked)
}

// The same, with or without On masked as `on_masked` says, outside a cloth run.
@(private)
cloth_free :: #force_inline proc(s: ^Sculptor, v: u32, on_masked: bool) -> f32 {
	if !on_masked do return shield(s.fade, s.mask, v)
	if s.mask == nil do return 0
	w := f32(s.mask[v]) * (1.0 / 255)
	if s.fade != nil do w *= f32(s.fade[v]) * (1.0 / 255)
	return w
}

// The cloth over the model's free part (the whole region), the brush a ball round the
// whole mesh, for Settle and the filters. Call inside a stroke for it to be undoable.
@(private = "file")
cloth_whole :: proc(s: ^Sculptor, settings: Cloth_Settings, follow: f32, run: Cloth_Run) -> int {
	if len(s.bvh.nodes) == 0 do return 0
	box := s.bvh.nodes[0].bounds
	set := settings
	set.region = .Whole
	b := Brush{radius = max(linalg.length(box.hi - box.lo) * 0.5, 1e-6), strength = 1}
	return cloth_start(s, b, (box.lo + box.hi) * 0.5, .Drag, set, CLOTH_REACH, follow, run)
}

// Settle, as ZBrush's Run Simulation: the free part of the model becomes cloth that falls
// `down` (sculptor_settle_step) by the settings' gravity, colliding with what
// sculptor_cloth_collide gives it and with itself, its edges keeping their lengths, until
// it comes to rest. Returns how many vertices it simulates.
sculptor_settle_begin :: proc(s: ^Sculptor, settings := CLOTH_DEFAULTS) -> int {
	return cloth_whole(s, settings, 0, .Settle)
}

// One step of Settle; returns the largest move it made, in mean links, which falls toward
// 0 as the cloth comes to rest.
sculptor_settle_step :: proc(s: ^Sculptor, down: Vec3) -> f32 {
	c := &s.cloth
	if c.run != .Settle || len(c.verts) == 0 do return 0
	// A vertex falls about CLOTH_SETTLE_GRAVITY / damping links a step at most, which the
	// substeps take a link at a time.
	fall := c.link_mean * clamp(c.settings.gravity, 0, 1) * CLOTH_SETTLE_GRAVITY / max(c.settings.damping, 0.02)
	_ = cloth_advance(s, c.center, {}, min(fall, c.link_mean * CLOTH_SUBSTEPS), down)
	return c.motion
}

// A filter of the Physics card's, `kind`, on the model's free part: each step
// (sculptor_filter_step) pulls the cloth toward the shape the filter makes of where it
// began, CLOTH_FILTER_FOLLOW of the way a round, so it folds rather than stretches. Scale
// goes along `axes` of `frame` (columns, unit length, in the mesh's space). Returns how
// many vertices it simulates.
sculptor_filter_begin :: proc(s: ^Sculptor, kind: Cloth_Filter_Kind, settings := CLOTH_DEFAULTS, frame: matrix[3, 3]f32 = 1, axes := bit_set[Axis]{.X, .Y, .Z}) -> int {
	n := cloth_whole(s, settings, CLOTH_FILTER_FOLLOW, .Filter)
	if n == 0 do return 0
	c := &s.cloth
	c.hold = true
	// The free part's mean, summed in order so it is the same on any number of threads.
	sum: [3]f64
	for p in c.rest do sum += {f64(p.x), f64(p.y), f64(p.z)}
	sum /= f64(n)
	c.filter = {kind = kind, frame = frame, axes = axes, middle = {f32(sum.x), f32(sum.y), f32(sum.z)}}
	return n
}

// One step of the filter under way at `amount` (-1 to 1), `down` the way gravity pulls.
// Returns how many vertices it simulates.
sculptor_filter_step :: proc(s: ^Sculptor, amount: f32, down: Vec3) -> int {
	c := &s.cloth
	n := len(c.verts)
	if c.run != .Filter || n == 0 do return 0
	j := Cloth_Job{s = s, ease = clamp(amount, -1, 1)}
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	chunks := (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK
	j.moves = make([]f32, chunks, context.temp_allocator)
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		c := &j.s.cloth
		f := c.filter
		a := j.ease
		// Scale doubles at 1 and halves at -1 along each chosen axis.
		factor := math.pow(f32(2), a)
		lo, hi := cloth_range(c, k)
		most: f32
		for i in lo ..< hi {
			rest := c.rest[i]
			target := rest
			switch f.kind {
			case .Inflate:
				target = rest + c.normal[i] * (a * c.radius * CLOTH_FILTER_INFLATE)
			case .Expand:
				target = rest + (rest - f.middle) * (a * CLOTH_FILTER_EXPAND)
			case .Scale:
				local := linalg.transpose(f.frame) * (rest - f.middle)
				for axis in Axis do if axis in f.axes do local[int(axis)] *= factor
				target = f.middle + f.frame * local
			}
			c.target[i], c.drive[i] = target, 1
			most = max(most, linalg.length(target - c.pos[i]))
		}
		j.moves[k] = most
	})
	// The targets pull a share of the way a round, so the move a step is that share of
	// the way at most.
	most: f32
	for x in j.moves do most = max(most, x)
	return cloth_advance(s, c.center, {}, most * CLOTH_FILTER_FOLLOW, down)
}

// Inflate at full amount moves the surface this share of the free part's half size out;
// Expand moves each vertex this share of its distance from the middle.
CLOTH_FILTER_INFLATE :: 0.15
CLOTH_FILTER_EXPAND :: 0.5

// The largest move a vertex made in the cloth's last step, in mean links.
sculptor_cloth_motion :: proc(s: ^Sculptor) -> f32 {return s.cloth.motion}
