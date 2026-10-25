package main

import "core:math/linalg"
import "core:time"

import "../camera"
import "../ui"

// Who a press on the viewport belongs to, decided once when it goes down and kept until
// every button is up, so a drag never changes what it does halfway (a stroke that
// wanders off the model keeps sculpting; an orbit that crosses the model keeps turning).
// As ZBrush does it:
// - right drag turns the view, Alt or Shift with it pans, Ctrl with it zooms; middle pans;
// - Alt and the left button turn the view;
// - the left button, a pen or one finger on the model drives the tool, and on empty space
//   turns the view (Settings > Touch and pen says what each does there); Ctrl keeps it
//   for the tool's own gestures on empty space (mask and hide shapes);
// - Shift while the view turns snaps it to the nearest view square to the axes.
// A finger or a pen turns nothing until it moves further than the slop, so a tap never
// nudges the view; the mouse has none, so it stays exact. Movement is measured from where
// the pointer was last frame, never from SDL's motion sum, so a pointer jumping to where
// a finger lands is no movement at all.
Drag :: struct {
	owner:   Drag_Owner,
	from:    [2]f32, // where it was pressed, window coordinates
	last:    [2]f32, // where the pointer was last frame
	travel:  f32, // the furthest it strayed from `from`
	moving:  bool, // past the slop (always, for a mouse)
	empty:   bool, // pressed on empty space
	// A finger's stroke on the model waits FINGER_HOLD (or the slop) before it begins, its
	// samples kept meanwhile, so a second finger landing with it makes a gesture without
	// sculpting first.
	pending: bool,
	held:    [dynamic]Input_Sample,
	at:      time.Tick,
	snap:    bool, // Shift snapped the view during this drag...
	free:    camera.Orbit, // ...which follows the drag unsnapped meanwhile
}

Drag_Owner :: enum u8 {
	None,
	Tool,
	Orbit,
	Pan,
	Zoom,
	Muted, // pressed, but nothing follows it (a palm, a finger while a gesture runs)
}

// What a pointer does dragged on empty space (Settings > Touch and pen).
Empty_Drag :: enum u8 {
	Orbit, // turns the view, as in ZBrush
	Tool, // goes to the tool, which sculpts once the drag reaches the model
}

// One finger on the model (Settings > Touch and pen).
Finger_Model :: enum u8 {
	Sculpt, // sculpts, as ZBrush's Touch Navigation does when on
	Orbit, // turns the view: only the pen sculpts, as on a drawing tablet
}

// How the pointer, fingers and pen drive the camera and the tools (Settings >
// Navigation, Touch and pen). Remembered by settings.odin.
Nav_Prefs :: struct {
	orbit_style:    camera.Orbit_Style,
	limit_pitch:    bool, // a turntable stops at straight up and straight down
	orbit_speed:    f32, // times the default
	pan_speed:      f32,
	zoom_speed:     f32,
	invert_x:       bool,
	invert_y:       bool,
	invert_wheel:   bool,
	finger_model:   Finger_Model,
	empty_drag:     [ui.Pointer_Kind]Empty_Drag, // a finger's is always Orbit
	pinch_zoom:     bool,
	two_finger_pan: bool,
	twist_roll:     bool, // ZBrush's Allow Roll Gesture
	zoom_toward:    bool, // ZBrush's Center Navigation on Pinch
	three_finger:   bool, // three fingers drag the brush's size and strength
	tap_history:    bool, // two fingers tap to undo, three to redo
	palm_rejection: bool, // a lone finger does nothing while the pen is near
}

NAV_DEFAULT :: Nav_Prefs {
	orbit_style    = .Free,
	orbit_speed    = 1,
	pan_speed      = 1,
	zoom_speed     = 1,
	finger_model   = .Sculpt,
	empty_drag     = {.Mouse = .Orbit, .Finger = .Orbit, .Pen = .Orbit},
	pinch_zoom     = true,
	two_finger_pan = true,
	twist_roll     = true,
	zoom_toward    = true,
	three_finger   = true,
	tap_history    = true,
	palm_rejection = true,
}

