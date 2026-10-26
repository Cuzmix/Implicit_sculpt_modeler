package main

import "core:math/linalg"

import "../ui"

// The modifier rail: Smooth, Invert, Mask and Hide as buttons at the bottom left, for
// a tablet with no Shift, Ctrl or Alt. A tap latches one until it is tapped again; a
// finger held on one makes it act only while held, so the pen (or another finger)
// sculpts with it and lifting the finger ends it, as Nomad's and 3DCoat's sticky keys.
// A finger on a rail button belongs to the rail, not to the touch (touch_event): it
// never becomes the pointer, never counts toward a gesture, and the pen landing does not
// cancel it. The mouse and the pen press the buttons as ordinary ones, which latch.

Modifier :: enum u8 {
	Smooth,
	Invert,
	Mask,
	Hide,
}
Modifiers :: bit_set[Modifier;u8]

// Smooth, Mask and Hide are what a press does, one at a time; Invert turns any of them
// (or the brush) the other way.
RAIL_MODES :: Modifiers{.Smooth, .Mask, .Hide}

// A press of a rail button shorter than this that sculpted nothing is a tap, which
// latches; longer, or with a stroke made meanwhile, it only acted while held.
RAIL_TAP :: 0.25 // seconds

// Where the rail sits (Settings > Interface): off, at the bottom left under the sliders,
// or at the bottom right over the object's status, for the other hand.
Rail_Side :: enum u8 {
	Off,
	Left,
	Right,
}

Modifier_Rail :: struct {
	latched: Modifiers,
	// Fingers held on rail buttons, in the order they came down.
	fingers: [4]Rail_Finger,
	count:   int,
	// Where last frame drew each button, in window coordinates, for touch_event to claim
	// the fingers that land on them; empty while the rail is hidden.
	rects:   [Modifier]ui.Rect,
	// The rail's container, so a finger is claimed only where nothing covers it.
	root:    ui.Id,
	// What the rail said when the press under way went down, kept to its release, so a
	// finger lifted mid-stroke never changes the brush the stroke uses; Smooth put down
	// mid-stroke makes the stroke a straight line instead (rail_press).
	press:   Rail_Press,
}

Rail_Finger :: struct {
	id:     u64,
	which:  Modifier,
	at:     f64, // when it came down, seconds
	start:  [2]f32, // where, window coordinates
	travel: f32, // the furthest it strayed from there
	used:   bool, // a press on the viewport went down while it was held
}

Rail_Press :: struct {
	active: bool,
	mods:   Modifiers,
	held:   bool, // its mode came from a finger held, not a latch
	line:   bool, // Smooth came down after it, for a straight line
}
@(rodata)
MODIFIER_NAMES := [Modifier]string {
	.Smooth = "Smooth",
	.Invert = "Invert",
	.Mask   = "Mask",
	.Hide   = "Hide",
}

@(rodata)
MODIFIER_ICONS := [Modifier]rune {
	.Smooth = 0xe283, // waves
	.Invert = 0xe30c, // diff: plus over minus
	.Mask   = 0xe0a1, // contrast
	.Hide   = 0xe0bf, // eye-off
}

// The keyboard's modifier that does the same, for the tooltip.
@(rodata)
MODIFIER_KEYS := [Modifier]string {
	.Smooth = "Shift",
	.Invert = "Ctrl",
	.Mask   = "Ctrl from empty space",
	.Hide   = "Ctrl+Shift",
}

// Latches `which` or lets it go. A mode latched lets the other modes go.
rail_toggle :: proc(r: ^Modifier_Rail, which: Modifier) {
	if which in r.latched {
		r.latched -= {which}
		return
	}
	if which in RAIL_MODES do r.latched -= RAIL_MODES
	r.latched += {which}
}

// Which button `p` (window coordinates) is on, if any.
rail_hit :: proc(r: ^Modifier_Rail, p: [2]f32) -> (which: Modifier, ok: bool) {
	for rect, m in r.rects {
		if rect.w > 0 && ui.rect_contains(rect, p) do return m, true
	}
	return {}, false
}

