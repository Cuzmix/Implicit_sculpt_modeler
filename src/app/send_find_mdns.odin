#+build linux, windows
package main

import "base:runtime"
import "core:crypto"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../send"

// Finding on Windows, Linux and Android, by the app's own multicast DNS (src/send's
// messages): a desktop that receives answers questions for the service on UDP 5353
// beside any responder the system runs (both share the port), and a tablet asks with a
// legacy unicast question, so it hears the answers on a port of its own and never joins
// the group (Android would need a multicast lock for that). Apple's systems use dns_sd
// instead (send_find_darwin.odin), which the iPad requires.

// The answering side: its thread, which owns its socket and ends with its generation.
Send_Answer :: struct {
	thread: ^thread.Thread,
}

// Starts answering for this desktop, beside the listener of generation gen.
send_answer_begin :: proc(sh: ^Send_Shared, gen: int, ctx: runtime.Context) -> (a: Send_Answer) {
	any_sock, err := net.create_socket(.IP4, .UDP)
	if err != nil {
		log.warnf("send: cannot answer on the network: %v", err)
		return
	}
	sock := any_sock.(net.UDP_Socket)
	// Shared with the system's responder (Windows' DNS client, Avahi) and with other
	// copies of the app on this machine.
	_ = net.set_option(sock, .Reuse_Address, true)
	if berr := net.bind(sock, {net.IP4_Any, send.MDNS_PORT}); berr != nil {
		log.warnf("send: cannot answer on UDP %d: %v (type this computer's address on the tablet instead)", send.MDNS_PORT, berr)
		net.close(sock)
		return
	}
	_ = net.set_option(sock, .Receive_Timeout, time.Second)
	joined := mdns_join(sock, {})
	locals := make([dynamic][4]u8, context.temp_allocator)
	local_addresses(&locals)
	for l in locals do joined = mdns_join(sock, l) || joined
	if !joined do log.warnf("send: cannot join the mDNS group: the tablet will not find this computer by itself")
	Start :: struct {
		sh:   ^Send_Shared,
		sock: net.UDP_Socket,
		gen:  int,
	}
	start := new(Start)
	start^ = {sh, sock, gen}
	a.thread = thread.create_and_start_with_data(start, proc(data: rawptr) {
		start := cast(^Start)data
		sh, sock, gen := start.sh, start.sock, start.gen
		free(start)
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		send_answer_run(sh, sock, gen, &arena)
		net.close(sock)
	}, ctx, .Normal, name = "send answer")
	log.infof("send: answering for %s on the local network", sh.me.name)
	return a
}

// Stops answering: the generation has moved on already, so the thread ends within its
// one-second receive. Returns it to be joined once done.
send_answer_stop :: proc(a: ^Send_Answer) -> ^thread.Thread {
	t := a.thread
	a^ = {}
	return t
}

@(private = "file")
send_answer_run :: proc(sh: ^Send_Shared, sock: net.UDP_Socket, gen: int, arena: ^runtime.Arena) {
	buf: [send.MDNS_MAX]u8
	// Kept across packets, while the temp arena is emptied after each.
	out := make([dynamic]u8)
	defer delete(out)
	sync.lock(&sh.lock)
	device, name, port := sh.me.device, strings.clone(sh.me.name), sh.port
	sync.unlock(&sh.lock)
	defer delete(name)
	host := strings.clone(send.host_name(device))
	defer delete(host)
	for send_receiving(sh, gen) {
		n, from, err := net.recv_udp(sock, buf[:])
		if err != nil || n == 0 do continue
		ip, is4 := from.address.(net.IP4_Address)
		if !is4 do continue
		asks, id, unicast, question := send.query_asks(buf[:n], from.port == send.MDNS_PORT, host)
		if !asks do continue
		// The address the asker reaches this machine by, worked out for each question:
		// the network may have changed since the last.
		local, lok := local_toward(cast([4]u8)ip)
		addresses := [1][4]u8{local}
		advert := send.Advert {
			device    = device,
			name      = name,
			port      = u16(port),
			addresses = addresses[:1] if lok else nil,
		}
		clear(&out)
		legacy := from.port != send.MDNS_PORT
		send.answer_put(&out, advert, id, legacy, question, SCENE_VERSION)
		to := from if unicast else net.Endpoint{net.IP4_Address(send.MDNS_GROUP), send.MDNS_PORT}
		_, _ = net.send_udp(sock, out[:], to)
		runtime.arena_free_all(arena)
	}
}

// Asks the local network for a desktop receiving scenes, and waits up to wait for the
// first that answers: the one called name (any case) when name is given, else any. With
// all, it waits out the whole time instead and appends every desktop that answered there,
// once each. Stops early once stop is set. Found names are owned by the caller
// (send.found_destroy).
send_find_run :: proc(sh: ^Send_Shared, name: string, wait: time.Duration, stop: ^bool, all: ^[dynamic]send.Found = nil) -> (found: send.Found, ok: bool) {
	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.warnf("send: cannot ask the network: %v", err)
		return
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 200 * time.Millisecond)
	sync.lock(&sh.lock)
	me := sh.me.device
	sync.unlock(&sh.lock)
	id_bytes: [2]u8
	crypto.rand_bytes(id_bytes[:])
	id := u16(id_bytes[0]) << 8 | u16(id_bytes[1])
	query := make([dynamic]u8, context.temp_allocator)
	send.query_put(&query, id)
	group := net.Endpoint{net.IP4_Address(send.MDNS_GROUP), send.MDNS_PORT}
	start := time.tick_now()
	asked := time.Duration(-1)
	buf: [send.MDNS_MAX]u8
	for {
		since := time.tick_since(start)
		if since >= wait || sync.atomic_load(&sh.quit) || sync.atomic_load(stop) do return found, ok || (all != nil && len(all) > 0)
		// Asked again each second, as a lost packet on Wi-Fi is common.
		if asked < 0 || since - asked >= time.Second {
			_, _ = net.send_udp(sock, query[:], group)
			asked = since
		}
		n, from, rerr := net.recv_udp(sock, buf[:])
		if rerr != nil || n < 2 do continue
		ip, is4 := from.address.(net.IP4_Address)
		if !is4 || u16(buf[0]) << 8 | u16(buf[1]) != id do continue
		list := send.answer_get(buf[:n], cast([4]u8)ip)
		defer delete(list)
		for &f in list {
			if all != nil && send_found_keep(all, &f, me) do continue
			if all == nil && !ok && f.device != me && f.protocol == send.PROTOCOL && (name == "" || strings.equal_fold(f.name, name)) {
				found, ok = f, true
			} else {
				send.found_destroy(&f)
			}
		}
		if ok do return
	}
}
