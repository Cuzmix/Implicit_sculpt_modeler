package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Smooth blend's projection, the CPU reference (the GPU kernel follows it): every vertex
// of an instance near an instance it is joined with is moved onto the smooth union of their
// distance fields by Newton steps along the union's gradient, as Implicit Skinning
// (Vaillant et al. 2013) projects skin onto its parts' fields. The union takes Gourmel et
// al.'s 2013 idea, the blend's amount following the angle between the two gradients, on
// signed distances: a full fillet where the surfaces cross, none where they only face each
// other across a gap, where a plain smooth minimum would build a bridge.

// Gradients' cosine from which the blend is full (outward normals up to ~107° apart).
BLEND_FULL_COS :: -0.3
// Gradients' cosine at and below which there is no blend: the surfaces face each other.
BLEND_NONE_COS :: -0.8
// Newton steps a vertex takes at most; the spike needed 3 on average and never 6.
BLEND_STEPS :: 6
// A step's length at most, in radii, so a step from a poor gradient cannot fly off.
BLEND_STEP_MAX :: 0.5
// Converged when |G − target| is below this share of the radius.
BLEND_TOLERANCE :: 1e-4
// A vertex deeper inside a partner than this share of the radius is hidden inside the
// union and stays where it is.
BLEND_HIDDEN_DEPTH :: 0.5
// The most instances one point's fold takes.
BLEND_FOLD_MAX :: 16
// The seam between two objects' sheets, both on the one blended surface: the object with
// the lower id owns it. Its vertices that would land further than this share of the radius
// past the bisector (own below its negative) stay where they are, inside the partner and
// hidden, while the partner's sheet reaches past the bisector to under the owner's; and
// its moved vertices near the seam are lifted along the surface's normal (blend_seam_lift,
// fading out by BLEND_SEAM_BAND from it, so the fillet's edge keeps no step), so where
// both sheets lie the owner's is in front, with no fight for the pixel.
// Only one side cuts, so no crack can open between two cut lines, and nothing in the
// fragment stage changes; the seam then follows the owner's triangles.
BLEND_SEAM_CUT :: 0.05
BLEND_SEAM_LIFT :: 0.002
// A coarse sheet's flat triangles stand off the curved fillet by their sagitta, about
// e² / (8 ρ) for edges e over a curvature radius ρ, which near a seam is about a quarter
// of the radius: the lift clears this many times that of the coarser sheet (20k against
// 1M at a radius of 0.15 left clay specks over the owner at the bare 0.2 % of R).
BLEND_SEAM_SAG :: 0.75
BLEND_SEAM_BAND :: 0.5

// One drawn copy of an object (the object itself, or a Live stack copy): its surface and
// field in its own space, where it is placed (local to world: rotation, translation and
// uniform `scale`, Draw_Item.model's rule) and its place in the fold's tie order.
Blend_Instance :: struct {
	surface: ^Blend_Surface,
	field:   ^Blend_Field,
	place:   matrix[4, 4]f32,
	scale:   f32,
	id:      u32,
}

// Two instances joined by a row: the fillet's radius in world units and its fullness
// (0 a plain union with a crease, 1 a full round).
Blend_Pair :: struct {
	a, b:     int,
	radius:   f32,
	strength: f32,
}

// A moved vertex of an instance: where it moves by, the blended surface's normal there,
// how much of the blend acts there (0 at a fillet's edge, 1 at the seam between the two
// objects) and which side of the seam it is on (own > 0: its own object is the nearer).
Blend_Move :: struct {
	vertex: u32,
	offset: Vec3,
	normal: Vec3,
	amount: f32,
	own:    f32,
}

Blend_Stats :: struct {
	scanned, moved, steps, unconverged: int,
	most_steps:                         int,
}

