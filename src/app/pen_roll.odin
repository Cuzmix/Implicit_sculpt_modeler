package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../camera"
import "../ui"

// The pen's roll over the view and the pencil's gestures by where the pen points
// (Settings > Pen, WHERE THE PEN POINTS). The pen hovering over the model and turned about
// its own length twists the view about the point under its tip, as Nomad's users know the
// Pencil Pro's roll; over empty space it twists about the tip. Each place can roll
// something else instead (a brush value, the zoom, History), and the pencil's double-tap
// and squeeze each run their own command over the model and over empty space
// (Gesture_Slot's _Empty slots), as Procreate Dreams lets a squeeze mean another thing over
// its timeline. A roll over a slider is the slider's own (ui.hover_roll), before any of this.

// Where the pen points, for what its gestures do there.
Pen_Area :: enum u8 {
	Model, // the model under the tip, in the view
	Empty, // the view's empty space, or anywhere a gesture has no place of its own
}

@(rodata)
PEN_AREA_NAMES := [Pen_Area]string {
	.Model = "Over the model",
	.Empty = "Over empty space",
}

// What the pen's roll does while it hovers a place.
Roll_Action :: enum u8 {
	Nothing,
	Twist, // the view rolls about the point under the tip, as far as the pen turns
	Spin, // the view turns about the scene's up axis through that point, as a turntable
	Zoom, // the view comes closer toward the tip, twice as close for a half turn
	Size,
	Strength,
	Focal_Shift,
	History, // undo and redo a step for every ROLL_HISTORY_STEP degrees
}

@(rodata)
ROLL_ACTION_NAMES := [Roll_Action]string {
	.Nothing     = "Nothing",
	.Twist       = "Twist the view",
	.Spin        = "Spin the view",
	.Zoom        = "Zoom toward the tip",
	.Size        = "Draw size",
	.Strength    = "Strength",
	.Focal_Shift = "Focal shift",
	.History     = "Undo and redo",
}

ROLL_DEFAULTS :: [Pen_Area]Roll_Action{.Model = .Twist, .Empty = .Twist}

// How far the hovering pen may travel, in points, while its roll has not yet passed
// ui.ROLL_ENGAGE: further, and the turn counts again from nothing, so a hand that turns
// the pen a little as it carries it across the view never starts a twist.
ROLL_TRAVEL :: 40

// The degrees of roll that undo or redo one step, as the Surface Dial's Undo tool steps
// History: enough that each step is a turn of its own.
ROLL_HISTORY_STEP :: 20

// A roll over the view under way: from when it passed ui.ROLL_ENGAGE until the pen
// touches down, leaves the view or goes.
Pen_Twist :: struct {
	gen:    u32, // the roll's id in the kit is its count; a new count starts the turn over
	anchor: [2]f32, // where the pen was, in the view's pixels, as this count began
	live:   bool,
	area:   Pen_Area,
	action: Roll_Action,
	// The model's point under the tip as the roll passed ui.ROLL_ENGAGE, which a twist or a
	// spin keeps where it is on screen; none over empty space.
	hit:    Maybe(Vec3),
	at:     [2]f32, // the tip then, from the view's middle (x right, y down), in pixels
	from:   f32, // the camera's roll then, undetented (roll_level_undetent)
	turned: f32, // radians turned since then
	steps:  f32, // History: degrees turned toward the next step
	size:   [2]f32, // the view's size in pixels as the frame last laid it out
	rolls:  int, // rolls begun, for the exit stats
}

// The roll's id in the kit, for ui.hover_roll.
@(private = "file")
pen_twist_id :: proc(tw: ^Pen_Twist) -> ui.Id {
	return ui.hash_under(0, fmt.tprintf("pen roll over the view %d", tw.gen))
}

// What a roll over `area` does now: a brush whose alpha turns with the pen (Pen roll)
// keeps the roll over the model for itself.
pen_roll_action :: proc(app: ^App, area: Pen_Area) -> Roll_Action {
	if area == .Model && app.tool == .Brush && brush_alpha(app) != nil && app.brush.alpha_mode == .Pen_Roll do return .Nothing
	return app.nav.pen_roll[area]
}

