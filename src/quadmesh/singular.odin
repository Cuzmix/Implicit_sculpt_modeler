package quadmesh

import "base:runtime"
import "core:math"
import "core:slice"

// The frame field's singular vertices and their clean-up, the rules of
// AutoRemesher's SingularitySimplifier (MIT, by Jeremy Hu). A vertex is singular when the
// frames' quarter turns across the edges round it do not add up to whole turns; its charge
// is that sum's remainder, and two singular vertices whose charges add up to whole turns
// cancel each other out when the frames between them turn a quarter more along a path
// from one to the other. Pairs at most MAX_PAIR_HOPS triangles apart are tried nearest
// first: the frames of the triangles near both (those with no sharp, feature or border
// edge) are relaxed toward their neighbours with that turn carried along the path, and the
// change is kept only when both vertices come out regular and no new singular vertex
// appears near them. Where AutoRemesher works over the whole mesh for every pair it tries (its
// charges, its regions' marks), this works over the pair's region alone, so the clean-up
// costs what its pairs reach, whatever the mesh's size.

// The farthest apart (triangle steps) two singular vertices are tried as a pair, the
// rounds of trying, and how far round the pair the relaxed region reaches.
@(private = "file")
MAX_PAIR_HOPS :: 6
@(private = "file")
MAX_ROUNDS :: 4
@(private = "file")
REGION_MARGIN :: 6
// The most two singular vertices' sizes may differ in the log (about 16 %) for the pair to
// be tried, when the field was solved in a scaled metric: a pair across a change of size
// is what the change needs (odin_field gives the measures).
@(private = "file")
PAIR_SCALE_SPREAD :: 0.15

@(private = "file")
Simplifier :: struct {
	s:              ^Surface,
	angles:         []f64, // per triangle: the frame's angle in its basis
	mismatch:       []u8, // per corner: the quarter turns between the frames across its edge, 0 to 3
	sharp:          []bool, // per corner: a singular vertex never moves across its edge
	jump:           []i32, // per corner: the quarter turns the relaxing keeps across its edge
	length:         []f64, // per corner: its edge's length, the relaxing's weight
	stamp:          u32, // the pair being tried; a mark equal to it is set for this pair
	in_a, in_b:     []u32, // per triangle: near the pair's first vertex, and its second
	in_region:      []u32,
	is_free:        []u32,
	depth:          []u32, // per triangle: its steps from the vertex it is near
	visited:        []u32, // per vertex
	previous:       []u32,
	affected:       []u32,
	ball, region:   [dynamic]u32,
	free, queue:    [dynamic]u32,
	path, fan:      [dynamic]u32,
	saved:          [dynamic]f64,
}

@(private = "file")
Candidate :: struct {
	a, b, hops: int, // the two singular vertices' places in the round's list, a before b
}

