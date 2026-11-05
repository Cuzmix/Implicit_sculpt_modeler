package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"

// A stand-in for the app's GPU (stroke_gpu.odin): takes the strokes of one sculptor when
// `take`, works each hand-off's normals out as job_node_normals would into its own copy,
// and gives them to the mesh only at a sync, as the real readback lands a frame or two
// on. Other sculptors (the tests run side by side) it leaves to the CPU.
@(private = "file")
Fake_Gpu :: struct {
	s:        ^Sculptor,
	take:     bool,
	dabs:     bool, // take the dabs too: lay each record as the kernels do (fake_lay)
	refuse:   bool, // and then refuse them at the hand-off, as a device out of memory would
	compute:  bool, // work the normals out at the hand-off; off leaves them stale for good
	begins:   int,
	handoffs: int,
	lasts:    int,
	syncs:    int,
	laid:     int, // dab records laid
	backs:    int, // frames that read owed normals back
	nows:     int, // syncs that read every owed normal back at once
	refuse_back: bool, // refuse reading normals back, which leaves them to the CPU
	normals:  []Vec3, // the GPU's copy
	pending:  [dynamic]Vertex_Range,
	taken:    [dynamic]Vertex_Range, // every range handed over so far
	landing:  [dynamic]Vertex_Range, // ranges whose positions the GPU moved, to land at the sync
}

@(private = "file")
fake_begin :: proc(data: rawptr, s: ^Sculptor, brush: Brush) -> Gpu_Take {
	f := cast(^Fake_Gpu)data
	if s != f.s do return .None
	f.begins += 1
	if !f.take do return .None
	return .Dabs if f.dabs else .Normals
}

// Lays a flush's records as the kernels do (dab.slang): the area from the normals
// inside the sample radius, then each vertex in reach moved by the kind, straight into
// the mesh, which stands in for the GPU's copy; the readback of the positions lands at
// the sync (fake_sync).
@(private = "file")
fake_dabs :: proc(data: rawptr, s: ^Sculptor, dabs: []Gpu_Dab) -> bool {
	f := cast(^Fake_Gpu)data
	if s != f.s || f.refuse do return false
	for rec in dabs do fake_lay(s, rec, f.normals)
	f.laid += len(dabs)
	return true
}

@(private = "file")
fake_lay :: proc(s: ^Sculptor, rec: Gpu_Dab, normals: []Vec3) {
	m := s.mesh
	normal_sum, center_sum: Vec3
	weight: f32
	if rec.kind != .Inflate || rec.alpha != nil {
		for r in rec.ranges do for v in r.first ..< r.first + r.count {
			delta := m.positions[v] - rec.center
			d2 := linalg.dot(delta, delta)
			if d2 * rec.inv_sample2 < 1 {
				w := falloff(d2 * rec.inv_sample2)
				normal_sum += normals[v] * w
				center_sum += m.positions[v] * w
				weight += w
			}
		}
	}
	normal := linalg.normalize0(normal_sum)
	plane := center_sum / weight if weight > 0 else Vec3{}
	plane += normal * rec.plane_offset
	// The alpha's frame, as alpha_frame works it out from this area.
	alpha: Alpha
	au, av, an: Vec3
	if rec.alpha != nil {
		alpha = {size = rec.alpha_size, values = rec.alpha}
		fd := Dab{normal = normal, brush = {radius = rec.radius, alpha = &alpha, alpha_up = rec.alpha_up, alpha_mirror = rec.alpha_mirror}}
		alpha_frame(&fd)
		au, av, an = fd.au, fd.av, fd.an
	}
	for r in rec.ranges do for v in r.first ..< r.first + r.count {
		p := m.positions[v]
		delta := p - rec.center
		d2 := linalg.dot(delta, delta)
		if d2 >= rec.r2 do continue
		// The kernels' weight: the round or drawn falloff, then the HD fade's and the
		// mask's shield.
		x2 := d2 * rec.inv_r2
		w := falloff(x2)
		if rec.alpha != nil {
			h := linalg.dot(delta, an)
			w = alpha_sample(&alpha, linalg.dot(delta, au), linalg.dot(delta, av)) * falloff(h * h)
		} else if rec.falloff != nil {
			if x2 >= 1 do continue
			x := x2 * FALLOFF_STEPS
			i := int(x)
			w = rec.falloff[i] + (rec.falloff[i + 1] - rec.falloff[i]) * (x - f32(i))
		}
		if rec.masked || rec.faded do w *= shield(s.fade if rec.faded else nil, s.mask if rec.masked else nil, v)
		if w <= 0 do continue
		#partial switch rec.kind {
		case .Draw, .Inflate:
			way := normal if rec.kind == .Draw else normals[v]
			if rec.once {
				l := &s.layer[v]
				h := l.height if l.stroke == rec.stroke else 0
				want := rec.amount * w
				next := max(h, want) if rec.amount > 0 else min(h, want)
				p += way * (next - h)
				l^ = {rec.stroke, next}
			} else {
				p += way * (rec.amount * w)
			}
		case .Clay:
			h := linalg.dot(p - plane, normal)
			if h * rec.amount < 0 do p -= normal * (h * min(rec.strength * w * PLANE_RATE, 1))
		case:
			continue
		}
		m.positions[v] = p
	}
}

