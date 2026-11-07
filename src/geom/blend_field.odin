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
	edge:   f32, // the mesh's mean edge (blend_surface_edge), for the seam's lift; 0 for none
}

// The sampled field: `h` apart, bricks of BLEND_SIDE³ samples, each value the signed
// distance clamped to ±band, and beside it the field's exact gradient there (the way from
// the closest point, or the pseudo-normal on the surface) with the painted weight at the
// closest point (blend_extra_pack). Gourmel's opening function turns the angle between two
// fields' gradients into the blend's radius through steep ramps, so the gradients are kept
// exact at the samples rather than rebuilt from the distances, whose differences turned by
// a few degrees from cell to cell and moved a three-way junction's fillet by 4 % of the
// radius. Slots are given in the sorted order of the keys each fill adds, so a field's
// contents never depend on thread timing.
Blend_Field :: struct {
	h, band: f32,
	keys:    [dynamic]u64, // per slot
	values:  [dynamic]f32, // BLEND_SAMPLES per slot, x fastest
	extras:  [dynamic]u32, // likewise: the gradient and weight (blend_extra_pack)
	table:   []u64, // open addressing: key, then its slot at the same index of `slots`
	slots:   []i32,
	used:    int,
	revision: u64, // moves on whenever the table does, for a copy kept elsewhere (the GPU's)
}

blend_field_init :: proc(f: ^Blend_Field, h, band: f32, allocator := context.allocator) {
	f^ = {h = h, band = band}
	f.keys = make([dynamic]u64, allocator)
	f.values = make([dynamic]f32, allocator)
	f.extras = make([dynamic]u32, allocator)
	table_regrow(f, 64)
}

blend_field_destroy :: proc(f: ^Blend_Field) {
	delete(f.keys)
	delete(f.values)
	delete(f.extras)
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

// The table slot a key starts its search at, before the mask: a 32-bit hash of the key's
// three 21-bit coordinates (lowbias32 over a spatial mix), so the GPU kernel
// (shaders/blend_project.comp.slang), which has no 64-bit integers everywhere, finds a
// brick by the same probes.
blend_key_hash :: #force_inline proc(k: u64) -> u32 {
	x, y, z := u32(k & KEY_MASK), u32((k >> 21) & KEY_MASK), u32((k >> 42) & KEY_MASK)
	h := x * 73856093 ~ y * 19349663 ~ z * 83492791
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return h
}

// The slot of the brick with key k, or -1 when the field does not hold it.
blend_field_slot :: #force_inline proc(f: ^Blend_Field, k: u64) -> i32 {
	mask := u64(len(f.table) - 1)
	for i := u64(blend_key_hash(k)) & mask; ; i = (i + 1) & mask {
		if f.table[i] == k do return f.slots[i]
		if f.table[i] == KEY_FREE do return -1
	}
}

