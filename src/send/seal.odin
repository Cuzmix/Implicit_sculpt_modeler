package send

import "core:crypto"
import "core:crypto/chacha20"
import "core:crypto/chacha20poly1305"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:encoding/endian"

// After the hellos every frame is sealed with ChaCha20-Poly1305 under a key for its
// direction, made for this session from the pairing's key and both hellos' nonces: a
// recorded session cannot be played back into a later one, and a frame cannot be moved
// from one direction to the other. The header goes in as associated data, so its kind
// and length are covered too; its sequence number is the nonce, and the receiver takes
// only the next one, so no frame can be dropped, repeated or reordered unnoticed.

TAG_SIZE :: chacha20poly1305.TAG_SIZE

// ChaCha20's 128-bit SIMD code, on every build: the pinned compiler's 256-bit code, the
// default, gives a wrong keystream after the first block in an unoptimised build where
// the machine has no AVX2 (the debug app on a plain x86-64 target), so a debug build and
// a release build would not understand each other. The 128-bit code is SSE2 or NEON,
// right at every optimisation, and far faster than any network (chacha_matches_rfc).
CHACHA_IMPL :: chacha20.Implementation.Simd128

Session :: struct {
	send_key: Key,
	recv_key: Key,
	send_seq: u32,
	recv_seq: u32,
}

// The keys of a session between the tablet whose hello carried tablet_nonce and the
// desktop whose hello carried desktop_nonce; tablet says which side this is.
session_begin :: proc(pair_key: Key, tablet_nonce, desktop_nonce: [32]u8, tablet: bool) -> (s: Session) {
	pair_key, tablet_nonce, desktop_nonce := pair_key, tablet_nonce, desktop_nonce
	salt: [64]u8
	copy(salt[0:], tablet_nonce[:])
	copy(salt[32:], desktop_nonce[:])
	keys: [2 * KEY_SIZE]u8
	info := "sculpt send session"
	hkdf.extract_and_expand(hash.Algorithm.SHA256, salt[:], pair_key[:], transmute([]u8)info, keys[:])
	to_desktop, to_tablet := keys[:KEY_SIZE], keys[KEY_SIZE:]
	copy(s.send_key[:], to_desktop if tablet else to_tablet)
	copy(s.recv_key[:], to_tablet if tablet else to_desktop)
	crypto.zero_explicit(&keys, size_of(keys))
	return s
}

session_end :: proc(s: ^Session) {crypto.zero_explicit(s, size_of(s^))}

// The header a sealed frame of this kind, sequence and body length carries: what both
// sides feed in as associated data.
@(private = "file")
sealed_header :: proc(kind: Kind, seq: u32, size: int) -> (h: [HEADER_SIZE]u8) {
	magic := MAGIC
	copy(h[:], magic[:])
	h[4] = u8(kind)
	h[5] = FLAG_SEALED
	endian.unchecked_put_u32le(h[8:], seq)
	endian.unchecked_put_u32le(h[12:], u32(size))
	return h
}

@(private = "file")
seal_iv :: proc(seq: u32) -> (iv: [chacha20poly1305.IV_SIZE]u8) {
	endian.unchecked_put_u32le(iv[:], seq)
	return iv
}

// Appends body as a sealed frame of kind. False when the session has sent as many frames
// as a sequence number counts, which no send comes near (4 billion chunks): it must end.
@(require_results)
seal_put :: proc(out: ^[dynamic]u8, s: ^Session, kind: Kind, body: []u8) -> bool {
	if s.send_seq == max(u32) do return false
	size := len(body) + TAG_SIZE
	if size > BODY_MAX do return false
	header := sealed_header(kind, s.send_seq, size)
	iv := seal_iv(s.send_seq)
	at := len(out)
	append(out, ..header[:])
	resize(out, at + HEADER_SIZE + size)
	text := out[at + HEADER_SIZE:][:len(body)]
	tag := out[at + HEADER_SIZE + len(body):][:TAG_SIZE]
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, s.send_key[:], CHACHA_IMPL)
	chacha20poly1305.seal(&ctx, text, tag, iv[:], header[:], body)
	chacha20poly1305.reset(&ctx)
	s.send_seq += 1
	return true
}

// The body of a sealed frame, opened into dst (at least the body's length less
// TAG_SIZE). Not ok for a frame that is not sealed, not the next in sequence, or not
// sealed with this session's key: the session ends.
@(require_results)
seal_open :: proc(s: ^Session, f: Frame, dst: []u8) -> (body: []u8, ok: bool) {
	if f.flags & FLAG_SEALED == 0 || f.seq != s.recv_seq || len(f.body) < TAG_SIZE do return nil, false
	n := len(f.body) - TAG_SIZE
	if len(dst) < n do return nil, false
	header := sealed_header(f.kind, f.seq, len(f.body))
	iv := seal_iv(f.seq)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, s.recv_key[:], CHACHA_IMPL)
	opened := chacha20poly1305.open(&ctx, dst[:n], iv[:], header[:], f.body[:n], f.body[n:])
	chacha20poly1305.reset(&ctx)
	if !opened do return nil, false
	s.recv_seq += 1
	return dst[:n], true
}
