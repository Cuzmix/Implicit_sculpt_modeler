package sculpt

import "core:math/linalg"
import "core:slice"

import "../jobs"

// Masking, as in ZBrush: a value per vertex, 0 to 255, that shields it from brushes in
// proportion (255 leaves it alone). The Mask brush paints it with the usual falloff,
// inverted it erases; mask commands change all of it at once, and the neighbourhood
// ones (ZBrush's BlurMask, SharpenMask, GrowMask and ShrinkMask, Blender's mask filters)
// move its edge. Mask strokes and commands are undo steps like any other stroke. The
// mask goes to the GPU with the normals (see render.pack_normal), so masked areas show
// darker.

Mask_Command :: enum {
	Clear,  // unmask everything
	Invert, // masked becomes unmasked and the other way round
	Fill,   // mask everything
	// The rest work a step at a time, each vertex from the corners of its triangles, so
	// one step reaches one ring of triangles further.
	Blur,    // toward the average: the edge softens
	Sharpen, // away from half masked: a soft edge narrows
	Grow,    // the most masked corner: the mask spreads
	Shrink,  // the least masked corner: the mask draws back
}

// How far a Sharpen step pushes a vertex toward fully masked or unmasked, out of 255.
// It works against half a Blur step, so the edge it narrows to stays smooth along the
// triangles instead of turning jagged.
SHARPEN_PUSH :: 13

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

// Applies a mask command to the whole mesh as one undo step; Blur, Sharpen, Grow and
// Shrink take `steps` steps. Returns true when it changed the mask (and so became a
// step); ends any stroke in progress first.
sculptor_mask_command :: proc(s: ^Sculptor, command: Mask_Command, steps := 1) -> bool {
	_ = sculptor_stroke_end(s)
	// No mask is all 0, which only Invert and Fill change.
	if s.mask == nil && command != .Invert && command != .Fill do return false
	mask_ensure(s)
	// The whole mask after the command is worked out first, so only the nodes that
	// change are saved and uploaded. Slots no node owns (free ones with dynamic
	// topology) keep their value.
	job := Mask_Job {
		s       = s,
		command = command,
		after   = slice.clone(s.mask, context.temp_allocator),
		changes = make([]bool, len(s.nodes), context.temp_allocator),
	}
	if command < .Blur {
		jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
			job := cast(^Mask_Job)data
			for id in lo ..< hi {
				n := job.s.nodes[id]
				for &k in job.after[n.vert_first:][:n.vert_count] do k = mask_after(job.command, k)
				job.changes[id] = true
			}
		}, NODE_GRAIN)
	} else {
		mask_steps(&job, steps)
	}
	// What a node ends with may match what it started with.
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Mask_Job)data
		for id in lo ..< hi {
			if !job.changes[id] do continue
			n := job.s.nodes[id]
			job.changes[id] = !slice.equal(job.after[n.vert_first:][:n.vert_count], job.s.mask[n.vert_first:][:n.vert_count])
		}
	}, NODE_GRAIN)
	sculptor_stroke_begin(s)
	changed := make([dynamic]u32, 0, len(s.nodes), context.temp_allocator)
	for changes, id in job.changes {
		if !changes do continue
		append(&changed, u32(id))
		record_mask(s, u32(id))
		record_painted(s, u32(id))
		mark_stale(s, u32(id), .Paint)
	}
	job.work = changed[:]
	jobs.parallel_for(s.pool, len(job.work), &job, proc(data: rawptr, i: int) {
		job := cast(^Mask_Job)data
		n := job.s.nodes[job.work[i]]
		copy(job.s.mask[n.vert_first:][:n.vert_count], job.after[n.vert_first:][:n.vert_count])
	})
	return sculptor_stroke_end(s)
}

// Nodes per claim when a pass goes over every node: claiming one at a time costs more
// than the little work most nodes need.
@(private = "file")
NODE_GRAIN :: 64

@(private = "file")
Mask_Job :: struct {
	s:       ^Sculptor,
	command: Mask_Command,
	after:   []u8, // the mask once the command is done
	changes: []bool, // per node: some vertex may differ from the mask before the command
	work:    []u32, // the nodes a pass over a list works on
	// The neighbourhood commands only:
	uneven:  []bool, // per node: its triangles' corners are not all one value
	next:    [dynamic]u8, // a step's new values for the vertices of `work`, node after node
	offsets: [dynamic]int, // where each node of `work` starts in `next`
	moved:   [dynamic]bool, // per node of `work`: a vertex it owns moved this step
}

