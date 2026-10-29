package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The gesture map (Settings > Touch): what the multi-finger taps and holds and the pen's
// side button run (and, in Settings > Pen, the pencil's double-tap and squeeze and the
// pen's second button: pencil.odin), each any of the commands a hand without a keyboard reaches for, as
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
	// zone). After the slots above, so they keep their places.
	One_Tap,
	// The pen's own (pencil.odin), listed in Settings > Pen rather than the map: its second
	// barrel button, and an Apple Pencil's double-tap and squeeze.
	Pen_Button_2,
	Pen_Double_Tap,
	Pen_Squeeze,
	// The pencil's double-tap and squeeze while it points at empty space (pen_roll.odin);
	// the two above are theirs over the model.
	Pen_Double_Tap_Empty,
	Pen_Squeeze_Empty,
	// ...and over the places of the interface that give them a meaning of their own
	// (Pen_Area), each to begin with As over empty space or its own.
	Pen_Double_Tap_Shelf,
	Pen_Squeeze_Shelf,
	Pen_Double_Tap_Panels,
	Pen_Squeeze_Panels,
	Pen_Double_Tap_History,
	Pen_Squeeze_History,
	Pen_Double_Tap_Nav_Head,
	Pen_Squeeze_Nav_Head,
	Pen_Double_Tap_Colors,
	Pen_Squeeze_Colors,
	// The pen's buttons by where it points, for pens with no roll or squeeze (Android's,
	// Windows'): the side button over empty space (over the interface it is the controls'
	// right click), and the second button over empty space and each place.
	Pen_Button_Empty,
	Pen_Button_2_Empty,
	Pen_Button_2_Shelf,
	Pen_Button_2_Panels,
	Pen_Button_2_History,
	Pen_Button_2_Nav_Head,
	Pen_Button_2_Colors,
}

// Whether the platform has the Apple Pencil's double-tap and squeeze (ios/sculpt_ios.m).
PENCIL_GESTURES :: ODIN_PLATFORM_SUBTARGET_IOS

// The Apple Pencil's double-tap and squeeze, wherever the pen points.
PENCIL_GESTURE_SLOTS :: bit_set[Gesture_Slot]{
	.Pen_Double_Tap, .Pen_Squeeze, .Pen_Double_Tap_Empty, .Pen_Squeeze_Empty, .Pen_Double_Tap_Shelf, .Pen_Squeeze_Shelf,
	.Pen_Double_Tap_Panels, .Pen_Squeeze_Panels, .Pen_Double_Tap_History, .Pen_Squeeze_History, .Pen_Double_Tap_Nav_Head,
	.Pen_Squeeze_Nav_Head, .Pen_Double_Tap_Colors, .Pen_Squeeze_Colors,
}

// The second button wherever the pen points.
PEN_BUTTON_2_SLOTS :: bit_set[Gesture_Slot]{
	.Pen_Button_2, .Pen_Button_2_Empty, .Pen_Button_2_Shelf, .Pen_Button_2_Panels, .Pen_Button_2_History, .Pen_Button_2_Nav_Head, .Pen_Button_2_Colors,
}

// The slots over the interface's places, which may do As over empty space.
PEN_PLACE_SLOTS :: bit_set[Gesture_Slot]{
	.Pen_Double_Tap_Shelf, .Pen_Squeeze_Shelf, .Pen_Double_Tap_Panels, .Pen_Squeeze_Panels, .Pen_Double_Tap_History, .Pen_Squeeze_History,
	.Pen_Double_Tap_Nav_Head, .Pen_Squeeze_Nav_Head, .Pen_Double_Tap_Colors, .Pen_Squeeze_Colors,
	.Pen_Button_2_Shelf, .Pen_Button_2_Panels, .Pen_Button_2_History, .Pen_Button_2_Nav_Head, .Pen_Button_2_Colors,
}

