package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import imgui "deps:odin-imgui"

// The History panel's timeline: every undo step on one bar, which can be dragged to any
// point, played back like a film, or recorded as a time-lapse. It only ever moves
// through the History with history_undo and history_redo, so scrubbing is exactly
// pressing Ctrl+Z or Ctrl+Shift+Z that many times, and the next stroke made after
// scrubbing back drops the steps ahead of it, as it would after undoing.
Timeline :: struct {
	seeking: bool,
	target:  int, // the number of done steps being moved toward, while seeking
	playing: bool,
	speed:   f32, // steps a second while playing
	owed:    f64, // steps playback owes from earlier frames, below one
	last:    time.Tick, // when playback last advanced
	lapse:   Timelapse,
}

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
			app.camera.yaw += lapse.spin * (math.PI / 180)
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
		if !history_step_toward(app, tl.target) {
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

// The History panel: transport buttons, the timeline bar and the time-lapse controls.
draw_history_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("History") do return
	tl := &app.timeline
	lapse := &tl.lapse
	done, total := len(app.history.done), history_total(app)
	recording := lapse.state != .Off

	imgui.BeginDisabled(recording || app.stroke.active)
	seek :: proc(tl: ^Timeline, to: int) {
		tl.target, tl.seeking, tl.playing = to, true, false
	}
	if imgui.Button("|<") do seek(tl, 0)
	if imgui.IsItemHovered() do imgui.SetTooltip("Back to the start")
	imgui.SameLine()
	if imgui.ArrowButton("back", .Left) do seek(tl, done - 1)
	imgui.SameLine()
	if imgui.Button("Pause" if tl.playing else "Play", {48, 0}) {
		if tl.playing {
			tl.playing = false
		} else {
			// From the end, playback starts over from the beginning.
			if done >= total do seek(tl, 0)
			tl.playing, tl.owed, tl.last = true, 0, time.tick_now()
		}
	}
	imgui.SameLine()
	if imgui.ArrowButton("forward", .Right) do seek(tl, done + 1)
	imgui.SameLine()
	if imgui.Button(">|") do seek(tl, total)
	if imgui.IsItemHovered() do imgui.SetTooltip("Forward to the newest step")
	imgui.SameLine()
	imgui.Text("Step %d of %d", i32(done), i32(total))
	if done > 0 {
		e := app.history.done[done - 1]
		imgui.SameLine()
		imgui.TextDisabled("%s", fmt.ctprintf("%s, %s", entry_label(e), ago_label(e.at)))
	}

	draw_timeline_bar(app)

	imgui.SetNextItemWidth(160)
	imgui.SliderFloat("Steps a second", &tl.speed, 1, TIMELINE_SPEED_MAX, "%.0f", {.Logarithmic})
	imgui.EndDisabled()

	imgui.SameLine()
	imgui.Dummy({16, 0})
	imgui.SameLine()
	if recording {
		if imgui.Button("Stop recording") do timelapse_stop(app, "stopped")
		imgui.SameLine()
		if lapse.state == .Rewinding {
			imgui.Text("Rewinding...")
		} else {
			imgui.Text("Frame %d of %d", i32(lapse.frame), i32(lapse.end / int(max(lapse.steps, 1)) + 1))
		}
	} else {
		imgui.BeginDisabled(total == 0 || app.stroke.active)
		if imgui.Button("Record time-lapse...") do file_dialog(app, .Timelapse)
		imgui.EndDisabled()
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Choose a folder: the History is replayed from the start to where the\ntimeline stands, saving the viewport as numbered PNGs (frame_00000.png ...)\nwhich any video tool turns into a film.")
		}
		imgui.SameLine()
		imgui.SetNextItemWidth(80)
		imgui.SliderInt("Steps a frame", &lapse.steps, 1, 20)
		imgui.SameLine()
		imgui.SetNextItemWidth(80)
		imgui.SliderFloat("Turn", &lapse.spin, 0, 10, "%.1f deg")
		if imgui.IsItemHovered() do imgui.SetTooltip("Degrees the camera turns around the scene each frame: a turntable")
	}
}

