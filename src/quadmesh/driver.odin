package quadmesh

import "base:runtime"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"

// The Odin driver (Core.Odin): qm_remesh's pipeline (quadmesh_shim.cpp) run here, one stage
// call at a time, so each stage can be replaced by an Odin one and checked against the
// C++'s on the same input. While every stage is the C++'s the result is qm_remesh's bit
// for bit: the input split into islands as MeshSeparator splits it, the island's values
// given out in the same order, the quad size, the cap test and the count's landing in the
// same arithmetic in the same order (the bracket's pow and log are the C library's, as
// the C++'s are), and the islands joined in order. Islands run on threads of their own up
// to the thread count, each whole on one thread, as qm_remesh's do; on the threads, the
// stages' own loops stay serial. A stage's output is checked (checks.odin) and, when
// Params.dump names a folder, written there (dump.odin).

// Where an island's own 0..1 progress splits across its stages, and the islands' share of
// the whole bar, as qm_remesh splits them.
@(private = "file")
ISLAND_RESAMPLE_END :: f32(0.17)
@(private = "file")
ISLAND_PARAMETERIZE_END :: f32(0.50)
@(private = "file")
PARALLEL_PHASE_BEGIN :: f32(0.03)
@(private = "file")
PARALLEL_PHASE_END :: f32(0.95)

// The landing's tolerance and the covers it may solve (remeshIsland's).
@(private = "file")
LANDING_MISS :: 0.03
@(private = "file")
LANDING_COVERS :: 3

@(private = "file")
Driver :: struct {
	params:          ^Params,
	progress:        ^jobs.Progress,
	share:           [2]f32,
	voxel_size:      f64,
	quad_edge:       f64,
	threads:         int,
	islands:         []Island_Work,
	lock:            sync.Mutex, // over the progress, the cancel and the reasons
	island_progress: []f32,
	island_weight:   []f32,
	cancelled:       bool, // sticky, as qm_remesh's handler's is
	failure:         Reason, // the last reason an island's cover gave for failing
	fatal:           Stage_Error, // the first stage that failed the whole remesh
	fatal_reason:    Reason,
	next:            int, // atomic: the next island a thread takes
	decimate_ns, isotropic_ns, parameterize_ns, extract_ns: i64, // atomic: the stages' times, summed over the islands
	isotropic_triangles, covers: int, // atomic
}

// An island, then its result.
@(private = "file")
Island_Work :: struct {
	island: Island,
	quads:  Quads,
	checks: Checks,
}

// A stage's progress tag: the island and the share of its own bar the stage covers.
@(private = "file")
Stage_Tag :: struct {
	driver:     ^Driver,
	island:     int,
	begin, end: f32,
}

