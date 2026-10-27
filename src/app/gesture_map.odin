package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The gesture map (Settings > Touch): what the multi-finger taps and holds and the pen's
// side button run, each any of the commands a hand without a keyboard reaches for, as
// Nomad's gesture settings let them be chosen. A gesture holds one command, so two never
// collide; where one overlaps the system or another gesture, a note under the map says so.

Gesture_Slot :: enum u8 {
	Two_Tap,
	Three_Tap,
	Four_Tap, // four or more fingers
	Two_Hold,
	Three_Hold,
	Four_Hold,
	Pen_Button, // the pen's side button, which SDL sends as a right click from the pen
	// A finger's tap on empty space (never on the model, where it sculpts, nor in the safe
	// zone). Last, so the taps and holds above keep their places.
	One_Tap,
}

// The order Settings lists the slots in: the taps by fingers, the holds, the pen.
@(rodata)
GESTURE_SLOT_ORDER := [Gesture_Slot]Gesture_Slot {
	.Two_Tap    = .One_Tap,
	.Three_Tap  = .Two_Tap,
	.Four_Tap   = .Three_Tap,
	.Two_Hold   = .Four_Tap,
	.Three_Hold = .Two_Hold,
	.Four_Hold  = .Three_Hold,
	.Pen_Button = .Four_Hold,
	.One_Tap    = .Pen_Button,
}

GESTURE_SLOT_NAMES := [Gesture_Slot]string {
	.Two_Tap    = "Two-finger tap",
	.Three_Tap  = "Three-finger tap",
	.Four_Tap   = "Four-finger tap",
	.Two_Hold   = "Hold two fingers",
	.Three_Hold = "Hold three fingers",
	.Four_Hold  = "Hold four fingers",
	.Pen_Button = "Pen side button",
	.One_Tap    = "One-finger tap",
}

GESTURE_DEFAULTS :: [Gesture_Slot]Pie_Slot {
	.Two_Tap    = {.Undo, 0},
	.Three_Tap  = {.Redo, 0},
	.Four_Tap   = {},
	.Two_Hold   = {.Undo, 0},
	.Three_Hold = {.Redo, 0},
	.Four_Hold  = {},
	.Pen_Button = {.Brush_Pie, 0},
	.One_Tap    = {},
}

// What a gesture's select lists in Settings: what a tablet without a keyboard reaches for,
// as the reference app's tap actions (subdivide, levels, solo, polyframe, symmetry, the
// mask and hiding, a new group, dynamic topology, render). Any other command a gesture may
// hold (gesture_lists) is one search away (Any command...), and the select then lists it
// too.
@(rodata)
GESTURE_CHOICES := [?]Pie_Slot {
	{.Undo, 0}, {.Redo, 0}, {.Brush_Pie, 0}, {.Pie, 0}, {.Pie, 1}, {.Pie, 2}, {.Pie, 3}, {.Command_Palette, 0},
	{.Inspector, 0}, {.Objects_Card, 0}, {.Settings, 0}, {.Help, 0}, {.Stats, 0},
	{.Frame_All, 0}, {.Focus_Selected, 0}, {.Reset_Camera, 0}, {.View_Back, 0}, {.View_Forward, 0}, {.Ortho_Toggle, 0},
	{.Wireframe, 0}, {.Polygroups, 0}, {.Flat_Shading, 0}, {.Studio_Render, 0}, {.Screenshot, 0}, {.Symmetry_X, 0},
	{.Solo_Object, 0}, {.Show_All_Objects, 0}, {.New_Folder, 0},
	{.Subdivide, 0}, {.Level_Up, 0}, {.Level_Down, 0}, {.Remesh, 0}, {.Dyntopo_Toggle, 0}, {.Adjust_Last, 0},
	{.Mask, int(sculpt.Mask_Command.Invert)}, {.Mask, int(sculpt.Mask_Command.Clear)}, {.Mask, int(sculpt.Mask_Command.Blur)},
	{.Mask, int(sculpt.Mask_Command.Sharpen)}, {.Mask, int(sculpt.Mask_Command.Grow)}, {.Mask, int(sculpt.Mask_Command.Shrink)},
	{.Show_All, 0}, {.Invert_Hidden, 0}, {.Hide_Masked, 0}, {.Hide_Unmasked, 0},
	{.Group, int(sculpt.Group_Command.Masked)}, {.Group, int(sculpt.Group_Command.Visible)},
	{.Tool_Move, 0}, {.Tool_Sculpt, 0},
}

// Whether a gesture may hold `id`: any command the palette lists, and the palette itself.
gesture_lists :: proc(id: Command_Id) -> bool {
	return palette_lists(id) || id == .Command_Palette
}

// The tap or hold slot for a gesture of `fingers` (2 or more).
gesture_slot :: proc(fingers: int, hold: bool) -> Gesture_Slot {
	switch {
	case fingers <= 2: return .Two_Hold if hold else .Two_Tap
	case fingers == 3: return .Three_Hold if hold else .Three_Tap
	}
	return .Four_Hold if hold else .Four_Tap
}

// Whether a hold repeats its command while the fingers stay (Undo and Redo step through
// the History); any other runs once.
gesture_repeats :: proc(s: Pie_Slot) -> bool {
	return s.id == .Undo || s.id == .Redo
}

