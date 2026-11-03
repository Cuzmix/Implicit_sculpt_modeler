package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// What happens when a scene arrives (README "Send", Round trips). The scene's token names
// it on every device, so a scene going back and forth replaces itself rather than piling
// up copies:
//   - the open scene, unchanged here since it last went out or came in (or matching its
//     file): the arrival opens in place, keeping this device's view of it;
//   - another scene, while the open one matches its file: the arrival opens;
//   - otherwise the pill asks: Open (the open scene kept first as a copy in the send
//     folder's `kept`) or Keep for later (the arrival stays in Received and in Home's
//     Recent). The open scene changed here too is said so.
// An opened arrival saves where this device last saved that scene (saved.txt), or, never
// saved here, asks where as Save as does: the Received copy is the next send's base, so
// Save never writes it.

Arrive_Answer :: enum u8 {
	Ask,  // the pill asks
	Open, // --send-arrived=open
	Keep, // --send-arrived=keep
}

// A scene that arrived and waits on the pill. All strings owned.
Send_Arrival :: struct {
	path:     string, // the copy in Received
	from:     string, // the device's name
	text:     string, // the receive's note
	token:    u64,
	conflict: bool, // the open scene is the same one, changed here too
}

// Where a scene was last saved on this device.
Send_Saved :: struct {
	token: u64,
	path:  string, // owned
}

// The kept list's file in the send folder, and how many scenes it remembers.
@(private = "file")
SEND_SAVED_FILE :: "saved.txt"
@(private = "file")
SEND_SAVED_MAX :: 200
// Where the open scene goes before an arrival replaces it.
@(private = "file")
SEND_KEPT :: "kept"

// What an arriving scene with token does, by the rules above.
Arrive_Rule :: enum u8 {
	In_Place, // the same scene, unchanged here: opens keeping the view
	Open,     // another scene, nothing here to lose: opens
	Ask,      // another scene, the open one holding work: the pill asks
	Conflict, // the same scene, changed here too: the pill asks
}

send_arrive_rule :: proc(app: ^App, token: u64) -> Arrive_Rule {
	same := token != 0 && app.scene.link_token == token
	changed := send_scene_changed(app)
	if same && (!changed || (app.send.exchanged_token == token && app.send.exchanged_fp == scene_fingerprint(app))) do return .In_Place
	if same do return .Conflict
	return .Ask if changed else .Open
}

// Settles a received scene by the rules above.
send_arrive :: proc(app: ^App, e: Send_Event) {
	switch rule := send_arrive_rule(app, e.token); rule {
	case .In_Place:
		send_arrival_open(app, e.path, e.from, e.token, e.text, in_place = true, keep_mine = false)
	case .Open:
		send_arrival_open(app, e.path, e.from, e.token, e.text, in_place = false, keep_mine = false)
	case .Ask, .Conflict:
		same := rule == .Conflict
		answer := app.send.arrive_answer
		if answer == .Ask {
			// A later arrival takes the pill; the one before stays in Received.
			if app.send.arrived.path != "" {
				recent_scene_add(app, app.send.arrived.path)
				file_note(app, false, "The scene from %s is kept for later: Home's Recent lists it", app.send.arrived.from)
			}
			send_arrival_drop(app)
			app.send.arrived = {
				path     = strings.clone(e.path),
				from     = strings.clone(e.from),
				text     = strings.clone(e.text),
				token    = e.token,
				conflict = same,
			}
			file_note(app, false, "%s. Changed here too: open it, or keep both?" if same else "%s. Open it, or keep it for later?", e.text)
			return
		}
		if answer == .Open {
			send_arrival_open(app, e.path, e.from, e.token, e.text, in_place = false, keep_mine = true)
		} else {
			recent_scene_add(app, e.path)
			file_note(app, false, "%s. Kept for later in Received: Home's Recent lists it", e.text)
		}
	}
	if app.send.exit_after_receive do app.running = false
}

// Whether the open scene holds work a replacing scene would lose, as Home and the top bar
// judge it: changes since its file, or, never saved, any work at all.
@(private = "file")
send_scene_changed :: proc(app: ^App) -> bool {
	return scene_unsaved(app) && (app.scene_path != "" || scene_has_work(app))
}

// The pill's answer to the waiting arrival.
send_arrival_answer :: proc(app: ^App, open: bool) {
	a := app.send.arrived
	if a.path == "" do return
	app.send.arrived = {}
	defer {
		delete(a.path)
		delete(a.from)
		delete(a.text)
	}
	if open {
		send_arrival_open(app, a.path, a.from, a.token, a.text, in_place = false, keep_mine = true)
	} else {
		recent_scene_add(app, a.path)
		file_note(app, false, "Kept the scene from %s for later: Home's Recent lists it", a.from)
	}
	if app.send.exit_after_receive do app.running = false
}

