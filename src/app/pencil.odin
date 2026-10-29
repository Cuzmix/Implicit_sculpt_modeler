package main

@(require) import "core:c"
import "core:log"
import "core:math"
import "core:reflect"
import "core:strings"
import sdl "vendor:sdl3"

import "../sculpt"
import "../ui"

// The pencil's own gestures and the pen's other ends: an Apple Pencil's double-tap and
// squeeze, which SDL does not report and the iPad's bridge (ios/sculpt_ios.m) sends as
// SDL user events of `Pencil.event_type`; a pen's second barrel button and its eraser end,
// which SDL reports on Windows, Linux and Android. Double-tap, squeeze and the second
// button are gesture-map slots (gesture_map.odin), as ZBrush for iPad lists its Pencil
// double-tap and squeeze beside the finger taps; the eraser end sculpts with a modifier
// (Settings > Pen), as flipping a pen over erases in a drawing app.

// What reaches the app from the pencil, as the user event's code.
Pencil_Gesture :: enum i32 {
	Double_Tap,
	Squeeze_Began,
	Squeeze_Ended,
	Squeeze_Cancelled,
}

// What the iPad's Settings > Apple Pencil asks a double-tap or squeeze to do (UIKit's
// UIPencilPreferredAction, which the bridge names one by one, so their order there never
// matters here). The app follows it while the slot holds Follow the Pencil setting.
Pencil_Action :: enum u8 {
	Ignore,
	Switch_Eraser,
	Switch_Previous,
	Color_Palette,
	Ink_Attributes,
	Contextual_Palette,
	Run_Shortcut,
}

// The iPad's own defaults, which a desktop, where no iPad setting arrives, follows too:
// double-tap swaps to the eraser, squeeze shows the palette at the tip.
PENCIL_PREFERRED_DEFAULT :: [2]Pencil_Action{.Switch_Eraser, .Contextual_Palette}

// What the eraser end sculpts with (Settings > Pen): as the tip does, or as the tip with a
// modifier wheel sector held.
Eraser_Use :: enum u8 {
	Tip,
	Smooth,
	Invert,
	Mask,
}

// The second barrel button's number in SDL's pen button events (the first is SDL's right
// click, the brush pie's side button).
PEN_BUTTON_SECOND :: 2

Pencil :: struct {
	// The SDL user event type the pencil's gestures come as, 0 until registered; the type
	// after it brings an Android pen's lean (android_main.c).
	event_type: u32,
	// The iPad's preferred double-tap and squeeze actions, as the latest gesture said.
	preferred:  [2]Pencil_Action,
	// The gesture slot that runs once the frame's events are in, nil for none: events are
	// read before the frame's interface exists, so a gesture's command waits for it.
	pending:    Maybe(Gesture_Slot),
	// Which preference Follow the Pencil setting reads: 0 double-tap, 1 squeeze.
	running:    int,
	// A squeeze that began while a stroke or a drag was under way does nothing when it
	// ends: pressing the barrel mid-stroke is the hand's grip, not a gesture.
	spoiled:    bool,
	eraser:     bool, // the pen's last touch was with its eraser end
	// The brush held before the one held now, for Switch to the last used.
	brush_now:    sculpt.Brush_Kind,
	brush_before: sculpt.Brush_Kind,
	// What SDL reported for the pencil's lean on an iPad, before pencil_tilt_uikit turns it
	// into the lean the other platforms report.
	tilt_raw:   [2]f32,
	// The iPad's Only Draw with Apple Pencil (Settings > Apple Pencil): a finger then never
	// sculpts, whatever Settings > Touch says, as Apple asks of drawing apps.
	only:       bool,
	haptics:    int, // haptics asked of the pencil, for the exit stats
	// Where the platform never says that the pen left (PEN_LEAVE_SAID, or --pen-no-leave),
	// pencil_leave says it: whether the pen is about and its tip down, and when, which pen
	// and over which window it last reported.
	no_leave:     bool,
	about:        bool,
	down:         bool,
	heard:        f64,
	heard_pen:    sdl.PenID,
	heard_window: sdl.WindowID,
	// The system rejects resting palms itself (SYSTEM_PALMS, or --system-palms), so only the
	// pen's tip makes a lone finger a palm (pen_holds_hand).
	system_palms: bool,
}

