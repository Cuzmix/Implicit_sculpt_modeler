package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Big undo copies on disk (the dense remesh plan's PR 4): a rebuild's copy of the object
// (a swap snapshot, history.odin) of UNDO_DISK_MIN or more is written to a file of its own
// on a thread, and once it is there its bytes leave memory; undoing or redoing that step
// reads it back first. ZBrush spills its undo to a scratch disk the same way, which is what
// lets it keep the steps of a dense mesh; Nomad and Blender keep them in memory and drop
// them. A 25M remesh's copy is about 1 GB, a sixth of what an 8 GB iPad gives the app.
//
// The copy is written as it is, not compressed: it is mostly positions, which LZ4 barely
// shrinks, and a thread compressing a gigabyte would take a core from the sculpting that
// follows a remesh. The thread only reads the snapshot's bytes, which nothing changes
// until the step is undone, redone or dropped, and each of those waits for it first
// (undo_disk_settle). One copy is written at a time, the oldest step first, since the
// newest is the likeliest to be undone next.
//
// Each run writes into a folder of its own, `undo/<pid>` beside the settings, so two
// copies of the app never share one; the files go as their steps do and the folder goes
// when the run ends. A folder a crashed run left is deleted at the next start.

// The smallest copy that goes to disk: below it the read back would cost more than the
// memory it gives back is worth.
UNDO_DISK_MIN :: 64 << 20

UNDO_DISK_FOLDER :: "undo"

// A snapshot's copy being written to `path` on a thread.
Undo_Disk_Write :: struct {
	thread: ^thread.Thread,
	bytes:  []u8, // the snapshot's own, read only while the thread runs
	path:   string, // owned
	done:   bool, // atomic
	ok:     bool,
	ms:     f64,
}

// The undo copies on disk this run: where they go ("" when nothing goes to disk) and what
// it did, for the exit stats.
Undo_Disk :: struct {
	folder:  string, // owned, ending in a separator
	min:     int, // the smallest copy written, 0 for UNDO_DISK_MIN (a test sets a small one)
	serial:  int,
	written: int,
	reads:   int,
	failed:  int,
	write_ms, read_ms: f64,
}

// At the start, after the settings: the run's own folder, and any a crashed run left
// deleted. Not on the web (no threads, and the files would be the page's memory), nor when
// the system gives no folder.
undo_disk_init :: proc(app: ^App) {
	when ODIN_OS == .JS do return
	pref := platform_folder()
	if pref == "" do return
	root := strings.concatenate({pref, UNDO_DISK_FOLDER}, context.temp_allocator)
	mine := os.get_pid()
	if infos, err := os.read_all_directory_by_path(root, context.temp_allocator); err == nil {
		for fi in infos {
			pid, ok := strconv.parse_int(fi.name)
			if !ok || pid == mine || undo_disk_run_alive(pid) do continue
			_ = os.remove_all(fi.fullpath)
			log.infof("undo disk: deleted %s, left by a run that ended", fi.fullpath)
		}
	}
	folder := fmt.tprintf("%s%s%d%s", root, filepath.SEPARATOR_STRING, mine, filepath.SEPARATOR_STRING)
	if err := os.make_directory_all(folder); err != nil && !os.is_dir(folder) {
		log.warnf("undo disk: cannot make %s (%v); undo copies stay in memory", folder, err)
		return
	}
	app.undo_disk.folder = strings.clone(folder)
}

// Whether a run of this app with process id `pid` is still going, so its folder stays.
@(private = "file")
undo_disk_run_alive :: proc(pid: int) -> bool {
	info, err := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator)
	defer os.free_process_info(info, context.temp_allocator)
	if err != nil || .Executable_Path not_in info.fields do return false
	mine, merr := os.process_info_by_pid(os.get_pid(), {.Executable_Path}, context.temp_allocator)
	defer os.free_process_info(mine, context.temp_allocator)
	if merr != nil do return false
	return filepath.base(info.executable_path) == filepath.base(mine.executable_path)
}

// When the run ends, after the History is gone (whose snapshots deleted their files).
undo_disk_destroy :: proc(app: ^App) {
	d := &app.undo_disk
	if d.folder != "" do _ = os.remove_all(d.folder)
	delete(d.folder)
	d.folder = ""
}

