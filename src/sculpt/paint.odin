package sculpt

import "core:math/linalg"

import "../jobs"

// Polypaint, as in ZBrush: a colour per vertex, painted with the Paint brush and drawn
// over the clay. A colour is sRGB red, green and blue and a coverage in its fourth
// byte: 0 shows the clay as it is, 255 shows only the paint, so painting fades the
// colour in and the inverted brush fades it out again without a colour of its own.
// Painting moves nothing; like the mask it is uploaded with the vertex data and is an
// undo step per stroke, saving the colours of the nodes a stroke reaches. Each
// subdivision level keeps its own colours, and a level change carries them from the
// level that was painted (levels_carry_color). Not under dynamic topology, whose edits
// would have to carry every colour along (sculptor_dyn_enable drops them).

Color :: [4]u8

Paint_Command :: enum {
	Fill,  // paint every vertex the brush could reach with the brush colour
	Clear, // take the paint off every vertex the brush could reach
}

// Whether the sculptor holds colours (painted or cleared since).
sculptor_has_color :: proc(s: ^Sculptor) -> bool {return s.color != nil}

// Gives the sculptor colours, none covering the clay, if it has none yet.
@(private)
color_ensure :: proc(s: ^Sculptor) {
	if s.color != nil do return
	s.color = make([]Color, len(s.mesh.positions), s.history.allocator)
	s.paint_stamp += 1
}

// One Paint dab, called by dab_once with the hit leaves found. Returns how many
// vertices changed colour.
@(private)
paint_dab :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool) -> int {
	if s.dyn != nil do return 0
	color_ensure(s)
	if s.history.recording {
		for leaf in s.hit do record_color(s, s.node_of[leaf])
	}
	jobs.parallel_for(pool, len(s.hit), d, job_paint)
	painted := 0
	for p, i in s.partials {
		if p.moved == 0 do continue
		painted += int(p.moved)
		id := s.node_of[s.hit[i]]
		mark_stale(s, id, .Paint)
		if s.history.recording do record_painted(s, id)
	}
	if painted > 0 do s.color_edited = true
	return painted
}

@(private)
job_paint :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	painted: u32
	for v in first ..< last {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 >= d.r2 do continue
		w := d.brush.strength * dab_weight(d, delta, d2) * facing_weight(d, m.normals[:], v) * shield(s.fade, s.mask, v)
		if w <= 0 do continue
		next := paint_mix(s.color[v], d.brush.color, w, d.brush.invert)
		if next == s.color[v] do continue
		s.color[v] = next
		painted += 1
	}
	s.partials[i].moved = painted
}

// Paint laid over a colour with weight `w` (0 to 1), as one layer over another: the
// coverage grows by `w` of what is left, and the colour is the mix of the new paint and
// the old as far as each covers, so paint over bare clay is the paint colour from the
// first touch, with no dark fringe. With `erase`, the coverage shrinks by `w` and the
// colour stays. Each value moves at least one step toward where it is heading, so a
// weak dab still gets there in the end.
@(private)
paint_mix :: #force_inline proc(c: Color, paint: [3]u8, w: f32, erase: bool) -> Color {
	toward :: #force_inline proc(a, b: u8, x: f32) -> u8 {
		if b > a do return u8(min(f32(b), max(f32(a) + 1, x + 0.5)))
		if b < a do return u8(max(f32(b), min(f32(a) - 1, x + 0.5)))
		return a
	}
	if erase do return {c.r, c.g, c.b, toward(c.a, 0, f32(c.a) * (1 - w))}
	old := f32(c.a) * (1.0 / 255) * (1 - w)
	cover := w + old
	out: Color
	for k in 0 ..< 3 do out[k] = toward(c[k], paint[k], (f32(paint[k]) * w + f32(c[k]) * old) / cover)
	out.a = toward(c.a, 255, 255 * cover)
	return out
}

