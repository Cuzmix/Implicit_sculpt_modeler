package geom

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// The distance field Smooth blend reads (the Live stack row; design in
// .claude/project-memory/notes/smooth-blend/design.md): one object's signed distance,
// negative inside, sampled from its BVH into sparse bricks only where another object comes
// within reach of it, in the object's own space, so a rigid move of either object reuses
// every brick. Implicit Skinning sampled each part's field into a grid once for the same
// reason: a field read from a grid costs a few loads, an exact closest-point query on a
// dense sculpt tens of microseconds.

// Cells along a brick's edge.
BLEND_BRICK :: 8
// Samples along a brick's edge: each brick keeps its far faces too, so a trilinear read
// never reaches into a neighbour (13 % more samples than shared faces, no seams to stitch).
BLEND_SIDE :: BLEND_BRICK + 1
BLEND_SAMPLES :: BLEND_SIDE * BLEND_SIDE * BLEND_SIDE
// Brick coordinates are packed in 21 bits each, so a field spans 2^21 bricks along an axis.
@(private = "file")
KEY_OFFSET :: 1 << 20
@(private = "file")
KEY_MASK :: (1 << 21) - 1
// A table slot nothing has taken.
@(private = "file")
KEY_FREE :: max(u64)

// One object's surface as the blend reads it, in its own space: positions and triangles,
// a tree over them (bvh_build_morton), the triangles round each vertex for the sign, and
// the painted weight per vertex (nil: blend everywhere; 255 fades the blend out fully).
Blend_Surface :: struct {
	mesh:   Mesh,
	bvh:    Bvh,
	faces:  Vertex_Faces,
	weight: []u8,
}

// The sampled field: `h` apart, bricks of BLEND_SIDE³ samples, each value the signed
// distance clamped to ±band and each weight the painted weight at the sample's closest
// point. Slots are given in the sorted order of the keys each fill adds, so a field's
// contents never depend on thread timing.
Blend_Field :: struct {
	h, band: f32,
	keys:    [dynamic]u64, // per slot
	values:  [dynamic]f32, // BLEND_SAMPLES per slot, x fastest
	weights: [dynamic]u8,  // likewise; 255 = no blend
	table:   []u64, // open addressing: key, then its slot at the same index of `slots`
	slots:   []i32,
	used:    int,
}

blend_field_init :: proc(f: ^Blend_Field, h, band: f32, allocator := context.allocator) {
	f^ = {h = h, band = band}
	f.keys = make([dynamic]u64, allocator)
	f.values = make([dynamic]f32, allocator)
	f.weights = make([dynamic]u8, allocator)
	table_regrow(f, 64)
}

blend_field_destroy :: proc(f: ^Blend_Field) {
	delete(f.keys)
	delete(f.values)
	delete(f.weights)
	delete(f.table, f.keys.allocator)
	delete(f.slots, f.keys.allocator)
	f^ = {}
}

// The brick holding point p of the field's space, and its packed key.
blend_brick_of :: #force_inline proc(h: f32, p: Vec3) -> [3]i32 {
	q := p / (h * BLEND_BRICK)
	return {i32(math.floor(q.x)), i32(math.floor(q.y)), i32(math.floor(q.z))}
}

blend_key :: #force_inline proc(b: [3]i32) -> u64 {
	return u64(b.x + KEY_OFFSET) & KEY_MASK | (u64(b.y + KEY_OFFSET) & KEY_MASK) << 21 | (u64(b.z + KEY_OFFSET) & KEY_MASK) << 42
}

blend_unkey :: #force_inline proc(k: u64) -> [3]i32 {
	return {i32(k & KEY_MASK) - KEY_OFFSET, i32((k >> 21) & KEY_MASK) - KEY_OFFSET, i32((k >> 42) & KEY_MASK) - KEY_OFFSET}
}

// Whether brick b can be packed: its coordinates inside the 21 bits a key keeps.
blend_brick_fits :: #force_inline proc(b: [3]i32) -> bool {
	return abs(b.x) < KEY_OFFSET - 1 && abs(b.y) < KEY_OFFSET - 1 && abs(b.z) < KEY_OFFSET - 1
}

@(private = "file")
key_hash :: #force_inline proc(k: u64) -> u64 {
	// splitmix64's finalizer: neighbouring bricks land far apart in the table.
	z := k + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// The slot of the brick with key k, or -1 when the field does not hold it.
blend_field_slot :: #force_inline proc(f: ^Blend_Field, k: u64) -> i32 {
	mask := u64(len(f.table) - 1)
	for i := key_hash(k) & mask; ; i = (i + 1) & mask {
		if f.table[i] == k do return f.slots[i]
		if f.table[i] == KEY_FREE do return -1
	}
}

