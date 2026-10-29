package main

import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../sculpt"
import "../ui"
import sdl "vendor:sdl3"

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
	at:      f64, // input_clock at the press
	snap:    bool, // Shift snapped the view during this drag...
	free:    camera.Orbit, // ...which follows the drag unsnapped meanwhile
	pivot:   Vec3, // what an orbit turns about, decided at the press (orbit_pivot)
	// What the keys and the rail said at the press. A finger's stroke that waited begins
	// with them even when it begins on the frame the finger lifts, when the rail has let
	// go of the press and the keys' flags read as up.
	mods:    Stroke_Mods,
	edge:    bool, // pressed in the safe zone
	selected: int, // the selection when it was pressed, which a tap may clear
	// A finger's brush press that may be a tap of a double tap: it waits FINGER_TAP rather
	// than FINGER_HOLD to begin, and as a tap its dab waits for a second one (Dab_Wait).
	defer_tap: bool,
	// A press with Mask on (the rail's Mask, or Ctrl off the model) that may be a tap: it
	// waits FINGER_TAP too, and as a tap runs a mask command chosen by where it landed
	// (mask_tap_act) instead of painting a dot.
	mask_tap:  bool,
}

// The modifiers of a primary drag, as Viewport_Input carries them.
Stroke_Mods :: struct {
	smooth, invert, mask, mask_shape, alt: bool,
}

// The last finger tap that could begin a double tap, and what double taps did.
Double_Tap :: struct {
	valid:    bool,
	at:       f64, // input_clock when it lifted
	pos:      [2]f32,
	selected: int, // the selection before it, which a Move tool tap clears
	framed:   int, // double taps on empty space, for the exit stats
}

// A second tap begins this soon after the first lifted (Android's double tap timeout)...
DOUBLE_TAP_GAP :: 0.30
// ...and this close to it, in points.
DOUBLE_TAP_REACH :: 48

// A finger's tap on the model while it sculpts, whose dab waits to see whether a second
// tap makes it a double tap. It plays as a stroke of its own, with the view, brush and
// modifiers it was tapped with, once the gap runs out or anything else happens first (a
// key, the mouse, the wheel, the pen, a finger landing elsewhere or a second finger), so
// it never lands after something that should have come after it: dab_wait_event marks
// that, and dab_wait_resolve plays it at the start of the next frame, before the panels,
// the keys or the tools run. A second tap drops it and acts instead.
Dab_Wait :: struct {
	active:  bool,
	play:    bool, // something else happened: play it now
	second:  bool, // a finger landed within the gap and reach: maybe the second tap...
	checked: bool, // ...and a frame went by since, in which it became a press or did not
	samples: [dynamic]Input_Sample, // the tap's press to release
	mods:    Stroke_Mods,
	camera:  camera.Orbit,
	brush:   Brush_Settings,
	size:    [2]f32, // the viewport's, when tapped
	at:      f64, // input_clock when the tap lifted
	pos:     [2]f32, // where it was pressed, in window coordinates, as the next finger comes
}

// Whether a tap pressed at `at` and `pos` is the second of a double tap after `first`.
double_tap_follows :: proc(first: Double_Tap, at: f64, pos: [2]f32, reach: f32) -> bool {
	return first.valid && at >= first.at && at - first.at <= DOUBLE_TAP_GAP && linalg.length(pos - first.pos) <= reach
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
	// middle wherever it is, as Blender turns with Orbit Around Selection off.
	Centre,
	// The middle of the selected objects, as Blender's Orbit Around Selection in Object
	// Mode and Nomad's Selection pivot: strokes do not move it.
	Selection,
	// The middle of every shown object, as Nomad's Scene pivot: the whole scene turns as
	// one piece.
	Scene,
}

// Where the pivot of the last orbit came from, for the exit stats.
Pivot_Source :: enum u8 {
	Centre,
	Stroke,
	Pointer,
	Object,
	Tapped, // a double tap pinned it
	Selection,
	Scene,
	Air, // Pointer off the model, with Turn about the air under the pointer on
}

// The middle of the last stroke, in its object's own space so it follows the object when
// the Move tool moves it, and what the last orbit turned about.
Stroke_Pivot :: struct {
	object: int, // the stroke's object, by id
	at:     Vec3,
	set:    bool, // a stroke has ended since the view was last framed or reset
	used:   Vec3, // the last orbit's pivot, in world space
	from:   Pivot_Source,
	// A double tap on the model put `object` and `at` there: every orbit turns about it,
	// whatever Turn about says, until the next stroke, a framing or the object going.
	pinned: bool,
	flash:  f64, // input_clock when it was pinned, for the dot's pulse
}

