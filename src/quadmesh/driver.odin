package quadmesh

import "base:runtime"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"

// The driver: the input split into islands (MeshSeparator's flood, as AutoRemesher splits
// it), each island's values given out, the quad size worked out, each island through the
// stages with its covers landing on its share of the count, and the islands' quads joined
// in order. Islands run on threads of their own up to the thread count, each whole on one
// thread; one island alone spreads its stages' loops over the threads instead. A stage's
// output is checked (checks.odin) and, when Params.dump names a folder, written there
// (dump.odin).

// Where an island's own 0..1 progress splits across its stages, and the islands' share of
// the whole bar.
@(private = "file")
ISLAND_RESAMPLE_END :: f32(0.17)
@(private = "file")
ISLAND_PARAMETERIZE_END :: f32(0.50)
@(private = "file")
PARALLEL_PHASE_BEGIN :: f32(0.03)
@(private = "file")
PARALLEL_PHASE_END :: f32(0.95)

// The landing's tolerance and the covers it may solve. A later cover refills the first's
// plan and takes a fraction of its time, so the landing closes in to the 2 % a count is
// asked to land within (a mirrored half's mending and rounding take some of it), and may
// take a few covers where the cells step (an open half's rows between its border and its
// singular vertices are whole).
@(private)
LANDING_MISS :: 0.015
@(private)
LANDING_COVERS :: 8

// The fewest triangles the isotropic mesh is sized for, and the most times finer than the
// plain size (about two triangles a quad) a low count's edge may be for them (the count
// Quad Remesh asks of it stays what it was): at the plain size a part a few quads round
// is a tube of three or four triangles round it, too coarse for the cover to wrap, which
// folds it flat for the extraction to cap off. A creature's tail at 1,200 quads was a
// tube of four, its cover folded on 245 of its triangles and the tail cut off at its root
// (36 % of the creature's size missing); half the edge kept it, and its ears and
// feet, at every count from 500 to 3,000 (the most missing 2 to 6 %). Counts of 4,000 and
// up are sized as before. The mesh is never asked for more than half the input's
// triangles, as an input that coarse has no detail finer than its own triangles, and a
// mesh finer than them sees their facets as curvature: three spheres of 1,280 triangles
// at 1,200 quads got 336 singular vertices and a cover folded in six places. An island
// with a frozen border keeps the plain size, which its border's band (frozen.odin) is
// graded at.
@(private)
ISOTROPIC_LEAST :: 8000.0
@(private)
ISOTROPIC_FINEST :: 2.0

@(private = "file")
Driver :: struct {
	params:          ^Params,
	progress:        ^jobs.Progress,
	share:           [2]f32,
	voxel_size:      f64, // the isotropic edge, finer than the plain one at a low count
	voxel_plain:     f64, // the plain one, about two triangles a quad
	quad_edge:       f64,
	threads:         int,
	pool:            ^jobs.Pool, // the stages' loops, while the islands run one at a time
	islands:         []Island_Work,
	lock:            sync.Mutex, // over the progress, the cancel and the reasons
	island_progress: []f32,
	island_weight:   []f32,
	cancelled:       bool, // sticky: once cancelled, every island stops
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
	cells:  f64, // the island's share of the count: its area times its density over the whole's
}

// A stage's progress tag: the island and the share of its own bar the stage covers.
@(private = "file")
Stage_Tag :: struct {
	driver:     ^Driver,
	island:     int,
	begin, end: f32,
}

