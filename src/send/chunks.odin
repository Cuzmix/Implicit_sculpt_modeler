package send

import "base:runtime"
import "core:crypto/blake2b"
import "core:slice"

import "../jobs"

// A scene file is cut where its own bytes say, FastCDC's way (a gear hash over the bytes,
// a cut where its top bits are zero, a stricter test before the average size and a looser
// one after), so an edit to one object moves the cuts only near it: every chunk before and
// after it keeps its bytes and its hash, and a later send of the same scene carries only
// the chunks that changed. Fixed-size blocks would shift every block after a change of
// size, which a level, a mask or a new layer makes.

// No chunk is smaller, except a file's last: below this, the chunk list outweighs what it
// saves.
CHUNK_MIN :: 64 << 10
// About the average chunk: a 25M-vertex scene of 900 MB is some 3,600 chunks, an offer of
// 130 KB.
CHUNK_AVERAGE :: 256 << 10
// No chunk is larger, so that one frame carries one chunk and a lost connection loses at
// most this much.
CHUNK_MAX :: 1 << 20
// The largest scene file a send takes: far beyond any scene a tablet holds, and small
// enough that an offer of it fits in a frame.
FILE_MAX :: 16 << 30

HASH_SIZE :: 32
Hash :: [HASH_SIZE]u8

Chunk :: struct {
	offset: u64,
	size:   u32,
	hash:   Hash,
}

// The gear table: a fixed random-looking word for each byte value. Both sides must cut
// alike, so it is made by a fixed generator (splitmix64), never at random.
@(private = "file")
gear: [256]u64

@(private = "file", init)
gear_init :: proc "contextless" () {
	x := u64(0x5367_6e64_5363_6e65)
	for &g in gear {
		x += 0x9e37_79b9_7f4a_7c15
		z := x
		z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
		z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
		g = z ~ (z >> 31)
	}
}

// The test before the average size asks for two more zero bits than the average's 18,
// the test after it two fewer: FastCDC's normalised chunking, which keeps sizes near the
// average. The gear hash shifts left, so its top bits depend on the last 64 bytes.
@(private = "file")
MASK_SMALL :: u64(0xffff_f000_0000_0000)
@(private = "file")
MASK_LARGE :: u64(0xffff_0000_0000_0000)

// Where the chunk that starts data ends.
@(private = "file")
chunk_cut :: proc(data: []u8) -> int {
	n := len(data)
	if n <= CHUNK_MIN do return n
	end := min(n, CHUNK_MAX)
	normal := min(CHUNK_AVERAGE, end)
	h := u64(0)
	i := CHUNK_MIN
	for ; i < normal; i += 1 {
		h = (h << 1) + gear[data[i]]
		if h & MASK_SMALL == 0 do return i + 1
	}
	for ; i < end; i += 1 {
		h = (h << 1) + gear[data[i]]
		if h & MASK_LARGE == 0 do return i + 1
	}
	return end
}

hash_bytes :: proc(data: []u8) -> (h: Hash) {
	ctx: blake2b.Context
	blake2b.init(&ctx, HASH_SIZE)
	blake2b.update(&ctx, data)
	blake2b.final(&ctx, h[:])
	return h
}

// The chunks of data in order, each with its hash. The cuts are found on the calling
// thread (each depends on the last); the hashes, most of the time, on the pool. The
// result is the same with or without a pool.
chunks_of :: proc(data: []u8, pool: ^jobs.Pool = nil, allocator := context.allocator) -> []Chunk {
	list := make([dynamic]Chunk, 0, len(data) / CHUNK_AVERAGE + 1, allocator)
	at := 0
	for at < len(data) {
		n := chunk_cut(data[at:])
		append(&list, Chunk{offset = u64(at), size = u32(n)})
		at += n
	}
	Hashing :: struct {
		data:   []u8,
		chunks: []Chunk,
	}
	work := Hashing{data, list[:]}
	jobs.parallel_for(pool, len(list), &work, proc(p: rawptr, i: int) {
		w := cast(^Hashing)p
		c := &w.chunks[i]
		c.hash = hash_bytes(w.data[c.offset:][:c.size])
	})
	return list[:]
}

// The whole file's hash: over its size and its chunks' hashes in order. Each chunk is
// checked against its own hash as it arrives, so this binds the list (and so the file)
// without hashing a large file twice.
file_hash :: proc(size: u64, chunks: []Chunk) -> Hash {
	ctx: blake2b.Context
	blake2b.init(&ctx, HASH_SIZE)
	head: [8]u8
	for i in 0 ..< 8 do head[i] = u8(size >> (8 * uint(i)))
	blake2b.update(&ctx, head[:])
	for &c in chunks do blake2b.update(&ctx, c.hash[:])
	h: Hash
	blake2b.final(&ctx, h[:])
	return h
}

