package sculpt

import "base:intrinsics"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../geom"

// The detail skin in the scene file, beside the levels (levels_write), as a record
// (Skin_Tag) whose samples run in an order only the top level's topology decides, since
// sculptor_init renumbers vertices, edges and triangles each time a sculptor is built: the
// vertices' samples in the level's file order (level_canon), then each edge's by the file
// places of its ends (lower first), running from the lower end, then each triangle's
// inside samples by tri_canon's order, counted from its corner placed first, keeping its
// winding. The sideways offsets, when the vector page is on, run in the same order, each a
// vector in the mesh's space (three f16), since the owner frame it is kept in depends on
// the numbering the reader builds anew. Normals are worked out again on reading.

// Tags are never reused or retyped (geom/record.odin).
@(private = "file")
Skin_Tag :: enum u16 {
	Segments  = 1, // u8, required: 2 to 16
	Vertices  = 2, // u32, required: the top level's, which the skin must fit
	Edges     = 3, // u32, required
	Triangles = 4, // u32, required
	Heights   = 5, // f16 per sample, required
	Side      = 6, // [3]f16 per sample: the vector page
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

// Appends the top level's detail skin as a record, when it has one: its segments, counts
// and heights in the file's order, and the vector page when it is on. False only when
// `abort` stopped it.
levels_skin_write :: proc(l: ^Levels, out: ^[dynamic]u8, abort: ^bool = nil) -> bool {
	sk := levels_skin(l)
	if sk == nil do return true
	order, ok := skin_file_order(l, abort)
	if !ok do return false
	rec := geom.record_begin(out)
	defer geom.record_end(out, rec)
	geom.rec_put(out, Skin_Tag.Segments, u8(sk.segments))
	geom.rec_put(out, Skin_Tag.Vertices, sk.vert_count)
	geom.rec_put(out, Skin_Tag.Edges, sk.edge_count)
	geom.rec_put(out, Skin_Tag.Triangles, sk.tri_count)
	at := geom.rec_begin(out, Skin_Tag.Heights)
	to := geom.byte_put_bytes(out, len(sk.heights) * size_of(f16))
	geom.rec_end(out, at)
	for h, x in sk.heights do intrinsics.unaligned_store(cast(^f16)&to[size_of(f16) * int(order[x])], h)
	if sk.side != nil {
		s := &l.levels[len(l.levels) - 1].sculptor
		at = geom.rec_begin(out, Skin_Tag.Side)
		side := geom.byte_put_bytes(out, len(sk.side) * size_of([3]f16))
		geom.rec_end(out, at)
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
// when even its record is damaged.
levels_skin_read :: proc(l: ^Levels, r: ^geom.Byte_Reader) -> bool {
	rec := geom.record_take(r)
	if !rec.ok do return false
	if known, _ := geom.record_known(&rec, Skin_Tag); !known do return false
	segments := u32(geom.rec_need(&rec, Skin_Tag.Segments, u8))
	V, E, T := geom.rec_need(&rec, Skin_Tag.Vertices, u32), geom.rec_need(&rec, Skin_Tag.Edges, u32), geom.rec_need(&rec, Skin_Tag.Triangles, u32)
	heights, _ := geom.rec_find(&rec, Skin_Tag.Heights)
	side, has_side := geom.rec_find(&rec, Skin_Tag.Side)
	if !rec.ok || segments < 2 || segments > 16 || len(l.levels) == 0 do return false
	S := segments
	count := u64(V) + u64(E) * u64(S - 1) + u64(T) * u64((S - 1) * (S - 2) / 2)
	if u64(len(heights)) != count * size_of(f16) || (has_side && u64(len(side)) != count * size_of([3]f16)) do return false
	if !has_side do side = nil
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