// Fills or clears the paint of every vertex the brush could reach, weighted by the mask
// and hiding as a dab is, as one undo step. Returns true when it changed a colour.
// Refused (false) under dynamic topology.
sculptor_paint_command :: proc(s: ^Sculptor, command: Paint_Command, color: [3]u8) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil do return false
	if s.color == nil && command == .Clear do return false
	color_ensure(s)
	Job :: struct {
		s:       ^Sculptor,
		command: Paint_Command,
		color:   [3]u8,
		changes: []bool,
	}
	job := Job{s, command, color, make([]bool, len(s.nodes), context.temp_allocator)}
	after :: #force_inline proc(job: ^Job, v: u32) -> Color {
		w := shield(job.s.fade, job.s.mask, v)
		if w <= 0 do return job.s.color[v]
		return paint_mix(job.s.color[v], job.color, w, job.command == .Clear)
	}
	// Twice: first to find the nodes that change, so only those are saved.
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for id in lo ..< hi {
			n := job.s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if after(job, v) != job.s.color[v] {
					job.changes[id] = true
					break
				}
			}
		}
	}, NODE_GRAIN)
	sculptor_stroke_begin(s)
	for c, id in job.changes do if c do record_color(s, u32(id))
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for id in lo ..< hi {
			if !job.changes[id] do continue
			n := job.s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count do job.s.color[v] = after(job, v)
		}
	}, NODE_GRAIN)
	for c, id in job.changes {
		if !c do continue
		mark_stale(s, u32(id), .Paint)
		record_painted(s, u32(id))
	}
	s.color_edited = true
	return sculptor_stroke_end(s)
}

// Saves a node's colours before the stroke first changes them. The sculptor must have
// colours.
@(private)
record_color :: proc(s: ^Sculptor, id: u32) {
	h := &s.history
	if h.color_saved[id] == h.stamp do return
	h.color_saved[id] = h.stamp
	n := s.nodes[id]
	saved := make([]Color, n.vert_count, h.allocator)
	copy(saved, s.color[n.vert_first:][:n.vert_count])
	append(&h.current.saved, Saved_Node{node = id, colors = saved})
}

// Changes to the colours or groups that need every vertex's paint data uploaded again
// (colours made, groups changed), as a stamp: data uploaded at one stamp is current
// while it stays the same, apart from the painted nodes each flush reports.
sculptor_paint_stamp :: proc(s: ^Sculptor) -> u32 {return s.paint_stamp}

// Gives the base level of levels just made (levels_init) the polypaint and polygroups of
// the mesh it was made from, for a rebuild that keeps the surface's parts, as Split and
// Merge do: `color` per vertex and `groups` per triangle of that mesh (either nil when it
// had none), `old_to_new` and `tri_from` as levels_init filled them. Not an undo step, as
// nothing came before it.
levels_take_surface :: proc(l: ^Levels, color: []Color, groups: []u16, old_to_new, tri_from: []u32) {
	s := &l.levels[0].sculptor
	if color != nil {
		color_ensure(s)
		for c, old in color do s.color[old_to_new[old]] = c
	}
	if groups != nil {
		a := s.history.allocator
		s.groups.tris = make([]u16, len(tri_from), a)
		for old, t in tri_from do s.groups.tris[t] = groups[old]
		groups_refresh(s)
	}
	s.color_edited, s.groups.edited = s.color != nil, s.groups.tris != nil
}

// Copies the colours from level `from` to level `to`, through the levels between: a
// vertex continuing one below takes its colour, a vertex on an edge the average of the
// edge's ends, and going down a vertex takes the colour of the vertex it became above.
@(private)
levels_carry_color :: proc(l: ^Levels, from, to: int) {
	if from == to do return
	step := 1 if to > from else -1
	for j := from; j != to; j += step {
		src, dst := l.levels[j], l.levels[j + step]
		if src.sculptor.color == nil do continue
		color_ensure(&dst.sculptor)
		Job :: struct {
			src, dst: ^Level,
			up:       bool,
			changed:  []bool, // per node of dst
		}
		job := Job{src, dst, step > 0, make([]bool, len(dst.sculptor.nodes), context.temp_allocator)}
		jobs.parallel_for(l.pool, len(dst.sculptor.nodes), &job, proc(data: rawptr, id: int) {
			job := cast(^Job)data
			s := &job.dst.sculptor
			from := job.src.sculptor.color
			n := s.nodes[id]
			changed := false
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				c: Color
				if job.up {
					p := job.dst.parents[v]
					if p[2] == EVEN {
						c = from[p[0]]
					} else {
						a, b := from[p[0]], from[p[1]]
						for k in 0 ..< 4 do c[k] = u8((u32(a[k]) + u32(b[k]) + 1) / 2)
					}
				} else {
					c = from[job.src.even_of[v]]
				}
				if s.color[v] != c {
					s.color[v] = c
					changed = true
				}
			}
			job.changed[id] = changed
		})
		for changed, id in job.changed do if changed do mark_stale(&dst.sculptor, u32(id), .Paint)
	}
}
