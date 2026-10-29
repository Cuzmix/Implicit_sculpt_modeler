package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:reflect"

import "../ui"

// The modifier wheel (Lens's dial): Smooth (top), Mask (left) and Invert (bottom) as the
// sectors of a ring at the bottom left, for a tablet with no Shift, Ctrl or Alt, and the
// brush pie on its right sector, as a sculpting tablet app's wheel; each sector can be
// any modifier or a command instead (Kit_State.dial), and a command's sector is tapped as
// the pie's is. Smooth and Mask on together are
// Hide, the hide gesture, as Shift and Ctrl held together are. A tap latches a sector
// until it is tapped again; a finger held on one makes it act only while held, so the pen
// (or another finger) sculpts with it and lifting the finger ends it. A finger on a
// modifier sector belongs to the wheel, not to the touch (touch_event): it never becomes
// the pointer, never counts toward a gesture, and the pen landing does not cancel it. The
// mouse and the pen press the sectors as ordinary buttons, which latch. The grip in the
// middle drags the wheel elsewhere; Settings > Interface sets its side, size, turn and
// what its sectors show. Two fingers on the ring that spread, pinch or twist resize and
// turn it instead of holding their sectors (rail_finger_move). The code still calls it
// the rail, the four buttons it was before.

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
	// ...and how far it is turned, in radians, clockwise.
	turn:    f32,
	// The wheel's container, so a finger is claimed only where nothing covers it.
	root:    ui.Id,
	// Two fingers on the ring are resizing and turning it rather than holding sectors,
	// from when they first spread, pinched or twisted until every finger on it lifts:
	// `pair` are their ids and `from` the line from the first to the second as they came
	// down, so the wheel follows the whole spread and twist, the part before it began too;
	// `began` asks the wheel to note its size and turn then (kit_modifier_rail).
	gesture: bool,
	began:   bool,
	pair:    [2]u64,
	from:    [2]f32,
	// What the rail said when the press under way went down, kept to its release, so a
	// finger lifted mid-stroke never changes the brush the stroke uses; Smooth put down
	// mid-stroke makes the stroke a straight line instead (rail_press).
	press:   Rail_Press,
}

Rail_Finger :: struct {
	id:     u64,
	which:  Modifier,
	// On the wheel but on no modifier (the brush pie's sector or the grip), claimed only
	// because another finger was already on it, for the two to resize and turn it.
	plain:  bool,
	pos:    [2]f32, // where it is now, window coordinates
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

// A modifier's name as the dial shows it: while painting, Smooth blurs the paint and
// Invert erases it (painting), and the dial says so.
modifier_name :: proc(app: ^App, m: Modifier) -> string {
	// The Model tool reads Smooth as Snap and Invert as Alt (model_tool.odin), whatever
	// brush is kept for Sculpt.
	if app.tool == .Model {
		#partial switch m {
		case .Smooth: return "Snap"
		case .Invert: return "Alt"
		}
		return MODIFIER_NAMES[m]
	}
	if painting(app) {
		#partial switch m {
		case .Smooth: return "Blur"
		case .Invert: return "Erase"
		}
	}
	return MODIFIER_NAMES[m]
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

// What a sector of the wheel (the dial) does: hold or latch a modifier, or run a command
// on a tap, as the brush pie's sector runs Brush_Pie. Which sector does what is a setting
// (Library > Dial while arranging), not part of a workspace, since it belongs to the hand
// rather than the screen. Each space has its own four (PR 3b), as each asks something
// else of the off hand: Model snaps and selects, Render places light and focus.
Dial_Sector :: union {
	Modifier,
	Bar_Slot,
}

