package send

// Who opens a session. Desktops listen for sends; tablets connect to them and keep the
// connection while the app is open, so the desktop can send back down it.
Role :: enum u8 {
	Desktop = 1,
	Tablet  = 2,
}

// The longest device name and build text a hello carries, in bytes.
NAME_MAX :: 64
BUILD_MAX :: 64

// The first message each side sends. Both must speak the same protocol and read the same
// scene files, or nothing else is said: an earlier build's scene is refused, never
// converted (no compatibility before release), so a send between two builds would only
// fail at the end, after the whole file went over.
Hello :: struct {
	protocol:      u16,
	scene_version: u32,
	role:          Role,
	device:        [16]u8, // random, made once per installation; names the device in pairings
	nonce:         [32]u8, // random, new for each session: both sides' make the session's keys (seal.odin)
	// The port this device receives scenes on while it is open, 0 when it does not: a
	// tablet that sends to a computer says where the computer can send it back.
	port:          u16,
	name:          string, // the device's name as shown ("Bolt's iPad"); into the body parsed
	build:         string, // the app's build, shown when the two differ
}

Refusal :: enum u8 {
	None,
	Protocol,      // the other side speaks another version of this protocol
	Scene_Version, // the other side reads or writes other scene files
	Damaged,       // a message did not read as one of ours
	Busy,          // the receiver is already taking a send
	Declined,      // the person on the other side said no
	Too_Big,       // the file is over FILE_MAX, or the receiver has no room for it
	Cancelled,     // the sender stopped
	Not_Paired,    // the receiver does not know this device, or its key no longer matches
}

REFUSAL_TEXT := [Refusal]string {
	.None          = "",
	.Protocol      = "the two devices run different versions of Sculpt: update the older one",
	.Scene_Version = "the two devices run different versions of Sculpt, which save scenes differently: update the older one",
	.Damaged       = "the connection sent something damaged",
	.Busy          = "it is already taking another send",
	.Declined      = "it was declined on the other device",
	.Too_Big       = "the scene is too big for the other device",
	.Cancelled     = "the send was cancelled",
	.Not_Paired    = "the two devices are not paired: pair them again",
}

hello_put :: proc(out: ^[dynamic]u8, h: Hello) {
	put_u16(out, h.protocol)
	put_u32(out, h.scene_version)
	append(out, u8(h.role))
	device := h.device
	append(out, ..device[:])
	nonce := h.nonce
	append(out, ..nonce[:])
	put_u16(out, h.port)
	put_string(out, h.name, NAME_MAX)
	put_string(out, h.build, BUILD_MAX)
}

// A hello read from body. Its strings point into body.
@(require_results)
hello_get :: proc(body: []u8) -> (h: Hello, ok: bool) {
	r := reader(body)
	h.protocol = get_u16(&r)
	h.scene_version = get_u32(&r)
	role := get_u8(&r)
	get_bytes(&r, h.device[:])
	get_bytes(&r, h.nonce[:])
	h.port = get_u16(&r)
	h.name = get_string(&r, NAME_MAX)
	h.build = get_string(&r, BUILD_MAX)
	if !reader_done(&r) do return {}, false
	if role != u8(Role.Desktop) && role != u8(Role.Tablet) do return {}, false
	h.role = Role(role)
	return h, true
}

// Why a session with theirs cannot go on, or None. The protocol is checked first: a peer
// of another protocol may lay out even the scene version differently.
@(require_results)
hello_check :: proc(mine, theirs: Hello) -> Refusal {
	if theirs.protocol != mine.protocol do return .Protocol
	if theirs.scene_version != mine.scene_version do return .Scene_Version
	return .None
}

refuse_put :: proc(out: ^[dynamic]u8, why: Refusal) {append(out, u8(why))}

@(require_results)
refuse_get :: proc(body: []u8) -> (why: Refusal, ok: bool) {
	r := reader(body)
	b := get_u8(&r)
	if !reader_done(&r) || b == 0 || b > u8(max(Refusal)) do return .Damaged, false
	return Refusal(b), true
}
