package main

import "core:math"
import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"

import "../sculpt"

// The brush pie: every brush in a ring around the pointer, as Blender's pie menus
// and ZBrush's spacebar palette put choices where the hand already is. Holding Space
// opens it and letting go picks the brush the pointer points toward, so a flick picks
// without aiming. A tap of Space, or of the right button (a pen's side button sends
// one), leaves it open for a click instead. A click in the middle, Escape, or another
// tap closes it. While it is open no tool or camera input reaches the viewport.

Pie :: struct {
	open:     bool,
	hold:     bool, // opened by holding Space: letting go picks
	center:   [2]f32, // where it opened, in viewport coordinates
	opened:   time.Tick,
	hover:    int, // the slice the pointer points toward, or -1 in the middle
	// A click picked from it: the left button does nothing else until it is let go.
	swallow:  bool,
	// Space over the viewport, which the event loop gives the pie rather than the frame's
	// keys: whether it is down, and whether it went down or up this frame.
	space_down, space_pressed, space_released: bool,
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
			p^ = {open = true, hold = true, center = input.mouse_pos, opened = time.tick_now(), space_down = p.space_down}
		} else if !busy && right_tap {
			p^ = {open = true, center = input.mouse_pos, opened = time.tick_now(), space_down = p.space_down}
		}
		p.hover = pie_slice(input.mouse_pos - p.center, app.kit.scale)
		if p.open do viewport_mute(input)
		return // what opened it this frame does nothing more
	}
	p.hover = pie_slice(input.mouse_pos - p.center, app.kit.scale)
	if p.hold {
		if p.space_released {
			if p.hover >= 0 {
				pie_pick(app, p.hover)
			} else if time.tick_since(p.opened) < PIE_TAP {
				p.hold = false // a tap: stay open for a click
			} else {
				p.open = false
			}
		}
	} else if .Left in d.pressed {
		if p.hover >= 0 do pie_pick(app, p.hover)
		p.open, p.swallow = false, true
	} else if right_tap || p.space_pressed || key_pressed(d, sdl.K_ESCAPE) {
		p.open = false
	}
	viewport_mute(input)
}

// Which slice a pointer this far from the middle points toward: the brushes in key order
// clockwise from the top, or -1 inside PIE_INNER. `d` is in window coordinates, `scale`
// of them to a point.
pie_slice :: proc(d: [2]f32, scale: f32) -> int {
	if linalg.length(d) < PIE_INNER * scale do return -1
	n := len(sculpt.Brush_Kind)
	step := 2 * math.PI / f32(n)
	// Screen y grows downward, so atan2 runs clockwise from the right; the top slice is
	// centred on straight up.
	a := math.atan2(d.y, d.x) + math.PI / 2 + step / 2
	a = math.mod(a + 4 * math.PI, 2 * math.PI)
	return min(int(a / step), n - 1)
}

@(private = "file")
pie_pick :: proc(app: ^App, slice: int) {
	command_run(app, .Brush, slice)
	app.ui.pie.open = false
}
