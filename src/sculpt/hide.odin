package sculpt

import "core:slice"

import "../geom"
import "../jobs"

// Hiding, as ZBrush's Ctrl+Shift selections do: triangles can be hidden, and a hidden
// triangle is neither drawn nor hit by the pointer. A vertex all of whose triangles are
// hidden gets a `fade` of 0, so brushes, Clip and the mask leave it alone; a vertex on
// the edge of what is hidden still moves, with the visible triangles it belongs to.
// Each sculptor (so each subdivision level) keeps its own hidden triangles; there are
// none under dynamic topology or in an HD window, whose sculptors use `fade` themselves.
// A hiding change is one undo step, saving the flags of the nodes it changes.

Hide :: struct {
	tris:    []bool, // per triangle: hidden; nil until something is first hidden
	in_node: []u32,  // per node: how many of its triangles are hidden
	count:   int,    // hidden triangles in all
	// Per chunk, then per group of simplified copies (Draw_Item.hidden): the chunks with
	// every triangle hidden, and the groups over any hidden triangle, whose copies would
	// show it.
	units:   []bool,
	// Nodes whose triangles changed visibility since sculptor_hidden_indices last took
	// them. `stamp` counts changes; `taken` is the stamp they were last taken at.
	dirty:   [dynamic]u32,
	stamp:   u32,
	taken:   u32,
	// Whether the last hiding change was refused because it would have hidden every
	// triangle, so the app can say why nothing happened.
	refused_all: bool,
}

Hide_Command :: enum {
	Show_All, // show every hidden triangle
	Invert,   // hide what is shown and show what is hidden
	// The mask made visibility, as ZBrush's HidePt by mask and Blender's Hide Masked: a
	// triangle counts as masked when every corner is masked at least half (MASK_HALF), so
	// the two hide exactly complementary parts. What is hidden already stays hidden.
	Masked,   // hide the masked triangles
	Unmasked, // hide the rest
}

// The mask value from which a corner counts as masked, for hiding by mask: half of 255,
// so every triangle is on exactly one side and the two hides are complements.
MASK_HALF :: 128

// What hiding by shape does with the triangles inside the shape.
Hide_Shape :: enum {
	Show_Only, // hide everything outside it (what is hidden inside stays hidden)
	Hide,      // hide everything inside it
}

@(private)
hide_destroy :: proc(s: ^Sculptor) {
	a := s.history.allocator
	delete(s.hide.tris, a)
	delete(s.hide.in_node, a)
	delete(s.hide.units, a)
	delete(s.hide.dirty)
	s.hide = {}
}

// Shows everything without an undo step, for changes that clear the history anyway
// (dynamic topology on). The GPU has to be given the mesh's own indices again.
@(private)
hide_drop :: proc(s: ^Sculptor) {
	if s.hide.count > 0 {
		delete(s.fade)
		s.fade = nil
	}
	hide_destroy(s)
}

// Whether the last hiding change was refused because it would have hidden everything.
sculptor_hide_refused_all :: proc(s: ^Sculptor) -> bool {return s.hide.refused_all}

// How many triangles are hidden.
sculptor_hidden_count :: proc(s: ^Sculptor) -> int {return s.hide.count}

// What drawing leaves out (see Hide.units), or nil when nothing is hidden.
sculptor_hidden_units :: proc(s: ^Sculptor) -> []bool {
	return s.hide.units if s.hide.count > 0 else nil
}

// The hidden flags per triangle for picking (geom.bvh_raycast's `skip`), or nil.
sculptor_hidden_tris :: proc(s: ^Sculptor) -> []bool {
	return s.hide.tris if s.hide.count > 0 else nil
}

// Counts changes to what is hidden: index data uploaded at one stamp is current while
// the stamp stays the same. 0 means nothing was ever hidden.
sculptor_hidden_stamp :: proc(s: ^Sculptor) -> u32 {return s.hide.stamp}

