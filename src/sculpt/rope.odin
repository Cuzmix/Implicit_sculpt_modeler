package sculpt

import "core:math"
import "core:math/linalg"

import "../geom"

// A curve as a rope: the Curve tool's points dragged with Physics on, as ZBrush's curves
// pull like a rope and Blender's rope simulations hang from what holds them. The curve is
// sampled into a chain of particles a radius apart; the press holds one of them at the
// pointer, the rest falls by the object's gravity and follows, every link keeping its
// length, a light bend link across each pair keeping it from folding sharp, onto the floor
// and the other objects (Cloth_Collisions), and the chain's own far parts kept two radii
// apart as capsules, so a loop pulled tight lies over itself and knots. After each step the
// curve's points go where the chain carries them, handles along its tangent. The chain is
// small (at most ROPE_MAX particles) and stepped serially, so it is the same everywhere.

ROPE_MAX :: 256
ROPE_MIN :: 16
// Constraint rounds a step and the bend links' strength.
ROPE_ROUNDS :: 12
ROPE_BEND :: f32(0.1)
// The share of its velocity the chain loses a step, and how far it falls a step at full
// gravity, in links (as Settle's).
ROPE_DAMPING :: f32(0.06)
ROPE_GRAVITY :: f32(0.15)

Rope :: struct {
	pos, prev: [dynamic]Vec3,
	at:        [dynamic]f32, // each particle's place on the curve (segment index + parameter) as it began
	link:      f32, // the rest length between neighbours
	radius:    f32, // how thick the rope is, for its self collision
	closed:    bool,
	end_at:    f32, // the curve's last place: its segment count
	held:      int, // the particle the press holds, or -1
	steps:     int,
}

// Samples the curve `points` into a chain held at its place `u` (segment index plus the
// parameter within it). `radius` is the rope's thickness for self collision; 0 takes the
// points' own.
rope_begin :: proc(r: ^Rope, points: []geom.Bezier_Point, closed: bool, u: f32, radius: f32 = 0) -> bool {
	rope_end(r)
	segs := geom.bezier_segments(len(points), closed)
	if segs == 0 do return false
	length := geom.bezier_length(points, closed)
	if length <= 0 do return false
	thick := radius
	if thick <= 0 {
		for p in points do thick += p.radius
		thick /= f32(len(points))
	}
	// A particle every radius or so, within the chain's limits.
	n := clamp(int(length / max(thick, length / ROPE_MAX)), ROPE_MIN, ROPE_MAX)
	samples := geom.bezier_sample(points, closed, length / f32(n), context.temp_allocator)
	if len(samples) < 3 do return false
	r.closed = closed
	r.end_at = f32(segs)
	r.radius = max(thick, 1e-6)
	r.held = -1
	best := f32(math.F32_MAX)
	for s, i in samples {
		append(&r.pos, s.p)
		append(&r.prev, s.p)
		append(&r.at, s.u)
		if d := abs(s.u - u); d < best do best, r.held = d, i
	}
	total: f32
	for i in 0 ..< rope_links(r) do total += linalg.length(r.pos[(i + 1) % len(r.pos)] - r.pos[i])
	r.link = total / f32(rope_links(r))
	return true
}

rope_end :: proc(r: ^Rope) {
	delete(r.pos)
	delete(r.prev)
	delete(r.at)
	r^ = {}
}

@(private = "file")
rope_links :: proc(r: ^Rope) -> int {
	return len(r.pos) if r.closed else len(r.pos) - 1
}

