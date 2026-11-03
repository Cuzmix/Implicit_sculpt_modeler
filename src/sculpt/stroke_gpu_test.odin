package sculpt

import "core:math/linalg"
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
	compute:  bool, // work the normals out at the hand-off; off leaves them stale for good
	begins:   int,
	handoffs: int,
	lasts:    int,
	syncs:    int,
	normals:  []Vec3, // the GPU's copy
	pending:  [dynamic]Vertex_Range,
	taken:    [dynamic]Vertex_Range, // every range handed over so far
}

@(private = "file")
fake_begin :: proc(data: rawptr, s: ^Sculptor, brush: Brush) -> bool {
	f := cast(^Fake_Gpu)data
	if s != f.s do return false
	f.begins += 1
	return f.take
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
	append(&f.pending, ..ranges)
	append(&f.taken, ..ranges)
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
fake_sync :: proc(data: rawptr, s: ^Sculptor) {
	f := cast(^Fake_Gpu)data
	if s != f.s do return
	f.syncs += 1
	for r in f.pending do copy(s.mesh.normals[r.first:][:r.count], f.normals[r.first:][:r.count])
	clear(&f.pending)
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

// The three scenarios run one after another from one test, since the tests of a package
// run side by side and all three set the package's stroke_gpu.
@(test)
stroke_gpu_hand_off :: proc(t: ^testing.T) {
	stroke_gpu_takes_the_normals_and_gives_them_back_at_a_sync(t)
	stroke_gpu_matches_the_cpu_path_with_exact_normals(t)
	stroke_gpu_ranges_given_back_are_recomputed_by_the_cpu(t)
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
	stroke_gpu = {data = &f, begin = fake_begin, normals = fake_normals, sync = fake_sync}
	defer stroke_gpu = {}

	before := make([]Vec3, len(m.normals), context.temp_allocator)
	copy(before, m.normals[:])
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 0.5}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_on_gpu(&s), "the GPU was offered the stroke and took it, so the stroke should run there")
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
	testing.expect(t, !sculptor_stroke_on_gpu(&s), "the last flush gives the stroke back")

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
	testing.expectf(t, f.begins == 2 && !sculptor_stroke_on_gpu(&s), "a refused stroke stays on the CPU (begins %d, on the GPU %v)", f.begins, sculptor_stroke_on_gpu(&s))
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
	stroke_gpu = {data = &f, begin = fake_begin, normals = fake_normals, sync = fake_sync}
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
	testing.expectf(t, f.begins == 1 && f.handoffs == 3 && !sculptor_stroke_on_gpu(&b), "the GPU stroke hands over once a flush (begins %d, hand-offs %d)", f.begins, f.handoffs)
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
	stroke_gpu = {data = &f, begin = fake_begin, normals = fake_normals, sync = fake_sync}
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
