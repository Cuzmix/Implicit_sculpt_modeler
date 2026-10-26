package sculpt

import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
sets_levels :: proc(steps: int, pool: ^jobs.Pool = nil) -> (l: Levels) {
	levels_init(&l, geom.icosphere(2), pool, 64)
	for _ in 0 ..< steps do assert(levels_subdivide(&l))
	return
}

// A mask on the current level: fully masked above the plane y = `above`, partly in a band
// below it, so it has long runs and a few short ones.
@(private = "file")
mask_above :: proc(l: ^Levels, above: f32) {
	s := &levels_current(l).sculptor
	values := make([]u8, len(s.mesh.positions), context.temp_allocator)
	for p, v in s.mesh.positions {
		values[v] = 255 if p.y > above else (128 if p.y > above - 0.2 else 0)
	}
	assert(sculptor_mask_values(s, values, .Replace))
}

@(private = "file")
round_trips :: proc(values: []u8) -> (ok, runs: bool) {
	data, r := set_encode(values, context.temp_allocator)
	back := make([]u8, len(values), context.temp_allocator)
	return set_decode(data, r, back) && slice.equal(back, values), r
}

// Runs where they are smaller, a byte a vertex where not, and either way the values back;
// damaged data is refused.
@(test)
selection_set_encoding_round_trips :: proc(t: ^testing.T) {
	ok, runs := round_trips({})
	testing.expect(t, ok)
	full := make([]u8, 10_000, context.temp_allocator)
	slice.fill(full, 255)
	ok, runs = round_trips(full)
	testing.expect(t, ok && runs)
	alternating := make([]u8, 1000, context.temp_allocator)
	for &x, i in alternating do x = 255 if i % 2 == 0 else 0
	ok, runs = round_trips(alternating)
	testing.expect(t, ok && !runs)
	zeros := make([]u8, 10_000_000)
	defer delete(zeros)
	data, r := set_encode(zeros, context.temp_allocator)
	testing.expect(t, r && len(data) == RUN_BYTES_FOR_TEST)
	back := make([]u8, len(zeros))
	defer delete(back)
	testing.expect(t, set_decode(data, r, back))

	short := make([]u8, 9_999_999)
	defer delete(short)
	testing.expect(t, !set_decode(data, r, short)) // the runs add up to more
	testing.expect(t, !set_decode(data[:4], r, back)) // part of a run
	testing.expect(t, !set_decode({0, 0, 0, 0, 7}, true, back[:1])) // an empty run
	testing.expect(t, !set_decode(alternating, false, back[:10])) // the wrong length
}

@(private = "file")
RUN_BYTES_FOR_TEST :: 5

// Restore puts the set back as the mask, Add takes the more masked and Subtract takes the
// set off, each one undo step; storing needs something masked, and at most
// MAX_SELECTION_SETS are kept.
@(test)
selection_set_restore_modes :: proc(t: ^testing.T) {
	l := sets_levels(1)
	defer levels_destroy(&l)
	s := &levels_current(&l).sculptor
	testing.expect_value(t, levels_set_store(&l, "none"), 0) // no mask
	testing.expect(t, sculptor_mask_command(s, .Invert))
	testing.expect(t, sculptor_mask_command(s, .Clear))
	testing.expect_value(t, levels_set_store(&l, "empty"), 0) // nothing masked
	mask_above(&l, 0.3)
	set := slice.clone(s.mask, context.temp_allocator)
	id := levels_set_store(&l, "top")
	testing.expect(t, id != 0)
	testing.expect_value(t, selection_set_name(&levels_sets(&l)[0]), "top")
	testing.expect(t, levels_sets(&l)[0].runs)

	mask_above(&l, -0.5)
	other := slice.clone(s.mask, context.temp_allocator)
	testing.expect(t, levels_set_restore(&l, id, .Replace))
	testing.expect(t, slice.equal(s.mask, set))
	testing.expect(t, !levels_set_restore(&l, id, .Replace)) // nothing changes
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, slice.equal(s.mask, other))
	testing.expect(t, levels_set_restore(&l, id, .Subtract))
	for k, v in s.mask do testing.expect_value(t, k, min(other[v], 255 - set[v]))
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, sculptor_mask_command(s, .Clear))
	mask_above(&l, 0.6)
	before := slice.clone(s.mask, context.temp_allocator)
	testing.expect(t, levels_set_restore(&l, id, .Add))
	for k, v in s.mask do testing.expect_value(t, k, max(before[v], set[v]))

	levels_set_rename(&l, id, "renamed")
	testing.expect_value(t, selection_set_name(&levels_sets(&l)[0]), "renamed")
	for _ in 1 ..< MAX_SELECTION_SETS do testing.expect(t, levels_set_store(&l, "more") != 0)
	testing.expect_value(t, levels_set_store(&l, "too many"), 0)
	testing.expect(t, levels_set_store(&l, "", over = id) == id) // over one is fine
	levels_set_delete(&l, id)
	testing.expect_value(t, len(levels_sets(&l)), MAX_SELECTION_SETS - 1)
	testing.expect_value(t, levels_set_index(&l, id), -1)
}