// The remesh through the driver, as cpp_remesh is through qm_remesh.
@(private)
driver_remesh :: proc(positions: []geom.Vec3, indices: []u32, params: Params, progress: ^jobs.Progress, share: [2]f32, allocator: runtime.Allocator) -> (out: Polygon_Mesh, times: Qm_Times, checks: Checks, err: Error, reason: string) {
	start := time.tick_now()
	heap := runtime.heap_allocator()
	params := params
	d := new(Driver, heap)
	defer free(d, heap)
	d.params, d.progress, d.share = &params, progress, share
	if !driver_whole(d, 0, "Computing voxel size") do return {}, {}, {}, .Cancelled, ""
	// The input in doubles, as the core keeps it, until the islands have their own copies.
	vertices := make([][3]f64, len(positions), heap)
	vertices_kept := true
	defer if vertices_kept do delete(vertices, heap)
	for p, v in positions do vertices[v] = {f64(p.x), f64(p.y), f64(p.z)}
	faces := (cast([^][3]u32)raw_data(indices))[:len(indices) / 3]
	d.threads = clamp(params.threads, 1, MAX_THREADS)
	// The core's isotropic target: a triangle of the area that twice the quads asked would
	// give, as an equilateral; the quad edge wanted is the plain one. Under Keep symmetry
	// the caps' area takes no quads: the count asked is the rest's.
	area := counted_area(&params, vertices, faces)
	d.voxel_size = math.sqrt((area / (2.0 * f64(u32(params.quads)))) / EQUILATERAL_AREA)
	d.quad_edge = math.sqrt(area / f64(u32(params.quads)))
	if !(d.voxel_size > 0) || !(d.quad_edge > 0) do return {}, {}, {}, .Failed, "the mesh has no area"
	if !driver_whole(d, 0.01, "Splitting mesh into islands") do return {}, {}, {}, .Cancelled, ""

	order, starts := islands_split(faces, len(vertices), heap)
	count := len(starts) - 1
	if count <= 0 {
		delete(order, heap)
		delete(starts, heap)
		return {}, {}, {}, .Failed, "the mesh is empty"
	}
	d.islands = make([]Island_Work, count, heap)
	defer {
		for &w in d.islands {
			island_destroy(&w.island)
			quads_destroy(&w.quads)
		}
		delete(d.islands, heap)
	}
	d.island_progress = make([]f32, count, heap)
	defer delete(d.island_progress, heap)
	d.island_weight = make([]f32, count, heap)
	defer delete(d.island_weight, heap)
	islands_fill(d, vertices, faces, order, starts, area)
	// The islands hold all the stages need, so the whole input goes before they start.
	delete(order, heap)
	delete(starts, heap)
	delete(vertices, heap)
	vertices_kept = false

	if !driver_whole(d, PARALLEL_PHASE_BEGIN, "Remeshing uniformly") do return {}, {}, {}, .Cancelled, ""
	if count <= 1 || d.threads <= 1 {
		for i in 0 ..< count {
			island_remesh(d, i, false)
			if d.cancelled || d.fatal != .None do break
		}
	} else {
		pool := make([]^thread.Thread, min(d.threads, count), heap)
		defer delete(pool, heap)
		for &t in pool do t = thread.create_and_start_with_poly_data(d, proc(d: ^Driver) {
			for {
				i := sync.atomic_add(&d.next, 1)
				if i >= len(d.islands) do break
				island_remesh(d, i, true)
			}
		})
		for t in pool {
			thread.join(t)
			thread.destroy(t)
		}
	}
	if d.cancelled do return {}, {}, {}, .Cancelled, ""
	switch d.fatal {
	case .None:
	case .Cancelled: return {}, {}, {}, .Cancelled, ""
	case .Out_Of_Memory: return {}, {}, {}, .Failed, "out of memory"
	case .Unavailable: return {}, {}, {}, .Unavailable, "Quad Remesh is not built for this platform"
	case .Failed: return {}, {}, {}, .Failed, clone_reason(&d.fatal_reason)
	}

	if !driver_whole(d, PARALLEL_PHASE_END, "Merging mesh islands") do return {}, {}, {}, .Cancelled, ""
	vertex_total, face_total, corner_total := 0, 0, 0
	for w in d.islands {
		if len(w.quads.first) < 2 do continue
		vertex_total += len(w.quads.positions)
		face_total += len(w.quads.first) - 1
		corner_total += len(w.quads.corners)
		checks_add(&checks, w.checks)
	}
	if face_total == 0 {
		why := reason_string(&d.failure)
		if why == "" {
			line: Reason
			cpp_console_line(&line)
			if reason_string(&line) != "" do return {}, {}, {}, .Failed, clone_reason(&line)
			return {}, {}, {}, .Failed, "AutoRemesher gave no polygons"
		}
		return {}, {}, {}, .Failed, clone_reason(&d.failure)
	}
	out.positions = make([]geom.Vec3, vertex_total, allocator)
	out.first = make([]u32, face_total + 1, allocator)
	out.corners = make([]u32, corner_total, allocator)
	v, f, n := 0, 0, 0
	for w in d.islands {
		q := w.quads
		if len(q.first) < 2 do continue
		base := u32(v)
		for p in q.positions {
			out.positions[v] = {f32(p.x), f32(p.y), f32(p.z)}
			v += 1
		}
		for p in 0 ..< len(q.first) - 1 {
			out.first[f] = u32(n)
			f += 1
			for k in q.first[p] ..< q.first[p + 1] {
				out.corners[n] = base + q.corners[k]
				n += 1
			}
		}
	}
	out.first[f] = u32(n)
	times = {
		decimate_ms         = f32(f64(sync.atomic_load(&d.decimate_ns)) / 1e6),
		isotropic_ms        = f32(f64(sync.atomic_load(&d.isotropic_ns)) / 1e6),
		parameterize_ms     = f32(f64(sync.atomic_load(&d.parameterize_ns)) / 1e6),
		extract_ms          = f32(f64(sync.atomic_load(&d.extract_ns)) / 1e6),
		total_ms            = f32(time.duration_milliseconds(time.tick_since(start))),
		isotropic_triangles = u32(min(sync.atomic_load(&d.isotropic_triangles), int(max(u32)))),
		covers              = u32(sync.atomic_load(&d.covers)),
	}
	_ = driver_whole(d, 1, "Done")
	return out, times, checks, .None, ""
}

