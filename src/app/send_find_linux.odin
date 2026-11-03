package main

import "core:net"
import "core:sys/linux"

import "../send"

// Linux's and Android's parts of finding (send_find_mdns.odin): joining the multicast
// group, and the address this machine reaches another by. core:net has neither.

// Joins the mDNS group on the interface whose address is local (all zeros: the one the
// system picks), as a responder must to hear questions sent to the group.
mdns_join :: proc(sock: net.UDP_Socket, local: [4]u8) -> bool {
	IP_ADD_MEMBERSHIP :: 35
	Mreq :: struct {
		group, local: [4]u8,
	}
	m := Mreq{send.MDNS_GROUP, local}
	return linux.setsockopt_base(linux.Fd(sock), 0, IP_ADD_MEMBERSHIP, &m) == .NONE
}

// The address of this machine on the way to to: a UDP socket connected there (which
// sends nothing) is bound to it by the routing table.
local_toward :: proc(to: [4]u8) -> (local: [4]u8, ok: bool) {
	fd, err := linux.socket(.INET, .DGRAM, {.CLOEXEC}, .UDP)
	if err != .NONE do return {}, false
	defer linux.close(fd)
	addr := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_port   = u16be(send.MDNS_PORT),
		sin_addr   = to,
	}
	if linux.connect(fd, &addr) != .NONE do return {}, false
	bound: linux.Sock_Addr_Any
	if linux.getsockname(fd, &bound) != .NONE do return {}, false
	return bound.ipv4.sin_addr, true
}

// This machine's IPv4 addresses, for joining the group on every interface. The pinned
// core:net does not list interfaces on Linux, so the group is joined on the one the
// system picks, which on a desktop with one network is the network.
local_addresses :: proc(out: ^[dynamic][4]u8) {}