// The camera's turn as the settings have it.
orbit_settings :: proc(app: ^App) -> camera.Orbit_Settings {
	n := app.nav
	return {style = n.orbit_style, limit_pitch = n.limit_pitch, speed = camera.ORBIT_SPEED * n.orbit_speed, invert_x = n.invert_x, invert_y = n.invert_y}
}

// Gives this frame's pointer on the viewport to its drag's owner: the tool sees primary,
// press and samples only while it owns the drag, the camera sees orbit, pan and zoom
// drags with how far the pointer moved. Runs in kit_viewport_input after touch_route.
pointer_route :: proc(app: ^App, input: ^Viewport_Input) {
	d := &app.device
	t := &app.touch
	g := &app.drag
	buttons := d.down & {.Left, .Right, .Middle}

	// A gesture or a cancel ends the drag the pointer began: a stroke not yet begun is
	// dropped, one begun is kept (or, cancelled, taken back).
	if (t.owner == .Viewport && t.gesture) || t.cancelled {
		if g.owner == .Tool && !g.pending {
			if t.cancelled do stroke_cancel(app)
			else do stroke_finish(app)
		}
		if g.owner != .None {
			g.owner, g.pending = .Muted, false
			clear(&g.held)
		}
		t.cancelled = false
		route_mute(input)
		// The pen that cancelled a finger's touch by landing has a drag of its own, decided
		// next frame while it stays down.
		if buttons == {} || d.pointer == .Pen do g.owner = .None
		return
	}

	// A drag is decided as it is pressed (a click within one frame too), or the frame
	// after a cancel, while still held.
	if g.owner == .None && input.dragging && (buttons != {} || d.pressed & {.Left, .Right, .Middle} != {}) {
		owner, empty := drag_decide(app, input^)
		g^ = {owner = owner, empty = empty, from = d.mouse, last = d.mouse, at = time.tick_now(), held = g.held}
		g.moving = d.pointer == .Mouse
		g.pending = g.owner == .Tool && d.pointer == .Finger && app.tool == .Brush
		clear(&g.held)
	}
	if g.owner == .None {
		input.orbit_drag, input.pan_drag, input.primary, input.press = false, false, false, false
		return
	}

	g.travel = max(g.travel, linalg.length(d.mouse - g.from))
	slop := app.kit.ctx.theme.slop * app.kit.scale
	delta := d.mouse - g.last
	g.last = d.mouse
	if !g.moving && g.travel > slop {
		// Past the slop: from here on it moves, from where it is now.
		g.moving = true
		delta = {}
	}
	if !g.moving do delta = {}

	switch g.owner {
	case .None, .Muted:
		route_mute(input)
	case .Tool:
		input.orbit_drag, input.pan_drag = false, false
		if g.pending {
			append(&g.held, ..input.samples)
			lifted := buttons == {}
			if lifted || g.travel > slop || time.tick_since(g.at) >= FINGER_HOLD {
				// One finger after all: the stroke begins where the finger first landed,
				// following every sample it made meanwhile.
				g.pending = false
				samples := make([]Input_Sample, len(g.held), context.temp_allocator)
				copy(samples, g.held[:])
				clear(&g.held)
				input.samples = samples
				input.primary, input.press = true, true
			} else {
				input.primary, input.press = false, false
				input.samples = {}
			}
		}
	case .Orbit:
		route_mute(input)
		if d.shift {
			// ZBrush's Shift: the view jumps to the nearest square view, and a drag far
			// enough to turn the unsnapped view past halfway jumps to the next one.
			if !g.snap do g.snap, g.free = true, app.camera
			camera.orbit_rotate(&g.free, delta, orbit_settings(app))
			snapped := g.free
			camera.orbit_snap(&snapped)
			app.camera.yaw, app.camera.pitch, app.camera.roll = snapped.yaw, snapped.pitch, snapped.roll
		} else {
			g.snap = false
			input.orbit_drag, input.mouse_delta = true, delta
		}
	case .Pan:
		route_mute(input)
		input.pan_drag, input.mouse_delta = true, delta
	case .Zoom:
		route_mute(input)
		input.zoom_drag, input.mouse_delta = true, delta
	}

	if buttons == {} {
		// A tap on empty space with the Move tool clears the selection, as its click did
		// before empty space turned the view.
		if g.owner == .Orbit && g.empty && app.tool == .Move && g.travel <= slop do app.scene.selected = -1
		g.owner = .None
	}
}

