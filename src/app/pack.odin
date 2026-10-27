package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"

import "../sculpt"
import "../zip"

// Content packs: a `.sculptpack` file is a ZIP archive, so that any zip tool makes one,
// holding `pack.txt` (name, author, version, description, license, one `key value` line
// each; only the name is needed), brush alphas under `alphas/` and brush presets in
// `brushes.txt` (settings.txt's `preset` lines, naming the pack's own alphas by stem). Installing one checks
// the archive (zip.odin), reads pack.txt, decodes every alpha, and only then writes
// anything: into library/.incoming, renamed to library/<id> once whole, so an install
// that stops halfway leaves nothing behind. A pack is data only (store rule: no
// downloaded code), and it only adds: its alphas are named `<id>/<stem>` beside the
// built-ins and the person's own, and its presets are listed under its name, read-only.
// Installing runs on a thread of its own so a big pack
// never holds a frame; the frame loop finishes it (library_frame).

PACK_FILE :: "pack.txt"
PACK_BRUSHES :: "brushes.txt"
// The most presets a pack brings: far more than a real set, and a bound on the lists.
PACK_PRESETS_MAX :: 256
PACK_INCOMING :: ".incoming"
// A replaced pack's folder is moved here while the new one is renamed in, then deleted.
PACK_ASIDE :: ".replaced"
PACK_LIMITS :: zip.Limits{entries = 4096, total = 512 << 20}
// pack.txt's values are cut to this many characters: a name, a line of credit.
PACK_TEXT_MAX :: 200

Pack :: struct {
	id:          string, // the folder's name, and the first part of its alphas' references
	name:        string,
	author:      string,
	version:     string,
	description: string,
	license:     string,
	alphas:      int,
	presets:     int,
}

// A content pack's brush preset, in Library.presets: the preset, read-only, and the pack's
// id. A removed pack's are marked gone and stay, so an index into the list holds for the
// run (PACK_PRESET).
Pack_Preset :: struct {
	preset: Brush_Preset,
	pack:   string, // owned
	gone:   bool,
}

// A brushes.txt line as read, before its alpha is looked up: the preset, with its alpha's
// word (`-`, a built-in's name, or the stem of one of the pack's alphas).
Pack_Preset_Read :: struct {
	preset: Brush_Preset,
	alpha:  string,
}

pack_free :: proc(p: ^Pack) {
	delete(p.id)
	delete(p.name)
	delete(p.author)
	delete(p.version)
	delete(p.description)
	delete(p.license)
	p^ = {}
}

// Everything an install makes is in the frame loop's allocator, which the install thread
// is started with (as the autosave thread is), so a leak on the thread is caught too.

// An alpha an install decoded, handed to the frame loop with the file it was written to.
Pack_Alpha :: struct {
	stem:  string,
	file:  string, // its name in the pack's alphas folder
	alpha: sculpt.Alpha,
	sum:   u32,
	size:  int,
}

// What an install made of a picked file: the pack, unpacked into library/.incoming, or
// why it was refused.
Pack_Unpacked :: struct {
	source:   string, // the picked file's name, for notes
	error:    string, // why it was refused, or ""
	info:     Pack,   // without an id until it is placed
	alphas:   [dynamic]Pack_Alpha,
	presets:  [dynamic]Pack_Preset_Read,
	bad:      int,    // brushes.txt lines it cannot use
	left_out: int,    // entries this version does not read
	left:     string, // the first of them
}

pack_unpacked_free :: proc(u: ^Pack_Unpacked) {
	delete(u.source)
	delete(u.error)
	pack_free(&u.info)
	for &a in u.alphas {
		delete(a.stem)
		delete(a.file)
		sculpt.alpha_destroy(&a.alpha)
	}
	delete(u.alphas)
	for p in u.presets do delete(p.alpha)
	delete(u.presets)
	delete(u.left)
	free(u)
}