// Each space's sectors as they come, clockwise from the top: Sculpt's Smooth, the brush
// pie, Invert and Mask; Model's Snap and Alt (Smooth and Invert, as the Model tool reads
// them), the pie and the Select action; Render's Place highlight, the pie, Exposure and
// Pick focus.
@(rodata)
DIAL_DEFAULTS := [Space][4]Dial_Sector {
	.Sculpt = {Modifier.Smooth, Bar_Slot{.Brush_Pie, 0}, Modifier.Invert, Modifier.Mask},
	.Model  = {Modifier.Smooth, Bar_Slot{.Brush_Pie, 0}, Modifier.Invert, Bar_Slot{.Model_Action, int(Model_Action.Select)}},
	.Render = {Bar_Slot{.Place_Light, 0}, Bar_Slot{.Brush_Pie, 0}, Bar_Slot{.Brush_Value, int(Brush_Value.Exposure)}, Bar_Slot{.Pick_Focus, 0}},
}

// The sectors' places, clockwise from the top, as Library > Dial names them.
@(rodata)
DIAL_PLACES := [4]string{"Top", "Right", "Bottom", "Left"}

// Which modifier sector of `sectors` `p` (window coordinates) is on, if any: not a
// command's (the brush pie's among them), the grip or the corners round the ring.
rail_hit :: proc(r: ^Modifier_Rail, sectors: [4]Dial_Sector, p: [2]f32) -> (which: Modifier, ok: bool) {
	if r.outer <= 0 do return {}, false
	i := ui.wheel_sector_at(r.center, p, r.outer, r.hole, r.turn)
	if i < 0 do return {}, false
	return sectors[i].(Modifier)
}

// The current space's sectors.
dial_of :: proc(k: ^Kit_State) -> ^[4]Dial_Sector {
	return &k.dials[k.spaces.current]
}

// Whether space `s`'s dial is as it comes.
dial_is_default :: proc(k: ^Kit_State, s: Space) -> bool {
	for sector, i in k.dials[s] do if sector != DIAL_DEFAULTS[s][i] do return false
	return true
}

// Whether some sector of the current space's dial is `m`.
dial_has :: proc(k: ^Kit_State, m: Modifier) -> bool {
	for s in dial_of(k) do if mod, ok := s.(Modifier); ok && mod == m do return true
	return false
}

// Drops the latches the current space's dial holds no sector for, after a space switch:
// a latch left from another space would act with nothing lit (Hide latched in Sculpt is
// Snap and Alt to the Model tool). Hide stays while both its sectors are there.
dial_latches_keep :: proc(app: ^App) {
	r := &app.rail
	for m in r.latched {
		kept := dial_has(&app.kit, .Smooth) && dial_has(&app.kit, .Mask) if m == .Hide else dial_has(&app.kit, m)
		if !kept do r.latched -= {m}
	}
}

// Moves a dial read from a settings file before version 6, when there was one dial for
// every space, onto each space's: the sectors that differ from Sculpt's defaults reach
// Model too, and Render (where a modifier does nothing, as a press there turns the view)
// the commands among them.
dials_from_one :: proc(k: ^Kit_State) {
	for sector, i in k.dials[.Sculpt] {
		if sector == DIAL_DEFAULTS[.Sculpt][i] do continue
		k.dials[.Model][i] = sector
		if _, is_command := sector.(Bar_Slot); is_command do k.dials[.Render][i] = sector
	}
}

// A sector as the settings file writes it: "modifier Smooth", or "command <name>".
dial_sector_text :: proc(s: Dial_Sector) -> string {
	switch v in s {
	case Modifier: return fmt.tprintf("modifier %v", v)
	case Bar_Slot: return fmt.tprintf("command %s", command_name(v.id, v.arg))
	}
	return ""
}

// Reads what dial_sector_text writes, split into its kind and name; false for a name this
// version does not know, or a command a bar may not hold.
dial_sector_parse :: proc(kind, name: string) -> (s: Dial_Sector, ok: bool) {
	switch kind {
	case "modifier":
		m := reflect.enum_from_name(Modifier, name) or_return
		return m, true
	case "command":
		id, arg := command_from_name(name) or_return
		if !bar_lists(id) do return
		return Bar_Slot{id, arg}, true
	}
	return
}