// The field's singular vertices before and after the clean-up, which `simplify` runs; the
// angles are those it leaves. With `log_scale` (per vertex, the field's metric's size in
// the log) a pair is tried only between vertices of about one size (PAIR_SCALE_SPREAD).
@(private)
singular_simplify :: proc(s: ^Surface, angles: []f64, sharp_degrees: f64, features: []u8, simplify: bool, log_scale: []f64 = nil) -> (before, after: int) {
	heap := runtime.heap_allocator()
	context.allocator = heap
	faces, vertices, corners := len(s.triangles), len(s.positions), len(s.opp)
	x := Simplifier {
		s        = s,
		angles   = angles,
		mismatch = make([]u8, corners),
	}
	defer delete(x.mismatch)
	for f in 0 ..< faces do update_mismatch(&x, f)
	before = 0
	for v in 0 ..< vertices do if charge(&x, u32(v)) != 0 do before += 1
	if !simplify || before < 2 do return before, before

	x.sharp = make([]bool, corners)
	x.jump = make([]i32, corners)
	x.length = make([]f64, corners)
	x.in_a = make([]u32, faces)
	x.in_b = make([]u32, faces)
	x.in_region = make([]u32, faces)
	x.is_free = make([]u32, faces)
	x.depth = make([]u32, faces)
	x.visited = make([]u32, vertices)
	x.previous = make([]u32, vertices)
	x.affected = make([]u32, vertices)
	defer {
		delete(x.sharp)
		delete(x.jump)
		delete(x.length)
		delete(x.in_a)
		delete(x.in_b)
		delete(x.in_region)
		delete(x.is_free)
		delete(x.depth)
		delete(x.visited)
		delete(x.previous)
		delete(x.affected)
		delete(x.ball)
		delete(x.region)
		delete(x.free)
		delete(x.queue)
		delete(x.path)
		delete(x.fan)
		delete(x.saved)
	}
	sharp := sharp_degrees * math.PI / 180
	for c in 0 ..< corners {
		x.length[c] = length3(surface_edge(s, u32(c)))
		if s.opp[c] == NONE do continue
		// A sharp edge either way round: AutoRemesher takes the signed angle, which is negative
		// on a convex crease, so a singular vertex could cross a cube's edge there though
		// the field locked the frames beside it.
		x.sharp[c] = abs(s.dihedral[c]) >= sharp || (features != nil && features[c] != 0)
	}

	charges := make([]u8, vertices)
	defer delete(charges)
	owner := make([]u32, faces)
	defer delete(owner)
	distance := make([]u32, faces)
	defer delete(distance)
	singular: [dynamic]u32
	defer delete(singular)
	encounters: [dynamic][2]int
	defer delete(encounters)
	candidates: [dynamic]Candidate
	defer delete(candidates)
	seen: map[u64]struct{}
	defer delete(seen)
	used: [dynamic]bool
	defer delete(used)
	queue: [dynamic]u32
	defer delete(queue)
	for _ in 0 ..< MAX_ROUNDS {
		clear(&singular)
		for v in 0 ..< vertices {
			charges[v] = charge(&x, u32(v))
			if charges[v] != 0 do append(&singular, u32(v))
		}
		if len(singular) < 2 do break
		// The triangles round each singular vertex, grown outward a step at a time: where
		// two growths meet, their vertices are a candidate pair that far apart.
		for &o in owner do o = NONE
		clear(&queue)
		clear(&encounters)
		clear(&candidates)
		clear(&seen)
		for v, i in singular {
			_ = surface_fan(s, v, &x.fan)
			for f in x.fan {
				if owner[f] == NONE {
					owner[f] = u32(i)
					distance[f] = 0
					append(&queue, f)
				} else {
					append(&encounters, [2]int{int(owner[f]), i})
				}
			}
		}
		consider :: proc(candidates: ^[dynamic]Candidate, seen: ^map[u64]struct{}, charges: []u8, singular: []u32, log_scale: []f64, a, b, hops: int) {
			if a == b || hops > MAX_PAIR_HOPS || (int(charges[singular[a]]) + int(charges[singular[b]])) % 4 != 0 do return
			if log_scale != nil && abs(log_scale[singular[a]] - log_scale[singular[b]]) > PAIR_SCALE_SPREAD do return
			lo, hi := min(a, b), max(a, b)
			key := u64(lo) << 32 | u64(hi)
			if key in seen do return
			seen[key] = {}
			append(candidates, Candidate{lo, hi, hops})
		}
		for e in encounters do consider(&candidates, &seen, charges, singular[:], log_scale, e[0], e[1], 0)
		for head := 0; head < len(queue); head += 1 {
			f := queue[head]
			for c in 3 * f ..< 3 * f + 3 {
				o := s.opp[c]
				if o == NONE do continue
				g := o / 3
				if owner[g] == NONE {
					if distance[f] + 1 > MAX_PAIR_HOPS do continue
					owner[g] = owner[f]
					distance[g] = distance[f] + 1
					append(&queue, g)
				} else {
					consider(&candidates, &seen, charges, singular[:], log_scale, int(owner[f]), int(owner[g]), int(distance[f] + distance[g]))
				}
			}
		}
		slice.stable_sort_by(candidates[:], proc(p, q: Candidate) -> bool {return p.hops < q.hops})
		resize(&used, len(singular))
		for &u in used do u = false
		cancelled := 0
		for c in candidates {
			if used[c.a] || used[c.b] do continue
			if cancel_pair(&x, singular[c.a], singular[c.b], c.hops) {
				used[c.a], used[c.b] = true, true
				cancelled += 1
			}
		}
		if cancelled == 0 do break
	}
	after = 0
	for v in 0 ..< vertices do if charge(&x, u32(v)) != 0 do after += 1
	return before, after
}