// Reads pack.txt into `p`. False when it is not UTF-8 or has no name.
pack_text_parse :: proc(text: string, p: ^Pack) -> bool {
	if !utf8.valid_string(text) do return false
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		space := strings.index_any(line, " \t")
		if space < 0 do continue
		key, value := line[:space], strings.trim_space(line[space:])
		if n := strings.rune_count(value); n > PACK_TEXT_MAX do value = value[:utf8_rune_offset(value, PACK_TEXT_MAX)]
		field: ^string
		switch key {
		case "name":        field = &p.name
		case "author":      field = &p.author
		case "version":     field = &p.version
		case "description": field = &p.description
		case "license":     field = &p.license
		case:               continue
		}
		delete(field^)
		field^ = strings.clone(value)
	}
	return p.name != ""
}

// Reads brushes.txt's `preset` lines into `out`, where `stems` are the pack's alphas;
// returns how many lines it cannot use: damaged, of a name it has already or a brush's
// own, with an alpha that is neither a built-in nor the pack's, or past PACK_PRESETS_MAX.
// The alphas' words are made in `allocator`.
pack_brushes_parse :: proc(text: string, stems: []string, out: ^[dynamic]Pack_Preset_Read, allocator := context.allocator) -> (bad: int) {
	if !utf8.valid_string(text) do return 1
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		f := strings.fields(line, context.temp_allocator)
		name, alpha: string
		v: Preset_Values
		ok := false
		if f[0] == "preset" do name, v, alpha, ok = preset_parse(f)
		name = preset_name_fit(strings.trim_space(name))
		_, a_brush := brush_by_name(name)
		taken := false
		for p in out do taken ||= strings.equal_fold(preset_name_of(p.preset), name)
		// The pack's own alpha before a built-in of that name, as pack_presets_add looks.
		word := "-" if alpha == "-" else ""
		for stem in stems do if word == "" && strings.equal_fold(alpha, stem) do word = stem
		for shape_name in sculpt.ALPHA_SHAPE_NAMES do if word == "" && strings.equal_fold(alpha, shape_name) do word = shape_name
		if !ok || name == "" || a_brush || taken || word == "" || len(out) >= PACK_PRESETS_MAX {
			bad += 1
			continue
		}
		r := Pack_Preset_Read{preset = {values = v}, alpha = strings.clone(word, allocator)}
		preset_name_set(&r.preset, name)
		append(out, r)
	}
	return
}

// A preset's name, from a copy of it.
@(private = "file")
preset_name_of :: proc(p: Brush_Preset) -> string {
	p := p
	return strings.clone(preset_name(&p), context.temp_allocator)
}

// The stems of the alphas pack `id` has now.
alphas_of_pack :: proc(app: ^App, id: string) -> []string {
	stems := make([dynamic]string, context.temp_allocator)
	prefix := fmt.tprintf("%s/", id)
	for e in app.alphas do if !e.gone && strings.has_prefix(e.ref, prefix) do append(&stems, e.ref[len(prefix):])
	return stems[:]
}

// Adds pack `id`'s presets to the library, each alpha looked up as the pack's own or a
// built-in's; returns how many.
pack_presets_add :: proc(app: ^App, id: string, read: []Pack_Preset_Read) -> int {
	for r in read {
		p := Pack_Preset{preset = r.preset, pack = strings.clone(id)}
		p.preset.values.alpha = -1
		if r.alpha != "-" {
			p.preset.values.alpha = alpha_find(app, fmt.tprintf("%s/%s", id, r.alpha))
			if p.preset.values.alpha < 0 do p.preset.values.alpha = alpha_find(app, r.alpha)
		}
		append(&app.library.presets, p)
	}
	return len(read)
}

// Pack `id`'s preset named `name` (ignoring case), numbered as PACK_PRESET says; 0 for
// none.
pack_preset_find :: proc(app: ^App, id, name: string) -> int {
	for &p, j in app.library.presets {
		if !p.gone && strings.equal_fold(p.pack, id) && strings.equal_fold(preset_name(&p.preset), name) do return PACK_PRESET + j
	}
	return 0
}