// A scene file as the sender offers it. token names the scene on every device (the one
// the scene file keeps); revision rises with each change sent, so a receiver can tell a
// newer copy from an older or a fork.
Offer :: struct {
	token:    u64,
	revision: u64,
	size:     u64,
	hash:     Hash,
	chunks:   []Chunk,
}

offer_make :: proc(token, revision: u64, size: int, chunks: []Chunk) -> Offer {
	return {token = token, revision = revision, size = u64(size), hash = file_hash(u64(size), chunks), chunks = chunks}
}

offer_put :: proc(out: ^[dynamic]u8, o: Offer) {
	put_u64(out, o.token)
	put_u64(out, o.revision)
	put_u64(out, o.size)
	hash := o.hash
	append(out, ..hash[:])
	put_u32(out, u32(len(o.chunks)))
	for &c in o.chunks {
		put_u32(out, c.size)
		append(out, ..c.hash[:])
	}
}

// An offer read from body, checked whole: chunk sizes within the limits, every chunk but
// the last at least CHUNK_MIN, the sizes adding up to the file's and the file's hash
// matching its list. Offsets follow from the sizes.
@(require_results)
offer_get :: proc(body: []u8, allocator := context.allocator) -> (o: Offer, ok: bool) {
	r := reader(body)
	o.token = get_u64(&r)
	o.revision = get_u64(&r)
	o.size = get_u64(&r)
	get_bytes(&r, o.hash[:])
	count := int(get_u32(&r))
	if !r.ok || o.size > FILE_MAX do return {}, false
	// Each chunk takes 36 bytes of the body: a count the body cannot hold is refused
	// before anything is allocated for it.
	if count * (4 + HASH_SIZE) != len(body) - r.at do return {}, false
	if (o.size == 0) != (count == 0) do return {}, false
	chunks := make([]Chunk, count, allocator)
	at := u64(0)
	for &c, i in chunks {
		c.offset = at
		c.size = get_u32(&r)
		get_bytes(&r, c.hash[:])
		if c.size == 0 || c.size > CHUNK_MAX || (i < count - 1 && c.size < CHUNK_MIN) {
			delete(chunks, allocator)
			return {}, false
		}
		at += u64(c.size)
	}
	if !reader_done(&r) || at != o.size || file_hash(o.size, chunks) != o.hash {
		delete(chunks, allocator)
		return {}, false
	}
	o.chunks = chunks
	return o, true
}

offer_destroy :: proc(o: ^Offer, allocator := context.allocator) {
	delete(o.chunks, allocator)
	o^ = {}
}

need_put :: proc(out: ^[dynamic]u8, indices: []u32) {
	put_u32(out, u32(len(indices)))
	for i in indices do put_u32(out, i)
}

// A need list read from body against the offer it answers: each index within the offer,
// in rising order, none twice.
@(require_results)
need_get :: proc(body: []u8, o: Offer, allocator := context.allocator) -> (indices: []u32, ok: bool) {
	r := reader(body)
	count := int(get_u32(&r))
	if !r.ok || count * 4 != len(body) - r.at || count > len(o.chunks) do return nil, false
	indices = make([]u32, count, allocator)
	for &i, k in indices {
		i = get_u32(&r)
		if int(i) >= len(o.chunks) || (k > 0 && i <= indices[k - 1]) {
			delete(indices, allocator)
			return nil, false
		}
	}
	return indices, true
}

chunk_put :: proc(out: ^[dynamic]u8, index: u32, data: []u8) {
	put_u32(out, index)
	append(out, ..data)
}

@(require_results)
chunk_get :: proc(body: []u8) -> (index: u32, data: []u8, ok: bool) {
	if len(body) < 4 do return 0, nil, false
	r := reader(body)
	index = get_u32(&r)
	return index, body[4:], true
}

// Rebuilds an offered file on the receiving side from the chunks of a file it already
// has (the base: the last copy of the same scene from that device) and those sent. Bytes
// go out through write, at their offsets in the new file, so a large file goes to disk
// rather than into memory; the base is read back through read. Every chunk, from the base
// or sent, is checked against its hash before it is written.
Write_Proc :: #type proc(user: rawptr, offset: u64, data: []u8) -> bool
Read_Proc :: #type proc(user: rawptr, offset: u64, data: []u8) -> bool