// SDL 3.4's UIKit driver never says that the pencil went: nothing there sends
// PEN_PROXIMITY_OUT, and the end of its hover is dropped (SDL_uikitview.m). Unsaid, the
// pencil stays near for the rest of the run, every finger after it is a palm (touch.odin),
// and its last roll is the start of its next turn, so that coming back turned jumps the
// value under it. SDL reports a hovering pencil whenever its place, height or angles
// change, which a hand holding it never stops doing for long, so there, with its tip up,
// PEN_GONE seconds without a report count as it having left.
PEN_LEAVE_SAID :: !ODIN_PLATFORM_SUBTARGET_IOS

// Half a second: many times the gap between a hovering pencil's reports (120 a second), and
// still shorter than reaching for the screen with a finger after putting the pencil down.
// A pencil held quite still over the screen that long counts as gone until it moves.
PEN_GONE :: 0.5

// Notes a pen event for pencil_leave: any report means the pen is about.
pencil_heard :: proc(app: ^App, e: ^sdl.Event) {
	p := &app.pencil
	#partial switch e.type {
	case .PEN_PROXIMITY_IN:
		p.heard_pen, p.heard_window = e.pproximity.which, e.pproximity.windowID
	case .PEN_PROXIMITY_OUT:
		p.about, p.down = false, false
		return
	case .PEN_MOTION:
		p.heard_pen, p.heard_window = e.pmotion.which, e.pmotion.windowID
	case .PEN_AXIS:
		p.heard_pen, p.heard_window = e.paxis.which, e.paxis.windowID
	case .PEN_DOWN, .PEN_UP:
		p.heard_pen, p.heard_window = e.ptouch.which, e.ptouch.windowID
		p.down = e.type == .PEN_DOWN
	case:
		return
	}
	p.about = true
	p.heard = input_clock(app)
}

// Whether the pen, unheard since `heard`, has left by `now` where the platform never says so.
pencil_gone :: proc(p: Pencil, now: f64) -> bool {
	return p.no_leave && p.about && !p.down && now - p.heard >= PEN_GONE
}

// Once the frame's events are in, says that the pen left where the platform never does:
// as SDL's own PEN_PROXIMITY_OUT, through its queue, so that everything reading the pen
// (touch.odin's palms, the roll, the hover height) takes it as on every other platform.
pencil_leave :: proc(app: ^App) {
	p := &app.pencil
	if !pencil_gone(p^, input_clock(app)) do return
	p.about = false
	e: sdl.Event
	e.pproximity = {type = .PEN_PROXIMITY_OUT, timestamp = sdl.GetTicksNS(), windowID = p.heard_window, which = p.heard_pen}
	if !sdl.PushEvent(&e) do log.warnf("pencil_leave: PushEvent failed: %s", sdl.GetError())
}

// The pen's turn about its own length as SDL reports it on this platform, in degrees
// clockwise seen from its top, as SDL's ROTATION axis is defined and Windows Ink reports
// it. SDL 3.4's UIKit driver passes UIKit's rollAngle on unchanged (SDL_uikitpen.m, whose
// note says its sign was never checked against a pencil), and that grows the other way:
// the Pencil Pro turned to the right reports a falling angle.
pencil_roll_degrees :: proc(value: f32) -> f32 {
	when ODIN_PLATFORM_SUBTARGET_IOS do return pencil_roll_uikit(value)
	else do return value
}

// An iPad's roll as SDL reports it (UIKit's rollAngle in degrees), turned to SDL's
// clockwise: the same angle the other way round.
pencil_roll_uikit :: proc(value: f32) -> f32 {
	return -value
}