// The smooth union of a and b (unit gradients na and nb) with radius k and fullness s:
// the value, its gradient and the blend's share h (0 none to 1 at the seam). k comes from
// the angle controller (blend_radius_at); with k 0 it is the plain minimum, never a divide.
blend_union :: #force_inline proc(a, b: f32, ga, gb: Vec3, k, s: f32) -> (g: f32, grad: Vec3, h: f32) {
	if k <= 0 {
		if a <= b do return a, ga, 0
		return b, gb, 0
	}
	h = max(k - abs(a - b), 0) / k
	g = min(a, b) - s * h * h * k * 0.25
	// The derivative of the lift goes to whichever argument is larger.
	if a <= b {
		return g, ga * (1 - s * h * 0.5) + gb * (s * h * 0.5), h
	}
	return g, gb * (1 - s * h * 0.5) + ga * (s * h * 0.5), h
}

// The blend radius at a point whose two unit gradients have cosine c: full from
// BLEND_FULL_COS up, none at BLEND_NONE_COS and below, smoothstepped between, times the
// painted weight w (0 no blend to 1).
blend_radius_at :: #force_inline proc(radius, c, w: f32) -> f32 {
	t := clamp((c - BLEND_NONE_COS) / (BLEND_FULL_COS - BLEND_NONE_COS), 0, 1)
	return radius * w * t * t * (3 - 2 * t)
}

// The field spacing for a radius: a power of two between radius/6 and radius/3, so a
// Radius drag fills new bricks only when it crosses an octave.
blend_spacing :: proc(radius: f32) -> f32 {
	return math.pow(2, math.floor(math.log2(radius / 3)))
}

// The band a field of spacing h is filled for at `radius`: at least the largest radius of
// h's octave (6h, so a Radius drag within the octave reads every value it needs) and the
// radius itself, plus a cell.
blend_band :: proc(h, radius: f32) -> f32 {
	return max(6 * h, radius) + h
}

// What one instance sees of another: the transform from its space into the other's, and
// the factor that turns the other's distances and gradients back into its own.
@(private = "file")
View :: struct {
	inst:    ^Blend_Instance,
	index:   int,
	into:    matrix[4, 4]f32, // this instance's space -> the other's
	back:    matrix[3, 3]f32, // the other's gradients -> this space's, times ratio (a rotation)
	ratio:   f32,             // the other's distances -> this space's
	joined:  bool,            // joined with the projected instance itself
	radius:  f32,             // that pair's radius, in this space
	strength: f32,
}

// One field's reading at a point, for the fold.
@(private = "file")
Term :: struct {
	d:     f32,
	g:     Vec3,
	w:     f32,
	id:    u32,
	view:  int, // into Project.views; -1 the instance itself
}

@(private = "file")
Project :: struct {
	self:     ^Blend_Instance,
	which:    int,
	views:    []View,
	pairs:    []Blend_Pair,
	instances: []Blend_Instance,
	reach:    f32, // the largest joined radius, in this space
	chunks:   [][dynamic]Blend_Move,
	stats:    []Blend_Stats,
}