send_arrival_drop :: proc(app: ^App) {
	delete(app.send.arrived.path)
	delete(app.send.arrived.from)
	delete(app.send.arrived.text)
	app.send.arrived = {}
}

// Opens a received copy as the scene: first keeping the open one when it has changes, in
// place keeping the view, then pointing Save at where this scene was saved here before.
@(private = "file")
send_arrival_open :: proc(app: ^App, path, from: string, token: u64, text: string, in_place, keep_mine: bool) {
	kept := ""
	if keep_mine && send_scene_changed(app) {
		kept = send_keep_mine(app)
		if kept == "" {
			file_note(app, true, "%s. It is kept in Received: the open scene could not be kept first, so it stays open", text)
			recent_scene_add(app, path)
			return
		}
	}
	view := app.camera
	// scene_open frees the temp memory: the names are kept here.
	copy_path := strings.clone(path)
	defer delete(copy_path)
	note := strings.clone(text)
	defer delete(note)
	opened, _ := scene_open(app, copy_path)
	if !opened do return
	if in_place do app.camera = view
	saves_to := send_saved_path(app, token)
	if saves_to != "" && os.exists(saves_to) {
		scene_remember_path(app, saves_to)
		// The file there is this device's older copy: the scene is not it until saved.
		app.saved_fp = 0
	} else {
		saves_to = ""
		scene_remember_path(app, "")
	}
	recent_scene_add(app, copy_path)
	if app.kit.home do home_close(app)
	app.send.exchanged_token, app.send.exchanged_fp = token, scene_fingerprint(app)
	how := " in place" if in_place else ""
	dest := fmt.tprintf("; Save goes to %s", filepath.base(saves_to)) if saves_to != "" else ""
	mine := fmt.tprintf("; the scene open before is kept as %s", filepath.base(kept)) if kept != "" else ""
	file_note(app, false, "%s, and opened it%s%s%s", note, how, dest, mine)
}

// Writes the open scene, as Save would, into the send folder's kept folder under its
// name and the time; returns the path, or "" when it could not be written.
@(private = "file")
send_keep_mine :: proc(app: ^App) -> string {
	sh := app.send.shared
	if sh == nil do return ""
	folder, _ := filepath.join({sh.folder, SEND_KEPT}, context.temp_allocator)
	if err := os.make_directory_all(folder); err != nil && !os.exists(folder) do return ""
	stem := filepath.stem(app.scene_path) if app.scene_path != "" else "scene"
	path, _ := filepath.join({folder, fmt.tprintf("%s %s.sculpt", stem, version_stamp(time.now()))}, context.allocator)
	defer delete(path)
	if !scene_save(app, path, copy = true) do return ""
	return strings.clone(path, context.temp_allocator)
}

// Where this device last saved the scene with token, or "".
send_saved_path :: proc(app: ^App, token: u64) -> string {
	if token == 0 do return ""
	for v in app.send.saved do if v.token == token do return v.path
	return ""
}

// Remembers that the scene was saved to path (Save and Save as, not a copy), most recent
// last, so it saves there again when it comes back. Paths in the send folder are not
// remembered: those are copies Send keeps.
send_saved_record :: proc(app: ^App, path: string) {
	sh := app.send.shared
	token := app.scene.link_token
	if sh == nil || token == 0 do return
	if rel, err := filepath.rel(sh.folder, path, context.temp_allocator); err == nil && !strings.has_prefix(rel, "..") do return
	for v, i in app.send.saved {
		if v.token != token do continue
		if v.path == path && i == len(app.send.saved) - 1 do return
		delete(v.path)
		ordered_remove(&app.send.saved, i)
		break
	}
	if len(app.send.saved) >= SEND_SAVED_MAX {
		delete(app.send.saved[0].path)
		ordered_remove(&app.send.saved, 0)
	}
	append(&app.send.saved, Send_Saved{token, strings.clone(path)})
	b := strings.builder_make(context.temp_allocator)
	for v in app.send.saved do fmt.sbprintf(&b, "saved %016x %s\n", v.token, preset_escape(v.path))
	file, _ := filepath.join({sh.folder, SEND_SAVED_FILE}, context.temp_allocator)
	if err := write_durably(file, b.buf[:]); err != "" do log.warnf("send: %s", err)
}

// Reads saved.txt; a line that does not read is passed over.
send_saved_load :: proc(app: ^App) {
	sh := app.send.shared
	if sh == nil do return
	file, _ := filepath.join({sh.folder, SEND_SAVED_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		words := strings.fields(line, context.temp_allocator)
		if len(words) != 3 || words[0] != "saved" do continue
		token, ok := strconv.parse_u64_of_base(words[1], 16)
		if !ok || token == 0 do continue
		append(&app.send.saved, Send_Saved{token, strings.clone(preset_unescape(words[2]))})
	}
}