// After a pack's presets were marked gone (removed, or replaced by a newer copy): the
// brush and every dock slot on one move to the preset of the same pack and name now, or,
// when there is none, the brush goes back to its plain self and the slot to its brush.
// Returns how many of the two fell back.
pack_presets_retarget :: proc(app: ^App) -> (fell: int) {
	retarget :: proc(app: ^App, n: ^int) -> bool {
		if !preset_of_pack(n^) do return false
		j := n^ - PACK_PRESET
		if j < len(app.library.presets) && !app.library.presets[j].gone do return false
		if j < len(app.library.presets) {
			old := &app.library.presets[j]
			if m := pack_preset_find(app, old.pack, preset_name(&old.preset)); m > 0 {
				n^ = m
				return false
			}
		}
		return true
	}
	if retarget(app, &app.brush.preset) {
		preset_leave(app)
		fell += 1
	}
	for &s in app.kit.dock {
		if retarget(app, &s.preset) {
			s.preset = 0
			fell += 1
		}
	}
	return
}

// The byte offset of rune `n` in `s`.
@(private = "file")
utf8_rune_offset :: proc(s: string, n: int) -> int {
	count := 0
	for _, i in s {
		if count == n do return i
		count += 1
	}
	return len(s)
}

// Checks and unpacks the pack at `path` into `<library>/.incoming`, replacing whatever
// an earlier install left there. It runs on the install thread, or in place for a
// script; it touches nothing of the app's.
pack_unpack :: proc(path, library: string) -> ^Pack_Unpacked {
	u := new(Pack_Unpacked)
	u.source = strings.clone(filepath.base(path))
	refuse :: proc(u: ^Pack_Unpacked, format: string, args: ..any) -> ^Pack_Unpacked {
		u.error = fmt.aprintf(format, ..args)
		return u
	}
	data, err := file_read_any(path)
	if err != nil do return refuse(u, "%v", err)
	defer delete(data)
	entries, zip_err := zip.entries(data, PACK_LIMITS)
	if zip_err != .None do return refuse(u, "%s", zip.ERROR_TEXT[zip_err])
	defer delete(entries)
	// Only now that the archive reads is anything written: into .incoming, emptied first.
	incoming, _ := filepath.join({library, PACK_INCOMING}, context.temp_allocator)
	incoming = strings.clone(incoming)
	defer delete(incoming)
	_ = os.remove_all(incoming)
	alphas_dir, _ := filepath.join({incoming, LIBRARY_ALPHAS}, context.temp_allocator)
	if dir_err := os.make_directory_all(alphas_dir); dir_err != nil do return refuse(u, "cannot make %s: %v", incoming, dir_err)
	// Read in name order, so two installs of one file write and number alike.
	slice.sort_by(entries, proc(a, b: zip.Entry) -> bool {return a.name < b.name})
	text_found := false
	brushes: []u8
	defer delete(brushes)
	// Each entry's temp memory (a big image's grey values) is its own and goes with it,
	// so neither the install thread nor a script's frame keeps more than one at a time.
	entry_temp: runtime.Arena
	defer runtime.arena_destroy(&entry_temp)
	for e in entries {
		context.temp_allocator = runtime.arena_allocator(&entry_temp)
		defer runtime.arena_free_all(&entry_temp)
		if strings.has_suffix(e.name, "/") do continue
		// An alpha sits right in alphas/, never in a folder below it.
		file := strings.trim_prefix(e.name, LIBRARY_ALPHAS + "/")
		in_alphas := len(file) < len(e.name) && strings.index_byte(file, '/') < 0
		switch {
		case e.name == PACK_FILE:
			bytes, read_err := zip.read(data, e)
			if read_err != .None do return refuse(u, "%s: %s", e.name, zip.ERROR_TEXT[read_err])
			ok := pack_text_parse(string(bytes), &u.info)
			delete(bytes)
			if !ok do return refuse(u, "its %s has no name line (or is not UTF-8 text)", PACK_FILE)
			text_found = true
		case e.name == PACK_BRUSHES:
			bytes, read_err := zip.read(data, e)
			if read_err != .None do return refuse(u, "%s: %s", e.name, zip.ERROR_TEXT[read_err])
			brushes = bytes
		case in_alphas && alpha_extension(file) && !strings.has_prefix(file, "."):
			stem := filepath.stem(file)
			taken := false
			for a in u.alphas do taken ||= strings.equal_fold(a.stem, stem)
			if taken || len(u.alphas) >= LIBRARY_ALPHAS_MAX {
				pack_left_out(u, e.name)
				continue
			}
			bytes, read_err := zip.read(data, e)
			if read_err != .None do return refuse(u, "%s: %s", e.name, zip.ERROR_TEXT[read_err])
			defer delete(bytes)
			alpha, _, _, failed := alpha_decode(bytes)
			if failed != "" do return refuse(u, "%s is not an image the app reads: %s", e.name, failed)
			a := Pack_Alpha{stem = strings.clone(stem), file = strings.clone(file), alpha = alpha, sum = hash.crc32(bytes), size = len(bytes)}
			append(&u.alphas, a)
			target, _ := filepath.join({incoming, LIBRARY_ALPHAS, a.file}, context.temp_allocator)
			if werr := os.write_entire_file(target, bytes); werr != nil do return refuse(u, "cannot write %s: %v", target, werr)
		case:
			pack_left_out(u, e.name)
		}
	}
	if !text_found do return refuse(u, "it has no %s, so it is not a content pack", PACK_FILE)
	if brushes != nil {
		stems := make([]string, len(u.alphas), context.temp_allocator)
		for a, i in u.alphas do stems[i] = a.stem
		u.bad = pack_brushes_parse(string(brushes), stems, &u.presets)
		// Written as checked, so what a start reads is always well formed.
		out := strings.builder_make(context.temp_allocator)
		for &r in u.presets do preset_line(&out, preset_name(&r.preset), r.preset.values, r.alpha)
		brushes_path, _ := filepath.join({incoming, PACK_BRUSHES}, context.temp_allocator)
		if werr := write_durably(brushes_path, transmute([]u8)strings.to_string(out)); werr != "" do return refuse(u, "%s", werr)
	}
	text_path, _ := filepath.join({incoming, PACK_FILE}, context.temp_allocator)
	// Written as read, one line a key, so the pack's own extra lines and comments go.
	text := fmt.tprintf("name %s\nauthor %s\nversion %s\ndescription %s\nlicense %s\n", u.info.name, u.info.author, u.info.version, u.info.description, u.info.license)
	if werr := write_durably(text_path, transmute([]u8)text); werr != "" do return refuse(u, "%s", werr)
	return u
}