// Whether vertex v is hidden: every triangle it belongs to is.
@(private)
vertex_hidden :: #force_inline proc(s: ^Sculptor, v: u32) -> bool {
	return s.hide.count > 0 && s.fade[v] == 0
}

// The index data that drawing needs for what is hidden and for polygroups: per node,
// its triangles with the hidden ones made degenerate (all three corners 0, which draws
// nothing) and, with groups, each starting from its lead corner (groups.odin), packed in
// node order, and where each node's triangles go in the index buffer. The nodes are the
// ones changed since the last call when the buffer holds the data of `uploaded` (the
// stamp it was last brought to, 0 for one made from the mesh), or else every node with a
// hidden triangle (every node, with groups) and every changed one. Both slices are
// temporary.
sculptor_hidden_indices :: proc(s: ^Sculptor, uploaded: u32) -> (indices: []u32, ranges: []geom.Index_Range) {
	h := &s.hide
	if uploaded == h.stamp do return
	nodes := make([dynamic]u32, 0, len(h.dirty), context.temp_allocator)
	append(&nodes, ..h.dirty[:])
	if uploaded != h.taken {
		if s.groups.tris != nil {
			for _, id in s.nodes do append(&nodes, u32(id))
		} else {
			for c, id in h.in_node do if c > 0 do append(&nodes, u32(id))
		}
	}
	clear(&h.dirty)
	h.taken = h.stamp
	slice.sort(nodes[:])
	kept := slice.unique(nodes[:])
	total := 0
	for id in kept do total += 3 * int(s.nodes[id].tri_count)
	indices = make([]u32, total, context.temp_allocator)
	ranges = make([]geom.Index_Range, len(kept), context.temp_allocator)
	at := 0
	for id, i in kept {
		n := s.nodes[id]
		first := 3 * int(n.tri_first)
		count := 3 * int(n.tri_count)
		if s.groups.tris != nil {
			for t in 0 ..< int(n.tri_count) {
				c := drawn_triangle(s, int(n.tri_first) + t)
				copy(indices[at + 3 * t:][:3], c[:])
			}
		} else {
			copy(indices[at:][:count], s.mesh.indices[first:][:count])
		}
		if h.tris != nil && h.in_node[id] > 0 {
			for t in 0 ..< int(n.tri_count) {
				if h.tris[int(n.tri_first) + t] do slice.zero(indices[at + 3 * t:][:3])
			}
		}
		ranges[i] = {u32(first), u32(count)}
		at += count
	}
	return
}

// Hides or shows everything at once, or by the mask, as one undo step. Returns true
// when it changed what is hidden. Refused (false) under dynamic topology, in an HD
// window (whose sculptor has a fade of its own), by the mask without one, and when it
// would hide every triangle (sculptor_hide_refused_all): something must stay in view,
// as in ZBrush.
sculptor_hide_command :: proc(s: ^Sculptor, command: Hide_Command) -> bool {
	_ = sculptor_stroke_end(s)
	if command == .Show_All && s.hide.count == 0 do return false
	// No mask is all unmasked: nothing to hide by it, and hiding the rest would hide all.
	if (command == .Masked || command == .Unmasked) && s.mask == nil do return false
	job := Hide_Job{s = s, command = command}
	return hide_apply(&job)
}

// Hides the triangles whose middle falls inside `shape` on screen, or with .Show_Only
// everything outside it, as ZBrush's SelectRect and SelectLasso do: `clip` takes the
// mesh's space to clip space and `shape` is a closed polygon in normalized device
// coordinates (x right, y up), as for sculptor_mask_shape. It reaches through the mesh.
// One undo step; returns true when it changed what is hidden. Refused as
// sculptor_hide_command is.
sculptor_hide_shape :: proc(s: ^Sculptor, clip: matrix[4, 4]f32, shape: [][2]f32, mode: Hide_Shape) -> bool {
	_ = sculptor_stroke_end(s)
	if len(shape) < 3 do return false
	grid := coverage_make(shape)
	if grid.cells == nil do return false
	job := Hide_Job{s = s, shaped = true, mode = mode, clip = clip, grid = grid}
	return hide_apply(&job)
}

