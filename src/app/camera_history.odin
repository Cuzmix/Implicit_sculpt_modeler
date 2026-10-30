package main

import "../camera"

// Camera history: Previous view and Next view walk back and forward through the views the
// camera rested on, as a browser walks its pages, apart from the undo of the work (ZBrush
// keeps such a camera undo; here it has keys, the View menu and a gesture to choose). A
// view counts once the camera has stayed still a moment with nothing turning it, so every
// way it moves, from a drag to Frame all, is covered without each one saying so.

CAMERA_VIEWS :: 32
// Long enough that a pause between two wheel clicks or two flicks of an orbit is not a
// view of its own; short enough that a look just taken is there to go back to.
CAMERA_REST :: 0.4

// What a view is: where the camera looks from. The projection and the field of view are
// modes of their own, which going back does not change.
Camera_View :: struct {
	target:   Vec3,
	distance: f32,
	yaw:      f32,
	pitch:    f32,
	roll:     f32,
}

Camera_History :: struct {
	views:    [CAMERA_VIEWS]Camera_View, // oldest first
	count:    int,
	at:       int, // the one shown, or the one the camera left
	seen:     Camera_View, // the camera at the last frame...
	moved_at: f64, // ...and when it last changed, on the interface's clock
	steps:    int, // back and forward taken, for the exit stats
}

camera_view_of :: proc(c: camera.Orbit) -> Camera_View {
	return {c.target, c.distance, c.yaw, c.pitch, c.roll}
}

// Keeps the camera's view once it has rested, dropping any views ahead of the one shown
// (as a new page drops a browser's forward pages). Called once a frame.
camera_history_frame :: proc(app: ^App) {
	h := &app.views
	now := app.kit.ctx.time
	v := camera_view_of(app.camera)
	moved := v != h.seen
	if moved do h.seen, h.moved_at = v, now
	// Mid-turn, or the camera follows something played back: not a place it rested.
	// Nor while a view pane is worked in: the camera is that pane's (grid_work), nor while
	// it glides to a view (camera_ease.odin), which it rests on once there.
	if app.drag.owner != .None || app.touch.fingers.count > 0 || timeline_busy(app) || replay_busy(app) || app.kit.grid.work != 0 || app.camera_ease.on do return
	// The view a scene opens with is the first, at once: a turn begun straight away
	// must still be able to go back to it.
	if h.count > 0 && (moved || now - h.moved_at < CAMERA_REST) do return
	camera_history_keep(h, v)
}

// Adds `v` after the view shown unless it is that view.
@(private = "file")
camera_history_keep :: proc(h: ^Camera_History, v: Camera_View) {
	if h.count > 0 && h.views[h.at] == v do return
	if h.count > 0 do h.count = h.at + 1
	if h.count == CAMERA_VIEWS {
		copy(h.views[:], h.views[1:])
		h.count -= 1
	}
	h.views[h.count] = v
	h.at = h.count
	h.count += 1
}

// The view the camera shows, or is gliding to (camera_ease.odin): what going back and
// forward start from, so a second step taken mid-glide steps on from where the first went.
camera_view_shown :: proc(app: ^App) -> Camera_View {
	return camera_view_of(app.camera_ease.to if app.camera_ease.on else app.camera)
}

camera_can_back :: proc(app: ^App) -> bool {
	h := &app.views
	return h.count > 0 && (h.at > 0 || camera_view_shown(app) != h.views[h.at])
}

// Forward only while the camera is still on the view shown: once it moves, that move is
// where forward goes, as it is for a browser.
camera_can_forward :: proc(app: ^App) -> bool {
	h := &app.views
	return h.at + 1 < h.count && camera_view_shown(app) == h.views[h.at]
}

// Shows the view before. A view not kept yet (the camera moved and has not rested) is
// kept first, so Next view comes back to it.
camera_back :: proc(app: ^App) {
	if !camera_can_back(app) do return
	h := &app.views
	camera_history_keep(h, camera_view_shown(app))
	camera_show(app, h.at - 1)
}

camera_forward :: proc(app: ^App) {
	if camera_can_forward(app) do camera_show(app, app.views.at + 1)
}

// Shows `v` (View from this step, in the History's step menu), keeping the view shown
// first and `v` after it, so Previous view comes back to where the camera was.
camera_go :: proc(app: ^App, v: Camera_View) {
	h := &app.views
	camera_history_keep(h, camera_view_shown(app))
	camera_history_keep(h, v)
	camera_show(app, h.at)
}

@(private = "file")
camera_show :: proc(app: ^App, at: int) {
	h := &app.views
	h.at = at
	v := h.views[at]
	app.camera.target, app.camera.distance, app.camera.yaw, app.camera.pitch, app.camera.roll = v.target, v.distance, v.yaw, v.pitch, v.roll
	// A jump, not a move: it does not start a rest that would keep it again.
	h.seen = v
	h.steps += 1
}

// Forgets the views, when the scene is replaced: its views are of another scene.
camera_history_clear :: proc(app: ^App) {
	steps := app.views.steps
	app.views = {steps = steps}
}
