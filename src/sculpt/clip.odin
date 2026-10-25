package sculpt

import "core:math/linalg"

import "../jobs"

// Clipping, as ZBrush's Clip brushes do: every vertex beyond a plane moves straight
// onto it, so the part of the surface past the plane is pressed flat into a cut face.
// Nothing is removed: the triangles stay and lie in the plane. Masked vertices stay
// where they are (partly masked ones move part of the way), as with brushes.

// The side of a plane that clipping flattens: where dot(p - point, normal) > 0.
Clip_Plane :: struct {
	point:  Vec3,
	normal: Vec3, // unit length
}

// Passes over the planes for a vertex past more than one of them.
@(private = "file")
CLIP_ROUNDS :: 8

@(private = "file")
beyond :: proc(planes: []Clip_Plane, p: Vec3) -> bool {
	for pl in planes do if linalg.dot(p - pl.point, pl.normal) > 1e-6 do return true
	return false
}

// Moves every vertex beyond any of `planes` onto it, in order, as one undo step; ends
// any stroke in progress first. Returns true when a vertex moved. Refused (false) with
// dynamic topology, whose strokes save whole nodes.
sculptor_clip :: proc(s: ^Sculptor, planes: []Clip_Plane) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || len(planes) == 0 do return false
	Clip_Job :: struct {
		s:      ^Sculptor,
		planes: []Clip_Plane,
		beyond: []bool, // per node: some vertex of it is past a plane and free to move
		move:   bool, // false: only find the nodes; true: move their vertices
	}
	job := Clip_Job{s = s, planes = planes, beyond = make([]bool, len(s.nodes), context.temp_allocator)}
	// Two passes, so the nodes are saved for undo before anything moves.
	pass :: proc(data: rawptr, lo, hi: int) {
		job := cast(^Clip_Job)data
		s := job.s
		positions := s.mesh.positions[:]
		for id in lo ..< hi {
			if job.move && !job.beyond[id] do continue
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				w := shield(s.fade, s.mask, v)
				if w <= 0 do continue
				if !job.move {
					if beyond(job.planes, positions[v]) {
						job.beyond[id] = true
						break
					}
					continue
				}
				// Onto each plane in turn, a few times over: where two planes meet at an
				// angle (a cut and its mirror image), moving onto one can put a vertex past
				// the other.
				p := positions[v]
				for _ in 0 ..< CLIP_ROUNDS {
					for pl in job.planes do p -= max(linalg.dot(p - pl.point, pl.normal), 0) * pl.normal
					if !beyond(job.planes, p) do break
				}
				positions[v] = linalg.lerp(positions[v], p, w)
			}
		}
	}
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, pass, NODE_GRAIN)
	moved := make([dynamic]u32, 0, 64, context.temp_allocator)
	for b, id in job.beyond do if b do append(&moved, u32(id))
	if len(moved) == 0 do return false

	sculptor_stroke_begin(s)
	clear(&s.hit)
	for id in moved do append(&s.hit, s.nodes[id].leaf)
	record_hit(s, false)
	job.move = true
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, pass, NODE_GRAIN)
	sculptor_nodes_moved(s, moved[:])
	for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
	return sculptor_stroke_end(s)
}
