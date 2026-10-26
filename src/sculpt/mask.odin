package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
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
	Cavity, // mask by cavity, as ZBrush's Mask By Cavity: the deeper a vertex sits below its neighbours, the more
	// Mask what is hidden: every corner of a hidden triangle fully, the rest not at all.
	// Hide a part, Mask hidden, Show all, and the mask is that part. The one command that
	// writes hidden vertices.
	Hidden,
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
		w := dab_weight(d, delta, d2) * facing_weight(d, m.normals[:], v)
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
	// No mask is all 0, which only Invert, Fill, Cavity and Hidden change.
	if s.mask == nil && command != .Invert && command != .Fill && command != .Cavity && command != .Hidden do return false
	// With nothing hidden, Mask hidden would only clear the mask, which Clear does.
	if command == .Hidden && s.hide.count == 0 do return false
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
				if job.command == .Hidden {
					for v in n.vert_first ..< n.vert_first + n.vert_count do job.after[v] = 255 if corner_hidden(job.s, v) else 0
					job.changes[id] = true
					continue
				}
				// Hidden vertices keep their mask, as in ZBrush.
				for v in n.vert_first ..< n.vert_first + n.vert_count {
					if vertex_hidden(job.s, v) do continue
					job.after[v] = mask_cavity(job.s, v) if job.command == .Cavity else mask_after(job.command, job.after[v])
				}
				job.changes[id] = true
			}
		}, NODE_GRAIN)
	} else {
		mask_steps(&job, steps)
	}
	return mask_commit(&job)
}

// Masks every corner of the shown triangles of group `group` fully, as a ZBrush mask by
// polygroup does, leaving the rest of the mask as it is. One undo step; returns true when
// it changed the mask. Nothing without groups.
sculptor_mask_group :: proc(s: ^Sculptor, group: u16) -> bool {
	_ = sculptor_stroke_end(s)
	g := s.groups.tris
	if g == nil do return false
	mask_ensure(s)
	job := Mask_Job{s = s, after = slice.clone(s.mask, context.temp_allocator), changes = make([]bool, len(s.nodes), context.temp_allocator)}
	hidden := sculptor_hidden_tris(s)
	for x, t in g {
		if x != group || (hidden != nil && hidden[t]) do continue
		for k in 0 ..< 3 {
			v := s.mesh.indices[3 * t + k]
			if job.after[v] == 255 do continue
			job.after[v] = 255
			job.changes[owner_node(s.nodes, v)] = true
		}
	}
	return mask_commit(&job)
}

// Which vertices a mask shape may reach: with `on`, only those whose normal faces the
// viewer, at `eye` in the mesh's space, or along `toward` (toward the viewer) when the
// projection is `parallel`.
Front_Only :: struct {
	on:       bool,
	parallel: bool,
	eye:      Vec3,
	toward:   Vec3,
}

// Masks (or with `unmask`, unmasks) every vertex that falls inside `shape` on screen,
// as ZBrush's mask rectangle and lasso do: `clip` takes the mesh's space to clip space,
// and `shape` is a closed polygon in normalized device coordinates (x right, y up, -1
// to 1). It reaches through the mesh: vertices behind others are masked too, as in
// ZBrush, unless `front` asks for front faces only, which leaves the vertices facing
// away from the viewer (those behind are still reached where they face it). One undo step; returns true when it changed the mask. The polygon is drawn
// into a coverage grid first, so the test per vertex is a lookup however many points
// the lasso has.
sculptor_mask_shape :: proc(s: ^Sculptor, clip: matrix[4, 4]f32, shape: [][2]f32, unmask: bool, front: Front_Only = {}) -> bool {
	_ = sculptor_stroke_end(s)
	if len(shape) < 3 do return false
	if s.mask == nil && unmask do return false
	mask_ensure(s)
	grid := coverage_make(shape)
	if grid.cells == nil do return false
	Shape_Job :: struct {
		job:   Mask_Job,
		clip:  matrix[4, 4]f32,
		grid:  Coverage,
		value: u8,
		front: Front_Only,
	}
	sj := Shape_Job {
		job = {s = s, after = slice.clone(s.mask, context.temp_allocator), changes = make([]bool, len(s.nodes), context.temp_allocator)},
		clip = clip,
		grid = grid,
		value = 0 if unmask else 255,
		front = front,
	}
	jobs.parallel_ranges(s.pool, len(s.nodes), &sj, proc(data: rawptr, lo, hi: int) {
		sj := cast(^Shape_Job)data
		s := sj.job.s
		for id in lo ..< hi {
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if vertex_hidden(s, v) do continue
				p := s.mesh.positions[v]
				c := sj.clip * [4]f32{p.x, p.y, p.z, 1}
				if c.w <= 1e-6 do continue
				if !coverage_at(sj.grid, {c.x / c.w, c.y / c.w}) do continue
				if f := sj.front; f.on {
					toward := f.toward if f.parallel else f.eye - p
					if linalg.dot(s.mesh.normals[v], toward) < 0 do continue
				}
				if sj.job.after[v] != sj.value {
					sj.job.after[v] = sj.value
					sj.job.changes[id] = true
				}
			}
		}
	}, NODE_GRAIN)
	return mask_commit(&sj.job)
}

