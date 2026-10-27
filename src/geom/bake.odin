package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"

import "../jobs"

// Baking a sculpt's detail into maps on a light mesh with UVs, as ZBrush's Multi Map
// Exporter and every baker do: each texel of the light mesh's UV square is a point on
// its surface, and a ray from there along its normal, out and in, finds the sculpt. The
// distance along the normal goes into the displacement map (outward positive), and the
// sculpt's normal there, in the light mesh's tangent frame (its UV directions and its
// normal), into the normal map. The tangent frame is made per vertex from the UVs of
// the quads around it, separately for each chart, and blended across each triangle, as
// the MikkTSpace convention most programs read normal maps with does, though not to the
// bit. Texels outside every chart take the value of the nearest charts' edge for a few
// texels, so filtering at a seam does not pull in the background.
//
// The same hit gives the maps of the bake set when asked for: the sculpt's colour (its
// polypaint over the material of the face hit), its occlusion, roughness and metal in
// glTF's ORM layout, and its polygroups in the viewport's group colours.

// Texels the charts' edges are grown by.
BAKE_DILATE :: 8

// The maps beyond normal and displacement, each made only when asked for.
Bake_Kind :: enum u8 {
	Base_Color, // sRGB: the polypaint over the material's colour
	Orm,        // linear: occlusion, roughness, metallic in red, green and blue
	Id,         // sRGB: each polygroup in its viewport colour
}

// A surface the sculpt's faces are shaded with, in glTF's terms: `base` linear, 0 to 1.
Bake_Surface :: struct {
	base:      [3]f32,
	metallic:  f32,
	roughness: f32,
}

// What a bake reads: the sculpt (with its vertex normals, and `bvh` over its triangles)
// and, for the bake set, what is on it.
Bake_Source :: struct {
	mesh:            Mesh,
	bvh:             ^Bvh,
	paint:           [][4]u8,        // per vertex, sRGB and how far it covers; nil for none
	groups:          []u16,          // per triangle; nil for none (all group 0)
	slots:           []u8,           // per triangle, into `surfaces`; nil for all 0
	surfaces:        []Bake_Surface, // [0] the object's own; none: a light grey
	occlusion_rays:  int,            // per texel; 0 leaves occlusion white
	occlusion_reach: f32,            // hits farther away do not occlude
}

Bake_Maps :: struct {
	size:             int,
	normal:           []u8,  // RGBA, rows top to bottom, v = 1 at the top
	displacement:     []f32, // along the light mesh's normal, outward positive
	base_color:       []u8,  // RGBA each, as Bake_Kind says; nil when not asked for
	orm:              []u8,
	id:               []u8,
	covered:          int,   // texels inside a chart
	hit:              int,   // of those, texels whose rays found the sculpt
	max_displacement: f32,   // largest distance either way
}

bake_maps_destroy :: proc(b: ^Bake_Maps) {
	delete(b.normal)
	delete(b.displacement)
	delete(b.base_color)
	delete(b.orm)
	delete(b.id)
	b^ = {}
}

