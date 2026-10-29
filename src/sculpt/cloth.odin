package sculpt

import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// The Cloth brush: for the length of a stroke, the surface in and around the brush
// behaves like a sheet of cloth. Its edges keep their lengths (position-based
// dynamics: Verlet steps, then rounds of edge constraints), so what the brush drags,
// pulls in or lets sag gathers into folds and wrinkles instead of stretching, as
// Blender's cloth brush does. Everything is simulated in the mesh's space, in a region
// CLOTH_REACH brush radii around where the stroke began; the region's rim and masked or
// hidden vertices are held where they were, so the cloth stays sewn to the rest of the
// mesh. Symmetry is not applied: the simulation is one piece.
Cloth_Mode :: enum u8 {
	Drag,    // what is under the brush follows the pointer; the rest of the region follows as cloth
	Gravity, // the region sags along `down` while the button is held
	Pinch,   // the brush pulls the cloth toward its centre: it bunches into folds
	Expand,  // the brush pushes the cloth out from its centre: it buckles into ridges
}

Cloth :: struct {
	mode:     Cloth_Mode,
	center:   Vec3,
	radius:   f32,
	strength: f32,
	steps:    int, // steps taken this stroke, which ease Pinch and Expand in
	leaves:   [dynamic]u32, // BVH leaves of the region, sorted
	nodes:    [dynamic]u32, // ...their nodes, for sculptor_nodes_moved
	verts:    [dynamic]u32, // the simulated vertices, ascending
	pos:      [dynamic]Vec3, // ...where they are
	prev:     [dynamic]Vec3, // ...where they were a step ago (their velocity is the difference)
	next:     [dynamic]Vec3, // scratch for the step under way
	rest:     [dynamic]Vec3, // ...where they were when the stroke began
	normal:   [dynamic]Vec3, // ...their normals then: the way squeezed cloth buckles
	pin:      [dynamic]f32, // how firmly each is held at rest: 1 at the rim, where masked or hidden
	drive:    [dynamic]f32, // the brush's falloff weight on each, 0 outside it
	first:    [dynamic]u32, // per vertex: where its links start; one more at the end
	links:    [dynamic]u32, // a neighbour's index in verts, or CLOTH_FIXED for one outside the region
	length:   [dynamic]f32, // each link's rest length
	anchor:   [dynamic]Vec3, // each link's neighbour position when that neighbour is outside the region
}

// How far around the brush the cloth reaches, in brush radii: far enough for folds to
// form around what the brush moves, small enough that a 10M-vertex mesh steps in a few
// milliseconds.
CLOTH_REACH :: 1.6
// Share of the region's radius from which vertices are increasingly held at rest, so
// the cloth's edge blends into the fixed mesh instead of creasing at the rim.
CLOTH_PIN_FROM :: 0.7
// Velocity kept from one step to the next: below 1 so the cloth settles while held.
CLOTH_DAMPING :: 0.92
// Constraint rounds a step. More stiffen the cloth (folds get larger and smoother) at a
// proportional cost.
CLOTH_ITERATIONS :: 5
// How far each Jacobi round moves a vertex toward satisfying its links: above 1 over-
// relaxes, which converges faster; below 2 stays stable.
CLOTH_RELAX :: 1.4
// Gravity a step, in brush radii times strength. Each vertex is also sprung back toward
// where it began by CLOTH_RESTORE of the way, so the cloth hangs at about
// CLOTH_GRAVITY / CLOTH_RESTORE radii times strength instead of falling for ever.
CLOTH_GRAVITY :: 0.012
CLOTH_RESTORE :: 0.02
// Pinch and Expand move what is under the brush up to this share of the way to (or
// away from) its centre, times strength, eased in over CLOTH_EASE_STEPS steps, so a
// held stroke settles instead of crushing the region to a point.
CLOTH_PINCH_MAX :: 0.55
CLOTH_EASE_STEPS :: 40
// How far squeezed cloth puffs out along its normal, per unit of average compression of
// its links, in link lengths: squeezed cloth then folds outward together instead of
// crumpling either way at random.
CLOTH_BUCKLE :: 1.5
// Bending: each round moves a vertex's displacement this share of the way toward its
// neighbours' average displacement, which keeps folds smooth rather than jagged at
// high resolution, without flattening the shape underneath.
CLOTH_BEND :: 0.3
// A link whose neighbour is outside the region and stays put.
CLOTH_FIXED :: max(u32)
// Links a vertex keeps, far more than any vertex of a sculpted mesh has neighbours.
CLOTH_MAX_LINKS :: 64
// Simulated vertices a job takes.
CLOTH_CHUNK :: 4096

