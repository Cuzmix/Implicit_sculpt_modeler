package sculpt

import "base:runtime"
import "core:math"
import "core:slice"

import "../geom"
import "../jobs"

// Carrying sculpt layers onto a rebuilt surface, as Nomad keeps its layers through a
// remesh: after Remesh, Decimate, Mirror and weld, Slice or a boolean, the new mesh
// takes the old one's layers with their names, sliders and recording. The new mesh is
// built from the shown surface, which already holds every layer's work at its
// strength, so nothing moves; what the new mesh gains is each layer's displacement,
// read at the nearest point of the old surface (blended over that triangle's corners),
// so that dialling a layer afterwards moves the new mesh as it moved the old one.
//
// A new vertex far from the old surface (where a boolean joined another object, or a
// slice closed the cut) takes the layers less the farther it is, down to none at
// SURFACE_REACH edge lengths, so a layer dialled afterwards leaves no step at the seam.

// How far from the old surface, in edge lengths of the coarser of the two meshes, a
// new vertex still takes some of the layers; it takes them fully within half of that.
SURFACE_REACH :: 4

@(private = "file")
SURFACE_LEAF :: 8

// For Mirror and weld: the new vertices on the side not kept are mirror images of kept
// ones, so they read the layers at their mirror image, mirrored back.
Surface_Mirror :: struct {
	active:        bool,
	axis:          Axis,
	keep_positive: bool,
}

// Where each vertex of a new mesh lies on an old one: per new vertex, the old triangle
// nearest to it, the weights over that triangle's corners, and how much of what is
// read there it takes (0 to 1, by distance). Built on the calling thread's allocator.
Surface_Map :: struct {
	tri:       []u32,
	bary:      [][3]f32,
	weight:    []f32,
	reflected: []bool, // read at the mirror image (Surface_Mirror)
	mirror:    Surface_Mirror,
}

surface_map_destroy :: proc(m: ^Surface_Map) {
	delete(m.tri)
	delete(m.bary)
	delete(m.weight)
	delete(m.reflected)
	m^ = {}
}

