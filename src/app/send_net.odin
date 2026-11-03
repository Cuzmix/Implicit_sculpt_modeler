package main

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../send"

// The threads that move a send's bytes: the listener (a desktop with receive on), which
// takes one connection at a time and receives on it, and the sender, which connects to
// an address and sends one scene. Both speak src/send's frames over blocking sockets
// with a short receive timeout, so a stop (the end of the run, Cancel) is seen within a
// second, and give up on a peer silent for longer than SEND_IDLE.

// A peer that says nothing for this long is gone.
SEND_IDLE :: 30 * time.Second
// How long the receiving side's person has to allow a pairing.
SEND_PAIR_WAIT :: 3 * time.Minute
// How long a send to a desktop by name (--send-to=@NAME) asks the network before it
// says none answered: answers come within a fraction of a second on a quiet network, and
// each second asks again for a packet Wi-Fi lost.
SEND_FIND_WAIT :: 3 * time.Second
@(private = "file")
SEND_TICK :: 1 * time.Second
@(private = "file")
RECV_PIECE :: 256 << 10

// One scene to send, made on the frame loop and owned by the sender thread from then on.
Send_Job :: struct {
	data:       [dynamic]u8,
	token:      u64,
	revision:   u64,
	host:       string,
	hd_dropped: int,
}

// One side of a session on a connected socket.
@(private = "file")
Conn :: struct {
	sock:    net.TCP_Socket,
	sh:      ^Send_Shared,
	buf:     [dynamic]u8, // what came in and is not yet taken
	start:   int,
	plain:   [dynamic]u8, // the last sealed frame's body, opened
	out:     [dynamic]u8,
	session: send.Session,
	sealed:  bool,
	wait:    time.Duration, // the silence allowed before the next frame
	cancel:  bool, // the sender's: whether Cancel stops this session
}

@(private = "file")
conn_init :: proc(c: ^Conn, sock: net.TCP_Socket, sh: ^Send_Shared) {
	c^ = {sock = sock, sh = sh, wait = SEND_IDLE}
	_ = net.set_option(sock, .Receive_Timeout, SEND_TICK)
	when ODIN_OS == .Darwin do _ = net.set_option(sock, .No_SIGPIPE_From_EPIPE, true)
}

@(private = "file")
conn_destroy :: proc(c: ^Conn) {
	net.close(c.sock)
	delete(c.buf)
	delete(c.plain)
	delete(c.out)
	send.session_end(&c.session)
	c^ = {}
}

@(private = "file")
conn_stopped :: proc(c: ^Conn) -> bool {
	return sync.atomic_load(&c.sh.quit) || (c.cancel && sync.atomic_load(&c.sh.cancel))
}

// Sends one frame of kind: sealed once the session is, else in the clear.
@(private = "file")
conn_send :: proc(c: ^Conn, kind: send.Kind, body: []u8) -> bool {
	clear(&c.out)
	if c.sealed {
		if !send.seal_put(&c.out, &c.session, kind, body) do return false
	} else {
		send.frame_put(&c.out, kind, 0, body)
	}
	n, err := net.send_tcp(c.sock, c.out[:])
	return err == nil && n == len(c.out)
}

// Sends a refusal and ends: in the clear, since the other side may hold no key to open it.
@(private = "file")
conn_refuse :: proc(c: ^Conn, why: send.Refusal) {
	body := make([dynamic]u8, context.temp_allocator)
	send.refuse_put(&body, why)
	c.sealed = false
	_ = conn_send(c, .Refuse, body[:])
}

