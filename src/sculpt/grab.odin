package sculpt

import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// The Grab brush (ZBrush's Move): a stroke picks up the vertices under the brush where
// it starts, and each later pointer position drags them by how far the pointer has
// gone, each by its falloff weight, instead of laying dabs along the path. With
// symmetry, the images of the brush drag their vertices the mirrored or turned way.
Grab :: struct {
	leaves:  [dynamic]u32,  // BVH leaves the grab can change, sorted
	touched: [dynamic]bool, // per leaf: one of its shared vertices is grabbed
	first:   [dynamic]u32,  // per leaf: where its vertices start in verts; one more at the end
	verts:   [dynamic]u32,  // the grabbed vertices
	start:   [dynamic]Vec3, // ...where they were when the grab began
	// ...how much of the offset they take: the sum of each image's turn weighted by its
	// falloff there, so a vertex under a mirror image moves the mirrored way and one under
	// a turned image the turned way.
	follow:  [dynamic]matrix[3, 3]f32,
	// The area normal where the grab began (the press's image), unit length or zero: the
	// way Same side keeps to and Silhouette measures the drag against.
	normal:  Vec3,
	// Silhouette: each grabbed vertex's normal as the grab began, which a move tests
	// against the drag (grab_silhouette_keeps); empty without it.
	normals:    [dynamic]Vec3,
	silhouette: bool,
	// Under dynamic topology: the detail size of the brush that pressed (Brush.detail of
	// its radius), which sculptor_grab_refine splits what the drag stretched down to.
	detail:     f32,
}

@(private)
Grab_Job :: struct {
	s:       ^Sculptor,
	centers: [dynamic; SYM_IMAGES_MAX]Vec3,
	turns:   [dynamic; SYM_IMAGES_MAX]matrix[3, 3]f32,
	r2:      f32,
	inv_r2:  f32,
	offset:  Vec3,
	shape:   ^Falloff, // the brush's drawn falloff, or nil for the built-in one
	// Per image: the direction it reaches through the whole depth along (Brush.through
	// turned as the image is), or zero for the round reach.
	dirs:    [dynamic; SYM_IMAGES_MAX]Vec3,
	// With Connected, per image: the vertices joined to where it presses, sorted.
	connected: bool,
	reach:   [dynamic; SYM_IMAGES_MAX][]u32,
	// With Topological, per image: each vertex of `reach` its distance along the surface
	// from where the image presses, which the falloff takes in place of the straight one.
	topological: bool,
	geodesic: [dynamic; SYM_IMAGES_MAX][]f32,
	// Same side, per image: the area normal turned as the image is; a vertex facing away
	// from its image's is left out. Empty without it.
	sides:   [dynamic; SYM_IMAGES_MAX]Vec3,
	// Silhouette: the drag's direction, flipped to point out of the surface (along the
	// press's normal); zero leaves every vertex to move.
	drag_out: Vec3,
	// Elastic: the Kelvinlet's constants for the brush (elastic.odin); its reach is
	// ELASTIC_REACH radii, which r2 holds.
	elastic: bool,
	kelvin:  Kelvinlet,
}