// Maps every vertex of `to` onto the surface of `from` (both without dynamic topology).
// With `wanted` (per node of `from`: whether what is read there matters, as
// sculptor_layers_wanted gives), only the vertices that could read a wanted node are
// mapped; the rest get weight 0, which is what reading them would give. That leaves
// most of the work undone for a layer over a small part of the surface.
surface_map_build :: proc(from, to: ^Sculptor, mirror: Surface_Mirror = {}, wanted: []bool = nil) -> Surface_Map {
	n := len(to.mesh.positions)
	sm := Surface_Map {
		tri       = make([]u32, n),
		bary      = make([][3]f32, n),
		weight    = make([]f32, n),
		reflected = make([]bool, n),
		mirror    = mirror,
	}
	Work :: struct {
		to:     ^Sculptor,
		from:   ^Sculptor,
		mesh:   geom.Mesh, // the old triangles searched: all of them, or those near a wanted node
		tris:   []u32,     // their ids in the old mesh, when only some
		bvh:    geom.Bvh,
		sm:     ^Surface_Map,
		reach:  f32,
		near:   []bool, // per old node: one of its triangles has a corner a wanted node owns
		mapped: []bool, // per new node: whether its vertices are mapped
	}
	w := Work{to = to, from = from, mesh = from.mesh^, sm = &sm}
	w.reach = SURFACE_REACH * max(mean_edge(from.mesh^, from.pool), mean_edge(to.mesh^, to.pool))
	w.mapped = make([]bool, len(to.nodes))
	defer delete(w.mapped)
	sub: [dynamic]u32
	defer delete(sub)
	defer delete(w.tris)
	if wanted == nil {
		slice.fill(w.mapped, true)
	} else {
		// A new vertex reads a wanted node's displacement only through an old triangle
		// with a corner that node owns, within reach. So a new node is mapped when its
		// box, grown by the reach, meets a node holding such a triangle, and the search
		// needs only the old nodes such a box meets: for a vertex of a mapped node,
		// anything nearer than the reach is in one of those.
		w.near = make([]bool, len(from.nodes))
		defer delete(w.near)
		for &near, id in w.near {
			nd := from.nodes[id]
			near = wanted[id]
			for o in from.owners[nd.owner_first:][:nd.owner_count] do near ||= wanted[o]
		}
		jobs.parallel_for(to.pool, len(to.nodes), &w, proc(data: rawptr, i: int) {
			w := cast(^Work)data
			w.mapped[i] = boxes_meet(w.from, surface_grow(w.to, i, w.reach, w.sm.mirror), w.near, nil)
		})
		searched := make([]bool, len(from.nodes))
		defer delete(searched)
		for mapped, i in w.mapped do if mapped do _ = boxes_meet(from, surface_grow(to, i, w.reach, mirror), nil, searched)
		count := 0
		for yes, id in searched do if yes do count += int(from.nodes[id].tri_count)
		if count == 0 do return sm
		if count < len(from.mesh.indices) / 3 {
			sub = make([dynamic]u32, 0, 3 * count)
			w.tris = make([]u32, count)
			k := 0
			for yes, id in searched {
				if !yes do continue
				nd := from.nodes[id]
				append(&sub, ..from.mesh.indices[3 * nd.tri_first:][:3 * nd.tri_count])
				for t in nd.tri_first ..< nd.tri_first + nd.tri_count {
					w.tris[k] = t
					k += 1
				}
			}
			w.mesh = geom.Mesh{positions = from.mesh.positions, indices = sub}
		}
	}
	// A tree of its own with small leaves: the sculptor's has a node's thousand
	// triangles in each, all of which a query would try. Eight a leaf builds a third
	// faster than four at 10M triangles, and queries as fast.
	w.bvh = geom.bvh_build_morton(w.mesh, SURFACE_LEAF, from.pool)
	defer geom.bvh_destroy(&w.bvh)
	jobs.parallel_for(to.pool, len(to.nodes), &w, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		if !w.mapped[i] do return
		sm := w.sm
		n := w.to.nodes[i]
		axis := int(sm.mirror.axis)
		side: f32 = 1 if sm.mirror.keep_positive else -1
		// A node's vertices lie together, so each starts from the last one's answer;
		// the node's first starts afresh, so threads find what one thread does.
		hint := geom.BVH_NONE
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			p := w.to.mesh.positions[v]
			if sm.mirror.active && p[axis] * side < 0 {
				p[axis] = -p[axis]
				sm.reflected[v] = true
			}
			tri, bary, dist, ok := geom.bvh_closest(w.bvh, w.mesh, p, w.reach, hint)
			if !ok do continue
			hint = tri
			sm.tri[v], sm.bary[v] = w.tris[tri] if w.tris != nil else tri, bary
			sm.weight[v] = 1 - math.smoothstep(w.reach * 0.5, w.reach, dist)
		}
	})
	return sm
}

// The box of new node `i` grown by `by`, and by its mirror image when the map reads
// mirrored: a vertex on the far side reads at its reflection.
@(private = "file")
surface_grow :: proc(to: ^Sculptor, i: int, by: f32, mirror: Surface_Mirror) -> geom.Aabb {
	b := to.bvh.nodes[to.nodes[i].leaf].bounds
	if mirror.active {
		a := int(mirror.axis)
		lo, hi := b.lo[a], b.hi[a]
		b.lo[a], b.hi[a] = min(lo, -hi), max(hi, -lo)
	}
	return {b.lo - by, b.hi + by}
}

