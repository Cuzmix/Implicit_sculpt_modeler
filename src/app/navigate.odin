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
	pivot:   Vec3, // what an orbit turns about, decided at the press (orbit_pivot)
}

// What the view turns about (Settings > Camera). The pivot stays where it is on screen
// while the view turns about it, so nothing jumps when an orbit starts.
Orbit_Pivot :: enum u8 {
	// The middle of the last stroke, as ZBrush's Local and Blender's Orbit Around Selection
	// in sculpt mode turn: the part being worked on stays in view. Before any stroke, the
	// selected object's middle.
	Stroke,
	// The surface under the press, as Blender's Auto Depth: a right drag over the model
	// turns about that spot. A press on empty space turns as Stroke does.
	Pointer,
	// The middle of the view, the camera's target: the model swings about the screen's
	// middle wherever it is.
	Centre,
}

// Where the pivot of the last orbit came from, for the exit stats.
Pivot_Source :: enum u8 {
	Centre,
	Stroke,
	Pointer,
	Object,
}

// The middle of the last stroke, in its object's own space so it follows the object when
// the Move tool moves it, and what the last orbit turned about.
Stroke_Pivot :: struct {
	object: int, // the stroke's object, by id
	at:     Vec3,
	set:    bool, // a stroke has ended since the view was last framed or reset
	used:   Vec3, // the last orbit's pivot, in world space
	from:   Pivot_Source,
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
	pivot:          Orbit_Pivot,
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
	// The safe zone, as the SculptNavigation add-on's border: a press this close to an
	// edge turns the view even over the model, so a view filled by the model can still
	// be turned with one finger, the pen or the left button.
	edge_orbit:     bool,
	edge_size:      f32, // points, EDGE_MIN to EDGE_MAX
	edge_show:      bool, // outline where the band ends
}

// The safe zone's width, in points: from half a touch target to a broad band.
EDGE_MIN :: 24
EDGE_MAX :: 200

NAV_DEFAULT :: Nav_Prefs {
	orbit_style    = .Free,
	pivot          = .Stroke,
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
	edge_orbit     = true,
	// A touch target and a bit, near the add-on's 75 pixels.
	edge_size      = 64,
	edge_show      = true,
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
		if owner == .Orbit {
			g.pivot, app.pivot.from = orbit_pivot(app, d.mouse, input.size)
			app.pivot.used = g.pivot
		}
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
			before := app.camera
			app.camera.yaw, app.camera.pitch, app.camera.roll = snapped.yaw, snapped.pitch, snapped.roll
			camera.orbit_turn_about(&app.camera, before, g.pivot)
		} else {
			g.snap = false
			input.orbit_drag, input.mouse_delta, input.orbit_pivot = true, delta, g.pivot
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
	// The safe zone turns the view whatever is under it, for every tool; Ctrl keeps it for
	// the mask and hide shapes, as on empty space.
	if !d.ctrl && in_edge(app, d.mouse) do return .Orbit, false
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

// What an orbit pressed at `at` turns about, as Settings > Camera says, in world space:
// the surface under the press, the middle of the last stroke, the selected object's
// middle, or else the target. A point behind the eye is passed over, since turning about
// it would swing what is in front of the eye out of view.
@(private = "file")
orbit_pivot :: proc(app: ^App, at, size: [2]f32) -> (pivot: Vec3, from: Pivot_Source) {
	c := app.camera
	switch app.nav.pivot {
	case .Centre:
		return c.target, .Centre
	case .Pointer:
		origin, dir := mouse_ray(c, at, size)
		if _, hit, ok := scene_raycast(app, origin, dir); ok && in_front(c, hit) do return hit, .Pointer
	case .Stroke:
	}
	if p := app.pivot; p.set {
		if obj := object_by_id(app, p.object); obj != nil {
			if w := to_world(obj.transform, p.at); in_front(c, w) do return w, .Stroke
		}
	}
	if obj := selected_object(app); obj != nil {
		if w := object_middle(obj); in_front(c, w) do return w, .Object
	}
	return c.target, .Centre

	// A parallel view shows what is behind the eye too, so anything will do there.
	in_front :: proc(c: camera.Orbit, p: Vec3) -> bool {
		_, _, back := camera.orbit_basis(c)
		return c.ortho || linalg.dot(p - camera.orbit_eye(c), -back) > c.near
	}
}

// Where the safe zone ends, in window coordinates: the safe area less `edge_size` points
// on every side. Inside it the tools and empty space decide; outside, the edges turn the view.
edge_inner :: proc(app: ^App) -> (lo, hi: [2]f32) {
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	band := app.nav.edge_size
	return [2]f32{area.x + band, area.y + band} * k.scale, [2]f32{area.x + area.w - band, area.y + area.h - band} * k.scale
}

// Whether `p` (window coordinates) is in the safe zone, when it is on.
in_edge :: proc(app: ^App, p: [2]f32) -> bool {
	if !app.nav.edge_orbit do return false
	lo, hi := edge_inner(app)
	return p.x < lo.x || p.y < lo.y || p.x > hi.x || p.y > hi.y
}

// The middle of the object's bounds in world space: its sculptor's BVH root box, which
// follows every stroke, or its origin before it has one.
object_middle :: proc(obj: ^Object) -> Vec3 {
	s := object_sculptor(obj)
	if len(s.bvh.nodes) == 0 do return obj.transform.position
	b := s.bvh.nodes[0].bounds
	return to_world(obj.transform, (b.lo + b.hi) * 0.5)
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
		before := c^
		camera.orbit_rotate(c, in_.mouse_delta, orbit_settings(app))
		camera.orbit_turn_about(c, before, in_.orbit_pivot)
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