// The area of an equilateral triangle of unit edge, as the core writes it.
@(private = "file")
EQUILATERAL_AREA :: f64(0.86602540378 * 0.5)

// A reason in temp memory, as `remesh` returns them.
@(private = "file")
clone_reason :: proc(r: ^Reason) -> string {
	s := reason_string(r)
	out := make([]u8, len(s), context.temp_allocator)
	copy(out, s)
	return string(out)
}

// The whole bar's progress outside the islands; false once cancelled.
@(private = "file")
driver_whole :: proc(d: ^Driver, fraction: f32, stage: string) -> bool {
	sync.mutex_lock(&d.lock)
	defer sync.mutex_unlock(&d.lock)
	if !d.cancelled {
		jobs.progress_set(d.progress, d.share[0], d.share[1], fraction)
		if jobs.progress_cancelled(d.progress) do d.cancelled = true
	}
	return !d.cancelled
}

// An island reports its own 0..1 and the bar gets the weighted whole, as qm_remesh's
// handler does; false once cancelled.
@(private = "file")
driver_report :: proc(d: ^Driver, island: int, fraction: f32) -> bool {
	sync.mutex_lock(&d.lock)
	defer sync.mutex_unlock(&d.lock)
	d.island_progress[island] = max(d.island_progress[island], min(f32(1), fraction))
	sum := f64(0)
	for p, i in d.island_progress do sum += f64(p) * f64(d.island_weight[i])
	overall := PARALLEL_PHASE_BEGIN + (PARALLEL_PHASE_END - PARALLEL_PHASE_BEGIN) * f32(min(1, sum))
	if !d.cancelled {
		jobs.progress_set(d.progress, d.share[0], d.share[1], overall)
		if jobs.progress_cancelled(d.progress) do d.cancelled = true
	}
	return !d.cancelled
}

@(private = "file")
driver_stage_progress :: proc(tag: rawptr, fraction: f32) -> bool {
	t := (^Stage_Tag)(tag)
	return driver_report(t.driver, t.island, t.begin + (t.end - t.begin) * fraction)
}

// A stage that failed the whole remesh: the first one wins, and a cancel is sticky.
@(private = "file")
driver_fail :: proc(d: ^Driver, err: Stage_Error, reason: ^Reason) {
	sync.mutex_lock(&d.lock)
	defer sync.mutex_unlock(&d.lock)
	if err == .Cancelled do d.cancelled = true
	if d.fatal == .None {
		d.fatal = err
		d.fatal_reason = reason^
	}
}

@(private = "file")
add_ns :: proc(to: ^i64, from: time.Tick) {
	sync.atomic_add(to, i64(time.tick_since(from)))
}