// The next frame's kind and body, opened when sealed; the body lasts until the next call.
// A Refuse may come in the clear at any point; why says what the other side refused.
@(private = "file")
conn_next :: proc(c: ^Conn) -> (kind: send.Kind, body: []u8, why: send.Refusal, ok: bool) {
	silent := time.Duration(0)
	for {
		f, used, status := send.frame_parse(c.buf[c.start:])
		switch status {
		case .Bad:
			return {}, nil, .Damaged, false
		case .Ok:
			c.start += used
			if f.kind == .Refuse && f.flags & send.FLAG_SEALED == 0 {
				r, rok := send.refuse_get(f.body)
				return .Refuse, nil, r if rok else .Damaged, false
			}
			if f.flags & send.FLAG_SEALED != 0 {
				if !c.sealed do return {}, nil, .Damaged, false
				resize(&c.plain, len(f.body))
				opened, ook := send.seal_open(&c.session, f, c.plain[:])
				if !ook do return {}, nil, .Not_Paired, false
				if f.kind == .Refuse {
					r, rok := send.refuse_get(opened)
					return .Refuse, nil, r if rok else .Damaged, false
				}
				return f.kind, opened, .None, true
			}
			if c.sealed do return {}, nil, .Damaged, false
			return f.kind, f.body, .None, true
		case .More:
		}
		// Room for the next piece: what was taken goes, once it is most of the buffer.
		if c.start > 0 && c.start >= len(c.buf) / 2 {
			copy(c.buf[:], c.buf[c.start:])
			resize(&c.buf, len(c.buf) - c.start)
			c.start = 0
		}
		at := len(c.buf)
		resize(&c.buf, at + RECV_PIECE)
		n, err := net.recv_tcp(c.sock, c.buf[at:])
		resize(&c.buf, at + max(n, 0))
		if conn_stopped(c) do return {}, nil, .Cancelled, false
		if err == .Timeout || err == .Would_Block {
			silent += SEND_TICK
			if silent >= c.wait do return {}, nil, .Damaged, false
			continue
		}
		if err != nil || n == 0 do return {}, nil, .Damaged, false
		silent = 0
	}
}

// The hellos, both ways: the connecting side speaks first. Returns the other side's,
// its strings cloned into the temp allocator.
@(private = "file")
conn_hello :: proc(c: ^Conn, me: send.Hello, connecting: bool) -> (theirs: send.Hello, why: send.Refusal, ok: bool) {
	body := make([dynamic]u8, context.temp_allocator)
	send.hello_put(&body, me)
	if connecting && !conn_send(c, .Hello, body[:]) do return {}, .Damaged, false
	kind, got, r, gok := conn_next(c)
	if !gok do return {}, r, false
	if kind != .Hello do return {}, .Damaged, false
	h, hok := send.hello_get(got)
	if !hok do return {}, .Damaged, false
	h.name = strings.clone(h.name, context.temp_allocator)
	h.build = strings.clone(h.build, context.temp_allocator)
	if refusal := send.hello_check(me, h); refusal != .None {
		conn_refuse(c, refusal)
		return h, refusal, false
	}
	if !connecting && !conn_send(c, .Hello, body[:]) do return {}, .Damaged, false
	return h, .None, true
}

@(private = "file")
pair_find :: proc(sh: ^Send_Shared, device: [16]u8) -> (key: send.Key, found: bool) {
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	for p in sh.pairs do if p.device == device do return p.key, true
	return {}, false
}

@(private = "file")
pair_keep :: proc(sh: ^Send_Shared, device: [16]u8, key: send.Key, name: string) {
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	for &p in sh.pairs do if p.device == device {
		p.key = key
		delete(p.name)
		p.name = strings.clone(name)
		send_pairs_save(sh)
		return
	}
	append(&sh.pairs, Send_Pair{device = device, key = key, name = strings.clone(name)})
	send_pairs_save(sh)
}

@(private = "file")
pair_forget :: proc(sh: ^Send_Shared, device: [16]u8) {
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	for p, i in sh.pairs do if p.device == device {
		delete(p.name)
		ordered_remove(&sh.pairs, i)
		send_pairs_save(sh)
		return
	}
}

@(private = "file")
code_text :: proc(code: u32) -> string {return fmt.tprintf("%03d %03d", code / 1000, code % 1000)}