// The remesh `remesh` asks for, its checks summed over the islands.
@(private)
driver_remesh :: proc(positions: []geom.Vec3, indices: []u32, params: Params, progress: ^jobs.Progress, share: [2]f32, allocator: runtime.Allocator) -> (out: Polygon_Mesh, times: Times, checks: Checks, err: Error, reason: string) {
	heap := runtime.heap_allocator()
	params := params
	d := new(Driver, heap)
	defer free(d, heap)
	d.params, d.progress, d.share = &params, progress, share
	if !driver_whole(d, 0, "Computing voxel size") do return {}, {}, {}, .Cancelled, ""
	// The input in doubles, as the stages keep it, until the islands have their own copies.
	vertices := make([][3]f64, len(positions), heap)
	vertices_kept := true
	defer if vertices_kept do delete(vertices, heap)
	for p, v in positions do vertices[v] = {f64(p.x), f64(p.y), f64(p.z)}
	faces := (cast([^][3]u32)raw_data(indices))[:len(indices) / 3]
	// Where threads run inline (the web version), more than one would only wait on itself.
	d.threads = clamp(params.threads, 1, MAX_THREADS) if thread.IS_SUPPORTED else 1
	// The isotropic target: a triangle of the area that twice the quads asked would give,
	// as an equilateral, finer at a low count for ISOTROPIC_LEAST triangles in all, up to
	// ISOTROPIC_FINEST times; the quad edge wanted is the plain one.
	area := mesh_area(vertices, faces)
	d.voxel_plain = math.sqrt((area / (2.0 * f64(u32(params.quads)))) / EQUILATERAL_AREA)
	least := min(ISOTROPIC_LEAST, f64(len(faces)) / 2)
	d.voxel_size = d.voxel_plain / clamp(d.voxel_plain / math.sqrt((area / least) / EQUILATERAL_AREA), 1, ISOTROPIC_FINEST)
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
		// One island at a time: its stages spread their loops over the threads.
		stage_pool: jobs.Pool
		if d.threads > 1 {
			jobs.pool_init(&stage_pool, d.threads - 1, heap)
			d.pool = &stage_pool
		}
		defer if d.pool != nil {
			jobs.pool_destroy(&stage_pool)
			d.pool = nil
		}
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
		if reason_string(&d.failure) == "" do return {}, {}, {}, .Failed, "the remesh gave no polygons"
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
		decimate_ms         = f64(sync.atomic_load(&d.decimate_ns)) / 1e6,
		isotropic_ms        = f64(sync.atomic_load(&d.isotropic_ns)) / 1e6,
		parameterize_ms     = f64(sync.atomic_load(&d.parameterize_ns)) / 1e6,
		extract_ms          = f64(sync.atomic_load(&d.extract_ns)) / 1e6,
		isotropic_triangles = sync.atomic_load(&d.isotropic_triangles),
		covers              = sync.atomic_load(&d.covers),
	}
	_ = driver_whole(d, 1, "Done")
	return out, times, checks, .None, ""
}

// The area of an equilateral triangle of unit edge, as AutoRemesher writes it.
@(private)
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

// An island reports its own 0..1 and the bar gets the islands' whole, each weighted by
// its share of the triangles; false once cancelled.
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

