package sculpt

import "../jobs"

// A lattice (free-form deformation, as Sederberg and Parry gave it): a box of points
// round the free part, `points` a side; moving a point moves each vertex by that point's
// Bernstein weight at the vertex times the point's move. It is linear in the points'
// moves, so every drag of a point can be a pose of its own from where the last one left
// the surface, as long as each weighs the vertices by where they were in the box when
// the lattice was made, not by where they are now: the sculptor keeps that place, 12
// bytes a vertex while a lattice is shown, and the drags then add up exactly to one
// deformation by all the points' moves, which is what the drawn cage shows.

// More points a side would crowd the cage under a finger, and the higher degree would
// make each point's pull too local to read as a lattice.
LATTICE_MAX_POINTS :: 4

// One point's move.
Lattice_Move :: struct {
	points: int,    // a side, 2 to LATTICE_MAX_POINTS
	point:  [3]int, // which, 0 ..< points along x, y and z
	offset: Vec3,   // its move, in the mesh's own space
}

@(private)
Lattice_Rest :: struct {
	place: []Vec3, // per vertex: where it was in the box when the lattice was made, 0 to 1 inside
}

// Notes where every vertex is in the box from `lo` to `hi`, for the lattice drags that
// follow; a lattice made again starts from the surface as it is then.
sculptor_lattice_rest :: proc(s: ^Sculptor, lo, hi: Vec3) {
	sculptor_lattice_clear(s)
	s.lattice.place = make([]Vec3, len(s.mesh.positions), s.history.allocator)
	Job :: struct {
		s:      ^Sculptor,
		lo, per: Vec3,
	}
	size := hi - lo
	job := Job{s, lo, {}}
	for i in 0 ..< 3 do job.per[i] = 1 / size[i] if size[i] > 0 else 0
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, first, last: int) {
		job := cast(^Job)data
		s := job.s
		for id in first ..< last {
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count do s.lattice.place[v] = (s.mesh.positions[v] - job.lo) * job.per
		}
	}, NODE_GRAIN)
}

// Forgets where the vertices were: the lattice is gone, or will be made again.
sculptor_lattice_clear :: proc(s: ^Sculptor) {
	delete(s.lattice.place, s.history.allocator)
	s.lattice = {}
}

// Whether a lattice's places are noted, so its drags can pose.
sculptor_lattice_ready :: proc(s: ^Sculptor) -> bool {return s.lattice.place != nil}

// How much the point of `m` pulls a vertex at `place` in the box: the product of the
// three Bernstein polynomials of degree points - 1, nothing outside the box.
lattice_weight :: #force_inline proc(m: ^Lattice_Move, place: Vec3) -> f32 {
	w: f32 = 1
	n := m.points - 1
	for axis in 0 ..< 3 {
		u := place[axis]
		if u < 0 || u > 1 do return 0
		i := m.point[axis]
		b := f32(BINOMIAL[n][i])
		for _ in 0 ..< i do b *= u
		for _ in 0 ..< n - i do b *= 1 - u
		w *= b
	}
	return w
}

// n choose i for the degrees a lattice has.
@(private = "file", rodata)
BINOMIAL := [LATTICE_MAX_POINTS][LATTICE_MAX_POINTS]u8 {
	{1, 0, 0, 0},
	{1, 1, 0, 0},
	{1, 2, 1, 0},
	{1, 3, 3, 1},
}
