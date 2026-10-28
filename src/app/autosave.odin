package main

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

import "../sculpt"
import "../voxel"

// Autosave and crash recovery. Once the scene changed and the interval passed, the
// first moment of rest (no button, key, finger, stroke or anything else that could
// change the scene: autosave_quiet) hands the scene to a thread of its own, which writes
// it the way a save does into its own buffer, then into a rotating slot of the app's
// autosave folder. The frame loop never waits for that, except for a moment when the
// user starts something while the scene is still being read: it then stops the thread,
// at most a piece later, and the next rest starts again. The writing itself goes on
// while the user sculpts, since the thread then reads only its own buffer.
//
// Each run is a session: its slots `<session>-1.sculpt` to `-3.sculpt` and a small
// `<session>.session` text file saying which scene it is, when it was last saved, which
// slot is newest and whether the run is still alive or ended cleanly. A session that
// neither ended nor is alive, and holds an autosave newer than its last save, is
// offered back at the next start (kit_recover.odin).

AUTOSAVE_FOLDER :: "autosave"
AUTOSAVE_SLOTS :: 3
// Seconds without a press, key or anything moving the scene before an autosave starts.
AUTOSAVE_REST :: 1.5
// How often a running session says it is alive, and how long after the last time it
// is taken for a crash rather than another copy of the app still running.
AUTOSAVE_HEARTBEAT :: 30
AUTOSAVE_ALIVE :: 90
// Sessions that ended cleanly keep their newest autosave, for "Open the last
// autosave"; the newest this many of them do.
AUTOSAVE_CLOSED_KEPT :: 3
// The intervals Settings offers, in minutes; 0 is off.
@(rodata)
AUTOSAVE_MINUTES := [?]i32{0, 1, 2, 5, 10}
AUTOSAVE_MINUTE_NAMES := [?]string{"Off", "Every minute", "Every 2 minutes", "Every 5 minutes", "Every 10 minutes"}
// A crash then loses at most about a minute and a half of work.
AUTOSAVE_DEFAULT_MINUTES :: 1
@(private = "file")
SESSION_EXT :: ".session"
@(private = "file")
SLOT_EXT :: ".sculpt"
@(private = "file")
SESSION_MAGIC :: "sculpt-session 1"

Autosave :: struct {
	minutes:  i32, // Settings > System, one of AUTOSAVE_MINUTES (remembered)
	on:       bool, // this run keeps a session: an interactive run, or one given --autosave or --autosave-folder
	seconds:  f64, // --autosave's interval, which wins over minutes; 0 for none
	rest:     f64,
	folder:   string, // ends in a separator
	session:  string,
	slot:     int, // where the next autosave goes, 1 to AUTOSAVE_SLOTS
	clean:    u64, // the fingerprint at the last autosave's start, save, open or new scene
	pending:  u64, // the fingerprint at the start of the autosave under way
	last_at:  f64, // input_clock at the last autosave's start, or at the last clean point
	busy_at:  f64, // input_clock of the last frame not at rest
	background: bool, // the app went to the background: autosave now
	scripted: bool, // a scripted bench or replay drives this frame (main.odin)
	check:    bool, // --check-autosave: the thread hashes what it read before and after
	crash_after: bool, // --crash-after-autosave
	// What the Settings line and the exit stats say.
	written:  int,
	aborts:   int,
	torn:     int, // --check-autosave runs whose scene changed while it was read
	wait_ms:  f64, // the longest the frame loop waited for the thread to stop
	sync_ms:  f64, // the levels_sync at the last start
	serialize_ms, write_ms: f64,
	bytes:    int,
	wall:     i64, // unix time of the last autosave written
	failed:   bool, // the last one failed, and the toast said so
	error:    string,
	recovered: int,
	offers:   [dynamic]Recover_Offer, // crashed sessions to ask about, newest first
	offer_hidden: bool, // Not now: the card stays away for this run
	worker:   ^Autosave_Worker,
}

// A crashed session the recovery card asks about.
Recover_Offer :: struct {
	session: string,
	info:    Session_Info,
	at:      i64, // unix time of its newest autosave
}

// What a session file holds. Times are unix seconds, 0 for never.
Session_Info :: struct {
	pid:      int, // the run's process, to tell a crash from a copy still running
	started:  i64,
	alive:    i64,
	scene:    string, // the scene's own file, "" for none
	saved:    i64, // when that file was last saved or opened
	newest:   int, // the newest autosave's slot, 0 for none
	at:       i64, // ...when it was made
	objects:  int,
	vertices: int,
	closed:   i64,
}

Autosave_Phase :: enum u8 {
	Idle,
	Serializing, // the thread reads the scene: the frame loop changes nothing
	Writing,     // the thread writes its own buffer: the scene is the frame loop's again
	Done,
	Failed,
	Aborted,
}