// Adds the pen's turn about its own length since its last report, `degrees` from -180 to
// 180, to this frame's roll, the short way round, so turning past the half turn where the
// numbers wrap reads as the small turn it is. A report further than ROLL_JUMP from the last
// is no turn a hand made between two reports but a new start (the pen came back turned,
// or its roll now comes from another source), and turns nothing.
pen_roll_take :: proc(app: ^App, degrees: f32) {
	if last, ok := app.pen_roll_last.?; ok {
		d := degrees - last
		d -= 360 * math.floor((d + 180) / 360)
		if abs(d) <= ROLL_JUMP do app.pen_roll += d
	}
	app.pen_roll_last = degrees
}

// The most a pen turns about its own length between two reports: a quick flick of the
// fingers is about four turns a second, some 12 degrees a report at the 120 a second an
// iPad's Pencil reports hovering, and scripted reports step by up to 30.
ROLL_JUMP :: f32(45)

// What a haptic says, as UIKit's canvas feedback has them: something snapped into place, or
// a drawn shape was finished.
Haptic :: enum c.int {
	Alignment,
	Path_Completed,
}

// Registers the pencil's user event type and, on the iPad, starts the bridge that sends
// it on `window`. A failure leaves the type 0, and double-tap and squeeze then never arrive.
pencil_init :: proc(app: ^App, window: ^sdl.Window = nil) {
	p := &app.pencil
	p.preferred = PENCIL_PREFERRED_DEFAULT
	p.brush_now, p.brush_before = app.brush.kind, app.brush.kind
	t := sdl.RegisterEvents(2)
	if t != 0 do p.event_type = t
	when ODIN_PLATFORM_SUBTARGET_IOS {
		if window != nil do sculpt_ios_pencil_start(window, p.event_type)
		if window != nil do sculpt_ios_scribble_start(window)
	}
	when ODIN_PLATFORM_SUBTARGET == .Android {
		if t != 0 do sculpt_android_pen_lean_start(t + 1)
	}
	pencil_only_read(app)
}

// Reads the iPad's Only Draw with Apple Pencil, at the start and each time the app comes
// back to the front, since it is changed in the iPad's Settings, away from the app.
pencil_only_read :: proc(app: ^App) {
	when ODIN_PLATFORM_SUBTARGET_IOS do app.pencil.only = sculpt_ios_pencil_only()
}

// What one finger on the model does now: the iPad's Only Draw with Apple Pencil turns the
// view with it, whatever Settings > Touch says.
finger_model_now :: proc(app: ^App) -> Finger_Model {
	return .Orbit if app.pencil.only else app.nav.finger_model
}

// Says, where the finger's choice is set, that the iPad's own setting overrides it.
pencil_only_note :: proc(app: ^App) {
	ctx := &app.kit.ctx
	if app.pencil.only do ui.paragraph(ctx, "Only Draw with Apple Pencil is on in the iPad's Settings > Apple Pencil, so a finger turns the view and only the pencil sculpts.", color = ctx.theme.warning)
}

// Asks the Apple Pencil Pro for a haptic where the pen is. Only for the pen: a finger or a
// mouse feels nothing, and UIKit plays it only for a Pencil Pro near the screen.
haptic :: proc(app: ^App, kind: Haptic) {
	if app.device.pointer != .Pen do return
	app.pencil.haptics += 1
	when ODIN_PLATFORM_SUBTARGET_IOS do sculpt_ios_haptic(c.int(kind), app.device.mouse.x, app.device.mouse.y)
}