// The model's point under `pos` (the view's pixels), if any.
@(private = "file")
pen_model_hit :: proc(app: ^App, pos, size: [2]f32) -> (Vec3, bool) {
	origin, dir := mouse_ray(app.camera, pos, size)
	_, hit, ok := scene_raycast(app, origin, dir)
	return hit, ok
}

// Turns the pen's roll over the view into its place's action, once the frame's interface
// is laid out (a slider under the pen took its roll there, and the view is not hovered).
pen_roll_frame :: proc(app: ^App, input: Viewport_Input) {
	ctx := &app.kit.ctx
	tw := &app.pen_twist
	tw.size = input.size
	hovering := input.hovered && app.device.pointer == .Pen && app.device.down == {}
	id := pen_twist_id(tw)
	engaged := ctx.roll.on == id && ctx.roll.engaged
	if !engaged {
		tw.live = false
		if !hovering || ctx.roll.on != id {
			tw.anchor = input.mouse_pos
		} else if linalg.length(input.mouse_pos - tw.anchor) > ROLL_TRAVEL * app.kit.scale {
			tw.gen += 1
			tw.anchor = input.mouse_pos
			id = pen_twist_id(tw)
		}
	}
	degrees := ui.hover_roll(ctx, id, hovering)
	if !(ctx.roll.on == id && ctx.roll.engaged) {
		tw.live = false
		return
	}
	if !tw.live {
		hit, on_model := pen_model_hit(app, input.mouse_pos, input.size)
		tw.live, tw.area = true, .Model if on_model else .Empty
		tw.rolls += 1
		tw.hit = hit if on_model else nil
		tw.action = pen_roll_action(app, tw.area)
		tw.at = input.mouse_pos - input.size * 0.5
		tw.from, tw.turned, tw.steps = roll_level_undetent(app.camera.roll), 0, 0
	}
	if degrees != 0 do pen_roll_apply(app, tw, degrees, input.size)
}

// Does `degrees` of the roll under way (clockwise seen from the pen's top).
pen_roll_apply :: proc(app: ^App, tw: ^Pen_Twist, degrees: f32, size: [2]f32) {
	c := &app.camera
	switch tw.action {
	case .Nothing:
	case .Twist:
		// As far as the pen turns, clockwise turning the picture clockwise, held level near
		// level as two fingers' twist is (roll_level_detent).
		tw.turned += math.to_radians(degrees)
		want := roll_level_detent(camera.wrap_angle(tw.from + tw.turned))
		turn := camera.wrap_angle(want - c.roll)
		if turn == 0 do return
		if want == 0 do haptic(app, .Alignment)
		if hit, ok := tw.hit.?; ok {
			before := c^
			camera.orbit_roll(c, turn)
			camera.orbit_turn_about(c, before, hit)
		} else {
			camera.orbit_roll_about(c, turn, tw.at, size.y)
		}
	case .Spin:
		// Clockwise turns the model clockwise seen from above.
		before := c^
		camera.orbit_spin(c, math.to_radians(degrees))
		camera.orbit_turn_about(c, before, tw.hit.? or_else before.target)
	case .Zoom:
		// Clockwise comes closer, as a screw turned in.
		camera.orbit_zoom_toward(c, math.pow(2, degrees / 180), tw.at, size.y)
	case .Size:
		app.brush.radius_px = clamp(app.brush.radius_px * math.pow(2, degrees * ROLL_POINTS / ROLL_SIZE_DOUBLE), MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Strength:
		strength := brush_strength(app)
		strength^ = clamp(strength^ + degrees * ROLL_POINTS / ROLL_STRENGTH_FULL, MIN_STRENGTH, 1)
	case .Focal_Shift:
		// Half a turn sweeps it end to end, as a slider's roll does.
		if value_enabled(app, .Focal_Shift) {
			lo, hi, _ := value_range(.Focal_Shift)
			value_set(app, .Focal_Shift, clamp(value_get(app, .Focal_Shift) + degrees / ui.ROLL_SWEEP * (hi - lo), lo, hi))
		}
	case .History:
		// Clockwise goes forward, as a dial turned on does; each step taps the hand.
		tw.steps += degrees
		for tw.steps >= ROLL_HISTORY_STEP {
			tw.steps -= ROLL_HISTORY_STEP
			if !history_can_redo(app) {
				tw.steps = 0
				break
			}
			history_redo(app)
			haptic(app, .Alignment)
		}
		for tw.steps <= -ROLL_HISTORY_STEP {
			tw.steps += ROLL_HISTORY_STEP
			if !history_can_undo(app) {
				tw.steps = 0
				break
			}
			history_undo(app)
			haptic(app, .Alignment)
		}
	}
}

// Where the pen points now, for a double-tap or squeeze: over the model in the view, or
// anywhere else. A pen out of hover range points nowhere the app can tell, and counts as
// over the model, the gesture's first choice.
pen_area_now :: proc(app: ^App) -> Pen_Area {
	d := &app.device
	p := &app.pencil
	if d.pointer != .Pen || !p.about do return .Model
	size := app.pen_twist.size
	pos := viewport_point(app, d.mouse)
	inside := pos.x >= 0 && pos.y >= 0 && pos.x <= size.x && pos.y <= size.y
	if !inside || ui.wants_pointer(&app.kit.ctx) do return .Empty
	if _, ok := pen_model_hit(app, pos, size); ok do return .Model
	return .Empty
}

// The gesture slot a double-tap or squeeze runs where the pen points now.
pencil_slot_here :: proc(app: ^App, slot: Gesture_Slot) -> Gesture_Slot {
	if pen_area_now(app) != .Empty do return slot
	#partial switch slot {
	case .Pen_Double_Tap: return .Pen_Double_Tap_Empty
	case .Pen_Squeeze:    return .Pen_Squeeze_Empty
	}
	return slot
}