// What the frame loop hands the thread, and what comes back. The frame loop fills and
// frees it; the thread reads it while Serializing or Writing.
@(private = "file")
Autosave_Job :: struct {
	header:  [dynamic]u8,
	objects: [dynamic]^Object,
	hd:      [dynamic]bool, // per object: an HD window is open
	refs:    [dynamic][]Material_Refs, // per object: its and its groups' material pack parts, owned
	path:    string,
	info:    Session_Info, // the session file once this autosave is written
	check:   bool,
	// The thread's answer.
	bytes:   int,
	serialize_ms, write_ms: f64,
	error:   string,
	torn:    bool,
}

Autosave_Worker :: struct {
	thread:   ^thread.Thread,
	wake:     sync.Sema,
	lock:     sync.Mutex,
	cond:     sync.Cond,
	phase:    Autosave_Phase, // under lock; every change is broadcast on cond
	abort:    bool, // atomic: stop reading the scene
	quit:     bool, // under lock
	job:      Autosave_Job,
	folder:   string,
	session:  string,
	info:     Session_Info, // under lock: what the next session file says
	info_due: bool, // under lock: write the session file soon
}

// Starts the session and finds the crashed ones to ask about. `seconds` and `folder` are
// the flags; without them only an interactive run keeps a session.
autosave_init :: proc(app: ^App, interactive: bool, seconds: f64, folder: string, rest: f64, check, crash_after: bool) {
	a := &app.autosave
	a.on = interactive || seconds > 0 || folder != ""
	a.seconds, a.check, a.crash_after = seconds, check, crash_after
	a.rest = rest if rest > 0 else AUTOSAVE_REST
	if !a.on do return
	dir := folder
	if dir == "" {
		pref := sdl.GetPrefPath("Implicit", "Sculpt")
		if pref == nil {
			log.warnf("autosave: no folder for it (%s); this run is not autosaved", sdl.GetError())
			a.on = false
			return
		}
		dir = strings.concatenate({string(cstring(pref)), AUTOSAVE_FOLDER}, context.temp_allocator)
		sdl.free(pref)
	}
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		log.warnf("autosave: cannot make %s (%v); this run is not autosaved", dir, err)
		a.on = false
		return
	}
	a.folder = strings.concatenate({strings.trim_right(dir, "/\\"), filepath.SEPARATOR_STRING})
	now := unix_now()
	a.session = fmt.aprintf("%d-%04x", now, u16(time.tick_now()._nsec))
	a.slot = 1
	a.clean = scene_fingerprint(app)
	a.last_at = input_clock(app)
	a.busy_at = a.last_at
	autosave_prune(app)

	w := new(Autosave_Worker)
	w.folder, w.session = strings.clone(a.folder), strings.clone(a.session)
	w.info.started = now
	w.info.pid = os.get_pid()
	a.worker = w
	// The frame loop's allocator (the tracking one in a debug build has its own lock), so a
	// leak on the thread is caught too; its temp memory is its own (autosave_thread).
	w.thread = thread.create_and_start_with_data(w, autosave_thread, context, .Low, name = "autosave")
}

// Stops the thread without ending the session, as a crash or a failed run leaves it,
// and frees what the run kept.
autosave_destroy :: proc(app: ^App) {
	a := &app.autosave
	if w := a.worker; w != nil {
		sync.lock(&w.lock)
		w.quit = true
		sync.atomic_store(&w.abort, true)
		sync.unlock(&w.lock)
		sync.sema_post(&w.wake)
		thread.join(w.thread)
		thread.destroy(w.thread)
		job_free(&w.job)
		delete(w.info.scene)
		delete(w.folder)
		delete(w.session)
		free(w)
		a.worker = nil
	}
	for o in a.offers do offer_free(o)
	delete(a.offers)
	delete(a.folder)
	delete(a.session)
	delete(a.error)
	a.offers, a.folder, a.session, a.error = nil, "", "", ""
}

// How often an autosave is due, in seconds; 0 for never.
autosave_interval :: proc(a: ^Autosave) -> f64 {
	if a.seconds > 0 do return a.seconds
	return 60 * f64(autosave_minutes(a.minutes))
}

// The nearest interval Settings offers to `m` (a settings file may hold any number).
autosave_minutes :: proc(m: i32) -> i32 {
	best := AUTOSAVE_MINUTES[0]
	for v in AUTOSAVE_MINUTES do if abs(v - m) < abs(best - m) do best = v
	return best
}