@(private = "file")
pack_left_out :: proc(u: ^Pack_Unpacked, name: string) {
	if u.left_out == 0 do u.left = strings.clone(name)
	u.left_out += 1
}

// The install thread's state, shared with the frame loop.
Pack_Worker :: struct {
	path:    string,
	library: string,
	result:  ^Pack_Unpacked,
	done:    bool, // atomic: the result is ready
	thread:  ^thread.Thread,
}

// Starts installing the pack at `path` on a thread of its own; the frame loop finishes
// it. One install at a time, and none without a library.
pack_install_start :: proc(app: ^App, path: string) {
	l := &app.library
	if l.folder == "" {
		file_note(app, true, "Cannot install %s: this run keeps no library (it keeps no settings)", filepath.base(path))
		return
	}
	if l.worker != nil || l.pending != nil {
		file_note(app, true, "Cannot install %s: another pack is being installed", filepath.base(path))
		return
	}
	w := new(Pack_Worker)
	w.path, w.library = strings.clone(path), strings.clone(l.folder)
	l.worker = w
	w.thread = thread.create_and_start_with_data(w, proc(data: rawptr) {
		w := (^Pack_Worker)(data)
		// Its own temp memory, freed as it goes and at the end.
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		w.result = pack_unpack(w.path, w.library)
		sync.atomic_store(&w.done, true)
	}, context, .Low, name = "pack install")
}

// Each frame: finishes an install the thread is done with.
library_frame :: proc(app: ^App) {
	w := app.library.worker
	if w == nil || !sync.atomic_load(&w.done) do return
	u := pack_worker_end(app)
	pack_install_finish(app, u, replace = false)
}

