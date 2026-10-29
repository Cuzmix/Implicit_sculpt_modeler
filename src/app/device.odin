package main

import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"

import "../ui"

// The keyboard and the pointer as SDL reported them this frame. The shortcuts, the brush
// pie, the size and strength adjustment, the interface and the viewport all read them
// here.
Device :: struct {
	keys:     [dynamic; 64]Key_Press, // keys that went down this frame, repeats included, oldest first
	// Held once the frame's events were read, or when its last key went down, so a chord
	// pressed and let go within one slow frame still counts.
	shift:    bool,
	ctrl:     bool,
	alt:      bool,
	key_mods: sdl.Keymod, // the modifiers held when the frame's last key went down
	script_mods: sdl.Keymod, // the modifiers a --ui-events script holds down
	mouse:    [2]f32, // the pointer, in window coordinates
	moved:    [2]f32, // how far it moved this frame, jumps of a finger to where it lands left out
	over:     bool, // the pointer is over the window
	// What drives the pointer: the mouse, a finger (touch.odin turns the first finger of
	// a touch into the pointer) or the pen, which hovers too.
	pointer:  ui.Pointer_Kind,
	cancel:   bool, // the system took the pointer back this frame: what it pressed lets go without a click
	down:     ui.Buttons, // held at the end of the frame
	pressed:  ui.Buttons, // went down during the frame, even if it came up again
	released: ui.Buttons, // came up during the frame
	wheel:    f32,
	// What was typed this frame (UTF-8), for the interface's text fields; past the
	// buffer's end it is dropped, which no typing between two frames reaches.
	text:     [256]u8,
	text_len: int,
	input_at: u64, // when the pointer last moved or a button went down, SDL nanoseconds: for latency
	// The right button's last press, to tell a tap (which opens the brush pie) from the
	// start of an orbit: when (SDL nanoseconds), where, and how far the pointer strayed.
	right_at:     u64,
	right_from:   [2]f32,
	right_travel: f32,
	right_tap:    bool, // let go this frame within PIE_TAP and PIE_TAP_PX of its press
}

// A key that went down: its key code as the layout gives it without modifiers (SDL
// leaves them out of key events), so Shift+[ is still [.
Key_Press :: struct {
	key:    sdl.Keycode,
	mods:   bit_set[Key_Mod;u8], // Ctrl, Shift and Alt as they were when it went down
	repeat: bool,
}

// Forgets what happened last frame and keeps what is held.
device_frame_begin :: proc(d: ^Device) {
	clear(&d.keys)
	d.moved, d.pressed, d.released, d.wheel, d.right_tap, d.text_len, d.key_mods, d.cancel = {}, {}, {}, 0, false, 0, {}, false
}

// Folds one SDL event in.
device_event :: proc(d: ^Device, e: ^sdl.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		append(&d.keys, Key_Press{e.key.key, key_mods(e.key.mod), e.key.repeat})
		d.key_mods = e.key.mod
	case .TEXT_INPUT:
		typed := string(e.text.text)
		if d.text_len + len(typed) <= len(d.text) {
			copy(d.text[d.text_len:], typed)
			d.text_len += len(typed)
		}
	// Fingers never arrive as the mouse (platform_hints turns that off): touch.odin
	// moves the pointer for them. What comes as the mouse is a mouse or the pen.
	case .MOUSE_MOTION:
		d.pointer = .Pen if e.motion.which == sdl.PEN_MOUSEID else .Mouse
		device_move(d, {e.motion.x, e.motion.y})
		d.input_at = e.common.timestamp
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		d.pointer = .Pen if e.button.which == sdl.PEN_MOUSEID else .Mouse
		device_move(d, {e.button.x, e.button.y})
		if e.button.down do d.input_at = e.common.timestamp
		b: ui.Button
		switch e.button.button {
		case sdl.BUTTON_LEFT:   b = .Left
		case sdl.BUTTON_RIGHT:  b = .Right
		case sdl.BUTTON_MIDDLE: b = .Middle
		case: return
		}
		device_button(d, b, e.button.down, e.common.timestamp)
	case .MOUSE_WHEEL:
		d.wheel += e.wheel.y
	case .WINDOW_MOUSE_LEAVE:
		d.over = false
	case .PEN_PROXIMITY_OUT:
		// The pen gone hovers over nothing: no tooltip or highlight stays where it left, and
		// coming back elsewhere is no drag from there.
		if d.pointer == .Pen do d.over = false
	case .WINDOW_FOCUS_LOST:
		// What is let go while another window has the focus never arrives here.
		d.down = {}
	}
}

// Reads the modifiers once every event of the frame is in.
device_frame_end :: proc(d: ^Device) {
	mods := sdl.GetModState() | d.key_mods | d.script_mods
	d.shift, d.ctrl, d.alt = mods & sdl.KMOD_SHIFT != {}, mods & sdl.KMOD_CTRL != {}, mods & sdl.KMOD_ALT != {}
}

// The pointer moved to `to` (window coordinates). A `jump` is the pointer landing
// somewhere new (a finger touching down far from where the last one lifted), which no
// drag may count as movement.
device_move :: proc(d: ^Device, to: [2]f32, jump := false) {
	if d.over && !jump do d.moved += to - d.mouse
	d.mouse, d.over = to, true
	if .Right in d.down do d.right_travel = max(d.right_travel, linalg.length(to - d.right_from))
}

// A button went down or up at `at` (SDL nanoseconds).
device_button :: proc(d: ^Device, b: ui.Button, down: bool, at: u64) {
	if down {
		d.pressed += {b}
		d.down += {b}
		if b == .Right do d.right_at, d.right_from, d.right_travel = at, d.mouse, 0
		return
	}
	d.released += {b}
	d.down -= {b}
	if b == .Right do d.right_tap = time.Duration(at - d.right_at) < PIE_TAP && d.right_travel < PIE_TAP_PX
}

// Whether the pointer is somewhere to show hover feedback and the brush outline: a mouse
// and a pen hover, a finger only points while it touches (and in the frame it lifts, so
// the release still lands where it was).
device_pointing :: proc(d: ^Device) -> bool {
	return d.over && (d.pointer != .Finger || d.down != {} || d.released != {})
}

// Whether `key` went down this frame; with `repeat`, a held key's repeats count too.
key_pressed :: proc(d: ^Device, key: sdl.Keycode, repeat := false) -> bool {
	for k in d.keys do if k.key == key && (repeat || !k.repeat) do return true
	return false
}