// Bakes `src` into maps of `size` texels square on the quad mesh `low` laid out by
// `uvs`: normal and displacement always, the others in `kinds`. Rays reach `reach`
// either way.
bake_maps :: proc(low: Quad_Mesh, uvs: Uv_Layout, src: Bake_Source, size: int, reach: f32, kinds: bit_set[Bake_Kind], pool: ^jobs.Pool, allocator := context.allocator) -> (b: Bake_Maps) {
	b.size = size
	texels := size * size
	b.normal = make([]u8, 4 * texels, allocator)
	b.displacement = make([]f32, texels, allocator)
	if .Base_Color in kinds do b.base_color = make([]u8, 4 * texels, allocator)
	if .Orm in kinds do b.orm = make([]u8, 4 * texels, allocator)
	if .Id in kinds do b.id = make([]u8, 4 * texels, allocator)
	source, bvh := src.mesh, src.bvh
	normals := quad_mesh_normals(low, context.temp_allocator)
	frame := quad_mesh_tangents(low, uvs, normals, context.temp_allocator)

	// Which triangle (quad * 2 + half) covers each texel centre, and where in it.
	owner := make([]u32, texels, context.temp_allocator)
	where_ := make([][2]f32, texels, context.temp_allocator)
	NOBODY :: max(u32)
	for &o in owner do o = NOBODY
	fsize := f32(size)
	for i in 0 ..< len(low.quads) {
		for half, h in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
			// Texel (x, y) has its centre at u = (x + 0.5) / size, v = 1 - (y + 0.5) / size.
			c: [3][2]f32
			for k in 0 ..< 3 {
				t := uvs.uvs[i][half[k]]
				c[k] = {t.x * fsize - 0.5, (1 - t.y) * fsize - 0.5}
			}
			area := (c[1].x - c[0].x) * (c[2].y - c[0].y) - (c[2].x - c[0].x) * (c[1].y - c[0].y)
			if abs(area) < 1e-12 do continue
			x0 := max(int(math.floor(min(c[0].x, c[1].x, c[2].x))), 0)
			x1 := min(int(math.ceil(max(c[0].x, c[1].x, c[2].x))), size - 1)
			y0 := max(int(math.floor(min(c[0].y, c[1].y, c[2].y))), 0)
			y1 := min(int(math.ceil(max(c[0].y, c[1].y, c[2].y))), size - 1)
			for y in y0 ..= y1 {
				for x in x0 ..= x1 {
					p := [2]f32{f32(x), f32(y)}
					w1 := ((p.x - c[0].x) * (c[2].y - c[0].y) - (c[2].x - c[0].x) * (p.y - c[0].y)) / area
					w2 := ((c[1].x - c[0].x) * (p.y - c[0].y) - (p.x - c[0].x) * (c[1].y - c[0].y)) / area
					EDGE :: -1e-4
					if w1 < EDGE || w2 < EDGE || 1 - w1 - w2 < EDGE do continue
					owner[y * size + x] = u32(2 * i + h)
					where_[y * size + x] = {w1, w2}
				}
			}
		}
	}

	Job :: struct {
		b:           ^Bake_Maps,
		low:         Quad_Mesh,
		normals:     []Vec3,
		frame:       Quad_Tangents,
		owner:       []u32,
		where_:      [][2]f32,
		source:      Mesh,
		bvh:         Bvh,
		src:         Bake_Source,
		reach:       f32,
		filled:      []bool,
		hits:        []bool,
		linear:      [256]f32,
		rows_hit:    []int,
		rows_max:    []f32,
	}
	job := Job {
		b        = &b,
		low      = low,
		normals  = normals,
		frame    = frame,
		owner    = owner,
		where_   = where_,
		source   = source,
		bvh      = bvh^,
		src      = src,
		reach    = reach,
		filled   = make([]bool, texels, context.temp_allocator),
		hits     = make([]bool, texels, context.temp_allocator),
		rows_hit = make([]int, size, context.temp_allocator),
		rows_max = make([]f32, size, context.temp_allocator),
	}
	for &x, k in job.linear do x = srgb_to_linear(f32(k) / 255)
	jobs.parallel_ranges(pool, size, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		b := job.b
		stack := make([dynamic]u32, 0, 64, runtime.heap_allocator())
		defer delete(stack)
		for y in lo ..< hi {
			for x in 0 ..< b.size {
				at := y * b.size + x
				o := job.owner[at]
				if o == max(u32) do continue
				job.filled[at] = true
				quad := o / 2
				half := [3]int{0, 1, 2} if o % 2 == 0 else [3]int{0, 2, 3}
				f := job.low.quads[quad]
				w := [3]f32{1 - job.where_[at].x - job.where_[at].y, job.where_[at].x, job.where_[at].y}
				// The frame a reader of the exported tangents builds at this point, as
				// MikkTSpace's pixel shader does: normal and tangent blended unnormalized,
				// the bitangent their cross product turned by the handedness.
				p, vn, vt: Vec3
				handed: f32
				for k in 0 ..< 3 {
					v := f[half[k]]
					p += w[k] * job.low.positions[v]
					vn += w[k] * job.normals[v]
					t := job.frame.tangents[job.frame.corner_slot[quad][half[k]]]
					vt += w[k] * t.xyz
					handed += w[k] * t.w
				}
				turned: f32 = 1 if handed >= 0 else -1
				vb := turned * linalg.cross(vn, vt)
				n := linalg.normalize0(vn)
				shown := Vec3{0, 0, 1}
				// Each ray starts a little behind the texel's point, so a surface right at
				// it is hit by one of them.
				back := 1e-3 * job.reach
				out_t, out_tri, out_hit := bvh_raycast_with(job.bvh, job.source, p - back * n, n, job.reach + back, &stack)
				in_t, in_tri, in_hit := bvh_raycast_with(job.bvh, job.source, p + back * n, -n, job.reach + back, &stack)
				out_t -= back
				in_t -= back
				d: f32
				tri: u32
				hit := true
				switch {
				case out_hit && (!in_hit || abs(out_t) <= abs(in_t)): d, tri = out_t, out_tri
				case in_hit:                                          d, tri = -in_t, in_tri
				case:                                                 hit = false
				}
				if hit {
					job.rows_hit[y] += 1
					job.rows_max[y] = max(job.rows_max[y], abs(d))
					b.displacement[at] = d
					at_hit := p + d * n
					weights := triangle_weights(job.source, tri, at_hit)
					sn := source_normal(job.source, tri, weights)
					// The sculpt's normal in that frame: what the reader's frame turns back
					// into it (the reciprocal basis, as the frame need not be orthogonal).
					det := linalg.dot(vt, linalg.cross(vb, vn))
					if abs(det) > 1e-20 && sn != {} {
						shown = linalg.normalize0(Vec3{linalg.dot(linalg.cross(vb, vn), sn), linalg.dot(linalg.cross(vn, vt), sn), linalg.dot(linalg.cross(vt, vb), sn)} / det)
					}
					job.hits[at] = true
					bake_surface_texel(b, job.src, &job.linear, at, tri, weights, at_hit, &stack)
				}
				put_normal(b.normal[4 * at:], shown)
			}
		}
	}, 8)
	for y in 0 ..< size {
		b.hit += job.rows_hit[y]
		b.max_displacement = max(b.max_displacement, job.rows_max[y])
	}
	for f in job.filled do if f do b.covered += 1
	// Normal and displacement grow from every texel in a chart (one whose rays missed
	// keeps a flat normal and no displacement); the set's maps only from texels that
	// found the sculpt, since a miss has nothing to show.
	dilate(&b, job.filled, surface = false)
	for at in 0 ..< texels do if b.normal[4 * at + 3] == 0 do put_normal(b.normal[4 * at:], {0, 0, 1})
	dilate(&b, job.hits, surface = true)
	// What is still empty shows the object's own material, open to the sky.
	first := src.surfaces[0] if len(src.surfaces) > 0 else source_surface({}, 0)
	empty_color := srgb_bytes(first.base)
	for at in 0 ..< texels {
		if b.base_color != nil && b.base_color[4 * at + 3] == 0 do put4(b.base_color[4 * at:], {empty_color.r, empty_color.g, empty_color.b, 255})
		if b.orm != nil && b.orm[4 * at + 3] == 0 do put4(b.orm[4 * at:], orm_bytes(1, first))
		if b.id != nil && b.id[4 * at + 3] == 0 {
			c := group_color_srgb(0)
			put4(b.id[4 * at:], {c.r, c.g, c.b, 255})
		}
	}
	return
}