@(private)
Cloth_Job :: struct {
	s:       ^Sculptor,
	offset:  Vec3, // Drag: where the brush has dragged to, from where it started
	gravity: Vec3, // Gravity: added to each vertex's position a step
	reach:   f32,
}

// Starts a cloth stroke around `center` (mesh space) in `mode`, with the brush's radius
// and strength. Call inside a stroke (sculptor_stroke_begin) for it to be undoable.
// Returns how many vertices it simulates.
sculptor_cloth_begin :: proc(s: ^Sculptor, brush: Brush, center: Vec3, mode: Cloth_Mode) -> int {
	c := &s.cloth
	if c.leaves == nil do cloth_init(c, s.history.allocator)
	sculptor_cloth_end(s)
	c.mode, c.center, c.radius, c.strength = mode, center, brush.radius, brush.strength
	reach := brush.radius * CLOTH_REACH
	stretch_note(s, center, reach, {}, brush.radius * brush.detail)
	geom.bvh_query_leaves(&s.bvh, center, reach, &c.leaves)
	slice.sort(c.leaves[:])
	resize(&c.leaves, len(slice.unique(c.leaves[:])))
	if len(c.leaves) == 0 do return 0
	clear(&s.hit)
	append(&s.hit, ..c.leaves[:])
	if s.history.recording do record_hit(s, masks = false)
	for leaf in c.leaves do append(&c.nodes, s.node_of[leaf])
	slice.sort(c.nodes[:])

	// Nodes own ascending, contiguous vertex ranges, so walking them in id order lists
	// the region's vertices in ascending order, which the link lookup below relies on.
	m := s.mesh
	r2, reach2 := brush.radius * brush.radius, reach * reach
	candidates := 0
	for id in c.nodes do candidates += int(s.nodes[id].vert_count)
	for a in ([?]^[dynamic]Vec3{&c.pos, &c.rest, &c.normal}) do reserve(a, candidates)
	reserve(&c.verts, candidates)
	reserve(&c.pin, candidates)
	reserve(&c.drive, candidates)
	for id in c.nodes {
		n := s.nodes[id]
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			p := m.positions[v]
			d2 := linalg.length2(p - center)
			if d2 >= reach2 do continue
			w := shield(s.fade, s.mask, v)
			pin := max(smoothstep(CLOTH_PIN_FROM, 1, linalg.sqrt(d2) / reach), 1 - w)
			drive := w * (falloff_drawn(brush.falloff_shape, d2 / r2) if brush.falloff_shape != nil else falloff(d2 / r2))
			append(&c.verts, v)
			append(&c.pos, p)
			append(&c.rest, p)
			append(&c.normal, m.normals[v] if int(v) < len(m.normals) else Vec3{})
			append(&c.pin, pin)
			append(&c.drive, drive)
		}
	}
	if !slice.is_sorted(c.verts[:]) do return cloth_abandon(s)
	n := len(c.verts)
	resize(&c.prev, n)
	resize(&c.next, n)
	copy(c.prev[:], c.pos[:])

	// Links: every other corner of every triangle around each vertex, once. Counted,
	// then filled, a chunk of vertices per job; at 10M vertices a region holds a few
	// hundred thousand.
	resize(&c.first, n + 1)
	j := Cloth_Job{s = s}
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	chunks := (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		c := &j.s.cloth
		near: [dynamic; CLOTH_MAX_LINKS]u32
		lo, hi := cloth_range(c, k)
		for i in lo ..< hi {
			cloth_near(j.s, c.verts[i], &near)
			c.first[i + 1] = u32(len(near))
		}
	})
	c.first[0] = 0
	for i in 0 ..< n do c.first[i + 1] += c.first[i]
	total := int(c.first[n])
	resize(&c.links, total)
	resize(&c.length, total)
	resize(&c.anchor, total)
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		j := cast(^Cloth_Job)data
		s := j.s
		c := &s.cloth
		m := s.mesh
		near: [dynamic; CLOTH_MAX_LINKS]u32
		lo, hi := cloth_range(c, k)
		for i in lo ..< hi {
			v := c.verts[i]
			cloth_near(s, v, &near)
			p := m.positions[v]
			l := c.first[i]
			for u in near {
				at, found := slice.binary_search(c.verts[:], u)
				c.length[l] = linalg.length(m.positions[u] - p)
				if found {
					c.links[l], c.anchor[l] = u32(at), {}
				} else {
					c.links[l], c.anchor[l] = CLOTH_FIXED, m.positions[u]
				}
				l += 1
			}
		}
	})
	return n
}