// A finger came down at `p` on button `which`. A finger of the same id still held is one
// whose lift never came, and is dropped first. False when the rail holds as many as it
// can: that finger is dropped too, since handing it to the touch would sculpt with it.
rail_finger_down :: proc(r: ^Modifier_Rail, id: u64, which: Modifier, p: [2]f32, now: f64, plain := false) -> bool {
	if i := rail_index(r, id); i >= 0 do rail_remove(r, i)
	if r.count == len(r.fingers) do return false
	r.fingers[r.count] = {id = id, which = which, plain = plain, at = now, start = p, pos = p}
	r.count += 1
	return true
}

// The finger `id` moved to `p`. Returns whether it was the rail's. The first two fingers
// on the wheel, while neither has made a press on the viewport, become a gesture that
// resizes and turns it once the line between them grows or shrinks by twice `slop` or
// turns by WHEEL_TWIST_START: from then on they hold no sector.
rail_finger_move :: proc(r: ^Modifier_Rail, id: u64, p: [2]f32, slop: f32) -> bool {
	i := rail_index(r, id)
	if i < 0 do return false
	f := &r.fingers[i]
	f.travel = max(f.travel, linalg.length(p - f.start))
	f.pos = p
	if r.gesture || r.count < 2 do return true
	a, b := r.fingers[0], r.fingers[1]
	if a.used || b.used do return true
	was, now := b.start - a.start, b.pos - a.pos
	if abs(linalg.length(now) - linalg.length(was)) > 2 * slop || abs(angle_between(was, now)) > WHEEL_TWIST_START {
		r.gesture, r.began = true, true
		r.pair, r.from = {a.id, b.id}, was
	}
	return true
}

// How far the line between two fingers turns before it turns the wheel, in radians.
WHEEL_TWIST_START :: 0.26 // 15 degrees

// The angle from `a` to `b`, in radians, clockwise on screen, between -pi and pi.
angle_between :: proc(a, b: [2]f32) -> f32 {
	return math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
}

// The finger `id` lifted (or was cancelled). Returns whether it was the rail's. A tap
// toggles its button's latch: quick, no further than `slop`, with no press on the
// viewport made meanwhile, and not cancelled.
rail_finger_up :: proc(r: ^Modifier_Rail, id: u64, now: f64, cancelled: bool, slop: f32) -> bool {
	i := rail_index(r, id)
	if i < 0 do return false
	f := r.fingers[i]
	gesture := r.gesture
	rail_remove(r, i)
	if !cancelled && !f.used && !f.plain && !gesture && now - f.at < RAIL_TAP && f.travel <= slop do rail_toggle(r, f.which)
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
	if r.count == 0 do r.gesture, r.began = false, false
}

// Forgets every finger, as when the app loses focus and their lifts never come.
rail_forget :: proc(r: ^Modifier_Rail) {
	r.count = 0
	r.press = {}
	r.gesture, r.began = false, false
}

// Whether finger `f` holds its sector: not one on no modifier, and none while the
// fingers resize or turn the wheel.
@(private = "file")
rail_holds :: proc(r: ^Modifier_Rail, f: Rail_Finger) -> bool {
	return !f.plain && !r.gesture
}

