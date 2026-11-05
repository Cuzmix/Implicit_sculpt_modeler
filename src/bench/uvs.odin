package bench

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import "../geom"
import "../jobs"
import "../uv"

// --uv: UV flattening (src/uv's ABF++ and least squares conformal maps, and the shelf
// packing) on three fixtures at each size, sizes being triangles: a tube welded round
// and cut open along one line by a seam (one big island, a strip), a dome (one island,
// its rim the border) and the same dome cut by seams into about nine by nine tiles (many
// small islands, solved side by side). Per row: the time on the calling thread alone and
// on the pool (the same bits, checked), Sander's L2 stretch, the worst singular value
// ratio, the mean angle error, the flipped triangles, the islands ABF++ left to LSCM,
// the share of the square the boxes fill, then the stretch relax on the pool (its time,
// the energy per unit of surface before and after, 4 being lengths kept, and the L2
// stretch after) and the row's peak memory.

uv_write_dir := ""
uv_measure := ""

uvs_header :: proc() {
	fmt.println("| Fixture | Method | Triangles | Islands | 1 thread ms | Pool ms | Same bits | L2 stretch | Worst | Angle ° | Flips | Fallbacks | Filled | Relax ms | Energy | Relaxed L2 | Peak RSS MB |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_uvs :: proc(target: int, pool: ^jobs.Pool) {
	for fixture in UV_Fixture do for method in uv.Method do uv_row(fixture, method, target, pool)
	unwrap_row(target, pool)
}

// A closed sphere of about `target` triangles through uv.unwrap (auto seams, ABF++, the
// relax and the packing), on one thread and on the pool; its charts go in the Islands
// column and the relax's time in Relax ms.
@(private = "file")
unwrap_row :: proc(target: int, pool: ^jobs.Pool) {
	peak_rss_reset()
	m := geom.geodesic_sphere(geom.geodesic_frequency_for(target / 2), pool)
	defer geom.mesh_destroy(&m)
	faces := geom.vertex_faces_build(m, pool)
	defer geom.vertex_faces_destroy(&faces)
	triangles := len(m.indices) / 3
	one := uv.make_uvs(triangles)
	defer uv.destroy(&one)
	t0 := time.tick_now()
	r := uv.unwrap(&one, m.positions[:], m.indices[:], faces)
	serial_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	pooled := uv.make_uvs(triangles)
	defer uv.destroy(&pooled)
	t0 = time.tick_now()
	_ = uv.unwrap(&pooled, m.positions[:], m.indices[:], faces, pool = pool)
	pool_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	same := true
	for c, t in one.corner do if c != pooled.corner[t] do same = false
	s := uv.stretch(one, m.positions[:], m.indices[:])
	fmt.printfln("| Sphere | Unwrap | %s | %d | %.0f | %.0f | %v | %.4f | %.3f | %.2f | %d | %d | %.2f | %.0f | %.4f to %.4f | | %.0f |", thousands(triangles), r.charts, serial_ms, pool_ms, "yes" if same else "NO", s.l2, s.worst, s.angle, s.flips, r.flatten.fallbacks, one.filled, r.relax.ms, r.relax.before, r.relax.after, peak_rss_mb())
}

@(private = "file")
UV_Fixture :: enum {
	Tube,
	Dome,
	Tiles,
}

@(private = "file")
uv_row :: proc(fixture: UV_Fixture, method: uv.Method, target: int, pool: ^jobs.Pool) {
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
		case .Dome, .Tiles:
			// The grid twice as wide as it is away from a sphere's middle, pushed out onto
			// it: a dome whose corners reach 70° from its top, no triangle a sliver.
			p := [3]f64{(f64(x) / f64(across) * 2 - 1) * 2, (f64(y) / f64(along) * 2 - 1) * 2, 1}
			p /= math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
			append(&m.positions, geom.Vec3{f32(p.x), f32(p.y), f32(p.z)})
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
		case .Dome:
		case .Tiles: cut = (px == qx && px % tiles == 0) || (py == qy && py % tiles == 0)
		}
		if cut do base.seam[t] += {k}
	}
	uv.islands_find(&base, m.indices[:], faces)
	free_all(context.temp_allocator)

	one := uv.clone(base)
	defer uv.destroy(&one)
	t0 := time.tick_now()
	r := uv.flatten(&one, m.positions[:], m.indices[:], faces, method)
	serial_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	pooled := uv.clone(base)
	defer uv.destroy(&pooled)
	t0 = time.tick_now()
	_ = uv.flatten(&pooled, m.positions[:], m.indices[:], faces, method, pool)
	pool_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	same := true
	for c, t in one.corner do if c != pooled.corner[t] do same = false

	if uv_write_dir != "" && method == .Abf do write_uv_obj(fmt.tprintf("%s/%v_%d.obj", uv_write_dir, fixture, triangles), m.positions[:], m.indices[:], one)
	s := uv.stretch(one, m.positions[:], m.indices[:])
	t0 = time.tick_now()
	rr := uv.relax(&pooled, m.positions[:], m.indices[:], faces, pool = pool)
	relax_ms := time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	sr := uv.stretch(pooled, m.positions[:], m.indices[:])
	fmt.printfln("| %v | %v | %s | %d | %.0f | %.0f | %v | %.4f | %.3f | %.2f | %d | %d | %.2f | %.0f | %.4f to %.4f | %.4f | %.0f |", fixture, method, thousands(triangles), base.islands, serial_ms, pool_ms, "yes" if same else "NO", s.l2, s.worst, s.angle, r.flips, r.fallbacks, one.filled, relax_ms, rr.before, rr.after, sr.l2, peak_rss_mb())
}

