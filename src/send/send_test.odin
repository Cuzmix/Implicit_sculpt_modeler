package send

import "core:math/rand"
import "core:testing"

import "../jobs"

// Bytes that look like a scene file's floats: no repeats a chunker could lean on.
@(private = "file")
noise :: proc(n: int, seed: u64, allocator := context.allocator) -> []u8 {
	b := make([]u8, n, allocator)
	state := rand.create(seed)
	gen := rand.default_random_generator(&state)
	for &v in b do v = u8(rand.uint32(gen))
	return b
}

@(private = "file")
hello_fixture :: proc() -> Hello {
	return {protocol = PROTOCOL, scene_version = 36, role = .Tablet, device = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}, port = 47820, name = "Bolt's iPad", build = "dev"}
}

@(test)
a_frame_reads_back_as_written :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	frame_put(&out, .Chunk, 7, {1, 2, 3})
	frame_put(&out, .Received, 8, nil)
	f, used, status := frame_parse(out[:])
	testing.expect_value(t, status, Parse.Ok)
	testing.expect_value(t, f.kind, Kind.Chunk)
	testing.expect_value(t, f.seq, 7)
	testing.expect_value(t, len(f.body), 3)
	g, used2, status2 := frame_parse(out[used:])
	testing.expect_value(t, status2, Parse.Ok)
	testing.expect_value(t, g.kind, Kind.Received)
	testing.expect_value(t, used + used2, len(out))
}

@(test)
a_frame_cut_short_asks_for_more :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	frame_put(&out, .Chunk, 1, {1, 2, 3, 4})
	for n in 0 ..< len(out) {
		_, used, status := frame_parse(out[:n])
		testing.expect_value(t, status, Parse.More)
		testing.expect_value(t, used, 0)
	}
}

@(test)
something_else_on_the_port_is_refused_at_once :: proc(t: ^testing.T) {
	_, _, status := frame_parse(transmute([]u8)string("GET"))
	testing.expect_value(t, status, Parse.Bad)
	out := make([dynamic]u8)
	defer delete(out)
	frame_put(&out, .Chunk, 1, nil)
	out[4] = 99 // a kind no build sends
	_, _, status = frame_parse(out[:])
	testing.expect_value(t, status, Parse.Bad)
	out[4] = u8(Kind.Chunk)
	out[15] = 0x7f // a body of two gigabytes
	_, _, status = frame_parse(out[:HEADER_SIZE])
	testing.expect_value(t, status, Parse.Bad)
}

@(test)
a_hello_reads_back_and_matches_its_own_build :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	h := hello_fixture()
	hello_put(&out, h)
	got, ok := hello_get(out[:])
	testing.expect(t, ok)
	testing.expect_value(t, got.name, "Bolt's iPad")
	testing.expect_value(t, got.device, h.device)
	testing.expect_value(t, got.role, Role.Tablet)
	testing.expect_value(t, hello_check(h, got), Refusal.None)
	// A byte more or less is another build's hello, or a damaged one.
	append(&out, 0)
	_, ok = hello_get(out[:])
	testing.expect(t, !ok)
	_, ok = hello_get(out[:len(out) - 2])
	testing.expect(t, !ok)
}

@(test)
another_build_is_refused_before_anything_is_sent :: proc(t: ^testing.T) {
	mine := hello_fixture()
	theirs := mine
	theirs.scene_version = 35
	testing.expect_value(t, hello_check(mine, theirs), Refusal.Scene_Version)
	theirs.protocol = PROTOCOL + 1
	testing.expect_value(t, hello_check(mine, theirs), Refusal.Protocol)
}

@(test)
a_name_with_control_characters_is_refused :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	h := hello_fixture()
	h.name = "Bolt\x1b[2J"
	hello_put(&out, h)
	_, ok := hello_get(out[:])
	testing.expect(t, !ok)
}

@(test)
a_long_name_is_cut_at_a_character :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	h := hello_fixture()
	h.name = "ééééééééééééééééééééééééééééééééééééééééééé" // 86 bytes
	hello_put(&out, h)
	got, ok := hello_get(out[:])
	testing.expect(t, ok)
	testing.expect_value(t, len(got.name), 64)
}