@(private = "file")
fake_normals :: proc(data: rawptr, s: ^Sculptor, ranges: []Vertex_Range, last: bool) -> bool {
	f := cast(^Fake_Gpu)data
	if s != f.s do return false
	f.handoffs += 1
	if last do f.lasts += 1
	if f.compute {
		for r in ranges do for v in r.first ..< r.first + r.count {
			sum: Vec3
			for face in faces_of(s, v) do sum += face_normal(s.mesh, face)
			f.normals[v] = linalg.normalize0(sum)
		}
	}
	append(&f.taken, ..ranges)
	// As the readback does: with the dabs on the GPU the positions come back alone, the
	// normals after the stroke (fake_normals_back, fake_normals_now).
	if sculptor_positions_on_gpu(s) do append(&f.landing, ..ranges)
	else do append(&f.pending, ..ranges)
	return true
}

@(private = "file")
fake_normals_back :: proc(data: rawptr, s: ^Sculptor, ranges: []Vertex_Range) -> bool {
	f := cast(^Fake_Gpu)data
	if s != f.s || f.refuse_back do return false
	f.backs += 1
	append(&f.pending, ..ranges)
	return true
}

@(private = "file")
fake_normals_now :: proc(data: rawptr, s: ^Sculptor, ranges: []Vertex_Range) -> bool {
	f := cast(^Fake_Gpu)data
	if s != f.s || f.refuse_back do return false
	f.nows += 1
	for r in ranges do copy(s.mesh.normals[r.first:][:r.count], f.normals[r.first:][:r.count])
	return true
}

// The normals of a mesh the GPU worked on against a twin's that stayed on the CPU: the
// ranges the GPU took are recomputed whole, so inside them every normal is the exact one
// (the CPU's flush leaves the inner vertices of a node whose border alone moved as they
// were, its own approximation, so the twin's can be a little off there); outside them
// neither path touched a normal, so there the two agree bit for bit.
@(private = "file")
expect_gpu_normals :: proc(t: ^testing.T, m: ^geom.Mesh, twin: ^geom.Mesh, taken: []Vertex_Range, what: string) {
	expected := geom.Mesh{positions = m.positions, indices = m.indices}
	expected.normals = make([dynamic]Vec3, len(m.normals), context.temp_allocator)
	geom.mesh_recompute_normals(&expected)
	inside := make([]bool, len(m.normals), context.temp_allocator)
	for r in taken do for v in r.first ..< r.first + r.count do inside[v] = true
	for n, v in m.normals {
		if inside[v] {
			if off := linalg.length(n - expected.normals[v]); off >= 1e-5 {
				testing.expectf(t, false, "vertex %d: its normal is %g off the exact one %s", v, off, what)
				return
			}
		} else if n != twin.normals[v] {
			testing.expectf(t, false, "vertex %d: outside the ranges the GPU took its normal is %v %s, the twin's %v", v, n, what, twin.normals[v])
			return
		}
	}
}

@(private = "file")
fake_sync :: proc(data: rawptr, s: ^Sculptor) -> bool {
	f := cast(^Fake_Gpu)data
	if s != f.s do return true
	f.syncs += 1
	for r in f.pending do copy(s.mesh.normals[r.first:][:r.count], f.normals[r.first:][:r.count])
	clear(&f.pending)
	// As the GPU's bounds kernel does: each node's bounds over its own and shared vertices.
	if len(f.landing) > 0 {
		nodes := sculptor_range_gpu_nodes(s, f.landing[:])
		bounds := make([]geom.Aabb, len(nodes), context.temp_allocator)
		for n, k in nodes {
			bounds[k] = geom.AABB_EMPTY
			for p in s.mesh.positions[n.vert_first:][:n.vert_count] do geom.aabb_grow(&bounds[k], p)
			for v in sculptor_gpu_shared(s)[n.shared_first:][:n.shared_count] do geom.aabb_grow(&bounds[k], s.mesh.positions[v])
		}
		sculptor_positions_landed(s, f.landing[:], nodes, bounds)
	}
	clear(&f.landing)
	return true
}

@(private = "file")
fake_destroy :: proc(f: ^Fake_Gpu) {
	delete(f.normals)
	delete(f.pending)
	delete(f.taken)
	delete(f.landing)
}

