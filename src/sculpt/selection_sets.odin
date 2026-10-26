package sculpt

import "base:intrinsics"
import "core:slice"

import "../jobs"

// Selection sets, as ZBrush's Selection Sets and 3DCoat's stored freezes: masks kept by
// name with the object, to bring back later. A set belongs to the level it was stored
// on, numbered as that level's vertices are, and is carried to another level the way
// the live mask is (carried_mask), so it restores on any level. Most masks are long
// runs of one value, so a set keeps runs when they are smaller than a byte a vertex,
// which a blurred or cavity mask is not. Sets go with the vertices they are numbered
// by: a remesh or any other rebuild drops them with the levels, and turning dynamic
// topology on (which renumbers the base) drops them too; deleting levels carries the
// sets of the deleted ones to the current level first. Storing, renaming and deleting a
// set are not undo steps, as in ZBrush; restoring one is a mask step like any other.

MAX_SELECTION_SETS :: 16

Selection_Set :: struct {
	id:       u32,     // unique among the object's sets while the app runs, for the panel's rows
	name:     [32]u8,  // zero-terminated
	level:    int,     // the level it is numbered by
	vertices: int,     // that level's vertex count
	masked:   f32,     // the mean mask, 0 to 1, taken when it was stored
	runs:     bool,    // data is runs of {count: u32, value: u8}, else a byte a vertex
	data:     []u8,
}

// How a restored set meets the mask there is.
Set_Mode :: enum {
	Replace,  // the set becomes the mask
	Add,      // the more masked of the two, per vertex
	Subtract, // the mask, less the set: min(mask, 255 - set)
}

// One run as kept in a set's data.
@(private = "file")
RUN_BYTES :: 5

// Packs `values` as a set's data: runs when smaller, else a copy.
@(private)
set_encode :: proc(values: []u8, allocator := context.allocator) -> (data: []u8, runs: bool) {
	count := 0
	for i := 0; i < len(values); count += 1 {
		j := i + 1
		for j < len(values) && values[j] == values[i] do j += 1
		i = j
	}
	if count * RUN_BYTES >= len(values) do return slice.clone(values, allocator), false
	data = make([]u8, count * RUN_BYTES, allocator)
	at := 0
	for i := 0; i < len(values); {
		j := i + 1
		for j < len(values) && values[j] == values[i] do j += 1
		intrinsics.unaligned_store(cast(^u32)&data[at], u32(j - i))
		data[at + 4] = values[i]
		at += RUN_BYTES
		i = j
	}
	return data, true
}

// Unpacks a set's data into `values`, which is as long as the set has vertices. False
// when the runs do not add up to exactly that, as in a damaged file.
@(private)
set_decode :: proc(data: []u8, runs: bool, values: []u8) -> bool {
	if !runs {
		if len(data) != len(values) do return false
		copy(values, data)
		return true
	}
	if len(data) % RUN_BYTES != 0 do return false
	at := 0
	for r := 0; r < len(data); r += RUN_BYTES {
		count := int(intrinsics.unaligned_load(cast(^u32)&data[r]))
		if count == 0 || count > len(values) - at do return false
		slice.fill(values[at:][:count], data[r + 4])
		at += count
	}
	return at == len(values)
}

// The sets, in the order they were stored.
levels_sets :: proc(l: ^Levels) -> []Selection_Set {return l.sets[:]}

// A set's name as text.
selection_set_name :: proc(set: ^Selection_Set) -> string {
	n := 0
	for n < len(set.name) && set.name[n] != 0 do n += 1
	return string(set.name[:n])
}

// Where the set with `id` is in the list, or -1.
levels_set_index :: proc(l: ^Levels, id: u32) -> int {
	for set, i in l.sets do if set.id == id do return i
	return -1
}

// Whether sets can be stored and restored now: not under dynamic topology, whose
// vertices move about, nor in an HD window, whose mask goes when it closes.
levels_sets_ready :: proc(l: ^Levels) -> bool {
	return !levels_dynamic(l) && l.hd.window == nil
}

// Stores the current level's mask as a new set called `name`, or over the set `over`'s
// mask when that is not 0 (keeping its name). Returns the set's id, or 0 when there is no
// mask, nothing in it is masked, MAX_SELECTION_SETS are kept already, or sets are not
// ready (levels_sets_ready).
levels_set_store :: proc(l: ^Levels, name: string, over: u32 = 0) -> u32 {
	if !levels_sets_ready(l) do return 0
	s := &levels_current(l).sculptor
	if s.mask == nil do return 0
	sum: u64
	for k in s.mask do sum += u64(k)
	if sum == 0 do return 0
	set: ^Selection_Set
	if over != 0 {
		i := levels_set_index(l, over)
		if i < 0 do return 0
		set = &l.sets[i]
		delete(set.data, l.allocator)
	} else {
		if len(l.sets) >= MAX_SELECTION_SETS do return 0
		l.set_serial += 1
		append(&l.sets, Selection_Set{id = l.set_serial})
		set = &l.sets[len(l.sets) - 1]
		copy(set.name[:len(set.name) - 1], name)
	}
	set.level, set.vertices = l.current, len(s.mask)
	set.masked = f32(f64(sum) / (255 * f64(len(s.mask))))
	set.data, set.runs = set_encode(s.mask, l.allocator)
	return set.id
}

