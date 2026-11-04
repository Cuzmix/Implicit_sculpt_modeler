package main

import "core:fmt"
import "core:strings"

import "../ui"

// Settings' sections, each a list of blocks (settings_blocks.odin), and the sheet (round 2
// of the mockups, screen settings2): the sections down its side under Search settings, as
// a desktop app's preferences window and a tablet app's settings both lay them out, and
// the section's blocks beside them, with Reset (the section's) at the end of its blocks
// and Reset all settings at the side's foot. Touch lists every gesture as a row with what
// it does, so the touch model is never hidden. A window too narrow for the columns gets
// a sheet that drills down into the same sections (kit_settings).

Settings_Section :: enum u8 {
	Interface,
	Camera,
	Touch,
	Pen,
	Dial,
	Performance,
	Frame_Rate,
	Bars,
	Files,
	Shortcuts,
}

@(rodata)
SETTINGS_SECTION_NAMES := [Settings_Section]string {
	.Interface   = "Interface",
	.Camera      = "Camera",
	.Touch       = "Touch",
	.Pen         = "Pen",
	.Dial        = "Dial",
	.Performance = "Performance",
	.Frame_Rate  = "Frame rate",
	.Bars        = "Bars",
	.Files       = "Files",
	.Shortcuts   = "Shortcuts",
}

@(rodata)
SETTINGS_INTERFACE := [?]Settings_Entry {
	{.Look, "LOOK"},
	{.Size, "SIZE"},
	{.Hands, "SCREEN LAYOUT"},
	{.Top_Bar, "TOP BAR"},
	{.Motion, "MOTION"},
	{.Starting, "STARTING"},
	{.Brush_Ring, "BRUSH RING"},
	{.Symmetry_Line, "SYMMETRY"},
	{.View_Grid, "VIEW GRID"},
	{.Inspector, "CARDS"},
	{.Panel_Places, "PANEL PLACES"},
}
@(rodata)
SETTINGS_TOUCH := [?]Settings_Entry {
	{.Hold, ""},
	{.Gesture_List, "GESTURES"},
	{.Gesture_More, ""},
	{.Finger_Sculpts, "PALM AND PEN"},
	{.Touch_Strength, ""},
	{.Shapes, "SHAPES"},
}
@(rodata)
SETTINGS_PEN := [?]Settings_Entry{{.Pen_Empty, "ON EMPTY SPACE"}, {.Pen_Objects, "OTHER OBJECTS"}, {.Pen_Tips, "HOVER"}, {.Pen_Predict, "CURSOR"}, {.Pen_Buttons, "PENCIL AND BUTTONS"}, {.Pen_Areas, "WHERE THE PEN POINTS"}}
@(rodata)
SETTINGS_DIAL := [?]Settings_Entry{{.Wheel, "DIAL"}, {.Clean_Dial, ""}}
@(rodata)
SETTINGS_PERFORMANCE := [?]Settings_Entry{{.Statistics, "STATISTICS"}, {.Anti_Aliasing, "DISPLAY"}, {.Graphics, ""}}
@(rodata)
SETTINGS_FRAME_RATE := [?]Settings_Entry{{.Frame_Rate, ""}}
@(rodata)
SETTINGS_BARS := [?]Settings_Entry{{.Bars, "BARS"}, {.Action_Bar, "ACTION BAR"}, {.Pies, "PIES"}}
@(rodata)
SETTINGS_FILES := [?]Settings_Entry{{.Autosave, "AUTOSAVE"}, {.Crash_Log, "CRASH LOG"}, {.Earlier_Saves, "EARLIER SAVES"}, {.Undo_History, "UNDO HISTORY"}, {.History_Steps, "WHAT BECOMES A STEP"}, {.History_Back, "GOING BACK"}, {.Blender_Link, "BLENDER LINK"}, {.Send_Scenes, "SEND SCENES"}, {.Printer, "3D PRINTER"}}

// Section `s`'s blocks.
settings_section_entries :: proc(s: Settings_Section) -> []Settings_Entry {
	switch s {
	case .Interface:   return SETTINGS_INTERFACE[:]
	case .Camera:      return SETTINGS_CAMERA[:]
	case .Touch:       return SETTINGS_TOUCH[:]
	case .Pen:         return SETTINGS_PEN[:]
	case .Dial:        return SETTINGS_DIAL[:]
	case .Performance: return SETTINGS_PERFORMANCE[:]
	case .Frame_Rate:  return SETTINGS_FRAME_RATE[:]
	case .Bars:        return SETTINGS_BARS[:]
	case .Files:       return SETTINGS_FILES[:]
	case .Shortcuts:   return SETTINGS_KEYS[:]
	}
	return nil
}