// How long the dot pulses where a double tap pinned the pivot.
PIN_FLASH :: 0.8

Drag_Owner :: enum u8 {
	None,
	Tool,
	Orbit,
	Pan,
	Zoom,
	Muted, // pressed, but nothing follows it (a palm, a finger while a gesture runs)
	Shape, // a handle of the shape waiting for Apply (shape_pending.odin)
}

// Which app's mouse buttons the view follows (Settings > Keys): what a right or middle
// drag, or one with Alt, does to the camera. The left button, the wheel, the safe zone,
// fingers and the pen are the same in all three.
Mouse_Scheme :: enum u8 {
	ZBrush, // right turns, middle pans
	Blender, // middle turns, Shift+middle pans, Ctrl+middle zooms
	Maya, // Alt+left turns, Alt+middle pans, Alt+right zooms
}

// What the camera does with a drag of `held` buttons under `scheme`, with these modifiers
// held as it was pressed; `decided` is false when the buttons leave it to the tool, the
// fingers and empty space (drag_decide). The right button comes before the middle, and
// both before Alt with the left.
mouse_button_owner :: proc(scheme: Mouse_Scheme, held: ui.Buttons, ctrl, shift, alt: bool) -> (owner: Drag_Owner, decided: bool) {
	if .Right in held {
		switch {
		case ctrl:                    return .Zoom, true
		case alt && scheme == .Maya: return .Zoom, true
		case shift || alt:            return .Pan, true
		}
		return .Orbit, true
	}
	if .Middle in held {
		switch {
		case ctrl:                       return .Zoom, true
		case scheme == .Blender && !shift: return .Orbit, true
		}
		return .Pan, true
	}
	if alt && !ctrl do return .Orbit, true
	return .None, false
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
	// A turntable may roll: twisting two fingers tilts it on screen (twist_rolls), and
	// drags then turn it about the world's up wherever that shows.
	turntable_roll: bool,
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
	three_finger:   bool, // three fingers drag the brush's size and focal shift
	touch_strength: f32, // a finger's strokes at this much of the brush's strength, TOUCH_STRENGTH_MIN to 1
	// Seconds a finger or the pen holds a control still for its long press (the theme's
	// long_press), HOLD_DELAY_MIN to HOLD_DELAY_MAX, as Android's Touch & hold delay.
	hold_delay:     f32,
	palm_rejection: bool, // a lone finger does nothing while the pen is near
	double_tap:     bool, // a finger's double tap frames, or pins the pivot on the model
	lift_one_orbit: bool, // two fingers down, one lifted: the other turns the view
	// Pointer off the model: turn about the point under the pointer as deep as the view's
	// middle (Nomad's Allow air pivot) instead of about the last stroke.
	air_pivot:      bool,
	pivot_dot:      bool, // show the dot the view turns about while it turns (Nomad can hide it)
	// The wheel zooms toward the pointer, keeping what is under it there, as Blender's Zoom
	// to Mouse Position and a pinch toward the fingers do; off, toward the middle.
	wheel_toward:   bool,
	// What the multi-finger taps and holds and the pen's side button run (gesture_map.odin).
	gestures:       [Gesture_Slot]Pie_Slot,
	// The safe zone, as the SculptNavigation add-on's border: a press this close to an
	// edge turns the view even over the model, so a view filled by the model can still
	// be turned with one finger, the pen or the left button.
	edge_orbit:     bool,
	edge_size:      f32, // points, EDGE_MIN to EDGE_MAX
	edge_show:      bool, // outline where the band ends
	mouse_scheme:   Mouse_Scheme,
	shape_apply:    Shape_Apply, // when a drawn mask, hide or clip shape applies (shape_pending.odin)
	pen_tips:       Pen_Tips, // when a hovering pen shows a control's name
	eraser:         Eraser_Use, // what the pen's eraser end sculpts with (pencil.odin)
}

// When the pen, held over a control without touching, shows its name and shortcut, as
// the mouse resting on it does: always, only while a keyboard is connected (when the
// shortcuts it shows can be used), or never. A long press shows it whatever this says.
Pen_Tips :: enum u8 {
	Always,
	With_Keyboard,
	Never,
}

