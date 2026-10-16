package main

import "../sculpt"

// Scene-wide undo order. Each sculptor keeps its own strokes; this records which
// object each stroke belongs to, newest last, so Ctrl+Z walks back across objects.
History :: struct {
	done:   [dynamic]int, // object ids
	undone: [dynamic]int,
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
	if obj == nil || !sculpt.sculptor_stroke_end(&obj.sculptor) do return
	// A new stroke discards everything that could have been redone, on every object.
	for id in app.history.undone {
		if o := object_by_id(app, id); o != nil do sculpt.sculptor_clear_redo(&o.sculptor)
	}
	clear(&app.history.undone)
	append(&app.history.done, obj.id)
}

history_can_undo :: proc(app: ^App) -> bool {return !app.stroke.active && len(app.history.done) > 0}
history_can_redo :: proc(app: ^App) -> bool {return !app.stroke.active && len(app.history.undone) > 0}

history_undo :: proc(app: ^App) {
	if app.stroke.active do return
	// Entries whose step a sculptor already dropped (memory limit) are skipped.
	for len(app.history.done) > 0 {
		id := pop(&app.history.done)
		obj := object_by_id(app, id)
		if obj != nil && sculpt.sculptor_undo(&obj.sculptor) {
			append(&app.history.undone, id)
			return
		}
	}
}

history_redo :: proc(app: ^App) {
	if app.stroke.active do return
	for len(app.history.undone) > 0 {
		id := pop(&app.history.undone)
		obj := object_by_id(app, id)
		if obj != nil && sculpt.sculptor_redo(&obj.sculptor) {
			append(&app.history.done, id)
			return
		}
	}
}

// Drops an object's entries, when its sculptor (and so its strokes) goes away.
history_forget :: proc(app: ^App, id: int) {
	for list in ([2]^[dynamic]int{&app.history.done, &app.history.undone}) {
		kept := 0
		for v in list {
			if v != id {
				list[kept] = v
				kept += 1
			}
		}
		resize(list, kept)
	}
}

object_by_id :: proc(app: ^App, id: int) -> ^Object {
	for obj in app.scene.objects do if obj.id == id do return obj
	return nil
}
