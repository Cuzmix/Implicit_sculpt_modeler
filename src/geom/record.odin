package geom

import "base:intrinsics"
import "core:mem"
import "core:reflect"
import "core:strings"

// Tagged records, the scene file's way of surviving updates: a record is a run of fields,
// each a tag, a size and its payload, so a reader finds a value by its tag rather than by
// where it stands. A later build adds a field under a new tag and an earlier file simply
// lacks it (the reader takes its default); an earlier build meets a field it does not know
// and steps over it. Tags are never reused or retyped (AGENTS.md), which is what makes a
// misread impossible where a positional layout would shift every value after a change.
//
// A field is `tag u16, size u64, payload`; a record on its own (record_begin) is a u64 size
// and its fields. Sizes are 64-bit because one field can hold a 50M-vertex mesh's sculpt
// layers, more than 4 GB together.

// Tags at or above this are critical: a reader that does not know one must refuse the
// record rather than step over it, as PNG's critical chunks are, because the field changes
// how the fields it does know are to be read (record_known).
RECORD_TAG_CRITICAL :: u16(0x8000)

// The bytes before a field's payload: its tag and its size.
RECORD_FIELD_HEAD :: size_of(u16) + size_of(u64)

// A record being read: its fields' bytes, checked whole once (record_of, record_take), and
// whether every read so far found what it expected. A get of a field whose size is wrong
// for its type turns `ok` false, as a short read turns Byte_Reader.ok false, so a caller
// checks once at the end.
Record :: struct {
	data: []u8,
	ok:   bool,
}

// A record over `data`, which must be fields from end to end: a size past the end, or bytes
// left over that are no whole field head, are damage (ok false).
record_of :: proc(data: []u8) -> Record {
	at := 0
	for at < len(data) {
		if len(data) - at < RECORD_FIELD_HEAD do return {nil, false}
		size: u64
		mem.copy(&size, &data[at + size_of(u16)], size_of(u64))
		at += RECORD_FIELD_HEAD
		if size > u64(len(data) - at) do return {nil, false}
		at += int(size)
	}
	return {data, true}
}

// Starts a record of its own in `out` (a u64 size, filled by record_end); returns where the
// size is. Used where a record stands inside bytes that are not themselves fields: an
// object's bytes in an undo snapshot, a copy or a chunk.
record_begin :: proc(out: ^[dynamic]u8) -> int {
	at := len(out)
	byte_put(out, u64(0))
	return at
}

// Ends the record begun at `at`: every field written since is in it.
record_end :: proc(out: ^[dynamic]u8, at: int) {
	size := transmute([8]u8)u64(len(out) - at - size_of(u64))
	copy(out[at:][:8], size[:])
}

// Reads a record record_begin wrote from `r`; r.ok and the record's ok are false on damage.
record_take :: proc(r: ^Byte_Reader) -> Record {
	size := byte_get(r, u64)
	if !r.ok || size > u64(len(r.data) - r.at) {
		r.ok = false
		return {nil, false}
	}
	rec := record_of(byte_get_bytes(r, int(size)))
	if !rec.ok do r.ok = false
	return rec
}

// A field's payload, written in place by the caller: rec_begin returns where its size is and
// rec_end fills it, so an existing writer (a level's bytes, a nested record's fields) can
// write the payload directly into `out` with no copy.
rec_begin :: proc(out: ^[dynamic]u8, tag: $E) -> int where intrinsics.type_is_enum(E) {
	byte_put(out, u16(tag))
	at := len(out)
	byte_put(out, u64(0))
	return at
}

rec_end :: proc(out: ^[dynamic]u8, at: int) {
	size := transmute([8]u8)u64(len(out) - at - size_of(u64))
	copy(out[at:][:8], size[:])
}

// A field of one value of plain data (a number, a vector, a fixed array).
rec_put :: proc(out: ^[dynamic]u8, tag: $E, v: $T) where intrinsics.type_is_enum(E) {
	byte_put(out, u16(tag))
	byte_put(out, u64(size_of(T)))
	byte_put(out, v)
}

// A field of a run of plain values.
rec_put_slice :: proc(out: ^[dynamic]u8, tag: $E, s: []$T) where intrinsics.type_is_enum(E) {
	byte_put(out, u16(tag))
	byte_put(out, u64(len(s) * size_of(T)))
	byte_put_slice(out, s)
}

// A field of text: its bytes, the field's size its length.
rec_put_string :: proc(out: ^[dynamic]u8, tag: $E, s: string) where intrinsics.type_is_enum(E) {
	byte_put(out, u16(tag))
	byte_put(out, u64(len(s)))
	append(out, s)
}

// The payload of the first field of `tag` after byte `from` of the record, and where the next
// field starts; present is false when there is none. Lookups walk the fields, since a
// record holds tens of them and the walk touches only their heads.
rec_find_from :: proc(rec: ^Record, tag: u16, from: int) -> (payload: []u8, next: int, present: bool) {
	at := from
	for at < len(rec.data) {
		t: u16
		size: u64
		mem.copy(&t, &rec.data[at], size_of(u16))
		mem.copy(&size, &rec.data[at + size_of(u16)], size_of(u64))
		start := at + RECORD_FIELD_HEAD
		at = start + int(size)
		if t == tag do return rec.data[start:at], at, true
	}
	return nil, at, false
}

// The payload of the field of `tag`, the first when it repeats.
rec_find :: proc(rec: ^Record, tag: $E) -> (payload: []u8, present: bool) where intrinsics.type_is_enum(E) {
	payload, _, present = rec_find_from(rec, u16(tag), 0)
	return
}