// Whether twisting two fingers rolls the view: in Trackball, and in Turntable once its roll
// is unlocked (Settings > Camera), as ZBrush's Allow Roll Gesture is.
twist_rolls :: proc(n: Nav_Prefs) -> bool {
	return n.twist_roll && (n.orbit_style == .Free || n.orbit_style == .Turntable && n.turntable_roll)
}

// A turntable's roll the fingers bring within this many radians of level is held level,
// as Procreate holds its canvas square, so twisting back finds level again.
ROLL_LEVEL :: 4 * math.PI / 180

// The roll that `roll` (radians, within a turn of 0) shows with the detent at level: 0
// within ROLL_LEVEL of it, then catching up at twice the pace until twice that, and
// itself beyond, so the view never jumps on its way into or out of level.
roll_level_detent :: proc(roll: f32) -> f32 {
	a := abs(roll)
	if a >= 2 * ROLL_LEVEL do return roll
	return math.sign(roll) * max(2 * (a - ROLL_LEVEL), 0)
}

// The roll that roll_level_detent turns into `shown`, so a twist that starts on a view the
// detent left part way picks up from what is on screen, with no jump.
roll_level_undetent :: proc(shown: f32) -> f32 {
	a := abs(shown)
	if a >= 2 * ROLL_LEVEL || a == 0 do return shown
	return math.sign(shown) * (a / 2 + ROLL_LEVEL)
}

// The least Touch strength: a finger's strokes at a tenth of the brush's strength, for a
// light touch where the pen does the heavy work.
TOUCH_STRENGTH_MIN :: 0.1

// The Hold delay's range: from a tenth of a second, about as long as a quick tap, for hands
// that want the long press at once, to Android's Long (1.5 s), for hands that need the time.
HOLD_DELAY_MIN :: 0.1
HOLD_DELAY_MAX :: 1.5

// The safe zone's width, in points: from half a touch target to a broad band.
EDGE_MIN :: 24
EDGE_MAX :: 200

NAV_DEFAULT :: Nav_Prefs {
	orbit_style    = .Turntable,
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
	touch_strength = 1,
	hold_delay     = 0.25,
	palm_rejection = true,
	double_tap     = true,
	lift_one_orbit = true,
	pivot_dot      = true,
	gestures       = GESTURE_DEFAULTS,
	edge_orbit     = true,
	// A touch target and a bit, near the add-on's 75 pixels.
	edge_size      = 64,
	edge_show      = true,
	// Smooth takes a stroke back, the nearest thing sculpting has to erasing.
	eraser         = .Smooth,
}

// The camera's turn as the settings have it.
orbit_settings :: proc(app: ^App) -> camera.Orbit_Settings {
	n := app.nav
	return {style = n.orbit_style, limit_pitch = n.limit_pitch, speed = camera.ORBIT_SPEED * n.orbit_speed, invert_x = n.invert_x, invert_y = n.invert_y, axis_sign = app.orbit_sign}
}

// Decides, as a turn of the view begins, which way round the X and Z axis orbits go for
// the rest of it (camera.Orbit_Settings.axis_sign).
orbit_latch :: proc(app: ^App) {
	app.orbit_sign = camera.orbit_axis_sign(app.camera, app.nav.orbit_style)
}

