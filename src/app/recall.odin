package main

import "core:fmt"
import "core:time"

import "../sculpt"
import "../ui"

// The History brush's recall point: what of the History it paints back to (sculpt
// recall.odin keeps the target, one per level or HD window). By default it is the
// oldest step the level's History still holds; Earlier and Later in the Brush tab's
// History brush section choose another, which stays until its step is undone or dropped.

// The History entry of the step `back` steps back on `obj` as shown now (its level, or
// its HD window): the entries of a sculptor's steps, newest first, are its steps newest
// first, since an object's strokes are only ever forgotten oldest first.
recall_entry :: proc(app: ^App, obj: ^Object, back: int) -> (History_Entry, bool) {
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	n := 0
	#reverse for e in app.history.done {
		if e.id != obj.id || e.level != level || e.swap != nil || e.kind == .Transform || e.kind == .Arrange do continue
		n += 1
		if n == back do return e, true
	}
	return {}, false
}

// Makes sure the History brush has a target on `obj` before a stroke starts: the one it
// has while its step is still done, or else one built from the oldest step in reach.
// False when there is nothing to paint back to, said (with `say`) as a warning.
recall_ready :: proc(app: ^App, obj: ^Object, say: bool) -> bool {
	s := object_sculptor(obj)
	if object_dynamic(obj) {
		if say do report(app, Kit_Section.Recall, {.Warning}, "The History brush does not work with dynamic topology on")
		return false
	}
	if _, ok := sculpt.sculptor_recall_back(s); ok do return true
	lost := sculpt.sculptor_recall_pinned(s)
	reach := sculpt.sculptor_recall_reach(s)
	if reach == 0 {
		if say do report(app, Kit_Section.Recall, {.Warning}, "History brush: nothing earlier on this level to paint back to yet")
		return false
	}
	recall_build(app, s, reach, false)
	// Said whatever started the stroke: it happens once, as the point is lost.
	if lost do report(app, Kit_Section.Recall, {.Warning}, "History brush: the chosen step is out of reach now, so it paints back to the oldest")
	return true
}

// Builds the target `back` steps back, timing it for the stats.
@(private = "file")
recall_build :: proc(app: ^App, s: ^sculpt.Sculptor, back: int, pinned: bool) {
	start := time.tick_now()
	_ = sculpt.sculptor_recall_build(s, back, pinned)
	app.stats.recall_ms = time.duration_milliseconds(time.tick_since(start))
}

// Moves the selected object's recall point: `to` steps back, kept within reach.
recall_move :: proc(app: ^App, to: int, pinned: bool) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || object_dynamic(obj) do return
	s := object_sculptor(obj)
	if reach := sculpt.sculptor_recall_reach(s); reach > 0 do recall_build(app, s, clamp(to, 1, reach), pinned)
}

// Where the selected object's recall point is now: how many steps back (0 with none),
// and how far back it could go; `shown`, the point a stroke would use (the oldest when
// there is none yet).
recall_now :: proc(app: ^App) -> (back, reach, shown: int) {
	obj := selected_object(app)
	if obj == nil || object_dynamic(obj) do return
	s := object_sculptor(obj)
	back, _ = sculpt.sculptor_recall_back(s)
	reach = sculpt.sculptor_recall_reach(s)
	return back, reach, back if back > 0 else reach
}

// The Brush tab's History brush section: what the brush paints back to, and the
// buttons that move it.
kit_recall :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	if obj == nil {
		ui.paragraph(ctx, "Select an object to see what the History brush paints back to.")
		return
	}
	back, _, shown := recall_now(app)
	switch {
	case object_dynamic(obj):
		ui.paragraph(ctx, "Not with dynamic topology on: its strokes renumber the vertices.")
	case shown == 0:
		ui.paragraph(ctx, "Nothing to paint back to yet: the brush works once this level has a stroke or another change in the History since it was last brought up to date with another level.")
	case:
		name := "an earlier step"
		if e, ok := recall_entry(app, obj, shown); ok do name = entry_label(e)
		which := "the oldest held" if back == 0 || !sculpt.sculptor_recall_pinned(object_sculptor(obj)) else "chosen"
		ui.paragraph(ctx, fmt.tprintf("Before: %s, %d step%s back (%s).", name, shown, "" if shown == 1 else "s", which))
	}
	kit_command_pair(app, .Recall_Earlier, .Recall_Later, label_a = "Earlier", label_b = "Later")
	_ = command_button(app, .Recall_Oldest, label = "Use the oldest")
	ui.paragraph(ctx, "The History brush is a local undo: it paints the surface back toward how it was before that step, only where you brush. Its strokes are steps of their own. It reaches back to the oldest step this level's History holds, but not past dynamic topology or a change carried from another level.")
}