// The tangent frame of `low` laid out by `uvs` (with vertex normals `normals`), which the
// bake reads normal maps in and the glTF export writes, so a reader that uses the file's
// tangents turns the map back into the sculpt's normals. A chart is flat, so a vertex has
// one UV in each chart it is in: each such (vertex, chart) is a slot with a tangent of its
// own, the sum of its triangles' UV tangents made square to the vertex normal and of unit
// length, w the side the UV bitangent (toward +v) is on: bitangent = w × cross(normal,
// tangent). A slot whose triangles have no UV area gets any tangent square to its normal.
Quad_Tangents :: struct {
	tangents:    [][4]f32, // per slot
	vertex:      []u32,    // per slot: its vertex
	corner_slot: [][4]u32, // per quad corner: its slot
}

quad_mesh_tangents :: proc(low: Quad_Mesh, uvs: Uv_Layout, normals: []Vec3, allocator := context.allocator) -> (q: Quad_Tangents) {
	// Slots in the order their first corner comes; the map is only looked up.
	slot_of := make(map[u64]u32, len(low.positions), context.temp_allocator)
	q.corner_slot = make([][4]u32, len(low.quads), allocator)
	vertex := make([dynamic]u32, 0, len(low.positions), allocator)
	sums := make([dynamic][2]Vec3, 0, len(low.positions), context.temp_allocator)
	for f, i in low.quads {
		for v, k in f {
			key := u64(v) << 32 | u64(uvs.chart[i])
			slot, found := slot_of[key]
			if !found {
				slot = u32(len(sums))
				append(&sums, [2]Vec3{})
				append(&vertex, v)
				slot_of[key] = slot
			}
			q.corner_slot[i][k] = slot
		}
		for half in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
			p0, p1, p2 := low.positions[f[half[0]]], low.positions[f[half[1]]], low.positions[f[half[2]]]
			t0, t1, t2 := uvs.uvs[i][half[0]], uvs.uvs[i][half[1]], uvs.uvs[i][half[2]]
			e1, e2 := p1 - p0, p2 - p0
			d1, d2 := t1 - t0, t2 - t0
			det := d1.x * d2.y - d2.x * d1.y
			if abs(det) < 1e-20 do continue
			r := 1 / det
			tangent := (e1 * d2.y - e2 * d1.y) * r
			bitangent := (e2 * d1.x - e1 * d2.x) * r
			for k in half {
				sums[q.corner_slot[i][k]][0] += tangent
				sums[q.corner_slot[i][k]][1] += bitangent
			}
		}
	}
	q.vertex = vertex[:]
	q.tangents = make([][4]f32, len(sums), allocator)
	for sum, slot in sums {
		n := normals[q.vertex[slot]]
		t := linalg.normalize0(sum[0] - linalg.dot(sum[0], n) * n)
		if t == {} do t, _ = perpendicular_pair(n)
		w: f32 = 1 if linalg.dot(linalg.cross(n, t), sum[1]) >= 0 else -1
		q.tangents[slot] = {t.x, t.y, t.z, w}
	}
	return
}

