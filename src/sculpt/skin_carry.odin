package sculpt

import "base:runtime"
import "core:math/linalg"

import "../geom"
import "../jobs"

// Carrying detail onto a new skin (Squeeze, and a skin through Remesh, Decimate, booleans
// and Mirror): every sample of the new mesh's skin finds the old surface, the old mesh
// (as its smooth shading shows it) with its own skin when it has one, and takes the
// offset to there from the new mesh's curved base (skin_curve). A ray along the
// sample's normal finds the old surface first, the nearer of the hits either way, which
// gives a height alone; where the ray finds nothing within the reach (an overhang, a
// fold, a hole the new mesh closed), the nearest point of the old surface does, which
// needs the vector page for its sideways part. Then the gaps are measured: the middle of
// a small triangle in each two by two block of them against the old surface found the
// same way, per triangle the worst over a grid step, kept as the skin's heat (Skin.heat)
// for the view and summed into the report.

Skin_Carry_Report :: struct {
	worst:  f32, // the largest gap, in the mesh's units
	mean:   f32, // the gaps' mean over every small triangle
	missed: int, // samples no ray found the old surface for, placed by the nearest point
	lost:   int, // samples neither found within the reach, left flat
	side:   bool, // the new skin has a vector page
}

// Fills `dst`'s skin (made already, flat) from `src`'s surface, searching up to `reach`
// from each sample. Serial and parallel runs give the same skin to the bit. The skin's
// normals are left to the next flush; its heat and height bound are set.
skin_carry :: proc(dst, src: ^Sculptor, reach: f32) -> (rep: Skin_Carry_Report) {
	sk := dst.skin
	if sk == nil do return
	n := len(sk.heights)
	// The sculptor's own tree has a node's thousand triangles in a leaf, made for dabs; a
	// ray wants a few.
	tree := geom.bvh_build_morton(src.mesh^, geom.BVH_LEAF_SIZE, dst.pool)
	defer geom.bvh_destroy(&tree)
	Job :: struct {
		dst, src: ^Sculptor,
		tree:     ^geom.Bvh,
		reach:    f32,
		side:     [][2]f32,
		missed:   []u32,
		gaps:     [][2]f32, // per triangle: the worst gap over a grid step, and the gaps' sum
		gap_worst: []f32,
	}
	job := Job {
		dst       = dst,
		src       = src,
		tree      = &tree,
		reach     = reach,
		side      = make([][2]f32, n, runtime.heap_allocator()),
		missed    = make([]u32, int(sk.tri_count) * 2, runtime.heap_allocator()),
		gaps      = make([][2]f32, sk.tri_count, runtime.heap_allocator()),
		gap_worst = make([]f32, sk.tri_count, runtime.heap_allocator()),
	}
	defer {
		delete(job.side, runtime.heap_allocator())
		delete(job.missed, runtime.heap_allocator())
		delete(job.gaps, runtime.heap_allocator())
		delete(job.gap_worst, runtime.heap_allocator())
	}
	// Each sample is written by the triangle that owns it, so no two jobs write one.
	jobs.parallel_ranges(dst.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		dst, src := job.dst, job.src
		sk := dst.skin
		I := dst.mesh.indices[:]
		S := sk.segments
		stack := make([dynamic]u32, 0, 64, runtime.heap_allocator())
		defer delete(stack)
		for t in u32(lo) ..< u32(hi) {
			for j in u32(0) ..= S do for i in u32(0) ..= S - j {
				if !skin_owns(dst, sk, t, i, j) do continue
				b, nb := skin_base(dst, sk, t, i, j)
				nu := linalg.normalize0(nb)
				q, how := carry_find(src, job.tree, b, nu, job.reach, &stack)
				switch how {
				case .Ray:
				case .Nearest: job.missed[2 * t] += 1
				case .None:    job.missed[2 * t + 1] += 1
				}
				// Measured from the curved base, not the flat point (skin_curve).
				off := q - b - skin_curve(dst, sk, t, i, j, b, nu)
				x := skin_sample(sk, I, t, i, j)
				sk.heights[x] = f16(linalg.dot(off, nu))
				// A ray's hit is along the normal: what little the smoothed old surface puts
				// beside it is no reason for a vector page.
				if how == .Ray do continue
				tu, tv := skin_frame(dst, sk, t, i, j, nu)
				job.side[x] = {linalg.dot(off, tu), linalg.dot(off, tv)}
			}
		}
	}, 1 << 10)

	// A vector page only when some sample sits off its normal by more than f16 keeps.
	needs_side := false
	for sd in job.side do if abs(sd.x) > 1e-6 || abs(sd.y) > 1e-6 {
		needs_side = true
		break
	}
	if needs_side {
		skin_side_fit(sk, dst.history.allocator)
		for sd, x in job.side do sk.side[x] = {f16(sd.x), f16(sd.y)}
	} else if sk.side != nil {
		delete(sk.side, dst.history.allocator)
		sk.side = nil
	}
	rep.side = needs_side
	most: f32
	for h, x in sk.heights {
		r := abs(f32(h))
		if sk.side != nil do r += abs(f32(sk.side[x].x)) + abs(f32(sk.side[x].y))
		most = max(most, r)
	}
	sk.height_max = max(sk.height_max, most)
	for k in 0 ..< int(sk.tri_count) {
		rep.missed += int(job.missed[2 * k])
		rep.lost += int(job.missed[2 * k + 1])
	}

	// The gaps, once every sample stands where it goes.
	jobs.parallel_ranges(dst.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		dst, src := job.dst, job.src
		sk := dst.skin
		S := sk.segments
		P := dst.mesh.positions[:]
		I := dst.mesh.indices[:]
		stack := make([dynamic]u32, 0, 64, runtime.heap_allocator())
		defer delete(stack)
		third :: f32(1) / 3
		for t in u32(lo) ..< u32(hi) {
			p0, p1, p2 := P[I[3 * t]], P[I[3 * t + 1]], P[I[3 * t + 2]]
			step := (linalg.length(p1 - p0) + linalg.length(p2 - p1) + linalg.length(p0 - p2)) / (3 * f32(S))
			worst, sum: f32
			// The small triangle pointing up in each two by two block of them: enough to see
			// where the skin falls short, at an eighth of the cost of measuring every one.
			step2 := u32(2) if S > 2 else 1
			for j := u32(0); j < S; j += step2 do for i := u32(0); i < S - j; i += step2 {
				ba, na := skin_base(dst, sk, t, i, j)
				bb, nb := skin_base(dst, sk, t, i + 1, j)
				bc, nc := skin_base(dst, sk, t, i, j + 1)
				// Where the skin shows the surface: its points on the curved base.
				on := skin_point(dst, sk, t, i, j) + skin_curve(dst, sk, t, i, j, ba, linalg.normalize0(na))
				on += skin_point(dst, sk, t, i + 1, j) + skin_curve(dst, sk, t, i + 1, j, bb, linalg.normalize0(nb))
				on += skin_point(dst, sk, t, i, j + 1) + skin_curve(dst, sk, t, i, j + 1, bc, linalg.normalize0(nc))
				on *= third
				q, _ := carry_find(src, job.tree, (ba + bb + bc) * third, linalg.normalize0(na + nb + nc), job.reach, &stack)
				gap := linalg.length(on - q)
				worst = max(worst, gap)
				sum += gap
			}
			job.gaps[t] = {worst / step if step > 0 else 0, sum}
			job.gap_worst[t] = worst
		}
	}, 1 << 8)
	delete(sk.heat, dst.history.allocator)
	sk.heat = make([]u16, sk.tri_count, dst.history.allocator)
	sum: f64
	for g, t in job.gaps {
		sk.heat[t] = 1 + u16(clamp(g.x, 0, 1) * 65534 + 0.5)
		rep.worst = max(rep.worst, job.gap_worst[t])
		sum += f64(g.y)
	}
	cells := 0
	step2 := u32(2) if sk.segments > 2 else 1
	for j := u32(0); j < sk.segments; j += step2 do for i := u32(0); i < sk.segments - j; i += step2 do cells += 1
	cells *= int(sk.tri_count)
	if cells > 0 do rep.mean = f32(sum / f64(cells))
	for id in 0 ..< u32(len(dst.nodes)) do skin_mark(dst, id)
	return
}

