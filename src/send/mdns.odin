package send

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Finding a computer to send to, by DNS-SD over multicast DNS (RFC 6762, 6763) as
// Bonjour does: a desktop that receives answers for the service SERVICE with its name,
// port and id, and a tablet asks and lists who answered. These are the messages only; the
// app's platform files move them, or leave it to the system's own responder where there
// is one (Apple's dns_sd).
//
// The asking side sends a "legacy unicast" query, from a port of its own rather than
// 5353: every responder answers it straight to that port (RFC 6762 6.7), so the asker
// never listens on the multicast group, which on Android needs a multicast lock and on
// the iPad an entitlement. The answer's sender is the address to connect to.

MDNS_PORT :: 5353
MDNS_GROUP :: [4]u8{224, 0, 0, 251}
SERVICE :: "_sculptsend._tcp.local"
// What a browser for every service type asks (RFC 6763 9).
SERVICES_ALL :: "_services._dns-sd._udp.local"
// A DNS message over UDP is at most this big here: every answer of ours fits in one
// Ethernet frame, and a bigger packet is not one of ours.
MDNS_MAX :: 1500
// How many addresses one answer lists at most; more are left out.
ADDRESSES_MAX :: 8

TYPE_A :: u16(1)
TYPE_PTR :: u16(12)
TYPE_TXT :: u16(16)
TYPE_SRV :: u16(33)
TYPE_ANY :: u16(255)
CLASS_IN :: u16(1)
// In a question, ask for the answer by unicast; in an answer, the record replaces what
// a cache holds for that name (RFC 6762 5.4, 10.2).
CLASS_TOP :: u16(0x8000)

// One desktop that answered: who it is, and where it listens. The strings are owned.
Found :: struct {
	device:    [16]u8,
	name:      string,
	protocol:  u16,
	scene:     u32,
	port:      u16,
	addresses: [ADDRESSES_MAX][4]u8,
	count:     int, // addresses used
}

found_destroy :: proc(f: ^Found, allocator := context.allocator) {
	delete(f.name, allocator)
	f^ = {}
}

// What a responder says about itself.
Advert :: struct {
	device:    [16]u8,
	name:      string, // the person-facing name, as the hello's
	port:      u16,
	addresses: [][4]u8, // this machine's IPv4 addresses, best first
}

@(private = "file")
put_u16be :: proc(out: ^[dynamic]u8, v: u16) {append(out, u8(v >> 8), u8(v))}