// Gives this frame's pointer on the viewport to its drag's owner: the tool sees primary,
// press and samples only while it owns the drag, the camera sees orbit, pan and zoom
// drags with how far the pointer moved. Runs in kit_viewport_input after touch_route.
pointer_route :: proc(app: ^App, input: ^Viewport_Input) {
	d := &app.device
	// The pointer in the main pane's coordinates, as the input has it.
	mouse := viewport_point(app, d.mouse)
	t := &app.touch
	g := &app.drag
	buttons := d.down & {.Left, .Right, .Middle}
	one_tap_wait(app)

	// A gesture or a cancel ends the drag the pointer began: a stroke not yet begun is
	// dropped, one begun is kept (or, cancelled, taken back).
	if (t.owner == .Viewport && t.gesture) || t.cancelled {
		if g.owner == .Tool && !g.pending {
			if t.cancelled do stroke_cancel(app)
			else do brush_stroke_finish(app)
		}
		// A handle dragged by a finger that became a gesture goes back where it was, and
		// so does an object the Move tool was dragging.
		if g.owner == .Shape do shape_release(app, true)
		if g.owner == .Tool && app.tool == .Move do move_cancel(app)
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
		// A one-finger tap still waiting runs before anything else acts, unless this press
		// may be the second tap of a double tap, which decides on its lift.
		if app.one_tap > 0 && !(owner == .Orbit && empty && d.pointer == .Finger) do one_tap_run(app)
		g^ = {owner = owner, empty = empty, from = mouse, last = mouse, at = input_clock(app), held = g.held, edge = in_edge(app, mouse), selected = app.scene.selected}
		g.mods = {input.smooth, input.invert, input.mask, input.mask_shape, input.alt}
		// Only a finger's tap that turns the view can be the second of a double tap.
		if !(owner == .Orbit && d.pointer == .Finger && !g.edge) do app.double_tap.valid = false
		g.moving = d.pointer == .Mouse
		// A finger's press the lights take (a marker, or the model with Place highlight on)
		// or Pick focus waits for acts as it lands, never waiting to see whether it is a tap.
		g.pending = g.owner == .Tool && d.pointer == .Finger && app.tool == .Brush && !lights_take_press(app, mouse, input.size) && !app.ui.focus_armed
		// Not the presses that go to the mask and hide shapes or a clip, nor during a replay.
		g.defer_tap = g.pending && app.nav.double_tap && !d.shift && !d.ctrl && !d.alt && !rail_keeps_empty_space(app.rail.press.mods) && !replay_busy(app)
		if owner == .Tool && app.tool == .Brush && !d.shift && (input.mask || input.mask_shape) && !replay_busy(app) {
			origin, dir := mouse_ray(app.camera, mouse, input.size)
			_, _, on := scene_raycast(app, origin, dir)
			// Ctrl on the model inverts the brush; only off it does Ctrl mask.
			g.mask_tap = input.mask || !on
			g.pending ||= g.mask_tap
		}
		if w := &app.dab_wait; w.active && !(g.defer_tap && w.second) do w.play = true
		clear(&g.held)
		if owner == .Orbit {
			orbit_latch(app)
			g.pivot, app.pivot.from = orbit_pivot(app, mouse, input.size)
			app.pivot.used = g.pivot
		}
		if owner == .Shape do shape_grab(app, shape_handle_at(app, mouse))
	}
	if g.owner == .None {
		input.orbit_drag, input.pan_drag, input.primary, input.press = false, false, false, false
		return
	}

	g.travel = max(g.travel, linalg.length(mouse - g.from))
	slop := app.kit.ctx.theme.slop * app.kit.scale
	delta := mouse - g.last
	g.last = mouse
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
			now := input_clock(app)
			waits_tap := g.defer_tap || g.mask_tap
			wait := ui.FINGER_TAP if waits_tap else time.duration_seconds(FINGER_HOLD)
			tap := lifted && waits_tap && g.travel <= slop && now - g.at < ui.FINGER_TAP
			w := &app.dab_wait
			if tap && g.mask_tap && !w.active {
				g.pending = false
				clear(&g.held)
				input.primary, input.press = false, false
				input.samples = {}
				mask_tap_act(app, g.from, input.size)
			} else if tap {
				// A tap: the second of a double tap acts and neither tap sculpts; a first
				// one's dab waits for a second (Dab_Wait).
				g.pending = false
				if w.active && w.second {
					w.active = false
					double_tap_act(app, g.from, input.size)
				} else {
					w^ = {active = true, samples = w.samples, mods = g.mods, camera = app.camera, brush = app.brush, size = input.size, at = now, pos = g.from + app.ui.viewport_origin}
					clear(&w.samples)
					append(&w.samples, ..g.held[:])
				}
				clear(&g.held)
				input.primary, input.press = false, false
				input.samples = {}
			} else if (lifted || g.travel > slop || now - g.at >= wait) && w.active {
				// A stroke after all, but a tap's dab still waits: it plays first, at the
				// start of the next frame, and this stroke begins after it.
				w.play = true
				input.primary, input.press = false, false
				input.samples = {}
			} else if lifted || g.travel > slop || now - g.at >= wait {
				// One finger after all: the stroke begins where the finger first landed,
				// following every sample it made meanwhile.
				g.pending = false
				samples := make([]Input_Sample, len(g.held), context.temp_allocator)
				copy(samples, g.held[:])
				clear(&g.held)
				input.samples = samples
				input.primary, input.press = true, true
				m := g.mods
				input.smooth, input.invert, input.mask, input.mask_shape, input.alt = m.smooth, m.invert, m.mask, m.mask_shape, m.alt
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
			if delta != {} do app.coach_seen += {.Turn}
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
	case .Shape:
		route_mute(input)
		shape_drag(app, delta)
	}

	// A press still pending here waits on a tap's dab and begins next frame, lifted or not.
	if buttons == {} && !g.pending {
		// A tap on empty space with the Move tool clears the selection, as its click did
		// before empty space turned the view; while Select several is on, or Shift held,
		// one that misses keeps the selection being built.
		several := app.kit.select_several || app.device.shift
		now := input_clock(app)
		// A finger's tap on empty space runs the one-finger tap gesture, when it holds one, in
		// place of the Move tool's deselecting; with double taps on, once one cannot follow.
		one := g.owner == .Orbit && g.empty && d.pointer == .Finger && g.travel <= slop && now - g.at < ui.FINGER_TAP && app.nav.gestures[.One_Tap].id != .None && !t.palm && !t.gesture && !t.pen_near && !t.pen_down
		if g.owner == .Orbit && g.empty && app.tool == .Move && g.travel <= slop && !several && !one do scene_deselect(app)
		if one && !(app.nav.double_tap && double_tap_follows(app.double_tap, g.at, g.from, DOUBLE_TAP_REACH * app.kit.scale)) {
			// A tap elsewhere than the one waiting: that one runs now, this one waits in turn.
			if app.one_tap > 0 do one_tap_run(app)
			if app.nav.double_tap do app.one_tap = max(now, 1e-9)
			else do one_tap_run(app, true)
		}
		if g.owner == .Shape do shape_release(app, false)
		if g.owner == .Orbit && d.pointer == .Finger && !g.edge && app.nav.double_tap {
			if g.travel > slop || now - g.at >= ui.FINGER_TAP {
				app.double_tap.valid = false
			} else if double_tap_follows(app.double_tap, g.at, g.from, DOUBLE_TAP_REACH * app.kit.scale) {
				app.scene.selected = app.double_tap.selected
				app.double_tap.valid = false
				// The first tap was half of this double tap, not a one-finger tap.
				app.one_tap = 0
				double_tap_act(app, g.from, input.size)
			} else {
				app.double_tap = {valid = true, at = now, pos = g.from, selected = g.selected, framed = app.double_tap.framed}
			}
		}
		g.owner = .None
	}
}