// Drops the skin's heat (a stroke changed what it measured). True when it had any, so
// the renderer's copy of the triangles' records needs sending again.
skin_heat_drop :: proc(s: ^Sculptor) -> bool {
	sk := s.skin
	if sk == nil || sk.heat == nil do return false
	delete(sk.heat, s.history.allocator)
	sk.heat = nil
	s.skin_stamp += 1
	return true
}

@(private = "file")
Carry_Found :: enum u8 {
	Ray,
	Nearest,
	None,
}

// The old surface's point for a sample at `b` with unit normal `nu`: the nearer hit of a
// ray each way along the normal within `reach`, else the nearest point within it, else
// `b` itself.
@(private = "file")
carry_find :: proc(src: ^Sculptor, tree: ^geom.Bvh, b, nu: Vec3, reach: f32, stack: ^[dynamic]u32) -> (q: Vec3, how: Carry_Found) {
	m := src.mesh^
	best := reach
	tri := max(u32)
	hit: Vec3
	if nu != {} {
		if d, t, ok := geom.bvh_raycast_with(tree^, m, b, nu, best, stack); ok && d < best do best, tri, hit = d, t, b + nu * d
		if d, t, ok := geom.bvh_raycast_with(tree^, m, b, -nu, best, stack); ok && d < best do best, tri, hit = d, t, b - nu * d
	}
	if tri != max(u32) {
		w := carry_weights(m, tri, hit)
		return skin_surface_at(src, tri, w[1], w[2]), .Ray
	}
	t, w, _, ok := geom.bvh_closest(tree^, m, b, reach)
	if !ok do return b, .None
	return skin_surface_at(src, t, w[1], w[2]), .Nearest
}