@(private = "file")
put_u32be :: proc(out: ^[dynamic]u8, v: u32) {append(out, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

// Writes a dotted name as labels, uncompressed, after the one label first when given
// (an instance's, which may hold dots of its own). A label longer than 63 bytes is cut at
// a character boundary; every name here is ours, so none is longer than 255 bytes.
@(private = "file")
put_name :: proc(out: ^[dynamic]u8, name: string, first := "") {
	label :: proc(out: ^[dynamic]u8, p: string) {
		n := min(len(p), 63)
		for n > 0 && n < len(p) && !utf8.rune_start(p[n]) do n -= 1
		if n == 0 do return
		append(out, u8(n))
		append(out, p[:n])
	}
	if first != "" do label(out, first)
	rest := name
	for p in strings.split_iterator(&rest, ".") do label(out, p)
	append(out, 0)
}

// A question for SERVICE's PTR records. id is echoed by a legacy unicast answer.
query_put :: proc(out: ^[dynamic]u8, id: u16) {
	put_u16be(out, id)
	put_u16be(out, 0) // a standard query
	put_u16be(out, 1) // one question
	put_u16be(out, 0)
	put_u16be(out, 0)
	put_u16be(out, 0)
	put_name(out, SERVICE)
	put_u16be(out, TYPE_PTR)
	put_u16be(out, CLASS_IN | CLASS_TOP)
}

// The instance label an advert's name gets: its name and the id's first two bytes, so
// two computers of the same name are still two instances.
instance_label :: proc(a: Advert, allocator := context.temp_allocator) -> string {
	name := a.name if a.name != "" else "Sculpt"
	if len(name) > 56 {
		n := 56
		for n > 0 && !utf8.rune_start(name[n]) do n -= 1
		name = name[:n]
	}
	return strings.clone(strings.concatenate({name, " (", hex4(a.device), ")"}, context.temp_allocator), allocator)
}

@(private = "file")
hex4 :: proc(id: [16]u8) -> string {
	digits := "0123456789abcdef"
	b := make([]u8, 4, context.temp_allocator)
	b[0], b[1], b[2], b[3] = digits[id[0] >> 4], digits[id[0] & 15], digits[id[1] >> 4], digits[id[1] & 15]
	return string(b)
}

@(private = "file")
id_hex :: proc(id: [16]u8) -> string {
	digits := "0123456789abcdef"
	b := make([]u8, 32, context.temp_allocator)
	for v, i in id do b[2 * i], b[2 * i + 1] = digits[v >> 4], digits[v & 15]
	return string(b)
}

// The host name an advert's addresses go under: its own, never the machine's, which
// the system's responder may hold already.
host_name :: proc(id: [16]u8) -> string {
	return strings.concatenate({"sculpt-", id_hex(id)[:8], ".local"}, context.temp_allocator)
}

// The answer to a question for SERVICE or for the advert's host: PTR, SRV, TXT and the
// addresses, all of them whichever was asked, as a responder may. legacy is a question
// from a port other than 5353, answered by unicast with its id and question (as
// query_asks gave it) echoed and short lifetimes (RFC 6762 6.7); otherwise id is 0 and
// nothing is echoed.
answer_put :: proc(out: ^[dynamic]u8, a: Advert, id: u16, legacy: bool, question: []u8, scene_version: u32) {
	instance := instance_label(a)
	host := host_name(a.device)
	ttl_name := u32(10) if legacy else 4500
	ttl_host := u32(10) if legacy else 120
	unique := CLASS_IN if legacy else CLASS_IN | CLASS_TOP
	count := min(len(a.addresses), ADDRESSES_MAX)
	put_u16be(out, id if legacy else 0)
	put_u16be(out, 0x8400) // a response, authoritative
	echo := legacy && len(question) > 0
	put_u16be(out, 1 if echo else 0)
	put_u16be(out, 3)
	put_u16be(out, 0)
	put_u16be(out, u16(count))
	if echo do append(out, ..question)
	record :: proc(out: ^[dynamic]u8, type, class: u16, ttl: u32) -> int {
		put_u16be(out, type)
		put_u16be(out, class)
		put_u32be(out, ttl)
		put_u16be(out, 0)
		return len(out)
	}
	finish :: proc(out: ^[dynamic]u8, at: int) {
		n := len(out) - at
		out[at - 2], out[at - 1] = u8(n >> 8), u8(n)
	}
	put_name(out, SERVICE)
	at := record(out, TYPE_PTR, CLASS_IN, ttl_name)
	put_name(out, SERVICE, instance)
	finish(out, at)
	put_name(out, SERVICE, instance)
	at = record(out, TYPE_SRV, unique, ttl_host)
	put_u16be(out, 0)
	put_u16be(out, 0)
	put_u16be(out, a.port)
	put_name(out, host)
	finish(out, at)
	put_name(out, SERVICE, instance)
	at = record(out, TYPE_TXT, unique, ttl_name)
	txt_put(out, a, scene_version)
	finish(out, at)
	for addr in a.addresses[:count] {
		put_name(out, host)
		at = record(out, TYPE_A, unique, ttl_host)
		addr := addr
		append(out, ..addr[:])
		finish(out, at)
	}
}

// The TXT record's strings, each a length byte and key=value (RFC 6763 6): the id, the
// protocol, the scene version and the name. Apple's DNSServiceRegister takes the same bytes.
txt_put :: proc(out: ^[dynamic]u8, a: Advert, scene_version: u32) {
	txt := [?]string {
		strings.concatenate({"id=", id_hex(a.device)}, context.temp_allocator),
		strings.concatenate({"proto=", uint_text(u64(PROTOCOL))}, context.temp_allocator),
		strings.concatenate({"scene=", uint_text(u64(scene_version))}, context.temp_allocator),
		strings.concatenate({"name=", a.name}, context.temp_allocator),
	}
	for t in txt {
		n := min(len(t), 255)
		for n > 0 && n < len(t) && !utf8.rune_start(t[n]) do n -= 1
		append(out, u8(n))
		append(out, t[:n])
	}
}

// Reads a TXT record's strings into f: its id, protocol, scene version and name (not
// owned: it points into txt). False without a valid id, which every answer of ours has.
@(require_results)
txt_get :: proc(txt: []u8, f: ^Found) -> bool {
	has_id := false
	for i := 0; i < len(txt); {
		n := int(txt[i])
		if i + 1 + n > len(txt) do break
		entry := string(txt[i + 1:][:n])
		i += 1 + n
		eq := strings.index_byte(entry, '=')
		if eq < 0 do continue
		key, value := entry[:eq], entry[eq + 1:]
		switch key {
		case "id":
			has_id = hex_id(value, &f.device)
		case "proto":
			v, ok := strconv.parse_u64_of_base(value, 10)
			if ok && v <= u64(max(u16)) do f.protocol = u16(v)
		case "scene":
			v, ok := strconv.parse_u64_of_base(value, 10)
			if ok && v <= u64(max(u32)) do f.scene = u32(v)
		case "name":
			if utf8.valid_string(value) && clean(value) do f.name = value
		}
	}
	return has_id
}

@(private = "file")
uint_text :: proc(v: u64) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_uint(buf, v, 10)
}

// A DNS message being read: every read is bounds-checked, and a short or damaged one
// leaves ok false.
@(private = "file")
Msg :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

@(private = "file")
msg_u16 :: proc(m: ^Msg) -> u16 {
	if !m.ok || m.at + 2 > len(m.data) {
		m.ok = false
		return 0
	}
	v := u16(m.data[m.at]) << 8 | u16(m.data[m.at + 1])
	m.at += 2
	return v
}

@(private = "file")
msg_u32 :: proc(m: ^Msg) -> u32 {
	hi := msg_u16(m)
	return u32(hi) << 16 | u32(msg_u16(m))
}

// Reads a name at m.at, following compression pointers, as lowercase dotted text in the
// temp allocator. A pointer must point before the label it replaces, so a name cannot
// loop; a name over 255 bytes is damaged.
@(private = "file")
msg_name :: proc(m: ^Msg) -> string {
	if !m.ok do return ""
	b := strings.builder_make(context.temp_allocator)
	at := m.at
	jumped := false
	for {
		if at >= len(m.data) {
			m.ok = false
			return ""
		}
		n := int(m.data[at])
		if n == 0 {
			at += 1
			break
		}
		if n & 0xc0 == 0xc0 {
			if at + 1 >= len(m.data) {
				m.ok = false
				return ""
			}
			to := (n & 0x3f) << 8 | int(m.data[at + 1])
			if to >= at {
				m.ok = false
				return ""
			}
			if !jumped do m.at = at + 2
			jumped = true
			at = to
			continue
		}
		if n > 63 || at + 1 + n > len(m.data) {
			m.ok = false
			return ""
		}
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '.')
		for c in m.data[at + 1:][:n] do strings.write_byte(&b, c + 32 if c >= 'A' && c <= 'Z' else c)
		if strings.builder_len(b) > 255 {
			m.ok = false
			return ""
		}
		at += 1 + n
	}
	if !jumped do m.at = at
	return strings.to_string(b)
}