// Which cells of a grid over a polygon's bounds the polygon covers (even-odd), sampled
// at each cell's centre, for sculptor_mask_shape.
@(private)
Coverage :: struct {
	lo, size: [2]f32, // the polygon's bounds
	n:        int, // cells a side
	cells:    []bool, // row by row from lo.y
}

@(private)
COVERAGE_CELLS :: 1024

@(private)
coverage_make :: proc(shape: [][2]f32) -> (c: Coverage) {
	lo, hi := shape[0], shape[0]
	for p in shape do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	if !(hi.x > lo.x && hi.y > lo.y) do return
	c.lo, c.size, c.n = lo, hi - lo, COVERAGE_CELLS
	c.cells = make([]bool, c.n * c.n, context.temp_allocator)
	crossings := make([dynamic]f32, 0, 16, context.temp_allocator)
	for row in 0 ..< c.n {
		y := lo.y + (f32(row) + 0.5) / f32(c.n) * c.size.y
		clear(&crossings)
		for a, i in shape {
			b := shape[(i + 1) % len(shape)]
			// Each edge counts its lower end and not its upper, so a vertex on the row
			// is crossed once.
			if (a.y <= y) == (b.y <= y) do continue
			append(&crossings, a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
		}
		slice.sort(crossings[:])
		for k := 0; k + 1 < len(crossings); k += 2 {
			x0 := int(math.ceil((crossings[k] - lo.x) / c.size.x * f32(c.n) - 0.5))
			x1 := int(math.floor((crossings[k + 1] - lo.x) / c.size.x * f32(c.n) - 0.5))
			for x in max(x0, 0) ..= min(x1, c.n - 1) do c.cells[row * c.n + x] = true
		}
	}
	return
}

@(private)
coverage_at :: #force_inline proc(c: Coverage, p: [2]f32) -> bool {
	f := (p - c.lo) / c.size
	if f.x < 0 || f.y < 0 || f.x >= 1 || f.y >= 1 do return false
	return c.cells[int(f.y * f32(c.n)) * c.n + int(f.x * f32(c.n))]
}

// Makes job.after the mask as one undo step: saves and uploads only the nodes whose
// mask it changes. Returns whether it changed any.
@(private = "file")
mask_commit :: proc(job: ^Mask_Job) -> bool {
	s := job.s
	// What a node ends with may match what it started with.
	jobs.parallel_ranges(s.pool, len(s.nodes), job, proc(data: rawptr, lo, hi: int) {
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
	jobs.parallel_for(s.pool, len(job.work), job, proc(data: rawptr, i: int) {
		job := cast(^Mask_Job)data
		n := job.s.nodes[job.work[i]]
		copy(job.s.mask[n.vert_first:][:n.vert_count], job.after[n.vert_first:][:n.vert_count])
	})
	return sculptor_stroke_end(s)
}

// Nodes per claim when a pass goes over every node: claiming one at a time costs more
// than the little work most nodes need.
@(private)
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

// Whether vertex v is a corner of some hidden triangle.
@(private = "file")
corner_hidden :: #force_inline proc(s: ^Sculptor, v: u32) -> bool {
	for f in faces_of(s, v) do if s.hide.tris[f] do return true
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

// How much of a cavity vertex v sits in: how far below the average of its triangles'
// corners it lies along its normal, over their mean distance from it, so it reads the
// same at any density. A crease or pore scores high, a flat or bulging surface 0.
@(private)
mask_cavity :: #force_inline proc(s: ^Sculptor, v: u32) -> u8 {
	m := s.mesh
	p := m.positions[v]
	sum: Vec3
	spread: f32
	n: f32
	for f in faces_of(s, v) {
		for c in 0 ..< u32(3) {
			q := m.positions[m.indices[3 * f + c]]
			sum += q
			spread += linalg.length(q - p)
			n += 1
		}
	}
	if n == 0 || spread <= 0 do return 0
	// The vertex's own corners count too (at zero distance), as in Blur's average.
	depth := linalg.dot(sum / n - p, m.normals[v]) / (spread / n)
	return u8(clamp(depth * CAVITY_GAIN, 0, 1) * 255 + 0.5)
}

// The cavity depth (in mean edge lengths) that masks fully: a groove a Crease stroke
// cuts reaches it, gentle dips stay partly masked.
CAVITY_GAIN :: 6

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

// How masked the shown surface is where a ray (in the mesh's space) meets it first, 0 to
// 1: the mean of the mask at the corners of the triangle it meets. ok is false when it
// meets none.
sculptor_mask_at :: proc(s: ^Sculptor, origin, dir: Vec3) -> (mask: f32, ok: bool) {
	tri: u32
	_, tri, ok = geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir, sculptor_hidden_tris(s))
	if !ok || len(s.mask) == 0 do return
	idx := s.mesh.indices
	for c in 0 ..< 3 do mask += f32(s.mask[idx[3 * tri + u32(c)]]) / (3 * 255)
	return
}

