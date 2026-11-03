package main

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../send"

// Finding on the iPad and the Mac, through Apple's own responder (dns_sd, in libSystem):
// the Mac registers the service and the system answers for it; the iPad browses,
// resolves the instance and asks for its address, which needs no multicast entitlement
// (only NSBonjourServices and the local network prompt, ios/Info.plist). The same
// service type and TXT record as the app's own responder (send_find_mdns.odin), so either
// side finds the other.

foreign import dnssd "system:System"

@(private = "file")
DNSServiceRef :: distinct rawptr

@(private = "file")
Browse_Reply :: #type proc "c" (ref: DNSServiceRef, flags: u32, iface: u32, err: i32, name, type, domain: cstring, ctx: rawptr)
@(private = "file")
Resolve_Reply :: #type proc "c" (ref: DNSServiceRef, flags: u32, iface: u32, err: i32, fullname, host: cstring, port_be: u16, txt_len: u16, txt: [^]u8, ctx: rawptr)
@(private = "file")
Addr_Reply :: #type proc "c" (ref: DNSServiceRef, flags: u32, iface: u32, err: i32, host: cstring, addr: [^]u8, ttl: u32, ctx: rawptr)

@(private = "file", default_calling_convention = "c")
foreign dnssd {
	DNSServiceRegister :: proc(ref: ^DNSServiceRef, flags: u32, iface: u32, name, type, domain, host: cstring, port_be: u16, txt_len: u16, txt: rawptr, reply: rawptr, ctx: rawptr) -> i32 ---
	DNSServiceBrowse :: proc(ref: ^DNSServiceRef, flags: u32, iface: u32, type, domain: cstring, reply: Browse_Reply, ctx: rawptr) -> i32 ---
	DNSServiceResolve :: proc(ref: ^DNSServiceRef, flags: u32, iface: u32, name, type, domain: cstring, reply: Resolve_Reply, ctx: rawptr) -> i32 ---
	DNSServiceGetAddrInfo :: proc(ref: ^DNSServiceRef, flags: u32, iface: u32, protocol: u32, host: cstring, reply: Addr_Reply, ctx: rawptr) -> i32 ---
	DNSServiceRefSockFD :: proc(ref: DNSServiceRef) -> c.int ---
	DNSServiceProcessResult :: proc(ref: DNSServiceRef) -> i32 ---
	DNSServiceRefDeallocate :: proc(ref: DNSServiceRef) ---
}

@(private = "file")
FLAG_ADD :: u32(0x2)
@(private = "file")
PROTOCOL_IPV4 :: u32(0x1)
// The service type as dns_sd names it: without the domain.
@(private = "file")
SERVICE_TYPE :: "_sculptsend._tcp"

Send_Answer :: struct {
	ref: DNSServiceRef,
}

@(private = "file")
be16 :: proc(v: u16) -> u16 {return v >> 8 | v << 8}

// Registers this desktop's service; the system answers for it until the run ends. Its
// name is the device's, and the system renames it should another computer hold it.
send_answer_begin :: proc(sh: ^Send_Shared, ctx: runtime.Context) -> (a: Send_Answer) {
	sync.lock(&sh.lock)
	advert := send.Advert {
		device = sh.me.device,
		name   = strings.clone(sh.me.name, context.temp_allocator),
		port   = u16(sh.port),
	}
	sync.unlock(&sh.lock)
	txt := make([dynamic]u8, context.temp_allocator)
	send.txt_put(&txt, advert, SCENE_VERSION)
	label := strings.clone_to_cstring(send.instance_label(advert), context.temp_allocator)
	if err := DNSServiceRegister(&a.ref, 0, 0, label, SERVICE_TYPE, nil, nil, be16(advert.port), u16(len(txt)), raw_data(txt), nil, nil); err != 0 {
		log.warnf("send: cannot register with Bonjour (%d): type this computer's address on the tablet instead", err)
		a.ref = nil
		return
	}
	log.infof("send: answering for %s on the local network", advert.name)
	return a
}

send_answer_end :: proc(sh: ^Send_Shared, a: ^Send_Answer) {
	if a.ref != nil do DNSServiceRefDeallocate(a.ref)
	a^ = {}
}

@(private = "file")
Instance :: struct {
	name, domain: string,
	iface:        u32,
}

@(private = "file")
Find :: struct {
	odin:      runtime.Context,
	instances: [dynamic]Instance,
	// The resolve and address answers of the instance being looked at.
	resolved:  bool,
	host:      string,
	port:      u16,
	txt:       []u8,
	addressed: bool,
	address:   [4]u8,
}

