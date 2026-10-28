package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Polygroups, as in ZBrush: a group number per triangle that splits a mesh into parts,
// which a click hides, isolates or masks whole (sculptor_hide_group, sculptor_mask_group).
// Groups come from what is shown (ZBrush's Ctrl+W), from the mask, or from the creases
// of the surface; each change is one undo step saving the groups of the nodes it
// changes. Each subdivision level keeps its own groups and a level change carries them
// from the level they were changed on (levels_carry_groups). None under dynamic
// topology (sculptor_dyn_enable drops them).
//
// Drawing shows each triangle in its group's colour, flat, with no colour data per
// triangle: a vertex carries one group to the GPU (`vertex`), and each triangle is drawn
// starting from a corner whose vertex carries its own group (`lead`), which is the corner
// the GPU takes a flat value from. groups_refresh picks both so that almost every
// triangle has such a corner; the rare one that cannot shows a neighbour's colour.

Groups :: struct {
	tris:   []u16, // per triangle: its group; nil until something is grouped
	vertex: []u16, // per vertex: the group it carries to the GPU
	lead:   []u8,  // per triangle: the corner (0 to 2) drawn first
	// Set when the groups changed since the level became current, so a level change
	// carries them to the others.
	edited: bool,
}

Group_Command :: enum {
	Visible, // what is shown becomes one new group (with nothing hidden: one group for everything)
	Masked,  // what is masked becomes one new group
	Creases, // a group for each part between creases sharper than the angle given
	Clear,   // everything back to group 0
	// Added later, so the ones before keep their numbers.
	Pieces,        // a group for each connected piece of what is shown
	Normals,       // a group for each part facing within the angle given of its first triangle (each flood starts at the first triangle no earlier one reached)
	Merge_Similar, // groups of as many triangles and much the same area become one
	Uv_Charts,     // a group for each UV chart: needs the levels (levels_group_uv_charts)
}

// Angle between neighbouring triangles beyond which Creases starts a new group, by default.
CREASE_GROUP_DEGREES :: 35

// Whether the sculptor has groups.
sculptor_has_groups :: proc(s: ^Sculptor) -> bool {return s.groups.tris != nil}

// The groups per triangle, or nil.
sculptor_groups :: proc(s: ^Sculptor) -> []u16 {return s.groups.tris}

// The group each vertex carries to the GPU, or nil without groups.
sculptor_vertex_groups :: proc(s: ^Sculptor) -> []u16 {return s.groups.vertex if s.groups.tris != nil else nil}

@(private)
groups_destroy :: proc(s: ^Sculptor) {
	a := s.history.allocator
	delete(s.groups.tris, a)
	delete(s.groups.vertex, a)
	delete(s.groups.lead, a)
	s.groups = {}
}

// Changes the groups as one undo step: Creases and Normals take the angle in degrees.
// Returns true when a group changed. Refused (false) under dynamic topology and for
// Uv_Charts (levels_group_uv_charts runs it); Masked does nothing without a mask, Clear
// and Merge similar nothing without groups. Hidden triangles keep their groups.
sculptor_group_command :: proc(s: ^Sculptor, command: Group_Command, degrees: f32 = CREASE_GROUP_DEGREES) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil do return false
	if command == .Masked && s.mask == nil do return false
	if (command == .Clear || command == .Merge_Similar) && s.groups.tris == nil do return false
	// The charts belong to the base level's quads, which a sculptor does not know.
	if command == .Uv_Charts do return false
	tcount := len(s.mesh.indices) / 3
	after := make([]u16, tcount, context.temp_allocator)
	if s.groups.tris != nil do copy(after, s.groups.tris)
	hidden := sculptor_hidden_tris(s)
	switch command {
	case .Visible, .Masked:
		fresh := groups_next(s)
		m := s.mesh
		for t in 0 ..< tcount {
			if hidden != nil && hidden[t] do continue
			if command == .Masked {
				sum := u32(s.mask[m.indices[3 * t]]) + u32(s.mask[m.indices[3 * t + 1]]) + u32(s.mask[m.indices[3 * t + 2]])
				if sum < 3 * 128 do continue
			}
			after[t] = fresh
		}
	case .Creases:
		groups_by_creases(s, after, hidden, math.cos(math.to_radians(degrees)))
	case .Pieces:
		// No edge is sharp enough to stop the flood.
		groups_by_creases(s, after, hidden, -2)
	case .Normals:
		groups_by_creases(s, after, hidden, math.cos(math.to_radians(degrees)), from_seed = true)
	case .Clear:
		for &g, t in after do if hidden == nil || !hidden[t] do g = 0
	case .Merge_Similar:
		groups_merge_similar(s, after, hidden)
	case .Uv_Charts:
	}
	return groups_commit(s, after)
}

