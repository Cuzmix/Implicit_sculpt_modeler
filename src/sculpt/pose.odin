package sculpt

import "core:math"
import "core:math/linalg"

import "../jobs"

// Posing, as ZBrush's Gizmo 3D does when a mask is on: a move, turn or scale of the
// unmasked part, the soft edge of the mask bending between it and the masked rest. Each
// vertex takes the pose in proportion to how free it is (shield: unmasked and shown),
// so a half-masked vertex moves half as far, turns through half the angle (keeping its
// distance to the pivot, so a joint bends rather than pinches) or scales by half the
// change. A pose is one stroke: begun when the drag starts, set afresh from the
// positions it started from each frame, ended (an undo step) or cancelled (nothing) when
// the drag stops. The start positions are the ones the stroke saved for undo, so posing
// keeps no copy of its own. Not with dynamic topology, whose strokes save whole nodes.

Pose_Kind :: enum {
	Move,
	Turn,
	Scale,
	Deform, // a bend, twist or taper (deform.odin)
	Lattice, // a lattice point's move (lattice.odin), once sculptor_lattice_rest noted the places
}

// A pose in the mesh's own space.
Pose :: struct {
	kind:   Pose_Kind,
	pivot:  Vec3, // what turns and scales go about
	axis:   Vec3, // Turn: the unit axis through the pivot
	angle:  f32,  // Turn: radians, right-handed about the axis
	delta:  Vec3, // Move: the offset
	factor: f32,  // Scale: the factor for a free vertex
	deform: Deform, // Deform: which, along what and how much
	lattice: Lattice_Move, // Lattice: the point and its move
}

@(private)
Pose_State :: struct {
	active: bool,
	nodes:  []u32, // the nodes with a free vertex, in the order their positions were saved
	first:  int,   // where their saved positions start in the stroke's saved nodes
	moved:  int,   // free vertices, for the stats
}

@(private)
pose_free :: proc(s: ^Sculptor) {
	delete(s.pose.nodes)
	s.pose = {}
}

// Whether a pose is under way.
sculptor_posing :: proc(s: ^Sculptor) -> bool {return s.pose.active}

// How many vertices the pose under way (or the last one) moves.
sculptor_pose_moved :: proc(s: ^Sculptor) -> int {return s.pose.moved}

// Starts a pose of every free vertex, saving their nodes for undo. False, starting
// nothing, while a stroke is being recorded (ending it here would leave a step the app
// never listed), under dynamic topology, or when no vertex is free (all masked or hidden).
sculptor_pose_begin :: proc(s: ^Sculptor) -> bool {
	if s.history.recording || s.dyn != nil do return false
	pose_free(s)
	Find :: struct {
		s:    ^Sculptor,
		free: []u32, // per node: its free vertices
	}
	f := Find{s, make([]u32, len(s.nodes), context.temp_allocator)}
	jobs.parallel_ranges(s.pool, len(s.nodes), &f, proc(data: rawptr, lo, hi: int) {
		f := cast(^Find)data
		s := f.s
		for id in lo ..< hi {
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count do if shield(s.fade, s.mask, v) > 0 do f.free[id] += 1
		}
	}, NODE_GRAIN)
	count, moved := 0, 0
	for c in f.free {
		count += int(c > 0)
		moved += int(c)
	}
	if count == 0 do return false
	s.pose.nodes = make([]u32, count)
	at := 0
	for c, id in f.free {
		if c == 0 do continue
		s.pose.nodes[at] = u32(id)
		at += 1
	}
	sculptor_stroke_begin(s)
	s.pose.first = len(s.history.current.saved)
	clear(&s.hit)
	for id in s.pose.nodes do append(&s.hit, s.nodes[id].leaf)
	record_hit(s, false)
	s.pose.active, s.pose.moved = true, moved
	return true
}