// Whether nothing this frame could change the scene: no button, key, wheel, typing,
// finger or pen contact, and nothing under way that changes it without one (a stroke or
// its samples left over, a drag, a tap's waiting dab, the Space pie, a replay, the
// timeline's playback or time-lapse, a scripted stroke) or waiting to (a scene command,
// a file request, a save waiting for its toast). Hovering is rest.
autosave_quiet :: proc(app: ^App) -> bool {
	d := &app.device
	if len(d.keys) > 0 || d.down != {} || d.pressed != {} || d.released != {} || d.wheel != 0 || d.text_len > 0 || d.cancel do return false
	if app.touch.fingers.count > 0 do return false
	p := &app.ui.pie
	if p.space_down || p.space_pressed || p.space_released do return false
	// A topological mask still settling after its release writes the mask meanwhile.
	if app.stroke.active || len(app.stroke.pending) > 0 || app.drag.owner != .None || app.dab_wait.active || move_busy(app) do return false
	if replay_busy(app) || timeline_busy(app) || app.autosave.scripted do return false
	return app.ui.scene_command.kind == .None && !file_pending() && app.saving.kind == .None
}

// What decides whether the scene changed since the last autosave: the History's edits,
// the changes it does not list, and per object what object_put stores outside its
// levels' undo (its name, placement and boolean mode) and the level shown, the number
// of levels and HD steps, and the scene's lights as the file stores them. The camera is
// left out: a new view alone is not worth a write.
scene_fingerprint :: proc(app: ^App) -> u64 {
	Part :: struct {
		id:         i64,
		position:   Vec3,
		rotation:   Vec3,
		scale:      f32,
		boolean:    u32,
		current:    u32,
		levels:     u32,
		hd_steps:   u32,
		name:       u64,
	}
	h := xxhash.XXH3_64(mem.ptr_to_bytes(&[4]u64{app.history.edits, app.scene_edits, app.view_edits, u64(len(app.scene.objects))}))
	lights := make([dynamic]u8, 0, 1024, context.temp_allocator)
	lights_put(&lights, app.scene.lights)
	h = xxhash.XXH3_64(lights[:], h)
	for obj in app.scene.objects {
		t := obj.transform
		part := Part {
			id       = i64(obj.id),
			position = t.position,
			rotation = t.rotation,
			scale    = t.scale,
			boolean  = u32(obj.boolean),
			current  = u32(obj.levels.current),
			levels   = u32(len(obj.levels.levels)),
			hd_steps = u32(obj.levels.hd.steps),
			name     = hash_bytes(transmute([]u8)obj.name, 0),
		}
		h = xxhash.XXH3_64(mem.ptr_to_bytes(&part), h)
	}
	return h
}

// XXH3 of `b` seeded with `seed`; nothing (which XXH3 refuses) hashes as no bytes do.
@(private = "file")
hash_bytes :: proc(b: []u8, seed: u64) -> u64 {
	if len(b) == 0 do return seed ~ 0x9e3779b97f4a7c15
	return xxhash.XXH3_64(b, seed)
}

// The first guard, inside the frame's scene command and file request: the thread stops
// reading before either changes anything.
autosave_settle :: proc(app: ^App) {
	a := &app.autosave
	w := a.worker
	if w == nil do return
	sync.lock(&w.lock)
	defer sync.unlock(&w.lock)
	if w.phase == .Serializing {
		start := time.tick_now()
		sync.atomic_store(&w.abort, true)
		for w.phase == .Serializing do sync.cond_wait(&w.cond, &w.lock)
		a.wait_ms = max(a.wait_ms, time.duration_milliseconds(time.tick_since(start)))
	}
	if w.phase == .Aborted {
		a.aborts += 1
		job_free(&w.job)
		w.phase = .Idle
	}
}

// The second guard, once the frame's events are read: anything but rest stops the
// thread reading.
autosave_guard :: proc(app: ^App) {
	w := app.autosave.worker
	if w == nil do return
	sync.lock(&w.lock)
	reading := w.phase == .Serializing
	sync.unlock(&w.lock)
	if reading && !autosave_quiet(app) do autosave_settle(app)
}

// At the end of each frame: takes the thread's result, and starts an autosave when one
// is due, the scene changed and the app has rested long enough (or went to the
// background).
autosave_frame :: proc(app: ^App) {
	a := &app.autosave
	if !a.on || a.worker == nil do return
	autosave_collect(app)
	now := input_clock(app)
	if !autosave_quiet(app) do a.busy_at = now
	w := a.worker
	sync.lock(&w.lock)
	idle := w.phase == .Idle
	sync.unlock(&w.lock)
	if !idle do return
	interval := autosave_interval(a)
	due := a.background || (interval > 0 && now - a.last_at >= interval && now - a.busy_at >= a.rest)
	if !due do return
	a.background = false
	fp := scene_fingerprint(app)
	if fp == a.clean do return
	autosave_start(app, fp)
}