// The lowest group number no triangle has yet, after the highest in use (wrapping past
// the last one a u16 holds).
@(private)
groups_next :: proc(s: ^Sculptor) -> u16 {
	if s.groups.tris == nil do return 1
	top: u16
	for g in s.groups.tris do top = max(top, g)
	return top + 1
}

// Floods each part of the shown surface between edges whose triangles meet at a cosine
// below `cos_limit`, numbering the parts 0, 1, ... in triangle order. With `from_seed`, a
// triangle joins when its normal is within `cos_limit` of the part's first triangle's
// instead, so a part stays one way round however gently it turns (Group by normals).
@(private = "file")
groups_by_creases :: proc(s: ^Sculptor, out: []u16, hidden: []bool, cos_limit: f32, from_seed := false) {
	m := s.mesh
	tcount := len(out)
	normal := make([]Vec3, tcount, context.temp_allocator)
	Normal_Job :: struct {
		m:      ^geom.Mesh,
		normal: []Vec3,
	}
	nj := Normal_Job{m, normal}
	jobs.parallel_ranges(s.pool, tcount, &nj, proc(data: rawptr, lo, hi: int) {
		nj := cast(^Normal_Job)data
		for t in lo ..< hi {
			a, b, c := nj.m.positions[nj.m.indices[3 * t]], nj.m.positions[nj.m.indices[3 * t + 1]], nj.m.positions[nj.m.indices[3 * t + 2]]
			nj.normal[t] = linalg.normalize0(linalg.cross(b - a, c - a))
		}
	}, geom.RANGE_GRAIN)
	seen := make([]bool, tcount, context.temp_allocator)
	stack := make([dynamic]u32, 0, 1024, context.temp_allocator)
	// Hidden triangles keep their groups, so the new ones start past those.
	group: u16 = groups_next(s) if hidden != nil else 0
	for start in 0 ..< tcount {
		if seen[start] || (hidden != nil && hidden[start]) do continue
		seen[start] = true
		append(&stack, u32(start))
		seed := normal[start]
		for len(stack) > 0 {
			t := pop(&stack)
			out[t] = group
			against := seed if from_seed else normal[t]
			for k in 0 ..< 3 {
				a, b := m.indices[3 * t + u32(k)], m.indices[3 * t + u32((k + 1) % 3)]
				for f in geom.vertex_faces_of(s.faces, a) {
					if seen[f] || (hidden != nil && hidden[f]) do continue
					if !tri_has(m.indices[:], f, b) do continue
					if linalg.dot(against, normal[f]) < cos_limit do continue
					seen[f] = true
					append(&stack, f)
				}
			}
		}
		// Past the last number a u16 holds, the rest share it rather than wrap to 0.
		if group < max(u16) do group += 1
	}
}

// Merges groups alike in size, as ZBrush's Merge similar groups does: over the shown
// triangles, each group's triangle count and area; groups sorted by those, and each run
// of the same count whose areas are within 1% of the run's first becomes the run's
// lowest group. Only shown triangles change, so a group partly hidden keeps its number
// on the hidden part. Serial and in a fixed order, so the result never depends on threads.
@(private = "file")
groups_merge_similar :: proc(s: ^Sculptor, out: []u16, hidden: []bool) {
	Stat :: struct {
		count: int,
		area:  f64,
		group: u16,
	}
	stats := make([]Stat, int(max(u16)) + 1, context.temp_allocator)
	m := s.mesh
	for g, t in out {
		if hidden != nil && hidden[t] do continue
		a, b, c := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
		stats[g].count += 1
		stats[g].area += f64(linalg.length(linalg.cross(b - a, c - a))) / 2
	}
	used := make([dynamic]Stat, 0, 64, context.temp_allocator)
	for &st, g in stats {
		st.group = u16(g)
		if st.count > 0 do append(&used, st)
	}
	slice.sort_by(used[:], proc(x, y: Stat) -> bool {
		if x.count != y.count do return x.count < y.count
		if x.area != y.area do return x.area < y.area
		return x.group < y.group
	})
	into := make([]u16, len(stats), context.temp_allocator)
	for &g, i in into do g = u16(i)
	for i := 0; i < len(used); {
		j, lowest := i + 1, used[i].group
		for j < len(used) && used[j].count == used[i].count && used[j].area - used[i].area <= 0.01 * used[i].area {
			lowest = min(lowest, used[j].group)
			j += 1
		}
		for k in i ..< j do into[used[k].group] = lowest
		i = j
	}
	for &g, t in out do if hidden == nil || !hidden[t] do g = into[g]
}

