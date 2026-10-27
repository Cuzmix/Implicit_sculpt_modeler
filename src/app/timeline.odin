package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "../camera"
import "../ui"

// The History panel's timeline: every undo step on one bar, which can be dragged to any
// point, played back like a film, or recorded as a time-lapse. It only ever moves
// through the History with history_undo and history_redo, so scrubbing is exactly
// pressing Ctrl+Z or Ctrl+Shift+Z that many times, and the next stroke made after
// scrubbing back drops the steps ahead of it, as it would after undoing.
Timeline :: struct {
	seeking: bool,
	scrubbing: bool, // the press on the bar is a scrub: a mouse's, or one moved past the slop
	picked:    bool, // ...or it chose the History brush's step, and scrubs nothing
	target:  int, // the number of done steps being moved toward, while seeking
	playing: bool,
	speed:   f32, // steps a second while playing
	owed:    f64, // steps playback owes from earlier frames, below one
	last:    time.Tick, // when playback last advanced
	lapse:   Timelapse,
	// Marker is on: the next tap on a done step of the bar makes it what the History brush
	// paints back to, as a long press does, instead of going there.
	marking: bool,
	// When Delete older history was tapped once, to take a second tap within
	// DELETE_OLDER_ARM_TIME as the go-ahead; 0 when it is not armed.
	delete_armed_at: f64,
}

// How long Delete older history waits for its second tap, in seconds.
DELETE_OLDER_ARM_TIME :: 3

// A time-lapse records the History as numbered PNG frames: it undoes everything, then
// redoes `steps` steps a frame, saving the viewport after each, optionally turning the
// camera a little each frame.
Timelapse :: struct {
	state:  enum u8 {Off, Rewinding, Capturing},
	dir:    string, // owned
	frame:  int, // the next frame's number
	end:    int, // done steps where it stops: where the timeline stood when it began
	steps:  i32, // steps redone a frame
	spin:   f32, // degrees the camera turns a frame
	yaw:    f32, // the camera's turn before it began, restored after
	shown:  bool, // the viewport shows the current step, ready to save
	failed: bool,
}

// Seeking spends at most this long a frame stepping through the History, so dragging
// across many steps on a large mesh keeps the window responsive; at least one step is
// taken every frame whatever it costs.
TIMELINE_BUDGET :: 25 * time.Millisecond

// What playback starts at, and how far its slider goes.
TIMELINE_SPEED_DEFAULT :: 8
TIMELINE_SPEED_MAX :: 120

timeline_init :: proc(tl: ^Timeline) {
	tl.speed = TIMELINE_SPEED_DEFAULT
	tl.lapse.steps = 1
}

timeline_destroy :: proc(tl: ^Timeline) {
	delete(tl.lapse.dir)
	tl^ = {}
}

// Whether the timeline is moving through the History by itself, so the run should not
// end yet (a --timelapse run waits for it).
timeline_busy :: proc(app: ^App) -> bool {
	tl := &app.timeline
	return tl.seeking || tl.playing || tl.lapse.state != .Off
}

// Steps through the History toward where the timeline was dragged, plays it back, and
// records the time-lapse. Runs at the start of each frame, before anything reads the
// meshes, so what it changes is drawn the same frame.
timeline_frame :: proc(app: ^App) {
	tl := &app.timeline
	if app.stroke.active {
		// A stroke wins: the timeline stops where it is.
		tl.seeking, tl.playing = false, false
		if tl.lapse.state != .Off do timelapse_stop(app, "a stroke started")
		return
	}
	lapse := &tl.lapse
	switch lapse.state {
	case .Off:
	case .Rewinding:
		tl.seeking, tl.target, tl.playing = true, 0, false
		timeline_seek(app)
		if len(app.history.done) == 0 {
			lapse.state = .Capturing
			lapse.shown = false
			lapse.yaw = app.camera.yaw
		}
		return
	case .Capturing:
		if lapse.shown {
			path, _ := filepath.join({lapse.dir, fmt.tprintf("frame_%05d.png", lapse.frame)}, context.temp_allocator)
			if !screenshot_save(app, path) {
				lapse.failed = true
				timelapse_stop(app, "a frame could not be written")
				return
			}
			lapse.frame += 1
			if len(app.history.done) >= min(lapse.end, history_total(app)) {
				timelapse_stop(app, "")
				return
			}
			for _ in 0 ..< max(lapse.steps, 1) {
				if len(app.history.done) >= lapse.end do break
				if !history_step_toward(app, len(app.history.done) + 1) do break
			}
			camera.orbit_spin(&app.camera, lapse.spin * (math.PI / 180))
		}
		lapse.shown = true
		return
	}

	if tl.playing && !tl.seeking {
		now := time.tick_now()
		tl.owed += time.duration_seconds(time.tick_diff(tl.last, now)) * f64(tl.speed)
		tl.last = now
		if n := int(tl.owed); n > 0 {
			tl.owed -= f64(n)
			tl.target = min(len(app.history.done) + n, history_total(app))
			tl.seeking = true
		}
		if len(app.history.done) >= history_total(app) do tl.playing = false
	}
	if tl.seeking do timeline_seek(app)
}