// A twin's leaf bounds against the GPU sculptor's after its positions landed: the
// landing refits them exactly, as the CPU's finish_move does.
@(private = "file")
expect_bounds_refit :: proc(t: ^testing.T, s, twin: ^Sculptor, what: string) {
	for n, id in s.nodes {
		if n.leaf == geom.BVH_NONE do continue
		b, tb := s.bvh.nodes[n.leaf].bounds, twin.bvh.nodes[twin.nodes[id].leaf].bounds
		if linalg.length(b.lo - tb.lo) > 1e-5 || linalg.length(b.hi - tb.hi) > 1e-5 {
			testing.expectf(t, false, "node %d: its bounds are %v..%v %s, the twin's %v..%v", id, b.lo, b.hi, what, tb.lo, tb.hi)
			return
		}
		testing.expectf(t, s.gpu_pending[id] == 0, "node %d still waits for %d readbacks %s", id, s.gpu_pending[id], what)
		// The landing's bounds are a full refit's.
		exact := geom.AABB_EMPTY
		for v in n.vert_first ..< n.vert_first + n.vert_count do geom.aabb_grow(&exact, s.mesh.positions[v])
		for v in node_shared(s, u32(id)) do geom.aabb_grow(&exact, s.mesh.positions[v])
		if b != exact {
			testing.expectf(t, false, "node %d: its bounds are %v..%v %s, a refit's %v..%v", id, b.lo, b.hi, what, exact.lo, exact.hi)
			return
		}
	}
}

// The GPU sculptor's positions against a twin's, within `tolerance` (0 for bit for bit).
@(private = "file")
expect_positions :: proc(t: ^testing.T, m, twin: ^geom.Mesh, tolerance: f32, what: string) {
	worst: f32
	at: int
	for p, v in m.positions {
		if off := linalg.length(p - twin.positions[v]); off > worst {
			worst, at = off, v
		}
	}
	testing.expectf(t, worst <= tolerance, "vertex %d: the GPU stroke put it at %v %s, the CPU's at %v (%g off)", at, m.positions[at], what, twin.positions[at], worst)
}


// Three dabs along a short path, as the stroke tool lays them.
@(private = "file")
fake_stroke :: proc(s: ^Sculptor, flush_each: bool) -> (ranges: [dynamic]Vertex_Range) {
	sculptor_stroke_begin(s)
	for k in 0 ..< 3 {
		_ = apply_dab(s, {kind = .Draw, radius = 0.3, strength = 0.5}, linalg.normalize(Vec3{0.1 * f32(k), 0.05 * f32(k), 1}))
		if flush_each do append(&ranges, ..sculptor_flush(s))
	}
	_ = sculptor_stroke_end(s)
	append(&ranges, ..sculptor_flush(s))
	return
}

// The scenarios run one after another from one test, since the tests of a package
// run side by side and all of them set the package's stroke_gpu.
@(test)
stroke_gpu_hand_off :: proc(t: ^testing.T) {
	stroke_gpu_takes_the_normals_and_gives_them_back_at_a_sync(t)
	stroke_gpu_matches_the_cpu_path_with_exact_normals(t)
	stroke_gpu_ranges_given_back_are_recomputed_by_the_cpu(t)
	stroke_gpu_dabs_match_the_cpu_and_undo(t)
	stroke_gpu_dabs_refused_are_laid_by_the_cpu(t)
	stroke_gpu_dabs_pending_at_a_sync_are_laid_by_the_cpu(t)
	stroke_gpu_dabs_step_down_for_a_brush_the_kernels_lack(t)
	stroke_gpu_dabs_normals_come_back_after_the_stroke(t)
	stroke_gpu_dabs_masked_and_drawn_match_the_cpu(t)
	stroke_gpu_dabs_faded_match_the_cpu(t)
	stroke_gpu_dabs_with_an_alpha_match_the_cpu(t)
}

// Two sculptors, each stroked the same way: the twin on the CPU, the other with its dabs
// recorded for the stand-in, which lays them as the kernels do and lands the positions at
// the sync after each flush, as --gpu-sculpt-sync has the app do.
@(private = "file")
dabs_pair :: proc(t: ^testing.T, f: ^Fake_Gpu, a, b: ^Sculptor, brushes: []Brush, sync_each: bool) {
	for brush in brushes {
		sculptor_stroke_begin(a)
		sculptor_stroke_begin(b)
		for k in 0 ..< 3 {
			at := linalg.normalize(Vec3{0.1 * f32(k), 0.05 * f32(k), 1})
			_ = apply_dab(a, brush, at)
			_ = sculptor_flush(a)
			_ = apply_dab(b, brush, at)
			_ = sculptor_flush(b)
			if sync_each do _ = sculptor_gpu_sync(b)
		}
		_ = sculptor_stroke_end(a)
		_ = sculptor_flush(a)
		_ = sculptor_stroke_end(b)
		_ = sculptor_flush(b)
		_ = sculptor_gpu_sync(b)
	}
}

