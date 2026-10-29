package main

import "core:fmt"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Every shortcut is in the Keys tab, under its command's name, with every chord bound to
// that command.
@(test)
help_keys_list_every_binding :: proc(t: ^testing.T) {
	app: App
	app.nav, app.tool = NAV_DEFAULT, .Brush
	testing.expect(t, bind_assign(&app, .Wireframe, 0, {sdl.K_K, {.Alt}, false}))
	rows := help_key_rows(&app)
	for b in keymap(&app) {
		name, chord := help_name(b.command, b.arg), chord_text(b.chord)
		found := false
		for r in rows {
			if r.what != name do continue
			for c in strings.split(r.how, ", ", context.temp_allocator) do if c == chord do found = true
		}
		testing.expectf(t, found, "%s (%s) is not in Help", name, chord)
	}
	redo := ""
	for r in rows do if r.what == "Redo" do redo = r.how
	testing.expect_value(t, redo, "Ctrl+Shift+Z, Ctrl+Y")
	free_all(context.temp_allocator)
}

// Every gesture command_gesture gives, for every tool and with one finger sculpting or
// turning the view, has a row in the Gestures tab: a gesture added there and not to
// TOUCH_HELP fails here.
@(test)
help_touch_rows_hold_every_gesture :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	for model in Finger_Model {
		app.nav.finger_model = model
		for tool in Tool {
			app.tool = tool
			rows := help_touch_rows(&app)
			for id in Command_Id {
				for arg in 0 ..< max(COMMANDS[id].args, 1) {
					gesture := command_gesture(&app, id, arg)
					if gesture == "" do continue
					found := false
					for r in rows do if r.how == gesture do found = true
					testing.expectf(t, found, "%v %v with %v: %q is not in Help", id, arg, tool, gesture)
				}
			}
			free_all(context.temp_allocator)
		}
	}
}

// The Gestures tab says what works now: the Undo row's words follow the two-finger
// settings, and a gesture turned off, or one the tool lacks, is not listed.
@(test)
help_touch_rows_follow_the_settings :: proc(t: ^testing.T) {
	how_of :: proc(app: ^App, what: string) -> string {
		for r in help_touch_rows(app) do if r.what == what do return r.how
		return ""
	}
	has :: proc(app: ^App, how: string) -> bool {
		for r in help_touch_rows(app) do if r.how == how do return true
		return false
	}
	app: App
	app.nav, app.tool = NAV_DEFAULT, .Brush
	testing.expect_value(t, how_of(&app, "Undo"), "Two-finger tap, hold to repeat")
	app.nav.gestures[.Two_Tap] = {}
	testing.expect_value(t, how_of(&app, "Undo"), "Hold two fingers still")
	app.nav.gestures[.Two_Hold] = {}
	testing.expect_value(t, how_of(&app, "Undo"), "")
	// A command the map gives a gesture that the table has no line for gets one.
	app.nav.gestures[.Four_Tap] = {.Wireframe, 0}
	testing.expect_value(t, how_of(&app, "Wireframe"), "Four-finger tap")
	app.nav.gestures[.Pen_Button] = {.Wireframe, 0}
	testing.expect_value(t, how_of(&app, "Wireframe"), "Four-finger tap, Pen side button")
	// Over empty space the side button still opens the brush pie.
	testing.expect_value(t, how_of(&app, "Brush pie"), "Pen side button on empty space")
	// Both size steps are one drag, listed once.
	sizes := 0
	for r in help_touch_rows(&app) do if r.how == "Three fingers up or down" do sizes += 1
	testing.expect_value(t, sizes, 1)
	testing.expect_value(t, how_of(&app, "Brush size"), "Three fingers up or down")
	testing.expect(t, has(&app, "Pinch two fingers"))
	app.nav.pinch_zoom = false
	testing.expect(t, !has(&app, "Pinch two fingers"))
	// Rolling needs the Free orbit style (the trackball), which is not the default, or the
	// turntable's roll unlocked.
	testing.expect(t, !has(&app, "Twist two fingers"))
	app.nav.orbit_style = .Free
	testing.expect(t, has(&app, "Twist two fingers"))
	app.nav.orbit_style = .Turntable
	testing.expect(t, !has(&app, "Twist two fingers"))
	app.nav.turntable_roll = true
	testing.expect(t, has(&app, "Twist two fingers"))
	app.nav.twist_roll = false
	testing.expect(t, !has(&app, "Twist two fingers"))
	app.nav.turntable_roll, app.nav.twist_roll = false, true
	// The modifier wheel, and the mask taps its Mask turns on, only while they are
	// shown; the mask taps only for Sculpt.
	testing.expect(t, !has(&app, "Modifier wheel: tap or hold; Smooth and Mask together hide"))
	testing.expect(t, !has(&app, "With Mask on, tap off the model"))
	app.kit.rail_side = .Left
	testing.expect(t, has(&app, "Modifier wheel: tap or hold; Smooth and Mask together hide"))
	testing.expect(t, has(&app, "With Mask on, tap off the model"))
	app.tool = .Curve
	testing.expect(t, !has(&app, "With Mask on, tap off the model"))
	testing.expect(t, !has(&app, "One finger on empty space"))
	free_all(context.temp_allocator)
}

// The other apps' names a glossary word lists find its commands first in the palette,
// so what the glossary says and what search does agree.
@(test)
help_glossary_names_find_their_commands :: proc(t: ^testing.T) {
	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for &e in enabled do e = true
	for g in GLOSSARY {
		testing.expectf(t, (g.searches == "") == (g.finds == {}), "%s: searches and finds go together", g.word)
		for name in strings.fields(g.searches, context.temp_allocator) {
			hits := palette_rank(name, entries, nil, enabled)
			ok := len(hits) > 0
			if ok {
				e := entries[hits[0].entry]
				ok = e.kind == .Command && e.id in g.finds
				testing.expectf(t, ok, "%q finds %s, not one of %s's commands", name, palette_label(e), g.word)
			} else do testing.expectf(t, ok, "%q finds nothing", name)
		}
	}
	free_all(context.temp_allocator)
}

// Each Help tab is found by its own words, the Settings tab named Touch still by "touch",
// and the remembered name of each reads back.
@(test)
help_tabs_are_found_by_search :: proc(t: ^testing.T) {
	best :: proc(query: string) -> string {
		entries := palette_entries()
		enabled := make([]bool, len(entries), context.temp_allocator)
		for &e in enabled do e = true
		hits := palette_rank(query, entries, nil, enabled)
		return palette_label(entries[hits[0].entry]) if len(hits) > 0 else ""
	}
	testing.expect_value(t, best("shortcuts"), "Help: Keys")
	testing.expect_value(t, best("gestures"), "Help: Gestures")
	testing.expect_value(t, best("glossary"), "Help: Glossary")
	testing.expect_value(t, best("touch"), "Settings: Touch")
	testing.expect_value(t, best("keymap"), "Settings: Keys")
	for tab in Help_Tab {
		name := palette_entry_name({.Command, .Help, int(tab)})
		testing.expect_value(t, name, fmt.tprintf("Help:%v", tab))
		e, ok := palette_entry_from_name(name)
		testing.expect(t, ok && e == Palette_Entry{.Command, .Help, int(tab)})
	}
	free_all(context.temp_allocator)
}