// The mesh with a texture coordinate a corner as OBJ (v up, as OBJ keeps it), so the
// islands survive a round trip through another app that reads its seams from them.
@(private = "file")
write_uv_obj :: proc(path: string, positions: []geom.Vec3, indices: []u32, u: uv.Uvs) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "# bench --uv fixture")
	for p in positions do fmt.sbprintfln(&b, "v %.9g %.9g %.9g", p.x, p.y, p.z)
	for c in u.corner do for p in c do fmt.sbprintfln(&b, "vt %.9g %.9g", p.x, p.y)
	for t in 0 ..< len(indices) / 3 {
		fmt.sbprintfln(&b, "f %d/%d %d/%d %d/%d", indices[3 * t] + 1, 3 * t + 1, indices[3 * t + 1] + 1, 3 * t + 2, indices[3 * t + 2] + 1, 3 * t + 3)
	}
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); err != nil do fmt.eprintfln("bench: cannot write %s: %v", path, err)
}

// --measure: an OBJ's own UVs (Blender's unwrap, say) measured by our stretch, then the
// same islands flattened by each of our methods, one row each.
measure_uvs :: proc(path: string, pool: ^jobs.Pool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("bench: cannot read %s: %v", path, err)
		return
	}
	defer delete(data)
	corners := make([dynamic][2]f32)
	defer delete(corners)
	m, read_err, line := geom.mesh_read_obj(data, pool, uvs = &corners)
	defer geom.mesh_destroy(&m)
	if read_err != .None || len(corners) != len(m.indices) {
		fmt.eprintfln("bench: %s: %v at line %d, or no UVs", path, read_err, line)
		return
	}
	faces := geom.vertex_faces_build(m, pool)
	defer geom.vertex_faces_destroy(&faces)
	file := uv.from_corners(m.indices[:], corners[:], nil, faces)
	defer uv.destroy(&file)
	free_all(context.temp_allocator)
	triangles := len(m.indices) / 3
	s := uv.stretch(file, m.positions[:], m.indices[:])
	fmt.printfln("| %s | file | %s | %d | | | | %.4f | %.3f | %.2f | %d | | %.2f | | | | |", path, thousands(triangles), file.islands, s.l2, s.worst, s.angle, s.flips, file.filled)
	for method in uv.Method {
		ours := uv.clone(file)
		defer uv.destroy(&ours)
		t0 := time.tick_now()
		r := uv.flatten(&ours, m.positions[:], m.indices[:], faces, method, pool)
		ms := time.duration_milliseconds(time.tick_since(t0))
		free_all(context.temp_allocator)
		so := uv.stretch(ours, m.positions[:], m.indices[:])
		fmt.printfln("| %s | %v | %s | %d | | %.0f | | %.4f | %.3f | %.2f | %d | %d | %.2f | | | | %.0f |", path, method, thousands(triangles), ours.islands, ms, so.l2, so.worst, so.angle, r.flips, r.fallbacks, ours.filled, peak_rss_mb())
	}
}