// Who a press on the viewport belongs to (see Drag).
@(private = "file")
drag_decide :: proc(app: ^App, input: Viewport_Input) -> (owner: Drag_Owner, empty: bool) {
	d := &app.device
	held := d.down + d.pressed
	if .Right in held {
		if d.ctrl do return .Zoom, false
		if d.shift || d.alt do return .Pan, false
		return .Orbit, false
	}
	if .Middle in held do return .Zoom if d.ctrl else .Pan, false
	if d.alt && !d.ctrl do return .Orbit, false
	if d.pointer == .Finger {
		if app.touch.palm do return .Muted, false
		if app.nav.finger_model == .Orbit do return .Orbit, false
	}
	// Empty space turns the view for the brushes and the Move tool; Ctrl keeps it for the
	// mask and hide shapes, which start there.
	if (app.tool == .Brush || app.tool == .Move) && !d.ctrl {
		empty := app.nav.empty_drag[d.pointer] if d.pointer != .Finger else .Orbit
		if empty == .Orbit {
			origin, dir := mouse_ray(app.camera, d.mouse, input.size)
			if _, _, hit := scene_raycast(app, origin, dir); !hit do return .Orbit, true
		}
	}
	return .Tool, false
}

@(private = "file")
route_mute :: proc(input: ^Viewport_Input) {
	input.primary, input.press, input.smooth, input.invert, input.alt = false, false, false, false, false
	input.orbit_drag, input.pan_drag, input.zoom_drag = false, false, false
	input.samples = {}
}

// Ends the stroke in progress and takes it back, as when the system cancels the touch
// that drew it (a palm was recognised, the pen came down): Redo brings it back.
stroke_cancel :: proc(app: ^App) {
	if !app.stroke.active do return
	before := len(app.history.done)
	stroke_finish(app)
	if len(app.history.done) > before && history_can_undo(app) do history_undo(app)
}

// Moves the camera by this frame's viewport input, as the settings say.
camera_apply_input :: proc(app: ^App, in_: Viewport_Input) {
	c := &app.camera
	nav := app.nav
	// Two or more fingers on the viewport (touch_route) navigate with no pointer down.
	if in_.touch_pan != {} do camera.orbit_pan(c, in_.touch_pan, in_.size.y)
	if in_.touch_zoom > 0 do camera.orbit_zoom_toward(c, in_.touch_zoom, in_.touch_zoom_at, in_.size.y)
	if in_.touch_roll != 0 do camera.orbit_roll(c, in_.touch_roll)
	if !in_.hovered && !in_.dragging do return
	if in_.primary do return
	switch {
	case in_.orbit_drag:
		camera.orbit_rotate(c, in_.mouse_delta, orbit_settings(app))
	case in_.pan_drag:
		camera.orbit_pan(c, in_.mouse_delta * nav.pan_speed, in_.size.y)
	case in_.zoom_drag:
		// Up zooms in, as ZBrush's Ctrl and right drag: 100 pixels is about four wheel notches.
		camera.orbit_zoom(c, -in_.mouse_delta.y * 0.04 * nav.zoom_speed)
	}
	if in_.hovered && in_.wheel != 0 {
		camera.orbit_zoom(c, (-in_.wheel if nav.invert_wheel else in_.wheel) * nav.zoom_speed)
	}
}