// Whether the box meets the bounds of a node of `s` marked in `marked` (nil: any);
// with `mark`, marks every node it meets there instead and returns whether any.
@(private = "file")
boxes_meet :: proc(s: ^Sculptor, box: geom.Aabb, marked: []bool, mark: []bool) -> bool {
	// The sculptor's tree is a Morton build, as deep as geom.bvh_closest allows for.
	stack: [64]u32
	top := 1
	met := false
	for top > 0 {
		top -= 1
		node := s.bvh.nodes[stack[top]]
		b := node.bounds
		if b.lo.x > box.hi.x || b.lo.y > box.hi.y || b.lo.z > box.hi.z || b.hi.x < box.lo.x || b.hi.y < box.lo.y || b.hi.z < box.lo.z do continue
		if node.count > 0 {
			id := s.node_of[stack[top]]
			if mark != nil {
				mark[id] = true
				met = true
			} else if marked == nil || marked[id] {
				return true
			}
			continue
		}
		assert(top + 2 <= len(stack))
		stack[top], stack[top + 1] = node.first, node.first + 1
		top += 2
	}
	return met
}

// Per node: whether any layer displaces its vertices, the nodes a carry reads from.
sculptor_layers_wanted :: proc(s: ^Sculptor) -> []bool {
	wanted := make([]bool, len(s.nodes))
	for l in s.layers.list do for d, id in l.delta do if d != nil do wanted[id] = true
	return wanted
}

// The mean edge length of a mesh, from its area as if its triangles were equilateral:
// one pass that is already written, and close enough for a reach.
@(private = "file")
mean_edge :: proc(m: geom.Mesh, pool: ^jobs.Pool) -> f32 {
	tris := len(m.indices) / 3
	if tris == 0 do return 0
	area, _ := geom.mesh_area_bounds(m, pool)
	return f32(math.sqrt(4 * area / (math.sqrt(f64(3)) * f64(tris))))
}

// Gives `to`, a sculptor just built from `from`'s shown surface (with no layers and no
// history of its own yet), `from`'s layers read through the map: names, strengths,
// visibility, which records and the naming count. Not an undo step: a rebuild is one
// already, whose undo puts the old object back with its layers. Returns how many
// layers it carried; none when `from` has none or either has dynamic topology on.
sculptor_layers_project :: proc(from, to: ^Sculptor, sm: Surface_Map) -> int {
	if len(from.layers.list) == 0 || from.dyn != nil || to.dyn != nil do return 0
	// Displacements are carried alone: each takes in what its mask shows first.
	layer_masks_bake(from)
	assert(len(to.layers.list) == 0 && len(sm.tri) == len(to.mesh.positions))
	Work :: struct {
		from:  ^Sculptor,
		to:    ^Sculptor,
		sm:    Surface_Map,
		owner: []u32, // per old vertex, the node owning it
		used:  []bool, // per layer and new node: whether some vertex reads a displacement
		nodes: int,
	}
	w := Work{from = from, to = to, sm = sm, nodes = len(to.nodes)}
	w.owner = make([]u32, len(from.mesh.positions))
	defer delete(w.owner)
	w.used = make([]bool, len(from.layers.list) * len(to.nodes))
	defer delete(w.used)
	jobs.parallel_for(from.pool, len(from.nodes), &w, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		n := w.from.nodes[i]
		for &o in w.owner[n.vert_first:][:n.vert_count] do o = u32(i)
	})
	// First which new nodes each layer reaches, so their displacement is allocated here
	// on the calling thread, with the allocator the layers are freed with.
	jobs.parallel_for(to.pool, len(to.nodes), &w, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		n := w.to.nodes[i]
		m := w.from.mesh
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			if w.sm.weight[v] == 0 do continue
			t := w.sm.tri[v]
			for l, k in w.from.layers.list {
				if w.used[k * w.nodes + i] do continue
				for c in 0 ..< 3 do if l.delta[w.owner[m.indices[3 * t + u32(c)]]] != nil && w.sm.bary[v][c] != 0 {
					w.used[k * w.nodes + i] = true
					break
				}
			}
		}
	})
	alloc := to.history.allocator
	for l, k in from.layers.list {
		carried := Sculpt_Layer{name = l.name, strength = l.strength, visible = l.visible, delta = make([][]Vec3, len(to.nodes), alloc)}
		for &d, i in carried.delta do if w.used[k * w.nodes + i] do d = make([]Vec3, to.nodes[i].vert_count, alloc)
		append(&to.layers.list, carried)
	}
	jobs.parallel_for(to.pool, len(to.nodes), &w, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		n := w.to.nodes[i]
		m := w.from.mesh
		axis := int(w.sm.mirror.axis)
		for l, k in w.from.layers.list {
			out := w.to.layers.list[k].delta[i]
			if out == nil do continue
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				weight := w.sm.weight[v]
				if weight == 0 do continue
				t := w.sm.tri[v]
				d: Vec3
				for c in 0 ..< 3 {
					corner := m.indices[3 * t + u32(c)]
					node := w.owner[corner]
					if l.delta[node] != nil do d += w.sm.bary[v][c] * l.delta[node][corner - w.from.nodes[node].vert_first]
				}
				if w.sm.mirror.active {
					// Mirrored back on the far side; along the plane on it, so that the
					// seam stays on the plane whatever the slider does.
					if w.sm.reflected[v] do d[axis] = -d[axis]
					if w.to.mesh.positions[v][axis] == 0 do d[axis] = 0
				}
				out[v - n.vert_first] = weight * d
			}
		}
	})
	to.layers.recording = from.layers.recording
	to.layers.named = from.layers.named
	return len(from.layers.list)
}

