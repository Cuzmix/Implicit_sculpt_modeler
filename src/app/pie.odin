package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"
import imgui "deps:odin-imgui"

import "../sculpt"

// The brush pie: the nine brushes in a ring around the pointer, as Blender's pie menus
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
	// Space over the viewport, which the event loop keeps from ImGui: whether it is
	// down, and whether it went down or up this frame.
	space_down, space_pressed, space_released: bool,
}

PIE_INNER :: 36 // pixels from the middle: pointing closer picks nothing
// Wide enough that the two labels side by side at the bottom of the ring, 40 degrees
// apart, sit clear of each other.
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
	defer p.space_pressed, p.space_released = false, false
	if p.swallow {
		if imgui.IsMouseDown(.Left) {
			pie_mute(input)
		} else {
			p.swallow = false
		}
	}
	if !p.open {
		// Never over a stroke or a drag in progress.
		busy := app.stroke.active || (input.dragging && imgui.IsMouseDown(.Left))
		if !busy && input.hovered && p.space_pressed {
			p^ = {open = true, hold = true, center = input.mouse_pos, opened = time.tick_now(), space_down = p.space_down}
		} else if !busy && right_tap {
			p^ = {open = true, center = input.mouse_pos, opened = time.tick_now(), space_down = p.space_down}
		}
		p.hover = pie_slice(input.mouse_pos - p.center)
		if p.open do pie_mute(input)
		return // what opened it this frame does nothing more
	}
	p.hover = pie_slice(input.mouse_pos - p.center)
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
	} else if imgui.IsMouseClicked(.Left) {
		if p.hover >= 0 do pie_pick(app, p.hover)
		p.open, p.swallow = false, true
	} else if right_tap || p.space_pressed || imgui.IsKeyPressed(.Escape, false) {
		p.open = false
	}
	pie_mute(input)
}

// Which slice a pointer this far from the middle points toward: the brushes in key order
// clockwise from the top, or -1 inside PIE_INNER.
pie_slice :: proc(d: [2]f32) -> int {
	if linalg.length(d) < PIE_INNER do return -1
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
	app.brush.kind = sculpt.Brush_Kind(slice)
	app.tool = .Brush
	app.ui.pie.open = false
}

// Takes the pointer away from the tools and the camera for this frame.
@(private = "file")
pie_mute :: proc(input: ^Viewport_Input) {
	input.primary, input.press, input.smooth, input.invert = false, false, false, false
	input.orbit_drag, input.pan_drag, input.wheel = false, false, 0
}

// Draws the open pie over everything, so it shows whole even near the viewport's edge.
draw_pie :: proc(app: ^App) {
	p := app.ui.pie
	if !p.open do return
	list := imgui.GetForegroundDrawList()
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	c := app.ui.viewport_origin + p.center
	n := len(sculpt.Brush_Kind)
	step := 2 * math.PI / f32(n)
	GAP :: 0.02 // radians between slices
	for kind, i in sculpt.Brush_Kind {
		mid := -math.PI / 2 + f32(i) * step
		a0, a1 := mid - step / 2 + GAP, mid + step / 2 - GAP
		fill := [4]f32{0.13, 0.14, 0.17, 0.92}
		if i == p.hover do fill = {0.85, 0.6, 0.25, 0.95}
		imgui.DrawList_PathArcTo(list, c, PIE_OUTER, a0, a1, 12)
		imgui.DrawList_PathArcTo(list, c, PIE_INNER + 6, a1, a0, 6)
		imgui.DrawList_PathFillConcave(list, rgba(fill))
		if kind == app.brush.kind {
			// The brush in use: a band along the outside of its slice.
			imgui.DrawList_PathArcTo(list, c, PIE_OUTER - 3, a0, a1, 12)
			imgui.DrawList_PathStroke(list, rgba({0.95, 0.8, 0.45, 1}), 4)
		}
		label := fmt.ctprintf("%d %s", i + 1, BRUSH_NAMES[kind])
		size := imgui.CalcTextSize(label)
		// Past the ring's middle, where neighbouring slices are furthest apart.
		r: f32 = PIE_INNER + 0.62 * (PIE_OUTER - PIE_INNER)
		at := c + r * imgui.Vec2{math.cos(mid), math.sin(mid)} - size * 0.5
		text := [4]f32{0.1, 0.08, 0.05, 1} if i == p.hover else {0.92, 0.92, 0.92, 1}
		imgui.DrawList_AddText(list, at, rgba(text), label)
	}
	// The middle, and which way the pointer points from it.
	imgui.DrawList_AddCircleFilled(list, c, PIE_INNER, rgba({0.13, 0.14, 0.17, 0.85}), 32)
	imgui.DrawList_AddCircle(list, c, PIE_INNER, rgba({1, 1, 1, 0.35}), 32, 1.5)
	if p.hover >= 0 {
		d := linalg.normalize(app.ui.viewport_mouse - p.center)
		imgui.DrawList_AddCircleFilled(list, c + (PIE_INNER - 6) * imgui.Vec2{d.x, d.y}, 4, rgba({0.95, 0.8, 0.45, 1}), 12)
	}
}