// Hands the scene to the thread: syncs the levels (which changes them, so here on the
// frame loop) and gives it the header and the objects to write.
@(private = "file")
autosave_start :: proc(app: ^App, fp: u64) {
	a := &app.autosave
	w := a.worker
	start := time.tick_now()
	job := Autosave_Job{check = a.check}
	vertices := 0
	for obj in app.scene.objects {
		hd := object_in_hd(obj)
		if !hd do sculpt.levels_sync(&obj.levels)
		append(&job.objects, obj)
		append(&job.hd, hd)
		// By name, here on the frame loop, which owns the library the thread must not read.
		refs := object_material_refs(app, obj)
		owned := make([]Material_Refs, len(refs))
		for r, k in refs do owned[k] = {strings.clone(r.material), strings.clone(r.matcap)}
		append(&job.refs, owned)
		vertices += object_vertex_count(obj)
	}
	a.sync_ms = time.duration_milliseconds(time.tick_since(start))
	scene_header_put(app, &job.header)
	job.path = strings.clone(slot_path(a.folder, a.session, a.slot))
	sync.lock(&w.lock)
	job.info = w.info
	job.info.scene = strings.clone(w.info.scene)
	job.info.newest, job.info.at = a.slot, unix_now()
	job.info.objects, job.info.vertices = len(app.scene.objects), vertices
	w.job = job
	w.phase = .Serializing
	sync.atomic_store(&w.abort, false)
	sync.unlock(&w.lock)
	sync.sema_post(&w.wake)
	a.pending = fp
}

// Takes a finished autosave's outcome: the next slot, the clean fingerprint and the
// numbers, or a failure's toast (once until one works again).
@(private = "file")
autosave_collect :: proc(app: ^App) {
	a := &app.autosave
	w := a.worker
	sync.lock(&w.lock)
	defer sync.unlock(&w.lock)
	if w.phase != .Done && w.phase != .Failed do return
	job := &w.job
	a.serialize_ms, a.write_ms = job.serialize_ms, job.write_ms
	a.last_at = input_clock(app)
	if job.torn {
		a.torn += 1
		log.errorf("autosave: the scene changed while it was read (--check-autosave)")
	}
	if w.phase == .Done {
		a.written += 1
		a.bytes = job.bytes
		a.wall = job.info.at
		a.clean = a.pending
		a.slot = a.slot % AUTOSAVE_SLOTS + 1
		a.failed = false
		// The scene and its save time may have changed while the thread wrote: the next
		// session file says both as they are now.
		w.info.newest, w.info.at, w.info.objects, w.info.vertices = job.info.newest, job.info.at, job.info.objects, job.info.vertices
		w.info_due = true
		sync.sema_post(&w.wake)
		log.infof("autosave: %s, %d MB in %.0f + %.0f ms", filepath.base(job.path), job.bytes >> 20, job.serialize_ms, job.write_ms)
	} else {
		delete(a.error)
		a.error = strings.clone(job.error)
		if !a.failed do report(app, nil, {.Warning}, "Autosave failed: %s. Your work is not being saved automatically", job.error)
		a.failed = true
	}
	job_free(job)
	w.phase = .Idle
	if a.crash_after && a.written > 0 {
		// The kill test: gone at once, as a crash leaves the session (no clean exit, no
		// session marked closed).
		log.info("autosave: --crash-after-autosave, exiting without a clean exit")
		os.exit(3)
	}
}

// After a save, an open or a new scene: what the session file names, and the scene is
// clean as it stands. `path` is the scene's file, "" for a new scene.
autosave_scene_saved :: proc(app: ^App, path: string) {
	app.saved_fp = scene_fingerprint(app)
	// The file's own time, which a save has just set and an opened file keeps from before.
	app.saved_at = {}
	if path != "" do app.saved_at = os.modification_time_by_path(path) or_else time.now()
	a := &app.autosave
	if !a.on do return
	a.clean = scene_fingerprint(app)
	a.last_at = input_clock(app)
	w := a.worker
	if w == nil do return
	sync.lock(&w.lock)
	delete(w.info.scene)
	w.info.scene = strings.clone(path)
	w.info.saved = unix_now() if path != "" else 0
	w.info_due = true
	sync.unlock(&w.lock)
	sync.sema_post(&w.wake)
}

// The clean exit: stops what is under way, writes what changed since the last autosave
// (with the window hidden first, so the app looks closed while it does), then marks the
// session closed and keeps only its newest autosave. On a phone or tablet the
// background autosave already ran, and closing must not wait.
autosave_close :: proc(app: ^App, window: ^sdl.Window) {
	a := &app.autosave
	w := a.worker
	if w == nil do return
	autosave_settle(app)
	autosave_wait(w)
	autosave_collect(app)
	mobile := ODIN_PLATFORM_SUBTARGET != .Default
	if fp := scene_fingerprint(app); !mobile && autosave_interval(a) > 0 && fp != a.clean {
		_ = sdl.HideWindow(window)
		autosave_start(app, fp)
		autosave_wait(w)
		autosave_collect(app)
	}
	sync.lock(&w.lock)
	info := w.info
	info.scene = strings.clone(w.info.scene, context.temp_allocator)
	sync.unlock(&w.lock)
	for k in 1 ..= AUTOSAVE_SLOTS do if k != info.newest do _ = os.remove(slot_path(a.folder, a.session, k))
	session := session_path(a.folder, a.session)
	if info.newest == 0 {
		_ = os.remove(session)
		return
	}
	info.closed = unix_now()
	info.alive = info.closed
	_ = session_write(session, info)
}