// Whether the record has a field of `tag`.
rec_has :: proc(rec: ^Record, tag: $E) -> bool where intrinsics.type_is_enum(E) {
	_, present := rec_find(rec, tag)
	return present
}

// The value of the field of `tag`, or `default` when the record has none (a file an earlier
// build wrote). A field of another size is damage: ok goes false and the default comes back.
rec_get :: proc(rec: ^Record, tag: $E, $T: typeid, default: T) -> T where intrinsics.type_is_enum(E) {
	payload, present := rec_find(rec, tag)
	if !present do return default
	if len(payload) != size_of(T) {
		rec.ok = false
		return default
	}
	v: T
	mem.copy(&v, raw_data(payload), size_of(T))
	return v
}

// The values of the field of `tag`, made with `allocator`; nil when it is missing. A size
// that is not a whole number of values is damage.
rec_get_slice :: proc(rec: ^Record, tag: $E, $T: typeid, allocator := context.allocator) -> []T where intrinsics.type_is_enum(E) {
	payload, present := rec_find(rec, tag)
	if !present do return nil
	if len(payload) % size_of(T) != 0 {
		rec.ok = false
		return nil
	}
	out := make([]T, len(payload) / size_of(T), allocator)
	if len(payload) > 0 do mem.copy(raw_data(out), raw_data(payload), len(payload))
	return out
}

// Fills `dst` from the field of `tag`, which must hold exactly len(dst) values; present is
// false (dst untouched) when it is missing, and a field of another size is damage.
rec_get_into :: proc(rec: ^Record, tag: $E, dst: []$T) -> (present: bool) where intrinsics.type_is_enum(E) {
	payload: []u8
	payload, present = rec_find(rec, tag)
	if !present do return
	if len(payload) != len(dst) * size_of(T) {
		rec.ok = false
		return
	}
	if len(payload) > 0 do mem.copy(raw_data(dst), raw_data(payload), len(payload))
	return
}

// The text of the field of `tag`, cloned with `allocator`; `default` (cloned too) when it
// is missing.
rec_get_string :: proc(rec: ^Record, tag: $E, default := "", allocator := context.allocator) -> string where intrinsics.type_is_enum(E) {
	payload, present := rec_find(rec, tag)
	return strings.clone(string(payload) if present else default, allocator)
}

// A reader over the field of `tag`'s payload, for a part whose own reader takes bytes (a
// level's arrays, a nested sub-format); present is false when it is missing.
rec_reader :: proc(rec: ^Record, tag: $E) -> (r: Byte_Reader, present: bool) where intrinsics.type_is_enum(E) {
	payload: []u8
	payload, present = rec_find(rec, tag)
	return byte_reader(payload), present
}

// The nested record in the field of `tag`; a missing one is an empty record (every get
// takes its default), a damaged one turns the outer record's ok false too.
rec_sub :: proc(rec: ^Record, tag: $E) -> (sub: Record, present: bool) where intrinsics.type_is_enum(E) {
	payload: []u8
	payload, present = rec_find(rec, tag)
	if !present do return {nil, true}, false
	sub = record_of(payload)
	if !sub.ok do rec.ok = false
	return
}

// Steps through the fields of `tag` in the order they were written, for a list written as
// one field an item: `at` starts at 0 and is moved past each one found.
rec_next :: proc(rec: ^Record, tag: $E, at: ^int) -> (payload: []u8, present: bool) where intrinsics.type_is_enum(E) {
	payload, at^, present = rec_find_from(rec, u16(tag), at^)
	return
}

// How many fields of `tag` the record holds.
rec_count :: proc(rec: ^Record, tag: $E) -> int where intrinsics.type_is_enum(E) {
	n, at := 0, 0
	for {
		_, next, present := rec_find_from(rec, u16(tag), at)
		if !present do return n
		n += 1
		at = next
	}
}

// The value of a field the record must have: one missing is damage, for a value no default
// can stand in for (an array of positions, the kind of an object).
rec_need :: proc(rec: ^Record, tag: $E, $T: typeid) -> T where intrinsics.type_is_enum(E) {
	if !rec_has(rec, tag) {
		rec.ok = false
		return {}
	}
	return rec_get(rec, tag, T, T{})
}

// Whether a field that must stand once does: a second one is damage, since which of the two
// a reader took would then decide what opens.
rec_once :: proc(rec: ^Record, tag: $E) -> bool where intrinsics.type_is_enum(E) {
	if rec_count(rec, tag) > 1 do rec.ok = false
	return rec.ok
}

// Whether a reader whose tags are `E` can read the record: false when it holds a critical
// tag (RECORD_TAG_CRITICAL) that `E` does not name, which a later build wrote. `skipped`
// counts the other fields `E` does not name, which the reader steps over and an earlier
// build's save then drops.
record_known :: proc(rec: ^Record, $E: typeid) -> (known: bool, skipped: int) where intrinsics.type_is_enum(E) {
	at := 0
	for at < len(rec.data) {
		t: u16
		size: u64
		mem.copy(&t, &rec.data[at], size_of(u16))
		mem.copy(&size, &rec.data[at + size_of(u16)], size_of(u64))
		at += RECORD_FIELD_HEAD + int(size)
		if reflect.enum_value_has_name(E(t)) do continue
		if t >= RECORD_TAG_CRITICAL do return false, skipped
		skipped += 1
	}
	return true, skipped
}
