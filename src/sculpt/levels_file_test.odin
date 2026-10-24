package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// Levels from an icosphere with strokes on two levels and a mask on the current one,
// left on level 2 of 3.
@(private = "file")
file_levels :: proc(pool: ^jobs.Pool) -> (l: Levels) {
	levels_init(&l, geom.icosphere(2), pool, 64)
	assert(levels_subdivide(&l) && levels_subdivide(&l))
	s := &levels_current(&l).sculptor
	_ = apply_dab(s, {kind = .Draw, radius = 0.3, strength = 1}, linalg.normalize(Vec3{0.2, 0.3, 1}))
	_ = apply_dab(s, {kind = .Crease, radius = 0.2, strength = 1}, linalg.normalize(Vec3{-0.4, 0.1, 1}))
	levels_set_current(&l, 1)
	s = &levels_current(&l).sculptor
	_ = apply_dab(s, {kind = .Inflate, radius = 0.5, strength = 1}, linalg.normalize(Vec3{1, 0, 0.2}))
	_ = apply_dab(s, {kind = .Mask, radius = 0.4, strength = 0.7}, linalg.normalize(Vec3{0, 1, 0}))
	for lv in l.levels do _ = sculptor_flush(&lv.sculptor)
	return
}

// Each level's positions, and the current level's mask with them, in an order of the
// positions alone, so differently numbered builds of the same levels compare.
@(private = "file")
Placed :: struct {
	p:    Vec3,
	mask: u8,
}

@(private = "file")
by_place :: proc(l: ^Levels) -> [][]Placed {
	out := make([][]Placed, len(l.levels), context.temp_allocator)
	for lv, j in l.levels {
		out[j] = make([]Placed, len(lv.mesh.positions), context.temp_allocator)
		mask := lv.sculptor.mask if j == l.current else nil
		for p, u in lv.mesh.positions do out[j][u] = {p, mask[u] if mask != nil else 0}
		slice.sort_by(out[j], proc(a, b: Placed) -> bool {
			x, y := transmute([3]u32)a.p, transmute([3]u32)b.p
			return x[0] < y[0] || (x[0] == y[0] && (x[1] < y[1] || (x[1] == y[1] && x[2] < y[2])))
		})
	}
	return out
}

@(test)
levels_file_round_trip_keeps_every_level :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l := file_levels(&pool)
	defer levels_destroy(&l)
	testing.expect(t, levels_hd_set_steps(&l, 1))
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	want := by_place(&l)
	top_before := slice.clone(l.levels[2].mesh.positions[:], context.temp_allocator)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, &pool, 64), "read failed")
	defer levels_destroy(&back)
	testing.expect_value(t, r.at, len(out))
	testing.expect_value(t, len(back.levels), 3)
	testing.expect_value(t, back.current, 1)
	testing.expect_value(t, back.hd.steps, 1)
	got := by_place(&back)
	for j in 0 ..< 3 {
		testing.expectf(t, slice.equal(slice.to_bytes(got[j]), slice.to_bytes(want[j])), "level %d or its mask differs", j)
		rep := geom.mesh_check(back.levels[j].mesh)
		testing.expectf(t, geom.mesh_report_ok(rep), "level %d: %v", j, rep)
	}
	masked := 0
	for v in want[1] do masked += int(v.mask > 0)
	testing.expect(t, masked > 0, "nothing was masked")
	// Which vertex of the copy's top level is which of the original's, by position.
	twin := make(map[Vec3]int, len(top_before), context.temp_allocator)
	for p, u in back.levels[2].mesh.positions do twin[p] = u
	// Every level decodes to what it shows, and nothing waits to sync.
	for j in 1 ..< 3 {
		lv, below := back.levels[j], level_base(back.levels[j - 1])
		worst: f32
		for p, u in lv.mesh.positions do worst = max(worst, linalg.length(p - frame_point(frame_at(&below, lv.parents[u]), lv.detail[u])))
		testing.expectf(t, worst < 1e-6, "level %d decodes %v away", j, worst)
		testing.expect_value(t, len(lv.sculptor.edited_nodes), 0)
	}
	// A change on the base carries up about the same way in both. Not exactly: a frame's
	// tangent follows an edge chosen by the vertex numbering, which differs, so detail
	// turns a little differently as the base under it bends.
	for levels in ([2]^Levels{&l, &back}) {
		levels_set_current(levels, 0)
		_ = apply_dab(&levels_current(levels).sculptor, {kind = .Draw, radius = 0.6, strength = 1}, {0, 0, 1})
		levels_set_current(levels, 2)
	}
	worst: f32
	for p, u in top_before do worst = max(worst, linalg.length(l.levels[2].mesh.positions[u] - back.levels[2].mesh.positions[twin[p]]))
	testing.expectf(t, worst < 1e-3, "the top levels differ by %v after a base edit", worst)
}

