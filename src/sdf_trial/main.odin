// Time-boxed comparison spike, not part of the app: a dense signed-distance grid
// sculpted with sphere dabs and remeshed per dirty chunk with surface nets. It
// prints memory, dab and remesh timings for the same stroke the mesh benchmark uses,
// so the two representations can be compared on equal terms.
package sdf_trial

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strconv"
import "core:time"

Vec3 :: [3]f32

CHUNK :: 16
EXTENT :: 1.5 // grid covers [-EXTENT, EXTENT] on each axis

Grid :: struct {
	n:      int, // voxels per axis (multiple of CHUNK)
	cell:   f32, // world size of one voxel
	dist:   []f32,
	dirty:  []bool, // per chunk
	chunks: int,    // chunks per axis
}

Mesh_Out :: struct {
	positions: [dynamic]Vec3,
	quads:     [dynamic][4]u32,
	cell_vert: []u32, // per voxel cell: vertex index, or max(u32) if none (reused scratch)
}

grid_make :: proc(n: int) -> Grid {
	g := Grid {
		n      = n,
		cell   = 2 * EXTENT / f32(n),
		dist   = make([]f32, n * n * n),
		chunks = n / CHUNK,
	}
	g.dirty = make([]bool, g.chunks * g.chunks * g.chunks)
	for z in 0 ..< n do for y in 0 ..< n do for x in 0 ..< n {
		g.dist[(z * n + y) * n + x] = linalg.length(voxel_pos(g, x, y, z)) - 1
	}
	return g
}

voxel_pos :: #force_inline proc(g: Grid, x, y, z: int) -> Vec3 {
	return {f32(x), f32(y), f32(z)} * g.cell - EXTENT
}

smooth_union :: #force_inline proc(a, b, k: f32) -> f32 {
	h := clamp(0.5 + 0.5 * (b - a) / k, 0, 1)
	return math.lerp(b, a, h) - k * h * (1 - h)
}

// Adds a sphere of `radius` at `center`, blended in. Only voxels within the
// blend band of the sphere change, and their chunks are marked dirty.
apply_dab :: proc(g: ^Grid, center: Vec3, radius: f32) {
	k := radius * 0.5
	reach := radius + k + 2 * g.cell
	lo := [3]int{}
	hi := [3]int{}
	for a in 0 ..< 3 {
		lo[a] = clamp(int((center[a] - reach + EXTENT) / g.cell), 0, g.n - 1)
		hi[a] = clamp(int((center[a] + reach + EXTENT) / g.cell) + 1, 0, g.n)
	}
	n := g.n
	for z in lo[2] ..< hi[2] do for y in lo[1] ..< hi[1] do for x in lo[0] ..< hi[0] {
		i := (z * n + y) * n + x
		s := linalg.length(voxel_pos(g^, x, y, z) - center) - radius
		g.dist[i] = smooth_union(g.dist[i], s, k)
	}
	// A cell reads its +1 neighbours, so the chunk before each touched one is dirty too.
	for cz in max(lo[2] - 1, 0) / CHUNK ..= (hi[2] - 1) / CHUNK {
		for cy in max(lo[1] - 1, 0) / CHUNK ..= (hi[1] - 1) / CHUNK {
			for cx in max(lo[0] - 1, 0) / CHUNK ..= (hi[0] - 1) / CHUNK {
				g.dirty[(cz * g.chunks + cy) * g.chunks + cx] = true
			}
		}
	}
}

// Surface nets over the cells of one chunk: one vertex per cell the surface crosses,
// placed at the mean of its edge crossings, and one quad per crossing edge. Quads
// whose cells straddle a chunk border are emitted by the chunk owning the edge.
remesh_chunk :: proc(g: Grid, cx, cy, cz: int, out: ^Mesh_Out) {
	n := g.n
	x0, y0, z0 := cx * CHUNK, cy * CHUNK, cz * CHUNK
	// The vertex pass covers one extra cell below so border quads can find vertices.
	for z in max(z0 - 1, 0) ..< min(z0 + CHUNK, n - 1) {
		for y in max(y0 - 1, 0) ..< min(y0 + CHUNK, n - 1) {
			for x in max(x0 - 1, 0) ..< min(x0 + CHUNK, n - 1) {
				out.cell_vert[(z * n + y) * n + x] = cell_vertex(g, x, y, z, out)
			}
		}
	}
	for z in z0 ..< min(z0 + CHUNK, n - 1) {
		for y in y0 ..< min(y0 + CHUNK, n - 1) {
			for x in x0 ..< min(x0 + CHUNK, n - 1) {
				emit_quads(g, x, y, z, out)
			}
		}
	}
}