@(private = "file")
dabs_fixture :: proc(f: ^Fake_Gpu, ma, mb: ^geom.Mesh, a, b: ^Sculptor) {
	ma^, mb^ = geom.icosphere(5), geom.icosphere(5)
	sculptor_init(a, ma, nil, 64)
	sculptor_init(b, mb, nil, 64)
	_ = sculptor_flush(a)
	_ = sculptor_flush(b)
	f^ = Fake_Gpu{s = b, take = true, dabs = true, compute = true, normals = make([]Vec3, len(mb.normals))}
	copy(f.normals, mb.normals[:])
	stroke_gpu = {data = f, begin = fake_begin, dabs = fake_dabs, normals = fake_normals, sync = fake_sync, normals_back = fake_normals_back, normals_now = fake_normals_now}
}

@(private = "file")
stroke_gpu_dabs_match_the_cpu_and_undo :: proc(t: ^testing.T) {
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	before := make([]Vec3, len(mb.positions), context.temp_allocator)
	copy(before, mb.positions[:])

	// Draw with Accumulate off (the default), whose heights the kernels keep, then Clay,
	// which works along the area's plane, then Draw accumulating.
	brushes := []Brush{{kind = .Draw, radius = 0.3, strength = 0.5, no_accumulate = true}, {kind = .Clay, radius = 0.3, strength = 0.5}, {kind = .Draw, radius = 0.3, strength = 0.5}}
	dabs_pair(t, &f, &a, &b, brushes, true)
	testing.expectf(t, f.begins == 3 && f.laid == 9 && f.handoffs == 9, "every dab of the three strokes was recorded and laid by the stand-in (begins %d, laid %d, hand-offs %d)", f.begins, f.laid, f.handoffs)
	testing.expect(t, sculptor_stroke_on_gpu(&b) == .None, "the last flush gives the stroke back")
	// The stand-in sums the area in another order than the CPU's leaves, so the two agree
	// to rounding, not bit for bit.
	expect_positions(t, &mb, &ma, 1e-5, "after three GPU strokes")
	expect_gpu_normals(t, &mb, &ma, f.taken[:], "after three GPU strokes")
	expect_bounds_refit(t, &b, &a, "after three GPU strokes")
	moved := 0
	for p, v in mb.positions do if p != before[v] do moved += 1
	testing.expect(t, moved > 0, "the strokes moved vertices")

	// Undo brings every vertex back as the CPU's does: the records saved the hit nodes
	// before the GPU moved them.
	for _ in 0 ..< 3 {
		testing.expect(t, sculptor_undo(&a) && sculptor_undo(&b), "undo")
	}
	for p, v in mb.positions do if p != before[v] {
		testing.expectf(t, false, "vertex %d: after undo it is at %v, it was at %v", v, p, before[v])
		break
	}
	expect_positions(t, &mb, &ma, 0, "after undo")
	testing.expect(t, sculptor_redo(&b), "redo")
	testing.expect(t, sculptor_redo(&a), "redo")
	testing.expect(t, sculptor_redo(&b) && sculptor_redo(&a) && sculptor_redo(&b) && sculptor_redo(&a), "redo")
	expect_positions(t, &mb, &ma, 1e-5, "after redo")
}

@(private = "file")
stroke_gpu_dabs_refused_are_laid_by_the_cpu :: proc(t: ^testing.T) {
	// The GPU takes the dabs and then refuses the first flush's records (its buffers are
	// out of memory): the CPU lays them from the mirror and the stroke steps down to
	// Normals, so it ends as the twin's, bit for bit.
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	f.refuse = true
	dabs_pair(t, &f, &a, &b, {{kind = .Draw, radius = 0.3, strength = 0.5, no_accumulate = true}}, true)
	testing.expectf(t, f.begins == 1 && f.laid == 0 && f.handoffs == 3, "the refused dabs were laid by the CPU and the normals still handed over (laid %d, hand-offs %d)", f.laid, f.handoffs)
	expect_positions(t, &mb, &ma, 0, "after the refused stroke")
	expect_gpu_normals(t, &mb, &ma, f.taken[:], "after the refused stroke")
	testing.expect(t, sculptor_undo(&b), "undo")
	testing.expect(t, sculptor_undo(&a), "undo")
	expect_positions(t, &mb, &ma, 0, "after undo of the refused stroke")
}

