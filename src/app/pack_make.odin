package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../sculpt"
import "../zip"

// Make a pack: the person's own alphas (library/mine) and brush presets written as a
// content pack (pack.odin), so they can be passed to another person or another device and
// installed there. The pack is named after its file ("Bolt clay.sculptpack" is "Bolt
// clay"). A preset's alpha from another pack is not the person's to pass on, so it goes
// round in the pack, and the note counts those presets.

// Writes the pack to `path`; "" when it is written, otherwise why not (also in a note).
pack_make :: proc(app: ^App, path: string) -> (error: string) {
	name := strings.trim_space(filepath.stem(path))
	fail :: proc(app: ^App, file, why: string) -> string {
		file_note(app, true, "Cannot make %s: %s", file, why)
		return fmt.tprint(why)
	}
	if name == "" do return fail(app, filepath.base(path), "the file needs a name, which becomes the pack's")
	files := make([dynamic]zip.File, context.temp_allocator)
	text := fmt.tprintf("name %s\n", name)
	append(&files, zip.File{PACK_FILE, transmute([]u8)text})
	alphas := 0
	for e, i in app.alphas {
		if !alpha_is_mine(app, i) do continue
		data, err := os.read_entire_file(e.file, context.temp_allocator)
		if err != nil do return fail(app, filepath.base(path), fmt.tprintf("cannot read the alpha %s: %v", e.name, err))
		append(&files, zip.File{fmt.tprintf("%s/%s", LIBRARY_ALPHAS, filepath.base(e.file)), data})
		alphas += 1
	}
	// Each preset's alpha by the word brushes.txt takes: the stem of one of the pack's
	// own, a built-in's name, or `-`.
	brushes := strings.builder_make(context.temp_allocator)
	went_round := 0
	for i in 0 ..< app.preset_count {
		p := &app.presets[i]
		v := p.values
		word := "-"
		switch {
		case alpha_is_mine(app, v.alpha):
			word = filepath.stem(app.alphas[v.alpha].file)
		case v.alpha >= 0 && v.alpha < len(sculpt.Alpha_Shape):
			word = app.alphas[v.alpha].ref
		case v.alpha >= 0 && v.alpha < len(app.alphas) && !app.alphas[v.alpha].gone:
			went_round += 1
		}
		preset_line(&brushes, preset_name(p), v, word)
	}
	if app.preset_count > 0 do append(&files, zip.File{PACK_BRUSHES, transmute([]u8)strings.to_string(brushes)})
	if alphas == 0 && app.preset_count == 0 do return fail(app, filepath.base(path), "there is nothing of yours to put in it yet: load an alpha (Brush palette, Alpha) or save a preset first")
	archive, ok := zip.write(files[:], context.temp_allocator)
	if !ok do return fail(app, filepath.base(path), "two of your alphas have names that differ only in case")
	if werr := write_durably(path, archive); werr != "" do return fail(app, filepath.base(path), werr)
	round := "" if went_round == 0 else fmt.tprintf("; %d preset%s used another pack's alpha, which is not yours to pass on, and %s round in it", went_round, "" if went_round == 1 else "s", "is" if went_round == 1 else "are")
	file_note(app, false, "Made %s: %s%s", filepath.base(path), pack_holds({alphas = alphas, presets = app.preset_count}), round)
	return ""
}
