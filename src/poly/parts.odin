package poly

import "core:math"
import "core:math/linalg"

// Parts: Align parts, as Shapr3D's Align (one piece of the cage joined face to face with
// another, then turned or flipped), and Spine, as 3D-Coat's Spine and Blender's extrude
// along a curve (faces extruded step by step along a path, turning with it). Both are
// pure procedures on the cage; the app finds the path and the faces.

Quat :: quaternion128

// The turn that takes direction `from` onto `to` by the shortest way; when they point
// opposite ways, half a turn about `axis` (which should be square to both).
turn_between :: proc(from, to, axis: Vec3) -> Quat {
	a, b := linalg.normalize0(from), linalg.normalize0(to)
	if linalg.dot(a, b) < -0.9999 do return linalg.quaternion_angle_axis_f32(math.PI, linalg.normalize0(axis))
	return linalg.quaternion_between_two_vector3_f32(a, b)
}

// Moves the part (`part`'s faces and their points, rigidly) so that face `from`, one of
// its faces, lies on face `to` of another part: centre on centre, facing it (with `flip`,
// facing the same way, so the part passes through), and turned about the join so the
// edge `from` starts with runs along the nearest edge of `to`, `turn` edges further round.
// Returns false, changing nothing, when `to` is one of the part's faces.
align_part :: proc(m: ^Mesh, part: []u32, from, to: u32, flip: bool, turn: int) -> bool {
	for f in part do if f == to do return false
	ca, cb := face_center(m, from), face_center(m, to)
	q := align_turn(face_normal(m, from), face_ways(m, from, context.temp_allocator)[0], face_normal(m, to), face_ways(m, to, context.temp_allocator), flip, turn)
	for v in face_set_verts(m, part, context.temp_allocator) {
		m.positions[v] = cb + linalg.quaternion_mul_vector3(q, m.positions[v] - ca)
	}
	return true
}

// The way along each of face f's edges, in order from its first.
face_ways :: proc(m: ^Mesh, f: u32, allocator := context.allocator) -> []Vec3 {
	ways := make([dynamic]Vec3, allocator)
	w := face_walk(m, f)
	for h in face_walk_next(&w) do append(&ways, m.positions[he_tip(m, h)] - m.positions[m.he_vert[h]])
	return ways[:]
}

// The turn Align parts gives a face (normal `from_normal`, an edge along `from_way`) to
// lie on another (normal `to_normal`, edges along `to_ways` in order): its normal against
// the other's (with `flip`, along it), then about that so its edge runs along the nearest
// of the other's edges, `turn` edges further round. The vectors may be in any space, so
// long as all are in the same one.
align_turn :: proc(from_normal, from_way, to_normal: Vec3, to_ways: []Vec3, flip: bool, turn: int) -> Quat {
	ta := linalg.normalize0(from_way)
	want := to_normal if flip else -to_normal
	// Square onto the join first, then round it to the nearest of the other's edges.
	q1 := turn_between(from_normal, want, ta)
	t := linalg.quaternion_mul_vector3(q1, ta)
	t = linalg.normalize0(t - want * linalg.dot(t, want))
	if len(to_ways) == 0 do return q1
	nearest, best := 0, f32(-2)
	for e, i in to_ways {
		if c := linalg.dot(t, linalg.normalize0(e - want * linalg.dot(e, want))); c > best do nearest, best = i, c
	}
	n := len(to_ways)
	goal := to_ways[((nearest + turn) % n + n) % n]
	goal = linalg.normalize0(goal - want * linalg.dot(goal, want))
	return turn_between(t, goal, want) * q1
}

// One step of a spine: where the faces' points go, from where they were. Each point p goes
// to at + turn (scale (p - from)).
Spine_Step :: struct {
	from, at: Vec3,
	turn:     Quat,
	scale:    f32,
}

spine_point :: proc(s: Spine_Step, p: Vec3) -> Vec3 {
	return s.at + linalg.quaternion_mul_vector3(s.turn, (p - s.from) * s.scale)
}