// The slots Settings > Pen lists instead of the gesture map.
PENCIL_SLOTS :: PENCIL_GESTURE_SLOTS + PEN_BUTTON_2_SLOTS + {.Pen_Button_Empty}

// The order Settings lists the slots in: the taps by fingers, the holds, the pen, then
// the pen's own, which the map leaves to Settings > Pen.
@(rodata)
GESTURE_SLOT_ORDER := [Gesture_Slot]Gesture_Slot {
	.Two_Tap        = .One_Tap,
	.Three_Tap      = .Two_Tap,
	.Four_Tap       = .Three_Tap,
	.Two_Hold       = .Four_Tap,
	.Three_Hold     = .Two_Hold,
	.Four_Hold      = .Three_Hold,
	.Pen_Button     = .Four_Hold,
	.One_Tap        = .Pen_Button,
	.Pen_Button_2   = .Pen_Button_2,
	.Pen_Double_Tap = .Pen_Double_Tap,
	.Pen_Squeeze    = .Pen_Squeeze,
	.Pen_Double_Tap_Empty = .Pen_Double_Tap_Empty,
	.Pen_Squeeze_Empty    = .Pen_Squeeze_Empty,
	.Pen_Double_Tap_Shelf    = .Pen_Double_Tap_Shelf,
	.Pen_Squeeze_Shelf       = .Pen_Squeeze_Shelf,
	.Pen_Double_Tap_Panels   = .Pen_Double_Tap_Panels,
	.Pen_Squeeze_Panels      = .Pen_Squeeze_Panels,
	.Pen_Double_Tap_History  = .Pen_Double_Tap_History,
	.Pen_Squeeze_History     = .Pen_Squeeze_History,
	.Pen_Double_Tap_Nav_Head = .Pen_Double_Tap_Nav_Head,
	.Pen_Squeeze_Nav_Head    = .Pen_Squeeze_Nav_Head,
	.Pen_Double_Tap_Colors   = .Pen_Double_Tap_Colors,
	.Pen_Squeeze_Colors      = .Pen_Squeeze_Colors,
	.Pen_Button_Empty        = .Pen_Button_Empty,
	.Pen_Button_2_Empty      = .Pen_Button_2_Empty,
	.Pen_Button_2_Shelf      = .Pen_Button_2_Shelf,
	.Pen_Button_2_Panels     = .Pen_Button_2_Panels,
	.Pen_Button_2_History    = .Pen_Button_2_History,
	.Pen_Button_2_Nav_Head   = .Pen_Button_2_Nav_Head,
	.Pen_Button_2_Colors     = .Pen_Button_2_Colors,
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
	.Pen_Button_2   = "Pen second button",
	.Pen_Double_Tap = "Pencil double-tap",
	.Pen_Squeeze    = "Pencil squeeze",
	.Pen_Double_Tap_Empty = "Pencil double-tap on empty space",
	.Pen_Squeeze_Empty    = "Pencil squeeze on empty space",
	.Pen_Double_Tap_Shelf    = "Pencil double-tap on the shelf",
	.Pen_Squeeze_Shelf       = "Pencil squeeze on the shelf",
	.Pen_Double_Tap_Panels   = "Pencil double-tap on a panel",
	.Pen_Squeeze_Panels      = "Pencil squeeze on a panel",
	.Pen_Double_Tap_History  = "Pencil double-tap on Undo, Redo or History",
	.Pen_Squeeze_History     = "Pencil squeeze on Undo, Redo or History",
	.Pen_Double_Tap_Nav_Head = "Pencil double-tap on the navigation head",
	.Pen_Squeeze_Nav_Head    = "Pencil squeeze on the navigation head",
	.Pen_Double_Tap_Colors   = "Pencil double-tap on the colour Disc",
	.Pen_Squeeze_Colors      = "Pencil squeeze on the colour Disc",
	.Pen_Button_Empty        = "Pen side button on empty space",
	.Pen_Button_2_Empty      = "Pen second button on empty space",
	.Pen_Button_2_Shelf      = "Pen second button on the shelf",
	.Pen_Button_2_Panels     = "Pen second button on a panel",
	.Pen_Button_2_History    = "Pen second button on Undo, Redo or History",
	.Pen_Button_2_Nav_Head   = "Pen second button on the navigation head",
	.Pen_Button_2_Colors     = "Pen second button on the colour Disc",
}