// The quad mesh `low` as triangles for a file that carries its UVs (a glTF): a vertex per
// slot of `frame` (each vertex once in each chart it is in), with its position, its
// smooth normal from `normals`, its UV and its tangent, and each quad as the two
// triangles the bake rasterizes (corners 0 1 2 and 0 2 3). Made with `allocator`.
quad_mesh_split_uvs :: proc(low: Quad_Mesh, uvs: Uv_Layout, normals: []Vec3, frame: Quad_Tangents, allocator := context.allocator) -> (positions, split_normals: []Vec3, texcoords: [][2]f32, indices: []u32) {
	slots := len(frame.vertex)
	positions = make([]Vec3, slots, allocator)
	split_normals = make([]Vec3, slots, allocator)
	texcoords = make([][2]f32, slots, allocator)
	for v, slot in frame.vertex do positions[slot], split_normals[slot] = low.positions[v], normals[v]
	indices = make([]u32, 6 * len(low.quads), allocator)
	for f, i in frame.corner_slot {
		for k in 0 ..< 4 do texcoords[f[k]] = uvs.uvs[i][k]
		copy(indices[6 * i:], []u32{f[0], f[1], f[2], f[0], f[2], f[3]})
	}
	return
}

quad_tangents_destroy :: proc(q: ^Quad_Tangents, allocator := context.allocator) {
	delete(q.tangents, allocator)
	delete(q.vertex, allocator)
	delete(q.corner_slot, allocator)
	q^ = {}
}

