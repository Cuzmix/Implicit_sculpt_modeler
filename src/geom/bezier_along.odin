package geom

import "core:math/linalg"

// Copies of a part set one after another along a Bézier curve, as Nomad's and ZBrush's
// curve brushes set stitches, teeth or any mesh: each copy turned to the curve's frame
// where it sits and sized by the curve's width there.

Along_Options :: struct {
	gap:       f32, // the space between copies, over a copy's own depth along the curve
	alternate: bool, // every other copy turned half round, pointing to the other side
	lift:      f32, // each copy raised out from the surface, over its width
	up:        Vec3, // the first frame's normal: the surface's, where the curve was drawn on a model
}

ALONG_DEFAULTS :: Along_Options{gap = 0.2, up = {0, 1, 0}}
ALONG_COPIES_MAX :: 4096
ALONG_VERTICES_MAX :: 2_000_000

// How finely the curve is sampled to find where each copy goes, over its mean width.
ALONG_SAMPLE_SHARE :: 0.05

// Copies of `part` along the curve through `points` (closed or not). The part is in unit
// space: x across the curve (1 wide), y out from the surface, z along it, its origin on
// the curve. ok is false for fewer than two points, no width, an empty part, or nothing
// placed.
bezier_along :: proc(points: []Bezier_Point, closed: bool, part: Mesh, o: Along_Options, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	if bezier_segments(len(points), closed) == 0 || len(part.positions) == 0 || len(part.indices) == 0 do return {}, false
	mean: f32
	for p in points do mean += 2 * max(p.radius, 0)
	mean /= f32(len(points))
	length := bezier_length(points, closed)
	if !(mean > 0) || !(length > 0) do return {}, false
	// The part's depth along the curve, which sets the step from one copy to the next.
	lo, hi := max(f32), -max(f32)
	for q in part.positions do lo, hi = min(lo, q.z), max(hi, q.z)
	depth := max(hi - lo, 0.05)
	samples := bezier_sample(points, closed, max(ALONG_SAMPLE_SHARE * mean, length / 65536), context.temp_allocator)
	if len(samples) < 2 do return {}, false
	up := linalg.normalize0(o.up)
	if up == {} do up = tube_up(points)
	frames := bezier_frames(samples, up, closed, context.temp_allocator)
	gap := max(o.gap, -0.9)
	most := min(ALONG_COPIES_MAX, ALONG_VERTICES_MAX / len(part.positions))
	m.positions = make([dynamic]Vec3, 0, min(most, 64) * len(part.positions), allocator)
	m.indices = make([dynamic]u32, 0, min(most, 64) * len(part.indices), allocator)
	s: f32
	j := 0
	for n := 0; n < most && s <= length; n += 1 {
		for j < len(samples) - 1 && samples[j + 1].s <= s do j += 1
		f := frames[j]
		width := 2 * max(samples[j].radius, 0)
		step := width * depth * (1 + gap)
		// A closed curve's last copy must not run into the first.
		if closed && n > 0 && s + step > length + 1e-6 * length do break
		if width > 0 {
			turn: f32 = -1 if o.alternate && n % 2 == 1 else 1
			base := u32(len(m.positions))
			origin := f.p + (o.lift * width) * f.n
			for q in part.positions do append(&m.positions, origin + width * (turn * q.x * f.b + q.y * f.n - turn * q.z * f.t))
			for v in part.indices do append(&m.indices, base + v)
		}
		s += max(step, 1e-4 * mean)
	}
	if len(m.indices) == 0 {
		mesh_destroy(&m)
		return {}, false
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	mesh_recompute_normals(&m)
	return m, true
}

// A part for bezier_along made from any mesh: centred on its bounds and scaled so its
// widest side is 1, in a new mesh.
along_part_of :: proc(mesh: Mesh, allocator := context.allocator) -> (part: Mesh, ok: bool) {
	if len(mesh.positions) == 0 || len(mesh.indices) == 0 do return {}, false
	b := AABB_EMPTY
	for p in mesh.positions do aabb_grow(&b, p)
	d := b.hi - b.lo
	side := max(d.x, d.y, d.z)
	if !(side > 0) do return {}, false
	middle := 0.5 * (b.lo + b.hi)
	part.positions = make([dynamic]Vec3, len(mesh.positions), allocator)
	part.indices = make([dynamic]u32, len(mesh.indices), allocator)
	for p, i in mesh.positions do part.positions[i] = (p - middle) / side
	copy(part.indices[:], mesh.indices[:])
	part.normals = make([dynamic]Vec3, len(mesh.positions), allocator)
	return part, true
}
