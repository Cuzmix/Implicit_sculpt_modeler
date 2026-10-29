package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../ui"
import "../zip"

// Input diagnostics: a developer's screen (kit_diag.odin) of guided tests that records what
// the app's own input pipeline received and what its controls did, for the iPad's finger,
// Pencil, keyboard and system gestures, and exports it as a report (README "Input
// diagnostics"). It only watches: diag_event reads each SDL event before the app's handlers
// see it, diag_frame reads the touch, device and interface state once the frame's interface
// is done, and the probes are the kit's own widgets. Nothing here changes how input is routed.
// While the screen shows, it covers the window as Home does, so no press reaches the scene,
// and gestures run no command (gesture_run).

// Whether the screen can be reached: in debug builds, and in a build made with
// -define:SCULPT_DIAGNOSTICS=true (the AltStore iPad build sets it through build.sh's
// SCULPT_DIAGNOSTICS); a store build leaves it out (sm-store: no debug panels reachable). The
// code compiles in every build; only the way in is closed, through Diag.allowed.
DIAGNOSTICS :: #config(SCULPT_DIAGNOSTICS, ODIN_DEBUG)
// What a report calls this build: the commit, which the iPad build passes; "dev" elsewhere.
SCULPT_VERSION :: #config(SCULPT_VERSION, "dev")

// The log's format, which scripts/input_report.py reads; a change to what a line holds bumps it.
DIAG_SCHEMA :: 1
// Bytes the log may hold. A long session stays a few megabytes, small enough to share and to
// keep in memory; past DIAG_SAMPLE_CAP moves and axes stop being sampled, and past the cap
// only the lines that say what the tests found (steps, results, anomalies) still go in, up to
// DIAG_LOG_RESERVE more.
DIAG_LOG_CAP :: 4 << 20
DIAG_SAMPLE_CAP :: 3 << 20
DIAG_LOG_RESERVE :: 256 << 10
// A moving pointer is logged at most every DIAG_MOVE_GAP seconds or DIAG_MOVE_TRAVEL points,
// with the moves between folded into the count `n`: enough to see a path, never a line a frame.
DIAG_MOVE_GAP :: 0.05
DIAG_MOVE_TRAVEL :: 24
// A pen axis is logged when it moved this much since its last line, or after DIAG_MOVE_GAP.
DIAG_AXIS_STEP :: [sdl.PenAxis]f32{.PRESSURE = 0.05, .XTILT = 2, .YTILT = 2, .DISTANCE = 0.05, .ROTATION = 2, .SLIDER = 0.05, .TANGENTIAL_PRESSURE = 0.05}
// Runs a session keeps; a person runs each test a few times at most.
DIAG_RUNS :: 256
// Anomalies the summary lists one by one (each run counts all of its own).
DIAG_ANOMALY_LIST :: 200
// Seconds something stays pressed with nothing touching before it is stuck, the pen stays
// "near" after its last report before it is stuck there, and a frame takes while a touch is
// down before it is a gap a gesture would feel.
DIAG_STUCK :: 0.3
DIAG_PEN_STUCK :: 2.0
DIAG_FRAME_GAP :: 0.25
// Seconds the field may hold the keys with text input off, and the keyboard show with no
// field, before they disagree.
DIAG_DESYNC :: 0.5
// Points from the bottom edge where a finger starts the system's Home swipe.
DIAG_EDGE :: 40
// Bytes of the diagnostic field's text a text line carries. Only that field's: what is typed
// anywhere else is never logged.
DIAG_TEXT_LOGGED :: 32
// Points the pad's trail keeps, to draw where the pointer went.
DIAG_TRAIL :: 96

// What arrives, counted by kind: the raw events, whatever the app then made of them.
Diag_Count :: enum u8 {
	Finger_Down,
	Finger_Move,
	Finger_Up,
	Finger_Cancel,
	Pen_Near,
	Pen_Far,
	Pen_Down,
	Pen_Up,
	Pen_Move,
	Pen_Axis,
	Pen_Button,
	Pen_Gesture,
	Mouse_Down,
	Mouse_Up,
	Mouse_Move,
	Mouse_Wheel,
	Key_Down,
	Text,
	Editing,
	Focus_Lost,
	Focus_Gained,
	Keyboard_Shown,
	Keyboard_Hidden,
	Will_Background,
	Background,
	Foreground,
}

@(rodata)
DIAG_COUNT_NAMES := [Diag_Count]string {
	.Finger_Down     = "finger_down",
	.Finger_Move     = "finger_move",
	.Finger_Up       = "finger_up",
	.Finger_Cancel   = "finger_cancel",
	.Pen_Near        = "pen_near",
	.Pen_Far         = "pen_far",
	.Pen_Down        = "pen_down",
	.Pen_Up          = "pen_up",
	.Pen_Move        = "pen_move",
	.Pen_Axis        = "pen_axis",
	.Pen_Button      = "pen_button",
	.Pen_Gesture     = "pen_gesture",
	.Mouse_Down      = "mouse_down",
	.Mouse_Up        = "mouse_up",
	.Mouse_Move      = "mouse_move",
	.Mouse_Wheel     = "mouse_wheel",
	.Key_Down        = "key_down",
	.Text            = "text",
	.Editing         = "editing",
	.Focus_Lost      = "focus_lost",
	.Focus_Gained    = "focus_gained",
	.Keyboard_Shown  = "keyboard_shown",
	.Keyboard_Hidden = "keyboard_hidden",
	.Will_Background = "will_background",
	.Background      = "background",
	.Foreground      = "foreground",
}

// The counts a result's metrics carry as "received" (the schema's list).
@(rodata)
DIAG_RECEIVED := [?]Diag_Count{.Finger_Down, .Finger_Up, .Finger_Cancel, .Pen_Near, .Pen_Far, .Pen_Down, .Pen_Up, .Pen_Move, .Pen_Axis, .Mouse_Down, .Mouse_Up, .Key_Down, .Text}

// What a probe control did.
Diag_Response :: enum u8 {
	Press,
	Release,
	Click,
	Cancel,
	Value,
	Focus,
	Blur,
	Text,
	Pick,
}

@(rodata)
DIAG_RESPONSE_NAMES := [Diag_Response]string{.Press = "press", .Release = "release", .Click = "click", .Cancel = "cancel", .Value = "value", .Focus = "focus", .Blur = "blur", .Text = "text", .Pick = "pick"}

// The screen's controls that a test points at.
Diag_Probe :: enum u8 {
	None,
	Pad,
	Slider,
	Vslider,
	Button,
	Menu,
	Field,
}

@(rodata)
DIAG_PROBE_NAMES := [Diag_Probe]string{.None = "none", .Pad = "pad", .Slider = "slider", .Vslider = "vslider", .Button = "button", .Menu = "menu", .Field = "field"}

// What the screen noticed as it happened, by the report's code.
Diag_Anomaly :: enum u8 {
	Received_Not_Responded,
	Finger_Palm,
	Pen_Near_Stuck,
	Hover_Changed_Value,
	Roll_Jump,
	Roll_Wrong_Direction,
	Stuck_Pressed,
	Down_Without_Up,
	Up_Without_Down,
	Os_Cancel,
	Text_Without_Focus,
	Keyboard_Desync,
	Background_During_Step,
	Pressure_Unavailable,
	Frame_Gap,
	Log_Truncated,
}

@(rodata)
DIAG_ANOMALY_NAMES := [Diag_Anomaly]string {
	.Received_Not_Responded = "received_not_responded",
	.Finger_Palm            = "finger_palm",
	.Pen_Near_Stuck         = "pen_near_stuck",
	.Hover_Changed_Value    = "hover_changed_value",
	.Roll_Jump              = "roll_jump",
	.Roll_Wrong_Direction   = "roll_wrong_direction",
	.Stuck_Pressed          = "stuck_pressed",
	.Down_Without_Up        = "down_without_up",
	.Up_Without_Down        = "up_without_down",
	.Os_Cancel              = "os_cancel",
	.Text_Without_Focus     = "text_without_focus",
	.Keyboard_Desync        = "keyboard_desync",
	.Background_During_Step = "background_during_step",
	.Pressure_Unavailable   = "pressure_unavailable",
	.Frame_Gap              = "frame_gap",
	.Log_Truncated          = "log_truncated",
}

// How much an anomaly says on its own: a fail is a control that did the wrong thing, a
// suspicious one may be the person or the platform, info is context.
@(rodata)
DIAG_ANOMALY_SEVERITY := [Diag_Anomaly]string {
	.Received_Not_Responded = "fail",
	.Finger_Palm            = "suspicious",
	.Pen_Near_Stuck         = "suspicious",
	.Hover_Changed_Value    = "fail",
	.Roll_Jump              = "suspicious",
	.Roll_Wrong_Direction   = "fail",
	.Stuck_Pressed          = "fail",
	.Down_Without_Up        = "suspicious",
	.Up_Without_Down        = "suspicious",
	.Os_Cancel              = "info",
	.Text_Without_Focus     = "suspicious",
	.Keyboard_Desync        = "suspicious",
	.Background_During_Step = "info",
	.Pressure_Unavailable   = "info",
	.Frame_Gap              = "suspicious",
	.Log_Truncated          = "info",
}

Diag_Verdict :: enum u8 {
	None, // only the person can judge this test
	Pass,
	Fail,
	Inconclusive,
	Unavailable, // the device does not report what the test needs
}

@(rodata)
DIAG_VERDICT_NAMES := [Diag_Verdict]string{.None = "none", .Pass = "pass", .Fail = "fail", .Inconclusive = "inconclusive", .Unavailable = "unavailable"}

Diag_Manual :: enum u8 {
	None,
	Pass,
	Fail,
	Inconclusive,
	Skip,
}

@(rodata)
DIAG_MANUAL_NAMES := [Diag_Manual]string{.None = "", .Pass = "pass", .Fail = "fail", .Inconclusive = "inconclusive", .Skip = "skip"}

@(rodata)
DIAG_OWNER_NAMES := [Touch_Owner]string{.None = "none", .Interface = "interface", .Viewport = "viewport"}

@(rodata)
DIAG_POINTER_NAMES := [ui.Pointer_Kind]string{.Mouse = "mouse", .Finger = "finger", .Pen = "pen"}