// Folds one SDL event in, and says whether it was the pencil's alone (a gesture, or the
// mouse button SDL makes of a second barrel button that the gesture map takes), which
// nothing else may then see.
pencil_event :: proc(app: ^App, e: ^sdl.Event) -> bool {
	p := &app.pencil
	if p.event_type != 0 && u32(e.type) == p.event_type {
		pencil_gesture(app, Pencil_Gesture(e.user.code), pencil_action_from(int(uintptr(e.user.data1))))
		return true
	}
	if p.event_type != 0 && u32(e.type) == p.event_type + 1 {
		tilt := transmute(f32)u32(uintptr(e.user.data1))
		orientation := transmute(f32)u32(uintptr(e.user.data2))
		if !math.is_nan(tilt) && !math.is_nan(orientation) {
			app.pen_tilt = pencil_tilt_android(tilt, orientation)
			app.pen_seen = true
		}
		return true
	}
	// The second button's slot where the pen points; mapped to nothing there, it stays the
	// middle button.
	here := pencil_slot_here(app, .Pen_Button_2)
	second := app.nav.gestures[here].id != .None && app.nav.gestures[here].id != .Pen_As_Empty
	#partial switch e.type {
	case .PEN_DOWN:
		p.eraser = e.ptouch.eraser
	case .PEN_BUTTON_DOWN:
		if second && e.pbutton.button == PEN_BUTTON_SECOND do p.pending = here
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		// SDL presses the middle button for the second barrel button; mapped, it is the
		// gesture's and never the middle button's drag.
		return second && e.button.which == sdl.PEN_MOUSEID && e.button.button == sdl.BUTTON_MIDDLE
	}
	return false
}

// A double-tap or squeeze arrived, with what the iPad's Settings ask of it. The system's
// Ignore turns the gesture off here too, whatever the slot holds, as Apple asks.
pencil_gesture :: proc(app: ^App, g: Pencil_Gesture, preferred: Pencil_Action) {
	p := &app.pencil
	switch g {
	case .Double_Tap:
		p.preferred[0] = preferred
		if preferred != .Ignore do p.pending = .Pen_Double_Tap
	case .Squeeze_Began:
		p.spoiled = app.stroke.active || .Left in app.device.down
	case .Squeeze_Ended:
		p.preferred[1] = preferred
		if !p.spoiled && preferred != .Ignore do p.pending = .Pen_Squeeze
		p.spoiled = false
	case .Squeeze_Cancelled:
		p.spoiled = false
	}
}

// Runs the gesture the events left waiting, and notes the brush held, once the frame's
// events are in.
pencil_frame :: proc(app: ^App) {
	p := &app.pencil
	if app.brush.kind != p.brush_now do p.brush_before, p.brush_now = p.brush_now, app.brush.kind
	slot, ok := p.pending.?
	p.pending = nil
	if !ok do return
	p.running = 1 if slot == .Pen_Squeeze else 0
	// Double-tap and squeeze each mean their own thing where the pen points (pen_roll.odin);
	// the second button's slot was chosen as it went down.
	_ = gesture_run(app, pencil_slot_here(app, slot))
}

// Follow the Pencil setting: what the iPad's preferred action for the gesture running
// means in sculpting. The eraser is Smooth, the sculptor's way of taking a stroke back;
// the palette at the tip is the brush pie, where the pointer is when the pencil hovers.
pencil_preferred_run :: proc(app: ^App) {
	p := &app.pencil
	switch p.preferred[clamp(p.running, 0, 1)] {
	case .Ignore, .Run_Shortcut:
	case .Switch_Eraser:      rail_toggle(&app.rail, .Smooth)
	case .Switch_Previous:    _ = command_run(app, .Brush, int(p.brush_before))
	case .Color_Palette:      _ = command_run(app, .Colors_Card)
	case .Ink_Attributes:     _ = command_run(app, .Show_Section, int(Kit_Section.Stroke))
	case .Contextual_Palette: _ = command_run(app, .Brush_Pie)
	}
}

// A preferred action by the number the bridge sends; one this version does not know is
// ignored, as a gesture with no meaning here should be.
pencil_action_from :: proc(n: int) -> Pencil_Action {
	if n < 0 || n >= len(Pencil_Action) do return .Ignore
	return Pencil_Action(n)
}

// A preferred action by its name in lower case (`switch_previous`), for scripted events.
pencil_action_named :: proc(name: string) -> (Pencil_Action, bool) {
	for a in Pencil_Action {
		if strings.equal_fold(reflect.enum_string(a), name) do return a, true
	}
	return .Ignore, false
}