@(private = "file")
table_put :: proc(f: ^Blend_Field, k: u64, slot: i32) {
	if (f.used + 1) * 2 > len(f.table) do table_regrow(f, len(f.table) * 2)
	mask := u64(len(f.table) - 1)
	for i := key_hash(k) & mask; ; i = (i + 1) & mask {
		if f.table[i] == k {
			f.slots[i] = slot
			return
		}
		if f.table[i] == KEY_FREE {
			f.table[i], f.slots[i] = k, slot
			f.used += 1
			return
		}
	}
}

@(private = "file")
table_regrow :: proc(f: ^Blend_Field, size: int) {
	allocator := f.keys.allocator
	old_table, old_slots := f.table, f.slots
	f.table = make([]u64, size, allocator)
	f.slots = make([]i32, size, allocator)
	slice.fill(f.table, KEY_FREE)
	f.used = 0
	for k, i in old_table do if k != KEY_FREE do table_put(f, k, old_slots[i])
	delete(old_table, allocator)
	delete(old_slots, allocator)
}

// Samples the bricks `keys` names that the field does not hold yet from surface `s`, in
// parallel over brick slices, and returns how many it filled. `keys` need not be sorted
// or unique. Every sample is the exact distance to the closest point within the band
// (bvh_closest, the hint chained along a slice's rows), signed by the angle-weighted
// pseudo-normal of the closest feature (Bærentzen and Aanæs 2005, from positions alone),
// and its weight the painted weight at that point. A sample with no surface within the
// band is stored as ±band, its sign the nearest signed sample's in its brick, since a
// sample that far has no crossing between it and its neighbour.
blend_field_fill :: proc(f: ^Blend_Field, s: ^Blend_Surface, keys: []u64, pool: ^jobs.Pool) -> int {
	fresh := make([dynamic]u64, 0, len(keys), context.temp_allocator)
	for k in keys do if blend_field_slot(f, k) == -1 do append(&fresh, k)
	slice.sort(fresh[:])
	n := len(slice.unique(fresh[:]))
	if n == 0 do return 0
	first := len(f.keys)
	for k, i in fresh[:n] {
		append(&f.keys, k)
		table_put(f, k, i32(first + i))
	}
	resize(&f.values, len(f.keys) * BLEND_SAMPLES)
	resize(&f.weights, len(f.keys) * BLEND_SAMPLES)
	Fill :: struct {
		f:     ^Blend_Field,
		s:     ^Blend_Surface,
		first: int,
	}
	job := Fill{f, s, first}
	jobs.parallel_for(pool, n * BLEND_SIDE, &job, proc(data: rawptr, i: int) {
		job := cast(^Fill)data
		fill_slice(job.f, job.s, job.first + i / BLEND_SIDE, i % BLEND_SIDE)
	})
	jobs.parallel_for(pool, n, &job, proc(data: rawptr, i: int) {
		job := cast(^Fill)data
		sign_unknown(job.f, job.first + i)
	})
	return n
}

// One z slice of a brick: its BLEND_SIDE² samples, rows along x, the hint carried from
// each sample to the next. A sample with no surface within the band is stored as NaN for
// sign_unknown.
@(private = "file")
fill_slice :: proc(f: ^Blend_Field, s: ^Blend_Surface, slot, z: int) {
	b := blend_unkey(f.keys[slot])
	lo := Vec3{f32(b.x), f32(b.y), f32(b.z)} * (f.h * BLEND_BRICK)
	base := slot * BLEND_SAMPLES + z * BLEND_SIDE * BLEND_SIDE
	hint := BVH_NONE
	for y in 0 ..< BLEND_SIDE {
		for x in 0 ..< BLEND_SIDE {
			p := lo + Vec3{f32(x), f32(y), f32(z)} * f.h
			d, w, tri, ok := surface_distance(s, p, f.band, hint)
			at := base + y * BLEND_SIDE + x
			if !ok {
				f.values[at] = math.nan_f32()
				f.weights[at] = 0
				continue
			}
			hint = tri
			f.values[at] = d
			f.weights[at] = w
		}
	}
}