@(private = "file")
stroke_gpu_dabs_pending_at_a_sync_are_laid_by_the_cpu :: proc(t: ^testing.T) {
	// Something reads the mesh between a dab and its flush (a sync with records pending):
	// the CPU lays the records then, and the rest of the stroke stays on the CPU's dabs.
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	brush := Brush{kind = .Draw, radius = 0.3, strength = 0.5, no_accumulate = true}
	sculptor_stroke_begin(&a)
	sculptor_stroke_begin(&b)
	for k in 0 ..< 3 {
		at := linalg.normalize(Vec3{0.1 * f32(k), 0.05 * f32(k), 1})
		_ = apply_dab(&a, brush, at)
		_ = sculptor_flush(&a)
		_ = apply_dab(&b, brush, at)
		if k == 0 {
			testing.expect(t, sculptor_stroke_on_gpu(&b) == .Dabs, "the stroke runs its dabs on the GPU")
			_ = sculptor_gpu_sync(&b)
			testing.expect(t, sculptor_stroke_on_gpu(&b) == .Normals, "a sync with records pending steps the stroke down to Normals")
		}
		_ = sculptor_flush(&b)
		_ = sculptor_gpu_sync(&b)
	}
	_ = sculptor_stroke_end(&a)
	_ = sculptor_flush(&a)
	_ = sculptor_stroke_end(&b)
	_ = sculptor_flush(&b)
	_ = sculptor_gpu_sync(&b)
	testing.expectf(t, f.laid == 0 && f.handoffs == 3, "nothing reached the stand-in's dabs (laid %d, hand-offs %d)", f.laid, f.handoffs)
	expect_positions(t, &mb, &ma, 0, "after the stroke")
	expect_gpu_normals(t, &mb, &ma, f.taken[:], "after the stroke")
}

@(private = "file")
stroke_gpu_dabs_normals_come_back_after_the_stroke :: proc(t: ^testing.T) {
	// The readbacks of a stroke whose dabs run on the GPU carry the positions alone; the
	// normals follow after the stroke, a slice a frame, and a sync that reads the
	// positions alone (the simplified copies') leaves them to that. Then a refused read
	// gives them to the CPU, which works them out from the positions.
	for refuse in ([]bool{false, true}) {
		ma, mb: geom.Mesh
		a, b: Sculptor
		f: Fake_Gpu
		dabs_fixture(&f, &ma, &mb, &a, &b)
		defer geom.mesh_destroy(&ma)
		defer geom.mesh_destroy(&mb)
		defer sculptor_destroy(&a)
		defer sculptor_destroy(&b)
		defer fake_destroy(&f)
		defer stroke_gpu = {}
		f.refuse_back = refuse
		brush := Brush{kind = .Draw, radius = 0.3, strength = 0.5}
		before := slice.clone(mb.normals[:], context.temp_allocator)
		sculptor_stroke_begin(&a)
		sculptor_stroke_begin(&b)
		for k in 0 ..< 3 {
			at := linalg.normalize(Vec3{0.1 * f32(k), 0.05 * f32(k), 1})
			_ = apply_dab(&a, brush, at)
			_ = sculptor_flush(&a)
			_ = apply_dab(&b, brush, at)
			_ = sculptor_flush(&b)
			_ = sculptor_gpu_sync(&b, normals = false)
		}
		testing.expect(t, len(b.gpu_owed_list) > 0, "the stroke's normals are owed")
		unchanged := true
		for r in f.taken do for v in r.first ..< r.first + r.count do if mb.normals[v] != before[v] do unchanged = false
		testing.expect(t, unchanged, "the mesh keeps its normals while the stroke's dabs run on the GPU")
		_ = sculptor_stroke_end(&a)
		_ = sculptor_flush(&a)
		_ = sculptor_stroke_end(&b)
		// The last flush hands the stroke back; each frame then asks for a slice after its
		// flush, as the app's frame does, and the frames' readbacks land at the sync.
		for frame := 0; frame < 8; frame += 1 {
			_ = sculptor_flush(&b)
			sculptor_gpu_back(&b)
			_ = sculptor_gpu_sync(&b, normals = false)
		}
		testing.expect(t, len(b.gpu_owed_list) == 0, "every owed normal came back")
		testing.expectf(t, f.nows == 0, "nothing read them all at once (%d)", f.nows)
		testing.expectf(t, (f.backs > 0) != refuse, "the frames read them back (%d), unless refused", f.backs)
		what := "after the stroke, read back refused" if refuse else "after the stroke"
		expect_positions(t, &mb, &ma, 1e-5, what)
		expect_gpu_normals(t, &mb, &ma, f.taken[:], what)
	}
}

