package main

import "core:net"
import win "core:sys/windows"

import "../send"

// Windows' parts of finding (send_find_mdns.odin): joining the multicast group, and the
// address this machine reaches another by. core:net has neither.

// Joins the mDNS group on the interface whose address is local (all zeros: the one the
// system picks), as a responder must to hear questions sent to the group.
mdns_join :: proc(sock: net.UDP_Socket, local: [4]u8) -> bool {
	group := send.MDNS_GROUP
	m := win.ip_mreq {
		imr_multiaddr = {s_addr = transmute(u32)group},
		imr_interface = {s_addr = transmute(u32)local},
	}
	return win.setsockopt(win.SOCKET(sock), win.IPPROTO_IP, win.IP_ADD_MEMBERSHIP, &m, size_of(m)) == 0
}

// The address of this machine on the way to to: a UDP socket connected there (which
// sends nothing) is bound to it by the routing table.
local_toward :: proc(to: [4]u8) -> (local: [4]u8, ok: bool) {
	s := win.socket(win.AF_INET, win.SOCK_DGRAM, win.IPPROTO_UDP)
	if s == win.INVALID_SOCKET do return {}, false
	defer win.closesocket(s)
	storage: win.SOCKADDR_STORAGE_LH
	addr := cast(^win.sockaddr_in)&storage
	addr^ = {
		sin_family = u16(win.AF_INET),
		sin_port   = u16be(send.MDNS_PORT),
		sin_addr   = {s_addr = transmute(u32)to},
	}
	if win.connect(s, &storage, size_of(win.sockaddr_in)) != 0 do return {}, false
	bound: win.SOCKADDR_STORAGE_LH
	size := i32(size_of(bound))
	if win.getsockname(s, &bound, &size) != 0 do return {}, false
	return transmute([4]u8)(cast(^win.sockaddr_in)&bound).sin_addr.s_addr, true
}

// This machine's IPv4 addresses, for joining the group on every interface: a PC with
// virtual adapters (Hyper-V, WSL, VPNs) may hear the tablet on any of them.
local_addresses :: proc(out: ^[dynamic][4]u8) {
	ifaces, err := net.enumerate_interfaces(context.temp_allocator)
	if err != nil do return
	for i in ifaces {
		for lease in i.unicast {
			if a, ok := lease.address.(net.IP4_Address); ok && a[0] != 127 do append(out, cast([4]u8)a)
		}
	}
}
