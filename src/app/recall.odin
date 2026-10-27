package main

import "core:fmt"
import "core:time"

import "../sculpt"
import "../ui"

// The History brush's recall point: what of the History it paints back to (sculpt
// recall.odin keeps the target, one per level or HD window). By default it is the
// oldest step the level's History still holds; Earlier and Later in the Brush palette's
// History brush section choose another, as does a right-click or long press on a step of
// the History panel's bar, which then marks it. A chosen point stays until its step is
// undone, dropped or out of reach.

// Whether a History entry is a step of its sculptor's own: not a transform, a change to
// the tree, a change of maps, or a swap.
entry_is_step :: proc(e: History_Entry) -> bool {
	return e.swap == nil && e.kind != .Transform && e.kind != .Arrange && e.kind != .Textures
}

// The History entry of the step `back` steps back on `obj` as shown now (its level, or
// its HD window): the entries of a sculptor's steps, newest first, are its steps newest
// first, since an object's strokes are only ever forgotten oldest first.
recall_entry :: proc(app: ^App, obj: ^Object, back: int) -> (History_Entry, bool) {
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	n := 0
	#reverse for e in app.history.done {
		if e.id != obj.id || e.level != level || !entry_is_step(e) do continue
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

// Makes the History brush paint back to how the object of done entry `index` was before
// it, on the entry's level, chosen as the user's point. Refused with a note for an entry
// that is no sculpting step, or out of reach. Returns whether the point moved.
recall_to_entry :: proc(app: ^App, index: int) -> bool {
	stroke_finish(app)
	if index < 0 || index >= len(app.history.done) do return false
	e := app.history.done[index]
	s := entry_sculptor(app, e)
	if s == nil || !entry_is_step(e) {
		report(app, Kit_Section.Recall, {.Warning}, "History brush: only a sculpting step can be what it paints back to")
		return false
	}
	// A step of a level not shown: going there brings that level up to date with the one
	// shown now, which puts the step out of reach (history_seal), so it is not taken.
	obj := object_by_id(app, e.id)
	if shown := HD_LEVEL if object_in_hd(obj) else obj.levels.current; e.level != shown {
		report(app, Kit_Section.Recall, {.Warning}, "History brush: %s is on another level; go to level %d first", entry_label(e), e.level + 1)
		return false
	}
	// The entry is this many steps back on its sculptor: its own and the newer ones of
	// the same object and level.
	back := 0
	for f in app.history.done[index:] do if f.id == e.id && f.level == e.level && entry_is_step(f) do back += 1
	if s.dyn != nil || back > sculpt.sculptor_recall_reach(s) {
		report(app, Kit_Section.Recall, {.Warning}, "History brush: %s is out of its reach (before dynamic topology, a change carried from another level, or a step the undo memory dropped)", entry_label(e))
		return false
	}
	recall_build(app, s, back, true)
	report(app, Kit_Section.Recall, {}, "History brush: paints %s back to before %s", object_label(obj), entry_label(e))
	return true
}

// The done entry whose step the selected object's History brush paints back to before,
// as it is shown now (built, or the oldest by default); -1 for none.
recall_marker :: proc(app: ^App) -> int {
	_, _, shown := recall_now(app)
	obj := selected_object(app)
	if shown == 0 || obj == nil do return -1
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	n := 0
	#reverse for e, i in app.history.done {
		if e.id != obj.id || e.level != level || !entry_is_step(e) do continue
		n += 1
		if n == shown do return i
	}
	return -1
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

// The Brush palette's History brush section: what the brush paints back to, and the
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
	ui.paragraph(ctx, "The History brush is a local undo: it paints the surface back toward how it was before that step, only where you brush. Its strokes are steps of their own. It reaches back to the oldest step this level's History holds, but not past dynamic topology or a change carried from another level. A right-click or long press on a step of the History panel's bar makes it the point, marked there.")
}
