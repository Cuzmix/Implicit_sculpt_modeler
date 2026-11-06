package main

import "core:fmt"
import "core:time"

import "../sculpt"
import "../ui"

// Dial back (the History's step menu): a step, or a group of strokes in the list, set to a
// share of what it did, 0 % taking it away and 150 % pushing it further, while every step
// after it stays (sculpt dial.odin). The dial shows in the History card over the rows; Done
// makes it one undo step, Cancel puts the model back. While it is open the History holds
// still (history_busy); a stroke, Undo, any scene command, a scene opened or the list
// leaving the screen cancels it.

// The dial the History card shows (Timeline.dial).
History_Dial :: struct {
	open:    bool,
	object:  int, // the object's id
	level:   int, // its level (or HD_LEVEL) the run is on
	first, last: time.Tick, // the run's oldest and newest entries, by when they were made
	steps:   int, // how many steps the run holds
	what:    string, // the run's name, as its row shows it (temp-safe: a constant or cloned)
	k:       f32,
	verts:   int,
	pending: bool, // a value waits for the slider to be let go (a run past DIAL_LIVE_VERTS)
	// Timings and counts for the exit stats.
	dials:   int,
	begin_ms, set_ms, end_ms: f64,
}

history_dial_destroy :: proc(d: ^History_Dial) {
	delete(d.what)
	d^ = {}
}

// Whether a dial is open: the History then holds still.
history_dial_open :: proc(app: ^App) -> bool {return app.timeline.dial.open}

// The sculptor an open dial works on, or nil once its object or level is gone or no longer
// shown.
@(private = "file")
history_dial_sculptor :: proc(app: ^App) -> ^sculpt.Sculptor {
	d := &app.timeline.dial
	obj := object_by_id(app, d.object)
	if obj == nil || obj.voxel != nil do return nil
	shown := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	if shown != d.level do return nil
	return object_sculptor(obj)
}

// Why the done entries from timeline position `first` to `last` cannot be dialled, or "".
history_dial_reason :: proc(app: ^App, first, last: int) -> string {
	done := len(app.history.done)
	switch {
	case history_busy(app) || app.timeline.lapse.state != .Off || app.timeline.seeking:
		return "Wait for the History to stop moving"
	case last >= done:
		return "Redo up to this step first: only done steps can be dialled back"
	}
	e := app.history.done[last]
	obj := object_by_id(app, e.id)
	if obj == nil || obj.voxel != nil do return "Only a mesh object's sculpting steps can be dialled back"
	if object_dynamic(obj) do return "Dial back does not work with dynamic topology on"
	shown := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	if e.level != shown do return fmt.tprintf("This step is on another level; go to level %d first", e.level + 1)
	for f in app.history.done[first:last + 1] {
		if f.id != e.id || f.level != e.level || f.step_id == 0 do return "Only sculpting steps of one object and level can be dialled back together"
	}
	return ""
}

// Opens a dial on the done entries from timeline position `first` to `last` at 100 %,
// refused with a note saying why it cannot.
history_dial_begin :: proc(app: ^App, first, last: int) {
	stroke_finish(app)
	if reason := history_dial_reason(app, first, last); reason != "" {
		report(app, Section.History, {.Warning}, "Dial back: %s", reason)
		return
	}
	h := &app.history
	newest, oldest := h.done[last], h.done[first]
	obj := object_by_id(app, newest.id)
	s := object_sculptor(obj)
	newest_back, oldest_back := sculpt.sculptor_step_back(s, newest.step_id), sculpt.sculptor_step_back(s, oldest.step_id)
	if newest_back == 0 || oldest_back == 0 {
		report(app, Section.History, {.Warning}, "Dial back: the undo memory dropped this step's saved model")
		return
	}
	start := time.tick_now()
	verts, refusal := sculpt.sculptor_dial_begin(s, oldest_back, newest_back)
	switch refusal {
	case .None:
	case .Busy:
		report(app, Section.History, {.Warning}, "Dial back: the last stroke is still landing; try again")
		return
	case .Dynamic:
		report(app, Section.History, {.Warning}, "Dial back does not work with dynamic topology on")
		return
	case .Reach:
		report(app, Section.History, {.Warning}, "Dial back: this step is out of reach (before a change carried from another level)")
		return
	case .Kind:
		report(app, Section.History, {.Warning}, "Dial back: it cannot share out a sculpt layer's or the detail skin's step")
		return
	case .Nothing:
		report(app, Section.History, {.Warning}, "Dial back: these steps moved nothing (a mask or paint step)")
		return
	case .Memory:
		report(app, Section.History, {.Warning}, "Dial back: its step would hold more than half of the History's memory (%s); raise History may use in Settings", bytes_label(verts * size_of(sculpt.Vec3)))
		return
	}
	d := &app.timeline.dial
	delete(d.what)
	steps := 0
	for i in first ..= last do if !h.done[i].chain do steps += 1
	label := entry_label(newest)
	d^ = {
		open = true,
		object = obj.id,
		level = newest.level,
		first = oldest.at,
		last = newest.at,
		steps = steps,
		what = fmt.aprintf("%s × %d", label, steps) if steps > 1 else fmt.aprintf("%s", label),
		k = 1,
		verts = verts,
		dials = d.dials,
		begin_ms = time.duration_milliseconds(time.tick_since(start)),
	}
	app.timeline.menu = false
}