// One step: the held particle at `target`, the others falling `down` by `gravity` (0 to 1)
// and following, colliding as `with` says. Returns the largest move a free particle made,
// in links.
rope_step :: proc(r: ^Rope, target: Vec3, down: Vec3, gravity: f32, with: ^Cloth_Collisions = nil) -> f32 {
	n := len(r.pos)
	if n == 0 do return 0
	r.steps += 1
	fall := linalg.normalize0(down) * r.link * ROPE_GRAVITY * clamp(gravity, 0, 1)
	before := make([]Vec3, n, context.temp_allocator)
	copy(before, r.pos[:])
	for i in 0 ..< n {
		p := r.pos[i]
		v := (p - r.prev[i]) * (1 - ROPE_DAMPING)
		r.prev[i] = p
		r.pos[i] = p + v + fall
	}
	if r.held >= 0 do r.pos[r.held] = target
	links := rope_links(r)
	for round in 0 ..< ROPE_ROUNDS {
		for i in 0 ..< links do rope_keep(r, i, (i + 1) % n, r.link, 1)
		for i in 0 ..< n {
			j := i + 2
			if j >= n && !r.closed do break
			rope_keep(r, i, j % n, 2 * r.link, ROPE_BEND)
		}
		// The pairs are many, the crossings few and slow: every third round finds them
		// (and once more after the links are put back, below).
		if round % 3 == 2 do rope_self(r)
		if with != nil do rope_collide(r, with)
		if r.held >= 0 do r.pos[r.held] = target
	}
	// A long chain's rounds leave it stretched under its own weight: each link is put back
	// to its length out from the held particle (follow the leader), so a rope never
	// stretches, then what that moved into the floor or an object comes out again.
	// What that put back is no motion of the rope's: its velocity keeps out of it.
	ruled := make([]Vec3, n, context.temp_allocator)
	copy(ruled, r.pos[:])
	rope_follow(r)
	for i in 0 ..< n do r.prev[i] += r.pos[i] - ruled[i]
	rope_self(r)
	if with != nil do rope_collide(r, with)
	most: f32
	for i in 0 ..< n do if i != r.held do most = max(most, linalg.length(r.pos[i] - before[i]))
	return most / max(r.link, 1e-12)
}

// Follow the leader: from the held particle outward each way (from the first, with none
// held), each particle is put a link from the one before it along the way it lies. A
// closed rope is walked each way half round.
@(private = "file")
rope_follow :: proc(r: ^Rope) {
	n := len(r.pos)
	from := max(r.held, 0)
	reach := n / 2 if r.closed else n
	for dir in ([2]int{1, -1}) {
		prev := from
		for k in 1 ..< reach {
			i := from + dir * k
			if r.closed do i = ((i % n) + n) % n
			else if i < 0 || i >= n do break
			d := r.pos[i] - r.pos[prev]
			if l := linalg.length(d); l > 1e-12 do r.pos[i] = r.pos[prev] + d * (r.link / l)
			prev = i
		}
	}
}

// Moves particles `i` and `j` toward `rest` apart by `stiff` of the error, each half (the
// held one not at all, the other then all of it).
@(private = "file")
rope_keep :: proc(r: ^Rope, i, j: int, rest, stiff: f32) {
	d := r.pos[j] - r.pos[i]
	l := linalg.length(d)
	if l < 1e-12 do return
	fix := d * ((l - rest) / l * stiff)
	wi: f32 = 0 if i == r.held else 1
	wj: f32 = 0 if j == r.held else 1
	if wi + wj == 0 do return
	r.pos[i] += fix * (wi / (wi + wj))
	r.pos[j] -= fix * (wj / (wi + wj))
}

// Keeps every two links that are not neighbours two radii apart, as capsules: their
// nearest points are pushed apart along the line between them, each link's two ends by
// where on it the nearest point lies.
@(private = "file")
rope_self :: proc(r: ^Rope) {
	n := len(r.pos)
	links := rope_links(r)
	reach := 2 * r.radius
	// Links nearer along the rope than its thickness touch as a bend, not a crossing.
	skip := int(math.ceil(reach / max(r.link, 1e-12))) + 1
	for a in 0 ..< links {
		a1 := (a + 1) % n
		for b in a + skip + 1 ..< links {
			b1 := (b + 1) % n
			// So do those near across a closed rope's seam.
			if r.closed && links - (b - a) <= skip do continue
			sa, sb := rope_nearest(r.pos[a], r.pos[a1], r.pos[b], r.pos[b1])
			pa := linalg.lerp(r.pos[a], r.pos[a1], sa)
			pb := linalg.lerp(r.pos[b], r.pos[b1], sb)
			d := pb - pa
			l := linalg.length(d)
			if l >= reach || l < 1e-12 do continue
			push := d * ((reach - l) / l * 0.5)
			rope_nudge(r, a, 1 - sa, -push)
			rope_nudge(r, a1, sa, -push)
			rope_nudge(r, b, 1 - sb, push)
			rope_nudge(r, b1, sb, push)
		}
	}
}