// Pairs as the connecting side: commits, reads the key, opens, and waits for the other
// side's person to allow it.
@(private = "file")
pair_connecting :: proc(c: ^Conn, mine, theirs: send.Hello) -> (key: send.Key, why: send.Refusal, ok: bool) {
	secret := send.pair_begin()
	defer send.pair_wipe(&secret)
	commit := send.pair_commitment(secret.public, secret.nonce)
	if !conn_send(c, .Pair_Commit, commit[:]) do return {}, .Damaged, false
	kind, body, r, gok := conn_next(c)
	if !gok do return {}, r, false
	if kind != .Pair_Key do return {}, .Damaged, false
	public, nonce, kok := send.pair_key_get(body)
	if !kok do return {}, .Damaged, false
	out := make([dynamic]u8, context.temp_allocator)
	send.pair_key_put(&out, secret.public, secret.nonce)
	if !conn_send(c, .Pair_Open, out[:]) do return {}, .Damaged, false
	code: u32
	fok: bool
	key, code, fok = send.pair_finish(secret, public, nonce, true)
	if !fok do return {}, .Damaged, false
	send_event(c.sh, .Note, "", 0, "Pairing with %s: check that it shows %s, and allow it there", theirs.name, code_text(code))
	// The answer is the first frame sealed with the new key.
	c.session = send.session_begin(key, mine.nonce, theirs.nonce, true)
	c.sealed = true
	c.wait = SEND_PAIR_WAIT
	kind, _, r, gok = conn_next(c)
	c.wait = SEND_IDLE
	if !gok do return {}, r, false
	if kind != .Pair_Done do return {}, .Damaged, false
	pair_keep(c.sh, theirs.device, key, theirs.name)
	return key, .None, true
}

// Pairs as the listening side, after the Pair_Commit in body: allowed at once with
// --send-allow, else refused with a note saying so.
@(private = "file")
pair_listening :: proc(c: ^Conn, body: []u8, mine, theirs: send.Hello) -> (why: send.Refusal, ok: bool) {
	commit, cok := send.pair_commit_get(body)
	if !cok do return .Damaged, false
	secret := send.pair_begin()
	defer send.pair_wipe(&secret)
	out := make([dynamic]u8, context.temp_allocator)
	send.pair_key_put(&out, secret.public, secret.nonce)
	if !conn_send(c, .Pair_Key, out[:]) do return .Damaged, false
	kind, opened, r, gok := conn_next(c)
	if !gok do return r, false
	if kind != .Pair_Open do return .Damaged, false
	public, nonce, kok := send.pair_key_get(opened)
	if !kok || send.pair_commitment(public, nonce) != commit do return .Damaged, false
	key, code, fok := send.pair_finish(secret, public, nonce, false)
	if !fok do return .Damaged, false
	if !c.sh.allow {
		send_event(c.sh, .Warning, "", 0, "%s asked to pair (code %s); this build pairs only in a run given --send-allow", theirs.name, code_text(code))
		conn_refuse(c, .Declined)
		return .Declined, false
	}
	send_event(c.sh, .Note, "", 0, "Paired with %s (code %s)", theirs.name, code_text(code))
	c.session = send.session_begin(key, theirs.nonce, mine.nonce, false)
	c.sealed = true
	if !conn_send(c, .Pair_Done, nil) do return .Damaged, false
	pair_keep(c.sh, theirs.device, key, theirs.name)
	return .None, true
}

// The sender thread: connects, pairs if need be, offers the scene and sends the chunks
// the other side asks for.
send_start :: proc(sh: ^Send_Shared, job: ^Send_Job, ctx: runtime.Context) -> ^thread.Thread {
	Start :: struct {
		sh:  ^Send_Shared,
		job: ^Send_Job,
	}
	start := new(Start)
	start^ = {sh, job}
	return thread.create_and_start_with_data(start, proc(data: rawptr) {
		start := cast(^Start)data
		sh, job := start.sh, start.job
		free(start)
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		send_run(sh, job)
		delete(job.data)
		delete(job.host)
		free(job)
		sync.lock(&sh.lock)
		sh.done, sh.total = 0, 0
		sync.unlock(&sh.lock)
	}, ctx, .Normal, name = "send")
}