// Runs what the gesture holds; false when it holds nothing or its command cannot run now.
gesture_run :: proc(app: ^App, slot: Gesture_Slot) -> bool {
	s := app.nav.gestures[slot]
	if s.id == .None do return false
	// A gesture never lands mid-stroke: a stroke the touch began ends first.
	stroke_finish(app)
	return command_run(app, s.id, s.arg)
}

// The gestures that run the command, as its tooltip and Help say them: "Two-finger tap,
// hold to repeat", "Hold three fingers still", "Pen side button"; "" for none.
gesture_text :: proc(app: ^App, id: Command_Id, arg: int) -> string {
	if id == .None do return ""
	is :: proc(app: ^App, slot: Gesture_Slot, id: Command_Id, arg: int) -> bool {
		s := app.nav.gestures[slot]
		return s.id == id && s.arg == arg
	}
	b := strings.builder_make(context.temp_allocator)
	COUNTS := [3]string{"two", "three", "four"}
	for n in 0 ..< 3 {
		tap, hold := is(app, Gesture_Slot(n), id, arg), is(app, Gesture_Slot(n + 3), id, arg)
		if !tap && !hold do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
		count := COUNTS[n]
		switch {
		case tap && hold:
			fmt.sbprintf(&b, "%s%s-finger tap, %s", strings.to_upper(count[:1], context.temp_allocator), count[1:], "hold to repeat" if gesture_repeats({id, arg}) else "or hold")
		case tap:
			fmt.sbprintf(&b, "%s%s-finger tap", strings.to_upper(count[:1], context.temp_allocator), count[1:])
		case hold:
			fmt.sbprintf(&b, "Hold %s fingers still", count)
		}
	}
	if is(app, .Pen_Button, id, arg) {
		if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "Pen side button")
	}
	if is(app, .One_Tap, id, arg) {
		if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "One-finger tap on empty space")
	}
	return strings.to_string(b)
}

// What the map overlaps, said under it in Settings > Touch: never a silent conflict.
gesture_notes :: proc(app: ^App) -> []string {
	g := &app.nav.gestures
	out := make([dynamic]string, 0, 6, context.temp_allocator)
	if g[.Four_Tap].id != .None || g[.Four_Hold].id != .None {
		append(&out, "Some tablets keep three- and four-finger touches for the system (Windows' touch gestures, some Android skins): if one does nothing here, turn the system's off.")
	}
	if g[.One_Tap].id != .None && app.nav.double_tap {
		append(&out, "A one-finger tap waits 0.3 s before it runs, in case a second tap makes it a double tap (Double tap to frame, above).")
	}
	if g[.Pen_Button] != {.Brush_Pie, 0} {
		append(&out, "The pen's side button no longer opens the brush pie: Space, the mouse's right click and Search still do.")
	}
	for slot in ([?]Gesture_Slot{.Two_Hold, .Three_Hold, .Four_Hold}) {
		s := g[slot]
		if s.id != .None && !gesture_repeats(s) do append(&out, fmt.tprintf("%s runs %s once when its ring fills; only Undo and Redo repeat.", GESTURE_SLOT_NAMES[slot], pie_slot_label(s)))
	}
	// The default hold and the lift have always shared the start; a command of the user's
	// own there is worth saying.
	defaults := GESTURE_DEFAULTS
	if g[.Two_Hold].id != .None && g[.Two_Hold] != defaults[.Two_Hold] && app.nav.lift_one_orbit {
		append(&out, "Hold two fingers and Lift one of two fingers to turn start alike: lifting one before the ring fills turns the view.")
	}
	for a in Gesture_Slot {
		for b in Gesture_Slot {
			if b <= a || g[a].id == .None || g[a] != g[b] do continue
			// A tap and its own hold running Undo or Redo is the usual pair, not news.
			if gesture_repeats(g[a]) && int(b) == int(a) + 3 do continue
			append(&out, fmt.tprintf("%s and %s both run %s.", GESTURE_SLOT_NAMES[a], GESTURE_SLOT_NAMES[b], pie_slot_label(g[a])))
		}
	}
	return out[:]
}

// The map's rows in Settings > Touch, then its notes.
settings_gesture_map :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.caption(ctx, "GESTURE MAP")
	for slot in GESTURE_SLOT_ORDER {
		s := &app.nav.gestures[slot]
		choices := make([dynamic]Pie_Slot, 0, len(GESTURE_CHOICES) + 2, context.temp_allocator)
		append(&choices, Pie_Slot{})
		append(&choices, ..GESTURE_CHOICES[:])
		chosen := -1
		for c, i in choices do if c == s^ {chosen = i; break}
		if chosen < 0 {
			append(&choices, s^)
			chosen = len(choices) - 1
		}
		// Last, a row that is no command: it opens the palette to choose any.
		names := make([]string, len(choices) + 1, context.temp_allocator)
		for c, i in choices do names[i] = "Nothing" if c.id == .None else pie_slot_label(c)
		names[len(choices)] = "Any command..."
		ui.label(ctx, GESTURE_SLOT_NAMES[slot])
		if picked := ui.select(ctx, fmt.tprintf("%s##gesture", GESTURE_SLOT_NAMES[slot]), names, chosen); picked >= 0 {
			if picked < len(choices) do s^ = choices[picked]
			else do palette_open_for(app, slot)
		}
	}
	ui.paragraph(ctx, "A hold fills a ring, then runs its command; Undo and Redo go on repeating while the fingers stay still. Never while the pen is near. The one-finger tap is a tap on empty space: on the model a tap sculpts.")
	for note in gesture_notes(app) do ui.paragraph(ctx, note, color = t.warning)
}
