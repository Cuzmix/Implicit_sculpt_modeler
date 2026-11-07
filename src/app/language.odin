package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import "../ui"

// The interface's language (Settings > Interface > Language): English, the words the app
// is written in, or a translation from assets/lang, which the kit shows in place of each
// English line it has (src/ui/language.odin). Automatic follows the device's preferred
// languages, the first of them the app has, else English. Only what is shown changes:
// scripts, keys, settings, files and the control map's names are the same in every
// language, and a line a translation lacks shows in English.
Language_Choice :: enum u8 {
	Automatic,
	English,
	German,
	French,
	Spanish,
}

// Each language by its own name, as language pickers show them.
@(rodata)
LANGUAGE_NAMES := [Language_Choice]string {
	.Automatic = "Automatic",
	.English   = "English",
	.German    = "Deutsch",
	.French    = "Français",
	.Spanish   = "Español",
}

// The ISO 639-1 code a device's preferred language names each by.
@(rodata)
LANGUAGE_CODES := [Language_Choice]string {
	.Automatic = "",
	.English   = "en",
	.German    = "de",
	.French    = "fr",
	.Spanish   = "es",
}

// Each translation's file, built into the app.
LANGUAGE_FILES := [Language_Choice]string {
	.Automatic = "",
	.English   = "",
	.German    = #load("../../assets/lang/de.txt", string),
	.French    = #load("../../assets/lang/fr.txt", string),
	.Spanish   = #load("../../assets/lang/es.txt", string),
}

// The language state in Kit_State: the setting, what the device asks for (found once, at
// the start), and which translation `data` holds.
Language_State :: struct {
	choice:  Language_Choice,
	system:  Language_Choice,
	loaded:  Language_Choice,
	data:    ui.Language,
	// --language-missing: where to write, on exit, every line shown that the language
	// lacks, for a translator.
	missing: string,
}

// The language shown: the setting, or for Automatic the device's.
language_shown :: proc(l: ^Language_State) -> Language_Choice {
	if l.choice != .Automatic do return l.choice
	return l.system if l.system != .Automatic else .English
}

// The first of the device's preferred languages (ISO codes, "de" or "de-AT") the app
// has, else English.
language_of_system :: proc(preferred: []string) -> Language_Choice {
	for tag in preferred {
		code := strings.to_lower(tag[:strings.index_any(tag, "-_") if strings.index_any(tag, "-_") >= 0 else len(tag)], context.temp_allocator)
		for c in Language_Choice do if c != .Automatic && LANGUAGE_CODES[c] == code do return c
	}
	return .English
}

// Before the frame's interface: loads the translation the setting asks for when it
// changed, and hands it to the kit (nil for English).
language_update :: proc(k: ^Kit_State) {
	l := &k.language
	want := language_shown(l)
	if l.loaded == .Automatic || want != l.loaded {
		ui.language_destroy(&l.data)
		l.loaded = want
		if text := LANGUAGE_FILES[want]; text != "" {
			data, ok, line := ui.language_parse(text)
			if ok {
				l.data = data
			} else {
				// A shipped file is checked by the tests; this guards a hand-edited build.
				log.errorf("language %s: assets/lang/%s.txt is damaged at line %d; showing English", LANGUAGE_NAMES[want], LANGUAGE_CODES[want], line)
			}
		}
		l.data.record = l.missing != ""
	}
	k.ctx.language = &l.data if len(l.data.entries) > 0 || l.data.record else nil
}

// At exit: writes the lines the language lacked (--language-missing), sorted, in the
// language file's own form with empty translations to fill in, and frees the translation.
language_destroy :: proc(k: ^Kit_State) {
	l := &k.language
	if l.missing != "" {
		lines := make([dynamic]string, 0, len(l.data.missing), context.temp_allocator)
		for s in l.data.missing {
			// Numbers, sizes and other lines with no letter in them need no translation.
			letters := false
			for r in s do if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') do letters = true
			if letters do append(&lines, s)
		}
		slice.sort(lines[:])
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintfln(&b, "@language %s", LANGUAGE_NAMES[language_shown(l)])
		for s in lines {
			escaped, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
			escaped, _ = strings.replace_all(escaped, "\n", "\\n", context.temp_allocator)
			fmt.sbprintf(&b, "\n%s\n= \n", escaped)
		}
		if err := os.write_entire_file(l.missing, transmute([]u8)strings.to_string(b)); err != nil do log.errorf("--language-missing: could not write %s", l.missing)
	}
	ui.language_destroy(&l.data)
	k.ctx.language = nil
}