// Joins the install thread and frees it, giving back what it made.
@(private = "file")
pack_worker_end :: proc(app: ^App) -> ^Pack_Unpacked {
	w := app.library.worker
	thread.join(w.thread)
	thread.destroy(w.thread)
	u := w.result
	delete(w.path)
	delete(w.library)
	free(w)
	app.library.worker = nil
	return u
}

// Whether a pack is being installed or waits on Replace.
pack_busy :: proc(app: ^App) -> bool {
	return app.library.worker != nil || app.library.pending != nil
}

// Places an unpacked pack in the library. A pack of the same name and author as one
// installed replaces it only with `replace`; otherwise it waits on the Library panel's
// Replace (app.library.pending). Takes `u`.
pack_install_finish :: proc(app: ^App, u: ^Pack_Unpacked, replace: bool) -> (error: string) {
	l := &app.library
	incoming, _ := filepath.join({l.folder, PACK_INCOMING}, context.temp_allocator)
	if u.error != "" {
		error = fmt.tprint(u.error)
		file_note(app, true, "Cannot install %s: %s", u.source, u.error)
		l.refused += 1
		pack_unpacked_free(u)
		_ = os.remove_all(incoming)
		return
	}
	old := -1
	for p, i in l.packs do if strings.equal_fold(p.name, u.info.name) && strings.equal_fold(p.author, u.info.author) do old = i
	if old >= 0 && !replace {
		l.pending = u
		library_open(app)
		return
	}
	id := strings.clone(l.packs[old].id, context.temp_allocator) if old >= 0 else pack_id(app, u.info.name)
	folder, _ := filepath.join({l.folder, id}, context.temp_allocator)
	aside, _ := filepath.join({l.folder, PACK_ASIDE}, context.temp_allocator)
	// A replace moves the old folder aside, renames the new one in and only then deletes
	// the old, putting it back if the new one cannot go in.
	if old >= 0 {
		_ = os.remove_all(aside)
		if err := os.rename(folder, aside); err != nil {
			error = fmt.tprintf("cannot move %s aside: %v", id, err)
			file_note(app, true, "Cannot replace %s: %s", u.info.name, error)
			pack_unpacked_free(u)
			_ = os.remove_all(incoming)
			return
		}
	}
	if err := os.rename(incoming, folder); err != nil {
		error = fmt.tprintf("cannot move it into the library: %v", err)
		file_note(app, true, "Cannot install %s: %s", u.info.name, error)
		if old >= 0 do _ = os.rename(aside, folder)
		pack_unpacked_free(u)
		_ = os.remove_all(incoming)
		return
	}
	if old >= 0 {
		_ = os.remove_all(aside)
		pack_forget(app, old)
	}
	p := u.info
	u.info = {}
	p.id = strings.clone(id)
	for &a in u.alphas {
		file, _ := filepath.join({folder, LIBRARY_ALPHAS, a.file}, context.temp_allocator)
		library_alpha_add(app, a.stem, fmt.tprintf("%s/%s", id, a.stem), file, a.sum, a.size, a.alpha)
		a.alpha = {}
		p.alphas += 1
	}
	p.presets = pack_presets_add(app, id, u.presets[:])
	// A replaced pack keeps its place in the list.
	if old >= 0 do inject_at(&l.packs, old, p)
	else do append(&l.packs, p)
	l.installed += 1
	dropped := alphas_retarget(app)
	_ = pack_presets_retarget(app)
	left := "" if u.left_out == 0 else fmt.tprintf("; left out %d file%s this version does not read (%s%s)", u.left_out, "" if u.left_out == 1 else "s", u.left, "" if u.left_out == 1 else ", ...")
	bad := "" if u.bad == 0 else fmt.tprintf("; skipped %d line%s of %s it cannot use", u.bad, "" if u.bad == 1 else "s", PACK_BRUSHES)
	lost := "" if dropped == 0 else fmt.tprintf("; %d preset%s used alphas it no longer has and %s round now", dropped, "" if dropped == 1 else "s", "is" if dropped == 1 else "are")
	file_note(app, false, "%s %s%s: %s%s%s%s", "Replaced" if old >= 0 else "Installed", p.name, "" if p.version == "" else fmt.tprintf(" %s", p.version), pack_holds(p), left, bad, lost)
	pack_unpacked_free(u)
	return ""
}

