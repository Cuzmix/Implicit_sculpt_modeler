package send

import "core:testing"

@(private = "file")
round_trip :: proc(t: ^testing.T, data: []u8, loc := #caller_location) -> (packed: int) {
	out := make([]u8, lz4_bound(len(data)))
	defer delete(out)
	packed = lz4_compress(data, out)
	back := make([]u8, len(data))
	defer delete(back)
	n, ok := lz4_decompress(out[:packed], back)
	testing.expect(t, ok && n == len(data), loc = loc)
	testing.expect(t, string(back) == string(data), "the block does not decode to its input", loc = loc)
	return packed
}

@(test)
lz4_blocks_decode_to_their_input :: proc(t: ^testing.T) {
	// Nothing, a few bytes, noise (no matches, so the bound holds) and runs (long matches
	// and long literal counts).
	round_trip(t, nil)
	round_trip(t, transmute([]u8)string("abcdabcdabcdabcdabcdab"))
	n := noise(300_000, 21)
	defer delete(n)
	testing.expect(t, round_trip(t, n) <= lz4_bound(len(n)))
	runs := make([]u8, 200_000)
	defer delete(runs)
	for &b, i in runs do b = u8(i / 1000)
	testing.expect(t, round_trip(t, runs) < len(runs) / 20)
}

@(test)
a_damaged_lz4_block_is_refused :: proc(t: ^testing.T) {
	runs := make([]u8, 50_000)
	defer delete(runs)
	for &b, i in runs do b = u8(i / 300)
	out := make([]u8, lz4_bound(len(runs)))
	defer delete(out)
	packed := lz4_compress(runs, out)
	back := make([]u8, len(runs))
	defer delete(back)
	// Cut anywhere, it never reads or writes past an end.
	for k in 0 ..< packed do _, _ = lz4_decompress(out[:k], back)
	// Too small an output is refused.
	_, ok := lz4_decompress(out[:packed], back[:len(back) - 1])
	testing.expect(t, !ok)
}

@(test)
shuffle4_comes_back :: proc(t: ^testing.T) {
	data := noise(4099, 22)
	defer delete(data)
	a := make([]u8, len(data))
	defer delete(a)
	b := make([]u8, len(data))
	defer delete(b)
	shuffle4(data, a)
	unshuffle4(a, b)
	testing.expect(t, string(b) == string(data))
	testing.expect_value(t, a[1], data[4])
}

@(test)
a_chunk_travels_packed_only_when_that_saves :: proc(t: ^testing.T) {
	// Floats along a curve, as a mesh's positions are: their high bytes repeat.
	floats := make([]f32, 60_000)
	defer delete(floats)
	for &f, i in floats do f = 1 + f32(i) * 0.0001
	smooth := (cast([^]u8)raw_data(floats))[:len(floats) * 4]
	rough := noise(len(smooth), 23)
	defer delete(rough)
	for data, k in ([2][]u8{smooth, rough}) {
		chunks := []Chunk{{offset = 0, size = u32(len(data)), hash = hash_bytes(data)}}
		offer := offer_make(1, 1, len(data), chunks)
		scratch: Chunk_Scratch
		defer chunk_scratch_destroy(&scratch)
		wire := make([dynamic]u8)
		defer delete(wire)
		chunk_put(&wire, 0, data, &scratch)
		index, bytes, packing, ok := chunk_get(wire[:], offer, &scratch)
		testing.expect(t, ok && index == 0 && string(bytes) == string(data))
		testing.expect_value(t, packing, Packing.Shuffled_Lz4 if k == 0 else Packing.Raw)
		if k == 0 do testing.expectf(t, len(wire) < len(data) / 2, "%d of %d bytes", len(wire), len(data))
		// Cut short, it never reads past its end, and never reads as the chunk.
		for n in 0 ..< len(wire) {
			_, cut, _, cut_ok := chunk_get(wire[:n], offer, &scratch)
			testing.expect(t, !cut_ok || string(cut) != string(data))
		}
		// An unknown packing or index is refused.
		wire[4] = 9
		_, _, _, ok = chunk_get(wire[:], offer, &scratch)
		testing.expect(t, !ok)
		wire[4], wire[0] = 0, 1
		_, _, _, ok = chunk_get(wire[:], offer, &scratch)
		testing.expect(t, !ok)
	}
}