@(test)
chunks_cover_the_file_within_their_sizes :: proc(t: ^testing.T) {
	data := noise(9 << 20, 1)
	defer delete(data)
	chunks := chunks_of(data)
	defer delete(chunks)
	at := u64(0)
	for c, i in chunks {
		testing.expect_value(t, c.offset, at)
		testing.expect(t, c.size <= CHUNK_MAX)
		if i < len(chunks) - 1 do testing.expect(t, c.size >= CHUNK_MIN)
		testing.expect_value(t, c.hash, hash_bytes(data[c.offset:][:c.size]))
		at += u64(c.size)
	}
	testing.expect_value(t, at, u64(len(data)))
	// Normalised chunking keeps the average near CHUNK_AVERAGE.
	average := len(data) / len(chunks)
	testing.expectf(t, average > CHUNK_AVERAGE / 2 && average < CHUNK_AVERAGE * 2, "average chunk %d bytes", average)
}

@(test)
chunks_are_the_same_with_a_pool :: proc(t: ^testing.T) {
	data := noise(6 << 20, 2)
	defer delete(data)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a := chunks_of(data)
	defer delete(a)
	b := chunks_of(data, &pool)
	defer delete(b)
	testing.expect_value(t, len(a), len(b))
	for i in 0 ..< min(len(a), len(b)) do testing.expect_value(t, a[i], b[i])
}

@(test)
an_insert_moves_only_the_cuts_near_it :: proc(t: ^testing.T) {
	data := noise(12 << 20, 3)
	defer delete(data)
	// 1,000 new bytes a third of the way in: every later chunk shifts, but by content
	// they are the same.
	edited := make([dynamic]u8, 0, len(data) + 1000)
	defer delete(edited)
	append(&edited, ..data[:len(data) / 3])
	extra := noise(1000, 4)
	defer delete(extra)
	append(&edited, ..extra)
	append(&edited, ..data[len(data) / 3:])
	a := chunks_of(data)
	defer delete(a)
	b := chunks_of(edited[:])
	defer delete(b)
	shared := 0
	for c in b do for d in a do if c.hash == d.hash {
		shared += 1
		break
	}
	testing.expectf(t, len(b) - shared <= 3, "%d of %d chunks changed", len(b) - shared, len(b))
}

@(test)
an_offer_reads_back_and_refuses_lies :: proc(t: ^testing.T) {
	data := noise(3 << 20, 5)
	defer delete(data)
	chunks := chunks_of(data)
	defer delete(chunks)
	o := offer_make(42, 3, len(data), chunks)
	out := make([dynamic]u8)
	defer delete(out)
	offer_put(&out, o)
	got, ok := offer_get(out[:])
	testing.expect(t, ok)
	testing.expect_value(t, got.token, 42)
	testing.expect_value(t, got.revision, 3)
	testing.expect_value(t, got.size, u64(len(data)))
	testing.expect_value(t, len(got.chunks), len(chunks))
	for i in 0 ..< min(len(got.chunks), len(chunks)) do testing.expect_value(t, got.chunks[i], chunks[i])
	offer_destroy(&got)
	// A size that does not add up, a count the body cannot hold, a chunk whose hash the
	// file's hash does not cover: each refused.
	lie := make([]u8, len(out))
	defer delete(lie)
	copy(lie, out[:])
	lie[16] ~= 1
	_, ok = offer_get(lie)
	testing.expect(t, !ok)
	copy(lie, out[:])
	lie[56] = 0xff
	_, ok = offer_get(lie)
	testing.expect(t, !ok)
	copy(lie, out[:])
	lie[len(lie) - 1] ~= 1
	_, ok = offer_get(lie)
	testing.expect(t, !ok)
	_, ok = offer_get(out[:len(out) - 1])
	testing.expect(t, !ok)
}

@(test)
a_need_list_must_rise_within_the_offer :: proc(t: ^testing.T) {
	chunks := []Chunk{{size = CHUNK_MIN}, {offset = CHUNK_MIN, size = CHUNK_MIN}, {offset = 2 * CHUNK_MIN, size = 10}}
	o := Offer{chunks = chunks}
	out := make([dynamic]u8)
	defer delete(out)
	need_put(&out, {0, 2})
	got, ok := need_get(out[:], o)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), 2)
	delete(got)
	for bad in ([][]u32{{2, 0}, {1, 1}, {3}}) {
		clear(&out)
		need_put(&out, bad)
		_, ok = need_get(out[:], o)
		testing.expect(t, !ok)
	}
}