// One island through the stages (remeshIsland's order): thinned, remeshed isotropically,
// covered until the cells land on the count, its quads extracted. `serial` keeps the
// stages' own loops on this thread.
@(private = "file")
island_remesh :: proc(d: ^Driver, i: int, serial: bool) {
	w := &d.islands[i]
	params := d.params
	reason: Reason
	if !driver_report(d, i, 0) do return
	t0 := time.tick_now()
	thin, decimated, added, err := cpp_thin(w.island, d.voxel_size, d.quad_edge, f64(params.sharp_degrees), &reason)
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	w.checks.islands = 1
	checks_thin(&w.checks, thin)
	w.checks.thin_decimated = 1 if decimated else 0
	w.checks.thin_unpinched = added
	dump_thin(params.dump, i, w.island, thin)
	island_destroy(&w.island)
	w.island = thin
	add_ns(&d.decimate_ns, t0)

	t1 := time.tick_now()
	tag := Stage_Tag{d, i, 0, ISLAND_RESAMPLE_END}
	run := Stage_Run{d.threads, serial, driver_stage_progress, &tag}
	iso: Isotropic
	iso, err = cpp_isotropic(w.island, d.voxel_size, f64(params.adaptivity), f64(params.sharp_degrees), &run, &reason)
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	defer isotropic_destroy(&iso)
	// The rest of the stages work on the isotropic mesh alone, but for the area the count
	// was asked of.
	island_area := counted_area(params, w.island.positions, w.island.triangles)
	island_destroy(&w.island)
	add_ns(&d.isotropic_ns, t1)
	sync.atomic_add(&d.isotropic_triangles, len(iso.triangles))
	checks_isotropic(&w.checks, iso)
	dump_isotropic(params.dump, i, iso)
	if !driver_report(d, i, ISLAND_RESAMPLE_END) do return
	if len(iso.positions) == 0 || len(iso.triangles) == 0 {
		_ = driver_report(d, i, 1)
		return
	}

	// The cover multiplies its scaling by the isotropic mesh's mean edge, so the quad edge
	// wanted divided by that mean asks for it; the cover's own area in cells then says how
	// far off the count will be, and up to two more covers correct the scaling by it
	// (remeshIsland says why). A count Params.scaling fixed is left alone.
	t2 := time.tick_now()
	landing := params.scaling <= 0
	scaling := f64(params.scaling)
	if landing {
		mean := iso.mean_edge
		scaling = d.quad_edge / mean if mean > 0 else 1.0
	}
	// A face whose quads are s times the size covers 1 / s² as many cells; a face on a cap
	// plane counts for none, here and in the cells measured below.
	heap := runtime.heap_allocator()
	cap_face := make([]bool, len(iso.triangles), heap)
	defer delete(cap_face, heap)
	within := max(f64(params.cap_snap), 0.05 * d.voxel_size)
	for t, f in iso.triangles do cap_face[f] = on_cap(params, iso.positions[t[0]], iso.positions[t[1]], iso.positions[t[2]], within)
	scaled_area := f64(0)
	scaled := len(iso.vertex_scale) == len(iso.positions)
	for t, f in iso.triangles {
		if cap_face[f] do continue
		a := triangle_area(iso.positions[t[0]], iso.positions[t[1]], iso.positions[t[2]])
		s := (iso.vertex_scale[t[0]] + iso.vertex_scale[t[1]] + iso.vertex_scale[t[2]]) / 3.0 if scaled else 1.0
		scaled_area += a / (s * s)
	}
	cells_wanted := scaled_area / (d.quad_edge * d.quad_edge)
	// The isotropic mesh is smoother than the island, so smaller, and the core lands on
	// that smaller area's share of the count, a few percent short of it on a detailed
	// mesh; the Odin core lands on the count itself, the island's own share of it, its
	// first cover's quads that much smaller.
	if params.core == .Odin {
		iso_area := f64(0)
		for t, f in iso.triangles do if !cap_face[f] do iso_area += triangle_area(iso.positions[t[0]], iso.positions[t[1]], iso.positions[t[2]])
		if iso_area > 0 && island_area > 0 {
			cells_wanted *= island_area / iso_area
			if landing do scaling *= math.sqrt(iso_area / island_area)
		}
	}
	guided: [][3]f64
	defer delete(guided, heap)
	guided, err = cpp_face_guides(iso, d.quad_edge, params.guides, params.guide_strength, &reason)
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	anisotropy := f64(params.anisotropy) if params.anisotropy > 0 else 1.0
	cover, best: Cover
	defer cover_destroy(&cover)
	defer cover_destroy(&best)
	best_miss, under_scaling, under_cells, over_scaling, over_cells: f64
	cover_span := ISLAND_PARAMETERIZE_END - ISLAND_RESAMPLE_END
	for pass in 0 ..< LANDING_COVERS {
		// The first cover takes the whole parameterize share of the bar; a later one the
		// last third of it again, so the bar steps back a little rather than stalling.
		tag = {d, i, ISLAND_RESAMPLE_END if pass == 0 else ISLAND_RESAMPLE_END + cover_span * 0.67, ISLAND_PARAMETERIZE_END}
		sync.atomic_add(&d.covers, 1)
		cover_destroy(&cover)
		cover, err = cpp_cover(iso, guided, scaling, f64(params.adaptivity), anisotropy, f64(params.sharp_degrees), &run, &reason)
		w.checks.covers += 1
		if err == .Failed {
			// An island whose cover fails is left without quads, its reason kept for the
			// report, as the core does.
			if reason_string(&reason) != "" {
				sync.mutex_lock(&d.lock)
				d.failure = reason
				sync.mutex_unlock(&d.lock)
			}
			add_ns(&d.parameterize_ns, t2)
			_ = driver_report(d, i, 1)
			return
		}
		if err != .None {
			driver_fail(d, err, &reason)
			return
		}
		cells := cover_cells(cover, cap_face)
		dump_cover(params.dump, i, pass, iso, cover, scaling, cells, cells_wanted)
		if !landing || len(cover.uvs) == 0 do break
		if cells <= 0 || cells_wanted <= 0 do break
		miss := abs(cells / cells_wanted - 1.0)
		if pass == 0 || miss < best_miss {
			cover_destroy(&best)
			best, cover = cover, {}
			best_miss = miss
		}
		if best_miss <= LANDING_MISS || pass == LANDING_COVERS - 1 do break
		// A cover a quarter of the ask or less, or four times it, came out folded up and
		// says nothing of how the cells go with the scaling, so it bounds no bracket.
		folded := cells * 4.0 <= cells_wanted || cells >= 4.0 * cells_wanted
		if !folded && cells < cells_wanted && cells > under_cells do under_scaling, under_cells = scaling, cells
		if !folded && cells > cells_wanted && (over_cells == 0 || cells < over_cells) do over_scaling, over_cells = scaling, cells
		// Between a cover under the ask and one over it, the scaling is found between theirs
		// as the cells go; otherwise the cells go as the scaling squared, inversely, a step
		// held within a factor of 1.5 either way.
		if under_cells > 0 && over_cells > 0 {
			scaling = under_scaling * libm_pow(over_scaling / under_scaling, libm_log(cells_wanted / under_cells) / libm_log(over_cells / under_cells))
		} else {
			scaling *= max(STEP_LEAST, min(1.5, math.sqrt(cells / cells_wanted)))
		}
	}
	if len(best.uvs) > 0 {
		cover_destroy(&cover)
		cover, best = best, {}
	}
	add_ns(&d.parameterize_ns, t2)
	checks_cover(&w.checks, iso, cover, cells_wanted)
	if !driver_report(d, i, ISLAND_PARAMETERIZE_END) do return

	t3 := time.tick_now()
	tag = {d, i, ISLAND_PARAMETERIZE_END, 1}
	if params.core == .Odin {
		w.quads, err = odin_extract(iso, cover, &run, &reason, &w.checks)
	} else {
		w.quads, err = cpp_extract(iso, cover, &run, &reason)
	}
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	add_ns(&d.extract_ns, t3)
	checks_quads(&w.checks, w.quads)
	dump_quads(params.dump, i, w.quads, w.checks)
	_ = driver_report(d, i, 1)
}