// The steps of a neighbourhood command, into job.after. A vertex whose triangles'
// corners all share its value (fully masked or unmasked, for Sharpen) stays as it is,
// so a step works only on the nodes around the mask's edge, and the step after it
// rechecks only the nodes with a corner that moved.
@(private = "file")
mask_steps :: proc(job: ^Mask_Job, steps: int) {
	s := job.s
	nodes := len(s.nodes)
	// For each node, the nodes listing it as the owner of a shared vertex: those whose
	// triangles have a corner it owns, besides its own.
	listed_first := make([]int, nodes + 1, context.temp_allocator)
	for id in 0 ..< nodes do for owner in node_owners(s, u32(id)) do listed_first[owner + 1] += 1
	for id in 0 ..< nodes do listed_first[id + 1] += listed_first[id]
	listed := make([]u32, listed_first[nodes], context.temp_allocator)
	fill := slice.clone(listed_first[:nodes], context.temp_allocator)
	for id in 0 ..< nodes {
		for owner in node_owners(s, u32(id)) {
			listed[fill[owner]] = u32(id)
			fill[owner] += 1
		}
	}

	job.uneven = make([]bool, nodes, context.temp_allocator)
	job.next = make([dynamic]u8, context.temp_allocator)
	job.offsets = make([dynamic]int, context.temp_allocator)
	job.moved = make([dynamic]bool, context.temp_allocator)
	marked := make([]bool, nodes, context.temp_allocator)
	work := make([dynamic]u32, 0, nodes, context.temp_allocator)
	mark :: proc(work: ^[dynamic]u32, marked: []bool, id: u32) {
		if marked[id] do return
		marked[id] = true
		append(work, id)
	}
	jobs.parallel_ranges(s.pool, nodes, job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Mask_Job)data
		for id in lo ..< hi do job.uneven[id] = node_uneven(job.s, job.after, job.command, u32(id))
	}, NODE_GRAIN)
	for _ in 0 ..< max(steps, 1) {
		// A vertex is a corner of its own node's triangles or, shared, of those of a
		// node listing its owner.
		clear(&work)
		slice.zero(marked)
		for uneven, id in job.uneven {
			if !uneven do continue
			mark(&work, marked, u32(id))
			for owner in node_owners(s, u32(id)) do mark(&work, marked, owner)
		}
		if len(work) == 0 do return
		job.work = work[:]
		resize(&job.offsets, len(work))
		resize(&job.moved, len(work))
		total := 0
		for id, i in work {
			job.offsets[i] = total
			total += int(s.nodes[id].vert_count)
		}
		resize(&job.next, total)
		// Every new value is read from the step before's mask, then written back.
		jobs.parallel_for(s.pool, len(work), job, proc(data: rawptr, i: int) {
			job := cast(^Mask_Job)data
			n := job.s.nodes[job.work[i]]
			out := job.next[job.offsets[i]:][:n.vert_count]
			moved := false
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				k := mask_filtered(job.s, job.after, job.command, v)
				out[v - n.vert_first] = k
				moved ||= k != job.after[v]
			}
			job.moved[i] = moved
		})
		jobs.parallel_for(s.pool, len(work), job, proc(data: rawptr, i: int) {
			job := cast(^Mask_Job)data
			if !job.moved[i] do return
			id := job.work[i]
			n := job.s.nodes[id]
			copy(job.after[n.vert_first:][:n.vert_count], job.next[job.offsets[i]:][:n.vert_count])
			job.changes[id] = true
		})
		// A node's corners changed only where a vertex moved: in the node that owns it
		// and the nodes listing that one as an owner.
		recheck := make([dynamic]u32, 0, len(work), context.temp_allocator)
		slice.zero(marked)
		for id, i in work {
			if !job.moved[i] do continue
			mark(&recheck, marked, id)
			for other in listed[listed_first[id]:listed_first[id + 1]] do mark(&recheck, marked, other)
		}
		job.work = recheck[:]
		jobs.parallel_for(s.pool, len(recheck), job, proc(data: rawptr, i: int) {
			job := cast(^Mask_Job)data
			id := job.work[i]
			job.uneven[id] = node_uneven(job.s, job.after, job.command, id)
		})
	}
}

// Whether the corners of the node's triangles (its own vertices and its shared ones)
// are not all the same value, or for Sharpen are all one partial value, which it pushes.
@(private = "file")
node_uneven :: proc(s: ^Sculptor, from: []u8, command: Mask_Command, id: u32) -> bool {
	n := s.nodes[id]
	own := from[n.vert_first:][:n.vert_count]
	shared := node_shared(s, id)
	k: u8
	if len(own) > 0 {
		k = own[0]
	} else if len(shared) > 0 {
		k = from[shared[0]]
	} else {
		return false
	}
	if command == .Sharpen && k != 0 && k != 255 do return true
	for x in own do if x != k do return true
	for v in shared do if from[v] != k do return true
	return false
}

@(private)
mask_after :: #force_inline proc(command: Mask_Command, k: u8) -> u8 {
	#partial switch command {
	case .Clear:
		return 0
	case .Invert:
		return 255 - k
	case .Fill:
		return 255
	}
	return k
}

// Vertex v's mask after one step of a neighbourhood command, from the corners of its
// triangles in `from`. v is a corner of each of them, so it counts a third of the
// average and each neighbour, in two of them, the rest between them.
@(private)
mask_filtered :: #force_inline proc(s: ^Sculptor, from: []u8, command: Mask_Command, v: u32) -> u8 {
	indices := s.mesh.indices[:]
	k := u32(from[v])
	lo, hi, sum, n := k, k, u32(0), u32(0)
	for f in faces_of(s, v) {
		for c in 0 ..< u32(3) {
			x := u32(from[indices[3 * f + c]])
			lo, hi = min(lo, x), max(hi, x)
			sum += x
			n += 1
		}
	}
	if n == 0 do return u8(k)
	#partial switch command {
	case .Blur:
		return u8((sum + n / 2) / n)
	case .Sharpen:
		push: f32 = SHARPEN_PUSH if k >= 128 else -SHARPEN_PUSH
		return u8(clamp(f32(k) + push + 0.5 * (f32(sum) / f32(n) - f32(k)) + 0.5, 0, 255))
	case .Grow:
		return u8(hi)
	case .Shrink:
		return u8(lo)
	}
	return u8(k)
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
