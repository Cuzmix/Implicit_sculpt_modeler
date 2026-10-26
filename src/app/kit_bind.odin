package main

import "core:fmt"
import sdl "vendor:sdl3"

import "../ui"

// Bind where you see it: Ctrl+Alt+click a panel control that runs a command (or the
// palette's Assign key) opens a popover beside it that takes the next key pressed as the
// command's shortcut, as ZBrush's Ctrl+Alt+click and Blender's Assign Shortcut do. A key
// another command has is a question asked in place: move it here, or keep it there.

Bind_State :: enum u8 {
	Listening, // waiting for a key
	Assigned, // the key pressed is the command's now
	Taken, // the key pressed runs another command: move it or keep it
	Refused, // the key pressed cannot be bound (chord_reserved), `reason` says why
}

Bind_Popover :: struct {
	open:   bool,
	id:     Command_Id,
	arg:    int,
	at:     ui.Rect, // the control it was opened from
	state:  Bind_State,
	chord:  Chord, // the key pressed
	other:  Binding, // what has it (Taken), or what lost it to this command (Assigned)
	lost:   bool, // Assigned: `other` has no key now
	reason: string, // Refused: a constant from chord_reserved
	// Opened from a row of Settings > Keys, which moves `at` as the list scrolls and
	// closes it when the row goes out of view.
	from_keys: bool,
}

// Whether a click now is the gesture that binds rather than runs: exactly Ctrl and Alt
// held while the layout handles a widget's click (a key that runs a command is no click).
bind_click :: proc(app: ^App) -> bool {
	d := &app.device
	return app.kit.laying_out && app.kit.ctx.clicked_now && d.ctrl && d.alt && !d.shift
}

// Opens the popover for command `id` (with `arg`) beside `at`, closing whatever else
// floats, as the palette does.
bind_open :: proc(app: ^App, id: Command_Id, arg: int, at: ui.Rect) {
	k := &app.kit
	if k.palette do palette_close(app)
	kit_floats_close(k)
	k.bind = {open = true, id = id, arg = arg, at = at}
}

// The popover. While it is open the shortcuts, S and U and Space are off (typing), and
// the next key that goes down is read here.
kit_bind_popover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.bind
	if !ui.popover_begin(ctx, "assign key", &b.open, b.at, .Below, {direction = .Column, gap = 4, padding = 12, width = 340}) do return
	defer ui.popover_end(ctx)
	if b.open && b.state != .Taken do bind_listen(app)

	ui.begin(ctx, "assign head", {direction = .Row, center = true})
	ui.begin(ctx, "assign title", {direction = .Column, width = 340 - 24 - ctx.theme.target})
	ui.caption(ctx, "ASSIGN KEY")
	ui.label(ctx, command_label(b.id, b.arg), font = .Semibold, color = ctx.theme.text)
	ui.end(ctx)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do b.open = false
	ui.end(ctx)
	now := command_chords(app, b.id, b.arg)
	ui.value_row(ctx, "Now", now if now != "" else "No key")

	// What happened to the last key pressed, in the text's own colour: it is the answer.
	strong := ctx.theme.text
	switch b.state {
	case .Listening:
		ui.paragraph(ctx, "Press a key, with Ctrl, Shift or Alt if you like.", color = strong)
	case .Assigned:
		text := fmt.tprintf("%s now runs %s.", chord_text(b.chord), command_label(b.id, b.arg))
		if b.lost do text = fmt.tprintf("%s %s has no key now.", text, command_label(b.other.command, b.other.arg))
		ui.paragraph(ctx, fmt.tprintf("%s Press another key to change it.", text), color = strong)
	case .Taken:
		ui.paragraph(ctx, fmt.tprintf("%s runs %s.", chord_text(b.chord), command_label(b.other.command, b.other.arg)), color = strong)
		move, keep := kit_button_pair(ctx, "Use it here", "Keep it there", tone_a = .Accent)
		if move do bind_take(app)
		if keep do b.state = .Listening
	case .Refused:
		ui.paragraph(ctx, fmt.tprintf("Not %s: %s.", chord_text(b.chord), b.reason), color = strong)
	}
	remove, reset := kit_button_pair(ctx, "Remove key", "Reset", enabled_a = now != "", enabled_b = key_override_find(app, b.id, b.arg) >= 0)
	if remove {
		_ = bind_remove(app, b.id, b.arg)
		b.state = .Listening
		bind_saved(app)
	}
	if reset {
		bind_reset(app, b.id, b.arg)
		b.state = .Listening
		bind_saved(app)
	}
}

// Reads this frame's first key that is not a modifier: Escape and Back close the popover
// (kit_frame), the rest is offered to the command.
@(private = "file")
bind_listen :: proc(app: ^App) {
	b := &app.kit.bind
	for key in app.device.keys {
		if key.repeat do continue
		switch key.key {
		case sdl.K_ESCAPE, sdl.K_AC_BACK:
			return
		case sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LALT, sdl.K_RALT, sdl.K_LGUI, sdl.K_RGUI:
			continue
		}
		c := Chord{key = key.key, mods = key.mods}
		b.chord = c
		// The system's own modifier (Cmd, the Windows key) is no part of a chord, so a
		// press with it would bind the bare key.
		if sdl.GetModState() & sdl.KMOD_GUI != {} {
			b.state, b.reason = .Refused, "Cmd and the Windows key belong to the system"
			return
		}
		if reason, reserved := chord_reserved(c); reserved {
			b.state, b.reason = .Refused, reason
			return
		}
		if other, taken := chord_owner(app, c); taken && (other.command != b.id || other.arg != b.arg) {
			b.state, b.other = .Taken, other
			return
		}
		b.other, b.lost = {}, false
		if bind_assign(app, b.id, b.arg, c) {
			b.state = .Assigned
			bind_saved(app)
		}
		return
	}
}

// Use it here: the key the other command has becomes this one's.
@(private = "file")
bind_take :: proc(app: ^App) {
	b := &app.kit.bind
	if !bind_assign(app, b.id, b.arg, b.chord) do return
	b.state = .Assigned
	b.lost = command_chords(app, b.other.command, b.other.arg) == ""
	bind_saved(app)
}

// A change to the keys is written at once, as closing Settings writes its changes.
@(private = "file")
bind_saved :: proc(app: ^App) {
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}