// The steps of a spine from faces centred at `center` with normal `normal` along `path`
// (object space, from the faces' centre), each about `step` long, the faces' size at each
// step by `scale` (one per path point, a share of the size they have; nil keeps it). The faces turn with the path, each
// step by the least turn from the one before, so the spine does not twist; the first
// step leaves the faces square to the way the path first goes, the rest follow it.
spine_steps :: proc(path: []Vec3, scale: []f32, center, normal: Vec3, step: f32, allocator := context.allocator) -> []Spine_Step {
	if len(path) < 2 || step <= 0 do return nil
	// The path's length at each of its points.
	run := make([]f32, len(path), context.temp_allocator)
	for i in 1 ..< len(path) do run[i] = run[i - 1] + linalg.length(path[i] - path[i - 1])
	total := run[len(path) - 1]
	if total <= 0 do return nil
	count := clamp(int(math.round(total / step)), 1, SPINE_STEPS_MAX)
	// The path at even lengths, and the scale there.
	at := make([]Vec3, count + 1, context.temp_allocator)
	size := make([]f32, count + 1, context.temp_allocator)
	j := 0
	for k in 0 ..= count {
		want := total * f32(k) / f32(count)
		for j < len(path) - 2 && run[j + 1] < want do j += 1
		span := run[j + 1] - run[j]
		u := clamp((want - run[j]) / span, 0, 1) if span > 0 else 0
		at[k] = linalg.lerp(path[j], path[j + 1], u)
		size[k] = 1
		if scale != nil do size[k] = linalg.lerp(scale[j], scale[j + 1], u)
	}
	steps := make([]Spine_Step, count, allocator)
	turn := Quat(1)
	way := linalg.normalize0(normal)
	for k in 1 ..= count {
		// The way on at this point: along the path, the last step's way at the end.
		next := at[k + 1] - at[k - 1] if k < count else at[k] - at[k - 1]
		if linalg.length2(next) > 1e-20 {
			n := linalg.normalize(next)
			turn = turn_between(way, n, linalg.vector3_orthogonal(way)) * turn
			way = n
		}
		steps[k - 1] = {from = center, at = center + (at[k] - at[0]), turn = turn, scale = max(size[k], SPINE_SCALE_MIN)}
	}
	return steps
}

// Step s seen in the mirror that flips the axes `sign` gives -1: where it puts each
// point's image is the image of where s puts the point.
spine_step_mirror :: proc(s: Spine_Step, sign: Vec3) -> Spine_Step {
	// A turn's axis seen in a mirror is the mirrored axis, reversed when the mirror flips
	// an odd number of axes; its angle stays.
	odd := (sign.x < 0) != (sign.y < 0) != (sign.z < 0)
	v := Vec3{imag(s.turn), jmag(s.turn), kmag(s.turn)} * sign
	if odd do v = -v
	return {from = s.from * sign, at = s.at * sign, turn = quaternion(w = real(s.turn), x = v.x, y = v.y, z = v.z), scale = s.scale}
}

// A spine's most steps, and its faces' least size, a share of what they were.
SPINE_STEPS_MAX :: 200
SPINE_SCALE_MIN :: f32(0.05)

// A circular arc from `center` leaving along `normal` and ending at `end`, as `count`
// points after the first (the first is `center`): Spine's Alt. Where the end lies
// straight ahead, a line.
spine_arc :: proc(center, normal, end: Vec3, count: int, allocator := context.allocator) -> []Vec3 {
	n := linalg.normalize0(normal)
	d := end - center
	side := d - n * linalg.dot(d, n)
	out := make([]Vec3, count + 1, allocator)
	out[0] = center
	if linalg.length(side) < 1e-6 * max(linalg.length(d), 1e-12) {
		for k in 1 ..= count do out[k] = center + d * f32(k) / f32(count)
		return out
	}
	u := linalg.normalize(side)
	// The circle through the centre tangent to n, whose middle is r along u.
	r := linalg.dot(d, d) / (2 * linalg.dot(d, u))
	mid := center + u * r
	from := center - mid
	to := end - mid
	axis := linalg.normalize(linalg.cross(from, n))
	// The angle swept, the way n points, up to all but a sliver of the circle.
	angle := math.atan2(linalg.dot(linalg.cross(from, to), axis), linalg.dot(from, to))
	if angle < 0 do angle += 2 * math.PI
	for k in 1 ..= count {
		q := linalg.quaternion_angle_axis_f32(angle * f32(k) / f32(count), axis)
		out[k] = mid + linalg.quaternion_mul_vector3(q, from)
	}
	return out
}

