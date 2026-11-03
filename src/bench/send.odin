package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../geom"
import "../jobs"
import "../send"
import "../sculpt"

// --send: at each size, what Send costs on each side for a sphere written as the scene
// file stores its sculpt: the sender cutting and hashing the file (on its one thread, as
// the send thread does, and across the pool for comparison), then one stroke and the file
// again, cut and offered to a receiver that holds the first copy, which rebuilds it in
// memory from that base and the chunks it asked for. The chunks sent and their megabytes
// are what crosses the network; the disk and Wi-Fi add their own time.
send_header :: proc() {
	fmt.println("| Vertices | Scene MB | Chunks | Cut and hash ms | MB/s | Pooled ms | After a stroke: chunks sent | MB sent | Receiver rebuild ms | Offer KB |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

// The second table: every chunk of the first file compressed on its own, as a send would,
// with LZ4 as it is and after shuffle4, on one thread: the share of the bytes left, the
// coder's speed, and the decoder's.
send_rows: [dynamic]string

send_footer :: proc() {
	fmt.println()
	fmt.println("| Vertices | LZ4 left | LZ4 MB/s | Shuffled LZ4 left | Shuffle + LZ4 MB/s | Unshuffle + decode MB/s |")
	fmt.println("| --- | --- | --- | --- | --- | --- |")
	for row in send_rows {
		fmt.println(row)
		delete(row)
	}
	delete(send_rows)
}

@(private = "file")
send_compression :: proc(vcount: int, data: []u8, chunks: []send.Chunk) {
	out := make([]u8, send.lz4_bound(send.CHUNK_MAX))
	defer delete(out)
	shuffled := make([]u8, send.CHUNK_MAX)
	defer delete(shuffled)
	back := make([]u8, send.CHUNK_MAX)
	defer delete(back)
	plain_bytes, shuffled_bytes := 0, 0
	t0 := time.tick_now()
	for c in chunks do plain_bytes += send.lz4_compress(data[c.offset:][:c.size], out)
	plain_ms := time.duration_milliseconds(time.tick_since(t0))
	decode: time.Duration
	t1 := time.tick_now()
	for c in chunks {
		piece := data[c.offset:][:c.size]
		send.shuffle4(piece, shuffled[:c.size])
		n := send.lz4_compress(shuffled[:c.size], out)
		shuffled_bytes += n
		td := time.tick_now()
		m, ok := send.lz4_decompress(out[:n], shuffled[:c.size])
		send.unshuffle4(shuffled[:c.size], back[:c.size])
		decode += time.tick_since(td)
		assert(ok && m == int(c.size) && string(back[:c.size]) == string(piece))
	}
	shuffled_ms := time.duration_milliseconds(time.tick_since(t1)) - time.duration_milliseconds(decode)
	mb := f64(len(data)) / (1 << 20)
	append(&send_rows, fmt.aprintf("| %s | %.0f%% | %.0f | %.0f%% | %.0f | %.0f |", thousands(vcount),
		100 * f64(plain_bytes) / f64(len(data)), mb / (plain_ms / 1000), 100 * f64(shuffled_bytes) / f64(len(data)),
		mb / (shuffled_ms / 1000), mb / (time.duration_milliseconds(decode) / 1000)))
}

run_send :: proc(target: int, pool: ^jobs.Pool) {
	l: sculpt.Levels
	sculpt.levels_init(&l, geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool), pool, node_triangles)
	defer sculpt.levels_destroy(&l)
	free_all(context.temp_allocator)
	vcount := len(l.levels[0].mesh.positions)

	before := make([dynamic]u8)
	defer delete(before)
	sculpt.levels_write(&l, &before)
	free_all(context.temp_allocator)

	t0 := time.tick_now()
	base := send.chunks_of(before[:])
	cut_ms := time.duration_milliseconds(time.tick_since(t0))
	defer delete(base)
	t1 := time.tick_now()
	pooled := send.chunks_of(before[:], pool)
	pooled_ms := time.duration_milliseconds(time.tick_since(t1))
	assert(len(pooled) == len(base))
	for c, i in pooled do assert(c == base[i])
	delete(pooled)
	send_compression(vcount, before[:], base)

	// One stroke across the front, as the brush bench lays it.
	s := &l.levels[0].sculptor
	brush := sculpt.Brush{kind = .Clay, radius = 0.13, strength = 0.3, stroke_dir = {1, 0, 0}, tip_roundness = sculpt.CLAY_TIP_ROUNDNESS, tip_scale = 1}
	eye := Vec3{0, 0, 3.5}
	sculpt.sculptor_stroke_begin(s)
	for i in 0 ..< DABS {
		k := f32(i) / f32(DABS - 1)
		point := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
		hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(point - eye))
		if !ok do hit = point
		_ = sculpt.apply_dab(s, brush, hit)
		if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 do _ = sculpt.sculptor_flush(s)
	}
	_ = sculpt.sculptor_stroke_end(s)
	for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
	free_all(context.temp_allocator)

	after := make([dynamic]u8)
	defer delete(after)
	sculpt.levels_write(&l, &after)
	free_all(context.temp_allocator)
	chunks := send.chunks_of(after[:])
	defer delete(chunks)
	offer := send.offer_make(1, 2, len(after), chunks)
	wire := make([dynamic]u8)
	defer delete(wire)
	send.offer_put(&wire, offer)
	offer_kb := f64(len(wire)) / 1024

	Memory :: struct {
		base, new: []u8,
	}
	memory := Memory{before[:], make([]u8, len(after))}
	defer delete(memory.new)
	// Touched first, as a file on disk already is: a fresh allocation's first writes
	// fault in its pages, which would cost more here than the rebuild itself.
	for i := 0; i < len(memory.new); i += 4096 do memory.new[i] = 1
	read :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
		m := cast(^Memory)user
		if offset + u64(len(data)) > u64(len(m.base)) do return false
		copy(data, m.base[offset:])
		return true
	}
	write :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
		m := cast(^Memory)user
		copy(m.new[offset:], data)
		return true
	}
	t2 := time.tick_now()
	r: send.Rebuild
	assert(send.rebuild_init(&r, offer, {{base, read, &memory}}, write, &memory))
	need := send.rebuild_need(&r)
	sent_bytes := 0
	for i in need {
		c := chunks[i]
		sent_bytes += int(c.size)
		assert(send.rebuild_take(&r, i, after[c.offset:][:c.size]) == .Ok)
	}
	rebuild_ms := time.duration_milliseconds(time.tick_since(t2))
	assert(send.rebuild_done(&r))
	assert(string(memory.new) == string(after[:]))
	send.rebuild_destroy(&r)
	free_all(context.temp_allocator)

	mb := f64(len(before)) / (1 << 20)
	fmt.printfln("| %s | %.0f | %d | %.0f | %.0f | %.0f | %d of %d | %.1f | %.0f | %.0f |",
		thousands(vcount), mb, len(base), cut_ms, mb / (cut_ms / 1000), pooled_ms, len(need), len(chunks), f64(sent_bytes) / (1 << 20), rebuild_ms, offer_kb)
	delete(need)
}