// The Library panel's Replace and Keep the old one, for the pack waiting on them.
pack_pending_answer :: proc(app: ^App, replace: bool) {
	u := app.library.pending
	if u == nil do return
	app.library.pending = nil
	if replace {
		_ = pack_install_finish(app, u, replace = true)
		return
	}
	incoming, _ := filepath.join({app.library.folder, PACK_INCOMING}, context.temp_allocator)
	_ = os.remove_all(incoming)
	file_note(app, false, "Kept %s as it was", u.info.name)
	pack_unpacked_free(u)
}

// A folder name for a new pack: its name in lower case, letters and digits with dashes
// between, never `mine`, a Windows device name or one a pack already has.
@(private = "file")
pack_id :: proc(app: ^App, name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	dash := false
	for r in strings.to_lower(name, context.temp_allocator) {
		if r < 0x80 && (r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
			if dash && strings.builder_len(b) > 0 do strings.write_byte(&b, '-')
			strings.write_rune(&b, r)
			dash = false
		} else {
			dash = true
		}
		if strings.builder_len(b) >= 40 do break
	}
	base := strings.to_string(b)
	if base == "" || base == LIBRARY_MINE || !zip.name_safe(base) do base = fmt.tprintf("%s-pack", base if base != "" else "content")
	for n := 1; ; n += 1 {
		id := base if n == 1 else fmt.tprintf("%s-%d", base, n)
		taken := false
		for p in app.library.packs do taken ||= strings.equal_fold(p.id, id)
		folder, _ := filepath.join({app.library.folder, id}, context.temp_allocator)
		if !taken && !os.exists(folder) do return id
	}
}

// What a pack holds, for notes and the Library panel: "3 alphas and 2 presets", leaving
// out presets when it has none, and alphas when it has only presets.
pack_holds :: proc(p: Pack) -> string {
	alphas := fmt.tprintf("%d alpha%s", p.alphas, "" if p.alphas == 1 else "s")
	presets := fmt.tprintf("%d preset%s", p.presets, "" if p.presets == 1 else "s")
	switch {
	case p.presets == 0: return alphas
	case p.alphas == 0:  return presets
	}
	return fmt.tprintf("%s and %s", alphas, presets)
}

// Forgets pack `i`: its alphas and presets are marked gone and it leaves the list. The
// caller retargets their users (alphas_retarget, pack_presets_retarget).
@(private = "file")
pack_forget :: proc(app: ^App, i: int) {
	l := &app.library
	prefix := fmt.tprintf("%s/", l.packs[i].id)
	for &e in app.alphas do if !e.gone && strings.has_prefix(e.ref, prefix) do e.gone = true
	for &p in l.presets do if strings.equal_fold(p.pack, l.packs[i].id) do p.gone = true
	pack_free(&l.packs[i])
	ordered_remove(&l.packs, i)
}

// Removes pack `i` from the library, with a note.
pack_remove :: proc(app: ^App, i: int) -> bool {
	if i < 0 || i >= len(app.library.packs) do return false
	name := strings.clone(app.library.packs[i].name, context.temp_allocator)
	folder, _ := filepath.join({app.library.folder, app.library.packs[i].id}, context.temp_allocator)
	if err := os.remove_all(folder); err != nil && os.exists(folder) {
		file_note(app, true, "Cannot remove %s: %v", name, err)
		return false
	}
	pack_forget(app, i)
	dropped := alphas_retarget(app)
	_ = pack_presets_retarget(app)
	if dropped == 0 {
		file_note(app, false, "Removed %s from your library", name)
	} else {
		file_note(app, false, "Removed %s from your library; %d preset%s that used its alphas %s round now", name, dropped, "" if dropped == 1 else "s", "is" if dropped == 1 else "are")
	}
	return true
}

// The index of the pack whose alphas `ref` names, or -1 (a built-in, or the person's own).
pack_of_ref :: proc(app: ^App, ref: string) -> int {
	slash := strings.index_byte(ref, '/')
	if slash < 0 do return -1
	for p, i in app.library.packs do if p.id == ref[:slash] do return i
	return -1
}