// Whether an autosave is being written to the disk (the scene is no longer read).
autosave_writing :: proc(app: ^App) -> bool {
	w := app.autosave.worker
	if w == nil do return false
	sync.lock(&w.lock)
	defer sync.unlock(&w.lock)
	return w.phase == .Writing
}

// Waits for the thread to finish what it is doing.
@(private = "file")
autosave_wait :: proc(w: ^Autosave_Worker) {
	sync.lock(&w.lock)
	for w.phase == .Serializing || w.phase == .Writing do sync.cond_wait(&w.cond, &w.lock)
	sync.unlock(&w.lock)
}

@(private = "file")
job_free :: proc(job: ^Autosave_Job) {
	delete(job.header)
	delete(job.objects)
	delete(job.hd)
	for list in job.refs {
		for r in list {
			delete(r.material)
			delete(r.matcap)
		}
		delete(list)
	}
	delete(job.refs)
	delete(job.path)
	delete(job.info.scene)
	delete(job.error)
	job^ = {}
}

// The thread: waits for a job or the heartbeat, writes the scene, and keeps the session
// file saying the run is alive.
@(private = "file")
autosave_thread :: proc(data: rawptr) {
	w := cast(^Autosave_Worker)data
	// Temp memory of its own: the context came from the frame loop, whose temp allocator
	// is that thread's.
	arena: runtime.Arena
	context.temp_allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)
	beat := time.tick_now()
	for {
		_ = sync.sema_wait_with_timeout(&w.wake, AUTOSAVE_HEARTBEAT * time.Second)
		sync.lock(&w.lock)
		quit, run := w.quit, w.phase == .Serializing
		due := w.info_due || time.duration_seconds(time.tick_since(beat)) >= AUTOSAVE_HEARTBEAT
		info := w.info
		info.scene = strings.clone(w.info.scene, context.temp_allocator)
		w.info_due = false
		sync.unlock(&w.lock)
		if quit do return
		if run {
			autosave_run(w)
			beat = time.tick_now()
		} else if due && info.newest > 0 {
			// Only a session with an autosave has anything to say.
			info.alive = unix_now()
			_ = session_write(session_path(w.folder, w.session), info)
			beat = time.tick_now()
		}
		runtime.arena_free_all(&arena)
	}
}

// One autosave: the scene into a buffer (stopping once asked), then the buffer to the
// slot's file, then the session file.
@(private = "file")
autosave_run :: proc(w: ^Autosave_Worker) {
	job := &w.job
	start := time.tick_now()
	out := make([dynamic]u8)
	defer delete(out)
	append(&out, ..job.header[:])
	before := read_hash(job) if job.check else 0
	ok := true
	for obj, i in job.objects {
		ok = object_put_bytes(&out, obj, {serial = true, abort = &w.abort, synced = true, hd_open = job.hd[i]}, job.refs[i])
		free_all(context.temp_allocator)
		if !ok do break
	}
	if ok && job.check do job.torn = read_hash(job) != before
	job.serialize_ms = time.duration_milliseconds(time.tick_since(start))
	sync.lock(&w.lock)
	w.phase = .Writing if ok else .Aborted
	sync.cond_broadcast(&w.cond)
	sync.unlock(&w.lock)
	if !ok do return
	// The scene is the frame loop's again: from here only the buffer is read.
	start = time.tick_now()
	job.bytes = len(out)
	err := write_durably(job.path, out[:])
	if err == "" {
		job.info.alive = unix_now()
		if session_write(session_path(w.folder, w.session), job.info) != nil do err = "cannot write the session file"
	}
	job.write_ms = time.duration_milliseconds(time.tick_since(start))
	sync.lock(&w.lock)
	if err != "" do job.error = strings.clone(err)
	w.phase = .Done if err == "" else .Failed
	sync.cond_broadcast(&w.cond)
	sync.unlock(&w.lock)
}

// A hash of every object's positions, triangles and node sizes, for --check-autosave:
// the same before and after reading means nothing changed under the thread.
@(private = "file")
read_hash :: proc(job: ^Autosave_Job) -> u64 {
	h: u64
	for obj in job.objects {
		for lv in obj.levels.levels {
			h = hash_bytes(slice.to_bytes(lv.mesh.positions[:]), h)
			h = hash_bytes(slice.to_bytes(lv.mesh.indices[:]), h)
			for n in lv.sculptor.nodes do h = xxhash.XXH3_64(mem.ptr_to_bytes(&[2]u32{n.tri_count, n.vert_count}), h)
		}
		if vp := obj.voxel; vp != nil do h = xxhash.XXH3_64(mem.ptr_to_bytes(&[1]u64{voxel.clay_hash(&vp.clay)}), h)
	}
	return h
}