// What a test measures as it runs, beyond the counts (diag_judge reads them).
Diag_Measures :: struct {
	pen_last:           f64, // seconds when the pen last reported in this run, -1 for not yet
	pen_to_finger:      f64, // from that to the first finger down after it, -1 for none
	after_pen_downs:    int, // finger downs on the pad after the pen was used in this run...
	after_pen_answered: int, // ...that the pad answered
	palm_pen_near:      bool, // the app thought the pen near when it took a finger for a palm
	switches:           int, // changes between finger and pen on the pad
	last_kind:          ui.Pointer_Kind,
	used:               bool, // last_kind holds something
	travel:             f32, // points the pointer moved while holding the pad
	drag_travel:        f32, // points along the size slider's track while it was held...
	drag_value:         f32, // ...and the value that moved, away from its ends
	drag_by:            ui.Pointer_Kind,
	roll_deg:           f32, // roll the app applied while the pen hovered the slider
	roll_value:         f32, // what the slider moved by with nothing touching
	max_step:           f32, // the largest such move in one frame, as a share of its range
	rotation_reports:   int,
	raw_min, raw_max:   f32, // the roll angles the pen reported
	raw_seen:           bool,
	wrapped:            bool, // the reported angle crossed between 180 and -180
	pressure_min:       f32,
	pressure_max:       f32,
	pressure_samples:   int,
	hover_frames:       int, // frames the pen hovered the test's control with nothing touching
	hover_changed:      f32, // what the hovered slider moved by meanwhile...
	hover_roll:         f32, // ...and the roll the app read in those frames
	hover_clicks:       int,
	hover_picks:        int,
	menu_open_frames:   int,
	field_presses:      [ui.Pointer_Kind]int,
	focused_by:         [ui.Pointer_Kind]int,
	field_pen_downs:    int,
	pen_text:           int, // text that arrived while the pen wrote (Scribble)
	text_input_on:      int, // times text input came on and went off
	text_input_off:     int,
	keyboard_known:     bool, // the platform has an on-screen keyboard to report
	keyboard_shown:     int,
	keyboard_hidden:    int,
	focus_changes:      int,
	field:              [64]u8, // the diagnostic field's text when the run ended
	background:         int,
	first_background:   f64, // seconds after the start, -1 for never
	edge_downs:         int,
	order:              int, // hover, contact, lift: 0 nothing, 1 near, 2 down, 3 up, 4 left
	order_broken:       bool,
	pen_stuck:          bool, // the pen stayed near past DIAG_PEN_STUCK after its last report
	stuck_for:          f64,
	pen_near_end:       bool, // the app thought the pen near at the run's last frame
}

// One run of a test: from Start (or Repeat) to its end.
Diag_Run :: struct {
	test:      Diag_Test_Id,
	run:       int, // 1 for a test's first
	start:     f64,
	end:       f64,
	received:  [Diag_Count]int,
	on_probe:  [Diag_Count]int, // pointer downs that landed on the test's control
	responded: [Diag_Response]int, // what the test's control did
	by:        [ui.Pointer_Kind]int, // presses on the test's control by each pointer
	palms:     int,
	anomalies: [Diag_Anomaly]int,
	auto:      Diag_Verdict,
	reason:    [128]u8,
	manual:    Diag_Manual,
	notes:     [160]u8,
	m:         Diag_Measures,
}

// An anomaly for the summary's list.
Diag_Anomaly_Entry :: struct {
	t:      f64,
	run:    int, // index into Diag.runs, -1 outside a test
	code:   Diag_Anomaly,
	detail: [112]u8,
}

// Where a moving pointer was last logged, for sampling.
Diag_Track :: struct {
	used:   bool,
	src:    string, // "finger", "pen" or "mouse"
	id:     u64,
	down:   bool,
	t:      f64,
	at:     [2]f32, // as last logged
	last:   [2]f32, // as last received
	folded: int, // moves received since the last logged line
}

// A pen axis as last logged.
Diag_Axis :: struct {
	seen:   bool,
	t:      f64,
	value:  f32, // as last logged
	last:   f32, // as last received
	folded: int,
}

// A probe's value changes folded into one control line.
Diag_Fold :: struct {
	on:      bool,
	from:    f32,
	to:      f32,
	t:       f64,
	roll:    f32,
	contact: bool,
	by:      ui.Pointer_Kind,
}

// What the pipeline's state was at the end of a frame; a line is logged when it changes.
Diag_State :: struct {
	pointer:    ui.Pointer_Kind,
	down:       bool,
	cancel:     bool,
	owner:      Touch_Owner,
	fingers:    int,
	palm:       bool,
	pen_near:   bool,
	pen_down:   bool,
	pointing:   bool,
	gesture:    bool,
	active:     bool,
	hot:        Diag_Probe,
	text_focus: bool,
	text_input: bool,
	keyboard:   i8, // -1 where the platform cannot say
	pie:        bool,
}

// This frame's happenings, cleared once diag_frame has read them.
Diag_Frame :: struct {
	finger_downs:  int,
	after_pen:     int, // finger downs on the pad after the pen, waiting to see if it answered
	contact_downs: int, // raw downs of any pointer
	pad_presses:   [ui.Pointer_Kind]int,
	text_input_was: bool,
}

// The live values the screen shows.
Diag_Live :: struct {
	event:    [48]u8, // the last event, as words
	at:       [2]f32, // where, in points
	pressure: f32,
	pressure_seen: bool,
	tilt:     [2]f32,
	raw_roll: f32,
	raw_seen: bool,
}

Diag :: struct {
	allowed:  bool, // the screen can be reached (DIAGNOSTICS, or --input-diagnostics)
	open:     bool, // the screen shows
	keep:     bool, // logging goes on after the screen closes, over the app's own panels
	started:  bool, // a session began in this run
	session:  [32]u8,
	start_ns: u64, // SDL ticks at the session's start
	clock0:   f64, // input_clock then
	started_at: time.Time,
	log:      [dynamic]u8, // diagnostic-events.jsonl as it grows
	lines:    int,
	seq:      int,
	dropped:  int,
	truncated: bool,
	counts:   [Diag_Count]int, // every event of the session, sampled into the log or not
	loose:    [Diag_Anomaly]int, // anomalies outside any test
	anomaly_list: [dynamic]Diag_Anomaly_Entry,
	runs:     [dynamic]Diag_Run,
	run_open: bool, // runs' last is under way
	test:     Diag_Test_Id, // the test the screen shows
	tracks:   [16]Diag_Track,
	axes:     [sdl.PenAxis]Diag_Axis,
	raw_roll: Maybe(f32), // the pen's last reported roll, for wraps
	// Raw contact, from the events alone: what is touching whatever the app made of it.
	fingers_down: int,
	pen_tip:  bool,
	mouse_buttons: int,
	pen_heard: f64, // seconds when the pen last reported anything
	state:    Diag_State,
	state_known: bool,
	frame:    Diag_Frame,
	frame_ns: u64,
	rests:    int, // app.idle.rests at the last frame, so a rest is no frame gap
	stuck_since: f64, // when something was first held with nothing touching, -1 for not
	desync_since: f64,
	keyboard_since: f64,
	// The probes: their values, what they did last frame, and where they were laid out
	// (points), which tells a raw event's control.
	slider:   f32,
	vslider:  f32,
	menu:     int,
	field:    [64]u8,
	field_id: ui.Id,
	menu_id:  ui.Id,
	rects:    [Diag_Probe]ui.Rect,
	held:     [Diag_Probe]bool,
	hovered:  [Diag_Probe]bool,
	focused:  bool,
	folds:    [Diag_Probe]Diag_Fold,
	last_mouse: [2]f32,
	trail:    [DIAG_TRAIL]struct {
		at:      [2]f32,
		contact: bool,
		kind:    ui.Pointer_Kind,
	},
	trail_at: int,
	trail_n:  int,
	live:     Diag_Live,
	list_scroll: f32,
	card_scroll: f32,
	controls_scroll: f32,
	exports:  int,
}

// The text a fixed buffer holds, up to its first zero byte.
diag_text :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 do n += 1
	return string(buf[:n])
}

// Copies `s` into a fixed buffer, cut at a whole UTF-8 sequence, with a zero after it.
diag_put_text :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	for n > 0 && n < len(s) && s[n] & 0xc0 == 0x80 do n -= 1
	copy(buf, s[:n])
	for i in n ..< len(buf) do buf[i] = 0
}

// The test a report or --diag-test names.
diag_test_named :: proc(name: string) -> (Diag_Test_Id, bool) {
	for t, id in DIAG_TESTS do if t.key == name do return id, true
	return .Finger_Tap, false
}

// The run under way, nil for none.
diag_run :: proc(d: ^Diag) -> ^Diag_Run {
	if !d.run_open || len(d.runs) == 0 do return nil
	return &d.runs[len(d.runs) - 1]
}

// The test's last run, under way or not, nil for none yet.
diag_last_run :: proc(d: ^Diag, test: Diag_Test_Id) -> ^Diag_Run {
	#reverse for &r in d.runs do if r.test == test do return &r
	return nil
}

// Seconds since the session began, on the frame's clock (fixed under --ui-dt).
diag_now :: proc(app: ^App) -> f64 {
	d := &app.diag
	if app.kit.fixed_dt > 0 do return input_clock(app) - d.clock0
	now := sdl.GetTicksNS()
	return f64(now - d.start_ns) / 1e9 if now > d.start_ns else 0
}

// Seconds since the session began for an event stamped `ns`: when it happened, not when the
// frame read it, which after a return from the background is much later.
@(private = "file")
diag_time_of :: proc(app: ^App, ns: u64) -> f64 {
	d := &app.diag
	if app.kit.fixed_dt > 0 || ns == 0 do return diag_now(app)
	return f64(ns - d.start_ns) / 1e9 if ns > d.start_ns else 0
}

// Window coordinates per point, as the interface counts them; before its first frame, from
// the display as kit_begin will have it.
diag_scale :: proc(app: ^App) -> f32 {
	if app.kit.scale > 0 do return app.kit.scale
	s := kit_content_scale(app.window) * app.kit.ui_scale
	return s if s > 0 else 1
}

// Opens the screen, starting the session the first time.
diag_open :: proc(app: ^App) {
	d := &app.diag
	if !d.allowed do return
	k := &app.kit
	kit_floats_close(k)
	if k.palette do palette_close(app)
	if k.home do home_close(app)
	if !d.started do diag_session_start(app)
	// What was touching when it closed may have lifted since, unseen: start from nothing.
	if !d.keep {
		d.fingers_down, d.pen_tip, d.mouse_buttons = 0, false, 0
		d.tracks, d.axes, d.raw_roll, d.frame_ns, d.state_known = {}, {}, nil, 0, false
		d.stuck_since, d.desync_since, d.keyboard_since = -1, -1, -1
	}
	d.open = true
}