// Every step the History holds, done and undone.
history_total :: proc(app: ^App) -> int {
	return len(app.history.done) + len(app.history.undone)
}

// Takes steps toward tl.target for up to TIMELINE_BUDGET, and stops seeking once it is
// there or the History cannot move (a step a sculptor's memory limit dropped is skipped
// by undo and redo themselves, which shortens the History).
@(private = "file")
timeline_seek :: proc(app: ^App) {
	tl := &app.timeline
	start := time.tick_now()
	for {
		tl.target = clamp(tl.target, 0, history_total(app))
		if len(app.history.done) == tl.target {
			tl.seeking = false
			return
		}
		before := len(app.history.done)
		if !history_step_toward(app, tl.target) {
			tl.seeking = false
			return
		}
		// Chained entries undo and redo together, so a target inside a chain is passed
		// over: the seek stops on the far side rather than stepping back and forth.
		if after := len(app.history.done); after != tl.target && (before < tl.target) != (after < tl.target) {
			tl.seeking = false
			return
		}
		if time.tick_since(start) >= TIMELINE_BUDGET do return
	}
}

// One undo or redo toward `target` done steps; false when the History would not move.
@(private = "file")
history_step_toward :: proc(app: ^App, target: int) -> bool {
	done, undone := len(app.history.done), len(app.history.undone)
	if target < done do history_undo(app)
	else if target > done do history_redo(app)
	return len(app.history.done) != done || len(app.history.undone) != undone
}

// Starts recording the History into `dir`, which is made if it is missing.
timelapse_start :: proc(app: ^App, dir: string) {
	stroke_finish(app)
	lapse := &app.timeline.lapse
	if lapse.state != .Off do return
	if history_total(app) == 0 {
		file_note(app, true, "Nothing to record: the History is empty")
		return
	}
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		file_note(app, true, "Cannot make the folder %s: %v", dir, err)
		return
	}
	delete(lapse.dir)
	lapse.dir = strings.clone(dir)
	lapse.state, lapse.frame, lapse.failed = .Rewinding, 0, false
	lapse.end = len(app.history.done)
	// From the very end when the timeline stands at the start: there is nothing to see
	// before the first step.
	if lapse.end == 0 do lapse.end = history_total(app)
	app.timeline.playing = false
	log.infof("time-lapse: recording %d steps into %s", lapse.end, dir)
}

// Ends a time-lapse, early with `why` or after its last frame with an empty `why`.
timelapse_stop :: proc(app: ^App, why: string) {
	lapse := &app.timeline.lapse
	if lapse.state == .Off do return
	capturing := lapse.state == .Capturing
	lapse.state = .Off
	if capturing do app.camera.yaw = lapse.yaw
	if why != "" {
		file_note(app, true, "Time-lapse stopped after %d frames: %s", lapse.frame, why)
	} else {
		file_note(app, false, "Time-lapse: %d frames in %s", lapse.frame, lapse.dir)
	}
	// The scrubbing that recording did leaves the timeline where it ends, as if dragged
	// there.
	app.timeline.seeking = false
}

// Whether the time-lapse is drawing frames, which should come out at full detail even
// though the camera turns between them.
timelapse_capturing :: proc(app: ^App) -> bool {return app.timeline.lapse.state == .Capturing}

@(private = "file", rodata)
KIND_COLORS := [History_Kind][4]f32 {
	.Stroke  = {0.95, 0.8, 0.45, 1},
	.Mask    = {0.5, 0.7, 1, 1},
	.Hide    = {0.7, 0.7, 0.7, 1},
	.Deform  = {0.6, 0.9, 0.6, 1},
	.Rebuild = {1, 0.5, 0.35, 1},
	.Paint   = {0.95, 0.5, 0.85, 1},
	.Layer   = {0.45, 0.9, 0.9, 1},
	.Transform = {0.75, 0.6, 1, 1},
	.Arrange   = {0.6, 0.85, 0.75, 1},
	.Textures  = {0.95, 0.65, 0.3, 1},
	.Lights    = {1, 0.95, 0.6, 1},
}