// The other corners of the triangles around `v`, each once, at most CLOTH_MAX_LINKS;
// under dynamic topology from its own triangle lists, which the stroke keeps as they are
// until the repair at its end.
@(private = "file")
cloth_near :: proc(s: ^Sculptor, v: u32, near: ^[dynamic; CLOTH_MAX_LINKS]u32) {
	clear(near)
	tris := dyn_faces(s.dyn, v) if s.dyn != nil else geom.vertex_faces_of(s.faces, v)
	for tri in tris {
		for k in 0 ..< 3 {
			u := s.mesh.indices[3 * tri + u32(k)]
			if u == v || slice.contains(near[:], u) do continue
			if len(near) == CLOTH_MAX_LINKS do return
			append(near, u)
		}
	}
}

// One step of the cloth: Verlet with the mode's force, then the edge constraints, then
// the positions written back. `offset` is how far a Drag stroke has dragged from where
// it began and `down` the way Gravity pulls (unit length), both in the mesh's space.
// Returns how many vertices it simulates. Like apply_dab, it leaves positions and BVH
// bounds current and normals to sculptor_flush.
sculptor_cloth_step :: proc(s: ^Sculptor, offset, down: Vec3) -> int {
	c := &s.cloth
	n := len(c.verts)
	if n == 0 || len(c.first) != n + 1 do return 0
	j := Cloth_Job{s = s, offset = offset}
	if c.mode == .Gravity do j.gravity = down * (c.radius * c.strength * CLOTH_GRAVITY)
	c.steps += 1
	pool := s.pool if n >= PARALLEL_MIN_VERTS else nil
	chunks := (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK
	jobs.parallel_for(pool, chunks, &j, job_cloth_integrate)
	c.pos, c.next = c.next, c.pos
	for _ in 0 ..< CLOTH_ITERATIONS {
		jobs.parallel_for(pool, chunks, &j, job_cloth_constrain)
		c.pos, c.next = c.next, c.pos
	}
	jobs.parallel_for(pool, chunks, &j, proc(data: rawptr, k: int) {
		c := &(cast(^Cloth_Job)data).s.cloth
		m := (cast(^Cloth_Job)data).s.mesh
		lo, hi := cloth_range(c, k)
		for i in lo ..< hi do m.positions[c.verts[i]] = c.pos[i]
	})
	sculptor_nodes_moved(s, c.nodes[:])
	if s.history.recording do for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
	return n
}

// Forgets the simulation; the next cloth stroke starts afresh.
sculptor_cloth_end :: proc(s: ^Sculptor) {
	c := &s.cloth
	clear(&c.leaves)
	clear(&c.nodes)
	clear(&c.verts)
	clear(&c.pos)
	clear(&c.prev)
	clear(&c.next)
	clear(&c.rest)
	clear(&c.normal)
	c.steps = 0
	clear(&c.pin)
	clear(&c.drive)
	clear(&c.first)
	clear(&c.links)
	clear(&c.length)
	clear(&c.anchor)
}

// Nodes not in ascending vertex order cannot be looked up; that never happens for a
// sculptor's own partition, but a stroke on a mesh that breaks it moves nothing rather
// than tearing the cloth.
@(private = "file")
cloth_abandon :: proc(s: ^Sculptor) -> int {
	sculptor_cloth_end(s)
	return 0
}

@(private = "file")
cloth_range :: #force_inline proc(c: ^Cloth, k: int) -> (lo, hi: int) {
	return k * CLOTH_CHUNK, min((k + 1) * CLOTH_CHUNK, len(c.verts))
}

