package main

import "core:fmt"
import "core:strings"
import "core:time"

import "../sculpt"
import "../ui"

// The History's step menu (History revamp H2): a long press, a right click or the pen's
// side button on a step, in the list or on the strip, opens what can be done with it, and
// a tap still just goes there. Go here; Paint back to here, which makes the step what the
// History brush paints back to and picks that brush (it replaces the Marker button and the
// strip's hidden right click); Bookmark..., which names the step as ZBrush's restore
// points name a state to come back to, and its rename and removal; View from this step,
// which puts the camera where it was when the step was made (ZBrush's Restore placement)
// without moving the History; Only that object's steps, in the list; and Delete everything
// older, which takes a second tap as the panel's button did.

// Lucide's flag and filter.
ICON_FLAG :: rune(0xe0d6)
ICON_FILTER :: rune(0xe0d5)

// The step whose first entry was made at `at`, as timeline positions: its first entry and
// its last (chained) one; ok is false once it is gone (dropped, or replaced by a new step).
history_step_of :: proc(app: ^App, at: time.Tick) -> (head, last: int, ok: bool) {
	if at == {} do return
	total := history_total(app)
	for i in 0 ..< total {
		e := history_entry_at(app, i)
		if (e.chain && i > 0) || e.at != at do continue
		last = i
		for last + 1 < total && history_entry_at(app, last + 1).chain do last += 1
		return i, last, true
	}
	return
}

// The entry at timeline position `i`, to change in place.
history_entry_ptr :: proc(app: ^App, i: int) -> ^History_Entry {
	done, total := len(app.history.done), history_total(app)
	return &app.history.done[i] if i < done else &app.history.undone[total - 1 - i]
}

// How many steps are bookmarked, done or undone.
history_bookmarks :: proc(app: ^App) -> int {
	n := 0
	for e in app.history.done do if e.bookmark != "" do n += 1
	for e in app.history.undone do if e.bookmark != "" do n += 1
	return n
}

// The name a new bookmark takes when none is typed: "Bookmark 1", 2 and so on.
history_bookmark_default :: proc(app: ^App) -> string {
	return fmt.tprintf("Bookmark %d", history_bookmarks(app) + 1)
}

// Names the step at timeline position `head`, or takes its bookmark away with an empty
// name. A bookmark is a note on the History, not a change to the scene, so it is no step
// of its own.
history_bookmark_set :: proc(app: ^App, head: int, name: string) {
	e := history_entry_ptr(app, head)
	// Cloned before the old one goes, which `name` may be.
	named := strings.clone(name) if name != "" else ""
	delete(e.bookmark)
	e.bookmark = named
}

// Paint back to here: makes done step `head` what the History brush paints back to and,
// once it is, picks the brush, since painting is what comes next. Refused with a note as
// recall_to_entry refuses.
history_paint_back :: proc(app: ^App, head: int) {
	if recall_to_entry(app, head) do command_run(app, .Brush, int(sculpt.Brush_Kind.History))
}

// Puts the camera where `v` says, gliding there: View from this step, and the History's
// camera following undo.
history_view_go :: proc(app: ^App, v: Camera_View) {
	if v == {} do return
	before := camera_ease_begin(app)
	camera_go(app, v)
	camera_ease_from(app, before)
}

// After the History moved from `from` done steps to where it stands: with Camera follows
// the History on (History > Settings, Nomad's Restore camera), the camera goes where it was
// when the step it moved over last was made, the one undone or the one redone, so the eye
// lands on what changed. Not while a time-lapse records, which turns the camera itself.
history_camera_follow :: proc(app: ^App, from: int) {
	h := &app.history
	if !app.history_camera || app.timeline.lapse.state != .Off do return
	if len(h.done) < from && len(h.undone) > 0 {
		history_view_go(app, h.undone[len(h.undone) - 1].view)
	} else if len(h.done) > from {
		history_view_go(app, h.done[len(h.done) - 1].view)
	}
}

// Opens the menu of the step whose first entry is at timeline position `head`, beside
// `anchor` (the pointer in the list, the step's block on the strip).
history_menu_open :: proc(app: ^App, head: int, anchor: ui.Rect, side: ui.Side) {
	tl := &app.timeline
	tl.menu, tl.menu_rect, tl.menu_side = true, anchor, side
	tl.menu_step = history_entry_at(app, head).at
	tl.delete_armed_at = 0
	tl.menus += 1
}