@(private = "file")
send_run :: proc(sh: ^Send_Shared, job: ^Send_Job) {
	target := job.host if strings.contains_rune(job.host, ':') else fmt.tprintf("%s:%d", job.host, SEND_PORT)
	if strings.has_prefix(job.host, "@") {
		// A desktop found on the local network: by its name, or the first to answer.
		name := job.host[1:]
		found, ok := send_find_run(sh, name, SEND_FIND_WAIT)
		if !ok {
			if sync.atomic_load(&sh.cancel) do return
			called := fmt.tprintf(" called %s", name) if name != "" else ""
			send_event(sh, .Warning, "", 0, "No computer%s answered on this network. Is Sculpt open there with Receive scenes on?", called)
			return
		}
		defer send.found_destroy(&found)
		sync.atomic_add(&sh.found, 1)
		a := found.addresses[0]
		target = fmt.tprintf("%d.%d.%d.%d:%d", a[0], a[1], a[2], a[3], found.port)
		log.infof("send: found %s at %s", found.name, target)
	}
	sock, derr := net.dial_tcp(target)
	if derr != nil {
		send_event(sh, .Warning, "", 0, "Cannot reach %s: %v. Is Sculpt open there with Receive scenes on?", job.host, derr)
		return
	}
	c: Conn
	conn_init(&c, sock, sh)
	c.cancel = true
	defer conn_destroy(&c)
	sync.lock(&sh.lock)
	me := sh.me
	sync.unlock(&sh.lock)
	crypto.rand_bytes(me.nonce[:])
	theirs, why, ok := conn_hello(&c, me, true)
	if !ok {
		send_fail(sh, job.host, why)
		return
	}
	if key, known := pair_find(sh, theirs.device); known {
		c.session = send.session_begin(key, me.nonce, theirs.nonce, true)
		c.sealed = true
	} else if _, why, ok = pair_connecting(&c, me, theirs); !ok {
		send_fail(sh, theirs.name, why)
		return
	}
	chunks := send.chunks_of(job.data[:])
	defer delete(chunks)
	offer := send.offer_make(job.token, job.revision, len(job.data), chunks)
	body := make([dynamic]u8)
	defer delete(body)
	send.offer_put(&body, offer)
	if !conn_send(&c, .Offer, body[:]) {
		send_fail(sh, theirs.name, .Damaged)
		return
	}
	kind, got, r, gok := conn_next(&c)
	if !gok {
		// The listener could not open the offer: it no longer holds this pairing.
		if r == .Not_Paired do pair_forget(sh, theirs.device)
		send_fail(sh, theirs.name, r)
		return
	}
	if kind != .Need {
		send_fail(sh, theirs.name, .Damaged)
		return
	}
	need, nok := send.need_get(got, offer)
	if !nok {
		send_fail(sh, theirs.name, .Damaged)
		return
	}
	defer delete(need)
	total := i64(0)
	for i in need do total += i64(chunks[i].size)
	sync.lock(&sh.lock)
	sh.done, sh.total = 0, max(total, 1)
	sync.unlock(&sh.lock)
	for i in need {
		if conn_stopped(&c) {
			conn_refuse(&c, .Cancelled)
			send_fail(sh, theirs.name, .Cancelled)
			return
		}
		ch := chunks[i]
		clear(&body)
		send.chunk_put(&body, i, job.data[ch.offset:][:ch.size])
		if !conn_send(&c, .Chunk, body[:]) {
			send_fail(sh, theirs.name, .Damaged)
			return
		}
		sync.lock(&sh.lock)
		sh.done += i64(ch.size)
		sync.unlock(&sh.lock)
	}
	kind, _, r, gok = conn_next(&c)
	if !gok || kind != .Received {
		send_fail(sh, theirs.name, r if !gok else .Damaged)
		return
	}
	hd := fmt.tprintf("; the HD detail of %d objects stays here, as with Save", job.hd_dropped) if job.hd_dropped > 0 else ""
	send_event(sh, .Sent, "", send_hash(offer.hash), "Sent the scene to %s: %d MB, %d of %d chunks went over%s", theirs.name, len(job.data) >> 20, len(need), len(chunks), hd)
}

