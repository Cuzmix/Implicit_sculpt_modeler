package send

import "core:testing"

@(private = "file")
advert :: proc() -> Advert {
	@(static) addresses := [2][4]u8{{192, 168, 1, 20}, {10, 0, 0, 5}}
	return {device = {0 = 0xab, 1 = 0xcd, 15 = 7}, name = "Desk", port = 47820, addresses = addresses[:]}
}

@(test)
a_query_asks_for_the_service :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	query_put(&out, 0x1234)
	asks, id, unicast, question := query_asks(out[:], false, "")
	testing.expect_value(t, len(question), len(out) - 12)
	testing.expect(t, asks)
	testing.expect_value(t, id, 0x1234)
	testing.expect(t, unicast)
	// From 5353 with the unicast bit set, still unicast.
	_, _, unicast, _ = query_asks(out[:], true, "")
	testing.expect(t, unicast)
	// A question for another service asks nothing.
	out[13 + 1] = 'x' // the service's first letter after the label length and underscore
	asks, _, _, _ = query_asks(out[:], false, "")
	testing.expect(t, !asks)
}

@(test)
an_answer_lists_the_desktop_and_its_addresses :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	a := advert()
	answer_put(&out, a, 0x77, true, nil, 36)
	testing.expect(t, len(out) < MDNS_MAX)
	testing.expect_value(t, int(out[0]) << 8 | int(out[1]), 0x77)
	// An answer is not a question.
	asks, _, _, _ := query_asks(out[:], false, "")
	testing.expect(t, !asks)
	found := answer_get(out[:], {192, 168, 1, 99})
	defer {
		for &f in found do found_destroy(&f)
		delete(found)
	}
	testing.expect_value(t, len(found), 1)
	if len(found) != 1 do return
	f := found[0]
	testing.expect_value(t, f.device, a.device)
	testing.expect_value(t, f.name, "Desk")
	testing.expect_value(t, f.port, 47820)
	testing.expect_value(t, f.protocol, PROTOCOL)
	testing.expect_value(t, f.scene, 36)
	// The sender first, then the advert's own addresses.
	testing.expect_value(t, f.count, 3)
	testing.expect_value(t, f.addresses[0], [4]u8{192, 168, 1, 99})
	testing.expect_value(t, f.addresses[1], [4]u8{192, 168, 1, 20})
	testing.expect_value(t, f.addresses[2], [4]u8{10, 0, 0, 5})
}

@(test)
an_answer_with_compressed_names_is_read :: proc(t: ^testing.T) {
	// As Apple's responder writes one: every name after the first points back into it.
	b := make([dynamic]u8)
	defer delete(b)
	append(&b, 0, 0, 0x84, 0, 0, 0, 0, 3, 0, 0, 0, 1)
	service := len(b) // _sculptsend._tcp.local at 12
	append(&b, 11)
	append(&b, "_sculptsend")
	append(&b, 4)
	append(&b, "_tcp")
	local := len(b)
	append(&b, 5)
	append(&b, "local")
	append(&b, 0)
	rr :: proc(b: ^[dynamic]u8, type: u16, data: []u8) {
		append(b, u8(type >> 8), u8(type), 0, 1, 0, 0, 0, 120, u8(len(data) >> 8), u8(len(data)))
		append(b, ..data)
	}
	// PTR: the instance "Mac Studio" under the service.
	instance := len(b) + 10
	rr(&b, TYPE_PTR, {10, 'M', 'a', 'c', ' ', 'S', 't', 'u', 'd', 'i', 'o', 0xc0, u8(service)})
	// SRV of the instance, to host "mac.local".
	append(&b, 0xc0, u8(instance))
	host := len(b) + 10 + 6
	rr(&b, TYPE_SRV, {0, 0, 0, 0, 0xba, 0xcc, 3, 'm', 'a', 'c', 0xc0, u8(local)})
	// TXT of the instance.
	append(&b, 0xc0, u8(instance))
	txt := "\x23id=0102030405060708090a0b0c0d0e0f10\x07proto=1\x0bname=Studio"
	rr(&b, TYPE_TXT, transmute([]u8)txt)
	// A of the host.
	append(&b, 0xc0, u8(host))
	rr(&b, TYPE_A, {192, 168, 0, 4})
	found := answer_get(b[:], {192, 168, 0, 4})
	defer {
		for &f in found do found_destroy(&f)
		delete(found)
	}
	testing.expect_value(t, len(found), 1)
	if len(found) != 1 do return
	testing.expect_value(t, found[0].name, "Studio")
	testing.expect_value(t, found[0].port, 47820)
	testing.expect_value(t, found[0].device[15], 0x10)
	// The A record's address is the sender's, so it is listed once.
	testing.expect_value(t, found[0].count, 1)
}

@(test)
a_damaged_answer_is_refused :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	answer_put(&out, advert(), 1, true, nil, 36)
	// Where the TXT record ends: the same answer with no addresses.
	bare := make([dynamic]u8)
	defer delete(bare)
	no_addresses := advert()
	no_addresses.addresses = nil
	answer_put(&bare, no_addresses, 1, true, nil, 36)
	// A cut never reads past its end: before the TXT record is whole it lists nothing,
	// and after it (only addresses missing) the desktop as it is.
	for n in 0 ..< len(out) {
		found := answer_get(out[:n], {1, 2, 3, 4})
		for f in found do testing.expect(t, f.device == advert().device && f.port == 47820 && f.addresses[0] == {1, 2, 3, 4})
		testing.expect(t, len(found) == 0 || n >= len(bare))
		for &f in found do found_destroy(&f)
		delete(found)
		_, _, _, _ = query_asks(out[:n], false, "")
	}
	// A name pointing at itself or forward is refused rather than followed for ever.
	loop := [?]u8{0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 12, 0, 12, 0, 1}
	asks, _, _, _ := query_asks(loop[:], false, "")
	testing.expect(t, !asks)
	forward := [?]u8{0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 14, 0, 0, 0, 12, 0, 1}
	asks, _, _, _ = query_asks(forward[:], false, "")
	testing.expect(t, !asks)
}

@(test)
a_question_for_the_host_is_answered_with_the_question_echoed :: proc(t: ^testing.T) {
	a := advert()
	host := host_name(a.device)
	q := make([dynamic]u8)
	defer delete(q)
	append(&q, 0, 9, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
	// "SCULPT-abcd0000.local" in capitals too: names compare without case.
	append(&q, 15)
	for c in transmute([]u8)host[:15] do append(&q, c - 32 if c >= 'a' && c <= 'z' else c)
	append(&q, 5)
	append(&q, "local")
	append(&q, 0, 0, u8(TYPE_A), 0, 1)
	asks, id, unicast, question := query_asks(q[:], false, host)
	testing.expect(t, asks && unicast)
	testing.expect_value(t, id, 9)
	testing.expect_value(t, len(question), len(q) - 12)
	out := make([dynamic]u8)
	defer delete(out)
	answer_put(&out, a, id, true, question, 36)
	// One question echoed, and the answer still reads.
	testing.expect_value(t, int(out[4]) << 8 | int(out[5]), 1)
	found := answer_get(out[:], {10, 0, 0, 1})
	defer {
		for &f in found do found_destroy(&f)
		delete(found)
	}
	testing.expect_value(t, len(found), 1)
	// Another host's name asks nothing.
	asks, _, _, _ = query_asks(q[:], false, "sculpt-00000000.local")
	testing.expect(t, !asks)
}