// Verlet: each vertex carries on with its damped velocity plus the mode's force, the
// part under the brush goes where the brush puts it, and pinned vertices are held at
// rest.
@(private = "file")
job_cloth_integrate :: proc(data: rawptr, k: int) {
	j := cast(^Cloth_Job)data
	c := &j.s.cloth
	ease := min(f32(c.steps) / CLOTH_EASE_STEPS, 1) * c.strength * CLOTH_PINCH_MAX
	lo, hi := cloth_range(c, k)
	for i in lo ..< hi {
		p, rest, w := c.pos[i], c.rest[i], c.drive[i]
		q := p + (p - c.prev[i]) * CLOTH_DAMPING
		switch c.mode {
		case .Drag:
			q = linalg.lerp(q, rest + j.offset, w)
		case .Gravity:
			q += (j.gravity + (rest - p) * CLOTH_RESTORE) * (1 - c.pin[i])
		case .Pinch:
			q = linalg.lerp(q, rest + (c.center - rest) * ease, w)
		case .Expand:
			q = linalg.lerp(q, rest - (c.center - rest) * ease, w)
		}
		c.next[i] = linalg.lerp(q, rest, c.pin[i])
		c.prev[i] = p
	}
}

// One Jacobi round of the edge constraints: each vertex moves by the average of what
// its links ask, puffs out along its normal as far as its links are squeezed, and
// evens its displacement with its neighbours' (bending), all scaled by how free it is
// (not pinned, and not held by the brush). It reads only the previous round's
// positions, so the result is the same on any number of threads.
@(private = "file")
job_cloth_constrain :: proc(data: rawptr, k: int) {
	j := cast(^Cloth_Job)data
	c := &j.s.cloth
	lo, hi := cloth_range(c, k)
	for i in lo ..< hi {
		p := c.pos[i]
		free := (1 - c.pin[i]) * (1 - c.drive[i])
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
			if dist > 1e-12 do pull += d * ((dist - rest) / dist)
			if rest > 0 do squeeze += max(rest - dist, 0) / rest
			span += rest
			moved += shift
		}
		count := f32(last - first)
		// Each link's correction is shared by its two ends, hence the half.
		step := pull * (0.5 * CLOTH_RELAX / count)
		step += c.normal[i] * (squeeze / count * (span / count) * CLOTH_BUCKLE)
		step += (moved / count - (p - c.rest[i])) * CLOTH_BEND
		c.next[i] = p + step * free
	}
}

@(private = "file")
smoothstep :: #force_inline proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private)
cloth_init :: proc(c: ^Cloth, allocator := context.allocator) {
	c.leaves = make([dynamic]u32, 0, 64, allocator)
	c.nodes = make([dynamic]u32, 0, 64, allocator)
	c.verts = make([dynamic]u32, 0, 1024, allocator)
	c.pos = make([dynamic]Vec3, 0, 1024, allocator)
	c.prev = make([dynamic]Vec3, 0, 1024, allocator)
	c.next = make([dynamic]Vec3, 0, 1024, allocator)
	c.rest = make([dynamic]Vec3, 0, 1024, allocator)
	c.normal = make([dynamic]Vec3, 0, 1024, allocator)
	c.pin = make([dynamic]f32, 0, 1024, allocator)
	c.drive = make([dynamic]f32, 0, 1024, allocator)
	c.first = make([dynamic]u32, 0, 1024, allocator)
	c.links = make([dynamic]u32, 0, 4096, allocator)
	c.length = make([dynamic]f32, 0, 4096, allocator)
	c.anchor = make([dynamic]Vec3, 0, 4096, allocator)
}

@(private)
cloth_destroy :: proc(c: ^Cloth) {
	delete(c.leaves)
	delete(c.nodes)
	delete(c.verts)
	delete(c.pos)
	delete(c.prev)
	delete(c.next)
	delete(c.rest)
	delete(c.normal)
	delete(c.pin)
	delete(c.drive)
	delete(c.first)
	delete(c.links)
	delete(c.length)
	delete(c.anchor)
	c^ = {}
}