// One island through the stages (AutoRemesher's remeshIsland's order): thinned, remeshed
// isotropically, covered until the cells land on the count, its quads extracted. `serial`
// keeps the stages' own loops on this thread.
@(private = "file")
island_remesh :: proc(d: ^Driver, i: int, serial: bool) {
	w := &d.islands[i]
	params := d.params
	reason: Reason
	if !driver_report(d, i, 0) do return
	t0 := time.tick_now()
	voxel_size := d.voxel_plain if len(w.island.frozen) == len(w.island.positions) else d.voxel_size
	thin, decimated, err := odin_thin(w.island, voxel_size, d.quad_edge, f64(params.sharp_degrees), d.pool)
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	w.checks.islands = 1
	checks_thin(&w.checks, thin)
	w.checks.thin_decimated = 1 if decimated else 0
	dump_thin(params.dump, i, w.island, thin)
	island_destroy(&w.island)
	w.island = thin
	// The frozen border, which the thinning kept as it was and every stage after keeps, and
	// the isotropic edge graded from it, which may ask more quads than the island's share
	// when the border alone needs them (frozen.odin).
	border := frozen_border(w.island)
	defer frozen_border_destroy(&border)
	away := d.quad_edge
	if len(border.points) > 0 do w.cells, away = frozen_grade(&w.island, border, d.quad_edge, w.cells)
	add_ns(&d.decimate_ns, t0)

	t1 := time.tick_now()
	tag := Stage_Tag{d, i, 0, ISLAND_RESAMPLE_END}
	run := Stage_Run{d.threads, serial, driver_stage_progress, &tag, d.pool}
	iso: Isotropic
	iso, err = odin_isotropic(w.island, voxel_size, f64(params.adaptivity), f64(params.sharp_degrees), &run, &reason, &w.checks)
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	defer isotropic_destroy(&iso)
	// The rest of the stages work on the isotropic mesh alone, but for the area the count
	// was asked of.
	island_area := mesh_area(w.island.positions, w.island.triangles)
	island_destroy(&w.island)
	add_ns(&d.isotropic_ns, t1)
	sync.atomic_add(&d.isotropic_triangles, len(iso.triangles))
	// The frozen border's band on the isotropic mesh: the field turns by its sizes and the
	// landing's first cover is sized by them, and each cover grades them again at its own
	// scaling (frozen_regrade).
	band: Frozen_Band
	defer frozen_band_destroy(&band)
	if len(border.points) > 0 do band = frozen_band(&iso, away, d.quad_edge)
	checks_isotropic(&w.checks, iso)
	dump_isotropic(params.dump, i, iso)
	if !driver_report(d, i, ISLAND_RESAMPLE_END) do return
	if len(iso.positions) == 0 || len(iso.triangles) == 0 {
		_ = driver_report(d, i, 1)
		return
	}

	// The cover multiplies its scaling by the isotropic mesh's mean edge, so the quad edge
	// wanted divided by that mean asks for it; the cover's own area in cells then says how
	// far off the count will be, and more covers correct the scaling by it, up to
	// LANDING_COVERS in all. A count Params.scaling fixed is left alone.
	t2 := time.tick_now()
	landing := params.scaling <= 0
	scaling := f64(params.scaling)
	if landing {
		mean := iso.mean_edge
		scaling = d.quad_edge / mean if mean > 0 else 1.0
	}
	// A face whose quads are s times the size covers 1 / s² as many cells. The landing aims
	// at the island's share of the count as the input measured it (islands_fill), and the
	// first cover's quads are sized so the isotropic mesh's scaled area holds that many: it
	// is smoother than the island, so smaller, and where a density varies its coarse
	// triangles weigh the densest vertices more than the input's did.
	heap := runtime.heap_allocator()
	scaled_area := f64(0)
	scaled := len(iso.vertex_scale) == len(iso.positions)
	for t in iso.triangles {
		a := triangle_area(iso.positions[t[0]], iso.positions[t[1]], iso.positions[t[2]])
		s := (iso.vertex_scale[t[0]] + iso.vertex_scale[t[1]] + iso.vertex_scale[t[2]]) / 3.0 if scaled else 1.0
		scaled_area += a / (s * s)
	}
	cells_wanted := w.cells
	if cells_wanted <= 0 do cells_wanted = island_area / (d.quad_edge * d.quad_edge)
	if landing && scaled_area > 0 && cells_wanted > 0 && iso.mean_edge > 0 do scaling = math.sqrt(scaled_area / cells_wanted) / iso.mean_edge
	guided := odin_face_guides(iso, d.quad_edge, params.guides, params.guide_strength, heap)
	defer delete(guided, heap)
	anisotropy := f64(params.anisotropy) if params.anisotropy > 0 else 1.0
	// The field is solved once for all the island's covers, as none of it depends on the
	// scaling.
	cover_span := ISLAND_PARAMETERIZE_END - ISLAND_RESAMPLE_END
	tag = {d, i, ISLAND_RESAMPLE_END, ISLAND_RESAMPLE_END + cover_span * FIELD_SHARE}
	field: Field
	field, err = odin_field(iso, guided, f64(params.adaptivity), anisotropy, f64(params.sharp_degrees), &run, &reason, &w.checks)
	defer field_destroy(&field)
	if err == .Failed {
		fail_island(d, i, &reason, t2)
		return
	}
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	cover_from := ISLAND_RESAMPLE_END + cover_span * FIELD_SHARE
	cover_span -= cover_span * FIELD_SHARE
	// The cover's work that does not depend on the scaling, once for all the covers.
	tag = {d, i, cover_from, ISLAND_PARAMETERIZE_END}
	plan: Cover_Plan
	plan, err = odin_cover_plan(iso, field, guided, f64(params.sharp_degrees), &run, &reason)
	defer cover_plan_destroy(&plan)
	if len(band.distance) > 0 do plan.band = &band
	if err == .Failed {
		fail_island(d, i, &reason, t2)
		return
	}
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	cover, best: Cover
	defer cover_destroy(&cover)
	defer cover_destroy(&best)
	best_miss, under_scaling, under_cells, over_scaling, over_cells: f64
	best_misses := 0
	last_cells := f64(-1)
	border_holds := false
	best_scaling := scaling
	for pass in 0 ..< LANDING_COVERS {
		// The first cover takes the whole parameterize share of the bar; a later one the
		// last third of it again, so the bar steps back a little rather than stalling.
		tag = {d, i, cover_from if pass == 0 else cover_from + cover_span * 0.67, ISLAND_PARAMETERIZE_END}
		sync.atomic_add(&d.covers, 1)
		cover_destroy(&cover)
		cover, err = odin_cover_at(&plan, scaling, &run, &reason, &w.checks)
		w.checks.covers += 1
		if err == .Failed {
			fail_island(d, i, &reason, t2)
			return
		}
		if err != .None {
			driver_fail(d, err, &reason)
			return
		}
		cells := cover_cells(cover)
		dump_cover(params.dump, i, pass, iso, cover, scaling, cells, cells_wanted)
		if !landing || len(cover.uvs) == 0 do break
		if cells <= 0 || cells_wanted <= 0 do break
		miss := abs(cells / cells_wanted - 1.0)
		// With a frozen border, the cover that keeps more of its edges one step each wins
		// before the count: the border's quads are set by its edges, and a scaling the
		// count asks that they cannot follow squeezes them into steps of none.
		misses := frozen_misses(cover, iso.corner_frozen) if len(border.points) > 0 else 0
		if pass == 0 || misses < best_misses || (misses == best_misses && miss < best_miss) {
			cover_destroy(&best)
			best, cover = cover, {}
			best_miss = miss
			best_misses = misses
			best_scaling = scaling
		}
		if best_miss <= LANDING_MISS || pass == LANDING_COVERS - 1 do break
		// A frozen border sets the count near it, and where it sets the whole island's, a
		// new scaling gives the cells of one before: the landing has nowhere to go, nor
		// has the extraction's.
		if len(border.points) > 0 && pass > 0 && abs(cells - last_cells) < 0.5 {
			border_holds = true
			break
		}
		last_cells = cells
		// A cover a quarter of the ask or less, or four times it, came out folded up and
		// says nothing of how the cells go with the scaling, so it bounds no bracket.
		folded := cells * 4.0 <= cells_wanted || cells >= 4.0 * cells_wanted
		// The end of the bracket on a cover's side moves to its scaling, which is closer in,
		// even when its cells are no nearer (AutoRemesher moves an end only to a cover nearer
		// the ask): the cells go in steps, and not quite evenly (a cover nearer the step can
		// have a cell or two more than one further off), so keeping the further end tried the
		// same scaling again until the covers ran out; the next try is then between the two
		// scalings nearest the step.
		if !folded && cells < cells_wanted do under_scaling, under_cells = scaling, cells
		if !folded && cells > cells_wanted do over_scaling, over_cells = scaling, cells
		// Between a cover under the ask and one over it, the scaling is found between theirs
		// as the cells go; otherwise the cells go as the scaling squared, inversely, a step
		// held within a factor of 1.5 either way.
		if under_cells > 0 && over_cells > 0 {
			scaling = under_scaling * math.pow(over_scaling / under_scaling, math.ln(cells_wanted / under_cells) / math.ln(over_cells / under_cells))
		} else {
			scaling *= max(STEP_LEAST, min(1.5, math.sqrt(cells / cells_wanted)))
		}
	}
	if len(best.uvs) > 0 {
		cover_destroy(&cover)
		cover, best = best, {}
	}
	// The landing's covers round their integers all at once, which folds a cover where two
	// near-halfway integers round apart; where the kept one folds more than ROUNDS_FOLDED of
	// its triangles (a coarse count on a detailed mesh: 6 % on a creature at 1,000 quads,
	// 1.2 % at 2,500, 0.3 % at 10,000, none on a sphere at 20,000), it is solved again at
	// its scaling with the integers rounded in ROUNDING_ROUNDS rounds, and kept when that
	// folds less. On the creature at 500 to 1,500 quads that took four-valent vertices from
	// 74 % to 79 % on average, with a tenth fewer folded triangles; at 2,500 it gained under
	// a point for a third more time, as each round is a factorization, so a count whose
	// cover hardly folds does not pay for them.
	rounds := 1
	if folded := cover_flipped(cover); landing && len(cover.uvs) > 0 && f64(folded) > ROUNDS_FOLDED * f64(len(cover.uvs)) {
		sync.atomic_add(&d.covers, 1)
		w.checks.covers += 1
		again: Cover
		again, err = odin_cover_at(&plan, best_scaling, &run, &reason, &w.checks, ROUNDING_ROUNDS)
		if err == .Cancelled {
			driver_fail(d, err, &reason)
			return
		}
		if err == .None && len(again.uvs) > 0 && cover_flipped(again) < folded {
			cover_destroy(&cover)
			cover, again = again, {}
			rounds = ROUNDING_ROUNDS
		}
		cover_destroy(&again)
		err = .None
	}
	add_ns(&d.parameterize_ns, t2)
	before := w.checks
	checks_cover(&w.checks, iso, cover, cells_wanted)
	if !driver_report(d, i, ISLAND_PARAMETERIZE_END) do return

	t3 := time.tick_now()
	tag = {d, i, ISLAND_PARAMETERIZE_END, 1}
	w.quads, err = odin_extract(iso, cover, &run, &reason, &w.checks)
	if err != .None {
		driver_fail(d, err, &reason)
		return
	}
	add_ns(&d.extract_ns, t3)
	checks_quads(&w.checks, w.quads)
	// The extraction's quads against the island's share, less the doublets the finish
	// dissolves (quads_kept): where the cover folded, the hole is filled with fewer, larger
	// quads than its cells, which at a few hundred quads on a creature lost up to a tenth
	// of the count (and a hole's fill can come out more). Up to
	// EXTRACT_TRIES more covers, each with its cells asked short or over by as much as the
	// last came out, and the quads nearest the share kept; on a dense count the extraction
	// lands within EXTRACT_MISS and nothing is redone.
	if landing && !border_holds && w.cells > 0 {
		at := best_scaling
		kept := quads_kept(w.quads)
		got := kept
		for _ in 0 ..< EXTRACT_TRIES {
			if got <= 0 || abs(kept / w.cells - 1) <= EXTRACT_MISS do break
			at *= math.sqrt(got / w.cells)
			t4 := time.tick_now()
			trial := before
			trial.covers = w.checks.covers + 1
			w.checks.covers += 1
			sync.atomic_add(&d.covers, 1)
			again: Cover
			again, err = odin_cover_at(&plan, at, &run, &reason, &trial, rounds)
			add_ns(&d.parameterize_ns, t4)
			if err == .Cancelled {
				cover_destroy(&again)
				driver_fail(d, err, &reason)
				return
			}
			if err != .None || len(again.uvs) == 0 {
				cover_destroy(&again)
				break
			}
			checks_cover(&trial, iso, again, cells_wanted)
			t5 := time.tick_now()
			redone: Quads
			redone, err = odin_extract(iso, again, &run, &reason, &trial)
			cover_destroy(&again)
			add_ns(&d.extract_ns, t5)
			if err == .Cancelled {
				quads_destroy(&redone)
				driver_fail(d, err, &reason)
				return
			}
			got = quads_kept(redone) if err == .None else 0
			if got > 0 && abs(got / w.cells - 1) < abs(kept / w.cells - 1) {
				checks_quads(&trial, redone)
				quads_destroy(&w.quads)
				w.quads, w.checks = redone, trial
				kept = got
			} else {
				quads_destroy(&redone)
			}
		}
		err = .None
	}
	if len(border.points) > 0 {
		frozen_mend(&w.quads, border, &w.checks)
		checks_quads(&w.checks, w.quads)
	}
	dump_quads(params.dump, i, w.quads, w.checks)
	_ = driver_report(d, i, 1)
}

