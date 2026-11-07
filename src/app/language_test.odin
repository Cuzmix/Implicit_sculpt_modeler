package main

import "core:testing"

import "../ui"

// Every language the app ships reads whole, by its own name, and translates the brush the
// app starts on.
@(test)
shipped_languages_read :: proc(t: ^testing.T) {
	for c in Language_Choice {
		text := LANGUAGE_FILES[c]
		if text == "" do continue
		l, ok, line := ui.language_parse(text)
		defer ui.language_destroy(&l)
		testing.expectf(t, ok, "assets/lang/%s.txt is damaged at line %d", LANGUAGE_CODES[c], line)
		testing.expect_value(t, l.name, LANGUAGE_NAMES[c])
		testing.expectf(t, "Draw" in l.entries, "%s has no Draw", LANGUAGE_NAMES[c])
	}
}

// Automatic takes the first of the device's languages the app has, a region or not, and
// English when it has none of them.
@(test)
language_follows_the_device :: proc(t: ^testing.T) {
	testing.expect_value(t, language_of_system({"de-AT", "en-US"}), Language_Choice.German)
	testing.expect_value(t, language_of_system({"ja", "pt_BR", "FR"}), Language_Choice.French)
	testing.expect_value(t, language_of_system({"en-GB", "es"}), Language_Choice.English)
	testing.expect_value(t, language_of_system({"ja"}), Language_Choice.English)
	testing.expect_value(t, language_of_system({}), Language_Choice.English)
	l := Language_State{choice = .Automatic, system = .Spanish}
	testing.expect_value(t, language_shown(&l), Language_Choice.Spanish)
	l.choice = .English
	testing.expect_value(t, language_shown(&l), Language_Choice.English)
}

// Choosing a language hands the kit its translation, and English hands it none.
@(test)
language_update_loads_the_choice :: proc(t: ^testing.T) {
	k: Kit_State
	k.language.choice = .French
	language_update(&k)
	testing.expect(t, k.ctx.language != nil)
	testing.expect_value(t, ui.tr(&k.ctx, "Draw"), "Dessiner")
	k.language.choice = .English
	language_update(&k)
	testing.expect(t, k.ctx.language == nil)
	testing.expect_value(t, ui.tr(&k.ctx, "Draw"), "Draw")
	language_destroy(&k)
}
