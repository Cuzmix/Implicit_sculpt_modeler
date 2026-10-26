package main

import "core:math/linalg"

import "../ui"

// The modifier wheel: Smooth (top), Mask (left) and Invert (bottom) as the sectors of a
// ring at the bottom left, for a tablet with no Shift, Ctrl or Alt, and the brush pie on
// its right sector, as a sculpting tablet app's wheel. Smooth and Mask on together are
// Hide, the hide gesture, as Shift and Ctrl held together are. A tap latches a sector
// until it is tapped again; a finger held on one makes it act only while held, so the pen
// (or another finger) sculpts with it and lifting the finger ends it. A finger on a
// modifier sector belongs to the wheel, not to the touch (touch_event): it never becomes
// the pointer, never counts toward a gesture, and the pen landing does not cancel it. The
// mouse and the pen press the sectors as ordinary buttons, which latch. The grip in the
// middle drags the wheel elsewhere; Settings > Interface sets its side and size. The code
// still calls it the rail, the four buttons it was before.

Modifier :: enum u8 {
	Smooth,
	Invert,
	Mask,
	Hide,
}
Modifiers :: bit_set[Modifier;u8]

// Smooth, Mask and Hide are what a press does, one at a time (Smooth and Mask together
// being Hide); Invert turns any of them (or the brush) the other way.
RAIL_MODES :: Modifiers{.Smooth, .Mask, .Hide}

// A press of a rail button shorter than this that sculpted nothing is a tap, which
// latches; longer, or with a stroke made meanwhile, it only acted while held.
RAIL_TAP :: 0.25 // seconds

// Where the wheel sits (Settings > Interface): off, at the bottom left under the brush
// bar, or at the bottom right, for the other hand.
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
	// Where last frame drew the wheel, in window coordinates: its middle and the ring's
	// outer and inner sizes across, for touch_event to claim the fingers that land on its
	// modifier sectors; zero while the wheel is hidden.
	center:  [2]f32,
	outer:   f32,
	hole:    f32,
	// The wheel's container, so a finger is claimed only where nothing covers it.
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

// Latches `which` or lets it go. Smooth and Mask latch together, as Hide; Hide latched
// lets them go, and either of them lets Hide go.
rail_toggle :: proc(r: ^Modifier_Rail, which: Modifier) {
	if which in r.latched {
		r.latched -= {which}
		return
	}
	switch which {
	case .Smooth, .Mask: r.latched -= {.Hide}
	case .Hide:          r.latched -= {.Smooth, .Mask}
	case .Invert:
	}
	r.latched += {which}
}

// The wheel's sectors, clockwise from the top: the modifier each is, or none for the
// right one, the brush pie.
@(rodata)
WHEEL_SECTORS := [4]Maybe(Modifier){.Smooth, nil, .Invert, .Mask}