// Spine: every region (a list of faces; the regions apart) is extruded once per step,
// the new faces' points put where step k of that region's list says (by where the
// region's points were at the start), so the regions grow along their paths as a run of
// rings. The regions' lists are equally long. Returns the regions' faces at the end, new
// ids; the cage is as it was when refused.
spine_faces :: proc(m: ^Mesh, regions: [][]u32, steps: [][]Spine_Step, allocator := context.allocator) -> (ends: []u32, err: Build_Error) {
	if len(regions) == 0 || len(steps) != len(regions) do return nil, .None
	count := len(steps[0])
	for s in steps do if len(s) != count do return nil, .None
	// A refusal part way puts the cage back as it was, in its own memory.
	home := m.positions.allocator
	kept := mesh_clone(m^, context.temp_allocator)
	defer if err != .None {
		mesh_destroy(m)
		m^ = mesh_clone(kept, home)
	}
	// Each region's points, where they started, and the id each has now.
	Point :: struct {
		region: int,
		start:  Vec3,
		now:    u32,
	}
	points := make([dynamic]Point, context.temp_allocator)
	faces := make([dynamic]u32, context.temp_allocator)
	owner := make(map[u32]int, allocator = context.temp_allocator)
	for r, i in regions {
		for v in face_set_verts(m, r, context.temp_allocator) {
			if _, twice := owner[v]; twice do return nil, .Unsupported
			owner[v] = i
			append(&points, Point{region = i, start = m.positions[v], now = v})
		}
		append(&faces, ..r)
	}
	for k in 0 ..< count {
		ring: Face_Ring
		ring, _ = extrude_faces(m, faces[:], false, false, context.temp_allocator) or_return
		// Old ids to new, then each point to its copy, which the step places.
		copy_of := make(map[u32]u32, allocator = context.temp_allocator)
		for c in ring.copies do copy_of[c[1]] = c[0]
		for &p in points {
			p.now = copy_of[ring.edit.vert[p.now]]
			m.positions[p.now] = spine_point(steps[p.region][k], p.start)
		}
		clear(&faces)
		append(&faces, ..ring.faces)
	}
	return clone_u32(faces[:], allocator), .None
}

@(private = "file")
clone_u32 :: proc(s: []u32, allocator := context.allocator) -> []u32 {
	out := make([]u32, len(s), allocator)
	copy(out, s)
	return out
}

// The faces of `faces` mirrored by `sign` (each axis 1 or -1): each face's image is the
// face on the images of its corners, found by position within `slack`. Returns false
// when some face has none.
mirror_faces_by :: proc(m: ^Mesh, faces: []u32, sign: Vec3, slack: f32, allocator := context.allocator) -> (out: []u32, ok: bool) {
	g := point_grid_make(m, slack * 4)
	result := make([dynamic]u32, allocator)
	for f in faces {
		h := m.face_he[f]
		a := nearest_point(m, &g, m.positions[m.he_vert[h]] * sign, slack)
		b := nearest_point(m, &g, m.positions[he_tip(m, h)] * sign, slack)
		if a == NONE || b == NONE {
			delete(result)
			return nil, false
		}
		// A mirror turns faces over: the image runs b to a, unless the sign keeps them.
		odd := (sign.x < 0) != (sign.y < 0) != (sign.z < 0)
		img := find_half_edge(m, b, a) if odd else find_half_edge(m, a, b)
		if img == NONE || m.he_face[img] == NONE {
			delete(result)
			return nil, false
		}
		append(&result, m.he_face[img])
	}
	return result[:], true
}
