package main

import "core:log"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"

// Scene-wide undo order. Each level of each object keeps its own strokes; this records
// which object and level each stroke belongs to, newest last, so Ctrl+Z walks back
// across objects and levels. Undoing a stroke made on another level first switches the
// object to that level, as ZBrush does: strokes come back newest first on every level,
// which keeps the levels consistent with each other.
History :: struct {
	done:   [dynamic]History_Entry,
	undone: [dynamic]History_Entry,
	// What the snapshots of every swap entry in both lists take, for the limit.
	swap_bytes: int,
}

History_Entry :: struct {
	id:    int, // object
	level: int, // or HD_LEVEL: the object's HD window
	// Set for a change a stroke's undo cannot take back, because it rebuilds the object
	// or adds or removes it (remesh, dynamic topology on or off, deleting levels, adding
	// or deleting the object): the object as it was on the other side of the change.
	swap:  ^Object_Snapshot,
}

// An object as object_put writes it, or that it did not exist. Undoing or redoing a swap
// entry trades the live object for its snapshot and keeps the live one in its place, so
// the same entry goes back and forth.
Object_Snapshot :: struct {
	exists: bool,
	index:  int, // where in the scene's list the object was
	bytes:  [dynamic]u8,
	what:   string, // the change, for the log and the Edit menu (not owned)
}

HD_LEVEL :: -1

// Swap snapshots above this many bytes in all drop the oldest ones (never the newest).
// A snapshot costs about 37 bytes a base vertex plus 12 a vertex of each level above, so
// a 10M-vertex object takes about 370 MB.
SWAP_LIMIT_BYTES :: 1536 << 20

history_destroy :: proc(h: ^History) {
	history_clear(h)
	delete(h.done)
	delete(h.undone)
	h^ = {}
}

// Drops every entry, freeing the snapshots.
history_clear :: proc(h: ^History) {
	for list in ([2]^[dynamic]History_Entry{&h.done, &h.undone}) {
		for e in list do snapshot_free(e.swap)
		clear(list)
	}
	h.swap_bytes = 0
}

@(private = "file")
snapshot_free :: proc(snap: ^Object_Snapshot) {
	if snap == nil do return
	delete(snap.bytes)
	free(snap)
}

// The object as it is now, before a change that rebuilds, adds or removes it; nil for
// an object that does not exist yet. Pass it to history_record_swap once the change has
// happened, or to history_snapshot_drop if it did not.
history_snapshot :: proc(app: ^App, obj: ^Object, what: string) -> ^Object_Snapshot {
	snap := new(Object_Snapshot)
	snap.what = what
	if obj == nil do return snap
	snap.exists = true
	for o, i in app.scene.objects do if o == obj do snap.index = i
	object_put(app, &snap.bytes, obj)
	return snap
}

history_snapshot_drop :: proc(snap: ^Object_Snapshot) {snapshot_free(snap)}

// Lists a change to object `id` that `before` (from history_snapshot) undoes as the
// newest undo step. The object's strokes from before it are dropped, since the sculptors
// they were made with are gone.
history_record_swap :: proc(app: ^App, id: int, before: ^Object_Snapshot) {
	history_drop_redo(app)
	history_forget_strokes(app, id)
	append(&app.history.done, History_Entry{id = id, swap = before})
	app.history.swap_bytes += len(before.bytes)
	// Over the limit, the oldest snapshots go, with every entry older than them, since
	// undo cannot skip a swap; strokes older than a swap are dropped anyway, so the
	// only older entries are other objects' strokes.
	h := &app.history
	for h.swap_bytes > SWAP_LIMIT_BYTES {
		oldest := -1
		for e, i in h.done do if e.swap != nil {oldest = i; break}
		if oldest < 0 || oldest == len(h.done) - 1 do break
		// The strokes among them stay in their sculptors, out of reach, until the
		// sculptors' own limit drops them.
		h.swap_bytes -= len(h.done[oldest].swap.bytes)
		snapshot_free(h.done[oldest].swap)
		remove_range(&h.done, 0, oldest + 1)
	}
}

// Lists adding the selected object, the one just added, as the newest undo step.
history_record_added :: proc(app: ^App) {
	if obj := selected_object(app); obj != nil do history_record_swap(app, obj.id, history_snapshot(app, nil, "add object"))
}