// Starts dragging the vertices within the brush around `center`. Call inside a stroke
// (sculptor_stroke_begin) for it to be undoable. Returns how many vertices it holds.
sculptor_grab_begin :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> int {
	g := &s.grab
	if g.leaves == nil do grab_init(g, s.history.allocator)
	clear(&g.leaves)
	j := Grab_Job{s = s, r2 = brush.radius * brush.radius, inv_r2 = 1 / (brush.radius * brush.radius), shape = brush.falloff_shape}
	// Elastic moves the whole solid round the press, fading out by ELASTIC_REACH radii, and
	// none of the surface switches below apply to it.
	reach := brush.radius
	brush := brush
	if brush.kind == .Elastic {
		reach = ELASTIC_REACH * brush.radius
		j.elastic, j.kelvin, j.r2 = true, kelvinlet_make(brush.radius, brush.volume), reach * reach
		brush.through, brush.connected, brush.topological, brush.same_side, brush.silhouette = {}, false, false, false, false
	}
	through := linalg.normalize0(brush.through)
	g.normal, g.silhouette = {}, false
	g.detail = brush.radius * brush.detail
	if brush.same_side || brush.silhouette {
		// Over half the radius, as Blender samples a grab's normal, so a grab wide enough
		// to reach round a curved part still finds the way the pressed surface faces.
		// The nearest vertex's normal says which side was pressed, so the far side of a
		// thin part does not cancel it out.
		if n, ok := sculptor_area_normal(s, center, 0.5 * brush.radius, nearest_normal(s, center, brush.radius)); ok do g.normal = linalg.normalize0(n)
		g.silhouette = brush.silhouette && g.normal != {}
	}
	for img in symmetry_images(brush) {
		if brush.same_side && g.normal != {} do append(&j.sides, img.turn * g.normal)
		at := sym_point(img, brush.sym_center, center)
		dir := img.turn * through
		append(&j.centers, at)
		append(&j.turns, img.turn)
		append(&j.dirs, dir)
		if dir != {} do geom.bvh_query_leaves_line(&s.bvh, at, dir, reach, &g.leaves)
		else do geom.bvh_query_leaves(&s.bvh, at, reach, &g.leaves)
	}
	slice.sort(g.leaves[:])
	resize(&g.leaves, len(slice.unique(g.leaves[:])))
	n := len(g.leaves)
	resize(&g.touched, n)
	resize(&g.first, n + 1)
	if n == 0 do return 0
	// Reaching through the depth wins over Connected and Topological, which keep to the
	// round reach; Topological reaches only what joins the press, so it is Connected too.
	if brush.topological && through == {} {
		j.connected, j.topological = true, true
		for k in 0 ..< len(j.centers) {
			verts, dist := geodesic_reach(s, j.centers[k], brush.radius)
			append(&j.reach, verts)
			append(&j.geodesic, dist)
		}
	} else if brush.connected && through == {} {
		j.connected = true
		for k in 0 ..< len(j.centers) do append(&j.reach, grab_reach(s, j.centers[k], brush.radius))
	}
	clear(&s.hit)
	append(&s.hit, ..g.leaves[:])
	if s.history.recording do record_hit(s, masks = false)
	candidates: u32
	for leaf in g.leaves do candidates += s.nodes[s.node_of[leaf]].vert_count
	pool := s.pool if candidates >= PARALLEL_MIN_VERTS else nil

	// Count the grabbed vertices of each leaf, then fill them in.
	jobs.parallel_for(pool, n, &j, proc(data: rawptr, i: int) {
		j := cast(^Grab_Job)data
		g := &j.s.grab
		first, last := owned(j.s, g.leaves[i])
		count: u32
		for v in first ..< last do count += u32(grab_follow(j, v) != 0)
		g.first[i + 1] = count
		touched := false
		for v in shared_of(j.s, g.leaves[i]) {
			if grab_follow(j, v) != 0 {
				touched = true
				break
			}
		}
		g.touched[i] = touched
	})
	g.first[0] = 0
	for i in 0 ..< n do g.first[i + 1] += g.first[i]
	total := int(g.first[n])
	resize(&g.verts, total)
	resize(&g.start, total)
	resize(&g.follow, total)
	resize(&g.normals, total if g.silhouette else 0)
	jobs.parallel_for(pool, n, &j, proc(data: rawptr, i: int) {
		j := cast(^Grab_Job)data
		g := &j.s.grab
		first, last := owned(j.s, g.leaves[i])
		k := g.first[i]
		for v in first ..< last {
			f := grab_follow(j, v)
			if f == 0 do continue
			g.verts[k], g.start[k], g.follow[k] = v, j.s.mesh.positions[v], f
			if g.silhouette do g.normals[k] = j.s.mesh.normals[v]
			k += 1
		}
	})
	return total
}

