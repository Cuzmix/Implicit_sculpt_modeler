package main

import "core:math"

import "../camera"
import "../ui"

// The camera ease (the overhaul's round 3, Motion II): Frame all, Focus selected, Reset
// camera, the axis views, Previous and Next view and a double tap's frame glide to the
// view they ask for rather than jump, as Blender's smooth view and ZBrush's framing do, so
// the eye keeps its place on the model. Only the camera moves, never the model, and only
// for a moment: navigating on the view stops it where it is, so the hand takes over from
// what it sees, and a press that sculpts sends it to the end first, so the stroke lands
// on the view asked for. Settings > Interface > Motion turns it off (Camera moves).

// How long a glide takes, on the interface's clock.
CAMERA_EASE_TIME :: 0.32

Camera_Ease :: struct {
	from, to: camera.Orbit,
	start:    f64, // the interface's clock when it set off
	on:       bool,
	allowed:  bool, // an interactive run, or --camera-ease (main.odin)
	eases:    int, // glides begun and cut short, for the exit stats
	cuts:     int,
}

// Whether a jump may glide now: motion moves the camera, and nothing plays, records or
// scripts the camera, which must land where it is sent at once.
camera_ease_allowed :: proc(app: ^App) -> bool {
	e := &app.camera_ease
	if !e.allowed || !ui.motion_moves(&app.kit.ctx, motion_class(.Camera)) do return false
	if app.script.running || replay_busy(app) || app.replay.recording || timeline_busy(app) || app.turntable.on do return false
	return app.kit.grid.work == 0
}

// Before a jump: the camera as it shows now, for camera_ease_from, with a glide under way
// sent to its end first, so the jump starts from the view the last one asked for.
camera_ease_begin :: proc(app: ^App) -> camera.Orbit {
	e := &app.camera_ease
	shown := app.camera
	if e.on do app.camera, e.on = e.to, false
	return shown
}

// After a jump that put the camera where it is now from `before`: the camera goes back to
// `before` and glides to the new view, when it changed and gliding is allowed.
camera_ease_from :: proc(app: ^App, before: camera.Orbit) {
	e := &app.camera_ease
	to := app.camera
	if to == before || !camera_ease_allowed(app) {
		e.on = false
		return
	}
	e.from, e.to, e.start, e.on = before, to, app.kit.ctx.time, true
	e.eases += 1
	app.camera = before
	app.camera.fov_y, app.camera.near, app.camera.far, app.camera.ortho = to.fov_y, to.near, to.far, to.ortho
}

// Moves a glide on, once a frame before the view's input turns the camera: navigation on
// the view stops it where it is, a press that sculpts ends it at once, and otherwise it
// moves along its curve and lands exactly on the view asked for.
camera_ease_frame :: proc(app: ^App, input: Viewport_Input) {
	e := &app.camera_ease
	if !e.on do return
	navigates := input.touch_pan != {} || input.touch_zoom > 0 || input.touch_roll != 0 || input.touch_orbit != {}
	navigates ||= (input.hovered || input.dragging) && !input.primary && (input.orbit_drag || input.pan_drag || input.zoom_drag) && input.mouse_delta != {}
	navigates ||= input.hovered && input.wheel != 0
	if navigates || input.primary || !camera_ease_allowed(app) {
		e.on = false
		e.cuts += 1
		if input.primary || !camera_ease_allowed(app) do app.camera = e.to
		return
	}
	t := f32(app.kit.ctx.time - e.start) / CAMERA_EASE_TIME
	if t >= 1 {
		app.camera = e.to
		e.on = false
		return
	}
	app.camera = camera_ease_at(e.from, e.to, ui.ease(.Out_Cubic, t))
}

// The view `k` (0 to 1) of the way from `a` to `b`: the target and the shift in a straight
// line, the distance by the same factor each step (so a long zoom reads even), and each
// angle the shorter way round; the lens is `b`'s.
camera_ease_at :: proc(a, b: camera.Orbit, k: f32) -> camera.Orbit {
	if k >= 1 do return b
	c := b
	c.target = a.target + (b.target - a.target) * k
	c.shift = a.shift + (b.shift - a.shift) * k
	if a.distance > 0 && b.distance > 0 {
		c.distance = a.distance * math.pow(b.distance / a.distance, k)
	} else {
		c.distance = a.distance + (b.distance - a.distance) * k
	}
	c.yaw = camera.wrap_angle(a.yaw + angle_between(a.yaw, b.yaw) * k)
	c.pitch = camera.wrap_angle(a.pitch + angle_between(a.pitch, b.pitch) * k)
	c.roll = camera.wrap_angle(a.roll + angle_between(a.roll, b.roll) * k)
	return c

	// The turn from `from` to `to` the shorter way round, in (-pi, pi].
	angle_between :: proc(from, to: f32) -> f32 {
		d := math.mod(to - from, 2 * math.PI)
		if d > math.PI do d -= 2 * math.PI
		if d <= -math.PI do d += 2 * math.PI
		return d
	}
}