// How a step reads in the panel: "Clay stroke", "Blur mask", "remesh", and with Adjust
// last stroke its share, "Clay stroke (80%)".
entry_label :: proc(e: History_Entry) -> string {
	label := fmt.tprintf("%s stroke", e.what) if e.kind == .Stroke else e.what
	if e.adjusted do return fmt.tprintf("%s (%.0f%%)", label, e.amount * 100)
	return label
}

@(private = "file")
ago_label :: proc(at: time.Tick) -> string {
	s := time.duration_seconds(time.tick_since(at))
	switch {
	case s < 60:   return fmt.tprintf("%.0f s ago", s)
	case s < 3600: return fmt.tprintf("%.0f min ago", s / 60)
	}
	return fmt.tprintf("%.1f h ago", s / 3600)
}

// Starts moving the History toward `to` done steps, stopping playback.
@(private = "file")
timeline_seek_to :: proc(tl: ^Timeline, to: int) {
	tl.target, tl.seeking, tl.playing = to, true, false
}

// The interface's History panel, a window that starts over the dock: step through the
// History, scrub it on the bar, play it back, and record it as a time-lapse. Returns true
// when a press landed on it, to bring it to the front.
kit_history_panel :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	shown := ui.presence(ctx, ui.id_of(ctx, "history panel"), k.history, t.panel_time)
	if shown <= 0 do return
	tl := &app.timeline
	lapse := &tl.lapse
	done, total := len(app.history.done), history_total(app)
	recording := lapse.state != .Off
	can := !recording && !app.stroke.active
	dock, _ := ui.prev_layout(ctx, "dock")
	// Centred over the dock, as wide as fits between the panel on the right (Settings or
	// Help in the inspector's place, else the inspector) and the same margin on the other
	// side, within its least and most.
	right: f32 = KIT_SETTINGS_W + 8 if side_panel_open(k) else tray_width(app) + 8 if k.inspector else 0
	side := max(kit_right(app) + right, kit_left(app))
	width := clamp(ui.safe_area(ctx).w - 2 * side, KIT_HISTORY_MIN_W, KIT_HISTORY_W)
	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "history panel", "History", &k.windows[.History], .Center, .End, {0, t.edge + dock.y + 8}, {direction = .Column, gap = 4, padding = 10, width = width, radius = t.radius_large, background = .Panel, inert = !k.history})
	raised = raised_now
	if closed do k.history = false
	if !body {
		ui.window_end(ctx)
		ui.transform_since(ctx, mark, shown, 1, {}, {0, (1 - shown) * 16})
		return
	}

	ui.begin(ctx, "transport", {direction = .Row, center = true})
	if ui.icon_button(ctx, "Back to the start", ui.ICON_SKIP_BACK, enabled = can) do timeline_seek_to(tl, 0)
	if ui.icon_button(ctx, "Step back", ui.ICON_STEP_BACK, enabled = can && done > 0) do timeline_seek_to(tl, done - 1)
	if ui.icon_button(ctx, "Pause" if tl.playing else "Play", ui.ICON_PAUSE if tl.playing else ui.ICON_PLAY, selected = tl.playing, enabled = can && total > 0) {
		if tl.playing {
			tl.playing = false
		} else {
			// From the end, playback starts over from the beginning.
			if done >= total do timeline_seek_to(tl, 0)
			tl.playing, tl.owed, tl.last = true, 0, time.tick_now()
		}
	}
	if ui.icon_button(ctx, "Step forward", ui.ICON_STEP_FORWARD, enabled = can && done < total) do timeline_seek_to(tl, done + 1)
	if ui.icon_button(ctx, "Forward to the newest step", ui.ICON_SKIP_FORWARD, enabled = can) do timeline_seek_to(tl, total)
	ui.spacer(ctx, 10)
	// While Marker is on, or Delete older history waits for its second tap, what the next
	// tap does takes the step count's place.
	status, status_color := fmt.tprintf("Step %d of %d", done, total), t.text
	if tl.marking {
		status, status_color = "Tap a step to mark it", t.accent
	} else if tl.delete_armed_at > 0 {
		n := history_step_count(app.history.done[:])
		status, status_color = fmt.tprintf("Deletes %d step%s; redo stays", n, "" if n == 1 else "s"), t.danger
	}
	ui.label(ctx, status, t.text_size, status_color, .Semibold)
	ui.end(ctx)
	if done > 0 {
		e := app.history.done[done - 1]
		ui.label(ctx, fmt.tprintf("Last: %s, %s", entry_label(e), ago_label(e.at)), t.small_size)
	}

	kit_timeline_bar(app, can)

	// Two rows of controls, each fitting the narrowest panel: playback speed and the
	// time-lapse's start or stop, then the time-lapse's steps and turn.
	half := (width - 20 - 12) * 0.5
	ui.begin(ctx, "history options", {direction = .Row, gap = 12, center = true})
	ui.begin(ctx, "speed", {direction = .Column, width = half})
	_ = ui.slider(ctx, "Steps a second", &tl.speed, 1, TIMELINE_SPEED_MAX, .Logarithmic, fmt.tprintf("%.0f", tl.speed), enabled = can)
	ui.end(ctx)
	if recording {
		if ui.button(ctx, "Stop recording", .Solid, .Danger, width = half, glyph = ui.ICON_STOP) do timelapse_stop(app, "stopped")
	} else {
		if ui.button(ctx, "Record time-lapse...", .Flat, width = half, glyph = ui.ICON_FILM, enabled = total > 0 && !app.stroke.active) do file_dialog(app, .Timelapse)
	}
	ui.end(ctx)
	if recording {
		frames := lapse.end / int(max(lapse.steps, 1)) + 1
		ui.label(ctx, "Rewinding..." if lapse.state == .Rewinding else fmt.tprintf("Frame %d of %d", lapse.frame, frames), t.small_size)
	} else {
		ui.begin(ctx, "lapse options", {direction = .Row, gap = 12})
		ui.begin(ctx, "lapse steps", {direction = .Column, width = half})
		steps := f32(lapse.steps)
		if ui.slider(ctx, "Steps a frame", &steps, 1, 20, .Linear, fmt.tprintf("%d", lapse.steps)) do lapse.steps = i32(steps + 0.5)
		ui.end(ctx)
		ui.begin(ctx, "lapse turn", {direction = .Column, width = half})
		_ = ui.slider(ctx, "Turn a frame", &lapse.spin, 0, 10, .Linear, fmt.tprintf("%.1f°", lapse.spin))
		ui.end(ctx)
		ui.end(ctx)
	}
	// The marker for the History brush, and forgetting what can be undone to free its
	// memory, which takes a second tap. At the panel's foot, and with their hints in the
	// step count's place, so turning either on never moves the bar under the next tap.
	ui.begin(ctx, "history tools", {direction = .Row, gap = 12, center = true})
	if !can || tl.seeking do tl.marking = false
	if ui.toggle_button(ctx, "Marker", tl.marking, half, tooltip = "Tap a step on the bar to make it what the History brush paints back to") && can && !tl.seeking do tl.marking = !tl.marking
	armed := tl.delete_armed_at > 0 && ctx.time - tl.delete_armed_at < DELETE_OLDER_ARM_TIME
	if !armed do tl.delete_armed_at = 0
	if ui.button(ctx, "Tap again to delete" if armed else "Delete older history", .Bordered, .Danger if armed else .Neutral, width = half, glyph = ui.ICON_TRASH, enabled = can && !timeline_busy(app) && done > 0, keys = command_hint(app, .Delete_Older_History)) {
		if armed {
			tl.delete_armed_at = 0
			command_run(app, .Delete_Older_History)
		} else {
			tl.delete_armed_at = max(ctx.time, 1e-6)
		}
	}
	ui.end(ctx)
	ui.paragraph(ctx, "Record time-lapse asks for a folder, replays the History from the start to where the bar stands, and saves the viewport each frame as numbered PNGs (frame_00000.png...) that any video tool turns into a film; Turn spins the camera a little each frame.", width - 20)
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {0, (1 - shown) * 16})
	return
}

