package send

import "core:testing"

// A whole pairing as the two devices run it, over the frames' bodies: the key and code
// each side ends with.
@(private = "file")
pair_both :: proc(t: ^testing.T, loc := #caller_location) -> (tablet_key, desktop_key: Key, tablet_code, desktop_code: u32) {
	tablet, desktop := pair_begin(), pair_begin()
	defer pair_wipe(&tablet)
	defer pair_wipe(&desktop)
	out := make([dynamic]u8)
	defer delete(out)
	// The tablet commits.
	commitment := pair_commitment(tablet.public, tablet.nonce)
	append(&out, ..commitment[:])
	commit, ok := pair_commit_get(out[:])
	testing.expect(t, ok, loc = loc)
	// The desktop answers with its key.
	clear(&out)
	pair_key_put(&out, desktop.public, desktop.nonce)
	d_public, d_nonce, ok2 := pair_key_get(out[:])
	testing.expect(t, ok2, loc = loc)
	// The tablet opens its commitment, which the desktop checks.
	clear(&out)
	pair_key_put(&out, tablet.public, tablet.nonce)
	t_public, t_nonce, ok3 := pair_key_get(out[:])
	testing.expect(t, ok3, loc = loc)
	testing.expect_value(t, pair_commitment(t_public, t_nonce), commit, loc = loc)
	ok4, ok5: bool
	tablet_key, tablet_code, ok4 = pair_finish(tablet, d_public, d_nonce, true)
	desktop_key, desktop_code, ok5 = pair_finish(desktop, t_public, t_nonce, false)
	testing.expect(t, ok4 && ok5, loc = loc)
	return
}

@(test)
both_sides_of_a_pairing_end_with_the_same_key_and_code :: proc(t: ^testing.T) {
	a, b, code_a, code_b := pair_both(t)
	testing.expect_value(t, a, b)
	testing.expect_value(t, code_a, code_b)
	testing.expect(t, code_a < 1_000_000)
	// A second pairing of the same two devices makes another key.
	c, _, _, _ := pair_both(t)
	testing.expect(t, c != a)
}

@(test)
someone_in_between_shows_different_codes :: proc(t: ^testing.T) {
	// The tablet pairs with an impostor, and the impostor with the desktop: each pair
	// agrees on a key, but the codes the two real screens show differ.
	tablet, desktop, impostor := pair_begin(), pair_begin(), pair_begin()
	_, tablet_code, _ := pair_finish(tablet, impostor.public, impostor.nonce, true)
	_, desktop_code, _ := pair_finish(desktop, impostor.public, impostor.nonce, false)
	testing.expect(t, tablet_code != desktop_code)
}

@(test)
a_commitment_binds_the_key_and_nonce :: proc(t: ^testing.T) {
	s := pair_begin()
	other := pair_begin()
	c := pair_commitment(s.public, s.nonce)
	testing.expect(t, pair_commitment(other.public, s.nonce) != c)
	testing.expect(t, pair_commitment(s.public, other.nonce) != c)
}

@(test)
a_key_that_makes_every_secret_alike_is_refused :: proc(t: ^testing.T) {
	s := pair_begin()
	_, _, ok := pair_finish(s, {}, {}, true)
	testing.expect(t, !ok)
}

@(private = "file")
sessions :: proc() -> (tablet, desktop: Session) {
	key: Key = {0 = 1, 1 = 2, 2 = 3}
	tn: [32]u8 = {0 = 7}
	dn: [32]u8 = {0 = 9}
	return session_begin(key, tn, dn, true), session_begin(key, tn, dn, false)
}

@(test)
a_sealed_frame_opens_on_the_other_side :: proc(t: ^testing.T) {
	tablet, desktop := sessions()
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("first")))
	testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("second")))
	dst: [64]u8
	f, used, status := frame_parse(out[:])
	testing.expect_value(t, status, Parse.Ok)
	body, ok := seal_open(&desktop, f, dst[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(body), "first")
	g, _, _ := frame_parse(out[used:])
	body, ok = seal_open(&desktop, g, dst[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(body), "second")
	// The plain text is not on the wire.
	testing.expect(t, string(out[HEADER_SIZE:][:5]) != "first")
	// And back the other way, under its own key.
	clear(&out)
	testing.expect(t, seal_put(&out, &desktop, .Received, nil))
	h, _, _ := frame_parse(out[:])
	_, ok = seal_open(&tablet, h, dst[:])
	testing.expect(t, ok)
}

@(test)
a_changed_repeated_or_reordered_frame_is_refused :: proc(t: ^testing.T) {
	dst: [64]u8
	out := make([dynamic]u8)
	defer delete(out)
	{
		tablet, desktop := sessions()
		testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("chunk")))
		out[HEADER_SIZE + 1] ~= 1
		f, _, _ := frame_parse(out[:])
		_, ok := seal_open(&desktop, f, dst[:])
		testing.expect(t, !ok)
	}
	{
		tablet, desktop := sessions()
		clear(&out)
		testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("chunk")))
		// The same bytes under another kind: the header is sealed too.
		out[4] = u8(Kind.Offer)
		f, _, _ := frame_parse(out[:])
		_, ok := seal_open(&desktop, f, dst[:])
		testing.expect(t, !ok)
	}
	{
		tablet, desktop := sessions()
		clear(&out)
		testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("one")))
		testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("two")))
		f, used, _ := frame_parse(out[:])
		g, _, _ := frame_parse(out[used:])
		// The second before the first, then the first twice.
		_, ok := seal_open(&desktop, g, dst[:])
		testing.expect(t, !ok)
		_, ok = seal_open(&desktop, f, dst[:])
		testing.expect(t, ok)
		_, ok = seal_open(&desktop, f, dst[:])
		testing.expect(t, !ok)
	}
}

@(test)
a_frame_from_another_session_or_direction_is_refused :: proc(t: ^testing.T) {
	dst: [64]u8
	out := make([dynamic]u8)
	defer delete(out)
	tablet, _ := sessions()
	testing.expect(t, seal_put(&out, &tablet, .Chunk, transmute([]u8)string("chunk")))
	f, _, _ := frame_parse(out[:])
	// The tablet's own frame sent back at it.
	mirror, _ := sessions()
	_, ok := seal_open(&mirror, f, dst[:])
	testing.expect(t, !ok)
	// A desktop whose session began with other nonces: a recording played into a later
	// session.
	key: Key = {0 = 1, 1 = 2, 2 = 3}
	later := session_begin(key, {0 = 7}, {0 = 10}, false)
	_, ok = seal_open(&later, f, dst[:])
	testing.expect(t, !ok)
	// A frame sent in the clear where a sealed one belongs.
	clear(&out)
	frame_put(&out, .Chunk, 0, make([]u8, 32, context.temp_allocator))
	g, _, _ := frame_parse(out[:])
	_, desktop := sessions()
	_, ok = seal_open(&desktop, g, dst[:])
	testing.expect(t, !ok)
}