// Settings > Pen's WHERE THE PEN POINTS: the place, then what the roll, double-tap and
// squeeze do there.
settings_pen_areas :: proc(app: ^App) {
	ctx := &app.kit.ctx
	n := &app.nav
	names := [len(Pen_Area)]string{"Over the model", "Over empty space"}
	if picked := ui.tabs(ctx, "Where the pen points", names[:], int(app.kit.pen_area)); picked >= 0 do app.kit.pen_area = Pen_Area(picked)
	area := app.kit.pen_area
	ui.label(ctx, "Roll")
	rolls: [len(Roll_Action)]string
	for a in Roll_Action do rolls[a] = ROLL_ACTION_NAMES[a]
	if picked := ui.select(ctx, fmt.tprintf("Roll %s##pen area", PEN_AREA_NAMES[area]), rolls[:], int(n.pen_roll[area])); picked >= 0 do n.pen_roll[area] = Roll_Action(picked)
	taps := [Pen_Area][2]Gesture_Slot{.Model = {.Pen_Double_Tap, .Pen_Squeeze}, .Empty = {.Pen_Double_Tap_Empty, .Pen_Squeeze_Empty}}
	ui.label(ctx, "Pencil double-tap")
	gesture_select(app, taps[area][0])
	ui.label(ctx, "Pencil squeeze")
	gesture_select(app, taps[area][1])
	ui.paragraph(ctx, "Turn the pen about its own length while it hovers, past the first 10 degrees, and it does this where it points: Twist the view keeps the point under the tip where it is and turns the picture as far as the pen turns, holding level as it passes. Over a slider the roll always sets the slider. A brush whose alpha turns with the pen keeps the roll over the model. Roll needs a pen that reports it (Apple Pencil Pro, some Windows pens).")
	_ = ui.switch_row(ctx, "Roll while grabbing twists what you hold", &n.grab_twist)
	ui.paragraph(ctx, "While Grab or Elastic drags, turning the pen past the first 10 degrees turns what it holds about where it took hold, as far as the pen turns, the middle fully and the brush's edge not at all; a symmetric copy turns the mirrored way.")
	ui.paragraph(ctx, "Double-tap and squeeze come from an Apple Pencil (squeeze from the Pro), and a pencil too far away to hover does what it does over the model. Follow the Pencil setting does what the iPad's Settings > Apple Pencil asks: the palette at the tip opens the brush pie, the eraser turns Smooth on or off. Off there turns them off here too.")
}
