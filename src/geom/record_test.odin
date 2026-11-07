package geom

import "core:testing"

@(private = "file")
Test_Tag :: enum u16 {
	Count = 1,
	Name  = 2,
	Point = 3,
	List  = 4,
	Inner = 5,
	Item  = 6,
	Later = 7, // a field a later build adds, which this test's "earlier" reader never asks for
}

// What an earlier build knew: Later and the critical tag below are both unknown to it.
@(private = "file")
Earlier_Tag :: enum u16 {
	Count = 1,
	Name  = 2,
	Point = 3,
	List  = 4,
	Inner = 5,
	Item  = 6,
}

@(private = "file")
Critical_Tag :: enum u16 {
	Units = RECORD_TAG_CRITICAL | 1,
}

// A record with a value, text, a slice and a nested record, as a writer lays them out.
@(private = "file")
test_record :: proc(out: ^[dynamic]u8, later: bool) -> int {
	at := record_begin(out)
	rec_put(out, Test_Tag.Count, i32(7))
	rec_put_string(out, Test_Tag.Name, "clay")
	rec_put(out, Test_Tag.Point, [3]f32{1, 2, 3})
	rec_put_slice(out, Test_Tag.List, []u16{4, 5, 6})
	if later do rec_put(out, Test_Tag.Later, f64(9.5))
	inner := rec_begin(out, Test_Tag.Inner)
	rec_put(out, Test_Tag.Count, u8(2))
	rec_end(out, inner)
	for i in 0 ..< 3 do rec_put(out, Test_Tag.Item, i32(10 + i))
	record_end(out, at)
	return at
}

@(test)
a_record_reads_back_what_it_wrote :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, false)
	r := byte_reader(out[:])
	rec := record_take(&r)
	testing.expect(t, r.ok && rec.ok)
	testing.expect_value(t, rec_get(&rec, Test_Tag.Count, i32, 0), 7)
	name := rec_get_string(&rec, Test_Tag.Name)
	defer delete(name)
	testing.expect_value(t, name, "clay")
	testing.expect_value(t, rec_get(&rec, Test_Tag.Point, [3]f32, [3]f32{}), [3]f32{1, 2, 3})
	list := rec_get_slice(&rec, Test_Tag.List, u16)
	defer delete(list)
	testing.expect(t, len(list) == 3 && list[0] == 4 && list[2] == 6)
	inner, present := rec_sub(&rec, Test_Tag.Inner)
	testing.expect(t, present && inner.ok)
	testing.expect_value(t, rec_get(&inner, Test_Tag.Count, u8, 0), 2)
	testing.expect_value(t, rec_count(&rec, Test_Tag.Item), 3)
	at, n := 0, i32(0)
	for payload in rec_next(&rec, Test_Tag.Item, &at) {
		v := (^i32)(raw_data(payload))^
		testing.expect_value(t, v, 10 + n)
		n += 1
	}
	testing.expect_value(t, n, 3)
	testing.expect(t, rec.ok && r.at == len(out))
}

@(test)
a_field_the_reader_does_not_know_is_stepped_over :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, later = true)
	r := byte_reader(out[:])
	rec := record_take(&r)
	// This reader never asks for Later; everything around it reads as before.
	testing.expect_value(t, rec_get(&rec, Test_Tag.Count, i32, 0), 7)
	inner, _ := rec_sub(&rec, Test_Tag.Inner)
	testing.expect_value(t, rec_get(&inner, Test_Tag.Count, u8, 0), 2)
	testing.expect(t, rec.ok && r.ok)
}

@(test)
a_missing_field_takes_its_default :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, later = false)
	r := byte_reader(out[:])
	rec := record_take(&r)
	testing.expect_value(t, rec_get(&rec, Test_Tag.Later, f64, 2.25), 2.25)
	testing.expect(t, !rec_has(&rec, Test_Tag.Later))
	testing.expect(t, rec.ok)
}

@(test)
a_field_of_the_wrong_size_is_damage :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, false)
	r := byte_reader(out[:])
	rec := record_take(&r)
	// Count was written as an i32; reading it as an f64 is a retyped tag, which never happens.
	_ = rec_get(&rec, Test_Tag.Count, f64, 0)
	testing.expect(t, !rec.ok)
	rec.ok = true
	dst: [2]u16
	_ = rec_get_into(&rec, Test_Tag.List, dst[:])
	testing.expect(t, !rec.ok)
}

@(test)
a_cut_short_record_is_damage :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, false)
	// Every cut that leaves the size word whole but loses bytes, and every cut inside a field
	// given as a whole record's data, is refused rather than read.
	for cut in 9 ..< len(out) {
		r := byte_reader(out[:cut])
		rec := record_take(&r)
		testing.expectf(t, !r.ok && !rec.ok, "a record cut at %d of %d was read", cut, len(out))
	}
	// A field head cut inside, or a size past the end, given as a record's whole data.
	testing.expect(t, !record_of(out[8:][:5]).ok)
	testing.expect(t, !record_of(out[8:][:RECORD_FIELD_HEAD + 2]).ok)
}

@(test)
an_unknown_critical_field_refuses_the_record :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, later = true)
	r := byte_reader(out[:])
	rec := record_take(&r)
	known, skipped := record_known(&rec, Earlier_Tag)
	testing.expect(t, known)
	testing.expect_value(t, skipped, 1)
	clear(&out)
	at := record_begin(&out)
	rec_put(&out, Test_Tag.Count, i32(1))
	rec_put(&out, Critical_Tag.Units, f32(0.01))
	record_end(&out, at)
	r = byte_reader(out[:])
	rec = record_take(&r)
	known, _ = record_known(&rec, Earlier_Tag)
	testing.expect(t, !known)
}

@(test)
a_required_field_missing_or_twice_is_damage :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	test_record(&out, false)
	r := byte_reader(out[:])
	rec := record_take(&r)
	testing.expect_value(t, rec_need(&rec, Test_Tag.Count, i32), 7)
	testing.expect(t, rec.ok && rec_once(&rec, Test_Tag.Count))
	_ = rec_need(&rec, Test_Tag.Later, f64)
	testing.expect(t, !rec.ok)
	rec.ok = true
	testing.expect(t, !rec_once(&rec, Test_Tag.Item))
}
