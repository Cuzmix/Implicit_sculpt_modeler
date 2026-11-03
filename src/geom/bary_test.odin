package geom

import "core:encoding/endian"
import "core:testing"

// The bird curve puts level 2's fifteen vertices where the reference library's diagram
// does, and at every level each vertex gets its own place.
@(test)
bary_bird_curve_matches_the_diagram :: proc(t: ^testing.T) {
	// Rows from the bottom (v = 0, from W to U) to the top (V), as the diagram draws them.
	rows := [5][]u32{{0, 8, 5, 11, 1}, {6, 7, 9, 10}, {3, 14, 4}, {12, 13}, {2}}
	for row, v in rows do for want, u in row {
		testing.expectf(t, bary_bird_index(u32(u), u32(v), 2) == want, "(%d, %d) is %d, not %d", u, v, bary_bird_index(u32(u), u32(v), 2), want)
	}
	for level in u32(0) ..= BARY_LEVEL_MAX {
		n := bary_vertex_count(level)
		seen := make([]bool, n, context.temp_allocator)
		s := u32(1) << level
		for v in u32(0) ..= s do for u in u32(0) ..= s - v {
			at := bary_bird_index(u, v, level)
			if !testing.expectf(t, int(at) < n && !seen[at], "level %d: (%d, %d) at %d", level, u, v, at) do return
			seen[at] = true
		}
	}
}

// The file has the header, the records in order, each property 4-byte aligned inside it,
// and values that come back within one step of 2048 of what went in.
@(test)
bary_file_holds_the_values :: proc(t: ^testing.T) {
	level := u32(1)
	per := bary_vertex_count(level)
	m := Bary_Mesh {
		positions  = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0}},
		directions = {{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}},
		indices    = {0, 1, 2, 2, 1, 3},
		level      = level,
	}
	values := make([]f32, 2 * per, context.temp_allocator)
	for &v, i in values do v = -0.25 + f32(i) * 0.05
	m.values = values
	data := bary_encode(m)
	defer delete(data)
	if !testing.expect(t, data != nil) do return
	testing.expect(t, string(data[1:5]) == "BARY")
	testing.expect_value(t, int(endian.unchecked_get_u64le(data[16:])), len(data))
	records := int(endian.unchecked_get_u64le(data[32:])) / 64
	testing.expect_value(t, records, 8)
	last := 0
	for k in 0 ..< records {
		r := data[40 + 64 * k:]
		at, n := int(endian.unchecked_get_u64le(r[16:])), int(endian.unchecked_get_u64le(r[24:]))
		testing.expect(t, at % 4 == 0 && at >= last && at + n <= len(data))
		last = at + n
	}
	// The values: their record is the first, the group the second (bias and scale at 24).
	vat := int(endian.unchecked_get_u64le(data[40 + 16:]))
	testing.expect_value(t, int(endian.unchecked_get_u32le(data[vat + 12:])), len(values))
	gat := int(endian.unchecked_get_u64le(data[40 + 64 + 16:]))
	bias := transmute(f32)endian.unchecked_get_u32le(data[gat + 24:])
	scale := transmute(f32)endian.unchecked_get_u32le(data[gat + 40:])
	for v, i in values {
		q := f32(endian.unchecked_get_u16le(data[vat + 24 + 2 * i:]))
		testing.expectf(t, abs(bias + scale * q / 2047 - v) <= scale / 2047, "value %d is %v, not %v", i, bias + scale * q / 2047, v)
	}
	// A mesh whose values do not fit its level makes no file.
	m.values = values[1:]
	testing.expect(t, bary_encode(m) == nil)
}
