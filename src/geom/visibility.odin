package geom

import "core:math"
import "core:math/linalg"

Mat4 :: matrix[4, 4]f32

// A run of triangles that is drawn or skipped as a unit (one sculpt node), with what
// the renderer needs to decide that: its bounds for frustum culling and the cone
// holding its face normals for back-face culling.
Chunk :: struct {
	bounds:      Aabb,
	cone_axis:   Vec3,
	cone_cutoff: f32, // sine of the cone's half-angle; >= 1 means it can never face away
	first_index: u32,
	index_count: u32,
}

// Indices [first_index, first_index + index_count) to draw.
Index_Range :: struct {
	first_index: u32,
	index_count: u32,
}

Cull_Stats :: struct {
	chunks:   int,
	frustum:  int, // culled because outside the view
	backface: int, // culled because every triangle faces away from the eye
}

// Slack on the normal cone, so float error in face normals never culls a triangle the
// GPU would still draw.
CONE_SLACK :: 0.01

// Normal cone of a set of face normals (any length; zero-length ones are ignored).
// Returns the cone to store in a Chunk. Normalizes `face_normals` in place.
normal_cone :: proc(face_normals: []Vec3) -> (axis: Vec3, cutoff: f32) {
	sum: Vec3
	for &n in face_normals {
		n = linalg.normalize0(n)
		sum += n
	}
	axis = linalg.normalize0(sum)
	if axis == {} do return {}, 1
	min_dot := f32(1)
	for u in face_normals {
		if u != {} do min_dot = min(min_dot, linalg.dot(u, axis))
	}
	min_dot -= CONE_SLACK
	if min_dot <= 0 do return axis, 1 // wider than a hemisphere: some face always faces the eye
	return axis, math.sqrt(1 - min_dot * min_dot)
}

// The six planes (a, b, c, d with a·x + b·y + c·z + d >= 0 inside) of the frustum of
// `clip`, the matrix from the chunks' space to clip space. Planes are not normalized;
// only their signs are used.
frustum_planes :: proc(clip: Mat4) -> (planes: [6][4]f32) {
	row :: #force_inline proc(m: Mat4, i: int) -> [4]f32 {return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}}
	r0, r1, r2, r3 := row(clip, 0), row(clip, 1), row(clip, 2), row(clip, 3)
	planes[0] = r3 + r0
	planes[1] = r3 - r0
	planes[2] = r3 + r1
	planes[3] = r3 - r1
	planes[4] = r2 // clip-space depth in [0, 1]
	planes[5] = r3 - r2
	return
}

// Whether the box lies entirely outside one of the planes.
aabb_outside :: #force_inline proc(planes: ^[6][4]f32, b: Aabb) -> bool {
	for p in planes {
		// The box corner furthest along the plane normal.
		far := Vec3 {
			b.hi.x if p.x >= 0 else b.lo.x,
			b.hi.y if p.y >= 0 else b.lo.y,
			b.hi.z if p.z >= 0 else b.lo.z,
		}
		if p.x * far.x + p.y * far.y + p.z * far.z + p.w < 0 do return true
	}
	return false
}

// Whether every triangle of the chunk faces away from `eye`. Conservative: uses the
// bounding sphere of the chunk's box, so a chunk the eye is near or inside is kept.
chunk_backfacing :: #force_inline proc(c: Chunk, eye: Vec3) -> bool {
	if c.cone_cutoff >= 1 do return false
	center := (c.bounds.lo + c.bounds.hi) * 0.5
	radius := linalg.length(c.bounds.hi - c.bounds.lo) * 0.5
	to := center - eye
	dist := linalg.length(to)
	return linalg.dot(to, c.cone_axis) >= c.cone_cutoff * (dist + radius) + radius
}

// Appends the index ranges of the chunks that may be visible from `eye` through the
// frustum of `clip` (both in the chunks' space) to `out`, merging chunks that are
// adjacent in the index buffer. Chunks must be sorted by first_index. Chunks marked in
// `hidden` (one entry per chunk, or nil) are left out.
cull_chunks :: proc(chunks: []Chunk, clip: Mat4, eye: Vec3, out: ^[dynamic]Index_Range, backface := true, hidden: []bool = nil) -> (stats: Cull_Stats) {
	planes := frustum_planes(clip)
	stats.chunks = len(chunks)
	for c, i in chunks {
		if hidden != nil && hidden[i] do continue
		if aabb_outside(&planes, c.bounds) {
			stats.frustum += 1
			continue
		}
		if backface && chunk_backfacing(c, eye) {
			stats.backface += 1
			continue
		}
		append_range(out, c.first_index, c.index_count)
	}
	return
}

// Appends the index ranges of every chunk not marked in `hidden`, merging chunks that
// are adjacent in the index buffer: what to draw without culling.
chunks_shown :: proc(chunks: []Chunk, hidden: []bool, out: ^[dynamic]Index_Range) {
	for c, i in chunks do if !hidden[i] do append_range(out, c.first_index, c.index_count)
}

// Appends a range, merged into the last one when it follows on from it.
append_range :: #force_inline proc(out: ^[dynamic]Index_Range, first, count: u32) {
	if n := len(out); n > 0 && out[n - 1].first_index + out[n - 1].index_count == first {
		out[n - 1].index_count += count
		return
	}
	append(out, Index_Range{first, count})
}

// Octahedral encoding of a unit normal into two signed 16-bit values, read back by the
// vertex shader as SHORT2_NORM. Error is under 0.01 degrees.
oct_encode :: #force_inline proc(n: Vec3) -> [2]i16 {
	l1 := abs(n.x) + abs(n.y) + abs(n.z)
	if l1 == 0 do return {0, 0}
	p := [2]f32{n.x / l1, n.y / l1}
	if n.z < 0 {
		sx: f32 = 1 if p.x >= 0 else -1
		sy: f32 = 1 if p.y >= 0 else -1
		p = {(1 - abs(p.y)) * sx, (1 - abs(p.x)) * sy}
	}
	return {i16(math.round(clamp(p.x, -1, 1) * 32767)), i16(math.round(clamp(p.y, -1, 1) * 32767))}
}

// Inverse of oct_encode, as the shader does it. For tests.
oct_decode :: proc(e: [2]i16) -> Vec3 {
	p := [2]f32{max(f32(e.x) / 32767, -1), max(f32(e.y) / 32767, -1)}
	v := Vec3{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
	if v.z < 0 {
		sx: f32 = 1 if v.x >= 0 else -1
		sy: f32 = 1 if v.y >= 0 else -1
		v.x, v.y = (1 - abs(p.y)) * sx, (1 - abs(p.x)) * sy
	}
	return linalg.normalize0(v)
}