session_path :: proc(folder, session: string) -> string {
	return strings.concatenate({folder, session, SESSION_EXT}, context.temp_allocator)
}

slot_path :: proc(folder, session: string, slot: int) -> string {
	return fmt.aprintf("%s%s-%d%s", folder, session, slot, SLOT_EXT, allocator = context.temp_allocator)
}

unix_now :: proc() -> i64 {return time.time_to_unix(time.now())}

// The session file's text.
session_text :: proc(info: Session_Info, allocator := context.allocator) -> string {
	return fmt.aprintf("%s\npid %d\nstarted %d\nalive %d\nsaved %d\nnewest %d %d %d %d\nclosed %d\nscene %s\n", SESSION_MAGIC, info.pid, info.started, info.alive, info.saved,
		info.newest, info.at, info.objects, info.vertices, info.closed, info.scene, allocator = allocator)
}

// Reads a session file's text; lines it does not know are skipped, and a text without
// the first line is refused. The scene's path is in `allocator`.
session_parse :: proc(text: string, allocator := context.allocator) -> (info: Session_Info, ok: bool) {
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if first {
			if strings.trim_space(line) != SESSION_MAGIC do return {}, false
			first = false
			continue
		}
		key, _, value := strings.partition(line, " ")
		number :: proc(s: string) -> i64 {
			v, _ := strconv.parse_i64(strings.trim_space(s))
			return max(v, 0)
		}
		switch key {
		case "pid":     info.pid = int(number(value))
		case "started": info.started = number(value)
		case "alive":   info.alive = number(value)
		case "saved":   info.saved = number(value)
		case "closed":  info.closed = number(value)
		case "scene":   info.scene = strings.clone(value, allocator)
		case "newest":
			parts := strings.fields(value, context.temp_allocator)
			if len(parts) == 4 {
				info.newest = clamp(int(number(parts[0])), 0, AUTOSAVE_SLOTS)
				info.at = number(parts[1])
				info.objects = int(number(parts[2]))
				info.vertices = int(number(parts[3]))
			}
		}
	}
	return info, !first
}

// Writes a session file through .partial and a rename, so a kill mid-write leaves the
// last one whole.
session_write :: proc(path: string, info: Session_Info) -> os.Error {
	text := session_text(info, context.temp_allocator)
	partial := strings.concatenate({path, ".partial"}, context.temp_allocator)
	if err := os.write_entire_file(partial, transmute([]u8)text); err != nil do return err
	return os.rename(partial, path)
}

// One earlier session found in the folder: its file's contents (when it has one) and
// its autosaves, newest first.
@(private = "file")
Found_Session :: struct {
	name:  string,
	info:  Session_Info,
	has_info: bool,
	slots: [dynamic]Found_Slot,
}

@(private = "file")
Found_Slot :: struct {
	path: string,
	at:   i64, // modification time, unix nanoseconds
}

// Every session in the folder but this run's, newest autosave first within each. In
// the temp allocator.
@(private = "file")
sessions_found :: proc(app: ^App) -> []Found_Session {
	a := &app.autosave
	infos, err := os.read_directory_by_path(a.folder, -1, context.temp_allocator)
	if err != nil do return nil
	found := make([dynamic]Found_Session, context.temp_allocator)
	find :: proc(found: ^[dynamic]Found_Session, name: string) -> ^Found_Session {
		for &f in found do if f.name == name do return &f
		append(found, Found_Session{name = name, slots = make([dynamic]Found_Slot, context.temp_allocator)})
		return &found[len(found) - 1]
	}
	for fi in infos {
		name := fi.name
		switch {
		case strings.has_suffix(name, SESSION_EXT):
			session := strings.trim_suffix(name, SESSION_EXT)
			if session == a.session do continue
			data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if rerr != nil do continue
			f := find(&found, session)
			f.info, f.has_info = session_parse(string(data), context.temp_allocator)
		case strings.has_suffix(name, SLOT_EXT):
			base := strings.trim_suffix(name, SLOT_EXT)
			dash := strings.last_index_byte(base, '-')
			if dash <= 0 do continue
			slot, sok := strconv.parse_int(base[dash + 1:])
			if !sok || slot < 1 || slot > AUTOSAVE_SLOTS || base[:dash] == a.session do continue
			f := find(&found, base[:dash])
			append(&f.slots, Found_Slot{fi.fullpath, time.time_to_unix_nano(fi.modification_time)})
		}
	}
	for &f in found do slice.sort_by(f.slots[:], proc(x, y: Found_Slot) -> bool {return x.at > y.at})
	return found[:]
}

// An earlier session's newest autosave, as the Home screen's Autosaves lists it.
Autosave_Entry :: struct {
	session: string,
	path:    string, // the newest autosave
	scene:   string, // the scene's own file, "" for none
	at:      i64, // unix seconds it was made
	crashed: bool, // the session never closed: its last save may not hold this work
}