// The modifiers the eraser end presses with, none when it sculpts as the tip.
eraser_mods :: proc(use: Eraser_Use) -> Modifiers {
	switch use {
	case .Tip:    return {}
	case .Smooth: return {.Smooth}
	case .Invert: return {.Invert}
	case .Mask:   return {.Mask}
	}
	return {}
}

// The lean an iPad pencil reports, from the X and Y tilts SDL makes of UIKit's azimuth and
// altitude, as every other platform reports it: degrees toward the right (x) and toward the
// bottom of the screen (y) of the pen's top. SDL 3.4 gives X as 90 less the azimuth's size,
// whatever the altitude, so a pencil held upright would lean 90 degrees; its two numbers
// still hold the azimuth (its size from X, its side from Y's sign) and the altitude (90
// less Y's size), from which the lean follows.
pencil_tilt_uikit :: proc(sdl_tilt: [2]f32) -> [2]f32 {
	azimuth := math.to_radians(90 - sdl_tilt.x)
	if sdl_tilt.y < 0 do azimuth = -azimuth
	return pencil_lean_uikit(azimuth, math.to_radians(90 - abs(sdl_tilt.y)))
}

// The lean of an Apple Pencil from UIKit's azimuth in the view (radians clockwise from the
// screen's right, as y grows down) and altitude (radians up from the screen).
pencil_lean_uikit :: proc(azimuth, altitude: f32) -> [2]f32 {
	// The pen's top, from the tip: across the screen cos(altitude) along the azimuth, and
	// sin(altitude) out of it.
	across := math.cos(altitude)
	up := max(math.sin(altitude), 1e-6)
	return {math.to_degrees(math.atan(across * math.cos(azimuth) / up)), math.to_degrees(math.atan(across * math.sin(azimuth) / up))}
}

// The lean an Android pen reports, from its AXIS_TILT (radians off upright) and
// AXIS_ORIENTATION (radians clockwise from the screen's up to the way its top points), as
// every other platform reports it: degrees toward the right (x) and toward the bottom of
// the screen (y) of the pen's top.
pencil_tilt_android :: proc(tilt, orientation: f32) -> [2]f32 {
	across := math.tan(clamp(tilt, 0, math.to_radians(f32(89))))
	return {math.to_degrees(math.atan(across * math.sin(orientation))), math.to_degrees(math.atan(-across * math.cos(orientation)))}
}

// Takes one of the pen's lean axes as SDL reports it on this platform.
pencil_tilt_take :: proc(app: ^App, axis: sdl.PenAxis, value: f32) {
	i := 0 if axis == .XTILT else 1
	when ODIN_PLATFORM_SUBTARGET_IOS {
		app.pencil.tilt_raw[i] = value
		app.pen_tilt = pencil_tilt_uikit(app.pencil.tilt_raw)
	} else {
		app.pen_tilt[i] = value
	}
}

// Settings > Pen's PENCIL AND BUTTONS: what the eraser end sculpts with. The buttons,
// double-tap and squeeze are chosen where the pen points (settings_pen_areas).
settings_pen_buttons :: proc(app: ^App) {
	ctx := &app.kit.ctx
	n := &app.nav
	ui.label(ctx, "Eraser end")
	uses := [len(Eraser_Use)]string{"As the tip", "Smooth", "Invert", "Mask"}
	if picked := ui.tabs(ctx, "Eraser end", uses[:], int(n.eraser)); picked >= 0 do n.eraser = Eraser_Use(picked)
	ui.paragraph(ctx, "Turn the pen over and its eraser end sculpts with this, as holding the modifier wheel's sector does. The side and second buttons, the Apple Pencil's double-tap and squeeze, and the roll are under Where the pen points.")
}

// Pushes a scripted double-tap or squeeze, as the iPad's bridge sends one.
pencil_push :: proc(app: ^App, g: Pencil_Gesture, preferred: Pencil_Action) {
	if app.pencil.event_type == 0 do return
	e: sdl.Event
	e.user = {type = sdl.EventType(app.pencil.event_type), timestamp = sdl.GetTicksNS(), code = i32(g), data1 = rawptr(uintptr(preferred))}
	_ = sdl.PushEvent(&e)
}