// Moves the vertices of instance `which` that lie within reach of the instances it is
// joined with onto the blended surface of every instance in its group (those joined to it
// through any chain of pairs), and appends them to `out` in vertex order. The fold at a
// point takes the fields that cover it sorted by value (ties by id), so every instance
// projects onto one surface, and the result does not depend on the order instances are
// given in. Bit-identical serial and parallel. Fields must hold the bricks
// blend_pair_bricks named for every pair.
blend_project :: proc(instances: []Blend_Instance, pairs: []Blend_Pair, which: int, out: ^[dynamic]Blend_Move, pool: ^jobs.Pool) -> (stats: Blend_Stats) {
	self := &instances[which]
	group := blend_group(instances, pairs, which, context.temp_allocator)
	views := make([dynamic]View, 0, len(group), context.temp_allocator)
	inverse_self := self.place
	reach: f32 = 0
	for j in group {
		if j == which do continue
		o := &instances[j]
		inv := linalg.inverse(o.place)
		into := inv * inverse_self
		ratio := o.scale / self.scale
		lin := matrix[3, 3]f32{into[0, 0], into[0, 1], into[0, 2], into[1, 0], into[1, 1], into[1, 2], into[2, 0], into[2, 1], into[2, 2]}
		v := View{inst = o, index = j, into = into, back = linalg.transpose(lin), ratio = ratio}
		for p in pairs {
			if (p.a == which && p.b == j) || (p.b == which && p.a == j) {
				v.joined = true
				if r := p.radius / self.scale; r > v.radius {
					v.radius, v.strength = r, p.strength
				}
			}
		}
		reach = max(reach, v.radius)
		append(&views, v)
	}
	if reach <= 0 do return
	n := len(self.surface.mesh.positions)
	chunk_count := (n + PROJECT_GRAIN - 1) / PROJECT_GRAIN
	pr := Project {
		self      = self,
		which     = which,
		views     = views[:],
		pairs     = pairs,
		instances = instances,
		reach     = reach,
		chunks    = make([][dynamic]Blend_Move, chunk_count, context.temp_allocator),
		stats     = make([]Blend_Stats, chunk_count, context.temp_allocator),
	}
	jobs.parallel_for(pool, chunk_count, &pr, proc(data: rawptr, c: int) {
		pr := cast(^Project)data
		heap := runtime.heap_allocator()
		moves := make([dynamic]Blend_Move, heap)
		lo := c * PROJECT_GRAIN
		hi := min(lo + PROJECT_GRAIN, len(pr.self.surface.mesh.positions))
		for v in lo ..< hi do project_vertex(pr, u32(v), &moves, &pr.stats[c])
		pr.chunks[c] = moves
	})
	for c in 0 ..< chunk_count {
		append(out, ..pr.chunks[c][:])
		delete(pr.chunks[c])
		s := pr.stats[c]
		stats.scanned += s.scanned
		stats.moved += s.moved
		stats.steps += s.steps
		stats.unconverged += s.unconverged
		stats.most_steps = max(stats.most_steps, s.most_steps)
	}
	return
}

// Vertices a projection job takes: enough to amortise the dispatch, few enough that the
// region near a contact spreads over the workers.
@(private = "file")
PROJECT_GRAIN :: 4096

// The instances joined to `which` through any chain of pairs, `which` included, ascending.
blend_group :: proc(instances: []Blend_Instance, pairs: []Blend_Pair, which: int, allocator := context.allocator) -> []int {
	in_group := make([]bool, len(instances), context.temp_allocator)
	in_group[which] = true
	for grew := true; grew; {
		grew = false
		for p in pairs {
			if in_group[p.a] != in_group[p.b] {
				in_group[p.a], in_group[p.b] = true, true
				grew = true
			}
		}
	}
	group := make([dynamic]int, allocator)
	for g, i in in_group do if g do append(&group, i)
	return group[:]
}

@(private = "file")
project_vertex :: proc(pr: ^Project, v: u32, out: ^[dynamic]Blend_Move, st: ^Blend_Stats) {
	x0 := pr.self.surface.mesh.positions[v]
	a0, _, _, ok := blend_field_at(pr.self.field, x0)
	if !ok do return
	// Near a joined partner, and not deep inside one.
	near := false
	for &view in pr.views {
		if !view.joined do continue
		b, _, _, okb := view_at(&view, x0)
		if okb && b > -BLEND_HIDDEN_DEPTH * view.radius && b < view.radius do near = true
	}
	if !near do return
	st.scanned += 1
	g0, _, amount0, _, _, _, _ := evaluate(pr, x0, false)
	// A point inside a partner where nothing blends would fall onto the partner's surface:
	// it is hidden, and stays.
	if amount0 <= 0 && g0 < a0 do return
	target := a0 * (1 - amount0)
	x := x0
	best, best_x := abs(g0 - target), x0
	steps := 0
	converged := best < BLEND_TOLERANCE * pr.reach
	for !converged && steps < BLEND_STEPS {
		g, grad, _, _, _, _, okg := evaluate(pr, x, false)
		if !okg do break
		steps += 1
		r := g - target
		if abs(r) < best do best, best_x = abs(r), x
		if abs(r) < BLEND_TOLERANCE * pr.reach {
			converged = true
			break
		}
		gg := linalg.dot(grad, grad)
		if gg < 1e-8 do break
		step := grad * (r / gg)
		if l := linalg.length(step); l > BLEND_STEP_MAX * pr.reach do step *= BLEND_STEP_MAX * pr.reach / l
		x -= step
	}
	if converged {
		best_x = x
	} else {
		// The last point may be the best one, unmeasured after the final step.
		if g, _, _, _, _, _, okg := evaluate(pr, x, false); okg && abs(g - target) < best do best_x = x
		st.unconverged += 1
	}
	st.steps += steps
	st.most_steps = max(st.most_steps, steps)
	if best_x == x0 do return
	_, normal, amount, own, rival, rival_edge, _ := evaluate(pr, best_x, true)
	n := linalg.normalize0(normal)
	offset := best_x - x0
	if pr.self.id < rival {
		if own < -BLEND_SEAM_CUT do return
		lift := blend_seam_lift(pr.reach, max(pr.self.surface.edge, rival_edge))
		offset += n * (lift * clamp(1 - own / BLEND_SEAM_BAND, 0, 1))
	}
	append(out, Blend_Move{vertex = v, offset = offset, normal = n, amount = amount, own = own})
	st.moved += 1
}