// Two unit directions square to unit `n` and to each other (Duff et al.'s, with no
// division by zero); (1, 0, 0) and (0, 1, 0) for no direction.
perpendicular_pair :: proc(n: Vec3) -> (x, y: Vec3) {
	if n == {} do return {1, 0, 0}, {0, 1, 0}
	sign: f32 = 1 if n.z >= 0 else -1
	a := -1 / (sign + n.z)
	b := n.x * n.y * a
	return {1 + sign * n.x * n.x * a, sign * b, -sign * n.x}, {b, sign + n.y * n.y * a, -n.y}
}

@(private = "file")
put_normal :: #force_inline proc(out: []u8, n: Vec3) {
	for k in 0 ..< 3 do out[k] = u8(clamp((n[k] * 0.5 + 0.5) * 255 + 0.5, 0, 255))
	out[3] = 255
}

// Where point `p` lies in triangle `tri`: the weights of its three corners, (1, 0, 0)
// for a triangle with no area.
@(private)
triangle_weights :: proc(m: Mesh, tri: u32, p: Vec3) -> [3]f32 {
	a, b, c := m.indices[3 * tri], m.indices[3 * tri + 1], m.indices[3 * tri + 2]
	pa, pb, pc := m.positions[a], m.positions[b], m.positions[c]
	n := linalg.cross(pb - pa, pc - pa)
	area := linalg.dot(n, n)
	if area == 0 do return {1, 0, 0}
	wb := linalg.dot(linalg.cross(p - pa, pc - pa), n) / area
	wc := linalg.dot(linalg.cross(pb - pa, p - pa), n) / area
	return {1 - wb - wc, wb, wc}
}

// The sculpt's smooth normal in triangle `tri` at corner weights `w`.
@(private)
source_normal :: proc(m: Mesh, tri: u32, w: [3]f32) -> Vec3 {
	a, b, c := m.indices[3 * tri], m.indices[3 * tri + 1], m.indices[3 * tri + 2]
	return linalg.normalize0(w[0] * m.normals[a] + w[1] * m.normals[b] + w[2] * m.normals[c])
}

// The surface of source triangle `tri`.
@(private = "file")
source_surface :: proc(src: Bake_Source, tri: u32) -> Bake_Surface {
	if len(src.surfaces) == 0 do return {base = 0.6, roughness = 0.5}
	slot := int(src.slots[tri]) if src.slots != nil else 0
	return src.surfaces[slot if slot < len(src.surfaces) else 0]
}