// Waits on ref's socket until it has an answer or until is past, and hands the answer
// to its callback. False when time is up or the connection to the system's responder
// failed.
@(private = "file")
dnssd_step :: proc(ref: DNSServiceRef, until: time.Tick) -> bool {
	left := time.tick_diff(time.tick_now(), until)
	if left <= 0 do return false
	fds := [1]posix.pollfd{{fd = posix.FD(DNSServiceRefSockFD(ref)), events = {.IN}}}
	n := posix.poll(raw_data(fds[:]), 1, c.int(min(time.duration_milliseconds(left), 200)) + 1)
	if n < 0 do return false
	if n == 0 do return true
	return DNSServiceProcessResult(ref) == 0
}

// Browses for desktops receiving scenes for up to wait and returns the first that
// answers: the one called name (any case) when name is given, else any. The found
// desktop's name is owned by the caller (send.found_destroy).
send_find_run :: proc(sh: ^Send_Shared, name: string, wait: time.Duration) -> (found: send.Found, ok: bool) {
	sync.lock(&sh.lock)
	me := sh.me.device
	sync.unlock(&sh.lock)
	f := Find {
		odin      = context,
		instances = make([dynamic]Instance, context.temp_allocator),
	}
	browse: DNSServiceRef
	on_browse :: proc "c" (ref: DNSServiceRef, flags: u32, iface: u32, err: i32, name, type, domain: cstring, ctx: rawptr) {
		f := cast(^Find)ctx
		context = f.odin
		if err != 0 || flags & FLAG_ADD == 0 do return
		append(&f.instances, Instance{strings.clone_from_cstring(name, context.temp_allocator), strings.clone_from_cstring(domain, context.temp_allocator), iface})
	}
	if err := DNSServiceBrowse(&browse, 0, 0, SERVICE_TYPE, nil, on_browse, &f); err != 0 {
		log.warnf("send: cannot browse with Bonjour (%d)", err)
		return
	}
	defer DNSServiceRefDeallocate(browse)
	until := time.tick_add(time.tick_now(), wait)
	looked := 0
	for !sync.atomic_load(&sh.quit) && !sync.atomic_load(&sh.cancel) {
		if looked == len(f.instances) {
			if !dnssd_step(browse, until) do return
			continue
		}
		inst := f.instances[looked]
		looked += 1
		// Resolve the instance to its host, port and TXT record.
		f.resolved, f.addressed = false, false
		on_resolve :: proc "c" (ref: DNSServiceRef, flags: u32, iface: u32, err: i32, fullname, host: cstring, port_be: u16, txt_len: u16, txt: [^]u8, ctx: rawptr) {
			f := cast(^Find)ctx
			context = f.odin
			if err != 0 || f.resolved do return
			f.resolved = true
			f.host = strings.clone_from_cstring(host, context.temp_allocator)
			f.port = be16(port_be)
			f.txt = runtime.make_slice([]u8, int(txt_len), context.temp_allocator)
			copy(f.txt, txt[:txt_len])
		}
		resolve: DNSServiceRef
		cname := strings.clone_to_cstring(inst.name, context.temp_allocator)
		cdomain := strings.clone_to_cstring(inst.domain, context.temp_allocator)
		if DNSServiceResolve(&resolve, 0, inst.iface, cname, SERVICE_TYPE, cdomain, on_resolve, &f) != 0 do continue
		for !f.resolved && dnssd_step(resolve, until) {}
		DNSServiceRefDeallocate(resolve)
		if !f.resolved do continue
		candidate: send.Found
		if !send.txt_get(f.txt, &candidate) || candidate.device == me || candidate.protocol != send.PROTOCOL do continue
		if name != "" && !strings.equal_fold(candidate.name, name) do continue
		// Its IPv4 address.
		on_addr :: proc "c" (ref: DNSServiceRef, flags: u32, iface: u32, err: i32, host: cstring, addr: [^]u8, ttl: u32, ctx: rawptr) {
			f := cast(^Find)ctx
			if err != 0 || f.addressed || addr == nil || flags & FLAG_ADD == 0 do return
			// A sockaddr_in: length, family (AF_INET is 2), port, then the address.
			if addr[1] != 2 do return
			f.address = {addr[4], addr[5], addr[6], addr[7]}
			f.addressed = true
		}
		lookup: DNSServiceRef
		chost := strings.clone_to_cstring(f.host, context.temp_allocator)
		if DNSServiceGetAddrInfo(&lookup, 0, inst.iface, PROTOCOL_IPV4, chost, on_addr, &f) != 0 do continue
		for !f.addressed && dnssd_step(lookup, until) {}
		DNSServiceRefDeallocate(lookup)
		if !f.addressed do continue
		candidate.port = f.port
		candidate.addresses[0] = f.address
		candidate.count = 1
		candidate.name = strings.clone(candidate.name)
		return candidate, true
	}
	return
}