@(private = "file")
send_fail :: proc(sh: ^Send_Shared, who: string, why: send.Refusal) {
	if why == .Cancelled {
		send_event(sh, .Note, "", 0, "The send to %s was cancelled", who)
		return
	}
	send_event(sh, .Warning, "", 0, "Could not send to %s: %s", who, send.REFUSAL_TEXT[why] if why != .None else "the connection ended")
}

// A file's hash as the exit stats give it: its first eight bytes.
@(private = "file")
send_hash :: proc(h: send.Hash) -> (v: u64) {
	for i in 0 ..< 8 do v = v << 8 | u64(h[i])
	return v
}

// The listener thread: accepts a connection, receives on it, and waits for the next.
send_listen_start :: proc(sh: ^Send_Shared, ctx: runtime.Context) -> ^thread.Thread {
	ep := net.Endpoint{address = net.IP4_Any, port = sh.port}
	sock, err := net.listen_tcp(ep, 4)
	if err != nil {
		log.warnf("send: cannot listen on port %d: %v", sh.port, err)
		send_event(sh, .Warning, "", 0, "Cannot receive scenes: port %d is in use or not allowed (%v)", sh.port, err)
		return nil
	}
	sh.listener = sock
	log.infof("send: receiving scenes on port %d", sh.port)
	return thread.create_and_start_with_data(sh, proc(data: rawptr) {
		sh := cast(^Send_Shared)data
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		for !sync.atomic_load(&sh.quit) {
			client, _, aerr := net.accept_tcp(sh.listener)
			if sync.atomic_load(&sh.quit) {
				if aerr == nil do net.close(client)
				break
			}
			if aerr != nil do continue
			receive_run(sh, client)
			runtime.arena_free_all(&arena)
		}
		net.close(sh.listener)
	}, ctx, .Normal, name = "receive")
}

// Wakes a listener waiting in accept by connecting to it, so it sees the quit.
send_listen_wake :: proc(sh: ^Send_Shared) {
	ep := net.Endpoint{address = net.IP4_Loopback, port = sh.port}
	if sock, err := net.dial_tcp(ep); err == nil do net.close(sock)
}

// Where the received copies of a scene from a device go, the base for its next send.
@(private = "file")
received_path :: proc(sh: ^Send_Shared, token: u64, device: [16]u8) -> string {
	name := fmt.tprintf("%016x-%02x%02x%02x%02x.sculpt", token, device[0], device[1], device[2], device[3])
	path, _ := filepath.join({sh.folder, SEND_RECEIVED, name}, context.temp_allocator)
	return path
}

@(private = "file")
receive_run :: proc(sh: ^Send_Shared, sock: net.TCP_Socket) {
	c: Conn
	conn_init(&c, sock, sh)
	defer conn_destroy(&c)
	sync.lock(&sh.lock)
	me := sh.me
	sync.unlock(&sh.lock)
	crypto.rand_bytes(me.nonce[:])
	theirs, why, ok := conn_hello(&c, me, false)
	if !ok {
		if why != .Damaged && why != .Cancelled do send_event(sh, .Warning, "", 0, "Refused a send from %s: %s", theirs.name, send.REFUSAL_TEXT[why])
		return
	}
	key, known := pair_find(sh, theirs.device)
	if known {
		c.session = send.session_begin(key, theirs.nonce, me.nonce, false)
		c.sealed = true
	}
	kind, body, r, gok := conn_next(&c)
	if !gok {
		// A sealed frame this pairing cannot open: the sender holds a key this side forgot.
		if r == .Not_Paired do conn_refuse(&c, .Not_Paired)
		return
	}
	if kind == .Pair_Commit && !c.sealed {
		if _, pok := pair_listening(&c, body, me, theirs); !pok do return
		kind, body, r, gok = conn_next(&c)
		if !gok do return
	} else if !c.sealed {
		conn_refuse(&c, .Not_Paired)
		return
	}
	if kind != .Offer do return
	offer, ook := send.offer_get(body)
	if !ook {
		conn_refuse(&c, .Damaged)
		return
	}
	defer send.offer_destroy(&offer)
	path := received_path(sh, offer.token, theirs.device)
	file, err := receive_file(&c, offer, path)
	if err != "" {
		send_event(sh, .Warning, "", 0, "Could not take the scene %s sent: %s", theirs.name, err)
		return
	}
	if !conn_send(&c, .Received, nil) do log.warn("send: the sender left before hearing the scene arrived")
	send_event(sh, .Received, file, send_hash(offer.hash), "Got a scene from %s: %d MB, %d of %d chunks went over", theirs.name, offer.size >> 20, receive_sent_chunks, len(offer.chunks))
}

