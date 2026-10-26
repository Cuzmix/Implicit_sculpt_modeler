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
	testing.expect(t, r && len(data) == RUN_BYTES)
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

// Levels written before sets (no LEVELS_SETS flag) read with none; a sets block with too
// many sets, a level past the levels, a runs flag past 1 or runs that do not add up is
// refused.
@(test)
selection_sets_old_and_damaged_files :: proc(t: ^testing.T) {
	l := sets_levels(1)
	defer levels_destroy(&l)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))
	// No sets: the block is a count of 0, the last four bytes.
	head := out[:len(out) - 4]
	old := slice.clone(head, context.temp_allocator)
	flags := (^u32)(&old[4])
	flags^ &~= 32 // LEVELS_SETS
	back: Levels
	r := geom.byte_reader(old)
	testing.expect(t, levels_read(&back, &r, nil, 64))
	testing.expect_value(t, len(levels_sets(&back)), 0)
	levels_destroy(&back)

	vertices := u32(len(l.levels[0].mesh.positions))
	Block :: struct {
		count, level: u32,
		runs:         u8,
		run:          u32, // one run of value 255 this long
	}
	cases := [?]Block {
		{count = MAX_SELECTION_SETS + 1, level = 0, runs = 1, run = vertices},
		{count = 1, level = 2, runs = 1, run = vertices},
		{count = 1, level = 0, runs = 2, run = vertices},
		{count = 1, level = 0, runs = 1, run = vertices - 1},
		{count = 1, level = 0, runs = 1, run = vertices}, // the one good block
	}
	for c, i in cases {
		bad := make([dynamic]u8, context.temp_allocator)
		append(&bad, ..head)
		geom.byte_put(&bad, c.count)
		name: [32]u8
		geom.byte_put_slice(&bad, name[:])
		geom.byte_put(&bad, c.level)
		geom.byte_put(&bad, f32(1))
		geom.byte_put(&bad, c.runs)
		geom.byte_put(&bad, u32(RUN_BYTES))
		geom.byte_put(&bad, c.run)
		geom.byte_put(&bad, u8(255))
		r = geom.byte_reader(bad[:])
		read := levels_read(&back, &r, nil, 64)
		testing.expectf(t, read == (i == len(cases) - 1), "case %d: read %v", i, read)
		if read do testing.expect_value(t, len(levels_sets(&back)), 1)
		if read do levels_destroy(&back)
	}
}

// A restore leaves hidden vertices' mask as it is, as the mask commands do.
@(test)
selection_set_restore_leaves_hidden_vertices :: proc(t: ^testing.T) {
	l := sets_levels(1)
	defer levels_destroy(&l)
	s := &levels_current(&l).sculptor
	mask_above(&l, -2) // everything
	id := levels_set_store(&l, "all")
	testing.expect(t, sculptor_mask_command(s, .Clear))
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_hide_shape(s, 1, rect, .Hide))
	testing.expect(t, levels_set_restore(&l, id, .Replace))
	hidden, wrong := 0, 0
	for v in 0 ..< len(s.mask) {
		if vertex_hidden(s, u32(v)) {
			hidden += 1
			if s.mask[v] != 0 do wrong += 1
		} else if s.mask[v] != 255 {
			wrong += 1
		}
	}
	testing.expect(t, hidden > 0)
	testing.expectf(t, wrong == 0, "%d vertices restored wrongly", wrong)
}