// Once a frame from history_cap: a finished write lets its copy go from memory; then, when
// no stroke, drag or job is under way, the oldest big copy still in memory starts writing.
undo_disk_frame :: proc(app: ^App) {
	d := &app.undo_disk
	h := &app.history
	writing := false
	for list in ([2]^[dynamic]History_Entry{&h.done, &h.undone}) {
		for e in list {
			s := e.swap
			if s == nil || s.disk == nil do continue
			if !sync.atomic_load(&s.disk.done) {
				writing = true
				continue
			}
			undo_disk_settle(s, d)
		}
	}
	if writing || d.folder == "" || history_busy(app) || long_job_busy(app) do return
	for list in ([2]^[dynamic]History_Entry{&h.done, &h.undone}) {
		for e in list {
			if s := e.swap; s != nil && s.file == "" && s.size >= (d.min if d.min > 0 else UNDO_DISK_MIN) && len(s.bytes) == s.size {
				undo_disk_start(d, s)
				return
			}
		}
	}
}

// Starts writing `snap`'s copy to a new file of the run's folder.
@(private = "file")
undo_disk_start :: proc(d: ^Undo_Disk, snap: ^Object_Snapshot) {
	d.serial += 1
	w := new(Undo_Disk_Write)
	w.bytes = snap.bytes[:]
	w.path = fmt.aprintf("%s%d.swap", d.folder, d.serial)
	snap.disk = w
	w.thread = thread.create_and_start_with_data(w, undo_disk_thread, context, .Low, name = "undo disk")
}

@(private = "file")
undo_disk_thread :: proc(data: rawptr) {
	w := cast(^Undo_Disk_Write)data
	start := time.tick_now()
	err := os.write_entire_file(w.path, w.bytes)
	w.ok = err == nil
	if !w.ok do log.warnf("undo disk: could not write %s (%v); the copy stays in memory", w.path, err)
	w.ms = time.duration_milliseconds(time.tick_since(start))
	sync.atomic_store(&w.done, true)
}

// Waits for `snap`'s write if one runs, then takes its result: written, the copy's bytes
// leave memory and the file holds them; not, the file goes and the bytes stay. `d` counts
// it (nil when the History is being freed and no one reads the counts).
undo_disk_settle :: proc(snap: ^Object_Snapshot, d: ^Undo_Disk = nil) {
	w := snap.disk
	if w == nil do return
	thread.join(w.thread)
	thread.destroy(w.thread)
	snap.disk = nil
	if w.ok {
		delete(snap.bytes)
		snap.bytes = nil
		snap.file = w.path
		if d != nil {
			d.written += 1
			d.write_ms += w.ms
		}
		log.infof("undo disk: %s of %s in %s (%.0f ms)", bytes_label(snap.size), snap.what, filepath.base(w.path), w.ms)
	} else {
		_ = os.remove(w.path)
		delete(w.path)
		if d != nil do d.failed += 1
	}
	free(w)
}

// Brings `snap`'s copy back into memory from its file before it is read, and deletes the
// file: false when it cannot be read whole, and the step cannot be undone.
undo_disk_load :: proc(app: ^App, snap: ^Object_Snapshot) -> bool {
	undo_disk_settle(snap, &app.undo_disk)
	if snap.file == "" do return true
	start := time.tick_now()
	data, err := os.read_entire_file(snap.file, context.allocator)
	if err != nil || len(data) != snap.size {
		log.errorf("undo disk: could not read %s back (%v, %d of %d bytes)", snap.file, err, len(data), snap.size)
		delete(data)
		app.undo_disk.failed += 1
		return false
	}
	_ = os.remove(snap.file)
	delete(snap.file)
	snap.file = ""
	raw := runtime.Raw_Dynamic_Array{data = raw_data(data), len = len(data), cap = len(data), allocator = context.allocator}
	snap.bytes = transmute([dynamic]u8)raw
	ms := time.duration_milliseconds(time.tick_since(start))
	app.undo_disk.reads += 1
	app.undo_disk.read_ms += ms
	log.infof("undo disk: read %s of %s back in %.0f ms", bytes_label(snap.size), snap.what, ms)
	return true
}

// The bytes of the History's copies that are on disk, not in memory.
history_disk_bytes :: proc(h: ^History) -> int {
	n := 0
	for list in ([2]^[dynamic]History_Entry{&h.done, &h.undone}) {
		for e in list do if e.swap != nil && e.swap.file != "" do n += e.swap.size
	}
	return n
}
