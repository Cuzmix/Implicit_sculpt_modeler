// Time-boxed comparison spike, not part of the app: the Draw brush's hot loops written
// the same way in Odin (this file) and in Dart (dart/bin/kernel.dart), run over the
// same mesh and stroke, so the cost of moving the sculpt core to Dart can be read off
// one table. The mesh is a cube-sphere cut into independent 16 x 16 quad tiles, each
// tile a node owning a contiguous vertex range and its 512 triangles, like the
// sculptor's nodes; a dab finds the nodes its sphere reaches, takes the weighted area
// normal over them, moves their vertices along it, and once a frame the touched nodes
// recompute their vertex normals from their faces. Both versions print the same
// checksum, which proves they did the same work.
package dart_trial

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import "../jobs"

Vec3 :: [3]f32

TILE :: 16 // quads per tile side
TILE_VERTS :: (TILE + 1) * (TILE + 1)
TILE_TRIS :: TILE * TILE * 2
DABS :: 77 // the stroke the mesh benchmark uses
DABS_PER_FRAME :: 4
RADIUS :: f32(0.13)
STRENGTH :: f32(0.3)
DRAW_HEIGHT :: f32(0.1) // displacement at the centre, in radii at full strength

Mesh :: struct {
	tiles:     int, // tiles per cube-face side
	positions: []Vec3,
	normals:   []Vec3,
	tris:      [][3]u32, // global vertex indices, as a real mesh stores them
	bounds:    [][2]Vec3, // per node: min, max
	touched:   []bool,
}

// Builds the cube-sphere with `tiles` x `tiles` tiles per cube face, in the order the
// Dart version builds it.
mesh_make :: proc(tiles: int) -> Mesh {
	nodes := 6 * tiles * tiles
	m := Mesh {
		tiles     = tiles,
		positions = make([]Vec3, nodes * TILE_VERTS),
		normals   = make([]Vec3, nodes * TILE_VERTS),
		tris      = make([][3]u32, nodes * TILE_TRIS),
		bounds    = make([][2]Vec3, nodes),
		touched   = make([]bool, nodes),
	}
	side := f32(tiles * TILE)
	for face in 0 ..< 6 {
		for ti in 0 ..< tiles {
			for tj in 0 ..< tiles {
				node := (face * tiles + ti) * tiles + tj
				base := node * TILE_VERTS
				for a in 0 ..= TILE {
					for b in 0 ..= TILE {
						u := f32(ti * TILE + a) / side * 2 - 1
						v := f32(tj * TILE + b) / side * 2 - 1
						p: Vec3
						switch face {
						case 0: p = {1, u, v}
						case 1: p = {-1, v, u}
						case 2: p = {u, 1, v}
						case 3: p = {v, -1, u}
						case 4: p = {u, v, 1}
						case: p = {v, u, -1}
						}
						p = linalg.normalize(p)
						i := base + a * (TILE + 1) + b
						m.positions[i] = p
						m.normals[i] = p
					}
				}
				t := node * TILE_TRIS
				for a in 0 ..< TILE {
					for b in 0 ..< TILE {
						i := u32(base + a * (TILE + 1) + b)
						m.tris[t] = {i, i + TILE + 1, i + 1}
						m.tris[t + 1] = {i + 1, i + TILE + 1, i + TILE + 2}
						t += 2
					}
				}
				node_bounds(&m, node)
			}
		}
	}
	return m
}

mesh_destroy :: proc(m: ^Mesh) {
	delete(m.positions)
	delete(m.normals)
	delete(m.tris)
	delete(m.bounds)
	delete(m.touched)
	m^ = {}
}

node_bounds :: proc(m: ^Mesh, node: int) {
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	for p in m.positions[node * TILE_VERTS:][:TILE_VERTS] {
		lo = linalg.min(lo, p)
		hi = linalg.max(hi, p)
	}
	m.bounds[node] = {lo, hi}
}

falloff :: #force_inline proc(x2: f32) -> f32 {
	if x2 >= 1 do return 0
	t := 1 - x2
	return t * t
}

// Shared read-only by the workers during one phase of a dab or a frame.
Dab :: struct {
	m:       ^Mesh,
	hit:     []u32,
	center:  Vec3,
	normal:  Vec3,
	sums:    []Vec3, // per hit node: weighted normal sum (area phase)
	moved:   []u32,  // per hit node: vertices moved (displace phase)
	nodes:   []u32,  // touched nodes (normals phase)
}

job_area :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	m := d.m
	first := int(d.hit[i]) * TILE_VERTS
	inv_r2 := 1 / (RADIUS * RADIUS)
	sum: Vec3
	for v in first ..< first + TILE_VERTS {
		delta := m.positions[v] - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < RADIUS * RADIUS do sum += m.normals[v] * falloff(d2 * inv_r2)
	}
	d.sums[i] = sum
}

job_displace :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	m := d.m
	node := int(d.hit[i])
	first := node * TILE_VERTS
	inv_r2 := 1 / (RADIUS * RADIUS)
	amount := STRENGTH * DRAW_HEIGHT * RADIUS
	moved: u32
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	for v in first ..< first + TILE_VERTS {
		p := m.positions[v]
		delta := p - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < RADIUS * RADIUS {
			w := falloff(d2 * inv_r2)
			if w > 0 {
				p += d.normal * (amount * w)
				m.positions[v] = p
				moved += 1
			}
		}
		lo = linalg.min(lo, p)
		hi = linalg.max(hi, p)
	}
	m.bounds[node] = {lo, hi}
	d.moved[i] = moved
	if moved > 0 do m.touched[node] = true
}