// The quarter turns across triangle f's edges, set on both sides of each.
@(private = "file")
update_mismatch :: proc(x: ^Simplifier, f: int) {
	s := x.s
	for c in 3 * f ..< 3 * f + 3 {
		o := s.opp[c]
		if o == NONE do continue
		g := int(o) / 3
		turns := i64(math.round((x.angles[g] - (x.angles[f] + s.connection[c])) / (math.PI / 2)))
		m := u8(((turns % 4) + 4) % 4)
		x.mismatch[c] = m
		x.mismatch[o] = (4 - m) % 4
	}
}

// Vertex v's charge: the quarter turns round it, 0 to 3; 0 on the border or where its fan
// does not close.
@(private = "file")
charge :: proc(x: ^Simplifier, v: u32) -> u8 {
	s := x.s
	if s.first[v] == s.first[v + 1] do return 0
	start := s.corners[s.first[v]]
	c := start
	sum := 0
	for steps := 1;; steps += 1 {
		if steps > len(s.opp) do return 0
		sum += int(x.mismatch[c])
		o := s.opp[c]
		if o == NONE do return 0
		c = corner_next(o)
		if surface_vertex(s, c) != v do return 0
		if c == start do return u8(sum % 4)
	}
}

// The triangles at most `radius` steps from `seeds`, marked in `mark` and listed in x.ball.
@(private = "file")
grow_ball :: proc(x: ^Simplifier, seeds: []u32, mark: []u32, radius: u32) {
	s := x.s
	clear(&x.ball)
	for f in seeds do if mark[f] != x.stamp {
		mark[f] = x.stamp
		x.depth[f] = 0
		append(&x.ball, f)
	}
	for head := 0; head < len(x.ball); head += 1 {
		f := x.ball[head]
		if x.depth[f] >= radius do continue
		for c in 3 * f ..< 3 * f + 3 {
			o := s.opp[c]
			if o == NONE do continue
			g := o / 3
			if mark[g] != x.stamp {
				mark[g] = x.stamp
				x.depth[g] = x.depth[f] + 1
				append(&x.ball, g)
			}
		}
	}
}

// Whether vertex v's fan closes inside the pair's region.
@(private = "file")
usable :: proc(x: ^Simplifier, v: u32) -> bool {
	if !surface_fan(x.s, v, &x.fan) do return false
	for f in x.fan do if x.in_region[f] != x.stamp do return false
	return true
}

// A path of edges from `first` to `second` between free triangles, through vertices whose
// fans lie in the region, the fewest edges long (pathBetween); in x.path, empty for none.
@(private = "file")
path_between :: proc(x: ^Simplifier, first, second: u32) {
	s := x.s
	clear(&x.path)
	clear(&x.queue)
	x.visited[first] = x.stamp
	x.previous[first] = first
	append(&x.queue, first)
	for head := 0; head < len(x.queue); head += 1 {
		v := x.queue[head]
		if v == second {
			for at := second; at != first; at = x.previous[at] do append(&x.path, at)
			append(&x.path, first)
			slice.reverse(x.path[:])
			return
		}
		for i in s.first[v] ..< s.first[v + 1] {
			c := s.corners[i]
			next := surface_vertex(s, corner_next(c))
			if x.visited[next] == x.stamp do continue
			o := s.opp[c]
			if o == NONE || x.is_free[c / 3] != x.stamp || x.is_free[o / 3] != x.stamp do continue
			if next != second && !usable(x, next) do continue
			x.visited[next] = x.stamp
			x.previous[next] = v
			append(&x.queue, next)
		}
	}
}

// The singular vertices among the region's.
@(private = "file")
singular_near :: proc(x: ^Simplifier) -> (n: int) {
	s := x.s
	for f in x.region do for v in s.triangles[f] do if x.affected[v] == x.stamp {
		x.affected[v] = 0
		if charge(x, v) != 0 do n += 1
	}
	for f in x.region do for v in s.triangles[f] do x.affected[v] = x.stamp
	return
}