// How far the extraction's quads may miss the island's share before another cover is
// tried, and how many more are (island_remesh).
@(private = "file")
EXTRACT_MISS :: 0.02
@(private = "file")
EXTRACT_TRIES :: 3

// The share of a landed cover's triangles that may be folded before it is solved again
// with its integers rounded in ROUNDING_ROUNDS rounds (island_remesh).
@(private = "file")
ROUNDS_FOLDED :: 0.02
@(private = "file")
ROUNDING_ROUNDS :: 16

// The quads that stay once the finish dissolves the doublets (retopo's dissolve_doublets):
// the faces less the vertices that just two faces meet at, sharing both of its edges,
// each dissolve joining two quads into one.
@(private = "file")
quads_kept :: proc(q: Quads) -> f64 {
	faces := len(q.first) - 1
	if faces <= 0 do return 0
	heap := runtime.heap_allocator()
	count := make([]u32, len(q.positions), heap)
	defer delete(count, heap)
	for c in q.corners do count[c] += 1
	// Per vertex of two faces: the neighbours before and after it in the first face.
	ends := make([][2]u32, len(q.positions), heap)
	defer delete(ends, heap)
	seen := make([]bool, len(q.positions), heap)
	defer delete(seen, heap)
	doublets := 0
	for f in 0 ..< faces {
		c := q.corners[q.first[f]:q.first[f + 1]]
		for v, k in c do if count[v] == 2 {
			prev, next := c[(k + len(c) - 1) % len(c)], c[(k + 1) % len(c)]
			if !seen[v] {
				seen[v] = true
				ends[v] = {prev, next}
			} else if ends[v] == {next, prev} {
				doublets += 1
			}
		}
	}
	return f64(faces - doublets)
}

