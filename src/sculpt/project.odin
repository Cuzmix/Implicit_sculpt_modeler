package sculpt

import "core:math/linalg"

import "../jobs"

// Projecting detail, as ZBrush's ProjectAll does: the caller works out where each vertex
// would land on another mesh (geom.project_along_normals) and, optionally, the colour
// there, and this moves the vertices that way by `strength` (the mask and hiding hold
// vertices back as they hold a dab), as one undo step. Refused under dynamic topology.

// Moves each vertex towards `next` and, with `colors`, fades its paint towards that
// colour, by `strength`. Returns true when it changed anything.
sculptor_project :: proc(s: ^Sculptor, next: []Vec3, colors: []Color, strength: f32) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || strength <= 0 || len(next) != len(s.mesh.positions) do return false
	if colors != nil && len(colors) != len(next) do return false
	Job :: struct {
		s:        ^Sculptor,
		next:     []Vec3,
		colors:   []Color,
		strength: f32,
		moves:    []bool, // per node
		paints:   []bool,
	}
	job := Job{s, next, colors, min(strength, 1), make([]bool, len(s.nodes), context.temp_allocator), make([]bool, len(s.nodes), context.temp_allocator)}
	weight :: #force_inline proc(job: ^Job, v: u32) -> f32 {return job.strength * shield(job.s.fade, job.s.mask, v)}
	// First find the nodes that change, so only those are saved.
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		for id in lo ..< hi {
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if weight(job, v) <= 0 do continue
				if job.next[v] != s.mesh.positions[v] do job.moves[id] = true
				if job.colors != nil && (s.color == nil || job.colors[v] != s.color[v]) do job.paints[id] = true
			}
		}
	}, NODE_GRAIN)
	moved := make([dynamic]u32, 0, len(s.nodes), context.temp_allocator)
	painted := false
	for id in 0 ..< len(s.nodes) {
		if job.moves[id] do append(&moved, u32(id))
		if job.paints[id] do painted = true
	}
	if len(moved) == 0 && !painted do return false

	sculptor_stroke_begin(s)
	clear(&s.hit)
	for id in moved do append(&s.hit, s.nodes[id].leaf)
	record_hit(s, false)
	if painted {
		color_ensure(s)
		for p, id in job.paints do if p do record_color(s, u32(id))
	}
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		for id in lo ..< hi {
			if !job.moves[id] && !job.paints[id] do continue
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				w := weight(job, v)
				if w <= 0 do continue
				if job.moves[id] do s.mesh.positions[v] = linalg.lerp(s.mesh.positions[v], job.next[v], w)
				if job.paints[id] {
					a, b := linalg.array_cast(s.color[v], f32), linalg.array_cast(job.colors[v], f32)
					mixed := linalg.lerp(a, b, w) + 0.5
					s.color[v] = linalg.array_cast(mixed, u8)
				}
			}
		}
	}, NODE_GRAIN)
	if len(moved) > 0 {
		sculptor_nodes_moved(s, moved[:])
		for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
	}
	if painted {
		for p, id in job.paints {
			if !p do continue
			mark_stale(s, u32(id), .Paint)
			record_painted(s, u32(id))
		}
		s.color_edited = true
	}
	return sculptor_stroke_end(s)
}