@(private = "file")
table_put :: proc(f: ^Blend_Field, k: u64, slot: i32) {
	f.revision += 1
	if (f.used + 1) * 2 > len(f.table) do table_regrow(f, len(f.table) * 2)
	mask := u64(len(f.table) - 1)
	for i := u64(blend_key_hash(k)) & mask; ; i = (i + 1) & mask {
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
	resize(&f.extras, len(f.keys) * BLEND_SAMPLES)
	Fill :: struct {
		f:     ^Blend_Field,
		s:     ^Blend_Surface,
		first: int,
	}
	job := Fill{f, s, first}
	// A job a row of a brick's samples, so a few bricks still spread over every worker.
	jobs.parallel_for(pool, n * BLEND_SIDE * BLEND_SIDE, &job, proc(data: rawptr, i: int) {
		job := cast(^Fill)data
		slot := job.first + i / (BLEND_SIDE * BLEND_SIDE)
		values := job.f.values[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
		extras := job.f.extras[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
		fill_row(job.f.h, job.f.band, job.s, job.f.keys[slot], values, extras, (i / BLEND_SIDE) % BLEND_SIDE, i % BLEND_SIDE)
	})
	jobs.parallel_for(pool, n, &job, proc(data: rawptr, i: int) {
		job := cast(^Fill)data
		sign_unknown(job.f.values[(job.first + i) * BLEND_SAMPLES:][:BLEND_SAMPLES], job.f.band)
	})
	return n
}

// One brick's samples, filled apart from any field: by blend_brick_sample on any thread
// (it reads only the surface, which must not change meanwhile), then published by
// blend_field_put on the thread that owns the field. A fill that must not hold up a frame
// samples its bricks this way on threads of its own.
Blend_Brick :: struct {
	key:    u64,
	values: [BLEND_SAMPLES]f32,
	extras: [BLEND_SAMPLES]u32,
}

// Samples brick k of a field at spacing h and band `band` from surface s into b: the same
// samples blend_field_fill makes.
blend_brick_sample :: proc(h, band: f32, s: ^Blend_Surface, k: u64, b: ^Blend_Brick) {
	b.key = k
	for z in 0 ..< BLEND_SIDE do for y in 0 ..< BLEND_SIDE do fill_row(h, band, s, k, b.values[:], b.extras[:], z, y)
	sign_unknown(b.values[:], band)
}

// Adds a sampled brick to the field and publishes it; false when the field holds it already.
blend_field_put :: proc(f: ^Blend_Field, b: ^Blend_Brick) -> bool {
	if blend_field_slot(f, b.key) >= 0 do return false
	append(&f.keys, b.key)
	append(&f.values, ..b.values[:])
	append(&f.extras, ..b.extras[:])
	table_put(f, b.key, i32(len(f.keys) - 1))
	return true
}

// One row of a brick (y, z) into its samples: BLEND_SIDE samples along x, the hint carried
// from each sample to the next. A sample with no surface within the band is stored as NaN
// for sign_unknown.
@(private = "file")
fill_row :: proc(h, band: f32, s: ^Blend_Surface, k: u64, values: []f32, extras: []u32, z, y: int) {
	b := blend_unkey(k)
	lo := Vec3{f32(b.x), f32(b.y), f32(b.z)} * (h * BLEND_BRICK)
	base := z * BLEND_SIDE * BLEND_SIDE
	hint := BVH_NONE
	for x in 0 ..< BLEND_SIDE {
		p := lo + Vec3{f32(x), f32(y), f32(z)} * h
		d, n, w, tri, ok := surface_distance(s, p, band, hint)
		at := base + y * BLEND_SIDE + x
		if !ok {
			values[at] = math.nan_f32()
			extras[at] = 0
			continue
		}
		hint = tri
		values[at] = d
		extras[at] = blend_extra_pack(n, w)
	}
}

// Gives each NaN sample of a brick ±band, the sign flooded from signed samples through
// face neighbours: a NaN sample has no surface within the band (at least h) of it, so its
// neighbours h away lie on its side. Passes read the last pass's values only, so the
// result is the same in any order; a brick with no signed sample at all is outside.
@(private = "file")
sign_unknown :: proc(v: []f32, band: f32) {
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
	for &x, i in v do if math.is_nan(x) do x = band if sign[i] >= 0 else -band
}

// The signed distance from p to the surface within `band`, the field's unit gradient there
// (the way from the closest point outward, or the pseudo-normal where p is on the surface),
// its painted weight, and the closest triangle (a hint for the next sample); ok is false
// past the band.
surface_distance :: proc(s: ^Blend_Surface, p: Vec3, band: f32, hint := BVH_NONE) -> (d: f32, g: Vec3, w: u8, tri: u32, ok: bool) {
	bary: [3]f32
	dist: f32
	tri, bary, dist, ok = bvh_closest(s.bvh, s.mesh, p, band, hint)
	if !ok do return
	c := [3]u32{s.mesh.indices[3 * tri], s.mesh.indices[3 * tri + 1], s.mesh.indices[3 * tri + 2]}
	q := s.mesh.positions[c[0]] * bary[0] + s.mesh.positions[c[1]] * bary[1] + s.mesh.positions[c[2]] * bary[2]
	n := pseudo_normal(s, tri, c, bary)
	d = dist if linalg.dot(p - q, n) >= 0 else -dist
	// Off the surface the gradient is the way from the closest point, outward either side.
	g = (p - q) / d if dist > 1e-6 * band else linalg.normalize0(n)
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

// A sample's gradient and weight in one word: the unit gradient octahedrally, 12 bits a
// half from 1 (0 for none, a sample past the band), and the weight in the top byte.
blend_extra_pack :: proc(n: Vec3, w: u8) -> u32 {
	l := abs(n.x) + abs(n.y) + abs(n.z)
	if l == 0 do return u32(w) << 24
	e := n.xy / l
	if n.z < 0 {
		sx: f32 = 1 if e.x >= 0 else -1
		sy: f32 = 1 if e.y >= 0 else -1
		e = {(1 - abs(e.y)) * sx, (1 - abs(e.x)) * sy}
	}
	qx := u32(math.round(clamp(e.x * 0.5 + 0.5, 0, 1) * 4094)) + 1
	qy := u32(math.round(clamp(e.y * 0.5 + 0.5, 0, 1) * 4094)) + 1
	return qx | qy << 12 | u32(w) << 24
}

// The gradient blend_extra_pack kept (zero for none) and the weight byte.
blend_extra_unpack :: proc(x: u32) -> (n: Vec3, w: u8) {
	w = u8(x >> 24)
	qx, qy := x & 0xfff, (x >> 12) & 0xfff
	if qx == 0 do return
	e := [2]f32{f32(qx - 1) / 4094 * 2 - 1, f32(qy - 1) / 4094 * 2 - 1}
	v := Vec3{e.x, e.y, 1 - abs(e.x) - abs(e.y)}
	if v.z < 0 {
		sx: f32 = 1 if e.x >= 0 else -1
		sy: f32 = 1 if e.y >= 0 else -1
		v.xy = {(1 - abs(e.y)) * sx, (1 - abs(e.x)) * sy}
	}
	return linalg.normalize0(v), w
}

// The field at p by trilinear reads of its brick: the distance, the gradient (the samples'
// exact gradients mixed, smooth across cells) and the weight 0 (no blend) to 1. ok is
// false where no brick holds p.
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
	xs := f.extras[slot * BLEND_SAMPLES:][:BLEND_SAMPLES]
	gc: [8]Vec3
	wc: [8]f32
	for k in 0 ..< 8 {
		n, wb := blend_extra_unpack(xs[corner_index(l, k)])
		gc[k], wc[k] = n, f32(wb)
	}
	gx0 := linalg.lerp(gc[0], gc[1], t.x)
	gx1 := linalg.lerp(gc[2], gc[3], t.x)
	gx2 := linalg.lerp(gc[4], gc[5], t.x)
	gx3 := linalg.lerp(gc[6], gc[7], t.x)
	g = linalg.lerp(linalg.lerp(gx0, gx1, t.y), linalg.lerp(gx2, gx3, t.y), t.z)
	wx0 := math.lerp(wc[0], wc[1], t.x)
	wx1 := math.lerp(wc[2], wc[3], t.x)
	wx2 := math.lerp(wc[4], wc[5], t.x)
	wx3 := math.lerp(wc[6], wc[7], t.x)
	w = 1 - math.lerp(math.lerp(wx0, wx1, t.y), math.lerp(wx2, wx3, t.y), t.z) / 255
	return d, g, w, true
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
	return len(f.keys) * (8 + BLEND_SAMPLES * 8) + len(f.table) * 12
}