// The landing's smallest step down, 1 / 1.5 as the C++ divides it.
@(private = "file")
STEP_LEAST :: f64(1.0 / 1.5)

// The cover's area in cells over the triangles off the caps (coverCells).
@(private = "file")
cover_cells :: proc(c: Cover, cap_face: []bool) -> f64 {
	cells := f64(0)
	for t, f in c.uvs {
		if f < len(cap_face) && cap_face[f] do continue
		cells += 0.5 * abs((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]))
	}
	return cells
}

// The triangle's area as the core's Vector3::area takes it.
@(private)
triangle_area :: proc(a, b, c: [3]f64) -> f64 {
	ab, ac := b - a, c - a
	x := ab.y * ac.z - ab.z * ac.y
	y := ab.z * ac.x - ab.x * ac.z
	z := ab.x * ac.y - ab.y * ac.x
	return 0.5 * math.sqrt(x * x + y * y + z * z)
}

// Whether the triangle lies on one of the caller's cap planes (onCap): every corner within
// `within` of it and the triangle square to its axis.
@(private = "file")
on_cap :: proc(params: ^Params, a, b, c: [3]f64, within: f64) -> bool {
	if cap_axes(params.cap) == 0 do return false
	ab, ac := b - a, c - a
	n := [3]f64{ab.y * ac.z - ab.z * ac.y, ab.z * ac.x - ab.x * ac.z, ab.x * ac.y - ab.y * ac.x}
	length := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
	// Vector3::normalized: a normal of no length is zero.
	normal := [3]f64{n.x / length, n.y / length, n.z / length} if abs(length) > EPSILON else {}
	for k in 0 ..< 3 {
		if !params.cap.axes[k] do continue
		o := f64(params.cap.center[k])
		if abs(a[k] - o) <= within && abs(b[k] - o) <= within && abs(c[k] - o) <= within && abs(normal[k]) >= 0.995 do return true
	}
	return false
}