// A finger came down at `p` on button `which`. A finger of the same id still held is one
// whose lift never came, and is dropped first. False when the rail holds as many as it
// can: that finger is dropped too, since handing it to the touch would sculpt with it.
rail_finger_down :: proc(r: ^Modifier_Rail, id: u64, which: Modifier, p: [2]f32, now: f64) -> bool {
	if i := rail_index(r, id); i >= 0 do rail_remove(r, i)
	if r.count == len(r.fingers) do return false
	r.fingers[r.count] = {id = id, which = which, at = now, start = p}
	r.count += 1
	return true
}

// The finger `id` moved to `p`. Returns whether it was the rail's.
rail_finger_move :: proc(r: ^Modifier_Rail, id: u64, p: [2]f32) -> bool {
	i := rail_index(r, id)
	if i < 0 do return false
	f := &r.fingers[i]
	f.travel = max(f.travel, linalg.length(p - f.start))
	return true
}

// The finger `id` lifted (or was cancelled). Returns whether it was the rail's. A tap
// toggles its button's latch: quick, no further than `slop`, with no press on the
// viewport made meanwhile, and not cancelled.
rail_finger_up :: proc(r: ^Modifier_Rail, id: u64, now: f64, cancelled: bool, slop: f32) -> bool {
	i := rail_index(r, id)
	if i < 0 do return false
	f := r.fingers[i]
	rail_remove(r, i)
	if !cancelled && !f.used && now - f.at < RAIL_TAP && f.travel <= slop do rail_toggle(r, f.which)
	return true
}

@(private = "file")
rail_index :: proc(r: ^Modifier_Rail, id: u64) -> int {
	for f, i in r.fingers[:r.count] do if f.id == id do return i
	return -1
}

// Takes out finger `i`, keeping the others in the order they came down.
@(private = "file")
rail_remove :: proc(r: ^Modifier_Rail, i: int) {
	copy(r.fingers[i:r.count - 1], r.fingers[i + 1:r.count])
	r.count -= 1
}

// Forgets every finger, as when the app loses focus and their lifts never come.
rail_forget :: proc(r: ^Modifier_Rail) {
	r.count = 0
	r.press = {}
}

// What is on, to light the buttons: latched, or held by a finger.
rail_mods :: proc(r: ^Modifier_Rail) -> Modifiers {
	on := r.latched
	for f in r.fingers[:r.count] do on += {f.which}
	return on
}

// What a press going down now takes from the rail. A held button beats a latched one,
// and among held ones the last to come down wins; Invert, held or latched, goes with
// whichever mode that leaves.
rail_press_mods :: proc(r: ^Modifier_Rail) -> (mods: Modifiers, held: bool) {
	mods = r.latched & {.Invert}
	mode, has := rail_mode(r.latched).?
	for f in r.fingers[:r.count] {
		if f.which == .Invert do mods += {.Invert}
		else do mode, has, held = f.which, true, true
	}
	if has do mods += {mode}
	return
}

// Follows the left button on the viewport (kit_viewport_input, while the viewport has the
// pointer): as it goes down, takes what the rail says, unless a key of the keyboard's own
// is held, which then says it all; the fingers held then made this press, so lifting
// them never latches. Until it comes up the press keeps what it took, which this frame's
// input gets, but for Smooth held down after it: that, as Shift pressed mid-stroke, turns
// the stroke into a straight line (Stroke.line), and is used, so lifting it never latches.
rail_press :: proc(app: ^App, input: ^Viewport_Input) {
	r := &app.rail
	d := &app.device
	if .Left in d.pressed {
		r.press = {active = true}
		if !d.shift && !d.ctrl && !d.alt do r.press.mods, r.press.held = rail_press_mods(r)
		for &f in r.fingers[:r.count] do f.used = true
	} else if .Left not_in d.down {
		r.press = {}
	}
	if !r.press.active do return
	rail_resolve(r.press.mods, input)
	// Only a brush stroke under way makes a line of it; any other drag leaves the button
	// to latch as before.
	if app.tool != .Brush || !app.stroke.active do return
	for &f in r.fingers[:r.count] {
		if f.which != .Smooth || !input.primary do continue
		if !f.used do f.used, r.press.line = true, true
		if r.press.line do input.smooth = true
	}
}

