package ui

import "core:strings"

// The interface in other languages, as gettext and Qt's Linguist do it: the English text
// is the key, so every label, button, hint and tooltip stays written in English where it
// is made, and the kit shows each in the chosen language where it draws or measures it
// (text, text_width, paragraph, text_fit). Nothing that names a control changes: ids,
// the control map's names and scripts keep the English, so a script or a saved layout
// works in any language. A line the language has no entry for, or one built from parts
// (a number, an object's name), shows as it is.
//
// A language file is UTF-8 text: a first line `@language` and the language's own name,
// then entries of an English line followed by a line starting `= ` with its translation,
// blank lines between them and `#` starting a comment. `\n` in either stands for a line
// break, `\\` for a backslash. Format verbs (%s, %v, %d, %.1f) the English has the
// translation must have too, in the same order (language_verbs_match).
Language :: struct {
	name:    string,
	entries: map[string]string,
	owned:   [dynamic]string, // every string above, freed with the allocator they were made with
	// With `record` on, every line shown that has no entry, once each, for a translator
	// (the app's --language-missing).
	record:  bool,
	missing: map[string]struct{},
	shown:   map[string]struct{}, // the translations, for record to pass over one drawn again
}

// The text a language file holds as a Language, its strings owned with `allocator`, or
// false and the line (from 1) of the first fault: an entry with no English line before
// it, an English line given twice, a translation whose format verbs differ, or no
// `@language` line first.
language_parse :: proc(text: string, allocator := context.allocator) -> (l: Language, ok: bool, fault_line: int) {
	context.allocator = allocator
	l.entries = make(map[string]string)
	l.owned = make([dynamic]string)
	key := ""
	have_key := false
	line_no := 0
	rest := text
	named := false
	for line_raw in strings.split_lines_iterator(&rest) {
		line_no += 1
		line := strings.trim_right(line_raw, "\r")
		if !named {
			// A byte order mark some editors save is passed over.
			if line_no == 1 && len(line) >= 3 && line[0] == 0xef && line[1] == 0xbb && line[2] == 0xbf do line = line[3:]
			if !strings.has_prefix(line, "@language ") {
				language_destroy(&l)
				return {}, false, line_no
			}
			l.name = language_keep(&l, strings.trim_space(line[len("@language "):]))
			named = true
			continue
		}
		switch {
		case len(strings.trim_space(line)) == 0 || line[0] == '#':
			continue
		case strings.has_prefix(line, "= "):
			value := language_unescape(&l, line[2:])
			if !have_key || key in l.entries || !language_verbs_match(key, value) {
				language_destroy(&l)
				return {}, false, line_no
			}
			l.entries[key] = value
			have_key = false
		case:
			if have_key {
				// An English line with no translation under it.
				language_destroy(&l)
				return {}, false, line_no - 1
			}
			key, have_key = language_unescape(&l, line), true
		}
	}
	if !named || have_key {
		language_destroy(&l)
		return {}, false, line_no
	}
	return l, true, 0
}

// Frees what language_parse made, with the allocator it was made with.
language_destroy :: proc(l: ^Language) {
	for s in l.owned do delete(s, l.owned.allocator)
	delete(l.owned)
	delete(l.entries)
	delete(l.missing)
	delete(l.shown)
	l^ = {}
}

@(private = "file")
language_keep :: proc(l: ^Language, s: string) -> string {
	kept := strings.clone(s, l.owned.allocator)
	append(&l.owned, kept)
	return kept
}

@(private = "file")
language_unescape :: proc(l: ^Language, s: string) -> string {
	if strings.index_byte(s, '\\') < 0 do return language_keep(l, s)
	b := strings.builder_make(0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 1
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return language_keep(l, strings.to_string(b))
}

// Whether `a` and `b` hold the same format verbs in the same order (%% is no verb), so a
// translated format string takes the same arguments.
language_verbs_match :: proc(a, b: string) -> bool {
	next :: proc(s: ^string) -> (verb: string, ok: bool) {
		for {
			i := strings.index_byte(s^, '%')
			if i < 0 || i + 1 >= len(s^) do return "", false
			if s[i + 1] == '%' {
				s^ = s[i + 2:]
				continue
			}
			// The verb runs to its first letter: %s, %v, %.1f, %3d.
			j := i + 1
			for j < len(s^) && !((s[j] >= 'a' && s[j] <= 'z') || (s[j] >= 'A' && s[j] <= 'Z')) do j += 1
			if j >= len(s^) do return "", false
			verb = s[i:j + 1]
			s^ = s[j + 1:]
			return verb, true
		}
	}
	a, b := a, b
	for {
		va, oka := next(&a)
		vb, okb := next(&b)
		if oka != okb || va != vb do return false
		if !oka do return true
	}
}

// `s` where one English word means two things (Light, the theme's against a lamp): the
// entry "`where`|`s`" when the language has one, else as tr gives it.
trc :: proc(ctx: ^Context, where_: string, s: string) -> string {
	l := ctx.language
	if l == nil do return s
	key := concatenate_temp(where_, "|", s)
	if t, ok := l.entries[key]; ok do return t
	return tr(ctx, s)
}

@(private = "file")
concatenate_temp :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// `s` in the context's language: its translation, or `s` itself when there is none.
tr :: proc(ctx: ^Context, s: string) -> string {
	l := ctx.language
	if l == nil || len(s) == 0 do return s
	if t, ok := l.entries[s]; ok do return t
	if l.record && s not_in l.missing {
		context.allocator = l.owned.allocator
		if l.missing == nil {
			l.missing = make(map[string]struct{})
			l.shown = make(map[string]struct{}, len(l.entries))
			for _, v in l.entries do l.shown[v] = {}
		}
		if s not_in l.shown do l.missing[language_keep(l, s)] = {}
	}
	return s
}