@(private = "file")
tri_has :: #force_inline proc(indices: []u32, t, v: u32) -> bool {
	return indices[3 * t] == v || indices[3 * t + 1] == v || indices[3 * t + 2] == v
}

// Saves the groups of the nodes `after` changes in an undo step of their own, takes
// `after` as the groups and brings what drawing needs up to date.
@(private)
groups_commit :: proc(s: ^Sculptor, after: []u16) -> bool {
	a := s.history.allocator
	changed := make([dynamic]u32, 0, 64, context.temp_allocator)
	for n, id in s.nodes {
		first, count := int(n.tri_first), int(n.tri_count)
		if s.groups.tris == nil {
			for g in after[first:][:count] do if g != 0 {append(&changed, u32(id)); break}
		} else if !slice.equal(after[first:][:count], s.groups.tris[first:][:count]) {
			append(&changed, u32(id))
		}
	}
	if len(changed) == 0 do return false
	if s.groups.tris == nil do s.groups.tris = make([]u16, len(after), a)
	sculptor_stroke_begin(s)
	h := &s.history
	for id in changed {
		n := s.nodes[id]
		append(&h.current.saved, Saved_Node{node = id, groups = slice.clone(s.groups.tris[n.tri_first:][:n.tri_count], a)})
		append(&h.current.grouped, id)
	}
	copy(s.groups.tris, after)
	groups_refresh(s)
	s.groups.edited = true
	return sculptor_stroke_end(s)
}

// Picks what each vertex carries to the GPU and the corner each triangle is drawn
// from (see Groups), then has every vertex's paint data and every node's triangles
// uploaded again.
@(private)
groups_refresh :: proc(s: ^Sculptor) {
	g := &s.groups
	if g.tris == nil do return
	a := s.history.allocator
	m := s.mesh
	vcount, tcount := len(m.positions), len(m.indices) / 3
	if len(g.vertex) != vcount {
		delete(g.vertex, a)
		g.vertex = make([]u16, vcount, a)
	}
	if len(g.lead) != tcount {
		delete(g.lead, a)
		g.lead = make([]u8, tcount, a)
	}
	// Each vertex carries the group most of its triangles have (the earliest of equals).
	jobs.parallel_ranges(s.pool, vcount, s, proc(data: rawptr, lo, hi: int) {
		s := cast(^Sculptor)data
		g := &s.groups
		for v in u32(lo) ..< u32(hi) {
			faces := geom.vertex_faces_of(s.faces, v)
			best, best_count := u16(0), 0
			for f, i in faces {
				count := 0
				for e in faces[i:] do count += int(g.tris[e] == g.tris[f])
				if count > best_count do best, best_count = g.tris[f], count
			}
			g.vertex[v] = best
		}
	}, geom.RANGE_GRAIN)
	jobs.parallel_ranges(s.pool, tcount, s, proc(data: rawptr, lo, hi: int) {
		s := cast(^Sculptor)data
		for t in lo ..< hi do s.groups.lead[t] = lead_corner(s, u32(t))
	}, geom.RANGE_GRAIN)
	// A triangle none of whose corners carries its group takes over a corner whose other
	// triangles do not need it, where one has such a corner. In order, so the outcome
	// never depends on threads.
	for t in 0 ..< u32(tcount) {
		if g.lead[t] != NO_LEAD do continue
		g.lead[t] = 0
		for k in 0 ..< u32(3) {
			v := m.indices[3 * t + k]
			free := true
			for f in geom.vertex_faces_of(s.faces, v) {
				if f == t || g.tris[f] == g.tris[t] do continue
				// f keeps its colour only through another corner carrying its group.
				other := false
				for j in 0 ..< u32(3) {
					w := m.indices[3 * f + j]
					if w != v && g.vertex[w] == g.tris[f] do other = true
				}
				if !other {free = false; break}
			}
			if !free do continue
			g.vertex[v] = g.tris[t]
			for f in geom.vertex_faces_of(s.faces, v) {
				if lead := lead_corner(s, f); lead != NO_LEAD do g.lead[f] = lead
			}
			break
		}
	}
	s.paint_stamp += 1
	// Every node's triangles go up again, turned to start at their lead corners.
	h := &s.hide
	for _, id in s.nodes do append(&h.dirty, u32(id))
	h.stamp += 1
	if h.stamp == 0 do h.stamp = 1
}