@(private)
cell_vertex :: proc(g: Grid, x, y, z: int, out: ^Mesh_Out) -> u32 {
	n := g.n
	corners: [8]f32
	for c in 0 ..< 8 {
		corners[c] = g.dist[((z + (c >> 2 & 1)) * n + y + (c >> 1 & 1)) * n + x + (c & 1)]
	}
	sum: Vec3
	count: f32
	EDGES :: [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
	for e in EDGES {
		a, b := corners[e[0]], corners[e[1]]
		if (a < 0) == (b < 0) do continue
		t := a / (a - b)
		pa := Vec3{f32(e[0] & 1), f32(e[0] >> 1 & 1), f32(e[0] >> 2 & 1)}
		pb := Vec3{f32(e[1] & 1), f32(e[1] >> 1 & 1), f32(e[1] >> 2 & 1)}
		sum += linalg.lerp(pa, pb, t)
		count += 1
	}
	if count == 0 do return max(u32)
	idx := u32(len(out.positions))
	append(&out.positions, (Vec3{f32(x), f32(y), f32(z)} + sum / count) * g.cell - EXTENT)
	return idx
}

@(private)
emit_quads :: proc(g: Grid, x, y, z: int, out: ^Mesh_Out) {
	n := g.n
	d0 := g.dist[(z * n + y) * n + x]
	// Edges along +x, +y, +z from this voxel; each is shared by four cells.
	dirs := [3][3]int{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	at := [3]int{x, y, z}
	for d, axis in dirs {
		if x + d[0] >= n || y + d[1] >= n || z + d[2] >= n do continue
		d1 := g.dist[((z + d[2]) * n + y + d[1]) * n + x + d[0]]
		if (d0 < 0) == (d1 < 0) do continue
		// The four cells around this edge are offset by -1 on the other two axes.
		u, v := (axis + 1) % 3, (axis + 2) % 3
		if at[u] == 0 || at[v] == 0 do continue
		q: [4]u32
		for k in 0 ..< 4 {
			c := at
			if k == 1 || k == 2 do c[u] -= 1
			if k >= 2 do c[v] -= 1
			q[k] = out.cell_vert[(c.z * n + c.y) * n + c.x]
		}
		if q[0] == max(u32) || q[1] == max(u32) || q[2] == max(u32) || q[3] == max(u32) do continue
		if d0 < 0 do q = {q[3], q[2], q[1], q[0]}
		append(&out.quads, q)
	}
}

remesh_dirty :: proc(g: ^Grid, out: ^Mesh_Out) -> (chunks: int) {
	for cz in 0 ..< g.chunks do for cy in 0 ..< g.chunks do for cx in 0 ..< g.chunks {
		i := (cz * g.chunks + cy) * g.chunks + cx
		if !g.dirty[i] do continue
		g.dirty[i] = false
		remesh_chunk(g^, cx, cy, cz, out)
		chunks += 1
	}
	return
}

main :: proc() {
	n := 128
	if len(os.args) > 1 {
		n = strconv.parse_int(os.args[1]) or_else 128
	}
	n = (n / CHUNK) * CHUNK

	t0 := time.tick_now()
	g := grid_make(n)
	defer delete(g.dist)
	defer delete(g.dirty)
	build_ms := time.duration_milliseconds(time.tick_since(t0))

	out := Mesh_Out{cell_vert = make([]u32, n * n * n)}
	defer delete(out.positions)
	defer delete(out.quads)
	defer delete(out.cell_vert)

	for &d in g.dirty do d = true
	t1 := time.tick_now()
	remesh_dirty(&g, &out)
	full_ms := time.duration_milliseconds(time.tick_since(t1))
	full_tris := 2 * len(out.quads)
	full_verts := len(out.positions)

	// Same stroke shape as the mesh benchmark: a wave across the front of the sphere,
	// 77 dabs of radius 0.13 (the 60 px brush at the default camera distance).
	DABS :: 77
	radius: f32 = 0.13
	dab_ms, remesh_ms: [DABS]f64
	chunks_total := 0
	for i in 0 ..< DABS {
		t := f32(i) / (DABS - 1)
		p := linalg.normalize(Vec3{-0.6 + 1.2 * t, 0.3 * math.sin(t * 4 * math.PI), 1}) * 1.0
		ta := time.tick_now()
		apply_dab(&g, p, radius)
		dab_ms[i] = time.duration_milliseconds(time.tick_since(ta))
		clear(&out.positions)
		clear(&out.quads)
		tb := time.tick_now()
		chunks_total += remesh_dirty(&g, &out)
		remesh_ms[i] = time.duration_milliseconds(time.tick_since(tb))
	}
	p50 :: proc(v: []f64) -> f64 {
		s := make([]f64, len(v), context.temp_allocator)
		copy(s, v)
		for i in 1 ..< len(s) do for j := i; j > 0 && s[j - 1] > s[j]; j -= 1 do s[j - 1], s[j] = s[j], s[j - 1]
		return s[len(s) / 2]
	}
	p99 :: proc(v: []f64) -> f64 {
		m: f64
		for x in v do m = max(m, x)
		return m
	}

	grid_mb := f64(len(g.dist) * size_of(f32)) / (1024 * 1024)
	mesh_mb := f64(full_verts * size_of(Vec3) + full_tris * 3 * size_of(u32)) / (1024 * 1024)
	fmt.printfln("grid=%d^3 voxel=%.4f grid_mb=%.1f build_ms=%.1f", n, g.cell, grid_mb, build_ms)
	fmt.printfln("full_remesh_ms=%.1f vertices=%d triangles=%d mesh_mb=%.1f", full_ms, full_verts, full_tris, mesh_mb)
	fmt.printfln("dabs=%d dab_ms_p50=%.3f dab_ms_max=%.3f", DABS, p50(dab_ms[:]), p99(dab_ms[:]))
	fmt.printfln("remesh_ms_p50=%.3f remesh_ms_max=%.3f chunks_per_dab=%.1f",
		p50(remesh_ms[:]), p99(remesh_ms[:]), f64(chunks_total) / DABS)
}