// Closes the screen, ending the run under way. The session stays, to export or go on with.
diag_close :: proc(app: ^App) {
	d := &app.diag
	if d.run_open do diag_run_end(app, .End)
	d.open = false
	if app.kit.ctx.text_focus == d.field_id do app.kit.ctx.text_focus = 0
}

diag_destroy :: proc(app: ^App) {
	d := &app.diag
	delete(d.log)
	delete(d.runs)
	delete(d.anomaly_list)
	d^ = {}
}

// Whether the log records now: while the screen shows, or after it when asked to.
diag_recording :: proc(d: ^Diag) -> bool {
	return d.started && (d.open || d.keep)
}

// ---- The log ----

// Starts a line of `kind` at `t` with the fields every line has.
@(private = "file")
diag_line :: proc(app: ^App, kind: string, t: f64) -> strings.Builder {
	d := &app.diag
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"t":%.3f,"seq":%d,"kind":"%s"`, max(t, 0), d.seq + 1, kind)
	if r := diag_run(d); r != nil {
		fmt.sbprintf(&b, `,"step":"%s","run":%d`, DIAG_TESTS[r.test].key, r.run)
	} else {
		strings.write_string(&b, `,"step":null,"run":0`)
	}
	return b
}

// Ends a line and keeps it, if the log has room for its kind (essential lines say what the
// tests found and get the reserve).
@(private = "file")
diag_keep :: proc(app: ^App, b: ^strings.Builder, essential := false) {
	d := &app.diag
	strings.write_string(b, "}\n")
	line := strings.to_string(b^)
	room := DIAG_LOG_CAP + (DIAG_LOG_RESERVE if essential else 0)
	if len(d.log) + len(line) > room {
		d.dropped += 1
		if !d.truncated do diag_truncate(app)
		return
	}
	append(&d.log, line)
	d.seq += 1
	d.lines += 1
}

// The log reached its cap: says so once, in the log and as an anomaly.
@(private = "file")
diag_truncate :: proc(app: ^App) {
	d := &app.diag
	d.truncated = true
	b := diag_line(app, "truncated", diag_now(app))
	jint(&b, "bytes", len(d.log))
	diag_keep(app, &b, essential = true)
	diag_anomaly(app, .Log_Truncated, "the log reached %d MB; moves and axes are no longer logged", DIAG_LOG_CAP >> 20)
}

// Whether moves and axes are still sampled into the log.
@(private = "file")
diag_sampling :: proc(d: ^Diag) -> bool {
	return len(d.log) < DIAG_SAMPLE_CAP && !d.truncated
}

// A JSON string, escaped; bytes that are not UTF-8 become U+FFFD.
json_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if r < 0x20 || r == 0x7f do fmt.sbprintf(b, `\u%04x`, int(r))
			else do strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

@(private = "file")
jstr :: proc(b: ^strings.Builder, key, value: string) {
	fmt.sbprintf(b, `,"%s":`, key)
	json_quote(b, value)
}

@(private = "file")
jint :: proc(b: ^strings.Builder, key: string, value: int) {
	fmt.sbprintf(b, `,"%s":%d`, key, value)
}

@(private = "file")
jbool :: proc(b: ^strings.Builder, key: string, value: bool) {
	fmt.sbprintf(b, `,"%s":%v`, key, value)
}

// A number, or null where JSON has none (NaN, infinity).
@(private = "file")
jnum :: proc(b: ^strings.Builder, key: string, value: f64) {
	if math.is_nan(value) || math.is_inf(value) {
		fmt.sbprintf(b, `,"%s":null`, key)
		return
	}
	fmt.sbprintf(b, `,"%s":%.4g`, key, value)
}

// A point, as "x" and "y".
@(private = "file")
jat :: proc(b: ^strings.Builder, at: [2]f32) {
	fmt.sbprintf(b, `,"x":%.1f,"y":%.1f`, at.x, at.y)
}

// Notes an anomaly: the first of its code in a run (or outside any) is logged, the rest
// counted, so a stuck state never floods the log.
diag_anomaly :: proc(app: ^App, code: Diag_Anomaly, format: string, args: ..any) {
	d := &app.diag
	if !d.started do return
	r := diag_run(d)
	if r != nil {
		r.anomalies[code] += 1
		if r.anomalies[code] > 1 do return
	} else {
		d.loose[code] += 1
		if d.loose[code] > 1 do return
	}
	detail := fmt.tprintf(format, ..args)
	t := diag_now(app)
	b := diag_line(app, "anomaly", t)
	jstr(&b, "code", DIAG_ANOMALY_NAMES[code])
	jstr(&b, "severity", DIAG_ANOMALY_SEVERITY[code])
	jstr(&b, "detail", detail)
	jint(&b, "count", 1)
	diag_keep(app, &b, essential = true)
	if len(d.anomaly_list) < DIAG_ANOMALY_LIST {
		e := Diag_Anomaly_Entry{t = t, run = len(d.runs) - 1 if r != nil else -1, code = code}
		diag_put_text(e.detail[:], detail)
		append(&d.anomaly_list, e)
	}
}

// The words for the screen's "last event" line.
@(private = "file")
diag_live_event :: proc(d: ^Diag, src, type: string, id: u64, at: [2]f32) {
	s := fmt.bprintf(d.live.event[:len(d.live.event) - 1], "%s %s #%d", src, type, id)
	d.live.event[len(s)] = 0
	d.live.at = at
}

// ---- The session ----

// A UTC time as ISO 8601 (`iso`) or as a session id's stamp.
@(private = "file")
diag_stamp :: proc(t: time.Time, iso: bool) -> string {
	y, mo, da := time.date(t)
	h, mi, s := time.clock_from_time(t)
	if iso do return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), da, h, mi, s)
	return fmt.tprintf("%04d%02d%02d-%02d%02d%02d", y, int(mo), da, h, mi, s)
}

// What the report says the device is: the OS and model where the platform tells them.
diag_device :: proc() -> (os_name, model, build: string) {
	when ODIN_PLATFORM_SUBTARGET_IOS {
		buf := make([]u8, 3 * 64, context.temp_allocator)
		sculpt_ios_device_info(raw_data(buf), raw_data(buf[64:]), raw_data(buf[128:]), 64)
		return diag_text(buf[:64]), diag_text(buf[64:128]), diag_text(buf[128:])
	} else {
		return fmt.tprintf("%v %v", ODIN_OS, ODIN_ARCH), "", ""
	}
}

// Starts the session: its id, its clock and its first line, which says what made it.
@(private = "file")
diag_session_start :: proc(app: ^App) {
	d := &app.diag
	d.started = true
	d.start_ns = sdl.GetTicksNS()
	d.clock0 = input_clock(app)
	d.started_at = time.now()
	d.stuck_since, d.desync_since, d.keyboard_since = -1, -1, -1
	d.slider, d.vslider = 50, 50
	_ = fmt.bprintf(d.session[:len(d.session) - 1], "%s-%04x", diag_stamp(d.started_at, false), u16(d.start_ns >> 12))
	clear(&d.log)
	reserve(&d.log, 64 << 10)
	b := strings.builder_make(context.temp_allocator)
	diag_session_fields(app, &b)
	strings.write_string(&b, "}\n")
	append(&d.log, strings.to_string(b))
	d.lines = 1
}

// The session line's fields after its opening brace, which the summary repeats.
@(private = "file")
diag_session_fields :: proc(app: ^App, b: ^strings.Builder) {
	d := &app.diag
	os_name, model, build := diag_device()
	version := SCULPT_VERSION if build == "" else fmt.tprintf("%s (build %s)", SCULPT_VERSION, build)
	hint := sdl.GetHint(sdl.HINT_IOS_HIDE_HOME_INDICATOR)
	fmt.sbprintf(b, `{{"kind":"session","schema":%d`, DIAG_SCHEMA)
	jstr(b, "session", diag_text(d.session[:]))
	jstr(b, "app", "Sculpt")
	jstr(b, "version", version)
	jstr(b, "build", "debug" when ODIN_DEBUG else "release")
	jstr(b, "platform", string(sdl.GetPlatform()))
	jstr(b, "os", os_name)
	jstr(b, "device", model)
	jstr(b, "started", diag_stamp(d.started_at, true))
	w, h: i32
	_ = sdl.GetWindowSize(app.window, &w, &h)
	scale := diag_scale(app)
	fmt.sbprintf(b, `,"window":[%.0f,%.0f]`, f32(w) / scale, f32(h) / scale)
	jnum(b, "scale", f64(scale))
	strings.write_string(b, `,"hints":{"ios_hide_home_indicator":`)
	json_quote(b, string(hint) if hint != nil else "")
	strings.write_string(b, "}")
	jbool(b, "diagnostics", DIAGNOSTICS)
}

// ---- Runs ----

// How a run ended.
Diag_End :: enum u8 {
	End,
	Skip,
	Next,
}

// Starts a run of `test`, ending the one under way.
diag_run_start :: proc(app: ^App, test: Diag_Test_Id) {
	d := &app.diag
	if !d.started do return
	if d.run_open do diag_run_end(app, .End)
	d.test = test
	if len(d.runs) >= DIAG_RUNS {
		report(app, nil, {.Warning}, "This session has run %d tests: export the report and restart the app to go on", DIAG_RUNS)
		return
	}
	n := 1
	for r in d.runs do if r.test == test do n += 1
	r := Diag_Run{test = test, run = n, start = diag_now(app)}
	r.m.pen_last, r.m.pen_to_finger, r.m.first_background = -1, -1, -1
	r.m.keyboard_known = sdl.HasScreenKeyboardSupport()
	append(&d.runs, r)
	d.run_open = true
	t := DIAG_TESTS[test]
	b := diag_line(app, "step", r.start)
	jstr(&b, "action", "start" if n == 1 else "repeat")
	jstr(&b, "test", t.key)
	jstr(&b, "category", t.category)
	jstr(&b, "device", t.device)
	diag_keep(app, &b, essential = true)
}

// Ends the run under way: its last checks, its verdict, and its result line.
diag_run_end :: proc(app: ^App, how: Diag_End) {
	d := &app.diag
	r := diag_run(d)
	if r == nil do return
	// A value change still being folded belongs to this run.
	for p in Diag_Probe do diag_fold_flush(app, p)
	r.end = diag_now(app)
	if how == .Skip && r.manual == .None do r.manual = .Skip
	// A pointer still down at the end never let go as far as the events say.
	held := 0
	for tr in d.tracks do if tr.used && tr.down do held += 1
	if held > 0 do diag_anomaly(app, .Down_Without_Up, "%d pointers still down when the run ended", held)
	m := &r.m
	if r.test == .Pressure_Ramp && m.pressure_samples == 0 && r.received[.Pen_Down] > 0 {
		diag_anomaly(app, .Pressure_Unavailable, "%d pen downs and no pressure report", r.received[.Pen_Down])
	}
	diag_put_text(m.field[:], diag_text(d.field[:]))
	verdict, reason := diag_judge(r)
	r.auto = verdict
	diag_put_text(r.reason[:], reason)
	if verdict == .Fail && (r.test == .Roll_Right || r.test == .Roll_Left) {
		diag_anomaly(app, .Roll_Wrong_Direction, "%s", reason)
	}
	pen := r.test == .Pencil_Tap || r.test == .Pencil_Drag
	downs := r.on_probe[.Pen_Down] if pen else r.on_probe[.Finger_Down]
	by := r.by[.Pen] if pen else r.by[.Finger]
	if DIAG_TESTS[r.test].probe == .Pad && downs > by {
		diag_anomaly(app, .Received_Not_Responded, "%d %s downs on the pad, %d answered", downs, "pen" if pen else "finger", by)
	}
	b := diag_line(app, "step", r.end)
	names := [Diag_End]string{.End = "end", .Skip = "skip", .Next = "next"}
	jstr(&b, "action", names[how])
	jstr(&b, "test", DIAG_TESTS[r.test].key)
	jstr(&b, "category", DIAG_TESTS[r.test].category)
	jstr(&b, "device", DIAG_TESTS[r.test].device)
	diag_keep(app, &b, essential = true)
	b = diag_line(app, "result", r.end)
	diag_result_fields(&b, r)
	diag_keep(app, &b, essential = true)
	d.run_open = false
}

// A result's fields, in the log and in the summary alike.
@(private = "file")
diag_result_fields :: proc(b: ^strings.Builder, r: ^Diag_Run) {
	jstr(b, "test", DIAG_TESTS[r.test].key)
	jstr(b, "auto", DIAG_VERDICT_NAMES[r.auto])
	jstr(b, "auto_reason", diag_text(r.reason[:]))
	if r.manual == .None {
		strings.write_string(b, `,"manual":null`)
	} else {
		jstr(b, "manual", DIAG_MANUAL_NAMES[r.manual])
	}
	jstr(b, "notes", diag_text(r.notes[:]))
	strings.write_string(b, `,"metrics":{`)
	diag_metrics(b, r)
	strings.write_string(b, "}")
}

// The run's metrics, the schema's common three then its test's own.
@(private = "file")
diag_metrics :: proc(b: ^strings.Builder, r: ^Diag_Run) {
	m := &r.m
	strings.write_string(b, `"received":{`)
	for c, i in DIAG_RECEIVED {
		if i > 0 do strings.write_byte(b, ',')
		fmt.sbprintf(b, `"%s":%d`, DIAG_COUNT_NAMES[c], r.received[c])
	}
	strings.write_string(b, `},"responded":{`)
	for name, i in DIAG_RESPONSE_NAMES {
		if i != .Press do strings.write_byte(b, ',')
		fmt.sbprintf(b, `"%s":%d`, name, r.responded[i])
	}
	strings.write_string(b, "}")
	jint(b, "palms", r.palms)
	opt :: proc(b: ^strings.Builder, key: string, v: f64, known: bool) {
		if known do jnum(b, key, v)
		else do fmt.sbprintf(b, `,"%s":null`, key)
	}
	#partial switch r.test {
	case .Finger_After_Pencil, .Finger_Pencil_Switch:
		opt(b, "pen_to_finger_ms", 1000 * m.pen_to_finger, m.pen_to_finger >= 0)
		jint(b, "after_pen_downs", m.after_pen_downs)
		jint(b, "after_pen_answered", m.after_pen_answered)
		jint(b, "switches", m.switches)
	case .Finger_Drag, .Pencil_Drag:
		jnum(b, "travel_pt", f64(m.travel))
	case .Slider_Ratio_Finger, .Slider_Ratio_Pencil:
		ratio, expected := diag_ratio(m)
		jnum(b, "ratio", f64(ratio))
		jnum(b, "expected_ratio", f64(expected))
		jnum(b, "travel_pt", f64(m.drag_travel))
		jnum(b, "value_delta", f64(m.drag_value))
		jstr(b, "by", DIAG_POINTER_NAMES[m.drag_by])
	case .Roll_Right, .Roll_Left, .Roll_Neutral, .Roll_Wrap:
		jnum(b, "roll_deg", f64(m.roll_deg))
		jnum(b, "value_delta", f64(m.roll_value))
		opt(b, "raw_min", f64(m.raw_min), m.raw_seen)
		opt(b, "raw_max", f64(m.raw_max), m.raw_seen)
		jbool(b, "wrapped", m.wrapped)
		jnum(b, "max_step", f64(m.max_step))
		jint(b, "rotation_reports", m.rotation_reports)
		jint(b, "hover_frames", m.hover_frames)
	case .Pressure_Ramp:
		opt(b, "pressure_min", f64(m.pressure_min), m.pressure_samples > 0)
		opt(b, "pressure_max", f64(m.pressure_max), m.pressure_samples > 0)
		jint(b, "pressure_samples", m.pressure_samples)
	case .Hover_Slider, .Hover_Button, .Hover_Menu:
		jint(b, "hover_frames", m.hover_frames)
		if r.test == .Hover_Slider do jnum(b, "value_delta", f64(m.hover_changed))
		if r.test == .Hover_Slider do jnum(b, "hover_roll", f64(m.hover_roll))
		if r.test == .Hover_Button do jint(b, "clicks", m.hover_clicks)
		if r.test == .Hover_Menu do jint(b, "picks", m.hover_picks)
		if r.test == .Hover_Menu do jint(b, "open_frames", m.menu_open_frames)
	case .Text_Focus_Finger, .Text_Focus_Pencil, .Text_Typing, .Text_Dismiss_Reopen, .Text_Scribble:
		jstr(b, "field", diag_text(m.field[:]))
		jint(b, "focus_changes", m.focus_changes)
		jbool(b, "text_input_on", m.text_input_on > 0)
		jint(b, "text_input_ons", m.text_input_on)
		jint(b, "text_input_offs", m.text_input_off)
		if m.keyboard_known do jbool(b, "keyboard_shown", m.keyboard_shown > 0)
		else do strings.write_string(b, `,"keyboard_shown":null`)
		jint(b, "pen_text", m.pen_text)
	case .Home_Swipe_Baseline, .Home_Swipe_After_Pencil:
		jint(b, "background", m.background)
		jint(b, "edge_downs", m.edge_downs)
		opt(b, "seconds_to_background", m.first_background, m.first_background >= 0)
	case .Pencil_Hover, .Pencil_Hover_Contact_Lift:
		jint(b, "hover_frames", m.hover_frames)
		jbool(b, "pen_stuck", m.pen_stuck)
		jbool(b, "pen_near_at_end", m.pen_near_end)
		jint(b, "order", m.order)
	}
}

// ---- Events ----

// The track of pointer (`src`, `id`), made if new.
@(private = "file")
diag_track :: proc(d: ^Diag, src: string, id: u64) -> ^Diag_Track {
	free_slot := -1
	for &tr, i in d.tracks {
		if tr.used && tr.src == src && tr.id == id do return &tr
		if free_slot < 0 && (!tr.used || !tr.down) do free_slot = i
	}
	tr := &d.tracks[max(free_slot, 0)]
	tr^ = {used = true, src = src, id = id}
	return tr
}

// A pointer moved to `at`: logged if far or long enough since its last line, else folded.
@(private = "file")
diag_move :: proc(app: ^App, src: string, id: u64, at: [2]f32, t: f64) {
	d := &app.diag
	tr := diag_track(d, src, id)
	tr.folded += 1
	tr.last = at
	gap := t - tr.t
	moved := at - tr.at
	if !diag_sampling(d) || (gap < DIAG_MOVE_GAP && moved.x * moved.x + moved.y * moved.y < DIAG_MOVE_TRAVEL * DIAG_MOVE_TRAVEL) do return
	diag_move_line(app, tr, t)
}

// Logs a track's latest position as a move, folding what came since its last line.
@(private = "file")
diag_move_line :: proc(app: ^App, tr: ^Diag_Track, t: f64) {
	b := diag_line(app, "event", t)
	jstr(&b, "src", tr.src)
	jstr(&b, "type", "move")
	jint(&b, "id", int(tr.id))
	jat(&b, tr.last)
	fmt.sbprintf(&b, `,"dx":%.1f,"dy":%.1f`, tr.last.x - tr.at.x, tr.last.y - tr.at.y)
	jint(&b, "n", tr.folded)
	if tr.src == "pen" && app.diag.live.pressure_seen && tr.down do jnum(&b, "pressure", f64(app.diag.live.pressure))
	diag_keep(app, &b)
	tr.t, tr.at, tr.folded = t, tr.last, 0
}

// A pointer went down, up or was cancelled at `at`. An up first logs the moves it folded,
// so the path ends where the pointer let go.
@(private = "file")
diag_contact :: proc(app: ^App, src, type: string, id: u64, at: [2]f32, t: f64, pressure: f32 = -1) {
	d := &app.diag
	tr := diag_track(d, src, id)
	down := type == "down"
	if !down && tr.folded > 0 && diag_sampling(d) do diag_move_line(app, tr, t)
	if !down && !tr.down && src != "mouse" do diag_anomaly(app, .Up_Without_Down, "%s %d %s with no down", src, id, type)
	if down && tr.down && src != "mouse" do diag_anomaly(app, .Down_Without_Up, "%s %d down again with no up", src, id)
	b := diag_line(app, "event", t)
	jstr(&b, "src", src)
	jstr(&b, "type", type)
	jint(&b, "id", int(id))
	jat(&b, at)
	if pressure >= 0 do jnum(&b, "pressure", f64(pressure))
	diag_keep(app, &b)
	tr.down, tr.t, tr.at, tr.last, tr.folded = down, t, at, at, 0
	diag_live_event(d, src, type, id, at)
}

// A line for an event with nothing but its source and type (and an id).
@(private = "file")
diag_plain :: proc(app: ^App, src, type: string, t: f64, id: u64 = 0) {
	b := diag_line(app, "event", t)
	jstr(&b, "src", src)
	jstr(&b, "type", type)
	jint(&b, "id", int(id))
	diag_keep(app, &b)
	diag_live_event(&app.diag, src, type, id, app.diag.live.at)
}

// Which probe is under `at` (points), by where it was laid out last.
@(private = "file")
diag_probe_at :: proc(d: ^Diag, at: [2]f32) -> Diag_Probe {
	for r, p in d.rects {
		if p == .None || r.w <= 0 do continue
		if at.x >= r.x && at.y >= r.y && at.x < r.x + r.w && at.y < r.y + r.h do return p
	}
	return .None
}

// Counts an event in the session and in the run under way.
@(private = "file")
diag_count :: proc(d: ^Diag, c: Diag_Count) {
	d.counts[c] += 1
	if r := diag_run(d); r != nil do r.received[c] += 1
}

// A pointer down on the run's control, by the raw event.
@(private = "file")
diag_down_on :: proc(d: ^Diag, c: Diag_Count, at: [2]f32, kind: ui.Pointer_Kind) {
	r := diag_run(d)
	if r == nil do return
	probe := diag_probe_at(d, at)
	if probe != .None && probe == DIAG_TESTS[r.test].probe do r.on_probe[c] += 1
	m := &r.m
	if probe == .Pad || probe == .Field {
		if m.used && m.last_kind != kind do m.switches += 1
		m.last_kind, m.used = kind, true
	}
	if kind == .Pen && probe == .Field do m.field_pen_downs += 1
}

// Reads one SDL event before the app's own handlers, while the log records. Window
// coordinates become points, as the interface's.
diag_event :: proc(app: ^App, e: ^sdl.Event) {
	d := &app.diag
	if !diag_recording(d) do return
	t := diag_time_of(app, e.common.timestamp)
	scale := diag_scale(app)
	r := diag_run(d)
	if app.pencil.event_type != 0 && u32(e.type) == app.pencil.event_type {
		diag_count(d, .Pen_Gesture)
		names := [?]string{"double_tap", "squeeze_began", "squeeze_ended", "squeeze_cancelled"}
		b := diag_line(app, "event", t)
		jstr(&b, "src", "pen")
		jstr(&b, "type", "gesture")
		jint(&b, "id", 0)
		jstr(&b, "gesture", names[e.user.code] if e.user.code >= 0 && int(e.user.code) < len(names) else "unknown")
		diag_keep(app, &b)
		d.pen_heard = t
		return
	}
	#partial switch e.type {
	case .FINGER_DOWN, .FINGER_MOTION, .FINGER_UP, .FINGER_CANCELED:
		f := e.tfinger
		// The pen's and the mouse's stand-in fingers are no fingers (touch_event drops them too).
		if f.touchID == sdl.PEN_TOUCHID || f.touchID == sdl.MOUSE_TOUCHID do return
		w, h: i32
		_ = sdl.GetWindowSize(app.window, &w, &h)
		at := [2]f32{f.x * f32(w), f.y * f32(h)} / scale
		id := u64(f.fingerID)
		#partial switch e.type {
		case .FINGER_DOWN:
			diag_count(d, .Finger_Down)
			d.fingers_down += 1
			d.frame.finger_downs += 1
			d.frame.contact_downs += 1
			diag_down_on(d, .Finger_Down, at, .Finger)
			if r != nil {
				m := &r.m
				if at.y >= app.kit.ctx.input.window.y - DIAG_EDGE do m.edge_downs += 1
				if m.pen_last >= 0 && diag_probe_at(d, at) == .Pad {
					m.after_pen_downs += 1
					d.frame.after_pen += 1
					if m.pen_to_finger < 0 do m.pen_to_finger = t - m.pen_last
				}
			}
			diag_contact(app, "finger", "down", id, at, t, f.pressure)
		case .FINGER_MOTION:
			diag_count(d, .Finger_Move)
			diag_move(app, "finger", id, at, t)
		case:
			cancel := e.type == .FINGER_CANCELED
			diag_count(d, .Finger_Cancel if cancel else .Finger_Up)
			d.fingers_down = max(d.fingers_down - 1, 0)
			if cancel do diag_anomaly(app, .Os_Cancel, "the system cancelled finger %d", id)
			diag_contact(app, "finger", "cancel" if cancel else "up", id, at, t)
		}
		diag_trail(d, at, e.type != .FINGER_UP && e.type != .FINGER_CANCELED, .Finger)
	case .PEN_PROXIMITY_IN, .PEN_PROXIMITY_OUT:
		near := e.type == .PEN_PROXIMITY_IN
		diag_count(d, .Pen_Near if near else .Pen_Far)
		diag_plain(app, "pen", "near" if near else "far", t, u64(e.pproximity.which))
		d.pen_heard = t
		if !near do d.raw_roll = nil
		if r != nil {
			r.m.pen_last = t
			if near && r.m.order == 0 do r.m.order = 1
			if !near && r.m.order == 3 do r.m.order = 4
		}
	case .PEN_MOTION:
		p := e.pmotion
		at := [2]f32{p.x, p.y} / scale
		diag_count(d, .Pen_Move)
		diag_move(app, "pen", u64(p.which), at, t)
		d.pen_heard = t
		if r != nil {
			r.m.pen_last = t
			// A hover move with no proximity event first is the pen near as far as order goes:
			// SDL's UIKit driver adds the pencil already near (SDL_uikitpen.m).
			if r.m.order == 0 && !d.pen_tip do r.m.order = 1
		}
		diag_trail(d, at, d.pen_tip, .Pen)
	case .PEN_DOWN, .PEN_UP:
		p := e.ptouch
		at := [2]f32{p.x, p.y} / scale
		down := e.type == .PEN_DOWN
		diag_count(d, .Pen_Down if down else .Pen_Up)
		d.pen_tip = down
		d.pen_heard = t
		if down {
			d.frame.contact_downs += 1
			diag_down_on(d, .Pen_Down, at, .Pen)
		}
		if r != nil {
			m := &r.m
			m.pen_last = t
			switch {
			case down && m.order == 0: m.order_broken = true; m.order = 2
			case down && m.order == 1: m.order = 2
			case !down && m.order == 2: m.order = 3
			case !down && m.order < 2:  m.order_broken = true
			}
		}
		diag_contact(app, "pen", "down" if down else "up", u64(p.which), at, t, d.live.pressure if d.live.pressure_seen else -1)
		diag_trail(d, at, down, .Pen)
	case .PEN_AXIS:
		diag_pen_axis(app, e.paxis, t)
	case .PEN_BUTTON_DOWN, .PEN_BUTTON_UP:
		p := e.pbutton
		diag_count(d, .Pen_Button)
		d.pen_heard = t
		b := diag_line(app, "event", t)
		jstr(&b, "src", "pen")
		jstr(&b, "type", "button_down" if p.down else "button_up")
		jint(&b, "id", int(p.which))
		jint(&b, "button", int(p.button))
		diag_keep(app, &b)
	case .MOUSE_MOTION:
		// The pen's twin as the mouse is the pen's, logged as such above.
		if e.motion.which == sdl.PEN_MOUSEID do return
		at := [2]f32{e.motion.x, e.motion.y} / scale
		diag_count(d, .Mouse_Move)
		diag_move(app, "mouse", u64(e.motion.which), at, t)
		diag_trail(d, at, d.mouse_buttons > 0, .Mouse)
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if e.button.which == sdl.PEN_MOUSEID do return
		at := [2]f32{e.button.x, e.button.y} / scale
		down := e.button.down
		diag_count(d, .Mouse_Down if down else .Mouse_Up)
		if down {
			d.mouse_buttons += 1
			d.frame.contact_downs += 1
			diag_down_on(d, .Mouse_Down, at, .Mouse)
		} else {
			d.mouse_buttons = max(d.mouse_buttons - 1, 0)
		}
		diag_contact(app, "mouse", "down" if down else "up", u64(e.button.which), at, t)
	case .MOUSE_WHEEL:
		diag_count(d, .Mouse_Wheel)
	case .KEY_DOWN:
		diag_count(d, .Key_Down)
		k := e.key.key
		// A letter's key says what was typed, which is the person's: only keys that type
		// nothing are named, from a list, so a keypad's digits or a layout's own keys never are.
		printable := !diag_key_named(k)
		b := diag_line(app, "event", t)
		jstr(&b, "src", "key")
		jstr(&b, "type", "key_down")
		jint(&b, "id", 0)
		jstr(&b, "key", "printable" if printable else string(sdl.GetKeyName(k)))
		if e.key.repeat do jbool(&b, "repeat", true)
		diag_keep(app, &b)
	case .TEXT_INPUT:
		diag_count(d, .Text)
		text := string(e.text.text)
		ours := app.kit.ctx.text_focus != 0 && app.kit.ctx.text_focus == d.field_id
		if app.kit.ctx.text_focus == 0 do diag_anomaly(app, .Text_Without_Focus, "%d bytes of text arrived with no field holding the keys", len(text))
		if r != nil && (d.pen_tip || t - d.pen_heard < 1) do r.m.pen_text += 1
		b := diag_line(app, "event", t)
		jstr(&b, "src", "text")
		jstr(&b, "type", "text")
		jint(&b, "id", 0)
		jint(&b, "len", len(text))
		if ours do jstr(&b, "text", text[:diag_cut(text, DIAG_TEXT_LOGGED)])
		diag_keep(app, &b)
	case .TEXT_EDITING:
		diag_count(d, .Editing)
		b := diag_line(app, "event", t)
		jstr(&b, "src", "text")
		jstr(&b, "type", "editing")
		jint(&b, "id", 0)
		jint(&b, "len", len(string(e.edit.text)))
		diag_keep(app, &b)
	case .SCREEN_KEYBOARD_SHOWN, .SCREEN_KEYBOARD_HIDDEN:
		shown := e.type == .SCREEN_KEYBOARD_SHOWN
		diag_count(d, .Keyboard_Shown if shown else .Keyboard_Hidden)
		if r != nil {
			if shown do r.m.keyboard_shown += 1
			else do r.m.keyboard_hidden += 1
		}
		diag_plain(app, "window", "keyboard_shown" if shown else "keyboard_hidden", t)
	case .WINDOW_FOCUS_LOST, .WINDOW_FOCUS_GAINED:
		lost := e.type == .WINDOW_FOCUS_LOST
		diag_count(d, .Focus_Lost if lost else .Focus_Gained)
		diag_plain(app, "window", "focus_lost" if lost else "focus_gained", t)
	case .WILL_ENTER_BACKGROUND, .DID_ENTER_BACKGROUND, .DID_ENTER_FOREGROUND:
		c := Diag_Count.Will_Background
		name := "will_background"
		#partial switch e.type {
		case .DID_ENTER_BACKGROUND: c, name = .Background, "background"
		case .DID_ENTER_FOREGROUND: c, name = .Foreground, "foreground"
		}
		diag_count(d, c)
		diag_plain(app, "app", name, t)
		if c == .Background && r != nil {
			r.m.background += 1
			if r.m.first_background < 0 do r.m.first_background = t - r.start
			if r.test != .Home_Swipe_Baseline && r.test != .Home_Swipe_After_Pencil do diag_anomaly(app, .Background_During_Step, "the app went to the background during %s", DIAG_TESTS[r.test].key)
		}
	}
}

// Whether a key types nothing, and so may be logged by name: editing, moving, modifiers and
// function keys.
@(private = "file")
diag_key_named :: proc(k: sdl.Keycode) -> bool {
	switch k {
	case sdl.K_BACKSPACE, sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_ESCAPE, sdl.K_TAB, sdl.K_DELETE, sdl.K_INSERT,
	     sdl.K_LEFT, sdl.K_RIGHT, sdl.K_UP, sdl.K_DOWN, sdl.K_HOME, sdl.K_END, sdl.K_PAGEUP, sdl.K_PAGEDOWN,
	     sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LALT, sdl.K_RALT, sdl.K_LGUI, sdl.K_RGUI,
	     sdl.K_CAPSLOCK, sdl.K_AC_BACK:
		return true
	}
	return k >= sdl.K_F1 && k <= sdl.K_F12 || k >= sdl.K_F13 && k <= sdl.K_F24
}

// The bytes of `s` up to `most`, cut at a whole UTF-8 sequence.
@(private = "file")
diag_cut :: proc(s: string, most: int) -> int {
	n := min(len(s), most)
	for n > 0 && n < len(s) && s[n] & 0xc0 == 0x80 do n -= 1
	return n
}

// A pen axis report: sampled into the log, and what the run measures of it.
@(private = "file")
diag_pen_axis :: proc(app: ^App, p: sdl.PenAxisEvent, t: f64) {
	d := &app.diag
	diag_count(d, .Pen_Axis)
	d.pen_heard = t
	r := diag_run(d)
	if r != nil do r.m.pen_last = t
	v := p.value
	wrap := false
	#partial switch p.axis {
	case .PRESSURE:
		d.live.pressure, d.live.pressure_seen = v, true
		if r != nil && d.pen_tip {
			m := &r.m
			if m.pressure_samples == 0 do m.pressure_min, m.pressure_max = v, v
			m.pressure_min, m.pressure_max = min(m.pressure_min, v), max(m.pressure_max, v)
			m.pressure_samples += 1
		}
	case .XTILT: d.live.tilt.x = v
	case .YTILT: d.live.tilt.y = v
	case .ROTATION:
		if last, ok := d.raw_roll.?; ok && abs(v - last) > 180 do wrap = true
		d.raw_roll = v
		d.live.raw_roll, d.live.raw_seen = v, true
		if r != nil {
			m := &r.m
			m.rotation_reports += 1
			if !m.raw_seen do m.raw_min, m.raw_max, m.raw_seen = v, v, true
			m.raw_min, m.raw_max = min(m.raw_min, v), max(m.raw_max, v)
			if wrap do m.wrapped = true
		}
	}
	ax := &d.axes[p.axis]
	ax.folded += 1
	ax.last = v
	steps := DIAG_AXIS_STEP
	if !wrap && ax.seen && (!diag_sampling(d) || (abs(v - ax.value) < steps[p.axis] && t - ax.t < DIAG_MOVE_GAP * 2)) do return
	names := [sdl.PenAxis]string{.PRESSURE = "pressure", .XTILT = "xtilt", .YTILT = "ytilt", .DISTANCE = "distance", .ROTATION = "rotation", .SLIDER = "slider", .TANGENTIAL_PRESSURE = "tangential"}
	b := diag_line(app, "event", t)
	jstr(&b, "src", "pen")
	jstr(&b, "type", "axis")
	jint(&b, "id", int(p.which))
	jstr(&b, "axis", names[p.axis])
	jnum(&b, "value", f64(v))
	jint(&b, "n", ax.folded)
	if wrap do jbool(&b, "wrap", true)
	diag_keep(app, &b)
	ax.seen, ax.t, ax.value, ax.folded = true, t, v, 0
}

// Where the pointer went, for the pad's picture.
@(private = "file")
diag_trail :: proc(d: ^Diag, at: [2]f32, contact: bool, kind: ui.Pointer_Kind) {
	if !d.open do return
	d.trail[d.trail_at] = {at, contact, kind}
	d.trail_at = (d.trail_at + 1) % DIAG_TRAIL
	d.trail_n = min(d.trail_n + 1, DIAG_TRAIL)
}

// ---- The probes (kit_diag.odin reports each one here as it is laid out) ----

// Whether anything touches, by the raw events alone.
diag_touching :: proc(d: ^Diag) -> bool {
	return d.fingers_down > 0 || d.pen_tip || d.mouse_buttons > 0 || d.frame.contact_downs > 0
}

// One probe's frame: what it did, logged as control lines, counted for the run when it is the
// test's own control, and measured for the test. `before` and `after` are its value around
// the widget.
diag_probe :: proc(app: ^App, probe: Diag_Probe, hovered, held, clicked: bool, before, after: f32) {
	d := &app.diag
	ctx := &app.kit.ctx
	by := ctx.input.pointer
	contact := diag_touching(d)
	now := diag_now(app)
	was_held, was_hovered := d.held[probe], d.hovered[probe]
	d.held[probe], d.hovered[probe] = held, hovered
	r := diag_run(d)
	ours := r != nil && DIAG_TESTS[r.test].probe == probe
	line :: proc(app: ^App, probe: Diag_Probe, action: string, by: ui.Pointer_Kind, contact: bool, t: f64) -> strings.Builder {
		b := diag_line(app, "control", t)
		jstr(&b, "control", DIAG_PROBE_NAMES[probe])
		jstr(&b, "action", action)
		jstr(&b, "by", DIAG_POINTER_NAMES[by])
		jbool(&b, "contact", contact)
		return b
	}
	respond :: proc(r: ^Diag_Run, ours: bool, what: Diag_Response) {
		if ours do r.responded[what] += 1
	}
	// Hovering is the pen's and the mouse's: a finger is only over what it touches.
	if by != .Finger && !contact && hovered != was_hovered && !held {
		b := line(app, probe, "hover_in" if hovered else "hover_out", by, contact, now)
		diag_keep(app, &b)
	}
	if held && !was_held {
		b := line(app, probe, "press", by, contact, now)
		jnum(&b, "before", f64(before))
		diag_keep(app, &b)
		respond(r, ours, .Press)
		if ours do r.by[by] += 1
		if probe == .Pad do d.frame.pad_presses[by] += 1
		if probe == .Field && r != nil do r.m.field_presses[by] += 1
	}
	if !held && was_held {
		cancel := ctx.input.cancel
		b := line(app, probe, "cancel" if cancel else "release", by, contact, now)
		jnum(&b, "after", f64(after))
		diag_keep(app, &b)
		respond(r, ours, .Cancel if cancel else .Release)
	}
	if clicked {
		b := line(app, probe, "click", by, contact, now)
		diag_keep(app, &b)
		respond(r, ours, .Click)
		if ours && probe == .Button && !contact && d.frame.contact_downs == 0 do r.m.hover_clicks += 1
	}
	// Value changes fold into one line a tenth of a second, so a drag or a roll is a few
	// lines, never one a frame.
	fold := &d.folds[probe]
	if diag_moved(before, after) {
		if !fold.on do fold^ = {on = true, from = before, t = now, contact = contact, by = by}
		fold.to = after
		fold.roll += ctx.input.roll
	}
	if fold.on && (now - fold.t >= 0.1 || contact != fold.contact || !(hovered || held)) do diag_fold_flush(app, probe)
	if r == nil || !ours do return
	m := &r.m
	pen_hover := by == .Pen && hovered && !held && !contact
	#partial switch probe {
	case .Pad:
		if held {
			delta := ctx.input.mouse - d.last_mouse
			if was_held do m.travel += math.sqrt(delta.x * delta.x + delta.y * delta.y)
		}
		if pen_hover do m.hover_frames += 1
	case .Slider:
		if pen_hover do m.hover_frames += 1
		if !contact && diag_moved(before, after) {
			change := after - before
			m.roll_value += change
			m.max_step = max(m.max_step, abs(change) / DIAG_RANGE)
			if r.test == .Hover_Slider do m.hover_changed += change
			if r.test == .Hover_Slider do m.hover_roll += ctx.input.roll
			if r.test == .Hover_Slider do diag_anomaly(app, .Hover_Changed_Value, "the slider moved %.2f with nothing touching (roll %.1f degrees)", change, ctx.input.roll)
			if abs(change) / DIAG_RANGE > DIAG_ROLL_JUMP do diag_anomaly(app, .Roll_Jump, "the slider jumped %.0f%% of its range in one frame", 100 * abs(change) / DIAG_RANGE)
		}
		if pen_hover do m.roll_deg += ctx.input.roll
	case .Vslider:
		if held && was_held {
			dy := abs(ctx.input.mouse.y - d.last_mouse.y)
			inside := before > 0 && before < DIAG_RANGE && after > 0 && after < DIAG_RANGE
			if dy > 0 && inside {
				m.drag_travel += dy
				m.drag_value += abs(after - before)
				m.drag_by = by
			}
		}
	case .Button:
		if pen_hover do m.hover_frames += 1
	}
}

// Logs a probe's folded value changes as one control line, counted as one response of the
// run's control, as the report's reader counts them.
@(private = "file")
diag_fold_flush :: proc(app: ^App, probe: Diag_Probe) {
	d := &app.diag
	fold := &d.folds[probe]
	if !fold.on do return
	b := diag_line(app, "control", diag_now(app))
	jstr(&b, "control", DIAG_PROBE_NAMES[probe])
	jstr(&b, "action", "value")
	jstr(&b, "by", DIAG_POINTER_NAMES[fold.by])
	jbool(&b, "contact", fold.contact)
	jnum(&b, "before", f64(fold.from))
	jnum(&b, "after", f64(fold.to))
	jnum(&b, "roll", f64(fold.roll))
	diag_keep(app, &b)
	if r := diag_run(d); r != nil && DIAG_TESTS[r.test].probe == probe do r.responded[.Value] += 1
	fold^ = {}
}

// The menu probe's frame: whether its list is open, and what was picked.
diag_menu :: proc(app: ^App, open: bool, picked: int) {
	d := &app.diag
	ctx := &app.kit.ctx
	r := diag_run(d)
	if picked >= 0 {
		contact := diag_touching(d)
		b := diag_line(app, "control", diag_now(app))
		jstr(&b, "control", "menu")
		jstr(&b, "action", "pick")
		jstr(&b, "by", DIAG_POINTER_NAMES[ctx.input.pointer])
		jbool(&b, "contact", contact)
		jint(&b, "after", picked)
		diag_keep(app, &b)
		if r != nil && r.test == .Hover_Menu {
			r.responded[.Pick] += 1
			if !contact && d.frame.contact_downs == 0 && .Left not_in app.device.released do r.m.hover_picks += 1
		}
	}
	if r == nil || r.test != .Hover_Menu || !open do return
	r.m.menu_open_frames += 1
	if ctx.input.pointer == .Pen && ctx.input.mouse_valid && !diag_touching(d) do r.m.hover_frames += 1
}

// The field probe's frame: focus gained or lost, and text that changed.
diag_field :: proc(app: ^App, focused, changed: bool) {
	d := &app.diag
	ctx := &app.kit.ctx
	r := diag_run(d)
	ours := r != nil && DIAG_TESTS[r.test].probe == .Field
	by := ctx.input.pointer
	now := diag_now(app)
	if focused != d.focused {
		b := diag_line(app, "control", now)
		jstr(&b, "control", "field")
		jstr(&b, "action", "focus" if focused else "blur")
		jstr(&b, "by", DIAG_POINTER_NAMES[by])
		jbool(&b, "contact", diag_touching(d))
		diag_keep(app, &b)
		if ours {
			r.responded[.Focus if focused else .Blur] += 1
			r.m.focus_changes += 1
			if focused do r.m.focused_by[by] += 1
		}
		d.focused = focused
	}
	if changed {
		text := diag_text(d.field[:])
		b := diag_line(app, "control", now)
		jstr(&b, "control", "field")
		jstr(&b, "action", "text")
		jstr(&b, "by", DIAG_POINTER_NAMES[by])
		jbool(&b, "contact", diag_touching(d))
		jint(&b, "len", len(text))
		jstr(&b, "text", text[:diag_cut(text, DIAG_TEXT_LOGGED)])
		diag_keep(app, &b)
		if ours do r.responded[.Text] += 1
	}
}

// ---- The frame ----

// Reads what the frame made of its events once the interface is done (after ui.frame_end, so
// the held control and the field with the keys are settled): palms, a pen that never left,
// something left pressed, a field and keyboard that disagree, a frame that took too long, and
// a state line when the pipeline changed.
diag_frame :: proc(app: ^App) {
	d := &app.diag
	defer {
		d.frame = {}
		d.last_mouse = app.kit.ctx.input.mouse
		d.rests = app.idle.rests
	}
	if !diag_recording(d) do return
	ctx := &app.kit.ctx
	t := &app.touch
	now := diag_now(app)
	r := diag_run(d)
	ns := sdl.GetTicksNS()
	// Only while something touches and the app did not rest or sleep in the background: a
	// gap then is a gesture that stalled.
	if d.frame_ns != 0 && app.kit.fixed_dt == 0 && app.idle.rests == d.rests && d.fingers_down + int(d.pen_tip) > 0 {
		if gap := f64(ns - d.frame_ns) / 1e9; gap > DIAG_FRAME_GAP do diag_anomaly(app, .Frame_Gap, "a frame took %.0f ms while a pointer was down", 1000 * gap)
	}
	d.frame_ns = ns
	// A finger that landed this frame and was taken for the hand holding the pen.
	if d.frame.finger_downs > 0 && t.fingers.count > 0 && t.palm {
		if r != nil {
			r.palms += d.frame.finger_downs
			if t.pen_near do r.m.palm_pen_near = true
		}
		diag_anomaly(app, .Finger_Palm, "a finger was taken for a palm: pen near %v, pen down %v, %.2f s after the pen last reported", t.pen_near, t.pen_down, now - d.pen_heard)
	}
	if r != nil && d.frame.after_pen > 0 {
		r.m.after_pen_answered += min(d.frame.after_pen, d.frame.pad_presses[.Finger])
	}
	// The pen still "near" long after its last report: the platform never said it left.
	if t.pen_near && !t.pen_down && !d.pen_tip && now - d.pen_heard > DIAG_PEN_STUCK {
		if r != nil {
			r.m.pen_stuck = true
			r.m.stuck_for = now - d.pen_heard
		}
		diag_anomaly(app, .Pen_Near_Stuck, "the pen still counts as near %.1f s after its last report", now - d.pen_heard)
	}
	if r != nil {
		r.m.pen_near_end = t.pen_near
		if r.m.order == 3 && !t.pen_near do r.m.order = 4
	}
	// Something held with nothing touching.
	held := ctx.active != 0 || app.device.down != {}
	if held && d.fingers_down == 0 && !d.pen_tip && d.mouse_buttons == 0 {
		if d.stuck_since < 0 do d.stuck_since = now
		if now - d.stuck_since > DIAG_STUCK do diag_anomaly(app, .Stuck_Pressed, "held for %.2f s with nothing touching (control %v, buttons %v)", now - d.stuck_since, ctx.active != 0, app.device.down)
	} else {
		d.stuck_since = -1
	}
	// The field with the keys while text input is off, or the keyboard up with no field.
	text_input := app.kit.text_input
	focus := ctx.text_focus != 0
	if focus && !text_input {
		if d.desync_since < 0 do d.desync_since = now
		if now - d.desync_since > DIAG_DESYNC do diag_anomaly(app, .Keyboard_Desync, "a field held the keys for %.2f s with text input off", now - d.desync_since)
	} else {
		d.desync_since = -1
	}
	keyboard: i8 = -1
	if sdl.HasScreenKeyboardSupport() do keyboard = 1 if sdl.ScreenKeyboardShown(app.window) else 0
	if keyboard == 1 && !focus {
		if d.keyboard_since < 0 do d.keyboard_since = now
		if now - d.keyboard_since > DIAG_DESYNC * 2 do diag_anomaly(app, .Keyboard_Desync, "the keyboard showed for %.2f s with no field holding the keys", now - d.keyboard_since)
	} else {
		d.keyboard_since = -1
	}
	if r != nil && d.state_known && text_input != d.state.text_input {
		if text_input do r.m.text_input_on += 1
		else do r.m.text_input_off += 1
	}
	hot := Diag_Probe.None
	if d.open do for h, p in d.hovered do if h && p != .None do hot = p
	s := Diag_State {
		pointer    = app.device.pointer,
		down       = .Left in app.device.down,
		cancel     = app.device.cancel,
		owner      = t.owner,
		fingers    = t.fingers.count,
		palm       = t.palm && t.fingers.count > 0,
		pen_near   = t.pen_near,
		pen_down   = t.pen_down,
		pointing   = t.pointing,
		gesture    = t.gesture,
		active     = ctx.active != 0,
		hot        = hot,
		text_focus = focus,
		text_input = text_input,
		keyboard   = keyboard,
		pie        = app.ui.pie.open,
	}
	if !d.state_known || s != d.state do diag_state_line(app, s, now)
	d.state, d.state_known = s, true
}

// Logs the pipeline's state, naming what changed since the last line.
@(private = "file")
diag_state_line :: proc(app: ^App, s: Diag_State, t: f64) {
	d := &app.diag
	p := d.state
	known := d.state_known
	b := diag_line(app, "state", t)
	strings.write_string(&b, `,"changed":[`)
	n := 0
	name :: proc(b: ^strings.Builder, n: ^int, changed: bool, key: string) {
		if !changed do return
		if n^ > 0 do strings.write_byte(b, ',')
		fmt.sbprintf(b, `"%s"`, key)
		n^ += 1
	}
	name(&b, &n, !known || s.pointer != p.pointer, "pointer")
	name(&b, &n, !known || s.down != p.down, "down")
	name(&b, &n, !known || s.cancel != p.cancel, "cancel")
	name(&b, &n, !known || s.owner != p.owner, "owner")
	name(&b, &n, !known || s.fingers != p.fingers, "fingers")
	name(&b, &n, !known || s.palm != p.palm, "palm")
	name(&b, &n, !known || s.pen_near != p.pen_near, "pen_near")
	name(&b, &n, !known || s.pen_down != p.pen_down, "pen_down")
	name(&b, &n, !known || s.pointing != p.pointing, "pointing")
	name(&b, &n, !known || s.gesture != p.gesture, "gesture")
	name(&b, &n, !known || s.active != p.active, "active")
	name(&b, &n, !known || s.hot != p.hot, "hot")
	name(&b, &n, !known || s.text_focus != p.text_focus, "text_focus")
	name(&b, &n, !known || s.text_input != p.text_input, "text_input")
	name(&b, &n, !known || s.keyboard != p.keyboard, "keyboard")
	name(&b, &n, !known || s.pie != p.pie, "pie")
	strings.write_string(&b, "]")
	jstr(&b, "pointer", DIAG_POINTER_NAMES[s.pointer])
	jbool(&b, "down", s.down)
	jbool(&b, "cancel", s.cancel)
	jstr(&b, "owner", DIAG_OWNER_NAMES[s.owner])
	jint(&b, "fingers", s.fingers)
	jbool(&b, "palm", s.palm)
	jbool(&b, "pen_near", s.pen_near)
	jbool(&b, "pen_down", s.pen_down)
	jbool(&b, "pointing", s.pointing)
	jbool(&b, "gesture", s.gesture)
	jbool(&b, "active", s.active)
	jstr(&b, "hot", DIAG_PROBE_NAMES[s.hot])
	jbool(&b, "text_focus", s.text_focus)
	jbool(&b, "text_input", s.text_input)
	if s.keyboard < 0 do strings.write_string(&b, `,"keyboard":null`)
	else do jbool(&b, "keyboard", s.keyboard == 1)
	jbool(&b, "pie", s.pie)
	jnum(&b, "pen_distance", f64(app.pen_distance))
	if roll, ok := app.pen_roll_last.?; ok do jnum(&b, "roll", f64(roll))
	else do strings.write_string(&b, `,"roll":null`)
	diag_keep(app, &b)
}

// ---- The report ----

// The summary: the session, the tests and their runs, and the anomalies.
diag_summary :: proc(app: ^App) -> string {
	d := &app.diag
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"schema":`)
	fmt.sbprintf(&b, "%d", DIAG_SCHEMA)
	strings.write_string(&b, `,"session":`)
	// The session line's fields, without its kind.
	session := strings.builder_make(context.temp_allocator)
	diag_session_fields(app, &session)
	strings.write_string(&session, "}")
	text, _ := strings.replace(strings.to_string(session), `"kind":"session",`, "", 1, context.temp_allocator)
	strings.write_string(&b, text)
	jstr(&b, "ended", diag_stamp(time.now(), true))
	jnum(&b, "duration_s", diag_now(app))
	jint(&b, "lines", d.lines)
	jint(&b, "dropped", d.dropped)
	jint(&b, "bytes", len(d.log))
	jbool(&b, "truncated", d.truncated)
	strings.write_string(&b, `,"counts":{`)
	for name, c in DIAG_COUNT_NAMES {
		if c != .Finger_Down do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `"%s":%d`, name, d.counts[c])
	}
	strings.write_string(&b, `},"tests":[`)
	for t, id in DIAG_TESTS {
		if id != .Finger_Tap do strings.write_byte(&b, ',')
		strings.write_string(&b, "{")
		fmt.sbprintf(&b, `"id":`)
		json_quote(&b, t.key)
		jstr(&b, "title", t.title)
		jstr(&b, "category", t.category)
		jstr(&b, "device", t.device)
		strings.write_string(&b, `,"needs":[`)
		for need, i in strings.split(t.needs, ",", context.temp_allocator) {
			if i > 0 do strings.write_byte(&b, ',')
			json_quote(&b, need)
		}
		strings.write_string(&b, `],"runs":[`)
		first := true
		for &r in d.runs {
			if r.test != id do continue
			if !first do strings.write_byte(&b, ',')
			first = false
			fmt.sbprintf(&b, `{{"run":%d`, r.run)
			jnum(&b, "start", r.start)
			jnum(&b, "end", r.end)
			// The test's fields (test, run, auto, ...) as its result line has them.
			diag_result_fields(&b, &r)
			strings.write_string(&b, `,"anomalies":{`)
			n := 0
			for count, code in r.anomalies do if count > 0 {
				if n > 0 do strings.write_byte(&b, ',')
				fmt.sbprintf(&b, `"%s":%d`, DIAG_ANOMALY_NAMES[code], count)
				n += 1
			}
			strings.write_string(&b, "}}")
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, `],"anomalies":[`)
	for &e, i in d.anomaly_list {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"t":%.3f`, e.t)
		count := d.loose[e.code]
		if e.run >= 0 {
			r := &d.runs[e.run]
			jstr(&b, "step", DIAG_TESTS[r.test].key)
			jint(&b, "run", r.run)
			count = r.anomalies[e.code]
		} else {
			strings.write_string(&b, `,"step":null,"run":0`)
		}
		jstr(&b, "code", DIAG_ANOMALY_NAMES[e.code])
		jstr(&b, "severity", DIAG_ANOMALY_SEVERITY[e.code])
		jstr(&b, "detail", diag_text(e.detail[:]))
		jint(&b, "count", count)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

// The report for people: what ran, what each run concluded and what it noticed.
diag_markdown :: proc(app: ^App) -> string {
	d := &app.diag
	b := strings.builder_make(context.temp_allocator)
	os_name, model, build := diag_device()
	fmt.sbprintf(&b, "# Input diagnostics report\n\nSession %s, started %s, %.0f s long.\n\n", diag_text(d.session[:]), diag_stamp(d.started_at, true), diag_now(app))
	fmt.sbprintf(&b, "- App: Sculpt %s%s, %s build\n", SCULPT_VERSION, fmt.tprintf(" (build %s)", build) if build != "" else "", "debug" when ODIN_DEBUG else "release")
	fmt.sbprintf(&b, "- Platform: %s, %s%s\n", sdl.GetPlatform(), os_name, fmt.tprintf(", %s", model) if model != "" else "")
	fmt.sbprintf(&b, "- Log: %d lines, %d KB%s\n\n", d.lines, len(d.log) >> 10, fmt.tprintf(", truncated (%d lines dropped)", d.dropped) if d.truncated else "")
	strings.write_string(&b, "Automatic verdicts come from the run's own events; your verdicts and notes are what you chose on the screen. scripts/input_report.py analyses diagnostic-events.jsonl further (README \"Input diagnostics\").\n\n")
	strings.write_string(&b, "| Test | Device | Run | Automatic | Why | Yours | Notes |\n|---|---|---|---|---|---|---|\n")
	for t, id in DIAG_TESTS {
		ran := false
		for &r in d.runs {
			if r.test != id do continue
			ran = true
			fmt.sbprintf(&b, "| %s | %s | %d | %s | %s | %s | %s |\n", t.title, t.device, r.run, DIAG_VERDICT_NAMES[r.auto], diag_md_cell(diag_text(r.reason[:])), DIAG_MANUAL_NAMES[r.manual] if r.manual != .None else "-", diag_md_cell(diag_text(r.notes[:])))
		}
		if !ran do fmt.sbprintf(&b, "| %s | %s | - | not run | | | |\n", t.title, t.device)
	}
	strings.write_string(&b, "\n## Anomalies\n\n")
	if len(d.anomaly_list) == 0 do strings.write_string(&b, "None noticed.\n")
	for &e in d.anomaly_list {
		where_ := "outside a test"
		if e.run >= 0 do where_ = fmt.tprintf("%s run %d", DIAG_TESTS[d.runs[e.run].test].key, d.runs[e.run].run)
		fmt.sbprintf(&b, "- %.2f s, %s, %s (%s): %s\n", e.t, where_, DIAG_ANOMALY_NAMES[e.code], DIAG_ANOMALY_SEVERITY[e.code], diag_text(e.detail[:]))
	}
	strings.write_string(&b, "\nAn anomaly is something the screen noticed as it happened; on its own it says what was seen, not why.\n")
	return strings.to_string(b)
}

// Text for a Markdown table cell: no bar or line break to break the row.
@(private = "file")
diag_md_cell :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "|", "/", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	return out
}

// The report's three files in one stored ZIP (zip.write, as a content pack is made).
diag_archive :: proc(app: ^App) -> (archive: []u8, ok: bool) {
	d := &app.diag
	files := [3]zip.File {
		{"diagnostic-report.md", transmute([]u8)diag_markdown(app)},
		{"diagnostic-events.jsonl", d.log[:]},
		{"diagnostic-summary.json", transmute([]u8)diag_summary(app)},
	}
	return zip.write(files[:], context.temp_allocator)
}

// The name the save dialog suggests for the report: the session's, so reports from several
// sessions never meet under one name.
diag_report_name :: proc(app: ^App) -> cstring {
	return strings.clone_to_cstring(fmt.tprintf("diagnostic-report-%s.zip", diag_text(app.diag.session[:])), context.temp_allocator)
}

// Writes the report to `path` (a file request's, or --diag-export's), ending the run under
// way so its result is in it. Returns whether it was written; the outcome is a toast.
diag_export :: proc(app: ^App, path: string) -> bool {
	d := &app.diag
	if !d.started {
		file_note(app, true, "There is no diagnostic session to export: open Input diagnostics first")
		return false
	}
	if d.run_open do diag_run_end(app, .End)
	archive, ok := diag_archive(app)
	if !ok {
		file_note(app, true, "The diagnostic report could not be packed")
		return false
	}
	if err := write_durably(path, archive); err != "" {
		file_note(app, true, "The diagnostic report was not saved: %s", err)
		return false
	}
	d.exports += 1
	file_note(app, false, "Saved the diagnostic report (%d KB) as %s", len(archive) >> 10, path)
	return true
}

// The exit stats' line: what the screen recorded and the last run's verdict.
diag_stats :: proc(app: ^App) {
	d := &app.diag
	if !d.started do return
	r: ^Diag_Run
	if len(d.runs) > 0 do r = &d.runs[len(d.runs) - 1]
	anomalies := strings.builder_make(context.temp_allocator)
	if r != nil do for count, code in r.anomalies do if count > 0 {
		if strings.builder_len(anomalies) > 0 do strings.write_byte(&anomalies, ',')
		strings.write_string(&anomalies, DIAG_ANOMALY_NAMES[code])
	}
	field, _ := strings.replace_all(diag_text(d.field[:]), " ", "_", context.temp_allocator)
	field, _ = strings.replace_all(field, "\t", "_", context.temp_allocator)
	fmt.printfln("diag_open=%d diag_runs=%d diag_lines=%d diag_bytes=%d diag_dropped=%d diag_exports=%d diag_test=%s diag_auto=%s diag_palms=%d diag_presses=%d diag_finger_downs=%d diag_pen_downs=%d diag_slider=%.2f diag_vslider=%.2f diag_field=%s diag_anomalies=%s",
		int(d.open), len(d.runs), d.lines, len(d.log), d.dropped, d.exports,
		DIAG_TESTS[r.test].key if r != nil else "none", DIAG_VERDICT_NAMES[r.auto] if r != nil else "none",
		r.palms if r != nil else 0, r.responded[.Press] if r != nil else 0, r.received[.Finger_Down] if r != nil else 0, r.received[.Pen_Down] if r != nil else 0,
		d.slider, d.vslider, field if field != "" else "none", strings.to_string(anomalies) if strings.builder_len(anomalies) > 0 else "none")
}
