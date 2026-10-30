package main

import sdl "vendor:sdl3"

import "../ui"

// Name every control (the Help overlay, after round 3's mHelp screen): every control on
// screen gets a yellow tag with its name and its key or gesture (ui/labels.odin, from the
// controls' own tooltips), and the view gets tags for what its gestures do, so the whole
// screen can be read at a glance. Holding ? shows them while it is held, as a keyboard
// app's cheat sheet does; a quick tap of ?, the command (Search, Help's button, a gesture
// or a pie) keeps them until Done, Escape or ? again. Nothing is blocked meanwhile: a tap
// on a control tries it and the tags stay, which is how the screen is learnt by doing.

Help_Labels :: struct {
	latched:  bool, // kept on by the command or a tap of ?
	key_held: bool, // ? is down
	key_at:   f64, // when ? went down, on the kit's clock
	key_off:  bool, // this press of ? turned latched tags off: its release does nothing
	shows:    int, // how many times they were turned on, for the exit stats
}

// A press of ? shorter than this keeps the tags on after it; a longer one was a hold.
LABELS_TAP :: 0.35

// Whether the tags show now.
help_labels_on :: proc(k: ^Kit_State) -> bool {
	return k.labels.latched || k.labels.key_held
}

// Turns the kept tags on or off (the command).
help_labels_toggle :: proc(app: ^App) {
	l := &app.kit.labels
	l.latched = !l.latched
	if l.latched do l.shows += 1
}

// ? going down or up, taken from the events before the keymap sees them: true when the
// event was the tags'. ? is Shift with / on most keyboards (SDL may report it either way);
// a press while typing is the text's, and the release follows the press it belongs to.
help_labels_key :: proc(app: ^App, e: ^sdl.Event) -> bool {
	if e.type != .KEY_DOWN && e.type != .KEY_UP do return false
	l := &app.kit.labels
	if e.type == .KEY_UP {
		if e.key.scancode != .SLASH || !(l.key_held || l.key_off) do return false
		if l.key_held && app.kit.ctx.time - l.key_at < LABELS_TAP do l.latched = true
		l.key_held, l.key_off = false, false
		return true
	}
	question := e.key.key == sdl.K_QUESTION || (e.key.key == sdl.K_SLASH && e.key.mod & sdl.KMOD_SHIFT != {})
	if !question || typing(app) do return false
	if e.key.repeat do return true
	if l.latched {
		l.latched, l.key_off = false, true
		return true
	}
	l.key_held, l.key_at = true, app.kit.ctx.time
	l.shows += 1
	return true
}

// The frame's part before the panels: the kit told whether the tags show (never over
// the Home screen, clean view or Input diagnostics, `shown` false), Escape taking kept
// ones down, the view dimmed under the panels (it takes no input, so a stroke still
// lands) and its gestures tagged.
help_labels_frame :: proc(app: ^App, shown := true) {
	k := &app.kit
	ctx := &k.ctx
	if k.labels.latched && key_pressed(&app.device, sdl.K_ESCAPE) do k.labels.latched = false
	on := help_labels_on(k) && shown
	ui.labels_show(ctx, on)
	ctx.labels.clear = {}
	if !on do return
	win := ctx.input.window
	ui.begin_at(ctx, "help labels dim", {0, 0}, {width = win.x, height = win.y, inert = true})
	ui.fill_rect(ctx, {0, 0, win.x, win.y}, 0, {8, 9, 11, 96})
	ui.end(ctx)
	// The view's gestures, beside its middle, worded for the pointer in use.
	mid := win * 0.5
	for g, i in help_view_gestures(app) {
		ui.label_add(ctx, ui.salt(ui.hash_under(0, "help label gesture"), u64(i)), {mid.x - 150, mid.y + f32(i) * 34 - 40, 1, 1}, g[0], g[1], clip = false)
	}
}

// What the view does under the pointer in use: its name and the gesture, as the first-run
// tips word them (kit_coach.odin), short enough for a tag.
help_view_gestures :: proc(app: ^App) -> [3][2]string {
	nav := &app.nav
	switch coach_pointer(app) {
	case .Finger:
		sculpt := "draw on the model" if finger_model_now(app) == .Sculpt else "draw with the pen"
		turn := "one finger anywhere" if finger_model_now(app) == .Orbit else "one finger off the model"
		move := "two fingers, pinch" if nav.two_finger_pan && nav.pinch_zoom else "two fingers"
		return {{"Sculpt", sculpt}, {"Turn the view", turn}, {"Move · zoom", move}}
	case .Pen:
		turn := "pen on empty space" if nav.empty_drag[.Pen] == .Orbit else "pen in from the edge" if nav.edge_orbit else "right drag"
		return {{"Sculpt", "draw on the model"}, {"Turn the view", turn}, {"Move · zoom", "middle drag, wheel"}}
	case .Mouse:
	}
	turn := "left drag off the model" if nav.empty_drag[.Mouse] == .Orbit else "right drag, Alt+drag"
	return {{"Sculpt", "left drag on the model"}, {"Turn the view", turn}, {"Move · zoom", "middle drag, wheel"}}
}

// The note under the top bar while the tags show: what they are and how they go, with
// Done while they are kept on. The tags keep clear of it.
kit_help_labels_note :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if !help_labels_on(k) do return
	t := ctx.theme
	safe := ui.safe_area(ctx)
	W :: f32(380)
	H :: f32(64)
	at := [2]f32{safe.x + (safe.w - W) * 0.5, safe.y + kit_top() + 82}
	ctx.labels.clear = {at.x, at.y, W, H}
	ui.begin_at(ctx, "help labels note", at, {direction = .Row, gap = 10, padding = 12, width = W, height = H, radius = t.radius_large, background = .Panel, center = true})
	defer ui.end(ctx)
	glyph := ui.place(ctx, {24, 24})
	ui.icon(ctx, ui.ICON_TAG, {glyph.x + 12, glyph.y + 12}, 18, t.text)
	ui.begin(ctx, "help labels note words", {direction = .Column, gap = 2, width = W - 24 - 10 - 24 - (90 if k.labels.latched else 0)})
	ui.label(ctx, "Every control, named", t.text_size, t.text, .Semibold)
	ui.label(ctx, "Tap anything to try it" if k.labels.latched else "Let go of ? to put them away", t.small_size, t.text_secondary)
	ui.end(ctx)
	if k.labels.latched && ui.button(ctx, "Done##help labels", .Solid, .Accent, width = 80) do k.labels.latched = false
}
