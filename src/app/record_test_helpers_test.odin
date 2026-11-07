package main

import "../geom"

// The fields object_get_fields reads, from bytes object_put_bytes wrote; damage turns r.ok
// false, as a positional read did, so a test checks one flag.
test_object_fields :: proc(r: ^geom.Byte_Reader, obj: ^Object) {
	rec := geom.record_take(r)
	object_get_fields(&rec, obj)
	if !rec.ok do r.ok = false
}

// The record of an object object_put_bytes wrote into `out`; its payloads alias `out`, so a
// test changes a field's bytes in place.
test_object_record :: proc(out: []u8) -> geom.Record {
	r := geom.byte_reader(out)
	return geom.record_take(&r)
}

// The scene chunk's record scene_header_put wrote into `head`, aliasing it.
test_scene_record :: proc(head: []u8) -> geom.Record {
	r := geom.byte_reader(head[len(SCENE_MAGIC):])
	_ = geom.byte_get(&r, u32)
	_ = preview_block_skip(&r)
	_, chunk, _ := scene_chunk_next(&r)
	return geom.record_of(chunk.data)
}

// A copy of the standalone record `data` (geom.record_begin's) with the payload of its
// first field of tags[0], or inside that of tags[1] and so on, replaced by `value`, each
// size around it mended; a field missing on the way is added at the end. Temporary.
test_record_set :: proc(data: []u8, value: []u8, tags: ..u16) -> []u8 {
	fields := test_fields_set(data[size_of(u64):], value, tags)
	out := make([dynamic]u8, context.temp_allocator)
	geom.byte_put(&out, u64(len(fields)))
	append(&out, ..fields)
	return out[:]
}

@(private = "file")
test_fields_set :: proc(fields: []u8, value: []u8, tags: []u16) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	put :: proc(out: ^[dynamic]u8, tag: u16, fields: []u8, value: []u8, tags: []u16) {
		inner := value if len(tags) == 1 else test_fields_set(fields, value, tags[1:])
		geom.byte_put(out, tag)
		geom.byte_put(out, u64(len(inner)))
		append(out, ..inner)
	}
	r := geom.byte_reader(fields)
	found := false
	for r.ok && r.at < len(fields) {
		start := r.at
		tag := geom.byte_get(&r, u16)
		size := geom.byte_get(&r, u64)
		payload := geom.byte_get_bytes(&r, int(size))
		if tag == tags[0] && !found {
			found = true
			put(&out, tag, payload, value, tags)
		} else do append(&out, ..fields[start:r.at])
	}
	if !found do put(&out, tags[0], nil, value, tags)
	return out[:]
}