// What Ctrl+Z would take back, for the Edit menu.
history_next_label :: proc(list: []History_Entry) -> string {
	if len(list) == 0 do return "stroke"
	if e := list[len(list) - 1]; e.swap != nil do return e.swap.what
	return "stroke"
}

// Ends the brush stroke in progress, if any, and records it when it changed the mesh.
stroke_finish :: proc(app: ^App) {
	if !app.stroke.active do return
	app.stroke.active = false
	obj := object_by_id(app, app.stroke.object)
	if obj == nil do return
	sculpt.sculptor_grab_end(object_sculptor(obj))
	if sculpt.sculptor_stroke_end(object_sculptor(obj)) do history_record(app, obj)
}

// Applies a mask command to the selected object as an undo step of its own; Blur,
// Sharpen, Grow and Shrink take the Mask section's step count. What it did and how long
// it took show in the Mask section, since many steps on a large mesh take a moment.
mask_command :: proc(app: ^App, command: sculpt.Mask_Command) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	start := time.tick_now()
	steps := int(max(app.ui.mask_steps, 1))
	changed := sculpt.sculptor_mask_command(object_sculptor(obj), command, steps)
	app.ui.mask_last = {command = command, steps = steps, ms = time.duration_milliseconds(time.tick_since(start)), changed = changed, set = true}
	if changed do history_record(app, obj)
}

// Masks (or unmasks) what of the selected object falls inside `shape`, a polygon in
// normalized device coordinates, as an undo step of its own (sculpt.sculptor_mask_shape).
mask_shape_command :: proc(app: ^App, shape: [][2]f32, size: [2]f32, unmask: bool) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	start := time.tick_now()
	front: sculpt.Front_Only
	if app.brush.front_only {
		t := obj.transform
		front = {
			on       = true,
			parallel = app.camera.ortho,
			eye      = to_local(t, camera.orbit_eye(app.camera)),
			toward   = to_local_dir(t, -camera.orbit_toward(app.camera, app.camera.target)),
		}
	}
	changed := sculpt.sculptor_mask_shape(object_sculptor(obj), object_clip(app, obj, size), shape, unmask, front)
	app.ui.mask_last = {command = .Fill if !unmask else .Clear, ms = time.duration_milliseconds(time.tick_since(start)), changed = changed, set = true, shape = true}
	if changed do history_record(app, obj)
}

// Lists the stroke (or mask command) the object's current sculptor just finished as
// the newest undo step.
@(private = "file")
history_record :: proc(app: ^App, obj: ^Object) {
	history_drop_redo(app)
	append(&app.history.done, History_Entry{id = obj.id, level = HD_LEVEL if object_in_hd(obj) else obj.levels.current})
}

// A new step discards everything that could have been redone, everywhere.
@(private = "file")
history_drop_redo :: proc(app: ^App) {
	for e in app.history.undone {
		if e.swap != nil {
			app.history.swap_bytes -= len(e.swap.bytes)
			snapshot_free(e.swap)
		} else if s := entry_sculptor(app, e); s != nil {
			sculpt.sculptor_clear_redo(s)
		}
	}
	clear(&app.history.undone)
}

history_can_undo :: proc(app: ^App) -> bool {return !app.stroke.active && len(app.history.done) > 0}
history_can_redo :: proc(app: ^App) -> bool {return !app.stroke.active && len(app.history.undone) > 0}

history_undo :: proc(app: ^App) {
	history_step(app, &app.history.done, &app.history.undone, sculpt.sculptor_can_undo, sculpt.sculptor_undo)
}

history_redo :: proc(app: ^App) {
	history_step(app, &app.history.undone, &app.history.done, sculpt.sculptor_can_redo, sculpt.sculptor_redo)
}

@(private = "file")
history_step :: proc(app: ^App, from, to: ^[dynamic]History_Entry, can, step: proc(s: ^sculpt.Sculptor) -> bool) {
	if app.stroke.active do return
	// Entries whose step a sculptor already dropped (memory limit) are skipped.
	for len(from) > 0 {
		e := pop(from)
		if e.swap != nil {
			if !history_swap(app, e) do app.running = false // GPU failure
			append(to, e)
			return
		}
		s := entry_sculptor(app, e)
		if s == nil || !can(s) do continue
		// A stroke from outside HD leaves the window first; one inside it is only listed
		// while the window is open.
		if e.level != HD_LEVEL && !object_set_level(app, object_by_id(app, e.id), e.level) do app.running = false // GPU failure
		_ = step(s)
		append(to, e)
		return
	}
}