// Moves the grabbed vertices to where they started plus `offset` (in the mesh's
// space) times their weight. Returns how many vertices moved. Like apply_dab, it
// leaves positions and BVH bounds current and normals to sculptor_flush.
sculptor_grab_move :: proc(s: ^Sculptor, offset: Vec3) -> int {
	g := &s.grab
	n := len(g.leaves)
	if n == 0 || len(g.first) != n + 1 do return 0
	clear(&s.hit)
	append(&s.hit, ..g.leaves[:])
	resize(&s.partials, n)
	slice.zero(s.partials[:])
	j := Grab_Job{s = s, offset = offset}
	if g.silhouette {
		// Blender's Grab silhouette: the drag's way out of the surface, so pulling an edge
		// outward leaves the side facing back, and pushing it in the side facing out.
		out := linalg.normalize0(offset)
		if linalg.dot(out, g.normal) < 0 do out = -out
		j.drag_out = out
	}
	pool := s.pool if len(g.verts) >= PARALLEL_MIN_VERTS else nil
	jobs.parallel_for(pool, n, &j, proc(data: rawptr, i: int) {
		j := cast(^Grab_Job)data
		s := j.s
		g := &s.grab
		m := s.mesh
		for k in g.first[i] ..< g.first[i + 1] {
			// A vertex Silhouette leaves stays where the grab found it.
			if j.drag_out != {} && !grab_silhouette_keeps(g.normals[k], g.follow[k] * j.drag_out) {
				m.positions[g.verts[k]] = g.start[k]
				continue
			}
			m.positions[g.verts[k]] = g.start[k] + g.follow[k] * j.offset
		}
		first, last := owned(s, g.leaves[i])
		bounds := geom.AABB_EMPTY
		for v in first ..< last do geom.aabb_grow(&bounds, m.positions[v])
		s.partials[i] = {bounds = bounds, moved = g.first[i + 1] - g.first[i], touched = g.touched[i]}
	})
	d := Dab{s = s}
	return finish_move(s, &d, pool)
}

// Forgets the grabbed vertices; the next grab starts afresh.
sculptor_grab_end :: proc(s: ^Sculptor) {
	g := &s.grab
	clear(&g.leaves)
	clear(&g.first)
	clear(&g.verts)
	clear(&g.start)
	clear(&g.follow)
	clear(&g.normals)
	g.normal, g.silhouette, g.detail = {}, false, 0
}

// Under dynamic topology, at the end of a grab: splits the edges round what it moved
// that are longer than the detail size (longest first, Rivara's bisection, as dabs do),
// then evens out the new vertices along the surface, so a long pull leaves triangles of
// the detail size rather than long slivers. Splitting while dragging would add vertices
// the grab does not hold, which would stay behind. Call before sculptor_grab_end, inside
// the stroke, so one undo puts the drag and the splits back. Returns how many edges split.
sculptor_grab_refine :: proc(s: ^Sculptor) -> int {
	g := &s.grab
	if s.dyn == nil || len(g.verts) == 0 || g.detail <= 0 do return 0
	// The sphere round where the grabbed vertices are now.
	bounds := geom.AABB_EMPTY
	for v in g.verts do geom.aabb_grow(&bounds, s.mesh.positions[v])
	return refine_region(s, bounds, g.detail, GRAB_REFINE_ROUNDS)
}

// The normal of the shown vertex nearest `center` within `radius`, the lowest index on a
// tie; zero when none is.
@(private = "file")
nearest_normal :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> Vec3 {
	leaves := make([dynamic]u32, context.temp_allocator)
	geom.bvh_query_leaves(&s.bvh, center, radius, &leaves)
	best_d2 := radius * radius
	best := max(u32)
	for leaf in leaves {
		first, last := owned(s, leaf)
		for v in first ..< last {
			if s.fade != nil && s.fade[v] == 0 do continue
			d := s.mesh.positions[v] - center
			d2 := linalg.dot(d, d)
			if d2 < best_d2 || (d2 == best_d2 && v < best) do best_d2, best = d2, v
		}
	}
	return s.mesh.normals[best] if best != max(u32) else {}
}

// Whether Silhouette lets a vertex facing `normal` (as the grab began) move, its image
// dragging along `out` (the drag's way out of the surface, as the image turns it): only
// when it faces that way, as Blender's grab_silhouette tests.
@(private)
grab_silhouette_keeps :: #force_inline proc(normal, out: Vec3) -> bool {
	return linalg.dot(normal, out) > 0
}

// The point of the shown surface nearest the line through `origin` along `dir` (unit
// length), within `radius` of it, for a Grab pressed just off the model, as Nomad's Move
// takes hold from past the silhouette: the vertex nearest the line, the nearest the
// origin along it on a tie, then the lowest index. False when none is that near.
sculptor_nearest_to_line :: proc(s: ^Sculptor, origin, dir: Vec3, radius: f32) -> (point: Vec3, ok: bool) {
	leaves := make([dynamic]u32, context.temp_allocator)
	geom.bvh_query_leaves_line(&s.bvh, origin, dir, radius, &leaves)
	best_d2, best_t := radius * radius, max(f32)
	best := max(u32)
	for leaf in leaves {
		first, last := owned(s, leaf)
		for v in first ..< last {
			if s.fade != nil && s.fade[v] == 0 do continue
			p := s.mesh.positions[v]
			t := linalg.dot(p - origin, dir)
			if t < 0 do continue
			d := p - origin - dir * t
			d2 := linalg.dot(d, d)
			if d2 > best_d2 || (d2 == best_d2 && (t > best_t || (t == best_t && v > best))) do continue
			best_d2, best_t, best = d2, t, v
		}
	}
	if best == max(u32) do return
	return s.mesh.positions[best], true
}