// The keyboard's modifiers as the rail's, to light its buttons: Shift smooths, Ctrl
// inverts, both run the hide gesture.
keyboard_mods :: proc(shift, ctrl: bool) -> Modifiers {
	switch {
	case shift && ctrl: return {.Hide}
	case shift:         return {.Smooth}
	case ctrl:          return {.Invert}
	}
	return {}
}

// The one mode `mods` presses with, Hide before Mask before Smooth, or nil.
rail_mode :: proc(mods: Modifiers) -> Maybe(Modifier) {
	switch {
	case .Hide in mods:   return .Hide
	case .Mask in mods:   return .Mask
	case .Smooth in mods: return .Smooth
	}
	return nil
}

// Turns the rail's modifiers into what the keyboard's would set on a primary drag: Smooth
// smooths; Invert inverts the brush; Mask paints the mask on the model and draws a mask
// shape from empty space (Invert: erases, unmasks); Hide runs the gesture tool (Invert:
// flipped), so a tap on a polygroup isolates it (Invert: masks it) and a tap off one
// shows everything, as Ctrl+Shift's click does.
rail_resolve :: proc(mods: Modifiers, input: ^Viewport_Input) {
	if !input.primary do return
	invert := .Invert in mods
	mode, has := rail_mode(mods).?
	switch {
	case has && mode == .Hide:
		input.smooth, input.invert = true, true
		input.alt ||= invert
	case has && mode == .Mask:
		input.mask, input.mask_shape = true, true
		input.invert ||= invert
		input.alt ||= invert
	case has && mode == .Smooth:
		input.smooth = true
		input.invert ||= invert
	case:
		input.invert ||= invert
	}
}

// Whether a press from empty space or the safe zone stays with the tool, for the shapes
// that start there, as with Ctrl.
rail_keeps_empty_space :: proc(mods: Modifiers) -> bool {
	m, ok := rail_mode(mods).?
	return ok && (m == .Mask || m == .Hide)
}

// The rail's size in points: two rows of two modifier buttons inside its padding.
rail_size :: proc(t: ui.Theme) -> [2]f32 {
	return {2 * t.target + 2 * RAIL_PADDING, 2 * (t.target + 4) + 2 * RAIL_PADDING}
}

RAIL_PADDING :: 2

// How far above the bottom of the safe area the rail sits, in points, from last frame's
// layout: the edge's margin, or higher where it would meet the brush dock (a narrow or
// portrait window) and, on the right, above the object's status.
rail_lift :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	size := rail_size(t)
	dock, _ := ui.prev_layout(ctx, "dock")
	lift := t.edge
	if area.w * 0.5 - dock.x * 0.5 - 8 < rail_inset(app, lift) + size.x do lift = max(lift, t.edge + DOCK_LIFT + dock.y + 8)
	return lift
}

// How far in from its side the rail sits when `lift` above the bottom: the edge's margin,
// or on the left beside the brush bar rather than under it where a short window (or a
// large interface) brings the bar down to it.
rail_inset :: proc(app: ^App, lift: f32) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if k.rail_side != .Left do return t.edge
	area := ui.safe_area(ctx)
	bar, _ := ui.prev_layout(ctx, "brush bar")
	if (area.h + bar.y) * 0.5 + 8 > area.h - lift - rail_size(t).y do return kit_left(app)
	return t.edge
}

// How far up from the bottom of the safe area the rail reaches, in points, on `side`;
// zero when it is elsewhere, for what must stay clear of it.
rail_reach :: proc(app: ^App, side: Rail_Side) -> f32 {
	if app.kit.rail_side != side || side == .Off do return 0
	return rail_lift(app) + rail_size(app.kit.ctx.theme).y
}