// The core's Double::isZero bound: the f64 epsilon.
@(private = "file")
EPSILON :: math.F64_EPSILON

// The input's area over the triangles off the caps (meshArea over countedTriangles).
@(private = "file")
counted_area :: proc(params: ^Params, vertices: [][3]f64, faces: [][3]u32) -> f64 {
	area := f64(0)
	snap := f64(params.cap_snap)
	for t in faces {
		a, b, c := vertices[t[0]], vertices[t[1]], vertices[t[2]]
		if on_cap(params, a, b, c, snap) do continue
		area += triangle_area(a, b, c)
	}
	return area
}

// The input's triangles island by island, as MeshSeparator::splitToIslands gives them: a
// flood from each triangle not yet reached, in order, across each edge to the last
// triangle that runs that edge the other way, first in first out, each island's triangles
// in the order the flood takes them. Island i is order[starts[i]:starts[i + 1]]. The
// directed edges are filed by their first vertex, in triangle order (a count, a prefix sum
// and a fill, linear where sorting three million edges took a third of a second), so the
// last match in a vertex's few is the core's last triangle.
@(private = "file")
islands_split :: proc(faces: [][3]u32, vertex_count: int, allocator: runtime.Allocator) -> (order: []u32, starts: []int) {
	edges := Edge_File {
		first = make([]u32, vertex_count + 1, allocator),
		to    = make([]u32, 3 * len(faces), allocator),
		face  = make([]u32, 3 * len(faces), allocator),
	}
	defer {
		delete(edges.first, allocator)
		delete(edges.to, allocator)
		delete(edges.face, allocator)
	}
	for t in faces do for k in 0 ..< 3 do edges.first[t[k] + 1] += 1
	for v in 0 ..< vertex_count do edges.first[v + 1] += edges.first[v]
	cursor := make([]u32, vertex_count, allocator)
	defer delete(cursor, allocator)
	copy(cursor, edges.first[:vertex_count])
	for t, f in faces do for k in 0 ..< 3 {
		slot := cursor[t[k]]
		cursor[t[k]] = slot + 1
		edges.to[slot] = t[(k + 1) % 3]
		edges.face[slot] = u32(f)
	}
	reached := make([]bool, len(faces), allocator)
	defer delete(reached, allocator)
	queue := make([dynamic]u32, 0, 64, allocator)
	defer delete(queue)
	order = make([]u32, len(faces), allocator)
	first := make([dynamic]int, 0, 4, allocator)
	n := 0
	for seed in 0 ..< len(faces) {
		if reached[seed] do continue
		append(&first, n)
		clear(&queue)
		append(&queue, u32(seed))
		for head := 0; head < len(queue); head += 1 {
			f := queue[head]
			if reached[f] do continue
			t := faces[f]
			for k in 0 ..< 3 {
				if g, ok := opposite_face(edges, t[(k + 1) % 3], t[k]); ok do append(&queue, g)
			}
			reached[f] = true
			order[n] = f
			n += 1
		}
	}
	append(&first, n)
	return order, first[:]
}

// The directed edges filed by their first vertex: vertex v's run edges first[v] to
// first[v + 1], each to `to` in triangle `face`, in triangle order.
@(private = "file")
Edge_File :: struct {
	first, to, face: []u32,
}

// The last triangle that runs from `from` to `to`, as the core's findFaceOfDirectedEdge
// takes it.
@(private = "file")
opposite_face :: proc(edges: Edge_File, from, to: u32) -> (face: u32, ok: bool) {
	for i := int(edges.first[from + 1]) - 1; i >= int(edges.first[from]); i -= 1 {
		if edges.to[i] == to do return edges.face[i], true
	}
	return 0, false
}

