package sculpt

import "core:math"
import "core:math/linalg"

import "../geom"
import "../jobs"

// Maps in: a displacement or vector displacement image, laid over an object through its
// UVs, read into its detail skin, as ZBrush's Displacement and Vector Displacement Map
// import does. Each sample of the skin finds its UV where it lies in its owner triangle
// (the vertex's first, the edge's lower, or its own), reads the image there (bilinear),
// and becomes the point the image puts it at, over the curved base the skin is lit over
// (skin_curve), so a map baked from this surface comes back as it went out.

// What an image holds.
Skin_Map_Kind :: enum u8 {
	Height,         // a distance along the normal, outward positive (the image's first channel)
	Tangent_Vector, // an offset in the tangent frame: tangent, bitangent toward +v, normal
	Object_Vector,  // an offset in the object's own axes
}

// An image to read: rows top to bottom (v = 1 at the top), each pixel's value
// (pixel - mid) * scale, in the object's units.
Skin_Map :: struct {
	width, height: int,
	pixels:        [][3]f32,
	kind:          Skin_Map_Kind,
	mid, scale:    f32,
}

// Per triangle of the mesh, its corners' UVs and tangents (xyz, and in w the side the
// bitangent is on: bitangent = w × cross(normal, tangent)), in the triangle's own corner
// order: levels_tri_uvs.
Skin_Uvs :: struct {
	uv:      [][3][2]f32,
	tangent: [][3][4]f32,
}

// Replaces the skin's heights (and vector page) with what `m` holds over `uvs`, as one
// undo step. False, with nothing changed, without a skin or under dynamic topology.
sculptor_skin_from_map :: proc(s: ^Sculptor, m: Skin_Map, uvs: Skin_Uvs) -> bool {
	old := s.skin
	if old == nil || s.dyn != nil || len(uvs.uv) != int(old.tri_count) do return false
	_ = sculptor_stroke_end(s)
	made, ok := skin_make(s, old.segments, s.history.allocator)
	if !ok do return false
	next := new_clone(made, s.history.allocator)
	n := len(next.heights)
	side := make([][2]f32, n, context.temp_allocator)
	Job :: struct {
		s:    ^Sculptor,
		sk:   ^Skin,
		m:    Skin_Map,
		uvs:  Skin_Uvs,
		side: [][2]f32,
	}
	job := Job{s, next, m, uvs, side}
	// Each sample is written by the triangle that owns it.
	jobs.parallel_ranges(s.pool, int(next.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s, sk := job.s, job.sk
		I := s.mesh.indices[:]
		N := s.mesh.normals[:]
		S := sk.segments
		for t in u32(lo) ..< u32(hi) do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			if !skin_owns(s, sk, t, i, j) do continue
			w := [3]f32{1 - f32(i) / f32(S) - f32(j) / f32(S), f32(i) / f32(S), f32(j) / f32(S)}
			uv: [2]f32
			for k in 0 ..< 3 do uv += job.uvs.uv[t][k] * w[k]
			v := skin_map_sample(job.m, uv)
			p, nb := skin_base(s, sk, t, i, j)
			nu := linalg.normalize0(nb)
			off: Vec3
			switch job.m.kind {
			case .Height:
				off = nu * v.x
			case .Object_Vector:
				off = v
			case .Tangent_Vector:
				// The frame a reader of the tangents builds, as the bake writes it.
				vn, vt: Vec3
				handed: f32
				for k in 0 ..< 3 {
					vn += N[I[3 * t + u32(k)]] * w[k]
					vt += job.uvs.tangent[t][k].xyz * w[k]
					handed += job.uvs.tangent[t][k].w * w[k]
				}
				vb := (f32(1) if handed >= 0 else -1) * linalg.cross(vn, vt)
				off = vt * v.x + vb * v.y + vn * v.z
			}
			off -= skin_curve(s, sk, t, i, j, p, nu)
			x := skin_sample(sk, I, t, i, j)
			sk.heights[x] = f16(linalg.dot(off, nu))
			if job.m.kind != .Height {
				tu, tv := skin_frame(s, sk, t, i, j, nu)
				job.side[x] = {linalg.dot(off, tu), linalg.dot(off, tv)}
			}
		}
	}, 1 << 10)
	most: f32
	for sd in side do most = max(most, abs(sd.x), abs(sd.y))
	if most > 1e-6 {
		skin_side_fit(next, s.history.allocator)
		for sd, x in side do next.side[x] = {f16(sd.x), f16(sd.y)}
	}
	for h, x in next.heights {
		r := abs(f32(h))
		if next.side != nil do r += abs(f32(next.side[x].x)) + abs(f32(next.side[x].y))
		next.height_max = max(next.height_max, r)
	}
	sculptor_stroke_begin(s)
	s.history.current.skin_op = {active = true, skin = s.skin}
	s.skin = next
	s.skin_stamp += 1
	skin_spheres_all(s, next)
	for id in 0 ..< u32(len(s.nodes)) do skin_mark(s, id)
	return sculptor_stroke_end(s)
}