// The level a rebuild starts from, taken out of its Levels so that it outlives them
// while its layers are carried onto the rebuilt object (levels_carry_layers); nil when
// it has no layers to carry. Free it with layered_level_free.
Layered_Level :: struct {
	level:     ^Level,
	allocator: runtime.Allocator,
}

// Takes the current level out of `l` when it has layers, just before `l` is destroyed
// for a rebuild: the other levels go as before, and so do their layers.
levels_take_layered :: proc(l: ^Levels) -> Layered_Level {
	if len(l.levels) == 0 do return {}
	lv := levels_current(l)
	if len(lv.sculptor.layers.list) == 0 || lv.sculptor.dyn != nil do return {}
	// A layer slider still held is ended here: what it set is what the shape shows.
	_ = sculptor_stroke_end(&lv.sculptor)
	ordered_remove(&l.levels, l.current)
	l.current = 0
	return {lv, l.allocator}
}

// Carries the taken level's layers onto the level `l` shows (a fresh one, built from
// that level's shown surface), mirrored as Mirror and weld made it. Returns how many.
levels_carry_layers :: proc(l: ^Levels, from: Layered_Level, mirror: Surface_Mirror = {}) -> int {
	if from.level == nil || len(l.levels) == 0 do return 0
	to := &levels_current(l).sculptor
	wanted := sculptor_layers_wanted(&from.level.sculptor)
	defer delete(wanted)
	sm := surface_map_build(&from.level.sculptor, to, mirror, wanted)
	defer surface_map_destroy(&sm)
	return sculptor_layers_project(&from.level.sculptor, to, sm)
}

layered_level_free :: proc(t: ^Layered_Level) {
	if t.level == nil do return
	// level_free reads only the allocator of the Levels it is given.
	owner := Levels{allocator = t.allocator}
	level_free(&owner, t.level)
	t^ = {}
}

// How many sculpt layers the object's levels hold, all levels together.
levels_layer_count :: proc(l: ^Levels) -> int {
	n := 0
	for lv in l.levels do n += len(lv.sculptor.layers.list)
	return n
}