// The bar itself: a tick per step coloured by its kind, the done part lit, a marker at
// the current position; click or drag to go there, hover for what a step was.
@(private = "file")
draw_timeline_bar :: proc(app: ^App) {
	HEIGHT :: 30
	tl := &app.timeline
	done, total := len(app.history.done), history_total(app)
	o := imgui.GetCursorScreenPos()
	width := max(imgui.GetContentRegionAvail().x, 50)
	size := imgui.Vec2{width, HEIGHT}
	imgui.InvisibleButton("timeline", size)
	list := imgui.GetWindowDrawList()
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	x_at :: proc(o: imgui.Vec2, width: f32, pos, total: int) -> f32 {
		return o.x + width * f32(pos) / f32(max(total, 1))
	}
	mouse := imgui.GetIO().MousePos
	under := clamp(int((mouse.x - o.x) / width * f32(max(total, 1)) + 0.5), 0, total)
	if imgui.IsItemActive() && total > 0 && under != tl.target {
		tl.target, tl.seeking, tl.playing = under, true, false
	}

	imgui.DrawList_AddRectFilled(list, o, o + size, rgba({0.1, 0.1, 0.12, 1}), 3)
	imgui.DrawList_AddRectFilled(list, o, {x_at(o, width, done, total), o.y + size.y}, rgba({0.32, 0.3, 0.26, 1}), 3)
	// A block per step, coloured by its kind and dimmed once undone; below about 3 px a
	// step they would merge, so they become lines of their kind's colour instead.
	gap := f32(1) if width / f32(max(total, 1)) >= 3 else 0
	for i in 0 ..< total {
		e := app.history.done[i] if i < done else app.history.undone[total - 1 - i]
		col := KIND_COLORS[e.kind]
		if i >= done do col.a = 0.3
		x0, x1 := x_at(o, width, i, total) + gap, max(x_at(o, width, i + 1, total) - gap, x_at(o, width, i, total) + 1)
		imgui.DrawList_AddRectFilled(list, {x0, o.y + 8}, {x1, o.y + size.y - 8}, rgba(col), 2 if gap > 0 else 0)
	}
	at := x_at(o, width, done, total)
	marker := rgba({1, 1, 1, 1})
	imgui.DrawList_AddLine(list, {at, o.y}, {at, o.y + size.y}, marker, 2)
	imgui.DrawList_AddTriangleFilled(list, {at - 5, o.y}, {at + 5, o.y}, {at, o.y + 6}, marker)
	if tl.seeking {
		ghost := x_at(o, width, tl.target, total)
		imgui.DrawList_AddLine(list, {ghost, o.y}, {ghost, o.y + size.y}, rgba({1, 1, 1, 0.4}), 1)
	}
	if imgui.IsItemHovered() && total > 0 {
		step := clamp(int((mouse.x - o.x) / width * f32(total)), 0, total - 1)
		e := app.history.done[step] if step < done else app.history.undone[total - 1 - step]
		imgui.SetTooltip("%s", fmt.ctprintf("Step %d: %s, object %d, %s%s", step + 1, entry_label(e), e.id, ago_label(e.at), "" if step < done else " (undone)"))
	}
}

@(private = "file", rodata)
KIND_COLORS := [History_Kind][4]f32 {
	.Stroke  = {0.95, 0.8, 0.45, 1},
	.Mask    = {0.5, 0.7, 1, 1},
	.Hide    = {0.7, 0.7, 0.7, 1},
	.Deform  = {0.6, 0.9, 0.6, 1},
	.Rebuild = {1, 0.5, 0.35, 1},
	.Paint   = {0.95, 0.5, 0.85, 1},
	.Layer   = {0.45, 0.9, 0.9, 1},
}

// How a step reads in the panel: "Clay stroke", "Blur mask", "remesh".
@(private = "file")
entry_label :: proc(e: History_Entry) -> string {
	if e.kind == .Stroke do return fmt.tprintf("%s stroke", e.what)
	return e.what
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