@(test)
levels_file_is_the_same_with_threads :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	files: [2][dynamic]u8
	defer for f in files do delete(f)
	for &f, i in files {
		p := &pool if i == 1 else nil
		l := file_levels(p)
		defer levels_destroy(&l)
		levels_write(&l, &f)
		back: Levels
		r := geom.byte_reader(f[:])
		testing.expect(t, levels_read(&back, &r, p, 64))
		levels_destroy(&back)
	}
	testing.expect(t, slice.equal(files[0][:], files[1][:]), "serial and parallel files differ")
}

@(test)
levels_file_refuses_damage :: proc(t: ^testing.T) {
	l := file_levels(nil)
	defer levels_destroy(&l)
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	// Cut short anywhere: a refusal, nothing kept, nothing leaked (the runner checks).
	for cut := 0; cut < len(out); cut += max(len(out) / 61, 1) {
		back: Levels
		r := geom.byte_reader(out[:cut])
		testing.expectf(t, !levels_read(&back, &r, nil, 64), "a file cut at %d of %d was read", cut, len(out))
		testing.expect(t, len(back.levels) == 0)
	}
	// A corner past the base's vertices.
	bad := slice.clone(out[:], context.temp_allocator)
	base_vertices := len(l.levels[0].mesh.positions)
	first_index := 5 * 4 + 8 + base_vertices * size_of(Vec3)
	past := transmute([4]u8)u32(base_vertices)
	copy(bad[first_index:], past[:])
	back: Levels
	r := geom.byte_reader(bad)
	testing.expect(t, !levels_read(&back, &r, nil, 64), "a bad index was read")
}

@(test)
levels_file_keeps_dynamic_topology :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(3), nil, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_dyn_enable(&l))
	s := &l.levels[0].sculptor
	sculptor_stroke_begin(s)
	for k in 0 ..< 10 do _ = apply_dab(s, {kind = .Draw, radius = 0.4, strength = 0.3, detail = 0.08, collapse = true}, linalg.normalize(Vec3{0.05 * f32(k), 0.2, 1}))
	_ = sculptor_stroke_end(s)
	_ = apply_dab(s, {kind = .Mask, radius = 0.3, strength = 1}, {0, 0, 1})
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)
	packed, mask := sculptor_compact_mesh(s, context.temp_allocator)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	testing.expect(t, levels_dynamic(&back), "not dynamic after reading")
	again, again_mask := sculptor_compact_mesh(&back.levels[0].sculptor, context.temp_allocator)
	testing.expect(t, len(packed.indices) > 3 * 1280 && len(again.indices) == len(packed.indices), "triangle count")
	rep := geom.mesh_check(again)
	testing.expectf(t, geom.mesh_report_ok(rep), "%v", rep)
	testing.expect(t, mask != nil && len(again_mask) == len(mask), "mask")
	painted := 0
	for k in again_mask do painted += int(k > 0)
	testing.expect(t, painted > 0, "the mask was lost")
}