// The History panel's width at most, which gives the bar room to tell steps apart, and
// at least, which its rows of controls need.
KIT_HISTORY_W :: 720
KIT_HISTORY_MIN_W :: 440

// The bar: a block per step coloured by its kind, the done part lit, a marker where the
// History stands; press or drag to go there, and rest on it to see what a step was.
@(private = "file")
kit_timeline_bar :: proc(app: ^App, enabled: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	tl := &app.timeline
	done, total := len(app.history.done), history_total(app)
	a := ui.area(ctx, "timeline", {0, 36})
	r := a.rect
	x_at :: proc(r: ui.Rect, pos, total: int) -> f32 {
		return r.x + r.w * f32(pos) / f32(max(total, 1))
	}
	under_step := clamp(int((a.mouse.x - r.x) / r.w * f32(max(total, 1))), 0, max(total - 1, 0))
	// A right-click or long press on a step makes it what the History brush paints back
	// to, and so does a tap while Marker is on; a finger or the pen therefore scrubs only
	// once it moves past the slop, or taps.
	mark :: proc(app: ^App, step, done: int) {
		switch {
		case app.timeline.seeking:
			// The step may be undone by the seek still under way.
			report(app, Kit_Section.Recall, {.Warning}, "History brush: wait for the History to stop moving, then choose the step")
		case step < done:
			_ = recall_to_entry(app, step)
		case:
			report(app, Kit_Section.Recall, {.Warning}, "History brush: redo up to that step first; it paints back only to a step that is done")
		}
	}
	if enabled && total > 0 && ui.secondary(ctx) {
		// The press is spent: drifting off as the finger lifts scrubs nothing.
		tl.picked = true
		mark(app, under_step, done)
	}
	if a.pressed do tl.scrubbing, tl.picked = ctx.input.pointer == .Mouse && !tl.marking, tl.marking
	if a.clicked && tl.marking && enabled && total > 0 {
		mark(app, under_step, done)
		tl.marking = false
	}
	if a.held && !tl.picked && linalg.length(a.mouse - ctx.press_mouse) > ctx.theme.slop do tl.scrubbing = true
	if enabled && total > 0 && ((a.held && tl.scrubbing) || (a.clicked && !tl.picked)) {
		// Where the History is heading: the target while seeking, else where it stands.
		under := clamp(int((a.mouse.x - r.x) / r.w * f32(total) + 0.5), 0, total)
		heading := tl.target if tl.seeking else done
		if under != heading do timeline_seek_to(tl, under)
	}
	ui.fill_rect(ctx, r, t.radius_small, t.fill)
	if done > 0 do ui.fill_rect(ctx, {r.x, r.y, x_at(r, done, total) - r.x, r.h}, t.radius_small, ui.color_fade(t.accent, 0.25))
	// Below about 3 points a step the blocks would merge, so they become lines instead.
	gap := f32(1) if r.w / f32(max(total, 1)) >= 3 else 0
	for i in 0 ..< total {
		e := app.history.done[i] if i < done else app.history.undone[total - 1 - i]
		color := KIND_COLORS[e.kind]
		if i >= done do color.a = 0.3
		x0 := x_at(r, i, total) + gap
		x1 := max(x_at(r, i + 1, total) - gap, x_at(r, i, total) + 1)
		ui.fill_rect(ctx, {x0, r.y + 10, x1 - x0, r.h - 20}, 2 if gap > 0 else 0, overlay_color(color))
	}
	at := x_at(r, done, total)
	ui.line(ctx, {at, r.y}, {at, r.y + r.h}, t.text, 2)
	marker := [3][2]f32{{at - 5, r.y}, {at + 5, r.y}, {at, r.y + 6}}
	ui.fill_convex(ctx, marker[:], t.text)
	if tl.seeking {
		ghost := x_at(r, tl.target, total)
		ui.line(ctx, {ghost, r.y}, {ghost, r.y + r.h}, ui.color_fade(t.text, 0.4), 1)
	}
	// The History brush's point: a mark at the foot of the bar where the step it paints
	// back to before begins.
	recall := recall_marker(app)
	if recall >= 0 {
		x := x_at(r, recall, total)
		mark := [3][2]f32{{x - 5, r.y + r.h}, {x, r.y + r.h - 7}, {x + 5, r.y + r.h}}
		ui.fill_convex(ctx, mark[:], t.accent)
	}
	if a.hovered && total > 0 {
		step := clamp(int((a.mouse.x - r.x) / r.w * f32(total)), 0, total - 1)
		e := app.history.done[step] if step < done else app.history.undone[total - 1 - step]
		point := ". The History brush paints back to before it" if step == recall else ""
		ui.tip(ctx, a.id, {a.mouse.x - 1, r.y, 2, r.h}, fmt.tprintf("Step %d: %s, object %d, %s%s%s", step + 1, entry_label(e), e.id, ago_label(e.at), "" if step < done else " (undone)", point))
	}
}