@(private = "file")
stroke_gpu_dabs_step_down_for_a_brush_the_kernels_lack :: proc(t: ^testing.T) {
	// A brush the kernels do not lay (Layer) keeps the normals on the GPU and the dabs on
	// the CPU; a dab's record carries the brush's terms.
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	sculptor_stroke_begin(&b)
	_ = apply_dab(&b, {kind = .Layer, radius = 0.3, strength = 0.5}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_on_gpu(&b) == .Normals, "Layer keeps its dabs on the CPU")
	_ = sculptor_stroke_end(&b)
	_ = sculptor_flush(&b)
	_ = sculptor_gpu_sync(&b)
	testing.expect_value(t, f.laid, 0)

	sculptor_stroke_begin(&b)
	_ = apply_dab(&b, {kind = .Clay, radius = 0.3, strength = 0.5, invert = true, no_accumulate = true}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_on_gpu(&b) == .Dabs && len(b.gpu_dabs) == 1, "Clay's dab is recorded")
	if len(b.gpu_dabs) == 1 {
		rec := b.gpu_dabs[0]
		testing.expectf(t, rec.kind == .Clay && rec.amount == -1 && abs(rec.plane_offset + 0.3 * CLAY_HEIGHT) < 1e-6 && abs(rec.r2 - 0.09) < 1e-6 && !rec.once && rec.stroke == b.layer_stroke && len(rec.ranges) == 0 && rec.range_count > 0, "the record carries Clay's terms: %v", rec)
	}
	_ = sculptor_stroke_end(&b)
	_ = sculptor_flush(&b)
	_ = sculptor_gpu_sync(&b)
	testing.expect_value(t, f.laid, 1)
}

@(private = "file")
stroke_gpu_takes_the_normals_and_gives_them_back_at_a_sync :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_ = sculptor_flush(&s)
	f := Fake_Gpu{s = &s, take = true, compute = true, normals = make([]Vec3, len(m.normals))}
	defer delete(f.normals)
	defer delete(f.pending)
	defer delete(f.taken)
	copy(f.normals, m.normals[:])
	stroke_gpu = {data = &f, begin = fake_begin, normals = fake_normals, sync = fake_sync, normals_back = fake_normals_back, normals_now = fake_normals_now}
	defer stroke_gpu = {}

	before := make([]Vec3, len(m.normals), context.temp_allocator)
	copy(before, m.normals[:])
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_on_gpu(&s) == .Normals, "the GPU was offered the stroke and took it, so the stroke should run there")
	testing.expect_value(t, f.begins, 1)
	ranges := sculptor_flush(&s)
	testing.expect(t, len(ranges) > 0 && f.handoffs == 1 && f.lasts == 0, "the first flush hands its ranges over, not as the last")
	// The CPU's normals wait for the readback: still the old ones where the dab moved vertices.
	stale := 0
	for r in ranges do for v in r.first ..< r.first + r.count do if m.normals[v] == before[v] do stale += 1
	testing.expect(t, stale > 0, "the CPU recomputed normals the GPU took")
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5}, linalg.normalize(Vec3{0.1, 0, 1}))
	_ = sculptor_stroke_end(&s)
	_ = sculptor_flush(&s)
	testing.expect(t, f.handoffs == 2 && f.lasts == 1, "the flush after the stroke's end is its last hand-off")
	testing.expect(t, sculptor_stroke_on_gpu(&s) == .None, "the last flush gives the stroke back")

	// A sync lands the GPU's normals, the exact ones of the ranges it took (the stroke's
	// begin synced once already, with nothing to land).
	sculptor_gpu_sync(&s)
	testing.expect_value(t, f.syncs, 2)
	expected := geom.Mesh{positions = m.positions, indices = m.indices}
	expected.normals = make([dynamic]Vec3, len(m.normals), context.temp_allocator)
	geom.mesh_recompute_normals(&expected)
	worst: f32
	for r in f.taken do for v in r.first ..< r.first + r.count do worst = max(worst, linalg.length(m.normals[v] - expected.normals[v]))
	testing.expectf(t, worst < 1e-5, "after the sync a normal the GPU took is %g off the exact one", worst)

	// The next stroke asks afresh, and syncs first; refused, it runs on the CPU.
	f.take = false
	sculptor_stroke_begin(&s)
	testing.expect_value(t, f.syncs, 3)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
	testing.expectf(t, f.begins == 2 && sculptor_stroke_on_gpu(&s) == .None, "a refused stroke stays on the CPU (begins %d, on the GPU %v)", f.begins, sculptor_stroke_on_gpu(&s))
	_ = sculptor_stroke_end(&s)
	_ = sculptor_flush(&s)
	testing.expect_value(t, f.handoffs, 2)
}