// The triangles a cover turns over.
@(private = "file")
cover_flipped :: proc(c: Cover) -> int {
	n := 0
	for t in c.uvs do if (t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]) < 0 do n += 1
	return n
}

// An island whose field or cover failed is left without quads, its reason kept for the
// report, as AutoRemesher leaves it.
@(private = "file")
fail_island :: proc(d: ^Driver, i: int, reason: ^Reason, from: time.Tick) {
	if reason_string(reason) != "" {
		sync.mutex_lock(&d.lock)
		d.failure = reason^
		sync.mutex_unlock(&d.lock)
	}
	add_ns(&d.parameterize_ns, from)
	_ = driver_report(d, i, 1)
}

// The share of the parameterize bar the field takes before the covers.
@(private = "file")
FIELD_SHARE :: 0.25

// The landing's smallest step down, 1 / 1.5 as AutoRemesher divides it.
@(private = "file")
STEP_LEAST :: f64(1.0 / 1.5)

// The cover's area in cells (AutoRemesher's coverCells).
@(private = "file")
cover_cells :: proc(c: Cover) -> f64 {
	cells := f64(0)
	for t in c.uvs {
		cells += 0.5 * abs((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]))
	}
	return cells
}

// The triangle's area as AutoRemesher's Vector3::area takes it.
@(private)
triangle_area :: proc(a, b, c: [3]f64) -> f64 {
	ab, ac := b - a, c - a
	x := ab.y * ac.z - ab.z * ac.y
	y := ab.z * ac.x - ab.x * ac.z
	z := ab.x * ac.y - ab.y * ac.x
	return 0.5 * math.sqrt(x * x + y * y + z * z)
}