// The map's value at `uv`, bilinear between texel centres, clamped at the image's edges.
@(private = "file")
skin_map_sample :: proc(m: Skin_Map, uv: [2]f32) -> Vec3 {
	if m.width <= 0 || m.height <= 0 do return {}
	fx := clamp(uv.x * f32(m.width) - 0.5, 0, f32(m.width - 1))
	fy := clamp((1 - uv.y) * f32(m.height) - 0.5, 0, f32(m.height - 1))
	x0, y0 := int(fx), int(fy)
	x1, y1 := min(x0 + 1, m.width - 1), min(y0 + 1, m.height - 1)
	ax, ay := fx - f32(x0), fy - f32(y0)
	at :: #force_inline proc(m: Skin_Map, x, y: int) -> Vec3 {return m.pixels[y * m.width + x]}
	top := math.lerp(at(m, x0, y0), at(m, x1, y0), ax)
	bottom := math.lerp(at(m, x0, y1), at(m, x1, y1), ax)
	return (math.lerp(top, bottom, ay) - m.mid) * m.scale
}

// The UVs and tangents of the object's triangles, from its quads' (Quad_Faces), for
// sculptor_skin_from_map; ok is false unless the object has UVs and one level (its quads
// are the base level's, and the skin lies on the top one). In `allocator`.
levels_tri_uvs :: proc(l: ^Levels, allocator := context.allocator) -> (out: Skin_Uvs, ok: bool) {
	if !levels_has_uvs(l) || len(l.levels) != 1 do return
	base := l.levels[0]
	s := &base.sculptor
	q := levels_quad_mesh(l, context.temp_allocator)
	normals := geom.quad_mesh_normals(q, context.temp_allocator)
	frame := geom.quad_mesh_tangents(q, l.faces.uv, normals, context.temp_allocator)
	tris := len(s.mesh.indices) / 3
	out.uv = make([][3][2]f32, tris, allocator)
	out.tangent = make([][3][4]f32, tris, allocator)
	found := make([]bool, tris, context.temp_allocator)
	I := s.mesh.indices[:]
	for f, qi in q.quads {
		for half in geom.quad_halves(q, qi) {
			a, b, c := f[half[0]], f[half[1]], f[half[2]]
			for t in faces_of(s, a) {
				tri := I[3 * t:][:3]
				has :: proc(tri: []u32, v: u32) -> bool {return tri[0] == v || tri[1] == v || tri[2] == v}
				if !has(tri, b) || !has(tri, c) do continue
				for k in 0 ..< 3 do for h in 0 ..< 3 do if f[half[h]] == tri[k] {
					out.uv[t][k] = l.faces.uv.uvs[qi][half[h]]
					out.tangent[t][k] = frame.tangents[frame.corner_slot[qi][half[h]]]
				}
				found[t] = true
				break
			}
		}
	}
	for f in found do if !f {
		delete(out.uv, allocator)
		delete(out.tangent, allocator)
		return {}, false
	}
	return out, true
}

// The skin as a displacement micro-map (geom.Bary_Mesh's values): per triangle, the grid
// vertices in bird-curve order, each the distance along the mesh's interpolated vertex
// normal (not normalised, as the file's directions are) from the flat triangle to the
// point the skin shows, its curved base included. A sample shared by triangles is worked
// out once, so neighbours agree along their edges. `folded` says the skin had sideways
// offsets, which a scalar map cannot hold and are left out. Not ok without a skin.
sculptor_skin_bary :: proc(s: ^Sculptor, allocator := context.allocator) -> (values: []f32, level: u32, folded, ok: bool) {
	sk := s.skin
	if sk == nil || sk.segments & (sk.segments - 1) != 0 do return
	for u32(1) << level < sk.segments do level += 1
	along := make([]f32, len(sk.heights), context.temp_allocator)
	Job :: struct {
		s:     ^Sculptor,
		along: []f32,
	}
	job := Job{s, along}
	// Each sample is written by the triangle that owns it.
	jobs.parallel_ranges(s.pool, int(sk.tri_count), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		sk := s.skin
		I := s.mesh.indices[:]
		S := sk.segments
		for t in u32(lo) ..< u32(hi) do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			if !skin_owns(s, sk, t, i, j) do continue
			p, nb := skin_base(s, sk, t, i, j)
			nu := linalg.normalize0(nb)
			x := skin_sample(sk, I, t, i, j)
			off := nu * f32(sk.heights[x]) + skin_curve(s, sk, t, i, j, p, nu)
			d := linalg.dot(nb, nb)
			job.along[x] = linalg.dot(off, nb) / d if d > 1e-12 else 0
		}
	}, 1 << 10)
	S := sk.segments
	per := u32(geom.bary_vertex_count(level))
	values = make([]f32, int(sk.tri_count * per), allocator)
	I := s.mesh.indices[:]
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		values[t * per + geom.bary_bird_index(i, j, level)] = along[skin_sample(sk, I, t, i, j)]
	}
	if sk.side != nil do for sd in sk.side do if sd != {} {
		folded = true
		break
	}
	return values, level, folded, true
}