// A set stored on one level restores on another as the live mask is carried there, and
// deleting the levels a set is kept by carries it to the current level first.
@(test)
selection_set_carries_across_levels :: proc(t: ^testing.T) {
	l := sets_levels(2)
	defer levels_destroy(&l)
	mask_above(&l, 0.2)
	top := levels_set_store(&l, "top")
	levels_set_current(&l, 0)
	carried := slice.clone(levels_current(&l).sculptor.mask, context.temp_allocator)
	testing.expect(t, sculptor_mask_command(&levels_current(&l).sculptor, .Clear))
	testing.expect(t, levels_set_restore(&l, top, .Replace))
	testing.expect(t, slice.equal(levels_current(&l).sculptor.mask, carried))

	base := levels_set_store(&l, "base")
	levels_set_current(&l, 1)
	carried = slice.clone(levels_current(&l).sculptor.mask, context.temp_allocator)
	levels_delete_lower(&l)
	sets := levels_sets(&l)
	testing.expect_value(t, len(sets), 2)
	testing.expect_value(t, sets[1].level, 0) // carried up from the base
	testing.expect_value(t, sets[0].level, 1) // the top level, one lower now
	s := &levels_current(&l).sculptor
	testing.expect(t, sculptor_mask_command(s, .Clear))
	testing.expect(t, levels_set_restore(&l, base, .Replace))
	testing.expect(t, slice.equal(s.mask, carried))
	testing.expect(t, sculptor_mask_command(s, .Clear))
	testing.expect(t, levels_set_restore(&l, top, .Replace))
	from_top := slice.clone(s.mask, context.temp_allocator)

	levels_delete_higher(&l)
	testing.expect_value(t, levels_sets(&l)[0].level, 0)
	testing.expect(t, sculptor_mask_command(s, .Clear))
	testing.expect(t, levels_set_restore(&l, top, .Replace))
	testing.expect(t, slice.equal(s.mask, from_top))
}

// Dynamic topology renumbers the vertices: turning it on drops the sets, and sets are
// neither stored nor restored while it is on.
@(test)
selection_sets_go_with_dynamic_topology :: proc(t: ^testing.T) {
	l := sets_levels(0)
	defer levels_destroy(&l)
	mask_above(&l, 0)
	id := levels_set_store(&l, "kept")
	testing.expect(t, id != 0)
	testing.expect(t, levels_dyn_enable(&l))
	defer levels_dyn_disable(&l)
	testing.expect_value(t, len(levels_sets(&l)), 0)
	testing.expect(t, !levels_sets_ready(&l))
	testing.expect_value(t, levels_set_store(&l, "refused"), 0)
}

@(private = "file")
Placed_Value :: struct {
	p: Vec3,
	k: u8,
}

// Each set's values with the positions of its level's vertices, sorted by position, so
// differently numbered builds compare.
@(private = "file")
set_by_place :: proc(l: ^Levels, set: ^Selection_Set) -> []Placed_Value {
	values := set_values_at(l, set, set.level)
	out := make([]Placed_Value, len(values), context.temp_allocator)
	for k, v in values do out[v] = {l.levels[set.level].mesh.positions[v], k}
	slice.sort_by(out, proc(a, b: Placed_Value) -> bool {
		x, y := transmute([3]u32)a.p, transmute([3]u32)b.p
		return x[0] < y[0] || (x[0] == y[0] && (x[1] < y[1] || (x[1] == y[1] && x[2] < y[2])))
	})
	return out
}

// Sets go through the scene file on their own levels, numbered as the file numbers the
// vertices; one cut short is refused.
@(test)
selection_sets_file_round_trip :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l := sets_levels(2, &pool)
	defer levels_destroy(&l)
	mask_above(&l, 0.1)
	testing.expect(t, levels_set_store(&l, "fine") != 0)
	levels_set_current(&l, 0)
	mask_above(&l, -0.4)
	testing.expect(t, levels_set_store(&l, "coarse") != 0)
	levels_set_current(&l, 1)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, &pool, 64), "read failed")
	defer levels_destroy(&back)
	testing.expect_value(t, r.at, len(out))
	testing.expect_value(t, len(levels_sets(&back)), 2)
	for &set, i in levels_sets(&back) {
		was := &levels_sets(&l)[i]
		testing.expect_value(t, selection_set_name(&set), selection_set_name(was))
		testing.expect_value(t, set.level, was.level)
		testing.expect_value(t, set.masked, was.masked)
		a, b := set_by_place(&l, was), set_by_place(&back, &set)
		testing.expectf(t, slice.equal(slice.to_bytes(a), slice.to_bytes(b)), "set %d differs", i)
	}
	// Cut short inside the last set.
	broken: Levels
	r = geom.byte_reader(out[:len(out) - 1])
	testing.expect(t, !levels_read(&broken, &r, &pool, 64))
}