// The input's area.
@(private = "file")
mesh_area :: proc(vertices: [][3]f64, faces: [][3]u32) -> f64 {
	area := f64(0)
	for t in faces do area += triangle_area(vertices[t[0]], vertices[t[1]], vertices[t[2]])
	return area
}

// The input's triangles island by island, as MeshSeparator::splitToIslands gives them: a
// flood from each triangle not yet reached, in order, across each edge to the last
// triangle that runs that edge the other way, first in first out, each island's triangles
// in the order the flood takes them. Island i is order[starts[i]:starts[i + 1]]. The
// directed edges are filed by their first vertex, in triangle order (a count, a prefix sum
// and a fill, linear where sorting three million edges took a third of a second), so the
// last match in a vertex's few is the last triangle, as AutoRemesher takes it.
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

// The last triangle that runs from `from` to `to`, as AutoRemesher's findFaceOfDirectedEdge
// takes it.
@(private = "file")
opposite_face :: proc(edges: Edge_File, from, to: u32) -> (face: u32, ok: bool) {
	for i := int(edges.first[from + 1]) - 1; i >= int(edges.first[from]); i -= 1 {
		if edges.to[i] == to do return edges.face[i], true
	}
	return 0, false
}

// Each island's own vertices (numbered as its triangles meet them), triangles, feature
// edges, density and refinement. A vertex two islands share
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
		for t in faces do weighted += triangle_area(vertices[t[0]], vertices[t[1]], vertices[t[2]]) * (density[t[0]] + density[t[1]] + density[t[2]]) / 3.0
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
	// Each island's share of the count, measured on the input as given: its area weighted
	// by the density (as normalized above) over the whole's, so the count lands on what was
	// asked however much the thinning and the isotropic remesh smooth away (a coarse
	// remesh of a creature loses a sixth of its area at its spikes and fingers, where the
	// thin parts ask the most).
	{
		weighted := make([]f64, len(d.islands), heap)
		defer delete(weighted, heap)
		total := f64(0)
		for i in 0 ..< len(d.islands) do for f in order[starts[i]:starts[i + 1]] {
			t := faces[f]
			a := triangle_area(vertices[t[0]], vertices[t[1]], vertices[t[2]])
			w := &d.islands[i]
			if len(w.island.density) == len(w.island.positions) {
				a *= (island_density(w, local, owner, u32(i), t[0]) + island_density(w, local, owner, u32(i), t[1]) + island_density(w, local, owner, u32(i), t[2])) / 3.0
			}
			weighted[i] += a
			total += a
		}
		for &w, i in d.islands do w.cells = f64(u32(params.quads)) * weighted[i] / total if total > 0 else 0
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
	// The frozen border, each island its vertices' share; none where nothing is marked.
	if len(params.frozen) == len(vertices) {
		for frozen, v in params.frozen {
			if !frozen || owner[v] == NONE do continue
			w := &d.islands[owner[v]]
			if len(w.island.frozen) != len(w.island.positions) do w.island.frozen = make([]bool, len(w.island.positions), heap)
			w.island.frozen[local[v]] = true
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

// The density island `i` keeps at input vertex v, 1 where another island owns v.
@(private = "file")
island_density :: proc(w: ^Island_Work, local, owner: []u32, i: u32, v: u32) -> f64 {
	return w.island.density[local[v]] if owner[v] == i else 1
}

// std::isfinite.
@(private = "file")
finite :: proc(x: f64) -> bool {
	return !math.is_nan(x) && !math.is_inf(x)
}
