package main

import "core:testing"

// Every block shows somewhere: in one of the narrow panel's tabs, in one of the sheet's sections, or
// both; none twice in either, so a search never finds a block in two places.
@(test)
settings_blocks_each_have_one_place :: proc(t: ^testing.T) {
	tabs, lens: [Settings_Block]int
	for tab in Settings_Tab do for e in settings_tab_entries(tab) do tabs[e.block] += 1
	for s in Settings_Section do for e in settings_section_entries(s) do lens[e.block] += 1
	for b in Settings_Block {
		testing.expectf(t, tabs[b] <= 1 && lens[b] <= 1, "%v is in two places", b)
		testing.expectf(t, tabs[b] + lens[b] > 0, "%v shows nowhere", b)
	}
	// The sheet gives the gesture switches and the map one list, and the tabs keep their own.
	testing.expect_value(t, lens[.Gesture_Map], 0)
	testing.expect_value(t, tabs[.Gesture_List], 0)
	// Every tab opens on a section.
	for tab in Settings_Tab do testing.expect(t, len(settings_section_entries(SETTINGS_TAB_SECTION[tab])) > 0)
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

// Reset on a section puts its settings back and leaves the others'; a tab's reset
// is its blocks', as it always was.
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
	settings_reset(&a, .Touch)
	testing.expect_value(t, a.nav.pen_tips, d.pen_tips)
	testing.expect_value(t, a.nav.shape_apply, d.shape_apply)
	testing.expect_value(t, a.nav.three_finger, d.three_finger)
	testing.expect_value(t, a.nav.orbit_speed, f32(2))
	settings_reset(&a, .Camera)
	testing.expect_value(t, a.nav.orbit_speed, d.orbit_speed)
}