// Carries the layers of every level above the current one down to it, as Delete higher
// is about to free those levels (the in-between levels' layers too, gathered on the
// way). A level's work reached the one below only through the sync, which moves each
// vertex below by half the change of the vertex it became plus half the mean change of
// that vertex's neighbours (push_down); a layer is carried with the same weights, a level
// at a time, so setting it to 0 afterwards takes off about what it put on the level. The
// detail finer than the level goes with the levels above, as their other work does.
// Layers past MAX_SCULPT_LAYERS go (their work stays in the shape, baked). Returns how
// many layers reached the current level, and how many went for want of room.
@(private)
levels_carry_layers_down :: proc(l: ^Levels) -> (carried, dropped: int) {
	for j := len(l.levels) - 1; j > l.current; j -= 1 {
		fine, coarse := l.levels[j], l.levels[j - 1]
		fs, cs := &fine.sculptor, &coarse.sculptor
		layer_masks_bake(fs)
		for &layer in fs.layers.list {
			if len(cs.layers.list) >= MAX_SCULPT_LAYERS || cs.dyn != nil {
				dropped += 1
			} else {
				append(&cs.layers.list, layer_push_down(l, j, layer))
				if j - 1 == l.current do carried += 1
			}
			layer_destroy(&layer, fs.history.allocator)
		}
		clear(&fs.layers.list)
		fs.layers.recording = 0
		cs.layers.named = max(cs.layers.named, fs.layers.named)
	}
	return
}

// Level j's layer as a layer of level j - 1, by push_down's weights.
@(private = "file")
layer_push_down :: proc(l: ^Levels, j: int, layer: Sculpt_Layer) -> Sculpt_Layer {
	Work :: struct {
		fine, coarse: ^Level,
		from:         Sculpt_Layer,
		out:          [][]Vec3,
		ids:          [dynamic]u32,
	}
	w := Work{fine = l.levels[j], coarse = l.levels[j - 1], from = layer}
	cs := &w.coarse.sculptor
	out := Sculpt_Layer{name = layer.name, strength = layer.strength, visible = layer.visible}
	out.delta = make([][]Vec3, len(cs.nodes), cs.history.allocator)
	w.out = out.delta
	// A node below moves only through the nodes above that read it, so it takes
	// displacement only when one of them has some; allocated here, on the calling thread.
	w.ids = make([dynamic]u32, 0, len(cs.nodes), context.temp_allocator)
	verts: u32
	for c in 0 ..< u32(len(cs.nodes)) {
		for id in node_list(w.fine.dependents, c) {
			if layer.delta[id] == nil do continue
			w.out[c] = make([]Vec3, cs.nodes[c].vert_count, cs.history.allocator)
			append(&w.ids, c)
			verts += cs.nodes[c].vert_count
			break
		}
	}
	jobs.parallel_for(l.pool if verts >= PARALLEL_MIN_VERTS else nil, len(w.ids), &w, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		fine := w.fine
		c := w.ids[i]
		n := w.coarse.sculptor.nodes[c]
		at :: #force_inline proc(fine: ^Level, layer: Sculpt_Layer, u: u32) -> Vec3 {
			id := fine.node_of_vertex[u]
			d := layer.delta[id]
			return d[u - fine.sculptor.nodes[id].vert_first] if d != nil else {}
		}
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			e := fine.even_of[v]
			faces := geom.vertex_faces_of(fine.sculptor.faces, e)
			ring: Vec3
			// Around a vertex of a closed mesh, each neighbour comes first in one triangle.
			for f in faces {
				o1, _ := others(fine.mesh.indices[:], f, e)
				ring += at(fine, w.from, o1)
			}
			w.out[c][v - n.vert_first] = at(fine, w.from, e) * 0.5 + ring * (0.5 / f32(len(faces)))
		}
	})
	return out
}

// Moves the layers of the level below the top up to the top, just made by Subdivide
// from it, as ZBrush moves its layers up. The new level is the Loop subdivision of the
// one below, and Loop's weights are linear, so a layer goes up as its displacement
// subdivided the same way: setting it to 0 on the new level gives what subdividing the
// surface without it gives. The level below keeps its shape with the layers gone from
// its list (baked, which moves nothing), and the recording goes up with them. Returns
// how many it moved.
@(private)
levels_carry_layers_up :: proc(l: ^Levels) -> int {
	n := len(l.levels)
	below, top := l.levels[n - 2], l.levels[n - 1]
	bs, ts := &below.sculptor, &top.sculptor
	// A slider still held on the level below ends here, so no step of it is left there
	// holding a layer that has gone.
	_ = sculptor_stroke_end(bs)
	for &layer in bs.layers.list {
		append(&ts.layers.list, layer_loop_up(l, below, top, layer))
		layer_destroy(&layer, bs.history.allocator)
	}
	moved := len(bs.layers.list)
	clear(&bs.layers.list)
	ts.layers.recording, bs.layers.recording = bs.layers.recording, 0
	ts.layers.named = bs.layers.named
	return moved
}