// A one-finger tap on empty space waiting to see whether a second makes it a double tap
// (App.one_tap): it runs its gesture once DOUBLE_TAP_GAP passes, and is dropped when the
// pen comes near or lands, a palm rests on the screen or more fingers come down, the
// usual ways a hand touches by accident.
@(private = "file")
one_tap_wait :: proc(app: ^App) {
	if app.one_tap == 0 do return
	t := &app.touch
	if t.pen_near || t.pen_down || (t.fingers.count > 0 && (t.palm || t.gesture)) {
		app.one_tap = 0
		return
	}
	if input_clock(app) - app.one_tap > DOUBLE_TAP_GAP do one_tap_run(app)
}

// Runs the one-finger tap gesture: the one waiting, or with `now`, a tap that need not wait.
@(private = "file")
one_tap_run :: proc(app: ^App, now := false) {
	if app.one_tap == 0 && !now do return
	app.one_tap = 0
	if gesture_run(app, .One_Tap) do app.one_taps += 1
}

// Who a press on the viewport belongs to (see Drag).
@(private = "file")
drag_decide :: proc(app: ^App, input: Viewport_Input) -> (owner: Drag_Owner, empty: bool) {
	d := &app.device
	mouse := input.mouse_pos
	if by_button, decided := mouse_button_owner(app.nav.mouse_scheme, d.down + d.pressed, d.ctrl, d.shift, d.alt); decided do return by_button, false
	if d.pointer == .Finger && app.touch.palm do return .Muted, false
	// A handle of the shape waiting for Apply, before the model or the safe zone under it.
	if shape_handle_at(app, mouse) >= 0 do return .Shape, false
	// A handle of the Move tool's gizmo, before the model, the safe zone or empty space
	// under it, so every pointer grabs a handle off the model's silhouette.
	if app.tool == .Move && gizmo_pick(app, mouse, input.size) != .None do return .Tool, false
	// So does a point of the lattice's cage, which stands in for the gizmo.
	if app.tool == .Move && lattice_pick(app, mouse, input.size) > 0 do return .Tool, false
	// And a light's marker, while the Lights section shows them, for any tool.
	if light_marker_pressed(app, mouse, input.size) do return .Tool, false
	if d.pointer == .Finger && app.nav.finger_model == .Orbit do return .Orbit, false
	// The rail's Mask or Hide, for the brushes, keeps empty space for their shapes as Ctrl
	// does; only held there by a finger does it take the safe zone too, so a view filled
	// by the model still turns from its edge while one is latched (modifiers.odin).
	press := app.rail.press
	shapes := app.tool == .Brush && rail_keeps_empty_space(press.mods)
	// The safe zone turns the view whatever is under it, for every tool; Ctrl keeps it for
	// the mask and hide shapes, as on empty space.
	if !d.ctrl && !(shapes && press.held) && in_edge(app, mouse) do return .Orbit, false
	// Empty space turns the view for the brushes, the Move tool and the Model tool; Ctrl
	// keeps it for the mask and hide shapes, which start there, and the Knife keeps it for
	// its stroke, which starts beside the cage to cut clean across it.
	knife := app.tool == .Model && app.model.action == .Knife
	if (app.tool == .Brush || app.tool == .Move || app.tool == .Model) && !d.ctrl && !shapes && !knife {
		empty := app.nav.empty_drag[d.pointer] if d.pointer != .Finger else .Orbit
		if empty == .Orbit {
			origin, dir := mouse_ray(app.camera, mouse, input.size)
			if _, _, hit := scene_raycast(app, origin, dir); !hit do return .Orbit, true
		}
	}
	return .Tool, false
}