// Whether triangle t writes the sample at its grid place (i, j): its inside samples, the
// inside samples of the edges it owns, and its corners whose first triangle it is.
@(private)
skin_owns :: proc(s: ^Sculptor, sk: ^Skin, t, i, j: u32) -> bool {
	I := s.mesh.indices[:]
	S := sk.segments
	switch {
	case (i == 0 && j == 0) || i == S || j == S:
		v := I[3 * t] if i == 0 && j == 0 else (I[3 * t + 1] if i == S else I[3 * t + 2])
		return faces_of(s, v)[0] == t
	case j == 0:
		return sk.tri_edges[t][0] & 1 == 0 && sk.edges[sk.tri_edges[t][0] >> 1].tris[0] == t
	case i + j == S:
		return sk.tri_edges[t][1] & 1 == 0 && sk.edges[sk.tri_edges[t][1] >> 1].tris[0] == t
	case i == 0:
		return sk.tri_edges[t][2] & 1 == 0 && sk.edges[sk.tri_edges[t][2] >> 1].tris[0] == t
	}
	return true
}

// The weights of triangle tri's corners at `p`, a point in its plane.
@(private = "file")
carry_weights :: proc(m: geom.Mesh, tri: u32, p: Vec3) -> [3]f32 {
	pa, pb, pc := m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]
	n := linalg.cross(pb - pa, pc - pa)
	area := linalg.dot(n, n)
	if area == 0 do return {1, 0, 0}
	wb := linalg.dot(linalg.cross(p - pa, pc - pa), n) / area
	wc := linalg.dot(linalg.cross(pb - pa, p - pa), n) / area
	return {1 - wb - wc, wb, wc}
}

// The skin as a mesh of its own, for a bake to read: a vertex at every sample where the
// skin shows it (`shown`, over its curved base) and the same triangles over the samples'
// flat points (`rest`, sharing `shown`'s indices), in the small triangles' winding, the
// mesh's. Both in `allocator`, `rest` with no normals and its indices `shown`'s own array:
// free `shown` whole and only `rest`'s positions.
sculptor_skin_mesh :: proc(s: ^Sculptor, allocator := context.allocator) -> (shown, rest: geom.Mesh, ok: bool) {
	sk := s.skin
	if sk == nil do return
	n := len(sk.heights)
	S := sk.segments
	shown.positions = make([dynamic]Vec3, n, allocator)
	rest.positions = make([dynamic]Vec3, n, allocator)
	shown.indices = make([dynamic]u32, 0, 3 * int(sk.tri_count * S * S), allocator)
	Job :: struct {
		s:           ^Sculptor,
		shown, rest: []Vec3,
	}
	job := Job{s, shown.positions[:], rest.positions[:]}
	// Each sample is written by the triangle that owns it.
	jobs.parallel_ranges(s.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		sk := s.skin
		I := s.mesh.indices[:]
		S := sk.segments
		for t in u32(lo) ..< u32(hi) do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			if !skin_owns(s, sk, t, i, j) do continue
			p, nb := skin_base(s, sk, t, i, j)
			nu := linalg.normalize0(nb)
			x := skin_sample(sk, I, t, i, j)
			job.rest[x] = p
			job.shown[x] = p + skin_lift(s, sk, x, t, i, j, nu, f32(sk.heights[x])) + skin_curve(s, sk, t, i, j, p, nu)
		}
	}, 1 << 10)
	I := s.mesh.indices[:]
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..< S do for i in u32(0) ..< S - j {
		a, b, c := skin_sample(sk, I, t, i, j), skin_sample(sk, I, t, i + 1, j), skin_sample(sk, I, t, i, j + 1)
		append(&shown.indices, a, b, c)
		if i + j + 1 < S do append(&shown.indices, b, skin_sample(sk, I, t, i + 1, j + 1), c)
	}
	rest.indices = shown.indices
	return shown, rest, true
}