@(private = "file")
NO_LEAD :: 255

// The first corner of triangle t whose vertex carries its group, or NO_LEAD.
@(private = "file")
lead_corner :: #force_inline proc(s: ^Sculptor, t: u32) -> u8 {
	g := &s.groups
	for k in 0 ..< u32(3) {
		if g.vertex[s.mesh.indices[3 * t + k]] == g.tris[t] do return u8(k)
	}
	return NO_LEAD
}

// Triangle t's corners as drawn: starting from its lead corner when there are groups,
// which keeps the winding.
@(private)
drawn_triangle :: #force_inline proc(s: ^Sculptor, t: int) -> [3]u32 {
	i := s.mesh.indices[3 * t:][:3]
	if s.groups.tris == nil do return {i[0], i[1], i[2]}
	switch s.groups.lead[t] {
	case 1:
		return {i[1], i[2], i[0]}
	case 2:
		return {i[2], i[0], i[1]}
	}
	return {i[0], i[1], i[2]}
}

// The group of the shown triangle a ray (in the mesh's space) meets first; ok is false
// when it meets none or there are no groups.
sculptor_group_at :: proc(s: ^Sculptor, origin, dir: Vec3) -> (group: u16, ok: bool) {
	if s.groups.tris == nil do return
	tri: u32
	_, tri, ok = geom.bvh_raycast(&s.bvh, s.mesh^, origin, dir, sculptor_hidden_tris(s))
	if ok do group = s.groups.tris[tri]
	return
}

// For each triangle of level j (above the base), the triangle of the level below it
// was cut from: the one with the vertices its corners came from. Temporary.
@(private = "file")
level_tri_parents :: proc(l: ^Levels, j: int) -> []u32 {
	Job :: struct {
		lv, below: ^Level,
		out:       []u32,
	}
	lv := l.levels[j]
	job := Job{lv, l.levels[j - 1], make([]u32, len(lv.mesh.indices) / 3, context.temp_allocator)}
	jobs.parallel_ranges(l.pool, len(job.out), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for t in lo ..< hi {
			// The corners come from three vertices below: an even corner from one, an edge
			// corner from its edge's two ends.
			from: [6]u32
			count := 0
			for k in 0 ..< 3 {
				p := job.lv.parents[job.lv.mesh.indices[3 * t + k]]
				ends := 1 if p[2] == EVEN else 2
				for e in 0 ..< ends {
					if !slice.contains(from[:count], p[e]) {
						from[count] = p[e]
						count += 1
					}
				}
			}
			job.out[t] = 0
			below := job.below
			for f in geom.vertex_faces_of(below.sculptor.faces, from[0]) {
				if count >= 3 && tri_has(below.mesh.indices[:], f, from[1]) && tri_has(below.mesh.indices[:], f, from[2]) {
					job.out[t] = f
					break
				}
			}
		}
	}, geom.RANGE_GRAIN)
	return job.out
}