@(private = "file")
stroke_gpu_matches_the_cpu_path_with_exact_normals :: proc(t: ^testing.T) {
	// Two spheres, one stroke each: the CPU's as it is, the GPU's with a stand-in that
	// syncs after every flush, as --gpu-sculpt-sync has the app do. The dabs then read the
	// same normals (these dabs reach no inner vertex of a node whose border alone moved,
	// the one place the two paths' normals differ), so the positions come out bit for bit
	// the same.
	ma, mb := geom.icosphere(5), geom.icosphere(5)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	a, b: Sculptor
	sculptor_init(&a, &ma, nil, 64)
	sculptor_init(&b, &mb, nil, 64)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	_ = sculptor_flush(&a)
	_ = sculptor_flush(&b)
	f := Fake_Gpu{s = &b, take = true, compute = true, normals = make([]Vec3, len(mb.normals))}
	defer delete(f.normals)
	defer delete(f.pending)
	defer delete(f.taken)
	copy(f.normals, mb.normals[:])
	stroke_gpu = {data = &f, begin = fake_begin, normals = fake_normals, sync = fake_sync, normals_back = fake_normals_back, normals_now = fake_normals_now}
	defer stroke_gpu = {}

	ra := fake_stroke(&a, true)
	defer delete(ra)
	sculptor_stroke_begin(&b)
	for k in 0 ..< 3 {
		_ = apply_dab(&b, {kind = .Draw, radius = 0.3, strength = 0.5}, linalg.normalize(Vec3{0.1 * f32(k), 0.05 * f32(k), 1}))
		_ = sculptor_flush(&b)
		sculptor_gpu_sync(&b)
	}
	_ = sculptor_stroke_end(&b)
	// Nothing is dirty after the end, so this flush hands nothing over and only gives the
	// stroke back.
	_ = sculptor_flush(&b)
	sculptor_gpu_sync(&b)
	testing.expectf(t, f.begins == 1 && f.handoffs == 3 && sculptor_stroke_on_gpu(&b) == .None, "the GPU stroke hands over once a flush (begins %d, hand-offs %d)", f.begins, f.handoffs)
	for p, v in ma.positions do if p != mb.positions[v] {
		testing.expectf(t, false, "vertex %d: the GPU stroke put it at %v, the CPU's at %v", v, mb.positions[v], p)
		break
	}
	expect_gpu_normals(t, &mb, &ma, f.taken[:], "after the GPU stroke")
}

@(private = "file")
stroke_gpu_ranges_given_back_are_recomputed_by_the_cpu :: proc(t: ^testing.T) {
	// The GPU took a stroke's ranges and then could not run them (a refused buffer): the
	// app marks them stale, and the next flush recomputes and reports them, so the mesh
	// ends as a twin's does that ran the stroke on the CPU.
	ma, m := geom.icosphere(5), geom.icosphere(5)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&m)
	a, s: Sculptor
	sculptor_init(&a, &ma, nil, 64)
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&s)
	_ = sculptor_flush(&a)
	_ = sculptor_flush(&s)
	f := Fake_Gpu{s = &s, take = true, compute = false, normals = make([]Vec3, len(m.normals))}
	defer delete(f.normals)
	defer delete(f.pending)
	defer delete(f.taken)
	copy(f.normals, m.normals[:])
	stroke_gpu = {data = &f, begin = fake_begin, normals = fake_normals, sync = fake_sync, normals_back = fake_normals_back, normals_now = fake_normals_now}
	defer stroke_gpu = {}

	// The twin's dabs read exact normals; the stand-in's read the stale ones the GPU left,
	// so the two strokes are one dab long, where no normal has gone stale yet.
	sculptor_stroke_begin(&a)
	_ = apply_dab(&a, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
	_ = sculptor_stroke_end(&a)
	_ = sculptor_flush(&a)
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
	_ = sculptor_stroke_end(&s)
	taken := make([dynamic]Vertex_Range, context.temp_allocator)
	append(&taken, ..sculptor_flush(&s))
	testing.expect(t, len(taken) > 0 && f.handoffs == 1, "the stroke handed ranges over")
	sculptor_gpu_sync(&s) // lands the stand-in's copy, which it never worked out: the old normals
	sculptor_normals_stale(&s, taken[:])
	again := sculptor_flush(&s)
	covered: u32
	for r in again do covered += r.count
	wanted: u32
	for r in taken do wanted += r.count
	testing.expectf(t, covered == wanted, "the flush reported %d vertices of the %d given back", covered, wanted)
	expect_gpu_normals(t, &m, &ma, taken[:], "after the CPU took the ranges back")
}

