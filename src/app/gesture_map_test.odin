package main

import "core:os"
import "core:strings"
import "core:testing"

// Fingers pick their slot; four or more are the four-finger gestures.
@(test)
gesture_slots_by_fingers :: proc(t: ^testing.T) {
	testing.expect_value(t, gesture_slot(2, false), Gesture_Slot.Two_Tap)
	testing.expect_value(t, gesture_slot(3, true), Gesture_Slot.Three_Hold)
	testing.expect_value(t, gesture_slot(5, false), Gesture_Slot.Four_Tap)
	for c in GESTURE_CHOICES do testing.expectf(t, gesture_lists(c.id), "%v cannot be read back from settings", c.id)
}

// The notes say what overlaps: the system's four fingers, the pen's brush pie, a hold
// that runs once, one command on two gestures; the defaults need none.
@(test)
gesture_overlaps_are_said :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	// The four-finger tap's Clean view is the one note a fresh install has: some systems
	// keep four fingers for themselves.
	defaults := gesture_notes(&app)
	testing.expect_value(t, len(defaults), 1)
	if len(defaults) == 1 do testing.expect(t, strings.contains(defaults[0], "four-finger touches"))
	app.nav.gestures[.Four_Tap] = {.Wireframe, 0}
	app.nav.gestures[.Pen_Button] = {.Wireframe, 0}
	app.nav.gestures[.Two_Hold] = {.Command_Palette, 0}
	notes := strings.join(gesture_notes(&app), "\n", context.temp_allocator)
	testing.expect(t, strings.contains(notes, "four-finger touches"))
	testing.expect(t, strings.contains(notes, "no longer opens the brush pie"))
	testing.expect(t, strings.contains(notes, "Hold two fingers runs Search commands once"))
	testing.expect(t, strings.contains(notes, "Four-finger tap and Pen side button both run Wireframe"))
	testing.expect(t, strings.contains(notes, "Lift one of two fingers to turn start alike"))
	free_all(context.temp_allocator)
}

// settings.txt keeps the slots that changed; the lines from before the map still turn
// the taps or the holds off, and a later gesture line wins.
@(test)
gestures_are_remembered :: proc(t: ^testing.T) {
	path := "build/gesture_map_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	a.nav = NAV_DEFAULT
	a.nav.gestures[.Four_Tap] = {.Pie, 2}
	a.nav.gestures[.Two_Hold] = {}
	// Any command the palette lists can go on a gesture, the search itself included.
	a.nav.gestures[.One_Tap] = {.Duplicate_Object, 0}
	a.nav.gestures[.Three_Hold] = {.Brush, 3}
	a.nav.gestures[.Pen_Button] = {.Command_Palette, 0}
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	b.nav = NAV_DEFAULT
	settings_load(&b, path)
	testing.expect_value(t, b.nav.gestures, a.nav.gestures)

	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("tap_history 0\nhold_history 1\ngesture_map Three_Tap Wireframe\ngesture_map Bogus Undo\ngesture_map Two_Hold Nothing\n")) == nil)
	c: App
	defer results_destroy(&c)
	c.nav = NAV_DEFAULT
	settings_load(&c, path)
	testing.expect_value(t, c.nav.gestures[.Two_Tap], Pie_Slot{})
	testing.expect_value(t, c.nav.gestures[.Three_Tap], Pie_Slot{.Wireframe, 0})
	testing.expect_value(t, c.nav.gestures[.Two_Hold], Pie_Slot{.Undo, 0})
	free_all(context.temp_allocator)
}

// Choosing what a gesture runs from the palette puts the picked command on the gesture
// instead of running it, keeps it out of the recents, and closes the palette; a settings
// page, which a gesture cannot open, leaves the gesture as it was.
@(test)
palette_chooses_a_gestures_command :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	app.nav = NAV_DEFAULT
	palette_open_for(&app, .One_Tap)
	testing.expect(t, app.kit.palette)
	palette_run(&app, {kind = .Command, id = .Duplicate_Object})
	testing.expect_value(t, app.nav.gestures[.One_Tap], Pie_Slot{.Duplicate_Object, 0})
	testing.expect(t, !app.kit.palette)
	testing.expect(t, app.kit.palette_for == nil)
	testing.expect_value(t, app.kit.palette_runs, 0)
	testing.expect_value(t, app.kit.palette_recent_count, 0)
	testing.expect_value(t, len(app.scene.objects), 0)

	palette_open_for(&app, .Four_Tap)
	before := app.nav.gestures[.Four_Tap]
	palette_run(&app, {kind = .Settings_Tab, arg = 0})
	testing.expect_value(t, app.nav.gestures[.Four_Tap], before)
	testing.expect(t, !app.kit.palette)
	free_all(context.temp_allocator)
}
