package sculpt

import "base:intrinsics"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../geom"

// The detail skin in the scene file, after the levels (levels_write), in an order only
// the top level's topology decides, since sculptor_init renumbers vertices, edges and
// triangles each time a sculptor is built: the vertices' samples in the level's file
// order (level_canon), then each edge's by the file places of its ends (lower first),
// running from the lower end, then each triangle's inside samples by tri_canon's order,
// counted from its corner placed first, keeping its winding. Then a byte saying whether
// the vector page follows, and if so each sample's sideways offset in the same order, as
// a vector in the mesh's space (three f16), since the owner frame it is kept in depends on
// the numbering the reader builds anew. Normals are worked out again on reading.

@(private = "file")
SKIN_TAG :: u32(0x4e49_4b53) // "SKIN" in the file

// Whether the bytes at the reader's place start a skin (levels_skin_write), without
// reading them.
levels_skin_follows :: proc(r: ^geom.Byte_Reader) -> bool {
	if !r.ok || len(r.data) - r.at < size_of(u32) do return false
	tag: u32
	copy(slice.bytes_from_ptr(&tag, size_of(u32)), r.data[r.at:][:size_of(u32)])
	return tag == SKIN_TAG
}

// The top level's skin, nil for none.
levels_skin :: proc(l: ^Levels) -> ^Skin {
	if len(l.levels) == 0 do return nil
	return l.levels[len(l.levels) - 1].sculptor.skin
}

// Per sample, where it goes in the file's order, for the top level's skin.
@(private = "file")
skin_file_order :: proc(l: ^Levels, abort: ^bool) -> (order: []u32, ok: bool) {
	top := len(l.levels) - 1
	lv := l.levels[top]
	s := &lv.sculptor
	sk := s.skin
	canon: []u32
	for j in 1 ..= top {
		canon = level_canon(l, j, canon, nil, abort, context.temp_allocator)
		if canon == nil do return nil, false
	}
	tris := tri_canon(s, canon, abort)
	if tris == nil do return nil, false
	place :: #force_inline proc(canon: []u32, v: u32) -> u32 {return canon[v] if canon != nil else v}
	S := sk.segments
	I := s.mesh.indices[:]
	V, E, T := sk.vert_count, sk.edge_count, sk.tri_count
	order = make([]u32, skin_sample_count(sk), context.temp_allocator)
	for v in 0 ..< V do order[v] = place(canon, v)
	// Edges by their ends' places, the lower first.
	Keyed :: struct {
		key:  u64,
		edge: u32,
	}
	keyed := make([]Keyed, E, context.temp_allocator)
	for e, i in sk.edges {
		a := place(canon, I[3 * e.tris[0] + e.corner])
		b := place(canon, I[3 * e.tris[0] + (e.corner + 1) % 3])
		keyed[i] = {u64(min(a, b)) << 32 | u64(max(a, b)), u32(i)}
	}
	if stopped_skin(abort) do return nil, false
	slice.sort_by_key(keyed, proc(k: Keyed) -> u64 {return k.key})
	for k, at in keyed {
		e := sk.edges[k.edge]
		a := place(canon, I[3 * e.tris[0] + e.corner])
		b := place(canon, I[3 * e.tris[0] + (e.corner + 1) % 3])
		for along in 1 ..< S {
			// The file runs the edge from its lower end.
			k_file := along if a < b else S - along
			order[V + k.edge * (S - 1) + (along - 1)] = V + u32(at) * (S - 1) + (k_file - 1)
		}
	}
	F := skin_face_samples(sk)
	if F > 0 {
		for t in 0 ..< T {
			if t & 0xffff == 0 && stopped_skin(abort) do return nil, false
			c := [3]u32{place(canon, I[3 * t]), place(canon, I[3 * t + 1]), place(canon, I[3 * t + 2])}
			k0 := u32(0)
			if c[1] < c[k0] do k0 = 1
			if c[2] < c[k0] do k0 = 2
			for j in 1 ..< S - 1 do for i in 1 ..< S - j {
				w := [3]u32{S - i - j, i, j}
				fi, fj := w[(k0 + 1) % 3], w[(k0 + 2) % 3]
				x := skin_sample(sk, I, t, i, j)
				order[x] = V + E * (S - 1) + tris[t] * F + skin_face_row(S, fi, fj)
			}
		}
	}
	return order, !stopped_skin(abort)
}

// Where inside sample (i, j) of a triangle is among its F inside samples.
@(private = "file")
skin_face_row :: #force_inline proc(S, i, j: u32) -> u32 {
	return (j - 1) * (S - 2) - (j - 1) * (j - 2) / 2 + (i - 1)
}

@(private = "file")
stopped_skin :: #force_inline proc(abort: ^bool) -> bool {return abort != nil && sync.atomic_load(abort)}