// Whether any vertex is masked at all. It reads eight vertices a word, stopping at the
// first block of them with a mask: the action bar asks after every step, and byte by byte
// an unmasked 10M-vertex object took 5 ms against 0.7 (release build).
sculptor_has_mask :: proc(s: ^Sculptor) -> bool {
	words := slice.reinterpret([]u64, s.mask)
	seen: u64
	for w, i in words {
		seen |= w
		if i & 4095 == 4095 && seen != 0 do return true
	}
	if seen != 0 do return true
	for k in s.mask[len(words) * 8:] do if k != 0 do return true
	return false
}

// What posing needs to know of a mask: whether any shown vertex is less than fully
// masked (something a pose would move), and a checksum of every value, so the app can
// tell a change of the mask from the other undo steps. It reads the whole mask, eight
// vertices a word, so the app asks only with the Move tool on and after a step.
Mask_Look :: struct {
	free: bool,
	sum:  u64,
}

sculptor_mask_look :: proc(s: ^Sculptor) -> (look: Mask_Look) {
	if s.mask == nil do return {free = true}
	FNV_PRIME :: u64(0x100000001b3)
	h := u64(0xcbf29ce484222325)
	words := slice.reinterpret([]u64, s.mask)
	for w, i in words {
		h = (h ~ w) * FNV_PRIME
		if w != max(u64) && !look.free do look.free = mask_free_in(s, 8 * i, 8 * i + 8)
	}
	tail := 8 * len(words)
	for k in s.mask[tail:] do h = (h ~ u64(k)) * FNV_PRIME
	look.free ||= mask_free_in(s, tail, len(s.mask))
	look.sum = h
	return
}

// Whether a vertex from `lo` up to `hi` is shown and not fully masked.
@(private = "file")
mask_free_in :: proc(s: ^Sculptor, lo, hi: int) -> bool {
	for v in lo ..< hi do if s.mask[v] < 255 && !vertex_hidden(s, u32(v)) do return true
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
				k := carried_mask(from, job.src, job.dst, job.up, v) if from != nil else 0
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

// Vertex v of level `dst`'s mask carried from `from`, the mask of `src`, the level next
// to it: going up, a vertex continuing one below takes its mask and an edge vertex the
// mean of the edge's ends; going down, a vertex takes the mask of the vertex it became.
@(private)
carried_mask :: #force_inline proc(from: []u8, src, dst: ^Level, up: bool, v: u32) -> u8 {
	if up {
		p := dst.parents[v]
		return from[p[0]] if p[2] == EVEN else u8((u32(from[p[0]]) + u32(from[p[1]]) + 1) / 2)
	}
	return from[src.even_of[v]]
}

// Carries `from`, a mask of level `src`, to `to`, one of the level next to it (`dst`),
// as levels_carry_mask carries the live mask.
@(private)
mask_carry_values :: proc(l: ^Levels, from: []u8, src, dst: ^Level, up: bool, to: []u8) {
	Job :: struct {
		from, to: []u8,
		src, dst: ^Level,
		up:       bool,
	}
	job := Job{from, to, src, dst, up}
	jobs.parallel_ranges(l.pool, len(to), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for v in lo ..< hi do job.to[v] = carried_mask(job.from, job.src, job.dst, job.up, u32(v))
	}, 1 << 14)
}

// Makes `after` the mask as one undo step, saving only the nodes `changes` marks that
// end up different. Returns true when it changed the mask.
@(private)
mask_commit_values :: proc(s: ^Sculptor, after: []u8, changes: []bool) -> bool {
	job := Mask_Job{s = s, after = after, changes = changes}
	return mask_commit(&job)
}
