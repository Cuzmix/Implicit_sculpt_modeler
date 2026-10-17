package main

import "../sculpt"

// Scene-wide undo order. Each level of each object keeps its own strokes; this records
// which object and level each stroke belongs to, newest last, so Ctrl+Z walks back
// across objects and levels. Undoing a stroke made on another level first switches the
// object to that level, as ZBrush does: strokes come back newest first on every level,
// which keeps the levels consistent with each other.
History :: struct {
	done:   [dynamic]History_Entry,
	undone: [dynamic]History_Entry,
}

History_Entry :: struct {
	id:    int, // object
	level: int,
}

history_destroy :: proc(h: ^History) {
	delete(h.done)
	delete(h.undone)
	h^ = {}
}

// Ends the brush stroke in progress, if any, and records it when it changed the mesh.
stroke_finish :: proc(app: ^App) {
	if !app.stroke.active do return
	app.stroke.active = false
	obj := object_by_id(app, app.stroke.object)
	if obj == nil || !sculpt.sculptor_stroke_end(object_sculptor(obj)) do return
	// A new stroke discards everything that could have been redone, everywhere.
	for e in app.history.undone {
		if s := entry_sculptor(app, e); s != nil do sculpt.sculptor_clear_redo(s)
	}
	clear(&app.history.undone)
	append(&app.history.done, History_Entry{obj.id, obj.levels.current})
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
		s := entry_sculptor(app, e)
		if s == nil || !can(s) do continue
		if !object_set_level(app, object_by_id(app, e.id), e.level) do app.running = false // GPU failure
		_ = step(s)
		append(to, e)
		return
	}
}

// The sculptor an entry's stroke was made with, or nil if it is gone.
@(private = "file")
entry_sculptor :: proc(app: ^App, e: History_Entry) -> ^sculpt.Sculptor {
	obj := object_by_id(app, e.id)
	if obj == nil || e.level >= len(obj.levels.levels) do return nil
	return &obj.levels.levels[e.level].sculptor
}

// Drops an object's entries, when its sculptors (and so its strokes) go away.
history_forget :: proc(app: ^App, id: int) {
	for list in ([2]^[dynamic]History_Entry{&app.history.done, &app.history.undone}) {
		kept := 0
		for e in list {
			if e.id != id {
				list[kept] = e
				kept += 1
			}
		}
		resize(list, kept)
	}
}

// Drops an object's strokes on every level, when its levels are renumbered or some
// are deleted: undoing a stroke from one level is only right once every later stroke,
// on any level, has been undone.
object_forget_history :: proc(app: ^App, obj: ^Object) {
	history_forget(app, obj.id)
	for lv in obj.levels.levels do sculpt.sculptor_clear_history(&lv.sculptor)
}

object_by_id :: proc(app: ^App, id: int) -> ^Object {
	for obj in app.scene.objects do if obj.id == id do return obj
	return nil
}