// Appends the top level's detail skin, when it has one: its tag, segments, counts and
// heights in the file's order. False only when `abort` stopped it.
levels_skin_write :: proc(l: ^Levels, out: ^[dynamic]u8, abort: ^bool = nil) -> bool {
	sk := levels_skin(l)
	if sk == nil do return true
	order, ok := skin_file_order(l, abort)
	if !ok do return false
	geom.byte_put(out, SKIN_TAG)
	geom.byte_put(out, u8(sk.segments))
	geom.byte_put(out, sk.vert_count)
	geom.byte_put(out, sk.edge_count)
	geom.byte_put(out, sk.tri_count)
	to := geom.byte_put_bytes(out, len(sk.heights) * size_of(f16))
	for h, x in sk.heights do intrinsics.unaligned_store(cast(^f16)&to[size_of(f16) * int(order[x])], h)
	geom.byte_put(out, u8(sk.side != nil))
	if sk.side != nil {
		s := &l.levels[len(l.levels) - 1].sculptor
		side := geom.byte_put_bytes(out, len(sk.side) * size_of([3]f16))
		io := Side_Io{side, order}
		skin_side_each(s, sk, proc(s: ^Sculptor, sk: ^Skin, x: u32, tu, tv: Vec3, data: rawptr) {
			io := cast(^Side_Io)data
			sd := sk.side[x]
			v := tu * f32(sd.x) + tv * f32(sd.y)
			intrinsics.unaligned_store(cast(^[3]f16)&io.bytes[size_of([3]f16) * int(io.order[x])], [3]f16{f16(v.x), f16(v.y), f16(v.z)})
		}, &io)
	}
	return !stopped_skin(abort)
}

// What skin_side_each's callbacks read and write in the file.
@(private = "file")
Side_Io :: struct {
	bytes: []u8,
	order: []u32,
}

// Calls `each` once for every sample of the skin with its owner frame (skin_frame), from
// the triangle that owns it.
@(private = "file")
skin_side_each :: proc(s: ^Sculptor, sk: ^Skin, each: proc(s: ^Sculptor, sk: ^Skin, x: u32, tu, tv: Vec3, data: rawptr), data: rawptr) {
	I := s.mesh.indices[:]
	S := sk.segments
	for t in 0 ..< sk.tri_count {
		for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			if skin_owner(s, sk, t, i, j) != t do continue
			_, n := skin_base(s, sk, t, i, j)
			tu, tv := skin_frame(s, sk, t, i, j, linalg.normalize0(n))
			each(s, sk, skin_sample(sk, I, t, i, j), tu, tv, data)
		}
	}
}

// Reads what levels_skin_write wrote onto the levels just read (levels_read), giving the
// top level the skin. False when the skin is damaged or does not fit the top level, which
// is then left without one; the reader has then gone past it either way, or is not ok
// when even its counts are damaged.
levels_skin_read :: proc(l: ^Levels, r: ^geom.Byte_Reader) -> bool {
	if !levels_skin_follows(r) do return false
	_ = geom.byte_get(r, u32)
	segments := u32(geom.byte_get(r, u8))
	V, E, T := geom.byte_get(r, u32), geom.byte_get(r, u32), geom.byte_get(r, u32)
	if !r.ok || segments < 2 || segments > 16 do return false
	S := segments
	count := u64(V) + u64(E) * u64(S - 1) + u64(T) * u64((S - 1) * (S - 2) / 2)
	if u64(len(r.data) - r.at) / size_of(f16) < count {
		r.ok = false
		return false
	}
	heights := geom.byte_get_bytes(r, int(count) * size_of(f16))
	has_side := geom.byte_get(r, u8)
	side: []u8
	if has_side != 0 {
		if u64(len(r.data) - r.at) / size_of([3]f16) < count {
			r.ok = false
			return false
		}
		side = geom.byte_get_bytes(r, int(count) * size_of([3]f16))
	}
	if !r.ok || has_side > 1 || len(l.levels) == 0 do return false
	s := &l.levels[len(l.levels) - 1].sculptor
	if s.dyn != nil || !sculptor_skin_set(s, S) do return false
	sk := s.skin
	if sk.vert_count != V || sk.edge_count != E || sk.tri_count != T {
		sculptor_skin_remove(s)
		return false
	}
	order, ok := skin_file_order(l, nil)
	if !ok {
		sculptor_skin_remove(s)
		return false
	}
	for &h, x in sk.heights {
		v := intrinsics.unaligned_load(cast(^f16)&heights[size_of(f16) * int(order[x])])
		// A height that is not a number is damage: the skin goes.
		if v != v {
			sculptor_skin_remove(s)
			return false
		}
		h = v
		sk.height_max = max(sk.height_max, abs(f32(v)))
	}
	if side != nil {
		skin_side_fit(sk, s.history.allocator)
		bad := false
		io := Side_Io{side, order}
		skin_side_each(s, sk, proc(s: ^Sculptor, sk: ^Skin, x: u32, tu, tv: Vec3, data: rawptr) {
			io := cast(^Side_Io)data
			w := intrinsics.unaligned_load(cast(^[3]f16)&io.bytes[size_of([3]f16) * int(io.order[x])])
			v := Vec3{f32(w.x), f32(w.y), f32(w.z)}
			sk.side[x] = {f16(linalg.dot(v, tu)), f16(linalg.dot(v, tv))}
			sk.height_max = max(sk.height_max, abs(f32(sk.heights[x])) + linalg.length(v))
		}, &io)
		for sd in sk.side do if sd.x != sd.x || sd.y != sd.y do bad = true
		if bad {
			sculptor_skin_remove(s)
			return false
		}
	}
	skin_normals_all(s, sk)
	return true
}