// Sets every free vertex to `p` applied to where it started, by how free it is.
sculptor_pose_apply :: proc(s: ^Sculptor, p: Pose) {
	if !s.pose.active do return
	Apply :: struct {
		s:        ^Sculptor,
		p:        Pose,
		turn:     matrix[3, 3]f32, // the whole turn, for fully free vertices
		axis:     Vec3,
		deform:   Deform_Plan,
		lattice:  Lattice_Move,
	}
	job := Apply{s = s, p = p, axis = linalg.normalize0(p.axis), deform = deform_plan(p.deform), lattice = p.lattice}
	job.turn = linalg.matrix3_rotate_f32(p.angle, job.axis) if job.axis != {} else 1
	jobs.parallel_for(s.pool, len(s.pose.nodes), &job, proc(data: rawptr, i: int) {
		job := cast(^Apply)data
		s := job.s
		p := job.p
		n := s.nodes[s.pose.nodes[i]]
		start := s.history.current.saved[s.pose.first + i].positions
		positions := s.mesh.positions[n.vert_first:][:n.vert_count]
		for k in 0 ..< int(n.vert_count) {
			w := shield(s.fade, s.mask, n.vert_first + u32(k))
			a := start[k]
			if w <= 0 {
				positions[k] = a
				continue
			}
			switch p.kind {
			case .Move:
				positions[k] = a + w * p.delta
			case .Scale:
				positions[k] = p.pivot + (a - p.pivot) * (1 + w * (p.factor - 1))
			case .Turn:
				if job.axis == {} {
					positions[k] = a
				} else if w >= 1 {
					positions[k] = p.pivot + job.turn * (a - p.pivot)
				} else {
					positions[k] = p.pivot + turn_by(a - p.pivot, job.axis, w * p.angle)
				}
			case .Deform:
				positions[k] = deform_at(&job.deform, a, w)
			case .Lattice:
				place := s.lattice.place
				positions[k] = a if place == nil else a + (w * lattice_weight(&job.lattice, place[n.vert_first + u32(k)])) * job.lattice.offset
			}
		}
	})
	sculptor_nodes_moved(s, s.pose.nodes)
	for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
}

// `v` turned by `angle` radians about the unit `axis` (Rodrigues' formula).
@(private)
turn_by :: #force_inline proc(v, axis: Vec3, angle: f32) -> Vec3 {
	c, sn := math.cos(angle), math.sin(angle)
	return v * c + linalg.cross(axis, v) * sn + axis * linalg.dot(axis, v) * (1 - c)
}

// Ends the pose. Returns true when it moved something and became an undo step.
sculptor_pose_end :: proc(s: ^Sculptor) -> bool {
	if !s.pose.active do return false
	moved := s.pose.moved
	pose_free(s)
	s.pose.moved = moved
	return sculptor_stroke_end(s)
}

// Puts every vertex back where the pose began and ends it without an undo step.
sculptor_pose_cancel :: proc(s: ^Sculptor) {
	if !s.pose.active do return
	pose_free(s)
	// A pose saves positions only, of a mesh without dynamic topology, so it always
	// discards.
	ok := sculptor_stroke_discard(s)
	assert(ok)
}

// Where a pose of the mask's free part would bend: the middle of the mask's soft edge
// (the shown vertices partly masked), or with a hard edge the free vertices touching a
// masked one, or else the middle of the free part. ok is false when nothing is free.
sculptor_mask_centroid :: proc(s: ^Sculptor) -> (centre: Vec3, ok: bool) {
	if s.mask == nil do return
	// Per node, the sums of the three kinds, added in node order so the result is the
	// same however the work is split.
	Sums :: [3][4]f64
	Job :: struct {
		s:    ^Sculptor,
		sums: []Sums,
	}
	job := Job{s, make([]Sums, len(s.nodes), context.temp_allocator)}
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		m := s.mesh
		for id in lo ..< hi {
			n := s.nodes[id]
			sums := &job.sums[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if vertex_hidden(s, v) do continue
				k := s.mask[v]
				if k == 255 do continue
				kind := 2
				if k > 0 {
					kind = 0
				} else {
					touching := false
					for f in faces_of(s, v) {
						for c in 0 ..< u32(3) do touching ||= s.mask[m.indices[3 * f + c]] == 255
					}
					if touching do kind = 1
				}
				p := m.positions[v]
				sums[kind] += {f64(p.x), f64(p.y), f64(p.z), 1}
			}
		}
	}, NODE_GRAIN)
	total: Sums
	for sums in job.sums do for t, kind in sums do total[kind] += t
	for t in total {
		if t[3] == 0 do continue
		return {f32(t[0] / t[3]), f32(t[1] / t[3]), f32(t[2] / t[3])}, true
	}
	return
}