// What is on, to light the buttons: latched, or held by a finger.
rail_mods :: proc(r: ^Modifier_Rail) -> Modifiers {
	on := r.latched
	for f in r.fingers[:r.count] do if rail_holds(r, f) do on += {f.which}
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
		if !rail_holds(r, f) do continue
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
		if !d.shift && !d.ctrl && !d.alt {
			r.press.mods, r.press.held = rail_press_mods(r)
			// The pen's eraser end presses as its sector held would (Settings > Pen).
			if d.pointer == .Pen && app.pencil.eraser {
				switch app.nav.eraser {
				case .Tip:
				case .Invert:        r.press.mods ~= {.Invert}
				case .Smooth, .Mask: r.press.mods = eraser_mods(app.nav.eraser) + (r.press.mods & {.Invert})
				}
				r.press.held ||= app.nav.eraser != .Tip
			}
		}
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
		if f.which != .Smooth || !input.primary || !rail_holds(r, f) do continue
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

// The wheel's sizes (Settings > Interface, or two fingers spreading and pinching on it):
// across its ring and across the grip in its middle, in points. The two largest suit a
// large tablet held in both hands.
Wheel_Size :: enum u8 {
	Small,
	Medium,
	Large,
	XL2,
	XL3,
}

@(rodata)
WHEEL_OUTER := [Wheel_Size]f32 {
	.Small  = 112,
	.Medium = 132,
	.Large  = 156,
	.XL2    = 184,
	.XL3    = 216,
}

@(rodata)
WHEEL_HOLE := [Wheel_Size]f32 {
	.Small  = 40,
	.Medium = 44,
	.Large  = 52,
	.XL2    = 58,
	.XL3    = 64,
}

@(rodata)
WHEEL_SIZE_NAMES := [Wheel_Size]string {
	.Small  = "Small",
	.Medium = "Medium",
	.Large  = "Large",
	.XL2    = "2XL",
	.XL3    = "3XL",
}

// What the wheel's sectors show (Settings > Interface): their icons, the icons over their
// names, or the names alone, for someone still learning which is which.
Wheel_Labels :: enum u8 {
	Icons,
	Icons_And_Names,
	Names,
}

// The wheel's turn snaps to steps of this many degrees, so a twist settles somewhere
// tidy, and an upright wheel is easy to get back to.
WHEEL_TURN_STEP :: 15

// The size whose ring is nearest `outer` points across, by ratio.
wheel_size_nearest :: proc(outer: f32) -> Wheel_Size {
	best := Wheel_Size.Small
	for s in Wheel_Size do if abs(math.ln(outer / WHEEL_OUTER[s])) < abs(math.ln(outer / WHEEL_OUTER[best])) do best = s
	return best
}

// `degrees` snapped to WHEEL_TURN_STEP and brought within -180 to 180.
wheel_turn_snapped :: proc(degrees: f32) -> f32 {
	d := math.round(degrees / WHEEL_TURN_STEP) * WHEEL_TURN_STEP
	d = d - 360 * math.floor((d + 180) / 360)
	return d
}

// Follows the two fingers resizing and turning the wheel: its size the one nearest the
// size it had times how far they have spread, its turn the one it had plus how far the
// line between them has turned, snapped. A finger of the two lifted leaves it as it is.
@(private = "file")
rail_gesture_apply :: proc(app: ^App) {
	r := &app.rail
	k := &app.kit
	if !r.gesture do return
	if r.began {
		r.began = false
		k.wheel_from_size, k.wheel_from_turn = WHEEL_OUTER[k.wheel_size], k.wheel_turn
	}
	a, b := rail_index(r, r.pair[0]), rail_index(r, r.pair[1])
	if a < 0 || b < 0 do return
	now := r.fingers[b].pos - r.fingers[a].pos
	from := linalg.length(r.from)
	if from <= 0 || linalg.length(now) <= 0 do return
	k.wheel_size = wheel_size_nearest(k.wheel_from_size * linalg.length(now) / from)
	k.wheel_turn = wheel_turn_snapped(k.wheel_from_turn + math.to_degrees(angle_between(r.from, now)))
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
	dock := shelf_bottom_size(app)
	// How far from the wheel's side the shelf starts (the same either side at Default).
	lo, hi := shelf_bottom_span(app)
	beside := area.w - hi if rail_shown(k) == .Right else lo
	lift := t.edge
	if beside - 8 < rail_inset(app, lift) + size.x do lift = max(lift, t.edge + dock_lift(app) + dock.y + 8)
	return lift
}

// How far in from its side the wheel sits by default when `lift` above the bottom: the
// edge's margin, or on the left beside the brush bar rather than under it where a short
// window (or a large interface) brings the bar down to it.
rail_inset :: proc(app: ^App, lift: f32) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	// A moved island keeps clear of the dial itself (bar_place_room).
	if rail_shown(k) != .Left || k.places[.Offhand].edge != .Default do return t.edge
	area := ui.safe_area(ctx)
	bar, _ := ui.prev_layout(ctx, "brush bar")
	// No brush bar (the workspace hides it), nothing to keep clear of.
	if bar.y <= 0 do return t.edge
	if brush_bar_top(app) + bar.y + 8 > area.h - lift - rail_size(app).y do return kit_left(app)
	return t.edge
}