GESTURE_DEFAULTS :: [Gesture_Slot]Pie_Slot {
	.Two_Tap    = {.Undo, 0},
	.Three_Tap  = {.Redo, 0},
	.Four_Tap   = {.Clean_View, 0},
	.Two_Hold   = {.Undo, 0},
	.Three_Hold = {.Redo, 0},
	.Four_Hold  = {},
	.Pen_Button = {.Brush_Pie, 0},
	.One_Tap    = {},
	// Unmapped, the second button stays SDL's middle button, which the mouse scheme drags.
	.Pen_Button_2   = {},
	.Pen_Double_Tap = {.Pencil_Preferred, 0},
	.Pen_Squeeze    = {.Pencil_Preferred, 0},
	// Over empty space a double-tap frames the model, as a finger's double tap there does;
	// a squeeze still does what the iPad asks.
	.Pen_Double_Tap_Empty = {.Frame_All, 0},
	.Pen_Squeeze_Empty    = {.Pencil_Preferred, 0},
	// Over the interface, what each place is for: the shelf opens every brush, Undo and
	// Redo the whole History, the navigation head puts the view back, the Disc swaps the
	// two colours; the rest does what it does over empty space.
	.Pen_Double_Tap_Shelf    = {.Brush_Picker, 0},
	.Pen_Squeeze_Shelf       = {.Pen_As_Empty, 0},
	.Pen_Double_Tap_Panels   = {.Pen_As_Empty, 0},
	.Pen_Squeeze_Panels      = {.Pen_As_Empty, 0},
	.Pen_Double_Tap_History  = {.History_Panel, 0},
	.Pen_Squeeze_History     = {.Pen_As_Empty, 0},
	.Pen_Double_Tap_Nav_Head = {.Reset_Camera, 0},
	.Pen_Squeeze_Nav_Head    = {.Pen_As_Empty, 0},
	.Pen_Double_Tap_Colors   = {.Swap_Colors, 0},
	.Pen_Squeeze_Colors      = {.Pen_As_Empty, 0},
	// The buttons start as they always were, the side button the brush pie and the second
	// the middle button, everywhere.
	.Pen_Button_Empty        = {.Brush_Pie, 0},
	.Pen_Button_2_Empty      = {},
	.Pen_Button_2_Shelf      = {.Pen_As_Empty, 0},
	.Pen_Button_2_Panels     = {.Pen_As_Empty, 0},
	.Pen_Button_2_History    = {.Pen_As_Empty, 0},
	.Pen_Button_2_Nav_Head   = {.Pen_As_Empty, 0},
	.Pen_Button_2_Colors     = {.Pen_As_Empty, 0},
}