// A finger's double tap at `at` (Nomad's): on the model it pins the pivot there, which
// nothing moves to show but the dot's pulse; on empty space it frames the selected object,
// or every object when none is selected.
double_tap_act :: proc(app: ^App, at, size: [2]f32) {
	origin, dir := mouse_ray(app.camera, at, size)
	if index, hit, ok := scene_raycast(app, origin, dir); ok {
		obj := app.scene.objects[index]
		p := &app.pivot
		p.object, p.at, p.set, p.pinned, p.flash = obj.id, to_local(obj.transform, hit), true, true, input_clock(app)
		p.used, p.from = hit, .Tapped
		return
	}
	if selected_object(app) != nil do focus_selected(app)
	else do frame_all(app)
	app.double_tap.framed += 1
}

// A tap with Mask on, by where it landed (ZBrush's Ctrl click, Nomad's taps while Mask is
// held): off the model it inverts the selected object's mask; on an object it selects it,
// as a stroke there would, and blurs its mask where it is masked and sharpens it where it
// is not. Each says so in a toast, with Undo when it changed something.
mask_tap_act :: proc(app: ^App, at, size: [2]f32) {
	origin, dir := mouse_ray(app.camera, at, size)
	index, _, on := scene_raycast(app, origin, dir)
	if !on {
		mask_command(app, .Invert, toast = true)
		return
	}
	app.scene.selected = index
	obj := app.scene.objects[index]
	t := obj.transform
	if m, ok := sculpt.sculptor_mask_at(object_sculptor(obj), to_local(t, origin), to_local_dir(t, dir)); ok {
		mask_command(app, .Blur if m >= 0.5 else .Sharpen, toast = true)
	}
}

// Notes what in event `e` comes before a waiting tap's dab is played (Dab_Wait). Runs for
// each event before touch_event.
dab_wait_event :: proc(app: ^App, e: ^sdl.Event, window: ^sdl.Window) {
	w := &app.dab_wait
	if !w.active do return
	#partial switch e.type {
	case .KEY_DOWN, .MOUSE_WHEEL, .PEN_DOWN, .WINDOW_FOCUS_LOST, .DID_ENTER_BACKGROUND, .QUIT:
		w.play = true
	case .MOUSE_BUTTON_DOWN:
		// The pen's and the fingers' stand-ins are not the mouse.
		if e.button.which != sdl.PEN_MOUSEID && e.button.which != sdl.TOUCH_MOUSEID do w.play = true
	case .FINGER_DOWN:
		f := e.tfinger
		// Only fingers on a screen, as touch_event takes them.
		if f.touchID == sdl.PEN_TOUCHID || f.touchID == sdl.MOUSE_TOUCHID do return
		if f.touchID != TOUCH_SCRIPTED && sdl.GetTouchDeviceType(f.touchID) != .DIRECT do return
		ww, wh: i32
		_ = sdl.GetWindowSize(window, &ww, &wh)
		at := [2]f32{f.x * f32(ww), f.y * f32(wh)}
		if _, rail := rail_claims(app, at); rail || rail_claims_plain(app, at) do return
		near := linalg.length(at - w.pos) <= DOUBLE_TAP_REACH * app.kit.scale
		if app.touch.fingers.count == 0 && !w.second && near && input_clock(app) - w.at <= DOUBLE_TAP_GAP {
			w.second = true
		} else {
			w.play = true
		}
	}
}

