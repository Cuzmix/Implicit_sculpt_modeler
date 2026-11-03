package main

import "core:crypto"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import "../send"

// Send to computer and Send to tablet: the whole scene, as Save writes it, goes over the
// local network to a paired copy of the app, which opens it. The frames, the pairing,
// the sealing and the rebuilding of the file are src/send's; this file is the app's side
// on the frame loop (who this device is, the paired devices, starting a send, opening
// what arrived) and send_net.odin the threads that move the bytes.
//
// A desktop listens for sends (--receive); any device sends to an address (--send-to).
// The first send between two devices pairs them: both show the
// same six digits, and the receiver allows it (--send-allow in a scripted run). Each
// received file lands whole in the Received folder, built from the copy of the same scene
// the receiver got last from that device and the chunks it lacked, and opens when the
// open scene has nothing unsaved.
//
// Everything lives in the send folder beside the settings (`send`, or `<name>-send` for
// --settings-file, or --send-folder): `device.txt` (this installation's id), `paired.txt`
// (each paired device's id, key and name) and `received/`.

SEND_FOLDER :: "send"
SEND_DEVICE_FILE :: "device.txt"
SEND_PAIRED_FILE :: "paired.txt"
SEND_RECEIVED :: "received"
// The port a desktop listens on unless told otherwise: unassigned, above the registered
// range's busy part, and the same on every device so that a typed address needs none.
SEND_PORT :: 47820
// The web version has no sockets.
SEND_AVAILABLE :: ODIN_OS != .JS

Send_Pair :: struct {
	device: [16]u8,
	key:    send.Key,
	name:   string, // owned
}

Send_Event_Kind :: enum u8 {
	Note,
	Warning,
	Received, // path is the file now whole in the Received folder
	Sent,
}

// What a thread tells the frame loop. Strings are owned by the event.
Send_Event :: struct {
	kind: Send_Event_Kind,
	text: string,
	path: string,
	hash: u64, // the file's hash, Sent and Received
}

// What the frame loop and the threads share, under lock unless said otherwise.
Send_Shared :: struct {
	lock:     sync.Mutex,
	quit:     bool, // atomic: every thread ends its session and returns
	cancel:   bool, // atomic: the send under way stops
	folder:   string,
	me:       send.Hello, // this device's hello, its strings owned
	role:     send.Role,
	allow:    bool, // --send-allow: pair with whoever asks, without asking anyone
	pairs:    [dynamic]Send_Pair,
	events:   [dynamic]Send_Event,
	listener: net.TCP_Socket, // the listening socket, for waking the listener at the end
	port:     int,
	// The send under way: how far it is, in bytes of the file.
	done, total: i64,
}

Send :: struct {
	shared:   ^Send_Shared, // nil in a run with no send folder
	listen:   ^thread.Thread,
	sender:   ^thread.Thread,
	revision: u64, // rises with each send from this run
	pending:  string, // --send-to: sent once the run is set up; owned
	frames:   int,
	exit_after_receive: bool,
	// What this run did, for the exit stats.
	sent, received, refused: int,
	sent_hash, received_hash: u64,
}