levels_set_rename :: proc(l: ^Levels, id: u32, name: string) {
	i := levels_set_index(l, id)
	if i < 0 do return
	set := &l.sets[i]
	set.name = {}
	copy(set.name[:len(set.name) - 1], name)
}

levels_set_delete :: proc(l: ^Levels, id: u32) {
	i := levels_set_index(l, id)
	if i < 0 do return
	delete(l.sets[i].data, l.allocator)
	ordered_remove(&l.sets, i)
}

// Drops every set; how many there were.
levels_sets_clear :: proc(l: ^Levels) -> int {
	n := len(l.sets)
	for set in l.sets do delete(set.data, l.allocator)
	clear(&l.sets)
	return n
}

// Brings back the set with `id` on the current level as a mask step (see Set_Mode).
// Hidden vertices keep their mask, as with the mask commands. Returns true when it
// changed the mask; false too when sets are not ready.
levels_set_restore :: proc(l: ^Levels, id: u32, mode: Set_Mode) -> bool {
	i := levels_set_index(l, id)
	if i < 0 || !levels_sets_ready(l) do return false
	values := set_values_at(l, &l.sets[i], l.current, context.temp_allocator)
	if values == nil do return false
	return sculptor_mask_values(&levels_current(l).sculptor, values, mode)
}

// The set's mask on level `to`, decoded on its own level and carried level by level.
// Temporary unless `allocator` says otherwise; nil when its data is damaged.
@(private)
set_values_at :: proc(l: ^Levels, set: ^Selection_Set, to: int, allocator := context.temp_allocator) -> []u8 {
	if set.vertices != len(l.levels[set.level].mesh.positions) do return nil
	values := make([]u8, set.vertices, allocator)
	if !set_decode(set.data, set.runs, values) do return nil
	step := 1 if to > set.level else -1
	for j := set.level; j != to; j += step {
		next := make([]u8, len(l.levels[j + step].mesh.positions), allocator)
		mask_carry_values(l, values, l.levels[j], l.levels[j + step], step > 0, next)
		delete(values, allocator)
		values = next
	}
	return values
}

// Carries every set numbered by a level in `from` (a range of levels about to go) to
// level `to`, which stays.
@(private)
levels_sets_carry :: proc(l: ^Levels, from: [2]int, to: int) {
	for i := 0; i < len(l.sets); {
		set := &l.sets[i]
		if set.level < from[0] || set.level >= from[1] {
			i += 1
			continue
		}
		values := set_values_at(l, set, to)
		delete(set.data, l.allocator)
		if values == nil {
			ordered_remove(&l.sets, i) // damaged: there is nothing to carry
			continue
		}
		set.level = to
		set.vertices = len(values)
		set.data, set.runs = set_encode(values, l.allocator)
		i += 1
	}
}

// Bytes the sets keep.
@(private)
levels_sets_bytes :: proc(l: ^Levels) -> int {
	total := 0
	for set in l.sets do total += len(set.data) + size_of(Selection_Set)
	return total
}

// Applies `values`, a mask for every vertex, to the mask by `mode` as one undo step,
// leaving hidden vertices as they are. Returns true when it changed the mask.
sculptor_mask_values :: proc(s: ^Sculptor, values: []u8, mode: Set_Mode) -> bool {
	_ = sculptor_stroke_end(s)
	if len(values) != len(s.mesh.positions) || s.dyn != nil do return false
	if s.mask == nil && mode == .Subtract do return false
	mask_ensure(s)
	Job :: struct {
		s:       ^Sculptor,
		values:  []u8,
		mode:    Set_Mode,
		after:   []u8,
		changes: []bool,
	}
	job := Job{s, values, mode, slice.clone(s.mask, context.temp_allocator), make([]bool, len(s.nodes), context.temp_allocator)}
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for id in lo ..< hi {
			n := job.s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				if vertex_hidden(job.s, v) do continue
				k, x := job.after[v], job.values[v]
				switch job.mode {
				case .Replace:  job.after[v] = x
				case .Add:      job.after[v] = max(k, x)
				case .Subtract: job.after[v] = min(k, 255 - x)
				}
			}
			job.changes[id] = true
		}
	}, NODE_GRAIN)
	return mask_commit_values(s, job.after, job.changes)
}
