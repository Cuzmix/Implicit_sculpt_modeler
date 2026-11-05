package sculpt

import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"
import "../uv"

// UVs on every level. They are kept once, on the base level (Levels.uvs), and a level above
// takes them from the level below whenever something asks: never stored, so a top level
// of millions of triangles costs nothing until its UVs are wanted. They are linear on
// purpose: a bake reads each base triangle flat, so a finer point takes exactly the
// coordinate the maps already give it there, where smoothed UVs would drift off them.
//
// Under Loop, each child triangle's corners are the parent's corners (an even vertex,
// taking its coordinate there) and the middles of its edges (taking the middle of the
// two ends' coordinates there). Under Catmull-Clark, each triangle has its polygon's face
// point as a corner, which names the polygon; a vertex point takes its vertex's coordinate
// in that polygon, an edge point the middle of its two ends', the face point the mean of
// the polygon's corners'. A child keeps its parent's island, so seams follow the parent's.

// Level `level`'s UVs, made with `allocator`; none when the levels have none, or when a
// level's triangles are not what its parents say (which a damaged file could make).
levels_uvs_at :: proc(l: ^Levels, level: int, allocator := context.allocator) -> (out: uv.Uvs, ok: bool) {
	if !levels_has_uvs(l) do return
	if level == 0 do return uv.clone(l.uvs, allocator), true
	below := l.uvs
	for j in 1 ..= level {
		allocate := allocator if j == level else context.temp_allocator
		next: uv.Uvs
		next, ok = level_uvs_from_below(l, j, below, allocate)
		if j > 1 do uv.destroy(&below, context.temp_allocator)
		if !ok {
			uv.destroy(&next, allocate)
			return {}, false
		}
		below = next
	}
	return below, true
}

@(private = "file")
level_uvs_from_below :: proc(l: ^Levels, j: int, below: uv.Uvs, allocator := context.allocator) -> (out: uv.Uvs, ok: bool) {
	Job :: struct {
		lv, down:  ^Level,
		below:     uv.Uvs,
		out:       uv.Uvs,
		tri_polys: []u32, // under Catmull-Clark, per triangle here: its polygon below
		down_poly: []u32, // under Catmull-Clark, per triangle below: its polygon
		bad:       bool, // atomic: some triangle could not be placed
	}
	lv, down := l.levels[j], l.levels[j - 1]
	tris := len(lv.mesh.indices) / 3
	if len(below.corner) != len(down.mesh.indices) / 3 do return
	job := Job{lv = lv, down = down, below = below}
	job.out = uv.make_uvs(tris, allocator)
	cc := lv.polys.first != nil && down.polys.first != nil
	if cc {
		job.tri_polys = cc_tri_polys(l, j)
		job.down_poly = down.polys.tri_poly
		if len(job.down_poly) != len(down.mesh.indices) / 3 {
			uv.destroy(&job.out, allocator)
			return
		}
	}
	jobs.parallel_ranges(l.pool, tris, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		bad := false
		for t in lo ..< hi {
			placed := uv_child_cc(job.lv, job.down, job.below, job.tri_polys, job.down_poly, t, &job.out) if job.tri_polys != nil else uv_child_loop(job.lv, job.down, job.below, t, &job.out)
			bad ||= !placed
		}
		if bad do sync.atomic_store(&job.bad, true)
	}, geom.RANGE_GRAIN)
	if sync.atomic_load(&job.bad) {
		uv.destroy(&job.out, allocator)
		return
	}
	out = job.out
	out.islands, out.filled = below.islands, below.filled
	uv.seams_from_breaks(&out, lv.mesh.indices[:], lv.sculptor.faces)
	if below.pins != nil {
		out.pins = make([]u32, len(below.pins), allocator)
		for p, i in below.pins do out.pins[i] = lv.even_of[p]
		slice.sort(out.pins)
	}
	return out, true
}

// The coordinate vertex `v` has in triangle `f` of `down`, and whether it is a corner of it.
@(private = "file")
uv_corner :: #force_inline proc(down: ^Level, below: uv.Uvs, f, v: u32) -> ([2]f32, bool) {
	idx := down.mesh.indices[:]
	for k in 0 ..< 3 do if idx[3 * f + u32(k)] == v do return below.corner[f][k], true
	return {}, false
}