// How far up from the bottom of the safe area the wheel reaches, in points, on `side`;
// zero when it is elsewhere or was dragged away from its place, for what must stay clear
// of it.
rail_reach :: proc(app: ^App, side: Rail_Side) -> f32 {
	if rail_shown(&app.kit) != side || side == .Off || app.kit.wheel_offset != {} do return 0
	return rail_lift(app) + rail_size(app).y
}

// How wide the wheel stands from its side where it sits in its place, in points, for the
// bottom bar to keep clear of; zero when it is off or was dragged elsewhere.
rail_reach_across :: proc(app: ^App) -> f32 {
	k := &app.kit
	if rail_shown(k) == .Off || k.wheel_offset != {} do return 0
	return rail_inset(app, rail_lift(app)) + rail_size(app).x
}

// The wheel at the bottom left or right, or where its grip was dragged to (kept inside
// the window). A click (the mouse's, the pen's) on a modifier sector toggles its latch;
// fingers never reach those, the wheel takes them first (rail_claims). The right sector
// opens the brush pie. Hidden, it lets go of every latch and finger, so nothing it held
// acts unseen.
kit_modifier_rail :: proc(app: ^App) {
	r := &app.rail
	k := &app.kit
	r.center, r.outer, r.hole, r.turn, r.root = {}, 0, 0, 0, 0
	if rail_shown(k) == .Off {
		r.latched = {}
		rail_forget(r)
		return
	}
	rail_gesture_apply(app)
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	size := rail_size(app)
	held := rail_mods(r)
	keys := keyboard_mods(app.device.shift, app.device.ctrl)
	// Hide, latched, held or from the keys, lights both of the sectors it is made of, and
	// both of them together light Hide's.
	lit_of :: proc(m: Modifier, set: Modifiers) -> bool {
		return m in set || (m == .Smooth || m == .Mask) && .Hide in set || m == .Hide && .Smooth in set && .Mask in set
	}
	sectors: [4]ui.Wheel_Sector
	for which, i in dial_of(k) {
		switch v in which {
		case Bar_Slot:
			if v.id == .Brush_Pie {
				sectors[i] = {name = "Brush pie", glyph = ui.ICON_PIE, caption = "Pie", keys = command_hint(app, .Brush_Pie)}
			} else {
				// A command's own icon and label, lit while it is on (Symmetry X, say).
				look := ui.Modifier_Look.Lit if command_checked(app, v.id, v.arg) else .Off
				sectors[i] = {name = bar_label(v), glyph = bar_icon(v), caption = bar_label(v), look = look, keys = command_hint(app, v.id, v.arg)}
			}
		case Modifier:
			look := ui.Modifier_Look.Latched if lit_of(v, r.latched) else (.Lit if lit_of(v, held) || lit_of(v, keys) else .Off)
			name := modifier_name(app, v)
			sectors[i] = {name = name, glyph = MODIFIER_ICONS[v], caption = name, look = look, keys = MODIFIER_KEYS[v]}
		}
		switch k.wheel_labels {
		case .Icons:           sectors[i].caption = ""
		case .Icons_And_Names:
		case .Names:           sectors[i].glyph = 0
		}
	}
	turn := math.to_radians(k.wheel_turn)
	x := ui.Anchor.Start if rail_shown(k) == .Left else .End
	// The drag is on the screen, so its sign follows the side the layout puts the wheel.
	screen_x, _ := ui.mirrored(ctx, x, {})
	side: f32 = 1 if screen_x == .Start else -1
	base_lift := rail_lift(app)
	base_inset := rail_inset(app, base_lift)
	// Dragged: as far from its place as the grip went, kept inside the window.
	inset := clamp(base_inset + side * k.wheel_offset.x, 0, max(area.w - size.x, 0))
	lift := clamp(base_lift - k.wheel_offset.y, 0, max(area.h - size.y, 0))
	r.root = ui.id_of(ctx, "modifier rail")
	ui.begin_anchored(ctx, "modifier rail", x, .End, {inset, lift}, {direction = .Column})
	res := ui.wheel(ctx, "modifier wheel", size.x, WHEEL_HOLE[k.wheel_size], sectors, turn)
	b := ctx.last_rect
	ui.end(ctx)
	r.center = [2]f32{b.x + b.w * 0.5, b.y + b.h * 0.5} * k.scale
	r.outer, r.hole, r.turn = b.w * k.scale, WHEEL_HOLE[k.wheel_size] * k.scale, turn
	if res.clicked >= 0 {
		switch v in dial_of(k)[res.clicked] {
		case Modifier: rail_toggle(r, v)
		case Bar_Slot: command_run(app, v.id, v.arg)
		}
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
	if rail_shown(k) == .Off || r.root == 0 do return
	if k.menu || k.versions || k.browser || k.object_menu || k.ctx.select_open != 0 || k.ctx.popup_open != 0 do return
	which = rail_hit(r, dial_of(k)^, p) or_return
	return which, ui.root_at(&k.ctx, p / k.scale) == r.root
}

// Whether a finger landing at `p` is the rail's though on no modifier (the brush pie's
// sector or the grip): only while another finger is on the wheel, so the two can resize
// and turn it; a lone finger there is the panels', to open the pie or drag the wheel.
rail_claims_plain :: proc(app: ^App, p: [2]f32) -> bool {
	k := &app.kit
	r := &app.rail
	if r.count == 0 || rail_shown(k) == .Off || r.root == 0 || linalg.length(p - r.center) > r.outer * 0.5 do return false
	if k.menu || k.versions || k.browser || k.object_menu || k.ctx.select_open != 0 || k.ctx.popup_open != 0 do return false
	return ui.root_at(&k.ctx, p / k.scale) == r.root
}

// The brush ring's colour (straight RGBA), as the reference app colours its cursor by what
// a press will do: red to sculpt, pink to sculpt inverted, blue to smooth, yellow to mask,
// white to hide (a selection), as the keyboard's keys held say, or else as the rail would
// press (or the press under way took). Pressing makes it more opaque.
brush_ring_color :: proc(app: ^App, pressing: bool) -> [4]f32 {
	r := &app.rail
	d := &app.device
	mods := keyboard_mods(d.shift, d.ctrl)
	if mods == {} && !d.alt {
		mods, _ = rail_press_mods(r)
		// A press's own, while it lasts: what it took when it went down.
		if r.press.active && .Left in d.down do mods = r.press.mods
	}
	a: f32 = 0.95 if pressing else 0.75
	mode, has := rail_mode(mods).?
	switch {
	case has && mode == .Hide:    return {1, 1, 1, a}
	case has && mode == .Mask:    return {1, 0.85, 0.3, a}
	case has && mode == .Smooth:  return {0.45, 0.7, 1, a}
	case .Invert in mods:         return {1, 0.5, 0.85, a}
	}
	return {1, 0.4, 0.34, a}
}
