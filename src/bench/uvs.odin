package bench

import "core:fmt"
import "core:math"
import "core:time"

import "../geom"
import "../jobs"
import "../uv"

// --uv: UV flattening (src/uv's least squares conformal maps and the shelf packing) on
// three fixtures at each size, sizes being triangles: a tube welded round and cut open
// along one line by a seam (one big island, a strip), a hemisphere (one island, its rim
// the border) and the same hemisphere cut by seams into about nine by nine tiles (many small islands,
// solved side by side). Per row: the time on the calling thread alone and on the pool
// (the same bits, checked), Sander's L2 stretch, the worst singular value ratio, the mean
// angle error, the flipped triangles, the share of the square the boxes fill and the
// row's peak memory.

uvs_header :: proc() {
	fmt.println("| Fixture | Triangles | Islands | 1 thread ms | Pool ms | Same bits | L2 stretch | Worst | Angle ° | Flips | Filled | Peak RSS MB |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_uvs :: proc(target: int, pool: ^jobs.Pool) {
	for fixture in UV_Fixture do uv_row(fixture, target, pool)
}

@(private = "file")
UV_Fixture :: enum {
	Tube,
	Hemisphere,
	Tiles,
}

@(private = "file")
uv_row :: proc(fixture: UV_Fixture, target: int, pool: ^jobs.Pool) {
	peak_rss_reset()
	m: geom.Mesh
	defer geom.mesh_destroy(&m)
	// A grid of `across` by `along` squares, two triangles a square; the tube's columns
	// wrap round, so its last column of squares joins the first column of vertices.
	side := max(int(math.sqrt(f64(target) / 2)), 4)
	across, along := side, side
	if fixture == .Tube do across, along = 4 * side / 3, 3 * side / 4
	columns := across if fixture == .Tube else across + 1
	for y in 0 ..= along do for x in 0 ..< columns {
		switch fixture {
		case .Tube:
			a := 2 * math.PI * f64(x) / f64(across)
			r := f64(across) / (2 * math.PI)
			append(&m.positions, geom.Vec3{f32(r * math.cos(a)), f32(r * math.sin(a)), f32(y)})
		case .Hemisphere, .Tiles:
			// The grid laid on the upper half of a sphere by its angles from the pole.
			u, v := f64(x) / f64(across) * 2 - 1, f64(y) / f64(along) * 2 - 1
			l := max(abs(u), abs(v))
			a := math.atan2(v, u)
			polar := l * math.PI * 0.45
			append(&m.positions, geom.Vec3{f32(math.sin(polar) * math.cos(a)), f32(math.sin(polar) * math.sin(a)), f32(math.cos(polar))})
		}
	}
	at :: proc(columns, x, y: int) -> u32 {return u32(y * columns + x % columns)}
	for y in 0 ..< along do for x in 0 ..< across {
		append(&m.indices, at(columns, x, y), at(columns, x + 1, y), at(columns, x + 1, y + 1))
		append(&m.indices, at(columns, x, y), at(columns, x + 1, y + 1), at(columns, x, y + 1))
	}
	faces := geom.vertex_faces_build(m, pool)
	defer geom.vertex_faces_destroy(&faces)
	triangles := len(m.indices) / 3
	base := uv.make_uvs(triangles)
	defer uv.destroy(&base)
	// The seams: the tube's line at its first column of vertices, the tiles' grid lines
	// every eighth of the way across and along.
	tiles := max(across / 8, 1)
	for t in 0 ..< triangles do for k in 0 ..< 3 {
		p, q := m.indices[3 * t + k], m.indices[3 * t + (k + 1) % 3]
		px, py, qx, qy := int(p) % columns, int(p) / columns, int(q) % columns, int(q) / columns
		cut := false
		switch fixture {
		case .Tube: cut = px == 0 && qx == 0
		case .Hemisphere:
		case .Tiles: cut = (px == qx && px % tiles == 0) || (py == qy && py % tiles == 0)
		}
		if cut do base.seam[t] += {k}
	}
	uv.islands_find(&base, m.indices[:], faces)
	free_all(context.temp_allocator)

	one := uv.clone(base)
	defer uv.destroy(&one)
	t0 := time.tick_now()
	r := uv.flatten(&one, m.positions[:], m.indices[:], faces)
	serial_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	pooled := uv.clone(base)
	defer uv.destroy(&pooled)
	t0 = time.tick_now()
	_ = uv.flatten(&pooled, m.positions[:], m.indices[:], faces, pool = pool)
	pool_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	same := true
	for c, t in one.corner do if c != pooled.corner[t] do same = false

	s := uv.stretch(one, m.positions[:], m.indices[:])
	fmt.printfln("| %v | %s | %d | %.0f | %.0f | %v | %.4f | %.3f | %.2f | %d | %.2f | %.0f |", fixture, thousands(triangles), base.islands, serial_ms, pool_ms, "yes" if same else "NO", s.l2, s.worst, s.angle, r.flips, one.filled, peak_rss_mb())
}
