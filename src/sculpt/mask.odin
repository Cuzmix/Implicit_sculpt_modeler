package sculpt

import "core:math/linalg"

import "../jobs"

// Masking, as in ZBrush: a value per vertex, 0 to 255, that shields it from brushes in
// proportion (255 leaves it alone). The Mask brush paints it with the usual falloff,
// inverted it erases; mask commands change all of it at once. Mask strokes and
// commands are undo steps like any other stroke. The mask goes to the GPU with the
// normals (see render.pack_normal), so masked areas show darker.

Mask_Command :: enum {
	Clear,  // unmask everything
	Invert, // masked becomes unmasked and the other way round
	Fill,   // mask everything
}

// One Mask dab, called by dab_once with the hit leaves found.
@(private)
mask_dab :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool) -> int {
	mask_ensure(s)
	if s.history.recording do record_hit(s, masks = true)
	d.amount = 255 * d.brush.strength * (-1 if d.brush.invert else 1)
	jobs.parallel_for(pool, len(s.hit), d, job_mask)
	painted := 0
	for p, i in s.partials {
		if p.moved == 0 do continue
		painted += int(p.moved)
		id := s.node_of[s.hit[i]]
		mark_stale(s, id, .Paint)
		if s.history.recording do record_painted(s, id)
	}
	return painted
}

@(private)
job_mask :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	fade, mask := s.fade, s.mask
	painted: u32
	for v in first ..< last {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 >= d.r2 do continue
		w := dab_weight(d, delta, d2)
		if fade != nil do w *= f32(fade[v]) * (1.0 / 255)
		next := u8(clamp(f32(mask[v]) + d.amount * w + 0.5, 0, 255))
		if next == mask[v] do continue
		mask[v] = next
		painted += 1
	}
	s.partials[i].moved = painted
}

// Gives the sculptor a mask, all zero, if it has none yet.
@(private)
mask_ensure :: proc(s: ^Sculptor) {
	if s.mask == nil do s.mask = make([]u8, len(s.mesh.positions), s.history.allocator)
}

// Applies a mask command to the whole mesh as one undo step. Returns true when it
// changed the mask (and so became a step); ends any stroke in progress first.
sculptor_mask_command :: proc(s: ^Sculptor, command: Mask_Command) -> bool {
	_ = sculptor_stroke_end(s)
	if s.mask == nil && command == .Clear do return false
	mask_ensure(s)
	Job :: struct {
		s:       ^Sculptor,
		command: Mask_Command,
		changes: []bool, // per node
	}
	job := Job{s, command, make([]bool, len(s.nodes), context.temp_allocator)}
	// Which nodes change, so only those are saved and uploaded.
	jobs.parallel_for(s.pool, len(s.nodes), &job, proc(data: rawptr, id: int) {
		job := cast(^Job)data
		n := job.s.nodes[id]
		for k in job.s.mask[n.vert_first:][:n.vert_count] {
			if k != mask_after(job.command, k) {
				job.changes[id] = true
				return
			}
		}
	})
	sculptor_stroke_begin(s)
	for changes, id in job.changes {
		if !changes do continue
		record_mask(s, u32(id))
		record_painted(s, u32(id))
		mark_stale(s, u32(id), .Paint)
	}
	jobs.parallel_for(s.pool, len(s.nodes), &job, proc(data: rawptr, id: int) {
		job := cast(^Job)data
		if !job.changes[id] do return
		n := job.s.nodes[id]
		for &k in job.s.mask[n.vert_first:][:n.vert_count] do k = mask_after(job.command, k)
	})
	return sculptor_stroke_end(s)
}

@(private)
mask_after :: #force_inline proc(command: Mask_Command, k: u8) -> u8 {
	switch command {
	case .Clear:
		return 0
	case .Invert:
		return 255 - k
	case .Fill:
		return 255
	}
	return k
}

// Whether any vertex is masked at all.
sculptor_has_mask :: proc(s: ^Sculptor) -> bool {
	for k in s.mask do if k != 0 do return true
	return false
}

// Carries the mask of level `from` to level `to` through the levels between, so a
// mask painted on one level holds on the others, as in ZBrush. A vertex that continues
// one of the level below takes its mask, a vertex on an edge the average of the
// edge's ends; going down, a vertex takes the mask of the vertex it became. Only nodes
// whose mask changes are marked for upload.
@(private)
levels_carry_mask :: proc(l: ^Levels, from, to: int) {
	if from == to do return
	step := 1 if to > from else -1
	for j := from; j != to; j += step {
		src, dst := l.levels[j], l.levels[j + step]
		if src.sculptor.mask == nil && dst.sculptor.mask == nil do continue
		mask_ensure(&dst.sculptor)
		Job :: struct {
			src, dst: ^Level,
			up:       bool,
			changed:  []bool, // per node of dst
		}
		job := Job{src, dst, step > 0, make([]bool, len(dst.sculptor.nodes), context.temp_allocator)}
		jobs.parallel_for(l.pool, len(dst.sculptor.nodes), &job, proc(data: rawptr, id: int) {
			job := cast(^Job)data
			s := &job.dst.sculptor
			from := job.src.sculptor.mask
			n := s.nodes[id]
			changed := false
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				k: u8
				if from != nil {
					if job.up {
						p := job.dst.parents[v]
						k = from[p[0]] if p[2] == EVEN else u8((u32(from[p[0]]) + u32(from[p[1]]) + 1) / 2)
					} else {
						k = from[job.src.even_of[v]]
					}
				}
				if s.mask[v] != k {
					s.mask[v] = k
					changed = true
				}
			}
			// Marked on the calling thread below: mark_stale appends to a shared list.
			job.changed[id] = changed
		})
		for changed, id in job.changed do if changed do mark_stale(&dst.sculptor, u32(id), .Paint)
	}
}