// Hides every shown triangle outside group `group`, showing the group's hidden ones,
// as ZBrush's Ctrl+Shift click on a polygroup does; when that group is all there is to
// see already, hides it and shows everything else instead. One undo step; returns true
// when it changed what is hidden. Refused as sculptor_hide_command is, and without
// groups.
sculptor_hide_group :: proc(s: ^Sculptor, group: u16) -> bool {
	_ = sculptor_stroke_end(s)
	g := s.groups.tris
	if g == nil do return false
	alone := true
	for x, t in g {
		shown := s.hide.tris == nil || !s.hide.tris[t]
		if (x == group) != shown {alone = false; break}
	}
	job := Hide_Job{s = s, by_group = true, group = group, hide_group = alone}
	return hide_apply(&job)
}

@(private = "file")
Hide_Job :: struct {
	s:       ^Sculptor,
	command: Hide_Command,
	by_group:   bool, // by `group` rather than `command` or a shape
	group:      u16,
	hide_group: bool, // hide `group` and show the rest, rather than the other way round
	shaped:  bool, // by `mode`, `clip` and `grid` rather than `command`
	mode:    Hide_Shape,
	clip:    matrix[4, 4]f32,
	grid:    Coverage,
	write:   bool, // false: only count; true: change the triangles
	changes: []bool, // per node: some triangle of it changes
	after:   []u32,  // per node: hidden triangles once the change is made
}

// Whether triangle t is hidden once the job is done.
@(private = "file")
hide_after :: #force_inline proc(job: ^Hide_Job, t: int) -> bool {
	s := job.s
	was := s.hide.tris != nil && s.hide.tris[t]
	if job.by_group do return (s.groups.tris[t] == job.group) == job.hide_group
	m := s.mesh
	if !job.shaped {
		switch job.command {
		case .Show_All: return false
		case .Invert:   return !was
		case .Masked, .Unmasked:
			i := m.indices[3 * t:][:3]
			masked := s.mask[i[0]] >= MASK_HALF && s.mask[i[1]] >= MASK_HALF && s.mask[i[2]] >= MASK_HALF
			return was || masked == (job.command == .Masked)
		}
	}
	c := (m.positions[m.indices[3 * t]] + m.positions[m.indices[3 * t + 1]] + m.positions[m.indices[3 * t + 2]]) * (1.0 / 3)
	q := job.clip * [4]f32{c.x, c.y, c.z, 1}
	inside := q.w > 1e-6 && coverage_at(job.grid, {q.x / q.w, q.y / q.w})
	return was || (inside == (job.mode == .Hide))
}

