package bench

import "core:fmt"
import "core:math"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// --files: at each size, a sphere written to OBJ and PLY and read back as the app's
// import does (parse, then clean: weld, drop unused, centre and size, check the edges),
// then made sculpt-ready with its normals; and the same sphere as a native scene, a
// single level written and read back (reading builds it ready to sculpt). A second
// table does the native scene for levels, laid out as the --levels table lays them
// out, since reading those subdivides and encodes every level again. Everything is in
// memory: the disk adds its own time, which the app's Stats show apart.
files_header :: proc() {
	fmt.println("| Vertices | OBJ MB | OBJ write ms | OBJ parse ms | PLY MB | PLY write ms | PLY parse ms | Clean ms | Sculpt-ready ms | Scene MB | Scene write ms | Scene read ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

files_rows: [dynamic]string

run_files :: proc(target: int, pool: ^jobs.Pool) {
	l: sculpt.Levels
	sculpt.levels_init(&l, geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool), pool, node_triangles)
	free_all(context.temp_allocator)
	mesh := l.levels[0].mesh
	vcount := len(mesh.positions)

	text := make([dynamic]u8)
	defer delete(text)
	t0 := time.tick_now()
	geom.mesh_write_obj(&text, mesh.positions[:], mesh.indices[:], pool = pool)
	obj_write_ms := time.duration_milliseconds(time.tick_since(t0))
	obj_mb := f64(len(text)) / (1 << 20)
	t1 := time.tick_now()
	from_obj, obj_err, _ := geom.mesh_read_obj(text[:], pool)
	obj_parse_ms := time.duration_milliseconds(time.tick_since(t1))
	assert(obj_err == .None)
	geom.mesh_destroy(&from_obj)
	free_all(context.temp_allocator)

	clear(&text)
	t2 := time.tick_now()
	geom.mesh_write_ply(&text, mesh.positions[:], mesh.indices[:], pool = pool)
	ply_write_ms := time.duration_milliseconds(time.tick_since(t2))
	ply_mb := f64(len(text)) / (1 << 20)
	t3 := time.tick_now()
	read, ply_err, _ := geom.mesh_read_ply(text[:], pool)
	ply_parse_ms := time.duration_milliseconds(time.tick_since(t3))
	assert(ply_err == .None)
	free_all(context.temp_allocator)

	t4 := time.tick_now()
	_, clean_err := geom.mesh_clean(&read, pool)
	_, _ = geom.mesh_normalize(&read, pool)
	edges := geom.mesh_edges(read, pool)
	clean_ms := time.duration_milliseconds(time.tick_since(t4))
	assert(clean_err == .None && geom.mesh_edges_closed(edges))
	free_all(context.temp_allocator)
	t5 := time.tick_now()
	imported: sculpt.Levels
	sculpt.levels_init(&imported, read, pool, node_triangles)
	sculpt.sculptor_recompute_all(&imported.levels[0].sculptor)
	ready_ms := time.duration_milliseconds(time.tick_since(t5))
	sculpt.levels_destroy(&imported)
	free_all(context.temp_allocator)

	scene_mb, write_ms, read_ms := scene_round_trip(&l, pool)
	sculpt.levels_destroy(&l)
	fmt.printfln("| %s | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f | %.0f |",
		thousands(vcount), obj_mb, obj_write_ms, obj_parse_ms, ply_mb, ply_write_ms, ply_parse_ms, clean_ms, ready_ms, scene_mb, write_ms, read_ms)

	// The levels for the second table.
	base_frequency, steps := levels_layout(target)
	sculpt.levels_init(&l, geom.geodesic_sphere(base_frequency, pool), pool, node_triangles)
	defer sculpt.levels_destroy(&l)
	for _ in 0 ..< steps {
		if !sculpt.levels_subdivide(&l) do panic("subdivide failed")
		free_all(context.temp_allocator)
	}
	top := len(l.levels) - 1
	levels_mb, levels_write_ms, levels_read_ms := scene_round_trip(&l, pool)
	append(&files_rows, fmt.aprintf("| %s | %d | %s | %.0f | %.0f | %.0f |",
		thousands(len(l.levels[top].mesh.positions)), len(l.levels), thousands(len(l.levels[0].mesh.positions)), levels_mb, levels_write_ms, levels_read_ms))
}

files_footer :: proc() {
	fmt.println()
	fmt.println("| Top vertices | Levels | Base vertices | Scene MB | Scene write ms | Scene read ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- |")
	for row in files_rows {
		fmt.println(row)
		delete(row)
	}
	delete(files_rows)
}

// Writes the levels as the scene file stores them and reads them back into new levels,
// checking the copy has as many vertices on top.
@(private = "file")
scene_round_trip :: proc(l: ^sculpt.Levels, pool: ^jobs.Pool) -> (mb, write_ms, read_ms: f64) {
	out := make([dynamic]u8)
	defer delete(out)
	t0 := time.tick_now()
	sculpt.levels_write(l, &out)
	write_ms = time.duration_milliseconds(time.tick_since(t0))
	free_all(context.temp_allocator)
	back: sculpt.Levels
	r := geom.byte_reader(out[:])
	t1 := time.tick_now()
	ok := sculpt.levels_read(&back, &r, pool, node_triangles)
	read_ms = time.duration_milliseconds(time.tick_since(t1))
	assert(ok && len(back.levels) == len(l.levels))
	top := len(l.levels) - 1
	assert(len(back.levels[top].mesh.positions) == len(l.levels[top].mesh.positions))
	sculpt.levels_destroy(&back)
	free_all(context.temp_allocator)
	return f64(len(out)) / (1 << 20), write_ms, read_ms
}

// How the --levels table reaches a target: a base of at most LEVELS_BASE_MAX vertices
// and as few levels above it as reach the target. Geodesic spheres have 10 f^2 + 2
// vertices, and a level above has twice the frequency.
levels_layout :: proc(target: int) -> (base_frequency, steps: int) {
	f := math.sqrt(f64(target - 2) / 10)
	for 10 * (f / f64(int(1) << uint(steps))) * (f / f64(int(1) << uint(steps))) + 2 > LEVELS_BASE_MAX do steps += 1
	return max(int(math.round(f / f64(int(1) << uint(steps)))), 1), steps
}