// Each island's own vertices (numbered as its triangles meet them), triangles, feature
// edges, density and refinement, as qm_remesh gives them out. A vertex two islands share
// (they touch at a point) belongs, for its values, to the last island that met it.
@(private = "file")
islands_fill :: proc(d: ^Driver, vertices: [][3]f64, faces: [][3]u32, order: []u32, starts: []int, area: f64) {
	heap := runtime.heap_allocator()
	params := d.params
	NONE :: max(u32)
	local := make([]u32, len(vertices), heap)
	defer delete(local, heap)
	owner := make([]u32, len(vertices), heap)
	defer delete(owner, heap)
	for &v in local do v = NONE
	for &v in owner do v = NONE
	positions := make([dynamic][3]f64, 0, 1024, heap)
	defer delete(positions)
	for &w, i in d.islands {
		clear(&positions)
		w.island.triangles = make([][3]u32, starts[i + 1] - starts[i], heap)
		for f, j in order[starts[i]:starts[i + 1]] {
			for k in 0 ..< 3 {
				v := faces[f][k]
				if local[v] == NONE || owner[v] != u32(i) {
					owner[v] = u32(i)
					local[v] = u32(len(positions))
					append(&positions, vertices[v])
				}
				w.island.triangles[j][k] = local[v]
			}
		}
		w.island.positions = make([][3]f64, len(positions), heap)
		copy(w.island.positions, positions[:])
		d.island_weight[i] = f32(f64(starts[i + 1] - starts[i]) / f64(len(faces)))
	}
	// The density, relative to its mean over the area, so the count stays what was asked
	// wherever the quads go; each island takes its vertices' share. An even one is none.
	if len(params.density) == len(vertices) {
		density := make([]f64, len(vertices), heap)
		defer delete(density, heap)
		for x_, v in params.density {
			x := f64(x_)
			density[v] = max(1.0 / 16.0, min(16.0, x)) if finite(x) else 1.0
		}
		weighted := f64(0)
		snap := f64(params.cap_snap)
		for t in faces {
			a, b, c := vertices[t[0]], vertices[t[1]], vertices[t[2]]
			if on_cap(params, a, b, c, snap) do continue
			weighted += triangle_area(a, b, c) * (density[t[0]] + density[t[1]] + density[t[2]]) / 3.0
		}
		mean := weighted / area
		if mean > 0 do for &x in density do x /= mean
		least, most := density[0], density[0]
		for x in density {
			least = min(least, x)
			most = max(most, x)
		}
		if most - least >= 1e-3 {
			for x, v in density {
				if owner[v] == NONE do continue
				w := &d.islands[owner[v]]
				if len(w.island.density) != len(w.island.positions) {
					w.island.density = make([]f64, len(w.island.positions), heap)
					for &y in w.island.density do y = 1
				}
				w.island.density[local[v]] = x
			}
		}
	}
	// The refinement as given (clamped), each island its vertices' share; none when nothing
	// is refined.
	if len(params.refine) == len(vertices) {
		clamped :: proc(r: f32) -> f64 {
			x := f64(r)
			return max(0.25, min(1.0, x)) if finite(x) else 1.0
		}
		any_refined := false
		for r in params.refine do if clamped(r) < 1 do any_refined = true
		if any_refined {
			for r, v in params.refine {
				if owner[v] == NONE do continue
				w := &d.islands[owner[v]]
				if len(w.island.refine) != len(w.island.positions) {
					w.island.refine = make([]f64, len(w.island.positions), heap)
					for &y in w.island.refine do y = 1
				}
				w.island.refine[local[v]] = clamped(r)
			}
		}
	}
	// A feature edge goes to the island of its ends, in that island's numbers.
	edges := make([][dynamic][2]u32, len(d.islands), heap)
	defer delete(edges, heap)
	for e := 0; e + 1 < len(params.features); e += 2 {
		a, b := params.features[e], params.features[e + 1]
		if int(a) >= len(vertices) || int(b) >= len(vertices) || a == b do continue
		if owner[a] == NONE || owner[a] != owner[b] do continue
		if edges[owner[a]] == nil do edges[owner[a]] = make([dynamic][2]u32, heap)
		append(&edges[owner[a]], [2]u32{local[a], local[b]})
	}
	for &w, i in d.islands {
		if len(edges[i]) == 0 {
			delete(edges[i])
			continue
		}
		w.island.features = make([][2]u32, len(edges[i]), heap)
		copy(w.island.features, edges[i][:])
		delete(edges[i])
	}
}

// std::isfinite.
@(private = "file")
finite :: proc(x: f64) -> bool {
	return !math.is_nan(x) && !math.is_inf(x)
}