@(private = "file")
rope_nudge :: #force_inline proc(r: ^Rope, i: int, share: f32, by: Vec3) {
	if i != r.held do r.pos[i] += by * share
}

// The parameters (0 to 1) of the nearest points of segments p0-p1 and q0-q1.
@(private)
rope_nearest :: proc(p0, p1, q0, q1: Vec3) -> (s, t: f32) {
	d1, d2, w := p1 - p0, q1 - q0, p0 - q0
	a, e := linalg.dot(d1, d1), linalg.dot(d2, d2)
	b, c, f := linalg.dot(d1, d2), linalg.dot(d1, w), linalg.dot(d2, w)
	den := a * e - b * b
	s = clamp((b * f - c * e) / den, 0, 1) if den > 1e-12 else 0
	t = clamp((b * s + f) / e, 0, 1) if e > 1e-12 else 0
	s = clamp((b * t - c) / a, 0, 1) if a > 1e-12 else 0
	return
}

// Pushes the free particles out of the floor and the other objects, a radius off them.
@(private = "file")
rope_collide :: proc(r: ^Rope, with: ^Cloth_Collisions) {
	for &p, i in r.pos {
		if i == r.held do continue
		if with.floor {
			if d := linalg.dot(p - with.floor_at, with.floor_up) - r.radius; d < 0 do p -= with.floor_up * d
		}
		for &o in with.colliders {
			x := o.to_volume * [4]f32{p.x, p.y, p.z, 1}
			d, grad := cloth_volume_sample(o.volume, x.xyz)
			d *= o.scale
			if d >= r.radius || grad == {} do continue
			t := o.to_volume
			linear := matrix[3, 3]f32{t[0, 0], t[0, 1], t[0, 2], t[1, 0], t[1, 1], t[1, 2], t[2, 0], t[2, 1], t[2, 2]}
			p += linalg.normalize0(linalg.transpose(linear) * grad) * (r.radius - d)
		}
	}
}

// Puts each of the curve's points where the chain now carries its place on the curve, its
// handles along the chain there a third of the way to its neighbours, as a fitted curve's.
rope_to_curve :: proc(r: ^Rope, points: []geom.Bezier_Point, closed: bool) {
	n := len(r.pos)
	if n < 2 do return
	for &pt, k in points {
		p, tangent := rope_at(r, f32(k))
		pt.p = p
		prev := k - 1 if k > 0 else (len(points) - 1 if closed else -1)
		next := k + 1 if k < len(points) - 1 else (0 if closed else -1)
		in_len, out_len: f32
		if prev >= 0 do in_len = linalg.length(rope_point(r, f32(prev)) - p) / 3
		if next >= 0 do out_len = linalg.length(rope_point(r, f32(next)) - p) / 3
		pt.h_in = -tangent * in_len
		pt.h_out = tangent * out_len
	}
}

@(private = "file")
rope_point :: proc(r: ^Rope, u: f32) -> Vec3 {
	p, _ := rope_at(r, u)
	return p
}

// Where the chain carries the curve's place `u`, and the chain's way there.
@(private = "file")
rope_at :: proc(r: ^Rope, u: f32) -> (p, tangent: Vec3) {
	n := len(r.pos)
	links := rope_links(r)
	// The link whose ends' places straddle u; a closed rope's last link runs to the end
	// of the curve, its far end's place one segment count on.
	for i in 0 ..< links {
		j := (i + 1) % n
		a, b := r.at[i], r.at[j]
		if j == 0 do b = r.end_at
		if u >= a && u <= b || i == links - 1 {
			t := clamp((u - a) / max(b - a, 1e-12), 0, 1)
			p = linalg.lerp(r.pos[i], r.pos[j], t)
			tangent = linalg.normalize0(r.pos[j] - r.pos[i])
			return
		}
	}
	return r.pos[0], {}
}