job_normals :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	m := d.m
	node := int(d.nodes[i])
	first := node * TILE_VERTS
	for &n in m.normals[first:][:TILE_VERTS] do n = {}
	for t in m.tris[node * TILE_TRIS:][:TILE_TRIS] {
		a, b, c := m.positions[t[0]], m.positions[t[1]], m.positions[t[2]]
		n := linalg.cross(b - a, c - a)
		m.normals[t[0]] += n
		m.normals[t[1]] += n
		m.normals[t[2]] += n
	}
	for &n in m.normals[first:][:TILE_VERTS] do n = linalg.normalize0(n)
}

Result :: struct {
	frame_ms, frame_max_ms, dab_ms, normals_ms: f64,
	verts_per_dab:                              int,
	checksum:                                   f64,
}

// Runs the stroke once over `m` (which it changes) and returns its timings.
run_stroke :: proc(m: ^Mesh, pool: ^jobs.Pool) -> Result {
	nodes := len(m.bounds)
	hit := make([dynamic]u32, 0, nodes)
	defer delete(hit)
	sums := make([]Vec3, nodes)
	defer delete(sums)
	moved := make([]u32, nodes)
	defer delete(moved)
	touched := make([dynamic]u32, 0, nodes)
	defer delete(touched)
	frames := (DABS + DABS_PER_FRAME - 1) / DABS_PER_FRAME
	frame := make([]f64, frames)
	defer delete(frame)
	normals := make([]f64, frames)
	defer delete(normals)
	dab := make([]f64, DABS)
	defer delete(dab)
	total_moved := 0
	for i in 0 ..< DABS {
		k := f32(i) / (DABS - 1)
		center := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
		tb := time.tick_now()
		// Nodes whose bounds the brush sphere reaches.
		clear(&hit)
		for b, n in m.bounds {
			q := linalg.clamp(center, b[0], b[1]) - center
			if linalg.dot(q, q) < RADIUS * RADIUS do append(&hit, u32(n))
		}
		d := Dab{m = m, hit = hit[:], center = center, sums = sums, moved = moved}
		jobs.parallel_for(pool, len(hit), &d, job_area)
		sum: Vec3
		for s in sums[:len(hit)] do sum += s // in hit order, so every run sums alike
		d.normal = linalg.normalize0(sum)
		jobs.parallel_for(pool, len(hit), &d, job_displace)
		for mv in moved[:len(hit)] do total_moved += int(mv)
		dab[i] = time.duration_milliseconds(time.tick_since(tb))
		f := i / DABS_PER_FRAME
		frame[f] += dab[i]
		if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
			tn := time.tick_now()
			clear(&touched)
			for t, n in m.touched do if t do append(&touched, u32(n))
			for n in touched do m.touched[n] = false
			d.nodes = touched[:]
			jobs.parallel_for(pool, len(touched), &d, job_normals)
			normals[f] = time.duration_milliseconds(time.tick_since(tn))
			frame[f] += normals[f]
		}
	}
	checksum: f64
	for p in m.positions do checksum += f64(p.x) + f64(p.y) * 3 + f64(p.z) * 7
	return {
		frame_ms = median(frame),
		frame_max_ms = slice.max(frame),
		dab_ms = median(dab),
		normals_ms = median(normals),
		verts_per_dab = total_moved / DABS,
		checksum = checksum,
	}
}

median :: proc(xs: []f64) -> f64 {
	s := slice.clone(xs, context.temp_allocator)
	slice.sort(s)
	return s[len(s) / 2]
}

// Tiles per cube-face side for about `target` vertices.
tiles_for :: proc(target: int) -> int {
	return max(1, int(math.round(math.sqrt(f64(target) / (6 * TILE_VERTS)))))
}

// Usage: dart_trial [sizes...] [--threads=N]; sizes default to 1M 5M 10M.
main :: proc() {
	sizes := make([dynamic]int)
	defer delete(sizes)
	threads := 0
	for arg in os.args[1:] {
		if len(arg) > 10 && arg[:10] == "--threads=" {
			threads = strconv.parse_int(arg[10:]) or_else 0
		} else if n, ok := strconv.parse_int(arg); ok {
			append(&sizes, n)
		}
	}
	if len(sizes) == 0 do append(&sizes, 1_000_000, 5_000_000, 10_000_000)
	pool: jobs.Pool
	jobs.pool_init(&pool, threads)
	defer jobs.pool_destroy(&pool)
	fmt.println("| Language | Threads | Vertices | Verts/dab | Dab ms | Normals ms/frame | Frame ms | Frame ms max | Checksum |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for target in sizes {
		for p in ([2]^jobs.Pool{nil, &pool}) {
			m := mesh_make(tiles_for(target))
			r := run_stroke(&m, p)
			fmt.printfln("| Odin | %d | %d | %d | %.3f | %.3f | %.2f | %.2f | %.4f |",
				jobs.pool_size(p) if p != nil else 1, len(m.positions), r.verts_per_dab, r.dab_ms,
				r.normals_ms, r.frame_ms, r.frame_max_ms, r.checksum)
			mesh_destroy(&m)
			free_all(context.temp_allocator)
		}
	}
}