// The sculptor an entry's stroke was made with, or nil if it is gone.
@(private = "file")
entry_sculptor :: proc(app: ^App, e: History_Entry) -> ^sculpt.Sculptor {
	obj := object_by_id(app, e.id)
	switch {
	case obj == nil:
		return nil
	case e.level == HD_LEVEL:
		return &obj.levels.hd.window.sculptor if object_in_hd(obj) else nil
	case e.level >= len(obj.levels.levels):
		return nil
	}
	return &obj.levels.levels[e.level].sculptor
}

// Trades the object the entry names, as it is now, for the entry's snapshot, and keeps
// what it was in the snapshot instead, so the entry can go back the other way. Returns
// false only on a GPU failure.
@(private = "file")
history_swap :: proc(app: ^App, e: History_Entry) -> bool {
	snap := e.swap
	start := time.tick_now()
	stroke_finish(app)
	app.move.drag = {}
	obj := object_by_id(app, e.id)
	live := history_snapshot(app, obj, snap.what)
	defer snapshot_free(live)
	restored: ^Object
	if snap.exists {
		r := geom.byte_reader(snap.bytes[:])
		read, made: bool
		restored, read, made = object_get(app, &r)
		if !read {
			// Written by this run a moment ago; only running out of memory gets here.
			log.errorf("undo: could not rebuild object %d", e.id)
			return true
		}
		if !made {
			_ = sdl.WaitForGPUIdle(app.renderer.device)
			object_discard(app, restored)
			return false
		}
	}
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	history_forget_strokes(app, e.id)
	scene := &app.scene
	if obj != nil {
		index := live.index
		ordered_remove(&scene.objects, index)
		object_free(app, obj)
		scene.selected = min(scene.selected, len(scene.objects) - 1)
	}
	if restored != nil {
		index := clamp(snap.index, 0, len(scene.objects))
		inject_at(&scene.objects, index, restored)
		scene.selected = index
	}
	app.history.swap_bytes += len(live.bytes) - len(snap.bytes)
	snap.exists, snap.index = live.exists, live.index
	snap.bytes, live.bytes = live.bytes, snap.bytes
	render.viewport_invalidate(&app.target)
	log.infof("swap: %s on object %d in %.0f ms", snap.what, e.id, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Drops an object's entries, when its sculptors (and so its strokes) go away.
history_forget :: proc(app: ^App, id: int) {
	history_forget_level(app, id, nil)
}

// Drops an object's strokes on every level but keeps its swap entries, which hold the
// whole object and so stay right whatever happened to its sculptors.
history_forget_strokes :: proc(app: ^App, id: int) {
	for list in ([2]^[dynamic]History_Entry{&app.history.done, &app.history.undone}) {
		kept := 0
		for e in list {
			if e.id != id || e.swap != nil {
				list[kept] = e
				kept += 1
			}
		}
		resize(list, kept)
	}
}

// Drops an object's entries on one level (all levels when nil): for the HD window,
// whose strokes go when it closes, since its detail is then stored.
history_forget_level :: proc(app: ^App, id: int, level: Maybe(int)) {
	for list in ([2]^[dynamic]History_Entry{&app.history.done, &app.history.undone}) {
		kept := 0
		for e in list {
			only, one := level.?
			if e.id != id || (one && (e.level != only || e.swap != nil)) {
				list[kept] = e
				kept += 1
			} else if e.swap != nil {
				app.history.swap_bytes -= len(e.swap.bytes)
				snapshot_free(e.swap)
			}
		}
		resize(list, kept)
	}
}

// Drops an object's strokes on every level, when its levels are renumbered or some
// are deleted: undoing a stroke from one level is only right once every later stroke,
// on any level, has been undone.
object_forget_history :: proc(app: ^App, obj: ^Object) {
	history_forget_strokes(app, obj.id)
	for lv in obj.levels.levels do sculpt.sculptor_clear_history(&lv.sculptor)
}

object_by_id :: proc(app: ^App, id: int) -> ^Object {
	for obj in app.scene.objects do if obj.id == id do return obj
	return nil
}