// Writes texel `at` of the bake set's maps from the hit at corner weights `w` of source
// triangle `tri`, point `p`. `linear` decodes sRGB bytes.
@(private = "file")
bake_surface_texel :: proc(b: ^Bake_Maps, src: Bake_Source, linear: ^[256]f32, at: int, tri: u32, w: [3]f32, p: Vec3, stack: ^[dynamic]u32) {
	m := src.mesh
	surface := source_surface(src, tri)
	if b.base_color != nil {
		// As the viewport shows it: each corner's paint decoded to linear light, blended
		// across the triangle with its coverage, laid over the material's colour, and
		// encoded once.
		color := surface.base
		if src.paint != nil {
			paint: [3]f32
			cover: f32
			for k in 0 ..< 3 {
				c := src.paint[m.indices[3 * int(tri) + k]]
				for ch in 0 ..< 3 do paint[ch] += w[k] * linear[c[ch]]
				cover += w[k] * f32(c.a) / 255
			}
			cover = clamp(cover, 0, 1)
			color = linalg.lerp(color, paint, cover)
		}
		out := srgb_bytes(color)
		put4(b.base_color[4 * at:], {out.r, out.g, out.b, 255})
	}
	if b.orm != nil {
		open := f32(1)
		if rays := src.occlusion_rays; rays > 0 {
			// Around the face's own normal: a ray leaving a face on its open side meets
			// no neighbour of a convex surface, as one around the smooth normal can.
			a, bb, c := m.positions[m.indices[3 * tri]], m.positions[m.indices[3 * tri + 1]], m.positions[m.indices[3 * tri + 2]]
			n := linalg.normalize0(linalg.cross(bb - a, c - a))
			if n != {} {
				blocked := 0
				tx, ty := perpendicular_pair(n)
				// The pattern turned by an angle from the texel alone, so any split of the
				// rows into jobs bakes the same.
				turn := f32(texel_hash(u32(at))) / f32(max(u32)) * 2 * math.PI
				lift := p + 1e-4 * max(src.occlusion_reach, 1e-6) * n
				for i in 0 ..< rays {
					u := (f32(i) + 0.5) / f32(rays)
					phi := 2 * math.PI * radical_inverse(u32(i)) + turn
					r := math.sqrt(u)
					dir := r * math.cos(phi) * tx + r * math.sin(phi) * ty + math.sqrt(1 - u) * n
					if bvh_any_hit(src.bvh^, m, lift, dir, src.occlusion_reach, stack) do blocked += 1
				}
				open = 1 - f32(blocked) / f32(rays)
			}
		}
		put4(b.orm[4 * at:], orm_bytes(open, surface))
	}
	if b.id != nil {
		c := group_color_srgb(src.groups[tri] if src.groups != nil else 0)
		put4(b.id[4 * at:], {c.r, c.g, c.b, 255})
	}
}

@(private = "file")
put4 :: #force_inline proc(out: []u8, v: [4]u8) {
	out[0], out[1], out[2], out[3] = v[0], v[1], v[2], v[3]
}

// A linear colour as sRGB bytes.
@(private = "file")
srgb_bytes :: proc(c: [3]f32) -> (out: [3]u8) {
	for k in 0 ..< 3 do out[k] = u8(math.round(srgb_from_linear(clamp(c[k], 0, 1)) * 255))
	return
}

// An ORM texel: how open the point is (1: nothing occludes it), the surface's roughness
// and metal.
@(private = "file")
orm_bytes :: proc(open: f32, s: Bake_Surface) -> [4]u8 {
	return {u8(math.round(clamp(open, 0, 1) * 255)), u8(math.round(clamp(s.roughness, 0, 1) * 255)), u8(math.round(clamp(s.metallic, 0, 1) * 255)), 255}
}

// Van der Corput's sequence: i's bits mirrored about the point, 0 to 1.
@(private = "file")
radical_inverse :: proc(i: u32) -> f32 {
	x := i
	x = (x << 16) | (x >> 16)
	x = ((x & 0x55555555) << 1) | ((x & 0xAAAAAAAA) >> 1)
	x = ((x & 0x33333333) << 2) | ((x & 0xCCCCCCCC) >> 2)
	x = ((x & 0x0F0F0F0F) << 4) | ((x & 0xF0F0F0F0) >> 4)
	x = ((x & 0x00FF00FF) << 8) | ((x & 0xFF00FF00) >> 8)
	return f32(x) * (1.0 / 4294967296.0)
}

// A well-mixed number from a texel's index (the "lowbias32" hash).
@(private = "file")
texel_hash :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return h
}