// A receiver's disk in memory: the base file to read from and the new file being
// written.
@(private = "file")
Disk :: struct {
	base: []u8,
	new:  []u8,
}

@(private = "file")
disk_read :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
	d := cast(^Disk)user
	if offset + u64(len(data)) > u64(len(d.base)) do return false
	copy(data, d.base[offset:])
	return true
}

@(private = "file")
disk_write :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
	d := cast(^Disk)user
	copy(d.new[offset:], data)
	return true
}

// Sends data to a receiver whose base is base, over frames as a socket would carry
// them, and returns how many chunks went over.
@(private = "file")
send_through :: proc(t: ^testing.T, data, base: []u8, loc := #caller_location) -> (sent: int) {
	chunks := chunks_of(data)
	defer delete(chunks)
	wire := make([dynamic]u8)
	defer delete(wire)
	offer_put(&wire, offer_make(1, 2, len(data), chunks))
	offer, ok := offer_get(wire[:])
	testing.expect(t, ok, loc = loc)
	defer offer_destroy(&offer)
	base_chunks := chunks_of(base)
	defer delete(base_chunks)
	disk := Disk{base = base, new = make([]u8, len(data))}
	defer delete(disk.new)
	r: Rebuild
	testing.expect(t, rebuild_init(&r, offer, {{base_chunks, disk_read, &disk}}, disk_write, &disk), loc = loc)
	defer rebuild_destroy(&r)
	need := rebuild_need(&r)
	defer delete(need)
	clear(&wire)
	need_put(&wire, need)
	asked, asked_ok := need_get(wire[:], offer)
	testing.expect(t, asked_ok, loc = loc)
	defer delete(asked)
	for i in asked {
		c := chunks[i]
		clear(&wire)
		chunk_put(&wire, i, data[c.offset:][:c.size])
		index, bytes, got := chunk_get(wire[:])
		testing.expect(t, got, loc = loc)
		testing.expect_value(t, rebuild_take(&r, index, bytes), Take.Ok, loc = loc)
	}
	testing.expect(t, rebuild_done(&r), loc = loc)
	testing.expect(t, string(disk.new) == string(data), "the rebuilt file is not the one sent", loc = loc)
	return len(asked)
}

@(test)
a_file_rebuilds_from_nothing :: proc(t: ^testing.T) {
	data := noise(5 << 20, 6)
	defer delete(data)
	chunks := chunks_of(data)
	defer delete(chunks)
	testing.expect_value(t, send_through(t, data, nil), len(chunks))
}

@(test)
a_second_send_carries_only_what_changed :: proc(t: ^testing.T) {
	base := noise(8 << 20, 7)
	defer delete(base)
	data := make([]u8, len(base))
	defer delete(data)
	copy(data, base)
	// A stroke changes a few kilobytes in two places.
	for i in 0 ..< 4000 do data[2 << 20 + i] ~= 0x55
	for i in 0 ..< 4000 do data[6 << 20 + i] ~= 0x55
	sent := send_through(t, data, base)
	testing.expectf(t, sent >= 2 && sent <= 6, "%d chunks sent", sent)
	testing.expect_value(t, send_through(t, base, base), 0)
}

@(test)
a_repeated_chunk_is_sent_once :: proc(t: ^testing.T) {
	block := noise(CHUNK_MAX, 8)
	defer delete(block)
	data := make([dynamic]u8)
	defer delete(data)
	for _ in 0 ..< 3 do append(&data, ..block)
	chunks := chunks_of(data[:])
	defer delete(chunks)
	sent := send_through(t, data[:], nil)
	testing.expectf(t, sent < len(chunks), "%d of %d chunks sent", sent, len(chunks))
}

@(test)
a_damaged_chunk_is_refused_and_the_file_is_not_done :: proc(t: ^testing.T) {
	data := noise(2 << 20, 9)
	defer delete(data)
	chunks := chunks_of(data)
	defer delete(chunks)
	offer := offer_make(1, 1, len(data), chunks)
	disk := Disk{new = make([]u8, len(data))}
	defer delete(disk.new)
	r: Rebuild
	testing.expect(t, rebuild_init(&r, offer, nil, disk_write, &disk))
	defer rebuild_destroy(&r)
	c := chunks[0]
	bad := make([]u8, c.size)
	defer delete(bad)
	copy(bad, data[:c.size])
	bad[100] ~= 1
	testing.expect_value(t, rebuild_take(&r, 0, bad), Take.Damaged)
	testing.expect_value(t, rebuild_take(&r, 0, data[:c.size - 1]), Take.Damaged)
	testing.expect_value(t, rebuild_take(&r, u32(len(chunks)), data[:c.size]), Take.Damaged)
	testing.expect(t, !rebuild_done(&r))
}