// The size and strength sliders' track, in points: the usual 260, shorter where the
// window under the top bar has no room for it (a short window, or a large interface
// size). Their popover stands the track and 80 points tall.
slider_track :: proc(app: ^App) -> f32 {
	TRACK :: 260
	MIN_TRACK :: 100
	area := ui.safe_area(&app.kit.ctx)
	return clamp(area.h - kit_top() - 80 - 16, MIN_TRACK, TRACK)
}

// The rail's buttons, a 2 by 2 grid at the bottom left or right. A click (the mouse's,
// the pen's) toggles a latch; fingers never reach these buttons, the rail takes them
// first. Hidden, it lets go of every latch and finger, so nothing it held acts unseen.
kit_modifier_rail :: proc(app: ^App) {
	r := &app.rail
	k := &app.kit
	r.rects, r.root = {}, 0
	if k.rail_side == .Off {
		r.latched = {}
		rail_forget(r)
		return
	}
	ctx := &k.ctx
	t := ctx.theme
	held := rail_mods(r)
	keys := keyboard_mods(app.device.shift, app.device.ctrl)
	x := ui.Anchor.Start if k.rail_side == .Left else .End
	r.root = ui.id_of(ctx, "modifier rail")
	lift := rail_lift(app)
	ui.begin_anchored(ctx, "modifier rail", x, .End, {rail_inset(app, lift), lift}, {direction = .Column, gap = 0, padding = RAIL_PADDING, radius = t.radius_large, background = .Panel})
	for row in 0 ..< 2 {
		ui.begin(ctx, "rail top" if row == 0 else "rail bottom", {direction = .Row, gap = 0})
		for col in 0 ..< 2 {
			m := Modifier(row * 2 + col)
			look := ui.Modifier_Look.Latched if m in r.latched else (.Lit if m in held || m in keys else .Off)
			if ui.modifier_button(ctx, MODIFIER_NAMES[m], MODIFIER_ICONS[m], look, MODIFIER_KEYS[m]) do rail_toggle(r, m)
			b := ctx.last_rect
			r.rects[m] = {b.x * k.scale, b.y * k.scale, b.w * k.scale, b.h * k.scale}
		}
		ui.end(ctx)
	}
	ui.end(ctx)
}

// Whether a finger landing at `p` (window coordinates) is the rail's, and on which
// button: only where the rail is on top, with nothing open that a press elsewhere would
// close (a menu, a popover, a list), since that press is the panels' to take.
rail_claims :: proc(app: ^App, p: [2]f32) -> (which: Modifier, ok: bool) {
	k := &app.kit
	r := &app.rail
	if k.rail_side == .Off || r.root == 0 do return
	if k.menu || k.versions || k.view_menu || k.browser || k.object_menu || k.ctx.select_open != 0 || k.ctx.popup_open != 0 do return
	which = rail_hit(r, p) or_return
	return which, ui.root_at(&k.ctx, p / k.scale) == r.root
}

// The brush ring's colour (straight RGBA): white, amber while pressing; blue to smooth,
// red to invert, violet to mask, as the keyboard's keys held say, or else as the rail
// would press (or the press under way took).
brush_ring_color :: proc(app: ^App, pressing: bool) -> [4]f32 {
	r := &app.rail
	d := &app.device
	mods := keyboard_mods(d.shift, d.ctrl)
	if mods == {} && !d.alt {
		mods, _ = rail_press_mods(r)
		// A press's own, while it lasts: what it took when it went down.
		if r.press.active && .Left in d.down do mods = r.press.mods
	}
	a: f32 = 0.95 if pressing else 0.8
	mode, has := rail_mode(mods).?
	switch {
	case has && mode == .Mask:    return {0.72, 0.55, 1, a}
	case has && mode == .Smooth:  return {0.45, 0.7, 1, a}
	case !has && .Invert in mods: return {1, 0.45, 0.4, a}
	}
	return {1, 0.8, 0.4, 0.9} if pressing else {1, 1, 1, 0.6}
}