// Which modifier sector `p` (window coordinates) is on, if any: not the pie's, the grip
// or the corners round the ring.
rail_hit :: proc(r: ^Modifier_Rail, p: [2]f32) -> (which: Modifier, ok: bool) {
	if r.outer <= 0 do return {}, false
	i := ui.wheel_sector_at(r.center, p, r.outer, r.hole)
	if i < 0 do return {}, false
	return WHEEL_SECTORS[i].?
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

// What a press going down now takes from the rail. A held sector beats a latched one,
// and among held ones the last to come down wins, but for Smooth and Mask held together,
// which are Hide; Invert, held or latched, goes with whichever mode that leaves.
rail_press_mods :: proc(r: ^Modifier_Rail) -> (mods: Modifiers, held: bool) {
	mods = r.latched & {.Invert}
	mode, has := rail_mode(r.latched).?
	holding: Modifiers
	for f in r.fingers[:r.count] {
		if f.which == .Invert {
			mods += {.Invert}
			continue
		}
		mode, has, held = f.which, true, true
		holding += {f.which}
	}
	if (Modifiers{.Smooth, .Mask} <= holding) do mode = .Hide
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

// The one mode `mods` presses with, Hide (or Smooth and Mask together) before Mask before
// Smooth, or nil.
rail_mode :: proc(mods: Modifiers) -> Maybe(Modifier) {
	switch {
	case .Hide in mods || Modifiers{.Smooth, .Mask} <= mods: return .Hide
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

// The wheel's sizes (Settings > Interface): across its ring and across the grip in its
// middle, in points.
Wheel_Size :: enum u8 {
	Small,
	Medium,
	Large,
}

@(rodata)
WHEEL_OUTER := [Wheel_Size]f32 {
	.Small  = 112,
	.Medium = 132,
	.Large  = 156,
}

@(rodata)
WHEEL_HOLE := [Wheel_Size]f32 {
	.Small  = 40,
	.Medium = 44,
	.Large  = 52,
}

// The wheel's size in points, a square round its ring.
rail_size :: proc(app: ^App) -> [2]f32 {
	d := WHEEL_OUTER[app.kit.wheel_size]
	return {d, d}
}

// How far above the bottom of the safe area the wheel sits by default, in points, from
// last frame's layout: the edge's margin, or above the bottom bar where it would meet it
// (a narrow or portrait window).
rail_lift :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	size := rail_size(app)
	dock, _ := ui.prev_layout(ctx, "dock")
	lift := t.edge
	if area.w * 0.5 - dock.x * 0.5 - 8 < rail_inset(app, lift) + size.x do lift = max(lift, t.edge + DOCK_LIFT + dock.y + 8)
	return lift
}

// How far in from its side the wheel sits by default when `lift` above the bottom: the
// edge's margin, or on the left beside the brush bar rather than under it where a short
// window (or a large interface) brings the bar down to it.
rail_inset :: proc(app: ^App, lift: f32) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if k.rail_side != .Left do return t.edge
	area := ui.safe_area(ctx)
	bar, _ := ui.prev_layout(ctx, "brush bar")
	if (area.h + bar.y) * 0.5 + 8 > area.h - lift - rail_size(app).y do return kit_left(app)
	return t.edge
}

// How far up from the bottom of the safe area the wheel reaches, in points, on `side`;
// zero when it is elsewhere or was dragged away from its place, for what must stay clear
// of it.
rail_reach :: proc(app: ^App, side: Rail_Side) -> f32 {
	if app.kit.rail_side != side || side == .Off || app.kit.wheel_offset != {} do return 0
	return rail_lift(app) + rail_size(app).y
}

// How wide the wheel stands from its side where it sits in its place, in points, for the
// bottom bar to keep clear of; zero when it is off or was dragged elsewhere.
rail_reach_across :: proc(app: ^App) -> f32 {
	k := &app.kit
	if k.rail_side == .Off || k.wheel_offset != {} do return 0
	return rail_inset(app, rail_lift(app)) + rail_size(app).x
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

// The wheel at the bottom left or right, or where its grip was dragged to (kept inside
// the window). A click (the mouse's, the pen's) on a modifier sector toggles its latch;
// fingers never reach those, the wheel takes them first (rail_claims). The right sector
// opens the brush pie. Hidden, it lets go of every latch and finger, so nothing it held
// acts unseen.
kit_modifier_rail :: proc(app: ^App) {
	r := &app.rail
	k := &app.kit
	r.center, r.outer, r.hole, r.root = {}, 0, 0, 0
	if k.rail_side == .Off {
		r.latched = {}
		rail_forget(r)
		return
	}
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	size := rail_size(app)
	held := rail_mods(r)
	keys := keyboard_mods(app.device.shift, app.device.ctrl)
	// Hide, latched, held or from the keys, lights both of the sectors it is made of.
	lit_of :: proc(m: Modifier, set: Modifiers) -> bool {
		return m in set || (m == .Smooth || m == .Mask) && .Hide in set
	}
	sectors: [4]ui.Wheel_Sector
	for which, i in WHEEL_SECTORS {
		m, is_mod := which.?
		if !is_mod {
			sectors[i] = {name = "Brush pie", glyph = ui.ICON_PIE, keys = command_hint(app, .Brush_Pie)}
			continue
		}
		look := ui.Modifier_Look.Latched if lit_of(m, r.latched) else (.Lit if lit_of(m, held) || lit_of(m, keys) else .Off)
		sectors[i] = {name = MODIFIER_NAMES[m], glyph = MODIFIER_ICONS[m], look = look, keys = MODIFIER_KEYS[m]}
	}
	x := ui.Anchor.Start if k.rail_side == .Left else .End
	side: f32 = 1 if x == .Start else -1
	base_lift := rail_lift(app)
	base_inset := rail_inset(app, base_lift)
	// Dragged: as far from its place as the grip went, kept inside the window.
	inset := clamp(base_inset + side * k.wheel_offset.x, 0, max(area.w - size.x, 0))
	lift := clamp(base_lift - k.wheel_offset.y, 0, max(area.h - size.y, 0))
	r.root = ui.id_of(ctx, "modifier rail")
	ui.begin_anchored(ctx, "modifier rail", x, .End, {inset, lift}, {direction = .Column})
	res := ui.wheel(ctx, "modifier wheel", size.x, WHEEL_HOLE[k.wheel_size], sectors)
	b := ctx.last_rect
	ui.end(ctx)
	r.center = [2]f32{b.x + b.w * 0.5, b.y + b.h * 0.5} * k.scale
	r.outer, r.hole = b.w * k.scale, WHEEL_HOLE[k.wheel_size] * k.scale
	if res.clicked >= 0 {
		if m, is_mod := WHEEL_SECTORS[res.clicked].?; is_mod do rail_toggle(r, m)
		else do command_run(app, .Brush_Pie)
	}
	if res.grabbed do k.wheel_from = k.wheel_offset
	if res.dragging {
		to := k.wheel_from + res.drag
		// No further than the window lets it go, so a drag back moves it at once.
		k.wheel_offset = {
			side * (clamp(base_inset + side * to.x, 0, max(area.w - size.x, 0)) - base_inset),
			base_lift - clamp(base_lift - to.y, 0, max(area.h - size.y, 0)),
		}
	}
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
