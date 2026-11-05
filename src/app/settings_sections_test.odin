package main

import "core:testing"

// Every block shows in exactly one section, so a search never finds a block in two
// places, and every section has blocks.
@(test)
settings_blocks_each_have_one_place :: proc(t: ^testing.T) {
	places: [Settings_Block]int
	for s in Settings_Section {
		testing.expectf(t, len(settings_section_entries(s)) > 0, "the %v section is empty", s)
		for e in settings_section_entries(s) do places[e.block] += 1
	}
	for b in Settings_Block do testing.expectf(t, places[b] == 1, "%v is in %d sections", b, places[b])
}

// Search settings finds a block by its words: "hold" is Touch's, "autosave" is Files'.
@(test)
settings_search_finds_the_section :: proc(t: ^testing.T) {
	for s in Settings_Section {
		testing.expectf(t, settings_section_matches(s, "hold") == (s == .Touch), "hold in %v", s)
		testing.expectf(t, settings_section_matches(s, "autosave") == (s == .Files), "autosave in %v", s)
		testing.expect(t, settings_section_matches(s, ""))
		testing.expect(t, !settings_section_matches(s, "nothing has this name"))
	}
	// A section's own name finds it.
	testing.expect(t, settings_section_matches(.Frame_Rate, "frame"))
}

// Reset on a section puts its settings back and leaves the others'.
@(test)
settings_section_reset_keeps_the_others :: proc(t: ^testing.T) {
	a: App
	a.nav = NAV_DEFAULT
	d := NAV_DEFAULT
	a.nav.hold_delay, a.nav.finger_model, a.nav.palm_rejection = 0.6, .Orbit, !d.palm_rejection
	a.nav.orbit_speed = 2
	settings_section_reset(&a, .Touch)
	testing.expect_value(t, a.nav.hold_delay, d.hold_delay)
	testing.expect_value(t, a.nav.finger_model, d.finger_model)
	testing.expect_value(t, a.nav.palm_rejection, d.palm_rejection)
	testing.expect_value(t, a.nav.orbit_speed, f32(2))

	a.nav.pen_tips, a.nav.shape_apply, a.nav.three_finger = .Never, .Confirm, !d.three_finger
	settings_section_reset(&a, .Pen)
	settings_section_reset(&a, .Touch)
	testing.expect_value(t, a.nav.pen_tips, d.pen_tips)
	testing.expect_value(t, a.nav.shape_apply, d.shape_apply)
	testing.expect_value(t, a.nav.three_finger, d.three_finger)
	testing.expect_value(t, a.nav.orbit_speed, f32(2))
	settings_section_reset(&a, .Camera)
	testing.expect_value(t, a.nav.orbit_speed, d.orbit_speed)
}