// Whether packet asks for SERVICE (or for every service type) or for host's address, and
// its id, whether the answer goes by unicast (asked so, or a legacy question; from_5353
// is false for one sent from another port), and the question's bytes to echo in a legacy
// answer (nil when it used compression, which an echo cannot carry). Answers and damaged
// packets ask nothing.
@(require_results)
query_asks :: proc(packet: []u8, from_5353: bool, host: string) -> (asks: bool, id: u16, unicast: bool, question: []u8) {
	if len(packet) > MDNS_MAX do return
	m := Msg{packet, 0, true}
	id = msg_u16(&m)
	flags := msg_u16(&m)
	questions := msg_u16(&m)
	m.at += 6
	if !m.ok || flags & 0x8000 != 0 || flags & 0x7800 != 0 do return false, 0, false, nil
	for _ in 0 ..< questions {
		start := m.at
		name := msg_name(&m)
		type := msg_u16(&m)
		class := msg_u16(&m)
		if !m.ok do return false, 0, false, nil
		if class & 0x7fff != CLASS_IN && class & 0x7fff != 255 do continue
		service := (type == TYPE_PTR || type == TYPE_ANY) && (name == SERVICE || name == SERVICES_ALL)
		address := (type == TYPE_A || type == TYPE_ANY) && host != "" && name == strings.to_lower(host, context.temp_allocator)
		if !service && !address do continue
		if !asks {
			question = packet[start:m.at]
			for i := start; i < m.at - 4; {
				n := int(packet[i])
				if n == 0 do break
				if n & 0xc0 != 0 {
					question = nil
					break
				}
				i += 1 + n
			}
		}
		asks = true
		unicast = unicast || class & CLASS_TOP != 0
	}
	if !asks do return false, 0, false, nil
	// The echoed question loses its unicast bit, as an answer's question should.
	return true, id, unicast || !from_5353, question
}