// How many chunks the last receive asked for, for its note. Only the listener writes it.
@(private = "file")
receive_sent_chunks: int

// Builds the offered file from the last copy of the same scene from that device (the
// base) and the chunks asked for, into path.partial, then puts it in place.
@(private = "file")
receive_file :: proc(c: ^Conn, offer: send.Offer, path: string) -> (done: string, err: string) {
	base_chunks: []send.Chunk
	defer delete(base_chunks)
	base: ^os.File
	if data, rerr := os.read_entire_file(path, context.allocator); rerr == nil {
		base_chunks = send.chunks_of(data)
		delete(data)
		base, _ = os.open(path)
	}
	defer if base != nil do os.close(base)
	partial := strings.concatenate({path, ".partial"}, context.temp_allocator)
	f, oerr := os.open(partial, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if oerr != nil do return "", fmt.tprintf("cannot write %s: %v", filepath.base(partial), oerr)
	kept := false
	defer if !kept {
		os.close(f)
		_ = os.remove(partial)
	}
	Files :: struct {
		base, new: ^os.File,
	}
	files := Files{base, f}
	read :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
		fs := cast(^Files)user
		if fs.base == nil do return false
		n, e := os.read_at(fs.base, data, i64(offset))
		return e == nil && n == len(data)
	}
	write :: proc(user: rawptr, offset: u64, data: []u8) -> bool {
		fs := cast(^Files)user
		n, e := os.write_at(fs.new, data, i64(offset))
		return e == nil && n == len(data)
	}
	r: send.Rebuild
	if !send.rebuild_init(&r, offer, base_chunks, read, write, &files) do return "", "cannot write the file"
	defer send.rebuild_destroy(&r)
	need := send.rebuild_need(&r)
	defer delete(need)
	receive_sent_chunks = len(need)
	out := make([dynamic]u8, context.temp_allocator)
	send.need_put(&out, need)
	if !conn_send(c, .Need, out[:]) do return "", "the sender left"
	for !send.rebuild_done(&r) {
		kind, body, why, ok := conn_next(c)
		if !ok do return "", send.REFUSAL_TEXT[why] if why != .None else "the sender left"
		if kind != .Chunk do return "", send.REFUSAL_TEXT[.Damaged]
		index, bytes, cok := send.chunk_get(body)
		if !cok do return "", send.REFUSAL_TEXT[.Damaged]
		switch send.rebuild_take(&r, index, bytes) {
		case .Ok:
		case .Damaged:
			conn_refuse(c, .Damaged)
			return "", send.REFUSAL_TEXT[.Damaged]
		case .Failed:
			return "", "the disk is full or the file cannot be written"
		}
	}
	if os.truncate(f, i64(offer.size)) != nil || os.sync(f) != nil do return "", "cannot write the file"
	if base != nil {
		os.close(base)
		base = nil
	}
	os.close(f)
	kept = true
	if e := replace_partial(partial, path); e != "" do return "", e
	return strings.clone(path, context.temp_allocator), ""
}
