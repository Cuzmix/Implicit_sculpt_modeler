package sculpt

import "base:runtime"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Where a plane cuts the surface, as the lines the app draws along a symmetry plane
// (Nomad draws the same thin line where its mirror plane crosses the model). Each
// triangle the plane passes through gives one segment between the two edges it crosses;
// segments meeting on a shared edge are joined into polylines, so the drawing can thin
// out points closer than a pixel and draw each run as one line.
//
// Only nodes whose box the plane passes through are read, so the cost goes with the
// triangles near the plane rather than the whole mesh: about 1.2 ms a plane through a
// 5M-triangle sphere on four threads.
// Hidden triangles are left out, as they are left out of the drawing.

// One point of a section: where it is, and the face normal of the triangle whose
// segment runs from it to the next point (the last point of an open polyline takes its
// last segment's), so the drawing can leave out the parts of the cut on faces turned
// away from the viewer.
Section_Point :: struct {
	at:     Vec3,
	normal: Vec3,
}

// Polylines over one points array: polyline k is points[lines[k].first:][:lines[k].count],
// closed when `closed` (its last point joins its first).
Section_Line :: struct {
	first:  u32,
	count:  u32,
	closed: bool,
}

Section :: struct {
	points: [dynamic]Section_Point,
	lines:  [dynamic]Section_Line,
}

section_destroy :: proc(sec: ^Section) {
	delete(sec.points)
	delete(sec.lines)
	sec^ = {}
}

section_clear :: proc(sec: ^Section) {
	clear(&sec.points)
	clear(&sec.lines)
}

// Replaces `sec` with where the plane through `point` square to `normal` cuts `s`'s
// shown surface, in the mesh's space. A vertex on the plane counts as in front of it,
// so each triangle is crossed on exactly two edges or none, and two triangles sharing
// an edge agree on where it is crossed.
sculptor_plane_section :: proc(s: ^Sculptor, point, normal: Vec3, sec: ^Section) {
	section_clear(sec)
	job := Section_Job{s = s, normal = normal, offset = linalg.dot(normal, point), hidden = sculptor_hidden_tris(s)}
	work := make([dynamic]u32, 0, 256, context.temp_allocator)
	tris := 0
	for n, id in s.nodes {
		if n.tri_count == 0 || !box_meets_plane(s.chunks[id].bounds, normal, job.offset) do continue
		append(&work, u32(id))
		tris += int(n.tri_count)
	}
	if len(work) == 0 do return
	job.work = work[:]
	job.parts = make([]Section_Part, len(work), context.temp_allocator)
	jobs.parallel_for(s.pool if tris >= PARALLEL_MIN_VERTS else nil, len(work), &job, job_section)

	// The nodes' segments one after another in node order, whichever worker cut them.
	// Segment k's ends are 2k and 2k + 1, each with the edge it lies on and where.
	edges := make([dynamic]u64, 0, 256, context.temp_allocator)
	ats := make([dynamic]Vec3, 0, 256, context.temp_allocator)
	normals := make([dynamic]Vec3, 0, 128, context.temp_allocator)
	for &part in job.parts {
		append(&edges, ..part.edges[:])
		append(&ats, ..part.ats[:])
		append(&normals, ..part.normals[:])
		delete(part.edges)
		delete(part.ats)
		delete(part.normals)
	}
	if len(normals) == 0 do return

	// Ends on the same edge join, the first two in node order where more than two meet:
	// the map only finds an edge's first end, so its order never decides anything.
	partner := make([]i32, len(edges), context.temp_allocator)
	slice.fill(partner, -1)
	first_end := make(map[u64]i32, len(edges), context.temp_allocator)
	for edge, i in edges {
		other, found := first_end[edge]
		if !found {
			first_end[edge] = i32(i)
		} else if partner[other] < 0 {
			partner[other], partner[i] = i32(i), other
		}
	}

	used := make([]bool, len(normals), context.temp_allocator)
	back := make([dynamic]u32, 0, 64, context.temp_allocator)
	for start in 0 ..< len(normals) {
		if used[start] do continue
		used[start] = true
		// Back from the start's first end to where the polyline begins, keeping the ends
		// passed through, unless it comes round to the start (a loop).
		clear(&back)
		closed := false
		at := u32(2 * start)
		for {
			p := partner[at]
			if p < 0 do break
			seg := u32(p) / 2
			if seg == u32(start) {
				closed = true
				break
			}
			if used[seg] do break
			used[seg] = true
			append(&back, u32(p))
			at = u32(p) ~ 1
		}
		line := Section_Line{first = u32(len(sec.points)), closed = closed}
		// The backward walk's ends, farthest first: each such segment runs from its far
		// end toward the start, so its far end is where it begins.
		#reverse for e in back do append(&sec.points, Section_Point{ats[e ~ 1], normals[e / 2]})
		append(&sec.points, Section_Point{ats[2 * start], normals[start]})
		// A loop's last segment ends at the polyline's first point; otherwise on to the
		// start's other end and forward from there.
		if !closed {
			at = u32(2 * start + 1)
			last := u32(start)
			for {
				p := partner[at]
				if p < 0 do break
				seg := u32(p) / 2
				if used[seg] do break
				used[seg] = true
				append(&sec.points, Section_Point{ats[at], normals[seg]})
				at, last = u32(p) ~ 1, seg
			}
			append(&sec.points, Section_Point{ats[at], normals[last]})
		}
		line.count = u32(len(sec.points)) - line.first
		append(&sec.lines, line)
	}
}

