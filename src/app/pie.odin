package main

import "core:math"
import "core:math/linalg"
import "core:time"
import "../sculpt"
import sdl "vendor:sdl3"

// The brush pie: every brush in a ring around the pointer, as Blender's pie menus
// and ZBrush's spacebar palette put choices where the hand already is. Holding Space
// opens it and letting go picks the brush the pointer points toward, so a flick picks
// without aiming. A tap of Space, or of the right button (a pen's side button sends
// one), leaves it open for a click instead. A click in the middle, Escape, or another
// tap closes it. While it is open no tool or camera input reaches the viewport, and no
// press reaches the panels under it (kit_begin).
//
// The same ring shows the user's pies (user_pies.odin), opened by the `.Pie` command:
// eight slots of commands, picked by a tap or click only. A dimmed slice (its command
// cannot run now) or an empty one keeps the pie open.

Pie :: struct {
	open:     bool,
	hold:     bool, // opened by holding Space: letting go picks
	which:    int, // 0 for the brushes, 1 to USER_PIES for a user pie
	center:   [2]f32, // where it opened, in viewport coordinates
	opened:   f64, // input_clock when it opened
	// The kit frame a user pie opened in: a command run by a click during that frame's
	// layout (the palette, a menu) must not see the same click pick from the pie.
	opened_frame: int,
	hover:    int, // the slice the pointer points toward, or -1 in the middle
	// A click picked from it: the left button does nothing else until it is let go.
	swallow:  bool,
	// Space over the viewport, which the event loop gives the pie rather than the frame's
	// keys: whether it is down, and whether it went down or up this frame.
	space_down, space_pressed, space_released: bool,
	// Lens's brush pie: the slice a press went down on, plus one (0 for none), which picks
	// when let go there; and the slice the pointer has rested on since `rest_at`, once
	// `rest_set` (a rest of PIE_REST shows that brush's quick settings).
	pressed_on: int,
	rest:       int,
	rest_at:    f64,
	rest_set:   bool,
}

// How long the pointer rests on a slice of Lens's brush pie before its quick settings show,
// in seconds: longer than the hold delay, so a flick that slows on its way is still a pick.
PIE_REST :: 0.5

// A fresh install's brush pie in Lens, clockwise from the top: the mockups' eight, placed by
// direction so a flick learns them (Clay up, Grab down, Pinch left, Inflate right).
BRUSH_PIE_DEFAULT :: [?]Bar_Slot {
	{.Brush, int(sculpt.Brush_Kind.Clay)}, {.Brush, int(sculpt.Brush_Kind.Draw)}, {.Brush, int(sculpt.Brush_Kind.Inflate)},
	{.Brush, int(sculpt.Brush_Kind.Crease)}, {.Brush, int(sculpt.Brush_Kind.Grab)}, {.Brush, int(sculpt.Brush_Kind.Flatten)},
	{.Brush, int(sculpt.Brush_Kind.Pinch)}, {.Brush, int(sculpt.Brush_Kind.Smooth)},
}

// Slot `i` of pie `which`: the brush pie's (0), or a user pie's.
pie_slot :: proc(app: ^App, which, i: int) -> Bar_Slot {
	if which == 0 {
		used := bar_used(app, .Brush_Pie)
		return used[i] if i >= 0 && i < len(used) else {}
	}
	return app.kit.pies[which - 1][i]
}

// The pie's sizes are interface points, like its labels, so it keeps its proportions on
// any display; window coordinates are these times the kit's scale.
PIE_INNER :: 36 // from the middle: pointing closer picks nothing
// Wide enough that the labels of neighbouring slices, 26 degrees apart for fourteen
// brushes, sit beside each other.
PIE_OUTER :: 165
// A hold of Space, or a right press, shorter than this and moving less than PIE_TAP_PX
// is a tap: it leaves the pie open (or opens it) rather than picking or orbiting.
PIE_TAP :: 250 * time.Millisecond
PIE_TAP_PX :: 4