// The send folder for a settings file, as link_folder's.
send_folder :: proc(settings: string) -> string {
	if settings == "" do return ""
	dir, base := filepath.split(settings)
	name := SEND_FOLDER if base == SETTINGS_FILE else fmt.tprintf("%s-%s", filepath.stem(base), SEND_FOLDER)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// This device's name as the other side shows it: the computer's own name where the system
// gives one, else what it is.
@(private = "file")
send_device_name :: proc() -> string {
	when ODIN_OS == .Windows {
		if n := os.get_env("COMPUTERNAME", context.temp_allocator); n != "" do return n
		return "Windows PC"
	} else when ODIN_PLATFORM_SUBTARGET_IOS {
		return "iPad"
	} else when ODIN_PLATFORM_SUBTARGET == .Android {
		return "Android tablet"
	} else when ODIN_OS == .Darwin {
		return "Mac"
	} else {
		if data, err := os.read_entire_file("/etc/hostname", context.temp_allocator); err == nil {
			if n := strings.trim_space(string(data)); n != "" do return n
		}
		return "Linux PC"
	}
}

@(private = "file")
hex_put :: proc(b: ^strings.Builder, bytes: []u8) {for v in bytes do fmt.sbprintf(b, "%02x", v)}

@(private = "file")
hex_get :: proc(s: string, dst: []u8) -> bool {
	if len(s) != 2 * len(dst) do return false
	for &v, i in dst {
		n, ok := strconv.parse_u64_of_base(s[2 * i:][:2], 16)
		if !ok do return false
		v = u8(n)
	}
	return true
}

// This installation's id, made once and kept in device.txt.
@(private = "file")
send_device_id :: proc(folder: string) -> (id: [16]u8) {
	path, _ := filepath.join({folder, SEND_DEVICE_FILE}, context.temp_allocator)
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		lines := strings.split_lines(string(data), context.temp_allocator)
		if len(lines) >= 2 && lines[0] == "sculpt_send 1" && strings.has_prefix(lines[1], "device ") && hex_get(lines[1][7:], id[:]) do return id
	}
	crypto.rand_bytes(id[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "sculpt_send 1\ndevice ")
	hex_put(&b, id[:])
	strings.write_byte(&b, '\n')
	if err := write_durably(path, b.buf[:]); err != "" do log.warnf("send: %s", err)
	return id
}

// The paired devices, from paired.txt: `paired <id> <key> <name>` a line. A line that
// does not read is passed over.
@(private = "file")
send_pairs_load :: proc(sh: ^Send_Shared) {
	path, _ := filepath.join({sh.folder, SEND_PAIRED_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		words := strings.fields(line, context.temp_allocator)
		if len(words) != 4 || words[0] != "paired" do continue
		p: Send_Pair
		if !hex_get(words[1], p.device[:]) || !hex_get(words[2], p.key[:]) do continue
		p.name = strings.clone(preset_unescape(words[3]))
		append(&sh.pairs, p)
	}
}

// Writes paired.txt, under the lock. Only this user can read it on a desktop: it holds
// the keys.
send_pairs_save :: proc(sh: ^Send_Shared) {
	b := strings.builder_make(context.temp_allocator)
	for &p in sh.pairs {
		strings.write_string(&b, "paired ")
		hex_put(&b, p.device[:])
		strings.write_byte(&b, ' ')
		hex_put(&b, p.key[:])
		fmt.sbprintf(&b, " %s\n", preset_escape(p.name if p.name != "" else "-"))
	}
	path, _ := filepath.join({sh.folder, SEND_PAIRED_FILE}, context.temp_allocator)
	if err := write_durably(path, b.buf[:]); err != "" do log.warnf("send: %s", err)
	when ODIN_OS != .Windows do _ = os.chmod(path, {.Read_User, .Write_User})
}

// Sets up sending for a run with a send folder: this device's id and pairs, and the
// listener when receive is on.
send_init :: proc(app: ^App, folder: string, receive, allow, exit_after_receive: bool, port: int) {
	when !SEND_AVAILABLE do return
	if folder == "" do return
	received, _ := filepath.join({folder, SEND_RECEIVED}, context.temp_allocator)
	if err := os.make_directory_all(received); err != nil && !os.exists(received) {
		log.warnf("send: cannot make %s: %v", received, err)
		return
	}
	sh := new(Send_Shared)
	sh.folder = strings.clone(folder)
	sh.role = .Tablet if MOBILE else .Desktop
	sh.me = send.Hello {
		protocol      = send.PROTOCOL,
		scene_version = SCENE_VERSION,
		role          = sh.role,
		device        = send_device_id(folder),
		name          = strings.clone(send_device_name()),
		build         = fmt.aprintf("Sculpt, scenes v%d", SCENE_VERSION),
	}
	sh.allow = allow
	sh.port = port if port > 0 else SEND_PORT
	send_pairs_load(sh)
	app.send.shared = sh
	app.send.exit_after_receive = exit_after_receive
	if receive && !MOBILE do app.send.listen = send_listen_start(sh, context)
}

// Ends every session and thread, then frees what they shared. A send under way at the end
// of a scripted run is let finish (--send-to with --frames), an interactive one stopped.
send_destroy :: proc(app: ^App, finish_send: bool) {
	sh := app.send.shared
	if sh == nil do return
	if app.send.sender != nil {
		if !finish_send do sync.atomic_store(&sh.cancel, true)
		thread.join(app.send.sender)
		thread.destroy(app.send.sender)
		app.send.sender = nil
	}
	if app.send.listen != nil {
		sync.atomic_store(&sh.quit, true)
		send_listen_wake(sh)
		thread.join(app.send.listen)
		thread.destroy(app.send.listen)
		app.send.listen = nil
	}
	send_events_take(app)
	for p in sh.pairs do delete(p.name)
	delete(sh.pairs)
	delete(sh.events)
	delete(sh.me.name)
	delete(sh.me.build)
	delete(sh.folder)
	free(sh)
	app.send.shared = nil
}

// Queues what a thread has to say, under the lock.
send_event :: proc(sh: ^Send_Shared, kind: Send_Event_Kind, path: string, hash: u64, format: string, args: ..any) {
	sync.lock(&sh.lock)
	append(&sh.events, Send_Event{kind = kind, text = fmt.aprintf(format, ..args), path = strings.clone(path), hash = hash})
	sync.unlock(&sh.lock)
}

// Sends the scene to host (`name`, `name:port`, an address), on a thread: the scene is
// read here, as Save reads it, then the thread does the rest.
send_scene :: proc(app: ^App, host: string) -> bool {
	sh := app.send.shared
	if sh == nil {
		file_note(app, true, "This run keeps no settings, so it cannot send: it has no send folder")
		return false
	}
	if app.send.sender != nil {
		sync.lock(&sh.lock)
		busy := sh.total > 0 && sh.done < sh.total
		sync.unlock(&sh.lock)
		if busy {
			file_note(app, true, "A send is already under way")
			return false
		}
		thread.join(app.send.sender)
		thread.destroy(app.send.sender)
		app.send.sender = nil
	}
	stroke_finish(app)
	job := new(Send_Job)
	hd := scene_bytes(app, &job.data)
	job.token = link_scene_token(app)
	app.send.revision += 1
	job.revision = app.send.revision
	job.host = strings.clone(host)
	job.hd_dropped = hd
	sync.atomic_store(&sh.cancel, false)
	sync.lock(&sh.lock)
	sh.done, sh.total = 0, i64(len(job.data))
	sync.unlock(&sh.lock)
	app.send.sender = send_start(sh, job, context)
	file_note(app, false, "Sending the scene to %s...", host)
	return true
}

// Takes what the threads said: notes, and a received scene, which opens when the open
// scene holds nothing unsaved (always in --exit-after-receive's run, which then ends).
send_events_take :: proc(app: ^App) {
	sh := app.send.shared
	if sh == nil do return
	sync.lock(&sh.lock)
	events := sh.events
	sh.events = {}
	sync.unlock(&sh.lock)
	defer delete(events)
	for e in events {
		defer {
			delete(e.text)
			delete(e.path)
		}
		switch e.kind {
		case .Note:    file_note(app, false, "%s", e.text)
		case .Warning:
			app.send.refused += 1
			file_note(app, true, "%s", e.text)
		case .Sent:
			app.send.sent += 1
			app.send.sent_hash = e.hash
			file_note(app, false, "%s", e.text)
		case .Received:
			app.send.received += 1
			app.send.received_hash = e.hash
			if !app.running do continue
			if !app.send.exit_after_receive && scene_unsaved(app) {
				file_note(app, false, "%s. It is kept in the Received folder, since this scene has unsaved changes", e.text)
				continue
			}
			opened, _ := scene_open(app, e.path)
			if opened {
				scene_remember_path(app, e.path)
				recent_scene_add(app, e.path)
				if app.kit.home do home_close(app)
				file_note(app, false, "%s, and opened it", e.text)
			}
			if app.send.exit_after_receive do app.running = false
		}
	}
}

// The frame loop's part, once a frame.
send_frame :: proc(app: ^App) {
	if app.send.shared == nil do return
	send_events_take(app)
	app.send.frames += 1
	// --send-to waits for a set-up script and for the first frames, which draw the
	// scene's preview the file keeps.
	if app.send.pending != "" && app.send.frames > 3 && !(app.script.running && app.script.setup) {
		_ = send_scene(app, app.send.pending)
		delete(app.send.pending)
		app.send.pending = ""
	}
}