// Works out what the job changes, refuses hiding everything, saves the nodes it
// changes in an undo step of their own and changes them.
@(private = "file")
hide_apply :: proc(job: ^Hide_Job) -> bool {
	s := job.s
	s.hide.refused_all = false
	if s.dyn != nil || (s.fade != nil && s.hide.count == 0) do return false
	job.changes = make([]bool, len(s.nodes), context.temp_allocator)
	job.after = make([]u32, len(s.nodes), context.temp_allocator)
	// Twice: first to count, so nothing is saved or changed for a refused job, then to
	// change what the first pass found.
	pass :: proc(data: rawptr, lo, hi: int) {
		job := cast(^Hide_Job)data
		s := job.s
		for id in lo ..< hi {
			n := s.nodes[id]
			if job.write && !job.changes[id] do continue
			hidden: u32
			for t in int(n.tri_first) ..< int(n.tri_first + n.tri_count) {
				now := hide_after(job, t)
				if job.write {
					s.hide.tris[t] = now
					continue
				}
				if now do hidden += 1
				if now != (s.hide.tris != nil && s.hide.tris[t]) do job.changes[id] = true
			}
			if !job.write do job.after[id] = hidden
		}
	}
	jobs.parallel_ranges(s.pool, len(s.nodes), job, pass, NODE_GRAIN)
	total := 0
	for c in job.after do total += int(c)
	if total == len(s.mesh.indices) / 3 {
		s.hide.refused_all = true
		return false
	}
	changed := make([dynamic]u32, 0, 64, context.temp_allocator)
	for c, id in job.changes do if c do append(&changed, u32(id))
	if len(changed) == 0 do return false

	a := s.history.allocator
	if s.hide.tris == nil {
		s.hide.tris = make([]bool, len(s.mesh.indices) / 3, a)
		s.hide.in_node = make([]u32, len(s.nodes), a)
	}
	sculptor_stroke_begin(s)
	h := &s.history
	for id in changed {
		n := s.nodes[id]
		append(&h.current.saved, Saved_Node{node = id, hidden = slice.clone(s.hide.tris[n.tri_first:][:n.tri_count], a)})
		append(&h.current.shown, id)
	}
	job.write = true
	jobs.parallel_ranges(s.pool, len(s.nodes), job, pass, NODE_GRAIN)
	hide_refresh(s, changed[:])
	return sculptor_stroke_end(s)
}

// Brings everything that follows from the hidden triangles up to date after those of
// `nodes` changed: the counts, the vertices' fade, what drawing leaves out, and the
// nodes the GPU must take again.
@(private)
hide_refresh :: proc(s: ^Sculptor, nodes: []u32) {
	h := &s.hide
	a := s.history.allocator
	for id in nodes {
		n := s.nodes[id]
		c: u32
		for x in h.tris[n.tri_first:][:n.tri_count] do c += u32(x)
		h.in_node[id] = c
	}
	h.count = 0
	for c in h.in_node do h.count += int(c)
	append(&h.dirty, ..nodes)
	h.stamp += 1
	if h.stamp == 0 do h.stamp = 1 // 0 means the mesh's own indices

	if h.count == 0 {
		delete(s.fade)
		s.fade = nil
		slice.zero(h.units)
		return
	}
	// A vertex is hidden when all its triangles are: only vertices of the changed nodes'
	// triangles can change, and those are owned by the nodes or by their owners.
	if s.fade == nil {
		s.fade = make([]u8, len(s.mesh.positions))
		slice.fill(s.fade, 255)
	}
	touch := make([]bool, len(s.nodes), context.temp_allocator)
	for id in nodes {
		touch[id] = true
		n := s.nodes[id]
		for o in s.owners[n.owner_first:][:n.owner_count] do touch[o] = true
	}
	Fade_Job :: struct {
		s:     ^Sculptor,
		touch: []bool,
	}
	fj := Fade_Job{s, touch}
	jobs.parallel_ranges(s.pool, len(s.nodes), &fj, proc(data: rawptr, lo, hi: int) {
		fj := cast(^Fade_Job)data
		s := fj.s
		for id in lo ..< hi {
			if !fj.touch[id] do continue
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				all := true
				for t in geom.vertex_faces_of(s.faces, v) do if !s.hide.tris[t] {all = false; break}
				s.fade[v] = 0 if all else 255
			}
		}
	}, NODE_GRAIN)

	units := len(s.nodes) + len(s.lod.tree.groups)
	if len(h.units) != units {
		delete(h.units, a)
		h.units = make([]bool, units, a)
	} else {
		slice.zero(h.units)
	}
	for c, id in h.in_node {
		if c == 0 do continue
		h.units[id] = c == s.nodes[id].tri_count
		unit := u32(id)
		for len(s.lod.parent) > 0 && s.lod.parent[unit] != LOD_NO_PARENT {
			unit = u32(len(s.nodes)) + s.lod.parent[unit]
			if h.units[unit] do break
			h.units[unit] = true
		}
	}
}