// What a gesture's select lists in Settings: what a tablet without a keyboard reaches for,
// as the reference app's tap actions (subdivide, levels, solo, polyframe, symmetry, the
// mask and hiding, a new group, dynamic topology, render). Any other command a gesture may
// hold (gesture_lists) is one search away (Any command...), and the select then lists it
// too.
@(rodata)
GESTURE_CHOICES := [?]Pie_Slot {
	{.Undo, 0}, {.Redo, 0}, {.Clean_View, 0}, {.Brush_Pie, 0}, {.Pie, 0}, {.Pie, 1}, {.Pie, 2}, {.Pie, 3}, {.Command_Palette, 0},
	{.Inspector, 0}, {.Objects_Card, 0}, {.Settings, 0}, {.Help, 0}, {.Stats, 0},
	{.Frame_All, 0}, {.Focus_Selected, 0}, {.Reset_Camera, 0}, {.View_Back, 0}, {.View_Forward, 0}, {.Ortho_Toggle, 0},
	{.Wireframe, 0}, {.Polygroups, 0}, {.Floor_Grid, 0}, {.Transparency, 0}, {.Flat_Shading, 0}, {.Studio_Render, 0}, {.Screenshot, 0}, {.Symmetry_X, 0}, {.Local_Symmetry, 0}, {.Radial_Symmetry, 0}, {.Brush_Subtract, 0}, {.Brush_Add, 0}, {.Paint_Channel, 0}, {.Swap_Colors, 0},
	{.Solo_Object, 0}, {.Show_All_Objects, 0}, {.New_Folder, 0},
	{.Subdivide, 0}, {.Level_Up, 0}, {.Level_Down, 0}, {.Remesh, 0}, {.Dyntopo_Toggle, 0}, {.Adjust_Last, 0},
	{.Mask, int(sculpt.Mask_Command.Invert)}, {.Mask, int(sculpt.Mask_Command.Clear)}, {.Mask, int(sculpt.Mask_Command.Blur)},
	{.Mask, int(sculpt.Mask_Command.Sharpen)}, {.Mask, int(sculpt.Mask_Command.Grow)}, {.Mask, int(sculpt.Mask_Command.Shrink)},
	{.Mask, int(sculpt.Mask_Command.Region)}, {.Mask_By, int(sculpt.Mask_By.Facing_Away)}, {.Mask_By, int(sculpt.Mask_By.Curvature)}, {.Mask_Adjust, 0},
	{.Show_All, 0}, {.Invert_Hidden, 0}, {.Hide_Masked, 0}, {.Hide_Unmasked, 0}, {.Grow_Visible, 0}, {.Shrink_Visible, 0},
	{.Group, int(sculpt.Group_Command.Masked)}, {.Group, int(sculpt.Group_Command.Visible)}, {.Group, int(sculpt.Group_Command.Pieces)},
	{.Tool_Move, 0}, {.Tool_Sculpt, 0},
}

// Whether a gesture may hold `id`: any command the palette lists, and the palette itself.
gesture_lists :: proc(id: Command_Id) -> bool {
	return palette_lists(id) || id == .Command_Palette || id == .Pencil_Preferred || id == .Pen_As_Empty
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
	// Input diagnostics logs the gesture (diag_event) but runs nothing: it would act on the
	// scene behind the screen, and a pie opened over it takes every press its tests count.
	if app.diag.open do return false
	// A gesture never lands mid-stroke: a stroke the touch began ends first.
	stroke_finish(app)
	return command_run(app, s.id, s.arg)
}

