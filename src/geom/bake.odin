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

// Texels the charts' edges are grown by.
BAKE_DILATE :: 8

Bake_Maps :: struct {
	size:             int,
	normal:           []u8,  // RGBA, rows top to bottom, v = 1 at the top
	displacement:     []f32, // along the light mesh's normal, outward positive
	covered:          int,   // texels inside a chart
	hit:              int,   // of those, texels whose rays found the sculpt
	max_displacement: f32,   // largest distance either way
}

bake_maps_destroy :: proc(b: ^Bake_Maps) {
	delete(b.normal)
	delete(b.displacement)
	b^ = {}
}

// Bakes `source` (with its vertex normals, and `bvh` over its triangles) into maps of
// `size` texels square on the quad mesh `low` laid out by `uvs`. Rays reach `reach`
// either way.
bake_maps :: proc(low: Quad_Mesh, uvs: Uv_Layout, source: Mesh, bvh: ^Bvh, size: int, reach: f32, pool: ^jobs.Pool, allocator := context.allocator) -> (b: Bake_Maps) {
	b.size = size
	texels := size * size
	b.normal = make([]u8, 4 * texels, allocator)
	b.displacement = make([]f32, texels, allocator)
	normals := quad_mesh_normals(low, context.temp_allocator)

	// Tangent and bitangent sums per vertex and chart, from each quad's two triangles.
	slot_of := make(map[u64]u32, len(low.positions), context.temp_allocator)
	corner_slot := make([][4]u32, len(low.quads), context.temp_allocator)
	sums := make([dynamic][2]Vec3, 0, len(low.positions), context.temp_allocator)
	for f, i in low.quads {
		for v, k in f {
			key := u64(v) << 32 | u64(uvs.chart[i])
			slot, found := slot_of[key]
			if !found {
				slot = u32(len(sums))
				append(&sums, [2]Vec3{})
				slot_of[key] = slot
			}
			corner_slot[i][k] = slot
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
				sums[corner_slot[i][k]][0] += tangent
				sums[corner_slot[i][k]][1] += bitangent
			}
		}
	}

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
		sums:        [][2]Vec3,
		corner_slot: [][4]u32,
		owner:       []u32,
		where_:      [][2]f32,
		source:      Mesh,
		bvh:         Bvh,
		reach:       f32,
		filled:      []bool,
		rows_hit:    []int,
		rows_max:    []f32,
	}
	job := Job{&b, low, normals, sums[:], corner_slot, owner, where_, source, bvh^, reach,
		make([]bool, texels, context.temp_allocator), make([]int, size, context.temp_allocator), make([]f32, size, context.temp_allocator)}
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
				p, n, tangent, bitangent: Vec3
				for k in 0 ..< 3 {
					v := f[half[k]]
					p += w[k] * job.low.positions[v]
					n += w[k] * job.normals[v]
					s := job.sums[job.corner_slot[quad][half[k]]]
					tangent += w[k] * s[0]
					bitangent += w[k] * s[1]
				}
				n = linalg.normalize0(n)
				tangent = linalg.normalize0(tangent - linalg.dot(tangent, n) * n)
				handed: f32 = 1 if linalg.dot(linalg.cross(n, tangent), bitangent) >= 0 else -1
				bitangent = handed * linalg.cross(n, tangent)
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
					sn := source_normal(job.source, tri, p + d * n)
					if tangent != {} && sn != {} do shown = linalg.normalize0(Vec3{linalg.dot(sn, tangent), linalg.dot(sn, bitangent), linalg.dot(sn, n)})
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
	dilate(&b, job.filled)
	for at in 0 ..< texels do if b.normal[4 * at + 3] == 0 do put_normal(b.normal[4 * at:], {0, 0, 1})
	return
}

@(private = "file")
put_normal :: #force_inline proc(out: []u8, n: Vec3) {
	for k in 0 ..< 3 do out[k] = u8(clamp((n[k] * 0.5 + 0.5) * 255 + 0.5, 0, 255))
	out[3] = 255
}

// The sculpt's smooth normal at point `p` of triangle `tri`: its vertex normals blended
// by where `p` lies in it.
@(private = "file")
source_normal :: proc(m: Mesh, tri: u32, p: Vec3) -> Vec3 {
	a, b, c := m.indices[3 * tri], m.indices[3 * tri + 1], m.indices[3 * tri + 2]
	pa, pb, pc := m.positions[a], m.positions[b], m.positions[c]
	n := linalg.cross(pb - pa, pc - pa)
	area := linalg.dot(n, n)
	if area == 0 do return linalg.normalize0(m.normals[a])
	wb := linalg.dot(linalg.cross(p - pa, pc - pa), n) / area
	wc := linalg.dot(linalg.cross(pb - pa, p - pa), n) / area
	wa := 1 - wb - wc
	return linalg.normalize0(wa * m.normals[a] + wb * m.normals[b] + wc * m.normals[c])
}

// Grows the charts' edges BAKE_DILATE texels outward: each empty texel next to a filled
// one takes the average of its filled neighbours, a ring at a time.
@(private = "file")
dilate :: proc(b: ^Bake_Maps, filled: []bool) {
	size := b.size
	ring := make([dynamic]int, 0, 1024, context.temp_allocator)
	for _ in 0 ..< BAKE_DILATE {
		clear(&ring)
		for y in 0 ..< size {
			for x in 0 ..< size {
				at := y * size + x
				if filled[at] do continue
				sum: Vec3
				disp: f32
				count := 0
				for dy in -1 ..= 1 {
					for dx in -1 ..= 1 {
						nx, ny := x + dx, y + dy
						if nx < 0 || ny < 0 || nx >= size || ny >= size do continue
						other := ny * size + nx
						if !filled[other] do continue
						for k in 0 ..< 3 do sum[k] += f32(b.normal[4 * other + k]) / 255 * 2 - 1
						disp += b.displacement[other]
						count += 1
					}
				}
				if count == 0 do continue
				put_normal(b.normal[4 * at:], linalg.normalize0(sum))
				b.displacement[at] = disp / f32(count)
				append(&ring, at)
			}
		}
		if len(ring) == 0 do break
		for at in ring do filled[at] = true
	}
}

// The displacement map as 16-bit samples: 32768 is no displacement and the full range
// is ±max_displacement (or ±1 when nothing was displaced).
bake_displacement_samples :: proc(b: Bake_Maps, allocator := context.allocator) -> []u16 {
	out := make([]u16, len(b.displacement), allocator)
	scale := 32767 / b.max_displacement if b.max_displacement > 0 else 0
	for d, i in b.displacement do out[i] = u16(clamp(32768 + d * scale + 0.5, 0, 65535))
	return out
}