// The desktops packet tells of, from its answers and additional records: each instance
// of SERVICE whose SRV and TXT it carries, with the addresses of its host. from is the
// address it came from, listed first since it is the one that answered. Damaged packets
// and records are left out, never asserted on.
@(require_results)
answer_get :: proc(packet: []u8, from: [4]u8, allocator := context.allocator) -> []Found {
	if len(packet) > MDNS_MAX do return nil
	m := Msg{packet, 0, true}
	_ = msg_u16(&m)
	flags := msg_u16(&m)
	questions := int(msg_u16(&m))
	answers := int(msg_u16(&m))
	authority := int(msg_u16(&m))
	additional := int(msg_u16(&m))
	if !m.ok || flags & 0x8000 == 0 do return nil
	for _ in 0 ..< questions {
		_ = msg_name(&m)
		m.at += 4
	}
	Srv :: struct {
		port: u16,
		host: string,
	}
	instances := make([dynamic]string, context.temp_allocator)
	srvs := make(map[string]Srv, context.temp_allocator)
	txts := make(map[string][]u8, context.temp_allocator)
	hosts := make([dynamic]struct {
			name: string,
			addr: [4]u8,
		}, context.temp_allocator)
	suffix := "." + SERVICE
	for _ in 0 ..< answers + authority + additional {
		name := msg_name(&m)
		type := msg_u16(&m)
		_ = msg_u16(&m)
		_ = msg_u32(&m)
		size := int(msg_u16(&m))
		if !m.ok || m.at + size > len(m.data) do break
		end := m.at + size
		data := Msg{m.data[:end], m.at, true}
		switch type {
		case TYPE_PTR:
			if name == SERVICE {
				target := msg_name(&data)
				if data.ok && strings.has_suffix(target, suffix) do append(&instances, target)
			}
		case TYPE_SRV:
			_ = msg_u16(&data)
			_ = msg_u16(&data)
			port := msg_u16(&data)
			host := msg_name(&data)
			if data.ok do srvs[name] = {port, host}
		case TYPE_TXT:
			txts[name] = m.data[m.at:end]
		case TYPE_A:
			if size == 4 do append(&hosts, struct {
					name: string,
					addr: [4]u8,
				}{name, {m.data[m.at], m.data[m.at + 1], m.data[m.at + 2], m.data[m.at + 3]}})
		}
		m.at = end
	}
	out := make([dynamic]Found, allocator)
	seen: for inst in instances {
		srv, has_srv := srvs[inst]
		txt, has_txt := txts[inst]
		if !has_srv || !has_txt || srv.port == 0 do continue
		f: Found
		f.port = srv.port
		has_id := txt_get(txt, &f)
		if !has_id do continue
		for o in out do if o.device == f.device do continue seen
		f.addresses[0] = from
		f.count = 1
		for h in hosts {
			if h.name != srv.host || h.addr == from || f.count == ADDRESSES_MAX do continue
			f.addresses[f.count] = h.addr
			f.count += 1
		}
		f.name = strings.clone(f.name, allocator)
		append(&out, f)
	}
	return out[:]
}

@(private = "file")
clean :: proc(s: string) -> bool {
	for c in s do if c < 0x20 || c == 0x7f do return false
	return true
}

@(private = "file")
hex_id :: proc(s: string, id: ^[16]u8) -> bool {
	if len(s) != 32 do return false
	for i in 0 ..< 16 {
		v, ok := strconv.parse_u64_of_base(s[2 * i:][:2], 16)
		if !ok do return false
		id[i] = u8(v)
	}
	return true
}