// A view's field at x of the projected instance's space, in that space's units.
@(private = "file")
view_at :: #force_inline proc(view: ^View, x: Vec3) -> (d: f32, g: Vec3, w: f32, ok: bool) {
	p := (view.into * [4]f32{x.x, x.y, x.z, 1}).xyz
	d, g, w = blend_field_at(view.inst.field, p) or_return
	return d * view.ratio, view.back * g * view.ratio, w, true
}

@(private = "file")
view_normal :: #force_inline proc(view: ^View, x: Vec3) -> (g: Vec3, ok: bool) {
	p := (view.into * [4]f32{x.x, x.y, x.z, 1}).xyz
	g = blend_field_normal(view.inst.field, p) or_return
	return view.back * g * view.ratio, true
}

// The blended field at x: its value, gradient, the blend's largest share over the fold
// (times the fullness), the seam side of the projected instance (own > 0 where its field
// is below the others') and the id of the nearest other instance (max(u32) for none).
// `smooth` takes the gradients from the smooth normals, for the final normal. ok is false
// where the instance's own field holds no brick.
@(private = "file")
evaluate :: proc(pr: ^Project, x: Vec3, smooth: bool) -> (g: f32, grad: Vec3, amount, own: f32, rival: u32, rival_edge: f32, ok: bool) {
	terms: [BLEND_FOLD_MAX]Term
	count := 0
	d, gs, w := blend_field_at(pr.self.field, x) or_return
	if smooth do gs = blend_field_normal(pr.self.field, x) or_return
	terms[0] = {d = d, g = gs, w = w, id = pr.self.id, view = -1}
	count = 1
	others := max(f32)
	rival = max(u32)
	for &view, i in pr.views {
		if count == BLEND_FOLD_MAX do break
		vd, vg, vw := view_at(&view, x) or_continue
		if smooth {
			if n, okn := view_normal(&view, x); okn do vg = n
		}
		terms[count] = {d = vd, g = vg, w = vw, id = view.inst.id, view = i}
		count += 1
		if vd < others || (vd == others && view.inst.id < rival) do others, rival, rival_edge = vd, view.inst.id, view.inst.surface.edge * view.ratio
	}
	sorted := terms[:count]
	slice.sort_by(sorted, proc(a, b: Term) -> bool {return a.d < b.d || (a.d == b.d && a.id < b.id)})
	g, grad = sorted[0].d, sorted[0].g
	for j in 1 ..< count {
		e := sorted[j]
		// The pair with the largest radius between this field and any before it.
		radius, strength, pw: f32
		for i in 0 ..< j {
			r, s := pair_of(pr, e.view, sorted[i].view)
			if r > radius do radius, strength, pw = r, s, e.w * sorted[i].w
		}
		k := blend_radius_at(radius, linalg.dot(linalg.normalize0(grad), linalg.normalize0(e.g)), pw)
		h: f32
		g, grad, h = blend_union(g, e.d, grad, e.g, k, strength)
		amount = max(amount, strength * h)
	}
	if others < max(f32) do own = clamp((others - d) / pr.reach, -1, 1)
	else do own = 1
	return g, grad, amount, own, rival, rival_edge, true
}