// Tries to cancel the pair `first` and `second`, `hops` triangle steps apart (cancelPair):
// the free triangles near both relaxed toward their neighbours with a quarter turn more
// carried along a path between them, kept when both come out regular and no more singular
// vertices are left near them than two fewer than before.
@(private = "file")
cancel_pair :: proc(x: ^Simplifier, first, second: u32, hops: int) -> bool {
	s := x.s
	x.stamp += 1
	radius := u32(hops + REGION_MARGIN)
	if !surface_fan(s, first, &x.fan) do return false
	grow_ball(x, x.fan[:], x.in_a, radius)
	if !surface_fan(s, second, &x.fan) do return false
	grow_ball(x, x.fan[:], x.in_b, radius)
	// The region: the triangles near both, in order.
	clear(&x.region)
	for f in x.ball do if x.in_a[f] == x.stamp do append(&x.region, f)
	if len(x.region) == 0 do return false
	slice.sort(x.region[:])
	for f in x.region do x.in_region[f] = x.stamp
	// A region triangle is free unless an edge of it is sharp, a border or the region's.
	clear(&x.free)
	for f in x.region {
		frozen := false
		for c in 3 * f ..< 3 * f + 3 {
			o := s.opp[c]
			if x.sharp[c] || o == NONE || x.in_region[o / 3] != x.stamp {
				frozen = true
				break
			}
		}
		if !frozen {
			append(&x.free, f)
			x.is_free[f] = x.stamp
		}
	}
	if len(x.free) == 0 do return false
	pair := [2]u32{first, second}
	for v in pair {
		_ = surface_fan(s, v, &x.fan)
		for f in x.fan do if x.in_region[f] != x.stamp do return false
	}
	path_between(x, first, second)
	if len(x.path) < 2 do return false
	for f in x.region do for v in s.triangles[f] do x.affected[v] = x.stamp
	before := singular_near(x)
	clear(&x.saved)
	for f in x.free do append(&x.saved, x.angles[f])

	for f in x.region do for c in 3 * f ..< 3 * f + 3 {
		o := s.opp[c]
		if o == NONE do continue
		x.jump[c] = i32(math.round((x.angles[o / 3] - x.angles[f] - s.connection[c]) / (math.PI / 2)))
	}
	carried := i32((int(charge(x, first)) + 1) % 4 - 1)
	for i in 0 ..< len(x.path) - 1 {
		c := corner_along(s, x.path[i], x.path[i + 1])
		if c == NONE do return false
		x.jump[c] -= carried
		x.jump[s.opp[c]] += carried
	}
	// Each free triangle's angle set to its neighbours' mean across its edges, weighted by
	// the edges' lengths, sweeping until no angle moves.
	sweeps := max(256, 40 * int(radius) * int(radius))
	for _ in 0 ..< sweeps {
		most := f64(0)
		for f in x.free {
			sum, weight := f64(0), f64(0)
			for c in 3 * f ..< 3 * f + 3 {
				o := s.opp[c]
				if o == NONE do continue
				w := x.length[c]
				sum += w * (x.angles[o / 3] - s.connection[c] - f64(x.jump[c]) * (math.PI / 2))
				weight += w
			}
			if weight > 0 {
				value := sum / weight
				most = max(most, abs(value - x.angles[f]))
				x.angles[f] = value
			}
		}
		if most < 1e-10 do break
	}
	for f in x.region do update_mismatch(x, int(f))
	after := singular_near(x)
	if charge(x, first) != 0 || charge(x, second) != 0 || after + 2 > before {
		for f, i in x.free do x.angles[f] = x.saved[i]
		for f in x.region do update_mismatch(x, int(f))
		return false
	}
	return true
}

// The corner at `from` whose edge runs to `to` between two triangles, or NONE.
@(private = "file")
corner_along :: proc(s: ^Surface, from, to: u32) -> u32 {
	for i in s.first[from] ..< s.first[from + 1] {
		c := s.corners[i]
		if surface_vertex(s, corner_next(c)) == to && s.opp[c] != NONE do return c
	}
	return NONE
}
