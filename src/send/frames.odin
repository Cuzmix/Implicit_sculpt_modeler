// Package send is what Send to computer and Send to tablet say over the local network:
// the frames, the hello that refuses another build, the scene file cut into chunks by its
// content, the offer that lists them, and the rebuilding of the file on the other side from
// the chunks it already holds and the ones sent. A pure package, as zip is: no sockets, no
// SDL, no app. The app's platform files move the bytes; everything the other side says is
// checked here before it is believed, and a damaged or hostile frame is refused, never
// asserted on.
package send

import "core:encoding/endian"
import "core:unicode/utf8"

// Bumped whenever a frame or message changes. There is no compatibility between builds
// before release: a peer with another number is refused in the hello.
PROTOCOL :: u16(1)

// The first bytes of every frame, so that something else that answers on the port is
// told apart at once.
MAGIC :: [4]u8{'S', 'S', 'N', 'D'}

// magic, kind, flags, two reserved bytes, sequence number, body length.
HEADER_SIZE :: 16

// The largest body a frame may claim: an offer of the largest file at the smallest
// chunks (FILE_MAX / CHUNK_MIN chunks of 36 bytes) fits with room to spare, and a peer
// claiming more is refused before anything is allocated.
BODY_MAX :: 16 << 20

Kind :: enum u8 {
	Hello    = 1, // who is speaking, and which build
	Refuse   = 2, // the session ends, and why
	Offer    = 3, // a scene file, as a list of chunks
	Need     = 4, // the chunks of an offer the receiver lacks
	Chunk    = 5, // one chunk's bytes
	Received = 6, // the whole file is rebuilt and checked
}

Frame :: struct {
	kind:  Kind,
	flags: u8,
	seq:   u32,
	body:  []u8, // into the bytes parsed
}

Parse :: enum u8 {
	Ok,
	More, // not a whole frame yet: read more and parse again
	Bad,  // not a frame of ours, or one claiming too much: end the session
}

// Appends one frame to out.
frame_put :: proc(out: ^[dynamic]u8, kind: Kind, seq: u32, body: []u8, flags: u8 = 0) {
	magic := MAGIC
	append(out, ..magic[:])
	append(out, u8(kind), flags, 0, 0)
	put_u32(out, seq)
	put_u32(out, u32(len(body)))
	append(out, ..body)
}

// The first frame in buf, and how many bytes it took. A header with the wrong magic, a
// kind we do not know, set reserved bytes or a body over BODY_MAX is Bad at once, before
// its body arrives.
@(require_results)
frame_parse :: proc(buf: []u8) -> (f: Frame, used: int, status: Parse) {
	if len(buf) < HEADER_SIZE {
		// A wrong start is refused as soon as it shows, so a stray connection is not
		// kept waiting for sixteen bytes.
		magic := MAGIC
		for b, i in buf[:min(len(buf), 4)] do if b != magic[i] do return {}, 0, .Bad
		return {}, 0, .More
	}
	if buf[0] != 'S' || buf[1] != 'S' || buf[2] != 'N' || buf[3] != 'D' do return {}, 0, .Bad
	kind := buf[4]
	if kind < u8(Kind.Hello) || kind > u8(Kind.Received) do return {}, 0, .Bad
	if buf[6] != 0 || buf[7] != 0 do return {}, 0, .Bad
	size := int(endian.unchecked_get_u32le(buf[12:]))
	if size > BODY_MAX do return {}, 0, .Bad
	if len(buf) < HEADER_SIZE + size do return {}, 0, .More
	f = Frame {
		kind  = Kind(kind),
		flags = buf[5],
		seq   = endian.unchecked_get_u32le(buf[8:]),
		body  = buf[HEADER_SIZE:][:size],
	}
	return f, HEADER_SIZE + size, .Ok
}

// Reads a message body front to back. Every get past the end yields zero and clears ok,
// so a decoder reads every field and checks ok once.
Reader :: struct {
	b:  []u8,
	at: int,
	ok: bool,
}

reader :: proc(b: []u8) -> Reader {return {b = b, ok = true}}

@(private)
take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.at + n > len(r.b) {
		r.ok = false
		return nil
	}
	s := r.b[r.at:][:n]
	r.at += n
	return s
}

get_u8 :: proc(r: ^Reader) -> u8 {
	s := take(r, 1)
	return s[0] if s != nil else 0
}

get_u16 :: proc(r: ^Reader) -> u16 {
	s := take(r, 2)
	return endian.unchecked_get_u16le(s) if s != nil else 0
}

get_u32 :: proc(r: ^Reader) -> u32 {
	s := take(r, 4)
	return endian.unchecked_get_u32le(s) if s != nil else 0
}

get_u64 :: proc(r: ^Reader) -> u64 {
	s := take(r, 8)
	return endian.unchecked_get_u64le(s) if s != nil else 0
}

get_bytes :: proc(r: ^Reader, dst: []u8) {
	s := take(r, len(dst))
	if s != nil do copy(dst, s)
}

// A string of at most max bytes: valid UTF-8 without control characters, since it is
// shown on screen as the other device's name.
get_string :: proc(r: ^Reader, max: int) -> string {
	n := int(get_u8(r))
	if n > max {
		r.ok = false
		return ""
	}
	s := string(take(r, n))
	if !r.ok do return ""
	if !utf8.valid_string(s) {
		r.ok = false
		return ""
	}
	for c in s do if c < 0x20 || c == 0x7f {
		r.ok = false
		return ""
	}
	return s
}

// The body ends exactly where its fields do: trailing bytes are a different build's
// message or a damaged one.
reader_done :: proc(r: ^Reader) -> bool {return r.ok && r.at == len(r.b)}

put_u16 :: proc(out: ^[dynamic]u8, v: u16) {append(out, u8(v), u8(v >> 8))}

put_u32 :: proc(out: ^[dynamic]u8, v: u32) {append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}

put_u64 :: proc(out: ^[dynamic]u8, v: u64) {
	put_u32(out, u32(v))
	put_u32(out, u32(v >> 32))
}

// Cut to max bytes at a character boundary: a long name is shortened, never refused.
put_string :: proc(out: ^[dynamic]u8, s: string, max: int) {
	n := min(len(s), max, 255)
	for n > 0 && n < len(s) && !utf8.rune_start(s[n]) do n -= 1
	append(out, u8(n))
	append(out, s[:n])
}