Rebuild :: struct {
	offer:     Offer,
	write:     Write_Proc,
	user:      rawptr,
	// For each chunk of the offer, whether it is written; and the first index of each
	// distinct hash, so a chunk the file holds twice is sent once.
	have:      []bool,
	first:     []u32,
	left:      int,
	allocator: runtime.Allocator,
}

// Begins rebuilding offer, writing what the base already holds. A base chunk that no
// longer matches its hash (the file changed on disk) is left to be sent.
rebuild_init :: proc(r: ^Rebuild, offer: Offer, base: []Chunk, read: Read_Proc, write: Write_Proc, user: rawptr, allocator := context.allocator) -> bool {
	r^ = {offer = offer, write = write, user = user, allocator = allocator}
	n := len(offer.chunks)
	r.have = make([]bool, n, allocator)
	r.first = make([]u32, n, allocator)
	r.left = n
	// Sorted by hash, then offer index: each chunk finds its twin's first index, and the
	// base's chunks are found, by binary search, with no map order in the result.
	Keyed :: struct {
		hash:  Hash,
		index: u32,
	}
	by_hash := make([]Keyed, n, context.temp_allocator)
	for &v, i in by_hash do v = {offer.chunks[i].hash, u32(i)}
	slice.sort_by(by_hash, proc(a, b: Keyed) -> bool {
		if a.hash != b.hash do return hash_less(a.hash, b.hash)
		return a.index < b.index
	})
	for k := 0; k < n; {
		j := k
		for j < n && by_hash[j].hash == by_hash[k].hash do j += 1
		for m in k ..< j do r.first[by_hash[m].index] = by_hash[k].index
		k = j
	}
	sorted_base := slice.clone(base, context.temp_allocator)
	slice.sort_by(sorted_base, proc(a, b: Chunk) -> bool {return hash_less(a.hash, b.hash)})
	buf: [dynamic]u8
	buf.allocator = context.temp_allocator
	for c, i in offer.chunks {
		if r.first[i] != u32(i) do continue
		at, found := slice.binary_search_by(sorted_base, c.hash, proc(e: Chunk, h: Hash) -> slice.Ordering {
			if e.hash == h do return .Equal
			return .Less if hash_less(e.hash, h) else .Greater
		})
		if !found || sorted_base[at].size != c.size do continue
		resize(&buf, int(c.size))
		if !read(user, sorted_base[at].offset, buf[:]) || hash_bytes(buf[:]) != c.hash do continue
		if !rebuild_write(r, u32(i), buf[:]) do return false
	}
	return true
}

rebuild_destroy :: proc(r: ^Rebuild) {
	delete(r.have, r.allocator)
	delete(r.first, r.allocator)
	r^ = {}
}

@(private = "file")
hash_less :: proc(a, b: Hash) -> bool {
	for i in 0 ..< HASH_SIZE do if a[i] != b[i] do return a[i] < b[i]
	return false
}

// Writes data, already checked, at chunk i and at every chunk with the same hash.
@(private = "file")
rebuild_write :: proc(r: ^Rebuild, i: u32, data: []u8) -> bool {
	for c, k in r.offer.chunks {
		if r.first[k] != i || r.have[k] do continue
		if !r.write(r.user, c.offset, data) do return false
		r.have[k] = true
		r.left -= 1
	}
	return true
}

// The chunks still to be sent, in rising order: one per distinct hash.
rebuild_need :: proc(r: ^Rebuild, allocator := context.allocator) -> []u32 {
	list := make([dynamic]u32, allocator)
	for k in 0 ..< len(r.have) do if !r.have[k] && r.first[k] == u32(k) do append(&list, u32(k))
	return list[:]
}

Take :: enum u8 {
	Ok,
	Damaged, // not the bytes the offer listed for that chunk, or no such chunk
	Failed,  // the bytes could not be written
}

// Takes a sent chunk. One already written is taken again without harm: a resumed send
// may repeat the chunk it was cut off in.
@(require_results)
rebuild_take :: proc(r: ^Rebuild, index: u32, data: []u8) -> Take {
	if int(index) >= len(r.offer.chunks) do return .Damaged
	c := r.offer.chunks[index]
	if int(c.size) != len(data) || hash_bytes(data) != c.hash do return .Damaged
	if r.have[index] do return .Ok
	return .Ok if rebuild_write(r, r.first[index], data) else .Failed
}

// Every chunk is written and checked, so the file is the one offered.
rebuild_done :: proc(r: ^Rebuild) -> bool {return r.left == 0}