// The menu itself, over every panel; it closes when its step goes or the panel closes.
kit_history_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	tl := &app.timeline
	head, last, ok := history_step_of(app, tl.menu_step)
	if !ok || !k.history {
		tl.menu = false
		return
	}
	if !ui.popover_begin(ctx, "history step menu", &tl.menu, tl.menu_rect, tl.menu_side, {direction = .Column, gap = 0, padding = 6, width = 300}) do return
	defer ui.popover_end(ctx)
	e := history_entry_at(app, head)
	done := len(app.history.done)
	can := tl.lapse.state == .Off && !app.stroke.active
	obj := object_by_id(app, e.id)
	bytes := 0
	for i in head ..= last do bytes += history_entry_at(app, i).bytes

	// The step: what it was and its number, then its object, age and size.
	ui.begin(ctx, "history menu head", {direction = .Column, gap = 2, padding = 8})
	ui.label(ctx, fmt.tprintf("%s · step %d", entry_label(e), head + 1), t.text_size, t.text, .Semibold)
	on := fmt.tprintf("%s · ", object_label(obj)) if obj != nil else ""
	size := fmt.tprintf(" · %s", bytes_label(bytes)) if bytes > 0 else ""
	state := "" if head < done else " · undone"
	ui.label(ctx, fmt.tprintf("%s%s%s%s", on, ago_label(e.at), size, state), t.small_size, t.text_secondary)
	if e.bookmark != "" do ui.label(ctx, e.bookmark, t.small_size, t.warning, .Semibold)
	ui.end(ctx)
	ui.divider(ctx, across = true)

	picked := false
	if ui.menu_item(ctx, "Go here", "Tap", ui.ICON_HISTORY, enabled = can && last + 1 != done, reason = "The scene stands at this step" if can else "Wait for the stroke or the time-lapse to end") {
		timeline_seek_to(tl, last + 1)
		picked = true
	}
	recall := recall_marker(app)
	paint_reason := ""
	switch {
	case !can || tl.seeking:
		paint_reason = "Wait for the History to stop moving"
	case head >= done:
		paint_reason = "Redo up to this step first: the History brush paints back only to a step that is done"
	case !entry_is_step(e) || entry_sculptor(app, e) == nil:
		paint_reason = "Only a sculpting step can be what the History brush paints back to"
	}
	if ui.menu_item(ctx, "Paint back to here", "History brush", ui.ICON_BRUSH, checked = recall >= head && recall <= last, enabled = paint_reason == "", reason = paint_reason, hint = "Makes the History brush paint back to how the object was before this step, and picks the brush") {
		history_paint_back(app, head)
		picked = true
	}
	if e.bookmark == "" {
		if ui.menu_item(ctx, "Bookmark...", glyph = ICON_FLAG, hint = "Names this step, to find it again in the list and on the strip") {
			app.kit.rename = {open = true, step = e.at, at = tl.menu_rect}
			picked = true
		}
	} else {
		if ui.menu_item(ctx, "Rename bookmark...", glyph = ICON_FLAG) {
			app.kit.rename = {open = true, step = e.at, at = tl.menu_rect}
			picked = true
		}
		if ui.menu_item(ctx, "Remove bookmark", glyph = ui.ICON_CLOSE) {
			history_bookmark_set(app, head, "")
			picked = true
		}
	}
	if ui.menu_item(ctx, "Show what it changed", glyph = ICON_SCAN_EYE, hint = "Tints the part of the model this step changed until the next press; resting on a step shows it too") {
		tl.tint_kept, tl.tint_kept_at = e.at, ctx.time
		picked = true
	}
	if ui.menu_item(ctx, "View from this step", glyph = ICON_CAMERA, enabled = e.view != {}, reason = "This step kept no view", hint = "Puts the camera where it was when this step was made; the History stays where it is") {
		history_view_go(app, e.view)
		picked = true
	}
	if tl.view == .List && obj != nil {
		sel := selected_object(app)
		only := tl.only_selected && sel == obj
		if ui.menu_item(ctx, "Every object's steps" if only else fmt.tprintf("Only %s's steps", object_label(obj)), glyph = ICON_FILTER) {
			if !only do for o, i in app.scene.objects do if o == obj do select_only(app, i)
			tl.only_selected = !only
			tl.list_scroll = 0
			picked = true
		}
	}
	ui.divider(ctx, across = true)
	older := history_step_count(app.history.done[:head]) if head < done else 0
	armed := tl.delete_armed_at > 0 && ctx.time - tl.delete_armed_at < DELETE_OLDER_ARM_TIME
	if !armed do tl.delete_armed_at = 0
	delete_reason := "Wait for the History to stop moving" if !can || timeline_busy(app) else "Redo up to this step first" if head >= done else "Nothing is older than this step"
	label := fmt.tprintf("Tap again: forgets %d step%s", older, "" if older == 1 else "s") if armed else "Delete everything older"
	if ui.menu_item(ctx, fmt.tprintf("%s##history menu delete", label), glyph = ui.ICON_TRASH, tone = .Danger, enabled = can && !timeline_busy(app) && older > 0, reason = delete_reason, hint = "Forgets the steps before this one to free their memory; it cannot be undone") {
		if armed {
			tl.delete_armed_at = 0
			history_delete_before(app, head)
			picked = true
		} else {
			tl.delete_armed_at = max(ctx.time, 1e-6)
		}
	}
	if picked do tl.menu = false
}