// Copies the groups from level `from` to level `to`, through the levels between: a
// triangle going up takes the group of the triangle it was cut from, and going down a
// triangle takes the group of the middle one of the four cut from it.
@(private)
levels_carry_groups :: proc(l: ^Levels, from, to: int) {
	if from == to do return
	step := 1 if to > from else -1
	for j := from; j != to; j += step {
		src, dst := &l.levels[j].sculptor, &l.levels[j + step].sculptor
		if src.groups.tris == nil && dst.groups.tris == nil do continue
		fine := j + 1 if step > 0 else j
		if dst.groups.tris == nil do dst.groups.tris = make([]u16, len(dst.mesh.indices) / 3, dst.history.allocator)
		// Catmull-Clark levels go by polygons: going up a triangle takes the group of the
		// first triangle of the polygon it was cut from, and going down every triangle of
		// a polygon takes the group of the lowest-numbered triangle cut from it.
		if p := &l.levels[fine - 1].polys; l.rule != .Loop && p.first != nil {
			polys := cc_tri_polys(l, fine)
			count := len(p.first) - 1
			switch {
			case src.groups.tris == nil:
				slice.zero(dst.groups.tris)
			case step > 0:
				first := make([]u32, count, context.temp_allocator)
				slice.fill(first, NO_SLOT)
				for f, t in p.tri_poly do if first[f] == NO_SLOT do first[f] = u32(t)
				for f, t in polys do dst.groups.tris[t] = src.groups.tris[first[f]]
			case:
				taken := make([]bool, count, context.temp_allocator)
				group := make([]u16, count, context.temp_allocator)
				for f, t in polys {
					if taken[f] do continue
					taken[f] = true
					group[f] = src.groups.tris[t]
				}
				for f, t in p.tri_poly do dst.groups.tris[t] = group[f]
			}
			groups_refresh(dst)
			continue
		}
		parent := level_tri_parents(l, fine)
		switch {
		case src.groups.tris == nil:
			slice.zero(dst.groups.tris)
		case step > 0:
			for p, t in parent do dst.groups.tris[t] = src.groups.tris[p]
		case:
			lv := l.levels[fine]
			for p, t in parent {
				middle := true
				for k in 0 ..< 3 do if lv.parents[lv.mesh.indices[3 * t + k]][2] == EVEN do middle = false
				if middle do dst.groups.tris[p] = src.groups.tris[t]
			}
		}
		groups_refresh(dst)
	}
}

// Gives each UV chart of a retopologized object its own group (the chart's number + 1)
// on the level shown, as ZBrush's Groups by UVs does, in one undo step: each base
// triangle takes the chart of the quad it is half of, and each triangle above the chart
// of the one it was cut from. Hidden triangles keep their groups. False without UVs,
// under dynamic topology, and when nothing changes.
levels_group_uv_charts :: proc(l: ^Levels) -> bool {
	if !levels_has_uvs(l) || l.hd.window != nil do return false
	s := &levels_current(l).sculptor
	_ = sculptor_stroke_end(s)
	if s.dyn != nil do return false
	base := l.levels[0]
	m := base.mesh
	// The quads at each base vertex, to find the one holding a triangle's three corners.
	// As offsets into one list: vertex v's quads are list[first[v]:first[v + 1]].
	first := make([]u32, len(m.positions) + 1, context.temp_allocator)
	for q in l.faces.quads do for v in q do first[v + 1] += 1
	for v in 0 ..< len(m.positions) do first[v + 1] += first[v]
	list := make([]u32, 4 * len(l.faces.quads), context.temp_allocator)
	fill := slice.clone(first, context.temp_allocator)
	for q, i in l.faces.quads {
		for v in q {
			list[fill[v]] = u32(i)
			fill[v] += 1
		}
	}
	chart := make([]u32, len(m.indices) / 3, context.temp_allocator)
	for &c, t in chart {
		i := m.indices[3 * t:][:3]
		found := false
		for q in list[first[i[0]]:first[i[0] + 1]] {
			quad := l.faces.quads[q]
			if slice.contains(quad[:], i[1]) && slice.contains(quad[:], i[2]) {
				c, found = l.faces.uv.chart[q], true
				break
			}
		}
		// The base level's triangles are its quads' halves, in its own vertex numbers.
		assert(found, "a base triangle is no quad's half")
	}
	for j in 1 ..= l.current {
		parent := level_tri_parents(l, j)
		up := make([]u32, len(parent), context.temp_allocator)
		for p, t in parent do up[t] = chart[p]
		chart = up
	}
	after := make([]u16, len(chart), context.temp_allocator)
	if s.groups.tris != nil do copy(after, s.groups.tris)
	hidden := sculptor_hidden_tris(s)
	// Hidden triangles keep their groups, so the charts' start past those, as Creases' do.
	start := u32(groups_next(s)) if hidden != nil else 1
	for c, t in chart do if hidden == nil || !hidden[t] do after[t] = u16(min(c + start, u32(max(u16))))
	return groups_commit(s, after)
}