// Gives each NaN sample of a brick ±band, the sign flooded from signed samples through
// face neighbours: a NaN sample has no surface within the band (at least h) of it, so its
// neighbours h away lie on its side. Passes read the last pass's values only, so the
// result is the same in any order; a brick with no signed sample at all is outside.
@(private = "file")
sign_unknown :: proc(f: ^Blend_Field, slot: int) {
	v := f.values[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
	unknown := 0
	for x in v do if math.is_nan(x) do unknown += 1
	if unknown == 0 do return
	sign: [BLEND_SAMPLES]i8
	for x, i in v do if !math.is_nan(x) do sign[i] = -1 if x < 0 else 1
	if unknown == BLEND_SAMPLES do slice.fill(sign[:], 1)
	next := sign
	for unknown > 0 && unknown < BLEND_SAMPLES {
		changed := false
		for i in 0 ..< BLEND_SAMPLES {
			if sign[i] != 0 do continue
			at := [3]int{i % BLEND_SIDE, (i / BLEND_SIDE) % BLEND_SIDE, i / (BLEND_SIDE * BLEND_SIDE)}
			for a in 0 ..< 3 {
				for step in ([2]int{-1, 1}) {
					n := at
					n[a] += step
					if n[a] < 0 || n[a] >= BLEND_SIDE do continue
					if s := sign[sample_index(n)]; s != 0 && next[i] == 0 {
						next[i] = s
						changed = true
						unknown -= 1
					}
				}
			}
		}
		sign = next
		if !changed do break
	}
	for &x, i in v do if math.is_nan(x) do x = f.band if sign[i] >= 0 else -f.band
}

// The signed distance from p to the surface within `band`, its painted weight there, and
// the closest triangle (a hint for the next sample); ok is false past the band.
surface_distance :: proc(s: ^Blend_Surface, p: Vec3, band: f32, hint := BVH_NONE) -> (d: f32, w: u8, tri: u32, ok: bool) {
	bary: [3]f32
	dist: f32
	tri, bary, dist, ok = bvh_closest(s.bvh, s.mesh, p, band, hint)
	if !ok do return
	c := [3]u32{s.mesh.indices[3 * tri], s.mesh.indices[3 * tri + 1], s.mesh.indices[3 * tri + 2]}
	q := s.mesh.positions[c[0]] * bary[0] + s.mesh.positions[c[1]] * bary[1] + s.mesh.positions[c[2]] * bary[2]
	n := pseudo_normal(s, tri, c, bary)
	d = dist if linalg.dot(p - q, n) >= 0 else -dist
	if s.weight != nil {
		w = u8(math.round(f32(s.weight[c[0]]) * bary[0] + f32(s.weight[c[1]]) * bary[1] + f32(s.weight[c[2]]) * bary[2]))
	}
	return
}

// The angle-weighted pseudo-normal of the feature of triangle `tri` the closest point lies
// on: the face's normal inside it, the two faces' sum on an edge (one weight zero), and
// each face's normal weighted by its angle at the corner on a corner (two zero). Exact for
// the sign of a closed manifold, the concave crease included (Bærentzen and Aanæs 2005).
@(private = "file")
pseudo_normal :: proc(s: ^Blend_Surface, tri: u32, c: [3]u32, bary: [3]f32) -> Vec3 {
	zeros := 0
	for w in bary do if w == 0 do zeros += 1
	switch zeros {
	case 1:
		a, b := c[1], c[2]
		if bary[1] == 0 do a, b = c[0], c[2]
		if bary[2] == 0 do a, b = c[0], c[1]
		n: Vec3
		for t in s.faces.tris[s.faces.offsets[a]:s.faces.offsets[a + 1]] {
			tc := s.mesh.indices[3 * t:][:3]
			if tc[0] == b || tc[1] == b || tc[2] == b do n += face_unit(s.mesh, t)
		}
		return n
	case 2:
		v := c[0] if bary[0] != 0 else (c[1] if bary[1] != 0 else c[2])
		n: Vec3
		for t in s.faces.tris[s.faces.offsets[v]:s.faces.offsets[v + 1]] {
			tc := s.mesh.indices[3 * t:][:3]
			k := 0 if tc[0] == v else (1 if tc[1] == v else 2)
			p := s.mesh.positions[v]
			e1 := linalg.normalize0(s.mesh.positions[tc[(k + 1) % 3]] - p)
			e2 := linalg.normalize0(s.mesh.positions[tc[(k + 2) % 3]] - p)
			n += face_unit(s.mesh, t) * math.acos(clamp(linalg.dot(e1, e2), -1, 1))
		}
		return n
	}
	return face_unit(s.mesh, tri)
}

@(private = "file")
face_unit :: #force_inline proc(m: Mesh, t: u32) -> Vec3 {
	p0, p1, p2 := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
	return linalg.normalize0(linalg.cross(p1 - p0, p2 - p0))
}

