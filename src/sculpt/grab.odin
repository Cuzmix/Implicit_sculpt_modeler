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
}

// Starts dragging the vertices within the brush around `center`. Call inside a stroke
// (sculptor_stroke_begin) for it to be undoable. Returns how many vertices it holds.
sculptor_grab_begin :: proc(s: ^Sculptor, brush: Brush, center: Vec3) -> int {
	g := &s.grab
	if g.leaves == nil do grab_init(g, s.history.allocator)
	clear(&g.leaves)
	j := Grab_Job{s = s, r2 = brush.radius * brush.radius, inv_r2 = 1 / (brush.radius * brush.radius), shape = brush.falloff_shape}
	through := linalg.normalize0(brush.through)
	for img in symmetry_images(brush) {
		at := sym_point(img, brush.sym_center, center)
		dir := img.turn * through
		append(&j.centers, at)
		append(&j.turns, img.turn)
		append(&j.dirs, dir)
		if dir != {} do geom.bvh_query_leaves_line(&s.bvh, at, dir, brush.radius, &g.leaves)
		else do geom.bvh_query_leaves(&s.bvh, at, brush.radius, &g.leaves)
	}
	slice.sort(g.leaves[:])
	resize(&g.leaves, len(slice.unique(g.leaves[:])))
	n := len(g.leaves)
	resize(&g.touched, n)
	resize(&g.first, n + 1)
	if n == 0 do return 0
	// Reaching through the depth wins over Connected, whose flood keeps to the round reach.
	if brush.connected && through == {} {
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
	jobs.parallel_for(pool, n, &j, proc(data: rawptr, i: int) {
		j := cast(^Grab_Job)data
		g := &j.s.grab
		first, last := owned(j.s, g.leaves[i])
		k := g.first[i]
		for v in first ..< last {
			f := grab_follow(j, v)
			if f == 0 do continue
			g.verts[k], g.start[k], g.follow[k] = v, j.s.mesh.positions[v], f
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
	pool := s.pool if len(g.verts) >= PARALLEL_MIN_VERTS else nil
	jobs.parallel_for(pool, n, &j, proc(data: rawptr, i: int) {
		j := cast(^Grab_Job)data
		s := j.s
		g := &s.grab
		m := s.mesh
		for k in g.first[i] ..< g.first[i + 1] do m.positions[g.verts[k]] = g.start[k] + g.follow[k] * j.offset
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
}

// How vertex v takes the offset: its weight under each image of the brush times that
// image's turn, summed. Zero outside every image.
@(private)
grab_follow :: #force_inline proc(j: ^Grab_Job, v: u32) -> (f: matrix[3, 3]f32) {
	p := j.s.mesh.positions[v]
	for c, k in j.centers {
		delta := p - c
		// Reaching through the depth, only the distance across the line counts.
		if dir := j.dirs[k]; dir != {} do delta -= linalg.dot(delta, dir) * dir
		d2 := linalg.dot(delta, delta)
		if d2 >= j.r2 do continue
		if j.connected {
			if _, found := slice.binary_search(j.reach[k], v); !found do continue
		}
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
}

@(private)
grab_destroy :: proc(g: ^Grab) {
	delete(g.leaves)
	delete(g.touched)
	delete(g.first)
	delete(g.verts)
	delete(g.start)
	delete(g.follow)
	g^ = {}
}