// The plane section's work, shared by its jobs: the nodes to cut and each one's segments.
@(private = "file")
Section_Job :: struct {
	s:      ^Sculptor,
	normal: Vec3,
	offset: f32,
	hidden: []bool,
	work:   []u32,
	parts:  []Section_Part,
}

// One node's segments, numbered from 0 within it, as the joined lists hold them: per end
// the mesh edge it lies on (the lower vertex index in the high half) and where; per
// segment its triangle's normal. Made on the heap, as jobs must.
@(private = "file")
Section_Part :: struct {
	edges:   [dynamic]u64,
	ats:     [dynamic]Vec3,
	normals: [dynamic]Vec3,
}

// Cuts node work[i]'s triangles: each crossed on two edges gives a segment, one end on each.
@(private = "file")
job_section :: proc(data: rawptr, i: int) {
	job := (^Section_Job)(data)
	s := job.s
	pos := s.mesh.positions[:]
	idx := s.mesh.indices[:]
	normal, offset := job.normal, job.offset
	n := s.nodes[job.work[i]]
	a := runtime.heap_allocator()
	part := Section_Part {
		edges   = make([dynamic]u64, 0, 0, a),
		ats     = make([dynamic]Vec3, 0, 0, a),
		normals = make([dynamic]Vec3, 0, 0, a),
	}
	for t in n.tri_first ..< n.tri_first + n.tri_count {
		if job.hidden != nil && job.hidden[t] do continue
		tri := [3]u32{idx[3 * t], idx[3 * t + 1], idx[3 * t + 2]}
		d := [3]f32{linalg.dot(normal, pos[tri[0]]) - offset, linalg.dot(normal, pos[tri[1]]) - offset, linalg.dot(normal, pos[tri[2]]) - offset}
		front := [3]bool{d[0] >= 0, d[1] >= 0, d[2] >= 0}
		if front[0] == front[1] && front[1] == front[2] do continue
		append(&part.normals, linalg.normalize0(linalg.cross(pos[tri[1]] - pos[tri[0]], pos[tri[2]] - pos[tri[0]])))
		for k in 0 ..< 3 {
			j := (k + 1) % 3
			if front[k] == front[j] do continue
			// Worked from the lower index so both triangles on the edge get the same point.
			va, vb := tri[k], tri[j]
			da, db := d[k], d[j]
			if va > vb do va, vb, da, db = vb, va, db, da
			append(&part.ats, pos[va] + (pos[vb] - pos[va]) * (da / (da - db)))
			append(&part.edges, u64(va) << 32 | u64(vb))
		}
	}
	job.parts[i] = part
}

// Whether the plane of points p with dot(normal, p) == offset passes through the box.
@(private = "file")
box_meets_plane :: proc(box: geom.Aabb, normal: Vec3, offset: f32) -> bool {
	if box.lo.x > box.hi.x do return false
	middle := (box.lo + box.hi) / 2
	half := (box.hi - box.lo) / 2
	reach := abs(normal.x) * half.x + abs(normal.y) * half.y + abs(normal.z) * half.z
	return abs(linalg.dot(normal, middle) - offset) <= reach
}
