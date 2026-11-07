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