// Every earlier session with an autosave, newest first, leaving out copies of the app
// still running. In the temp allocator.
autosave_entries :: proc(app: ^App) -> []Autosave_Entry {
	if !app.autosave.on do return nil
	now := unix_now()
	out := make([dynamic]Autosave_Entry, context.temp_allocator)
	for f in sessions_found(app) {
		if len(f.slots) == 0 || session_alive(f, now) do continue
		append(&out, Autosave_Entry{f.name, f.slots[0].path, f.info.scene, f.slots[0].at / 1e9, !f.has_info || f.info.closed == 0})
	}
	// The session's name breaks a tie, so the folder's order never decides it.
	slice.sort_by(out[:], proc(x, y: Autosave_Entry) -> bool {return x.at > y.at || (x.at == y.at && x.session > y.session)})
	return out[:]
}

// Whether a session is another copy of the app still running: its process is there and
// runs this app (a crash's number may since have gone to some other program). Where the
// system will not say, a session that said it was alive lately counts as alive. A phone
// or tablet runs one copy at a time, so there every session not closed crashed.
@(private = "file")
session_alive :: proc(f: Found_Session, now: i64) -> bool {
	if !f.has_info || f.info.closed > 0 do return false
	when ODIN_PLATFORM_SUBTARGET != .Default do return false
	if f.info.pid <= 0 do return now - f.info.alive < AUTOSAVE_ALIVE
	if f.info.pid == os.get_pid() do return true
	theirs, ok := process_exe(f.info.pid)
	if !ok do return false
	mine, _ := process_exe(os.get_pid())
	return theirs == mine
}

// The base name of a process's program, in the temp allocator; false when there is no
// such process (or the system will not say).
@(private = "file")
process_exe :: proc(pid: int) -> (name: string, ok: bool) {
	info, err := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator)
	defer os.free_process_info(info, context.temp_allocator)
	if err != nil || .Executable_Path not_in info.fields do return "", false
	return strings.clone(filepath.base(info.executable_path), context.temp_allocator), true
}

// Deletes a session's files.
@(private = "file")
session_delete :: proc(folder: string, f: Found_Session) {
	for s in f.slots do _ = os.remove(s.path)
	_ = os.remove(session_path(folder, f.name))
}

// At the start: leftover .partial files go; sessions that ended cleanly beyond the
// newest few go; a crash with nothing newer than its last save goes; the other crashes
// become the recovery card's offers, newest first. A crash is never deleted unasked.
@(private = "file")
autosave_prune :: proc(app: ^App) {
	a := &app.autosave
	if infos, err := os.read_directory_by_path(a.folder, -1, context.temp_allocator); err == nil {
		for fi in infos do if strings.has_suffix(fi.name, ".partial") do _ = os.remove(fi.fullpath)
	}
	now := unix_now()
	found := sessions_found(app)
	closed := make([dynamic]Found_Session, context.temp_allocator)
	for f in found {
		switch {
		case session_alive(f, now):
		case f.has_info && f.info.closed > 0:
			append(&closed, f)
		case len(f.slots) == 0:
			session_delete(a.folder, f)
		case f.has_info && f.slots[0].at / 1e9 <= f.info.saved:
			// Saved after its newest autosave: the crash lost nothing an autosave held.
			session_delete(a.folder, f)
		case:
			info := f.info
			info.scene = strings.clone(f.info.scene)
			append(&a.offers, Recover_Offer{strings.clone(f.name), info, f.slots[0].at / 1e9})
		}
	}
	slice.sort_by(closed[:], proc(x, y: Found_Session) -> bool {return x.info.closed > y.info.closed})
	for f, i in closed do if i >= AUTOSAVE_CLOSED_KEPT do session_delete(a.folder, f)
	slice.sort_by(a.offers[:], proc(x, y: Recover_Offer) -> bool {return x.at > y.at})
}

@(private = "file")
offer_free :: proc(o: Recover_Offer) {
	delete(o.session)
	delete(o.info.scene)
}

// Drops the offer for `session` from the card's list.
@(private = "file")
offer_drop :: proc(app: ^App, session: string) {
	a := &app.autosave
	for o, i in a.offers {
		if o.session != session do continue
		offer_free(o)
		ordered_remove(&a.offers, i)
		return
	}
}