@(test)
a_base_changed_on_disk_is_not_trusted :: proc(t: ^testing.T) {
	data := noise(3 << 20, 10)
	defer delete(data)
	chunks := chunks_of(data)
	defer delete(chunks)
	base := make([]u8, len(data))
	defer delete(base)
	copy(base, data)
	// The chunk list says the base holds the file, but its bytes changed since.
	base[10] ~= 1
	disk := Disk{base = base, new = make([]u8, len(data))}
	defer delete(disk.new)
	r: Rebuild
	testing.expect(t, rebuild_init(&r, offer_make(1, 1, len(data), chunks), {{chunks, disk_read, &disk}}, disk_write, &disk))
	defer rebuild_destroy(&r)
	need := rebuild_need(&r)
	defer delete(need)
	testing.expect_value(t, len(need), 1)
	if len(need) == 1 do testing.expect_value(t, need[0], 0)
}

// The partial file of a send cut short, read back as a base.
@(private = "file")
partial_read :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
	d := cast(^Disk)user
	if offset + u64(len(data)) > u64(len(d.new)) do return false
	copy(data, d.new[offset:])
	return true
}

@(test)
a_send_cut_short_carries_on_from_what_it_wrote :: proc(t: ^testing.T) {
	data := noise(6 << 20, 11)
	defer delete(data)
	chunks := chunks_of(data)
	defer delete(chunks)
	offer := offer_make(1, 3, len(data), chunks)
	first := Disk{new = make([]u8, len(data))}
	defer delete(first.new)
	r: Rebuild
	testing.expect(t, rebuild_init(&r, offer, nil, disk_write, &first))
	// Half the chunks arrive, then the connection drops.
	half := len(chunks) / 2
	for c, i in chunks[:half] do testing.expect_value(t, rebuild_take(&r, u32(i), data[c.offset:][:c.size]), Take.Ok)
	saved := make([dynamic]u8)
	defer delete(saved)
	resume_put(&saved, &r)
	rebuild_destroy(&r)
	written, ok := resume_get(saved[:])
	testing.expect(t, ok)
	defer delete(written)
	testing.expect_value(t, len(written), half)
	// The next send of the same file asks only for the rest, reading the first half back
	// from the partial file.
	second := Disk{new = make([]u8, len(data))}
	defer delete(second.new)
	again: Rebuild
	testing.expect(t, rebuild_init(&again, offer, {{written, partial_read, &first}}, disk_write, &second))
	defer rebuild_destroy(&again)
	need := rebuild_need(&again)
	defer delete(need)
	testing.expect_value(t, len(need), len(chunks) - half)
	for i in need {
		c := chunks[i]
		testing.expect_value(t, rebuild_take(&again, i, data[c.offset:][:c.size]), Take.Ok)
	}
	testing.expect(t, rebuild_done(&again))
	testing.expect(t, string(second.new) == string(data))
	// A damaged record is refused, whatever its length.
	for n in 0 ..< len(saved) {
		cut, cut_ok := resume_get(saved[:n])
		testing.expect(t, !cut_ok)
		delete(cut)
	}
	// A byte of the first chunk's hash: past the length, token, revision, size, file hash,
	// count and that chunk's size.
	saved[4 + 8 + 8 + 8 + HASH_SIZE + 4 + 4 + 1] ~= 1
	bad, bad_ok := resume_get(saved[:])
	testing.expect(t, !bad_ok)
	delete(bad)
}

@(test)
many_twins_are_written_once_each :: proc(t: ^testing.T) {
	// A file of one block over and over, as an empty mask or colour layer makes: every
	// chunk is a twin of the first, sent once and written at each place.
	block := noise(CHUNK_MIN, 12)
	defer delete(block)
	// The same bytes again and again cut at the same place each time.
	data := make([dynamic]u8)
	defer delete(data)
	for _ in 0 ..< 200 do append(&data, ..block)
	chunks := chunks_of(data[:])
	defer delete(chunks)
	sent := send_through(t, data[:], nil)
	testing.expectf(t, sent <= 3, "%d of %d chunks sent", sent, len(chunks))
}