// Sets an open dial to `k` now.
@(private = "file")
history_dial_apply :: proc(app: ^App, k: f32) {
	d := &app.timeline.dial
	s := history_dial_sculptor(app)
	if s == nil do return
	start := time.tick_now()
	_ = sculpt.sculptor_dial_set(s, k)
	d.set_ms = time.duration_milliseconds(time.tick_since(start))
	d.pending = false
}

// Closes an open dial as one undo step (or as nothing at 100 %).
history_dial_done :: proc(app: ^App) {
	d := &app.timeline.dial
	if !d.open do return
	s := history_dial_sculptor(app)
	if s == nil {
		history_dial_close(app)
		return
	}
	if d.pending do history_dial_apply(app, d.k)
	start := time.tick_now()
	made := sculpt.sculptor_dial_end(s)
	d.end_ms = time.duration_milliseconds(time.tick_since(start))
	k, what := d.k, d.what
	d.what = ""
	defer delete(what)
	history_dial_close(app)
	if !made do return
	obj := object_by_id(app, d.object)
	history_record(app, obj, .Deform, "Dial back")
	e := &app.history.done[len(app.history.done) - 1]
	e.adjusted, e.amount = true, k
	d.dials += 1
	report(app, Section.History, {.Quiet}, "Dialled %s to %.0f%%", what, k * 100)
}

// Closes an open dial as if it never opened: the model goes back as it was.
history_dial_cancel :: proc(app: ^App) {
	if !app.timeline.dial.open do return
	if s := history_dial_sculptor(app); s != nil do sculpt.sculptor_dial_cancel(s)
	history_dial_close(app)
}

@(private = "file")
history_dial_close :: proc(app: ^App) {
	d := &app.timeline.dial
	delete(d.what)
	d.what = ""
	d.open, d.pending = false, false
}

// Keeps an open dial honest each frame: it closes when its object or level stops being
// shown (the sculptor then cancelled it or is gone), or when a stroke began, which cancels
// it in the sculptor; and it is cancelled once the History's list, where it shows, is not
// on screen, so no dial stays open unseen.
history_dial_settle :: proc(app: ^App) {
	d := &app.timeline.dial
	if !d.open do return
	if !card_shown(app, .History) || app.timeline.view != .List || app.timeline.settings {
		history_dial_cancel(app)
		return
	}
	s := history_dial_sculptor(app)
	if s == nil {
		history_dial_close(app)
		return
	}
	if _, verts := sculpt.sculptor_dial_state(s); verts == 0 do history_dial_close(app)
}

// The dial over the History card's rows: what it dials, the amount, Done and Cancel.
kit_history_dial :: proc(app: ^App, inner: f32) {
	d := &app.timeline.dial
	if !d.open do return
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.begin(ctx, "history dial", {direction = .Column, gap = ui.SPACE_S, width = inner})
	ui.label(ctx, ui.text_fit(ctx, fmt.tprintf("Dial back %s", d.what), t.text_size, inner, .Semibold), t.text_size, t.text, .Semibold)
	k := d.k
	if ui.slider(ctx, "Amount##history dial", &k, 0, sculpt.DIAL_MAX, .Linear, fmt.tprintf("%.0f%%", k * 100)) {
		d.k = k
		// Past DIAL_LIVE_VERTS a set is too long to follow a drag: it lands when let go.
		if d.verts > sculpt.DIAL_LIVE_VERTS do d.pending = true
		else do history_dial_apply(app, k)
	}
	if d.pending && ctx.input.down == {} do history_dial_apply(app, d.k)
	ui.paragraph(ctx, "How much of it stays: 0% takes it away, 100% is as it is, more pushes it further. Later steps keep what they did on top. Done makes it one undo step.", inner)
	half := (inner - ui.SPACE_M) * 0.5
	ui.begin(ctx, "history dial buttons", {direction = .Row, gap = ui.SPACE_M})
	if ui.button(ctx, "Cancel##history dial", .Flat, width = half) do history_dial_cancel(app)
	if ui.button(ctx, "Done##history dial", .Solid, width = half) do history_dial_done(app)
	ui.end(ctx)
	ui.end(ctx)
	ui.divider(ctx, across = true)
}