// How far the seam's owner stands out near the seam, for a radius and the coarser of the
// two sheets' mean edges (both in one space): BLEND_SEAM_LIFT of the radius, or enough to
// clear that sheet's sagitta over the fillet (BLEND_SEAM_SAG), whichever is more.
blend_seam_lift :: proc(radius, edge: f32) -> f32 {
	return max(BLEND_SEAM_LIFT * radius, BLEND_SEAM_SAG * edge * edge / radius)
}

// A mesh's mean edge, from its area per triangle as if every triangle were equilateral:
// what Blend_Surface.edge holds, worked out once per surface.
blend_surface_edge :: proc(m: Mesh) -> f32 {
	tris := len(m.indices) / 3
	if tris == 0 do return 0
	area: f64 = 0
	for t in 0 ..< tris {
		p0, p1, p2 := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
		area += f64(linalg.length(linalg.cross(p1 - p0, p2 - p0))) * 0.5
	}
	return f32(math.sqrt(4 * area / (f64(tris) * math.sqrt(f64(3)))))
}

// The radius (in the projected instance's space) and fullness of the pair joining two
// fold terms (view indices, -1 the projected instance), zero when they are not joined.
@(private = "file")
pair_of :: proc(pr: ^Project, a, b: int) -> (radius, strength: f32) {
	ia := pr.which if a < 0 else pr.views[a].index
	ib := pr.which if b < 0 else pr.views[b].index
	for p in pr.pairs {
		if (p.a == ia && p.b == ib) || (p.a == ib && p.b == ia) {
			if r := p.radius / pr.self.scale; r > radius do radius, strength = r, p.strength
		}
	}
	return
}

// The bricks each field of a pair needs: where a's surface comes within the radius of b's,
// in each instance's own space and at its field's spacing, dilated by one brick (a vertex
// moves up to about the radius), less the bricks whose middle is further than the radius
// plus half a brick's diagonal from either surface. Whether a brick is needed depends on
// the partner, so nothing is remembered as empty in a field (another pair may need the
// brick). Appends sorted, unique keys. Leaves come from each surface's tree, so the work
// follows the contact, not the meshes' size.
blend_pair_bricks :: proc(instances: []Blend_Instance, pair: Blend_Pair, want_a, want_b: ^[dynamic]u64, pool: ^jobs.Pool) {
	ia, ib := &instances[pair.a], &instances[pair.b]
	ab := linalg.inverse(ib.place) * ia.place
	ba := linalg.inverse(ia.place) * ib.place
	near_a := make([dynamic]u64, context.temp_allocator)
	near_b := make([dynamic]u64, context.temp_allocator)
	leaf_bricks(ia, ib, ab, pair.radius, &near_a, &near_b)
	leaf_bricks(ib, ia, ba, pair.radius, &near_b, &near_a)
	cull_bricks(ia, ib, ab, pair.radius, near_a[:], want_a, pool)
	cull_bricks(ib, ia, ba, pair.radius, near_b[:], want_b, pool)
}

// For each node of `from`'s tree within `radius` (world) of `to`'s surface, descending
// only until a node fits in a brick of both fields (or is a leaf), so the work follows the
// bricks of the contact rather than the triangles under it: the bricks its box touches in
// `from`'s field, and the bricks the box touches once placed in `to`'s space in `to`'s
// field, each dilated by one brick.
@(private = "file")
leaf_bricks :: proc(from, to: ^Blend_Instance, into: matrix[4, 4]f32, radius: f32, out_from, out_to: ^[dynamic]u64) {
	r_to := radius / to.scale
	nodes := from.surface.bvh.nodes[:]
	if len(nodes) == 0 || len(to.surface.bvh.nodes) == 0 do return
	brick_from, brick_to := from.field.h * BLEND_BRICK, to.field.h * BLEND_BRICK
	stack := make([dynamic]u32, 0, 64, context.temp_allocator)
	append(&stack, 0)
	for len(stack) > 0 {
		at := pop(&stack)
		node := nodes[at]
		moved := box_into(node.bounds, into)
		if !tree_near(to.surface.bvh, moved, r_to) do continue
		small := box_extent(node.bounds) <= brick_from && box_extent(moved) <= brick_to
		if node.count == 0 && !small {
			append(&stack, node.first, node.first + 1)
			continue
		}
		bricks_of_box(node.bounds, from.field.h, out_from)
		bricks_of_box(moved, to.field.h, out_to)
	}
}