// Plays a waiting tap's dab when its gap ran out or something else came first, as the
// stroke it would have been, with the view and brush it was tapped with. Runs after the
// frame's events, before the interface and the tools.
dab_wait_resolve :: proc(app: ^App) -> (res: Sculpt_Frame_Result) {
	w := &app.dab_wait
	if !w.active do return
	expired := !w.second && input_clock(app) - w.at > DOUBLE_TAP_GAP
	if w.second {
		// The finger that may be the second tap had a frame to become a brush press that
		// waits as a tap; one the interface took, or a palm's, never will.
		g := app.drag
		if w.checked && !(g.owner == .Tool && g.pending && g.defer_tap) do expired = true
		w.checked = true
	}
	if !w.play && !expired do return
	w.active, w.play, w.second, w.checked = false, false, false, false
	// It plays whatever the tool is now: it was tapped with the brush.
	if len(w.samples) == 0 do return
	// Only a finger's tap waits, so it lands at Touch strength whatever points now.
	saved_camera, saved_brush, saved_scale := app.camera, app.brush, app.stroke_scale_from
	defer app.camera, app.brush, app.stroke_scale_from = saved_camera, saved_brush, saved_scale
	app.camera, app.brush, app.stroke_scale_from = w.camera, w.brush, app.nav.touch_strength
	samples := make([]Input_Sample, len(w.samples), context.temp_allocator)
	copy(samples, w.samples[:])
	m := w.mods
	input := Viewport_Input {
		size = w.size, mouse_pos = samples[len(samples) - 1].pos, hovered = true, primary = true, press = true, samples = samples,
		smooth = m.smooth, invert = m.invert, mask = m.mask, mask_shape = m.mask_shape, alt = m.alt,
	}
	stroke_finish(app)
	replay_frame_begin(app)
	res = sculpt_frame(app, input)
	replay_record(app, input, res)
	// Its samples end with the release, which ended the stroke.
	stroke_finish(app)
	return
}