// Whether section `s` has a block that search `q` (lower case) finds.
settings_section_matches :: proc(s: Settings_Section, q: string) -> bool {
	name := strings.to_lower(SETTINGS_SECTION_NAMES[s], context.temp_allocator)
	for e in settings_section_entries(s) do if settings_block_shown(e.block) && settings_entry_matches(e, q, name) do return true
	return false
}

// What Search settings holds, trimmed and in lower case.
settings_query :: proc(k: ^Kit_State) -> string {
	return strings.to_lower(strings.trim_space(string(cstring(&k.settings_find[0]))), context.temp_allocator)
}

// The sections Search settings finds, for the exit stats: "all" with no search, "none"
// when it finds nothing.
settings_found_text :: proc(k: ^Kit_State) -> string {
	q := settings_query(k)
	if q == "" do return "all"
	b := strings.builder_make(context.temp_allocator)
	for s in Settings_Section {
		if !settings_section_matches(s, q) do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprint(&b, s)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}

// Puts section `s` back as a fresh install has it.
settings_section_reset :: proc(app: ^App, s: Settings_Section) {
	for e in settings_section_entries(s) do settings_block_reset(app, e.block)
}

// The sheet's width, its height at most and its side column's width.
SETTINGS_SHEET_W :: 780
SETTINGS_SHEET_H :: 600
SETTINGS_SHEET_SIDE :: 190

// The sheet as wide as it asks: the sections down its side, the open one beside them,
// `inner` wide and `height` tall, scrolling as sheet `id`'s.
settings_columns :: proc(app: ^App, id: ui.Id, inner, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	GAP :: 16
	body_w := inner - SETTINGS_SHEET_SIDE - GAP
	q := settings_query(k)
	// A search that leaves the section open without a match moves to the first that has one.
	if q != "" && !settings_section_matches(k.settings_section, q) {
		for s in Settings_Section do if settings_section_matches(s, q) {
			k.settings_section, k.settings_scroll = s, 0
			break
		}
	}

	ui.begin(ctx, "settings columns", {direction = .Row, gap = GAP})
	// The side: the search, the sections, and the resets at its foot.
	ui.begin(ctx, "settings side", {direction = .Column, gap = 0, width = SETTINGS_SHEET_SIDE, height = height})
	_ = ui.text_field(ctx, "Search settings##sheet", k.settings_find[:], SETTINGS_SHEET_SIDE, hint = "Search settings")
	ui.spacer(ctx, 8)
	// The sections scroll when the window is too short for them all, Reset all settings
	// staying at the foot.
	rows := kit_scroll_begin(ctx, "settings sections", &k.settings_side_scroll, id, SETTINGS_SHEET_SIDE, height - 2 * t.target - 16, 0)
	found := 0
	for s in Settings_Section {
		if q != "" && !settings_section_matches(s, q) do continue
		found += 1
		if ui.list_row(ctx, fmt.tprintf("%s##settings section", SETTINGS_SECTION_NAMES[s]), selected = s == k.settings_section).clicked && s != k.settings_section {
			k.settings_section, k.settings_scroll = s, 0
		}
	}
	if found == 0 do ui.paragraph(ctx, "No setting has that name.")
	kit_scroll_end(ctx, rows)
	ui.spacer(ctx, 8)
	if settings_wipe_button(app, SETTINGS_SHEET_SIDE) do settings_reset_all(app)
	ui.end(ctx)

	// The section: its name, then its blocks in a scroll.
	ui.begin(ctx, "settings section", {direction = .Column, gap = 8, width = body_w, height = height})
	head := ui.place(ctx, {body_w, t.target})
	ui.text(ctx, SETTINGS_SECTION_NAMES[k.settings_section], head.x, head.y + head.h * 0.5, t.heading_size, t.text, .Semibold)
	scroll := kit_scroll_begin(ctx, "settings body", &k.settings_scroll, id, body_w, height - t.target - 8, 4)
	k.settings_body = scroll.at
	name := strings.to_lower(SETTINGS_SECTION_NAMES[k.settings_section], context.temp_allocator)
	settings_entries_draw(app, settings_section_entries(k.settings_section), q, name)
	ui.spacer(ctx, 8)
	if ui.button(ctx, fmt.tprintf("Reset %s settings", SETTINGS_SECTION_NAMES[k.settings_section]), .Bordered) do settings_section_reset(app, k.settings_section)
	kit_scroll_end(ctx, scroll)
	ui.end(ctx)
	ui.end(ctx)
}

// The width of a gesture row's choice, on the row's right.
GESTURE_CHOICE_W :: 220

// Touch's GESTURES in Lens: each gesture a row naming it, with what it does on the right
// to change there: one finger on the model, on empty space, two and three fingers, then
// the gesture map's taps, holds and the pen's side button.
lens_gesture_list :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	n := &app.nav
	width := ui.fill_width(ctx)

	if picked := gesture_row(ctx, "One finger on the model", {"Sculpt", "Turn the view"}, int(n.finger_model), width); picked >= 0 do n.finger_model = Finger_Model(picked)
	pencil_only_note(app)
	if picked := gesture_row(ctx, "One finger tap on another object", {"Switch to it", "Same as on the model"}, 0 if n.tap_switches else 1, width); picked >= 0 do n.tap_switches = picked == 0
	gesture_row_text(ctx, "One finger on empty space", "Turns the view", width)
	// Two fingers always move the view; what else they do is one choice of three, or the
	// switches' own mix when a settings file from before this list holds one these name none of.
	two := [?]string{"Pan, zoom and roll", "Pan and zoom", "Pan only", "Zoom and roll"}
	at := -1
	switch {
	case n.two_finger_pan && n.pinch_zoom && n.twist_roll:   at = 0
	case n.two_finger_pan && n.pinch_zoom && !n.twist_roll:  at = 1
	case n.two_finger_pan && !n.pinch_zoom && !n.twist_roll: at = 2
	case !n.two_finger_pan && n.pinch_zoom && n.twist_roll:  at = 3
	}
	options := two[:]
	if at < 0 {
		mixed := make([]string, len(two) + 1, context.temp_allocator)
		copy(mixed, two[:])
		mixed[len(two)] = "Own mix"
		options, at = mixed, len(two)
	}
	if picked := gesture_row(ctx, "Two fingers", options, at, width); picked >= 0 && picked < len(two) {
		n.two_finger_pan, n.pinch_zoom, n.twist_roll = picked != 3, picked != 2, picked == 0 || picked == 3
	}
	if n.twist_roll && !twist_rolls(n^) do ui.paragraph(ctx, "Rolling needs the Trackball orbit style, or Twist two fingers to roll the turntable (Camera).")
	if picked := gesture_row(ctx, "Three fingers drag", {"Size and focal shift", "Nothing"}, 0 if n.three_finger else 1, width); picked >= 0 do n.three_finger = picked == 0
	for slot in GESTURE_SLOT_ORDER {
		if slot in PENCIL_SLOTS do continue
		ui.begin(ctx, fmt.tprintf("gesture row %v", slot), {direction = .Row, center = true, width = width})
		r := ui.place(ctx, {width - GESTURE_CHOICE_W, t.target})
		ui.text(ctx, GESTURE_SLOT_NAMES[slot], r.x, r.y + r.h * 0.5, t.text_size, t.text, .Regular)
		gesture_select(app, slot, GESTURE_CHOICE_W)
		ui.end(ctx)
	}
	ui.paragraph(ctx, "A hold fills a ring, then runs its command; Undo and Redo go on repeating while the fingers stay still. Never while the pen is near. The one-finger tap is a tap on empty space: on the model a tap sculpts.")
	for note in gesture_notes(app) do ui.paragraph(ctx, note, color = t.warning)
}

// A gesture row: its name on the left, the choice of `options` on the right. Returns the
// option picked, or -1.
@(private = "file")
gesture_row :: proc(ctx: ^ui.Context, label: string, options: []string, chosen: int, width: f32) -> int {
	t := ctx.theme
	ui.begin(ctx, fmt.tprintf("gesture row %s", label), {direction = .Row, center = true, width = width})
	r := ui.place(ctx, {width - GESTURE_CHOICE_W, t.target})
	ui.text(ctx, label, r.x, r.y + r.h * 0.5, t.text_size, t.text, .Regular)
	picked := ui.select(ctx, fmt.tprintf("%s##gesture row", label), options, chosen, GESTURE_CHOICE_W)
	ui.end(ctx)
	return picked
}

// A gesture row whose behaviour is fixed: its name and what it does, as text.
@(private = "file")
gesture_row_text :: proc(ctx: ^ui.Context, label, does: string, width: f32) {
	t := ctx.theme
	r := ui.place(ctx, {width, t.target})
	ui.text(ctx, label, r.x, r.y + r.h * 0.5, t.text_size, t.text, .Regular)
	ui.text(ctx, does, r.x + r.w - 12, r.y + r.h * 0.5, t.small_size, t.text_secondary, .Regular, .Right)
}