// A layer of `below` as a layer of `top`, the level Loop subdivision made from it.
@(private = "file")
layer_loop_up :: proc(l: ^Levels, below, top: ^Level, layer: Sculpt_Layer) -> Sculpt_Layer {
	Work :: struct {
		below, top: ^Level,
		owner:      []u32,
		from:       Sculpt_Layer,
		out:        [][]Vec3,
		ids:        [dynamic]u32,
		// Under a Catmull-Clark rule, the layer's displacement of every vertex below as
		// one array, which frame_cc's origin carries up as it does positions: the rules
		// are linear in the points, the weights coming from the topology and creases.
		cc:         Loop_Base,
	}
	w := Work{below = below, top = top, from = layer}
	if p := &below.polys; l.rule != .Loop && p.first != nil {
		flat := make([]Vec3, len(below.mesh.positions), context.temp_allocator)
		for d, id in layer.delta do if d != nil do copy(flat[below.sculptor.nodes[id].vert_first:], d)
		w.cc = {flat, below.mesh.indices[:], below.sculptor.faces, p, p.tri_poly, &below.sharp, l.rule}
	}
	ts := &top.sculptor
	out := Sculpt_Layer{name = layer.name, strength = layer.strength, visible = layer.visible}
	out.delta = make([][]Vec3, len(ts.nodes), ts.history.allocator)
	w.out = out.delta
	// A node of the new level takes displacement only when a node below that its Loop
	// points read has some; allocated here, on the calling thread.
	w.ids = make([dynamic]u32, 0, len(ts.nodes), context.temp_allocator)
	verts: u32
	for id in 0 ..< u32(len(ts.nodes)) {
		for c in node_list(top.deps, id) {
			if layer.delta[c] == nil do continue
			w.out[id] = make([]Vec3, ts.nodes[id].vert_count, ts.history.allocator)
			append(&w.ids, id)
			verts += ts.nodes[id].vert_count
			break
		}
	}
	jobs.parallel_for(l.pool if verts >= PARALLEL_MIN_VERTS else nil, len(w.ids), &w, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		at :: #force_inline proc(below: ^Level, layer: Sculpt_Layer, v: u32) -> Vec3 {
			id := below.node_of_vertex[v]
			d := layer.delta[id]
			return d[v - below.sculptor.nodes[id].vert_first] if d != nil else {}
		}
		id := w.ids[i]
		n := w.top.sculptor.nodes[id]
		for u in n.vert_first ..< n.vert_first + n.vert_count {
			par := w.top.parents[u]
			d: Vec3
			if w.cc.polys != nil {
				d = frame_cc(&w.cc, par).origin
			} else if par[2] == EVEN {
				// frame_at's origin, over the displacement instead of the positions.
				v := par[0]
				ring: Vec3
				faces := geom.vertex_faces_of(w.below.sculptor.faces, v)
				for f in faces {
					o1, o2 := others(w.below.mesh.indices[:], f, v)
					ring += at(w.below, w.from, o1) + at(w.below, w.from, o2)
				}
				beta := loop_beta(len(faces))
				d = at(w.below, w.from, v) * (1 - f32(len(faces)) * beta) + ring * (0.5 * beta)
			} else {
				d = (at(w.below, w.from, par[0]) + at(w.below, w.from, par[1])) * 0.375 + (at(w.below, w.from, par[2]) + at(w.below, w.from, par[3])) * 0.125
			}
			w.out[id][u - n.vert_first] = d
		}
	})
	return out
}