@(private = "file")
stroke_gpu_dabs_masked_and_drawn_match_the_cpu :: proc(t: ^testing.T) {
	// A half-masked mesh (fully, partly and not at all) and a drawn falloff: the dabs stay
	// on the GPU, a fully masked vertex never moves, and the rest end as the CPU's.
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	for s in ([]^Sculptor{&a, &b}) {
		mask_ensure(s)
		for p, v in s.mesh.positions do s.mask[v] = 255 if p.x > 0.05 else (128 if p.x > -0.05 else 0)
	}
	before := make([]Vec3, len(mb.positions), context.temp_allocator)
	copy(before, mb.positions[:])
	drawn: Falloff
	for &w, i in drawn.table do w = 1 - f32(i) / FALLOFF_STEPS * f32(i) / FALLOFF_STEPS
	brushes := []Brush{{kind = .Draw, radius = 0.3, strength = 0.5, no_accumulate = true}, {kind = .Clay, radius = 0.3, strength = 0.5}, {kind = .Draw, radius = 0.3, strength = 0.5, falloff_shape = &drawn}}
	dabs_pair(t, &f, &a, &b, brushes, true)
	testing.expectf(t, f.begins == 3 && f.laid == 9, "every dab was laid by the stand-in (begins %d, laid %d)", f.begins, f.laid)
	expect_positions(t, &mb, &ma, 1e-5, "after masked and drawn GPU strokes")
	still, moved := true, 0
	for p, v in mb.positions {
		if b.mask[v] == 255 && p != before[v] do still = false
		if p != before[v] do moved += 1
	}
	testing.expect(t, still, "no fully masked vertex moved")
	testing.expect(t, moved > 0, "the strokes moved the unmasked vertices")
}

@(private = "file")
stroke_gpu_dabs_faded_match_the_cpu :: proc(t: ^testing.T) {
	// An HD window's fade (0 on its border, a ramp, then full strength) under a partial
	// mask: the dabs stay on the GPU, a border vertex never moves, and the rest end as
	// the CPU's, the fade and the mask taken in sculpt.shield's order.
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	for s in ([]^Sculptor{&a, &b}) {
		s.fade = make([]u8, len(s.mesh.positions))
		mask_ensure(s)
		for p, v in s.mesh.positions {
			s.fade[v] = 0 if p.x > 0.1 else u8(clamp(255 * (0.1 - p.x) / 0.2, 1, 255))
			s.mask[v] = 100 if p.y > 0 else 0
		}
	}
	before := make([]Vec3, len(mb.positions), context.temp_allocator)
	copy(before, mb.positions[:])
	brushes := []Brush{{kind = .Draw, radius = 0.3, strength = 0.5}, {kind = .Clay, radius = 0.3, strength = 0.5}}
	dabs_pair(t, &f, &a, &b, brushes, true)
	testing.expectf(t, f.begins == 2 && f.laid > 0, "the dabs were laid by the stand-in (begins %d, laid %d)", f.begins, f.laid)
	expect_positions(t, &mb, &ma, 1e-5, "after faded GPU strokes")
	still, moved := true, 0
	for p, v in mb.positions {
		if b.fade[v] == 0 && p != before[v] do still = false
		if p != before[v] do moved += 1
	}
	testing.expect(t, still, "no vertex on the border moved")
	testing.expect(t, moved > 0, "the strokes moved the faded vertices")
}

@(private = "file")
stroke_gpu_dabs_with_an_alpha_match_the_cpu :: proc(t: ^testing.T) {
	// The Noise alpha on Draw, Inflate (whose area the GPU then finds only for the alpha's
	// frame) and Clay turned and mirrored: the dabs stay on the GPU and end as the CPU's.
	// A vector displacement alpha stays on the CPU.
	ma, mb: geom.Mesh
	a, b: Sculptor
	f: Fake_Gpu
	dabs_fixture(&f, &ma, &mb, &a, &b)
	defer geom.mesh_destroy(&ma)
	defer geom.mesh_destroy(&mb)
	defer sculptor_destroy(&a)
	defer sculptor_destroy(&b)
	defer fake_destroy(&f)
	defer stroke_gpu = {}
	noise := alpha_make(.Noise, 64)
	defer alpha_destroy(&noise)
	brushes := []Brush {
		{kind = .Draw, radius = 0.3, strength = 0.5, alpha = &noise, alpha_up = {0, 1, 0}},
		{kind = .Inflate, radius = 0.3, strength = 0.5, alpha = &noise, alpha_up = {0, 1, 0}},
		{kind = .Clay, radius = 0.3, strength = 0.5, alpha = &noise, alpha_up = {1, 1, 0}, alpha_mirror = true},
	}
	dabs_pair(t, &f, &a, &b, brushes, true)
	testing.expectf(t, f.begins == 3 && f.laid == 9, "every dab was laid by the stand-in (begins %d, laid %d)", f.begins, f.laid)
	expect_positions(t, &mb, &ma, 1e-5, "after GPU strokes with an alpha")

	vdm := alpha_make(.Noise, 8)
	defer alpha_destroy(&vdm)
	vdm.vectors = make([][3]f32, vdm.size * vdm.size)
	testing.expect(t, !dab_gpu_takes(&b, {kind = .Draw, radius = 0.3, strength = 0.5, alpha = &vdm}), "a vector displacement alpha stays on the CPU")
	testing.expect(t, dab_gpu_takes(&b, {kind = .Draw, radius = 0.3, strength = 0.5, alpha = &noise}), "a grey alpha goes to the GPU")
}