// How vertex v takes the offset: its weight under each image of the brush times that
// image's turn, summed. Zero outside every image.
@(private)
grab_follow :: #force_inline proc(j: ^Grab_Job, v: u32) -> (f: matrix[3, 3]f32) {
	p := j.s.mesh.positions[v]
	if j.elastic {
		for c, k in j.centers {
			r := p - c
			if linalg.dot(r, r) >= j.r2 do continue
			f += kelvinlet_follow(&j.kelvin, r) * j.turns[k]
		}
		if f != 0 do f = mat_scaled(f, shield(j.s.fade, j.s.mask, v))
		return
	}
	for c, k in j.centers {
		delta := p - c
		// Reaching through the depth, only the distance across the line counts.
		if dir := j.dirs[k]; dir != {} do delta -= linalg.dot(delta, dir) * dir
		d2 := linalg.dot(delta, delta)
		if d2 >= j.r2 do continue
		if j.connected {
			at, found := slice.binary_search(j.reach[k], v)
			if !found do continue
			if j.topological {
				d2 = j.geodesic[k][at] * j.geodesic[k][at]
				if d2 >= j.r2 do continue
			}
		}
		// Same side: a vertex facing away from the surface pressed (the far side of a thin
		// part) is not picked up, as Nomad's Move keeps to.
		if len(j.sides) > 0 && linalg.dot(j.s.mesh.normals[v], j.sides[k]) <= 0 do continue
		f += mat_scaled(j.turns[k], falloff_drawn(j.shape, d2 * j.inv_r2) if j.shape != nil else falloff(d2 * j.inv_r2))
	}
	if f != 0 do f = mat_scaled(f, shield(j.s.fade, j.s.mask, v))
	return
}

// The vertices joined through the shown surface to where a grab image presses at
// `center`, without leaving the round reach of `radius` (filters.odin's flood), sorted;
// on the temp allocator, for grab_begin alone. It leaves `s.hit` as the image's leaves.
@(private = "file")
grab_reach :: proc(s: ^Sculptor, center: Vec3, radius: f32) -> []u32 {
	clear(&s.hit)
	geom.bvh_query_leaves(&s.bvh, center, radius, &s.hit)
	slice.sort(s.hit[:])
	resize(&s.hit, len(slice.unique(s.hit[:])))
	d := Dab{s = s, center = center, r2 = radius * radius, inv_r2 = 1 / (radius * radius)}
	verts: u32
	for leaf in s.hit do verts += s.nodes[s.node_of[leaf]].vert_count
	connected_flood(s, &d, s.pool if verts >= PARALLEL_MIN_VERTS else nil)
	c := &s.connected
	out := make([dynamic]u32, context.temp_allocator)
	for leaf in s.hit {
		first, last := owned(s, leaf)
		for v in first ..< last do if c.mark[v] == c.stamp + 1 do append(&out, v)
	}
	slice.sort(out[:])
	return out[:]
}

// Every entry of `m` times `k`.
@(private)
mat_scaled :: #force_inline proc(m: matrix[3, 3]f32, k: f32) -> (out: matrix[3, 3]f32) {
	for i in 0 ..< 3 do for c in 0 ..< 3 do out[i, c] = m[i, c] * k
	return
}

@(private)
grab_init :: proc(g: ^Grab, allocator := context.allocator) {
	g.leaves = make([dynamic]u32, 0, 64, allocator)
	g.touched = make([dynamic]bool, 0, 64, allocator)
	g.first = make([dynamic]u32, 0, 64, allocator)
	g.verts = make([dynamic]u32, 0, 1024, allocator)
	g.start = make([dynamic]Vec3, 0, 1024, allocator)
	g.follow = make([dynamic]matrix[3, 3]f32, 0, 1024, allocator)
	g.normals = make([dynamic]Vec3, 0, 0, allocator)
}

@(private)
grab_destroy :: proc(g: ^Grab) {
	delete(g.leaves)
	delete(g.touched)
	delete(g.first)
	delete(g.verts)
	delete(g.start)
	delete(g.follow)
	delete(g.normals)
	g^ = {}
}