// What an orbit pressed at `at` turns about, in world space: a pivot a double tap pinned,
// or as Settings > Camera says, the surface under the press, the middle of the last
// stroke, the selected object's middle, or else the target. A point behind the eye is
// passed over, since turning about it would swing what is in front of the eye out of view.
orbit_pivot :: proc(app: ^App, at, size: [2]f32) -> (pivot: Vec3, from: Pivot_Source) {
	c := app.camera
	if p := &app.pivot; p.pinned {
		obj := object_by_id(app, p.object)
		if obj == nil {
			p.pinned, p.set = false, false
		} else if w := to_world(obj.transform, p.at); in_front(c, w) {
			return w, .Tapped
		}
	}
	switch app.nav.pivot {
	case .Centre:
		return c.target, .Centre
	case .Pointer:
		origin, dir := mouse_ray(c, at, size)
		if _, hit, ok := scene_raycast(app, origin, dir); ok && in_front(c, hit) do return hit, .Pointer
		if app.nav.air_pivot {
			// As deep along the view as its middle, so the turn feels as it does about the
			// middle but swings about the place pressed.
			_, _, back := camera.orbit_basis(c)
			depth := linalg.dot(c.target - origin, -back)
			if along := linalg.dot(dir, -back); depth > c.near && along > 1e-4 do return origin + dir * (depth / along), .Air
		}
	case .Selection:
		if lo, hi, ok := objects_bounds(app, true); ok do return (lo + hi) / 2, .Selection
		return c.target, .Centre
	case .Scene:
		if lo, hi, ok := objects_bounds(app, false); ok do return (lo + hi) / 2, .Scene
		return c.target, .Centre
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

// Where the safe zone ends, in the main pane's coordinates: the safe area within the pane
// less `edge_size` points on every side, the top one counted from under the top bar.
// Inside it the tools and empty space decide; outside, the edges
// turn the view.
edge_inner :: proc(app: ^App) -> (lo, hi: [2]f32) {
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	// The top band starts under the top bar where the pane reaches the window's top edge,
	// which the bar covers; a pane lower down (a view pane worked in) starts at its own top.
	under_bar := true
	if pane := k.grid.main; pane.w > 0 && pane.h > 0 {
		under_bar = pane.y <= area.y
		x0, y0 := max(area.x, pane.x), max(area.y, pane.y)
		area = {x0, y0, min(area.x + area.w, pane.x + pane.w) - x0, min(area.y + area.h, pane.y + pane.h) - y0}
	}
	band := app.nav.edge_size
	top := area.y + band + (TOP_BAR_H if under_bar else 0)
	o := app.ui.viewport_origin
	return [2]f32{area.x + band, top} * k.scale - o, [2]f32{area.x + area.w - band, area.y + area.h - band} * k.scale - o
}

// Whether `p` (the main pane's coordinates) is in the safe zone, when it is on.
in_edge :: proc(app: ^App, p: [2]f32) -> bool {
	if !app.nav.edge_orbit do return false
	lo, hi := edge_inner(app)
	return p.x < lo.x || p.y < lo.y || p.x > hi.x || p.y > hi.y
}

// The middle of the object's bounds in world space: its sculptor's BVH root box, which
// follows every stroke, or its origin before it has one.
// The world box round the selected objects' (or every shown object's) surfaces, from
// their nodes' bounds: false when there are none.
objects_bounds :: proc(app: ^App, selected: bool) -> (lo, hi: Vec3, ok: bool) {
	lo, hi = Vec3(max(f32)), Vec3(min(f32))
	for obj in app.scene.objects {
		take := object_in_selection(app, obj) if selected else object_shown(app, obj)
		if !take do continue
		s := object_sculptor(obj)
		if len(s.bvh.nodes) == 0 do continue
		b := s.bvh.nodes[0].bounds
		for corner in 0 ..< 8 {
			p := Vec3{b.hi.x if corner & 1 != 0 else b.lo.x, b.hi.y if corner & 2 != 0 else b.lo.y, b.hi.z if corner & 4 != 0 else b.lo.z}
			w := to_world(obj.transform, p)
			lo, hi = linalg.min(lo, w), linalg.max(hi, w)
		}
	}
	return lo, hi, lo.x <= hi.x
}

object_middle :: proc(obj: ^Object) -> Vec3 {
	s := object_sculptor(obj)
	if len(s.bvh.nodes) == 0 do return obj.transform.position
	b := s.bvh.nodes[0].bounds
	return to_world(obj.transform, (b.lo + b.hi) * 0.5)
}

@(private = "file")
route_mute :: proc(input: ^Viewport_Input) {
	input.primary, input.press, input.smooth, input.invert, input.alt = false, false, false, false, false
	input.mask, input.mask_shape = false, false
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
	// What is done here counts toward the first-run tips (kit_coach.odin).
	if in_.touch_orbit != {} || ((in_.hovered || in_.dragging) && !in_.primary && in_.orbit_drag && in_.mouse_delta != {}) do app.coach_seen += {.Turn}
	if ((in_.hovered || in_.dragging) && !in_.primary && (in_.pan_drag || in_.zoom_drag) && in_.mouse_delta != {}) || (in_.hovered && in_.wheel != 0) do app.coach_seen += {.Move}
	// Two fingers count once they moved or pinched past the slop: a two-finger tap (undo)
	// moves them a little too.
	if in_.touch_pan != {} || in_.touch_zoom > 0 {
		zoom := in_.touch_zoom if in_.touch_zoom > 0 else 1
		// A pinch's change in points, for fingers about 150 points apart.
		app.coach_touch += linalg.length(in_.touch_pan) + abs(math.ln(zoom)) * 150
		if app.coach_touch > app.kit.ctx.theme.slop do app.coach_seen += {.Move}
	}
	// Two or more fingers on the viewport (touch_route) navigate with no pointer down.
	if in_.touch_pan != {} do camera.orbit_pan(c, in_.touch_pan, in_.size.y)
	if in_.touch_zoom > 0 do camera.orbit_zoom_toward(c, in_.touch_zoom, in_.touch_at, in_.size.y)
	if in_.touch_roll != 0 do camera.orbit_roll_about(c, in_.touch_roll, in_.touch_at, in_.size.y)
	if in_.touch_orbit != {} {
		before := c^
		camera.orbit_rotate(c, in_.touch_orbit, orbit_settings(app))
		camera.orbit_turn_about(c, before, in_.touch_pivot)
	}
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
		steps := (-in_.wheel if nav.invert_wheel else in_.wheel) * nav.zoom_speed
		if nav.wheel_toward {
			// orbit_zoom's step, as a factor closer.
			camera.orbit_zoom_toward(c, math.pow(f32(0.88), -steps), in_.mouse_pos - in_.size * 0.5, in_.size.y)
		} else {
			camera.orbit_zoom(c, steps)
		}
	}
}