// Opens, follows and closes the pie with this frame's input, and while it is open (and
// until a click that picked from it is let go) takes the pointer away from the tools and
// the camera. `right_tap` is a right press let go this frame as a tap.
pie_update :: proc(app: ^App, input: ^Viewport_Input, right_tap: bool) {
	p := &app.ui.pie
	d := &app.device
	defer p.space_pressed, p.space_released = false, false
	if p.swallow {
		if .Left in d.down {
			viewport_mute(input)
		} else {
			p.swallow = false
		}
	}
	if !p.open {
		// Never over a stroke or a drag in progress.
		busy := app.stroke.active || (input.dragging && .Left in d.down)
		if !busy && input.hovered && p.space_pressed {
			p^ = {open = true, hold = true, center = input.mouse_pos, opened = input_clock(app), space_down = p.space_down}
		} else if !busy && right_tap && d.pointer == .Pen && app.nav.gestures[pencil_slot_here(app, .Pen_Button)] != {.Brush_Pie, 0} {
			// The pen's side button runs what the gesture map gives it where it points instead.
			_ = gesture_run(app, pencil_slot_here(app, .Pen_Button))
		} else if !busy && right_tap {
			p^ = {open = true, center = input.mouse_pos, opened = input_clock(app), space_down = p.space_down}
		}
		p.hover = pie_slice(input.mouse_pos - p.center, app.kit.scale, pie_slot_count(app, p.which))
		if p.open do viewport_mute(input)
		return // what opened it this frame does nothing more
	}
	p.hover = pie_slice(input.mouse_pos - p.center, app.kit.scale, pie_slot_count(app, p.which))
	// A lifted finger points at nothing: where it last was (the dial's Pie, say) is not a choice.
	brushes := p.which == 0
	if brushes && d.pointer == .Finger && .Left not_in d.down && p.pressed_on == 0 do p.hover = -1
	if brushes && lens_pie_update(app, input) do return
	if p.which > 0 && p.opened_frame == app.kit.frame {
		// Opened during this frame's layout: the press or release that did it is spent.
		if .Left in d.down do p.swallow = true
		viewport_mute(input)
		return
	}
	if p.hold {
		if p.space_released {
			if p.hover >= 0 {
				pie_pick(app, p.hover)
			} else if input_clock(app) - p.opened < time.duration_seconds(PIE_TAP) {
				p.hold = false // a tap: stay open for a click
			} else {
				p.open = false
			}
		}
	} else if .Left in d.pressed {
		p.swallow = true
		if p.hover < 0 {
			p.open = false
		} else if pie_pickable(app, p.which, p.hover) {
			pie_pick(app, p.hover)
		}
	} else if right_tap || p.space_pressed || key_pressed(d, sdl.K_ESCAPE) {
		p.open = false
	}
	viewport_mute(input)
}

// Which of `n` slices a pointer this far from the middle points toward: the brushes in key
// order, or a user pie's slots, clockwise from the top, or -1 inside PIE_INNER. `d` is in
// window coordinates, `scale` of them to a point.
pie_slice :: proc(d: [2]f32, scale: f32, n: int) -> int {
	if linalg.length(d) < PIE_INNER * scale do return -1
	step := 2 * math.PI / f32(n)
	// Screen y grows downward, so atan2 runs clockwise from the right; the top slice is
	// centred on straight up.
	a := math.atan2(d.y, d.x) + math.PI / 2 + step / 2
	a = math.mod(a + 4 * math.PI, 2 * math.PI)
	return min(int(a / step), n - 1)
}

// Whether a click on slice `i` of pie `which` runs something: a command that can run now.
pie_pickable :: proc(app: ^App, which, i: int) -> bool {
	s := pie_slot(app, which, i)
	return s.id != .None && command_enabled(app, s.id, s.arg)
}

// The brush pie, open: a press on a slice picks it when let go there (a flick from the
// dial or Space picks on letting go as before), and resting on a slice for PIE_REST, with a
// press, Space or the pen held over it, picks that brush and shows its quick settings
// beside the slice instead (lens_shelf.odin). True when it took this frame's input.
@(private = "file")
lens_pie_update :: proc(app: ^App, input: ^Viewport_Input) -> bool {
	p := &app.ui.pie
	d := &app.device
	now := input_clock(app)
	if !p.rest_set || p.hover != p.rest do p.rest, p.rest_at, p.rest_set = p.hover, now, true
	pressing := p.pressed_on > 0 && p.pressed_on - 1 == p.hover
	if p.hover >= 0 && now - p.rest_at >= PIE_REST && (p.hold || pressing || d.pointer == .Pen) && pie_pickable(app, 0, p.hover) {
		pie_quick(app, p.hover)
		viewport_mute(input)
		return true
	}
	if p.hold do return false
	if .Left in d.pressed {
		p.swallow = true
		if p.hover < 0 do p.open = false
		else do p.pressed_on, p.rest, p.rest_at = p.hover + 1, p.hover, now
		viewport_mute(input)
		return true
	}
	if p.pressed_on > 0 && .Left not_in d.down {
		if p.pressed_on - 1 == p.hover && pie_pickable(app, 0, p.hover) do pie_pick(app, p.hover)
		p.pressed_on = 0
		viewport_mute(input)
		return true
	}
	return false
}

// Picks slice `i` of the brush pie and, for a brush, shows its quick settings beside
// where the slice's label was.
@(private = "file")
pie_quick :: proc(app: ^App, i: int) {
	p := &app.ui.pie
	k := &app.kit
	s := pie_slot(app, 0, i)
	step := 2 * math.PI / f32(PIE_SLOTS)
	mid := -math.PI / 2 + f32(i) * step
	r: f32 = PIE_INNER + 0.62 * (PIE_OUTER - PIE_INNER)
	at := (p.center + r * k.scale * [2]f32{math.cos(mid), math.sin(mid)} + app.ui.viewport_origin) / k.scale
	pie_pick(app, i)
	if s.id != .Brush do return
	kit_floats_close(k)
	k.shelf.quick, k.shelf.quick_at = true, {at.x - 20, at.y - 20, 40, 40}
	k.pie_quicks += 1
}

// Closes the pie, then runs what the slice holds, so a command that opens something (the
// palette, a popover, another pie) is not closed by the pie closing.
@(private = "file")
pie_pick :: proc(app: ^App, slice: int) {
	haptic(app, .Alignment)
	which := app.ui.pie.which
	app.ui.pie.open = false
	s := pie_slot(app, which, slice)
	if which == 0 {
		command_run(app, s.id, s.arg)
		return
	}
	app.kit.pie_runs += 1
	command_run(app, s.id, s.arg)
}