// The gestures that run the command, as its tooltip and Help say them: "Two-finger tap,
// hold to repeat", "Hold three fingers still", "Pen side button"; "" for none.
gesture_text :: proc(app: ^App, id: Command_Id, arg: int) -> string {
	// As over empty space is no command of its own to name.
	if id == .None || id == .Pen_As_Empty do return ""
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
	// The pen's, in the enum's order, then the one-finger tap.
	pens := make([dynamic]Gesture_Slot, 0, len(Gesture_Slot), context.temp_allocator)
	append(&pens, Gesture_Slot.Pen_Button)
	for slot in Gesture_Slot.Pen_Button_2 ..= Gesture_Slot.Pen_Button_2_Colors do append(&pens, slot)
	append(&pens, Gesture_Slot.One_Tap)
	for slot in pens {
		if !is(app, slot, id, arg) do continue
		// The Apple Pencil's own gestures only where one can be paired: elsewhere the
		// default empty-space double-tap would name itself under Frame all for nothing.
		if !PENCIL_GESTURES && slot in PENCIL_GESTURE_SLOTS do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, "One-finger tap on empty space" if slot == .One_Tap else GESTURE_SLOT_NAMES[slot])
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
	if g[.Pen_Button] != {.Brush_Pie, 0} || g[.Pen_Button_Empty] != {.Brush_Pie, 0} {
		append(&out, "The pen's side button no longer opens the brush pie everywhere: Space, the mouse's right click and Search still do.")
	}
	second_mapped := false
	for slot in PEN_BUTTON_2_SLOTS do if g[slot].id != .None && g[slot].id != .Pen_As_Empty do second_mapped = true
	if second_mapped {
		append(&out, "The pen's second button no longer acts as the middle mouse button, which some tablets' drivers make it.")
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
			// Follow the Pencil setting reads each gesture's own preference, so it is never one
			// command on two.
			if b <= a || g[a].id == .None || g[a].id == .Pencil_Preferred || g[a].id == .Pen_As_Empty || g[a] != g[b] do continue
			// A tap and its own hold running Undo or Redo is the usual pair, not news; nor is
			// one pen button or Pencil gesture doing the same in two places.
			if gesture_repeats(g[a]) && int(b) == int(a) + 3 do continue
			if pen_input(a) >= 0 && pen_input(a) == pen_input(b) do continue
			append(&out, fmt.tprintf("%s and %s both run %s.", GESTURE_SLOT_NAMES[a], GESTURE_SLOT_NAMES[b], pie_slot_label(g[a])))
		}
	}
	return out[:]
}

// Puts the map's slots back as they come, leaving Settings > Pen's own to its reset.
gesture_map_reset :: proc(n: ^Nav_Prefs) {
	defaults := GESTURE_DEFAULTS
	for slot in Gesture_Slot do if slot not_in PENCIL_SLOTS do n.gestures[slot] = defaults[slot]
}

// Which of the pen's inputs `slot` is in some place: the double-tap, squeeze, second
// button or side button by their column in PEN_AREA_SLOTS (3 the side button), else -1.
pen_input :: proc(slot: Gesture_Slot) -> int {
	if slot == .Pen_Button || slot == .Pen_Button_Empty do return 3
	for row in PEN_AREA_SLOTS do for s, column in row do if s == slot do return column
	return -1
}

// The map's rows in Settings > Touch, then its notes.
settings_gesture_map :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.caption(ctx, "GESTURE MAP")
	for slot in GESTURE_SLOT_ORDER {
		if slot in PENCIL_SLOTS do continue
		ui.label(ctx, GESTURE_SLOT_NAMES[slot])
		gesture_select(app, slot)
	}
	ui.paragraph(ctx, "A hold fills a ring, then runs its command; Undo and Redo go on repeating while the fingers stay still. Never while the pen is near. The one-finger tap is a tap on empty space: on the model a tap sculpts.")
	for note in gesture_notes(app) do ui.paragraph(ctx, note, color = t.warning)
}

// The choice of what gesture `slot` runs, `width` wide (0 fills the row): nothing, the
// usual commands, the one it runs now when it is none of those, and Any command..., which
// opens the palette to choose one.
gesture_select :: proc(app: ^App, slot: Gesture_Slot, width: f32 = 0) {
	ctx := &app.kit.ctx
	s := &app.nav.gestures[slot]
	choices := make([dynamic]Pie_Slot, 0, len(GESTURE_CHOICES) + 3, context.temp_allocator)
	append(&choices, Pie_Slot{})
	if slot in PENCIL_GESTURE_SLOTS do append(&choices, Pie_Slot{.Pencil_Preferred, 0})
	if slot in PEN_PLACE_SLOTS do append(&choices, Pie_Slot{.Pen_As_Empty, 0})
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
	if picked := ui.select(ctx, fmt.tprintf("%s##gesture", GESTURE_SLOT_NAMES[slot]), names, chosen, width, roll_count = len(choices)); picked >= 0 {
		if picked < len(choices) do s^ = choices[picked]
		else do palette_open_for(app, slot)
	}
}