// Triangle `t` of a Loop level: finds its parent below from two of its edge corners (each
// child has at least two: only one of an edge's two triangles holds both ends of the other
// edge), then gives each corner its coordinate there.
@(private = "file")
uv_child_loop :: proc(lv, down: ^Level, below: uv.Uvs, t: int, out: ^uv.Uvs) -> bool {
	idx := lv.mesh.indices[:]
	down_idx := down.mesh.indices[:]
	edges: [2][4]u32
	found := 0
	for k in 0 ..< 3 {
		p := lv.parents[idx[3 * t + k]]
		if p[2] != EVEN && found < 2 {
			edges[found] = p
			found += 1
		}
	}
	if found < 2 do return false
	// The edge a-b lies between a-b-c and b-a-d: the parent is whichever holds the other
	// edge's two ends.
	a, b := edges[0][0], edges[0][1]
	holds :: proc(down_idx: []u32, f: u32, x, y: u32) -> bool {
		tri := down_idx[3 * f:][:3]
		return (tri[0] == x || tri[1] == x || tri[2] == x) && (tri[0] == y || tri[1] == y || tri[2] == y)
	}
	parent := max(u32)
	for f in geom.vertex_faces_of(down.sculptor.faces, a) {
		tri := down_idx[3 * f:][:3]
		has_b := tri[0] == b || tri[1] == b || tri[2] == b
		if has_b && holds(down_idx, f, edges[1][0], edges[1][1]) {
			parent = f
			break
		}
	}
	if parent == max(u32) do return false
	out.island[t] = below.island[parent]
	for k in 0 ..< 3 {
		p := lv.parents[idx[3 * t + k]]
		if p[2] == EVEN {
			c, on := uv_corner(down, below, parent, p[0])
			if !on do return false
			out.corner[t][k] = c
		} else {
			c0, on0 := uv_corner(down, below, parent, p[0])
			c1, on1 := uv_corner(down, below, parent, p[1])
			if !on0 || !on1 do return false
			out.corner[t][k] = 0.5 * (c0 + c1)
		}
	}
	return true
}

// The coordinate vertex `v` has in polygon `poly` below: taken from the lowest numbered of
// its triangles in that polygon, so a polygon a seam crosses gives the same answer however
// the triangles were visited.
@(private = "file")
uv_in_poly :: proc(down: ^Level, below: uv.Uvs, down_poly: []u32, poly, v: u32) -> ([2]f32, bool) {
	for f in geom.vertex_faces_of(down.sculptor.faces, v) {
		if down_poly[f] != poly do continue
		return uv_corner(down, below, f, v)
	}
	return {}, false
}

// Triangle `t` of a Catmull-Clark level, from the polygon its face point names.
@(private = "file")
uv_child_cc :: proc(lv, down: ^Level, below: uv.Uvs, tri_polys, down_poly: []u32, t: int, out: ^uv.Uvs) -> bool {
	idx := lv.mesh.indices[:]
	poly := tri_polys[t]
	if int(poly) + 1 >= len(down.polys.first) do return false
	corners := down.polys.corners[down.polys.first[poly]:down.polys.first[poly + 1]]
	if len(corners) == 0 do return false
	island := max(u32)
	for f in geom.vertex_faces_of(down.sculptor.faces, corners[0]) {
		if down_poly[f] == poly {
			island = below.island[f]
			break
		}
	}
	if island == max(u32) do return false
	out.island[t] = island
	for k in 0 ..< 3 {
		p := lv.parents[idx[3 * t + k]]
		switch p[2] {
		case FACE:
			sum: [2]f32
			for c in corners {
				at, on := uv_in_poly(down, below, down_poly, poly, c)
				if !on do return false
				sum += at
			}
			out.corner[t][k] = sum / f32(len(corners))
		case EVEN:
			at, on := uv_in_poly(down, below, down_poly, poly, p[0])
			if !on do return false
			out.corner[t][k] = at
		case:
			c0, on0 := uv_in_poly(down, below, down_poly, poly, p[0])
			c1, on1 := uv_in_poly(down, below, down_poly, poly, p[1])
			if !on0 || !on1 do return false
			out.corner[t][k] = 0.5 * (c0 + c1)
		}
	}
	return true
}