// Opens an earlier session's newest autosave that opens (`session`, or the newest of any
// when ""), as Open does, and takes it into this session, so a second crash still finds
// it. The scene's own file stays where Save goes. Returns false only on a GPU failure.
autosave_recover :: proc(app: ^App, session: string) -> bool {
	a := &app.autosave
	if !a.on {
		report(app, nil, {.Warning}, "This run keeps no autosaves")
		return true
	}
	now := unix_now()
	found := sessions_found(app)
	pick: ^Found_Session
	for &f in found {
		if len(f.slots) == 0 || (session != "" && f.name != session) do continue
		if pick == nil || f.slots[0].at > pick.slots[0].at do pick = &f
	}
	if pick == nil {
		offer_drop(app, session)
		report(app, nil, {.Warning}, "No autosave from an earlier session")
		return true
	}
	// Checked again now: the card may have waited while another copy of the app wrote.
	if session_alive(pick^, now) {
		offer_drop(app, pick.name)
		report(app, nil, {.Warning}, "That autosave belongs to a copy of Sculpt that is still running")
		return true
	}
	// Opening a scene frees the temp memory the folder was listed into: what is needed
	// after it is kept here.
	name, scene := strings.clone(pick.name), strings.clone(pick.info.scene)
	defer delete(name)
	defer delete(scene)
	saved := pick.info.saved
	slots := make([]Found_Slot, len(pick.slots))
	defer {
		for s in slots do delete(s.path)
		delete(slots)
	}
	for s, i in pick.slots do slots[i] = {strings.clone(s.path), s.at}
	for s in slots {
		opened, ok := scene_open(app, s.path)
		if !ok do return false
		if !opened do continue
		mine := slot_path(a.folder, a.session, 1)
		if err := os.rename(s.path, mine); err != nil do log.warnf("autosave: cannot keep %s as %s: %v", s.path, mine, err)
		for other in slots do if other.path != s.path do _ = os.remove(other.path)
		_ = os.remove(session_path(a.folder, name))
		scene_remember_path(app, scene)
		// The recovered scene is in this session's first slot: clean until it changes,
		// and the next autosave goes to the second.
		autosave_scene_saved(app, scene)
		// Recovered work is in no scene file yet: a New scene or an earlier save asks first.
		app.saved_fp = 0
		vertices := 0
		for obj in app.scene.objects do vertices += object_vertex_count(obj)
		w := a.worker
		sync.lock(&w.lock)
		w.info.saved = saved
		w.info.newest, w.info.at = 1, s.at / 1e9
		w.info.objects, w.info.vertices = len(app.scene.objects), vertices
		w.info_due = true
		sync.unlock(&w.lock)
		sync.sema_post(&w.wake)
		a.slot = 2
		a.recovered += 1
		offer_drop(app, name)
		report(app, nil, {}, "Recovered your work from %s. Save to keep it", wall_ago(s.at / 1e9))
		return true
	}
	offer_drop(app, name)
	report(app, nil, {.Warning}, "The autosaves of that session could not be opened")
	return true
}

// Deletes an earlier session's autosaves (the card's Discard), unless it turned out to
// be alive.
autosave_discard :: proc(app: ^App, session: string) {
	a := &app.autosave
	defer offer_drop(app, session)
	for f in sessions_found(app) {
		if f.name != session do continue
		if session_alive(f, unix_now()) {
			report(app, nil, {.Warning}, "That autosave belongs to a copy of Sculpt that is still running")
			return
		}
		session_delete(a.folder, f)
		report(app, nil, {}, "Deleted the autosave")
		return
	}
}

// "3 minutes ago" for a unix time.
wall_ago :: proc(at: i64) -> string {
	s := max(unix_now() - at, 0)
	switch {
	case s < 60:    return "less than a minute ago"
	case s < 120:   return "a minute ago"
	case s < 3600:  return fmt.tprintf("%d minutes ago", s / 60)
	case s < 7200:  return "an hour ago"
	case s < 86400: return fmt.tprintf("%d hours ago", s / 3600)
	}
	return fmt.tprintf("%d days ago", s / 86400)
}

// The line under Settings > System's select.
autosave_status :: proc(app: ^App) -> string {
	a := &app.autosave
	b := strings.builder_make(context.temp_allocator)
	switch {
	case !a.on:
		strings.write_string(&b, "This run keeps no autosaves.")
	case autosave_interval(a) == 0:
		strings.write_string(&b, "Off: if Sculpt closes unexpectedly, the work since the last save is lost.")
	case a.failed:
		fmt.sbprintf(&b, "The last autosave failed: %s.", a.error)
	case a.written > 0:
		// A small scene's autosave takes milliseconds, which tenths of a second would show as none.
		ms := a.serialize_ms + a.write_ms
		took := fmt.tprintf("%.0f ms", ms) if ms < 1000 else fmt.tprintf("%.1f s", ms / 1000)
		fmt.sbprintf(&b, "Autosaved %s: %s in %s.", wall_ago(a.wall), bytes_label(a.bytes), took)
	case:
		strings.write_string(&b, "Nothing to autosave yet.")
	}
	for obj in app.scene.objects {
		if object_in_hd(obj) {
			strings.write_string(&b, " Work inside an HD window is not autosaved.")
			break
		}
	}
	return strings.to_string(b)
}