// The viewport's colour for polygroup `g` (mesh.vert's group_color), as sRGB bytes: hues
// a golden angle apart, in two lightnesses.
group_color_srgb :: proc(g: u16) -> (out: [3]u8) {
	h := f32(g) * 0.618034 + 0.12
	h -= math.floor(h)
	light: f32 = 0.75 if g & 1 == 0 else 0.55
	offset := [3]f32{0, 2, 1}
	for k in 0 ..< 3 {
		x := h + offset[k] / 3
		x -= math.floor(x)
		rgb := clamp(abs(x * 6 - 3) - 1, 0, 1)
		linear := (1 + 0.55 * (rgb - 1)) * light
		out[k] = u8(math.round(srgb_from_linear(linear) * 255))
	}
	return
}

// The sRGB value of a linear channel, both 0 to 1.
srgb_from_linear :: proc(c: f32) -> f32 {
	return c * 12.92 if c <= 0.0031308 else 1.055 * math.pow(c, 1 / 2.4) - 0.055
}


// Grows the charts' edges BAKE_DILATE texels outward: each empty texel next to a filled
// one takes the average of its filled neighbours, a ring at a time; in the ID map the
// colour most of them have (the first in reading order on a tie), so no new colour
// appears between two groups.
@(private = "file")
dilate :: proc(b: ^Bake_Maps, filled: []bool, surface: bool) {
	size := b.size
	ring := make([dynamic]int, 0, 1024, context.temp_allocator)
	for _ in 0 ..< BAKE_DILATE {
		clear(&ring)
		for y in 0 ..< size {
			for x in 0 ..< size {
				at := y * size + x
				if filled[at] do continue
				if surface && b.base_color == nil && b.orm == nil && b.id == nil do return
				sum: Vec3
				disp: f32
				color, orm: [4]u32
				count := 0
				near: [8]int
				for dy in -1 ..= 1 {
					for dx in -1 ..= 1 {
						nx, ny := x + dx, y + dy
						if nx < 0 || ny < 0 || nx >= size || ny >= size do continue
						other := ny * size + nx
						if !filled[other] do continue
						for k in 0 ..< 3 do sum[k] += f32(b.normal[4 * other + k]) / 255 * 2 - 1
						disp += b.displacement[other]
						for k in 0 ..< 4 {
							if b.base_color != nil do color[k] += u32(b.base_color[4 * other + k])
							if b.orm != nil do orm[k] += u32(b.orm[4 * other + k])
						}
						near[count] = other
						count += 1
					}
				}
				if count == 0 do continue
				append(&ring, at)
				if !surface {
					put_normal(b.normal[4 * at:], linalg.normalize0(sum))
					b.displacement[at] = disp / f32(count)
					continue
				}
				half := u32(count) / 2
				for k in 0 ..< 4 {
					if b.base_color != nil do b.base_color[4 * at + k] = u8((color[k] + half) / u32(count))
					if b.orm != nil do b.orm[4 * at + k] = u8((orm[k] + half) / u32(count))
				}
				if b.id != nil {
					best, most := near[0], 0
					for i in 0 ..< count {
						same := 0
						for j in 0 ..< count do if mem_equal4(b.id[4 * near[i]:], b.id[4 * near[j]:]) do same += 1
						if same > most do best, most = near[i], same
					}
					copy(b.id[4 * at:][:4], b.id[4 * best:][:4])
				}
			}
		}
		if len(ring) == 0 do break
		for at in ring do filled[at] = true
	}
}

@(private = "file")
mem_equal4 :: #force_inline proc(a, b: []u8) -> bool {
	return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]
}

// The displacement map as 16-bit samples: 32768 is no displacement and the full range
// is ±max_displacement (or ±1 when nothing was displaced).
bake_displacement_samples :: proc(b: Bake_Maps, allocator := context.allocator) -> []u16 {
	out := make([]u16, len(b.displacement), allocator)
	scale := 32767 / b.max_displacement if b.max_displacement > 0 else 0
	for d, i in b.displacement do out[i] = u16(clamp(32768 + d * scale + 0.5, 0, 65535))
	return out
}
