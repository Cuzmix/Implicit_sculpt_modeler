package send

import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"

// Pairing makes a key two devices share for good, with a person at each confirming that
// the six digits on both screens match, as Bluetooth's numeric comparison does. The keys
// are agreed by X25519; the tablet commits to its key before it sees the desktop's, so
// someone in between cannot try keys until the digits happen to match: one guess in a
// million, each a failed pairing someone sees.
//
//     tablet                                desktop
//     Pair_Commit  hash(public, nonce)  ->
//                                       <-  Pair_Key   public, nonce
//     Pair_Open    public, nonce        ->  checks the commitment
//     both show the code; the desktop's person presses Allow
//                                       <-  Pair_Done
//
// The code and the key come from the same exchange, so equal codes mean equal keys.

KEY_SIZE :: 32

Key :: [KEY_SIZE]u8

// One side's part of a pairing, kept until it ends and then wiped.
Pair_Secret :: struct {
	private: [32]u8,
	public:  [32]u8,
	nonce:   [32]u8,
}

// A fresh pairing secret from the system's random source.
pair_begin :: proc() -> (s: Pair_Secret) {
	crypto.rand_bytes(s.private[:])
	crypto.rand_bytes(s.nonce[:])
	x25519.scalarmult_basepoint(s.public[:], s.private[:])
	return s
}

pair_wipe :: proc(s: ^Pair_Secret) {crypto.zero_explicit(s, size_of(s^))}

// What the tablet commits to first.
pair_commitment :: proc(public, nonce: [32]u8) -> Hash {
	ctx: blake2b.Context
	blake2b.init(&ctx, HASH_SIZE)
	tag := "sculpt send commit"
	blake2b.update(&ctx, transmute([]u8)tag)
	public, nonce := public, nonce
	blake2b.update(&ctx, public[:])
	blake2b.update(&ctx, nonce[:])
	h: Hash
	blake2b.final(&ctx, h[:])
	return h
}

pair_key_put :: proc(out: ^[dynamic]u8, public, nonce: [32]u8) {
	public, nonce := public, nonce
	append(out, ..public[:])
	append(out, ..nonce[:])
}

// A Pair_Key or Pair_Open body: a public key and a nonce.
@(require_results)
pair_key_get :: proc(body: []u8) -> (public, nonce: [32]u8, ok: bool) {
	r := reader(body)
	get_bytes(&r, public[:])
	get_bytes(&r, nonce[:])
	return public, nonce, reader_done(&r)
}

@(require_results)
pair_commit_get :: proc(body: []u8) -> (commit: Hash, ok: bool) {
	r := reader(body)
	get_bytes(&r, commit[:])
	return commit, reader_done(&r)
}

// The pairing's key and the six digits both screens show, from this side's secret and
// the other side's public key and nonce. tablet says which side this is, so both order
// the exchange alike. Not ok when the other side's key is one that makes every secret the
// same (a low-order point), which no honest device sends.
@(require_results)
pair_finish :: proc(mine: Pair_Secret, their_public, their_nonce: [32]u8, tablet: bool) -> (key: Key, code: u32, ok: bool) {
	mine, their_public := mine, their_public
	shared: [32]u8
	x25519.scalarmult(shared[:], mine.private[:], their_public[:])
	defer crypto.zero_explicit(&shared, size_of(shared))
	if crypto.is_zero_constant_time(shared[:]) == 1 do return {}, 0, false
	// The transcript, tablet's part first: both keys and both nonces.
	transcript: [128]u8
	t_public, t_nonce, d_public, d_nonce := mine.public, mine.nonce, their_public, their_nonce
	if !tablet do t_public, t_nonce, d_public, d_nonce = their_public, their_nonce, mine.public, mine.nonce
	copy(transcript[0:], t_public[:])
	copy(transcript[32:], t_nonce[:])
	copy(transcript[64:], d_public[:])
	copy(transcript[96:], d_nonce[:])
	derived: [KEY_SIZE + 8]u8
	info := "sculpt send pairing"
	hkdf.extract_and_expand(hash.Algorithm.SHA256, transcript[:], shared[:], transmute([]u8)info, derived[:])
	copy(key[:], derived[:KEY_SIZE])
	digits := u64(0)
	for i in 0 ..< 8 do digits = digits << 8 | u64(derived[KEY_SIZE + i])
	crypto.zero_explicit(&derived, size_of(derived))
	return key, u32(digits % 1_000_000), true
}