@(private = "file")
box_extent :: #force_inline proc(b: Aabb) -> f32 {
	e := b.hi - b.lo
	return max(e.x, e.y, e.z)
}

// The box round a box's eight corners placed by m.
@(private = "file")
box_into :: proc(b: Aabb, m: matrix[4, 4]f32) -> Aabb {
	out := AABB_EMPTY
	for k in 0 ..< 8 {
		c := Vec3{b.hi.x if k & 1 != 0 else b.lo.x, b.hi.y if k & 2 != 0 else b.lo.y, b.hi.z if k & 4 != 0 else b.lo.z}
		aabb_grow(&out, (m * [4]f32{c.x, c.y, c.z, 1}).xyz)
	}
	return out
}

// Whether any leaf box of tree b is within r of box q.
@(private = "file")
tree_near :: proc(b: Bvh, q: Aabb, r: f32) -> bool {
	stack: [64]u32
	stack[0] = 0
	top := 1
	for top > 0 {
		top -= 1
		node := b.nodes[stack[top]]
		gap: f32 = 0
		for a in 0 ..< 3 {
			e := max(node.bounds.lo[a] - q.hi[a], q.lo[a] - node.bounds.hi[a], 0)
			gap += e * e
		}
		if gap > r * r do continue
		if node.count > 0 do return true
		if top + 2 > len(stack) do return true
		stack[top], stack[top + 1] = node.first, node.first + 1
		top += 2
	}
	return false
}

@(private = "file")
bricks_of_box :: proc(b: Aabb, h: f32, out: ^[dynamic]u64) {
	lo, hi := blend_brick_of(h, b.lo), blend_brick_of(h, b.hi)
	for z in lo.z - 1 ..= hi.z + 1 do for y in lo.y - 1 ..= hi.y + 1 do for x in lo.x - 1 ..= hi.x + 1 {
		if blend_brick_fits({x, y, z}) do append(out, blend_key({x, y, z}))
	}
}

// Keeps the candidate bricks of `self`'s field whose middle lies within the radius plus
// half a brick's diagonal of both surfaces and appends them to `want`; bricks the field
// already holds are kept without a test. The test runs in parallel; the kept order is the
// keys' sorted order.
@(private = "file")
cull_bricks :: proc(self, other: ^Blend_Instance, into: matrix[4, 4]f32, radius: f32, candidates: []u64, want: ^[dynamic]u64, pool: ^jobs.Pool) {
	slice.sort(candidates)
	keys := slice.unique(candidates)
	fresh := make([dynamic]u64, 0, len(keys), context.temp_allocator)
	for k in keys {
		if blend_field_slot(self.field, k) >= 0 {
			append(want, k)
		} else {
			append(&fresh, k)
		}
	}
	Cull :: struct {
		self, other: ^Blend_Instance,
		into:        matrix[4, 4]f32,
		radius:      f32,
		keys:        []u64,
		keep:        []bool,
	}
	c := Cull{self, other, into, radius, fresh[:], make([]bool, len(fresh), context.temp_allocator)}
	jobs.parallel_for(pool, len(fresh), &c, proc(data: rawptr, i: int) {
		c := cast(^Cull)data
		h := c.self.field.h
		b := blend_unkey(c.keys[i])
		mid := (Vec3{f32(b.x), f32(b.y), f32(b.z)} + 0.5) * (h * BLEND_BRICK)
		half := h * BLEND_BRICK * 0.5 * math.SQRT_THREE
		r_self := c.radius / c.self.scale + half
		_, _, _, near_self := surface_distance(c.self.surface, mid, r_self)
		if !near_self do return
		r_other := (c.radius + half * c.self.scale) / c.other.scale
		p := (c.into * [4]f32{mid.x, mid.y, mid.z, 1}).xyz
		_, _, _, near_other := surface_distance(c.other.surface, p, r_other)
		c.keep[i] = near_other
	})
	for k, i in fresh do if c.keep[i] do append(want, k)
	slice.sort(want[:])
}