// The field at p by trilinear reads of its brick: the distance, its gradient (the
// trilinear's own, constant across a cell's faces only to first order: Newton's steps),
// and the weight 0 (no blend) to 1. ok is false where no brick holds p.
blend_field_at :: proc(f: ^Blend_Field, p: Vec3) -> (d: f32, g: Vec3, w: f32, ok: bool) {
	slot, l, t := locate(f, p) or_return
	v := f.values[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
	c := corners(v, l)
	x0 := math.lerp(c[0], c[1], t.x)
	x1 := math.lerp(c[2], c[3], t.x)
	x2 := math.lerp(c[4], c[5], t.x)
	x3 := math.lerp(c[6], c[7], t.x)
	y0 := math.lerp(x0, x1, t.y)
	y1 := math.lerp(x2, x3, t.y)
	d = math.lerp(y0, y1, t.z)
	gx := math.lerp(math.lerp(c[1] - c[0], c[3] - c[2], t.y), math.lerp(c[5] - c[4], c[7] - c[6], t.y), t.z)
	gy := math.lerp(math.lerp(c[2] - c[0], c[3] - c[1], t.x), math.lerp(c[6] - c[4], c[7] - c[5], t.x), t.z)
	g = Vec3{gx, gy, y1 - y0} / f.h
	ws := f.weights[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
	wc: [8]f32
	for k in 0 ..< 8 do wc[k] = f32(ws[corner_index(l, k)])
	wx0 := math.lerp(wc[0], wc[1], t.x)
	wx1 := math.lerp(wc[2], wc[3], t.x)
	wx2 := math.lerp(wc[4], wc[5], t.x)
	wx3 := math.lerp(wc[6], wc[7], t.x)
	w = 1 - math.lerp(math.lerp(wx0, wx1, t.y), math.lerp(wx2, wx3, t.y), t.z) / 255
	return d, g, w, true
}

// The field's gradient at p, smooth across cell faces: the trilinear mix of the central
// differences at the cell's eight corners (one-sided on a brick's faces), for normals,
// where the trilinear's own gradient would facet a fillet a few cells across.
blend_field_normal :: proc(f: ^Blend_Field, p: Vec3) -> (g: Vec3, ok: bool) {
	slot, l, t := locate(f, p) or_return
	v := f.values[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
	gc: [8]Vec3
	for k in 0 ..< 8 {
		at := l + {k & 1, (k >> 1) & 1, (k >> 2) & 1}
		for a in 0 ..< 3 {
			lo, hi := at, at
			if lo[a] > 0 do lo[a] -= 1
			if hi[a] < BLEND_SIDE - 1 do hi[a] += 1
			gc[k][a] = (v[sample_index(hi)] - v[sample_index(lo)]) / (f32(hi[a] - lo[a]) * f.h)
		}
	}
	x0 := linalg.lerp(gc[0], gc[1], t.x)
	x1 := linalg.lerp(gc[2], gc[3], t.x)
	x2 := linalg.lerp(gc[4], gc[5], t.x)
	x3 := linalg.lerp(gc[6], gc[7], t.x)
	return linalg.lerp(linalg.lerp(x0, x1, t.y), linalg.lerp(x2, x3, t.y), t.z), true
}

// The slot of the brick holding p, the cell's lower corner within it and p's place in the
// cell.
@(private = "file")
locate :: #force_inline proc(f: ^Blend_Field, p: Vec3) -> (slot: int, l: [3]int, t: Vec3, ok: bool) {
	q := p / f.h
	cell := [3]f32{math.floor(q.x), math.floor(q.y), math.floor(q.z)}
	b := [3]i32{i32(math.floor(cell.x / BLEND_BRICK)), i32(math.floor(cell.y / BLEND_BRICK)), i32(math.floor(cell.z / BLEND_BRICK))}
	if !blend_brick_fits(b) do return
	s := blend_field_slot(f, blend_key(b))
	if s < 0 do return
	l = {int(cell.x) - int(b.x) * BLEND_BRICK, int(cell.y) - int(b.y) * BLEND_BRICK, int(cell.z) - int(b.z) * BLEND_BRICK}
	return int(s), l, q - cell, true
}

@(private = "file")
sample_index :: #force_inline proc(at: [3]int) -> int {return (at.z * BLEND_SIDE + at.y) * BLEND_SIDE + at.x}

@(private = "file")
corner_index :: #force_inline proc(l: [3]int, k: int) -> int {
	return sample_index(l + {k & 1, (k >> 1) & 1, (k >> 2) & 1})
}

@(private = "file")
corners :: #force_inline proc(v: []f32, l: [3]int) -> (c: [8]f32) {
	for k in 0 ..< 8 do c[k] = v[corner_index(l, k)]
	return
}

// Bytes a field holds, for the bench and the memory budget.
blend_field_bytes :: proc(f: ^Blend_Field) -> int {
	return len(f.keys) * (8 + BLEND_SAMPLES * 5) + len(f.table) * 12
}

