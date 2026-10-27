package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:unicode"
import "core:unicode/utf8"

import "../sculpt"
import "../zip"

// The library: a folder beside the settings file that keeps what the person adds, so it
// is there at the next start. Its subfolder `mine` holds their own, and each content
// pack installed has a folder of its own beside it (pack.odin). Today it keeps brush
// alphas: Load image copies the image into mine/alphas, and presets, the settings and
// scripts name an alpha `mine/<stem>` or `<pack>/<stem>`, so a preset that uses one comes
// back with it.

LIBRARY_FOLDER :: "library"
LIBRARY_MINE :: "mine"
LIBRARY_ALPHAS :: "alphas"

// The most alphas a start reads from the library: far more than a real collection, and
// a bound on how long a start can take.
LIBRARY_ALPHAS_MAX :: 256

// Seconds Remove from library waits for its second tap.
ALPHA_REMOVE_ARM_TIME :: 3

// The image files the library reads as alphas, by extension.
ALPHA_EXTENSIONS := [?]string{".png", ".jpg", ".jpeg", ".bmp", ".tga", ".qoi"}

Library :: struct {
	folder:       string, // owned; "" for a run that keeps no settings, and so no library
	alphas:       int,    // the person's own, read at start or kept since
	skipped:      int,    // files and pack folders in the library it cannot read
	packs:        [dynamic]Pack, // sorted by id at start, then in the order installed
	presets:      [dynamic]Pack_Preset, // every pack's brush presets, a removed pack's marked gone
	meshes:       [dynamic]Pack_Mesh, // every pack's base meshes, a removed pack's marked gone
	installed:    int,    // packs installed this run
	refused:      int,    // packs refused this run
	worker:       ^Pack_Worker,    // the install under way, or nil
	pending:      ^Pack_Unpacked,  // a pack waiting on Replace, or nil
}

// The library's folder: `library` beside the settings file or, for a settings file of
// another name (--settings-file), `<its name>-library`, as macros_folder does, so runs
// given their own settings keep their own library.
library_folder :: proc(settings: string) -> string {
	if settings == "" do return ""
	dir, base := filepath.split(settings)
	name := LIBRARY_FOLDER if base == SETTINGS_FILE else fmt.tprintf("%s-%s", filepath.stem(base), LIBRARY_FOLDER)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// The folder the person's own alphas are kept in.
library_alphas_folder :: proc(app: ^App) -> string {
	path, _ := filepath.join({app.library.folder, LIBRARY_MINE, LIBRARY_ALPHAS}, context.temp_allocator)
	return path
}

// Waits for an install under way (a closing app leaves no half-written pack), and frees
// the library's list.
library_destroy :: proc(app: ^App) {
	l := &app.library
	if l.worker != nil {
		thread.join(l.worker.thread)
		if u := l.worker.result; u != nil do pack_unpacked_free(u)
		thread.destroy(l.worker.thread)
		delete(l.worker.path)
		delete(l.worker.library)
		free(l.worker)
	}
	if l.pending != nil do pack_unpacked_free(l.pending)
	if l.folder != "" {
		incoming, _ := filepath.join({l.folder, PACK_INCOMING}, context.temp_allocator)
		_ = os.remove_all(incoming)
	}
	for &p in l.packs do pack_free(&p)
	delete(l.packs)
	for &p in l.presets do delete(p.pack)
	delete(l.presets)
	for &m in l.meshes do pack_mesh_free(&m)
	delete(l.meshes)
	delete(l.folder)
	l^ = {}
}

// Reads the library at `folder` (library_folder): the person's own alphas after the
// built-ins, then each pack's, packs sorted by folder name and alphas by name, so every
// start lists them alike. Whatever an interrupted install or replace left is cleared
// first. A file that is not an image the app reads, or a pack folder without a
// pack.txt, is skipped and counted, with one note naming the first; it stays on disk
// for the person to look at.
library_load :: proc(app: ^App, folder: string) {
	if folder == "" do return
	l := &app.library
	l.folder = strings.clone(folder)
	for leftover in ([]string{PACK_INCOMING, PACK_ASIDE}) {
		path, _ := filepath.join({folder, leftover}, context.temp_allocator)
		_ = os.remove_all(path)
	}
	first_skipped := ""
	l.alphas = library_alphas_load(app, library_alphas_folder(app), LIBRARY_MINE, &first_skipped)
	infos, err := os.read_directory_by_path(folder, -1, context.temp_allocator)
	if err == nil {
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for fi in infos {
			if fi.type != .Directory || strings.has_prefix(fi.name, ".") || strings.equal_fold(fi.name, LIBRARY_MINE) do continue
			p := Pack{}
			text_path, _ := filepath.join({fi.fullpath, PACK_FILE}, context.temp_allocator)
			text, text_err := os.read_entire_file(text_path, context.temp_allocator)
			if text_err != nil || !zip.name_safe(fi.name) || !pack_text_parse(string(text), &p) {
				pack_free(&p)
				if first_skipped == "" do first_skipped = fi.name
				l.skipped += 1
				continue
			}
			p.id = strings.clone(fi.name)
			alphas, _ := filepath.join({fi.fullpath, LIBRARY_ALPHAS}, context.temp_allocator)
			p.alphas = library_alphas_load(app, alphas, p.id, &first_skipped)
			// Install wrote brushes.txt as it checked it, so a line now refused was changed
			// by hand, and is left out like a file the app cannot read.
			brushes_path, _ := filepath.join({fi.fullpath, PACK_BRUSHES}, context.temp_allocator)
			if brushes, brushes_err := os.read_entire_file(brushes_path, context.temp_allocator); brushes_err == nil {
				read: [dynamic]Pack_Preset_Read
				read.allocator = context.temp_allocator
				if bad := pack_brushes_parse(string(brushes), alphas_of_pack(app, p.id), &read, context.temp_allocator); bad > 0 {
					if first_skipped == "" do first_skipped = fmt.tprintf("%s/%s", fi.name, PACK_BRUSHES)
					l.skipped += 1
				}
				p.presets = pack_presets_add(app, p.id, read[:])
			}
			p.meshes = pack_meshes_load(app, p.id, fi.fullpath)
			append(&l.packs, p)
		}
	}
	switch {
	case first_skipped == "":
	case l.skipped == 1:
		file_note(app, true, "Skipped %s in the library: the app cannot read it", first_skipped)
	case:
		file_note(app, true, "Skipped %d files and folders in the library that the app cannot read, %s first", l.skipped, first_skipped)
	}
}

// Reads the images in `dir` as alphas named `<prefix>/<stem>`, sorted by stem; returns
// how many, counting what it skips in the library's `skipped`.
@(private = "file")
library_alphas_load :: proc(app: ^App, dir, prefix: string, first_skipped: ^string) -> (loaded: int) {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return
	// By stem first, so "rock" comes before "rock-2" whatever their extensions.
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
		sa, sb := filepath.stem(a.name), filepath.stem(b.name)
		return sa < sb if sa != sb else a.name < b.name
	})
	for fi in infos {
		if fi.type != .Regular || strings.has_prefix(fi.name, ".") || !alpha_extension(fi.name) do continue
		stem := filepath.stem(fi.name)
		ref := fmt.tprintf("%s/%s", prefix, stem)
		// Two files of one stem (rock.png and rock.jpg) would be one name: the first wins.
		if loaded >= LIBRARY_ALPHAS_MAX || alpha_find(app, ref) >= 0 {
			app.library.skipped += 1
			continue
		}
		data, read_err := os.read_entire_file(fi.fullpath, context.allocator)
		if read_err != nil {
			app.library.skipped += 1
			continue
		}
		defer delete(data)
		alpha, _, _, failed := alpha_decode(data)
		if failed != "" {
			if first_skipped^ == "" do first_skipped^ = fmt.tprintf("%s/%s", prefix, fi.name)
			app.library.skipped += 1
			continue
		}
		library_alpha_add(app, stem, ref, fi.fullpath, hash.crc32(data), len(data), alpha)
		loaded += 1
	}
	return
}

// Adds an alpha read from the library file `file`, and returns its index.
library_alpha_add :: proc(app: ^App, stem, ref, file: string, sum: u32, size: int, alpha: sculpt.Alpha) -> int {
	i := alpha_add(app, stem, ref, alpha)
	e := &app.alphas[i]
	e.file, e.sum, e.size = strings.clone(file), sum, size
	return i
}

alpha_extension :: proc(name: string) -> bool {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	return slice.contains(ALPHA_EXTENSIONS[:], ext)
}

// Load image: the image becomes an alpha, as alpha_load makes it, and a copy goes into
// the library, so that it, and every preset that uses it, are there at the next start.
// The same image loaded again is found there by its bytes rather than kept twice. A run
// with no library, or a copy that cannot be written, loads it for this run only.
alpha_keep :: proc(app: ^App, path: string) -> bool {
	if app.library.folder == "" do return alpha_load(app, path)
	name := filepath.base(path)
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot load alpha %s: %v", name, err)
		return false
	}
	defer delete(data)
	sum := hash.crc32(data)
	for e, i in app.alphas {
		if e.gone || e.file == "" || e.size != len(data) || e.sum != sum do continue
		kept, kept_err := os.read_entire_file(e.file, context.temp_allocator)
		if kept_err != nil || !slice.equal(kept, data) do continue
		app.brush.alpha = i
		file_note(app, false, "Alpha %s is in your library already, as %s", name, e.name)
		return true
	}
	alpha, width, height, bad := alpha_decode(data)
	if bad != "" {
		file_note(app, true, "Cannot load alpha %s: %s", name, bad)
		return false
	}
	folder := library_alphas_folder(app)
	stem, ext := library_stem(folder, filepath.stem(path), path, data)
	file, _ := filepath.join({folder, fmt.tprintf("%s%s", stem, ext)}, context.temp_allocator)
	failed := ""
	if dir_err := os.make_directory_all(folder); dir_err != nil && !os.exists(folder) {
		failed = fmt.tprint(dir_err)
	} else {
		failed = write_durably(file, data)
	}
	if failed != "" {
		app.brush.alpha = alpha_add(app, stem, stem, alpha)
		alpha_loaded_note(app, name, alpha, width, height, fmt.tprintf(", for this run only: the library could not keep a copy (%s)", failed))
		return true
	}
	app.brush.alpha = library_alpha_add(app, stem, fmt.tprintf("%s/%s", LIBRARY_MINE, stem), file, sum, len(data), alpha)
	app.library.alphas += 1
	alpha_loaded_note(app, name, alpha, width, height, ", and kept it in your library")
	return true
}

// A name for an image kept in `folder`, and its extension: the file's own stem made safe
// for every OS (letters, digits, spaces and - _ ( ) kept, anything else an underscore),
// with -2, -3 and on when a file there already has it in any case. The extension is the
// one the bytes say, since a picked content:// URI has none.
@(private = "file")
library_stem :: proc(folder, wanted, path: string, data: []u8) -> (stem, ext: string) {
	switch {
	case len(data) >= 4 && string(data[:4]) == "\x89PNG": ext = ".png"
	case len(data) >= 2 && data[0] == 0xff && data[1] == 0xd8: ext = ".jpg"
	case len(data) >= 2 && string(data[:2]) == "BM": ext = ".bmp"
	case len(data) >= 4 && string(data[:4]) == "qoif": ext = ".qoi"
	case alpha_extension(path): ext = strings.to_lower(filepath.ext(path), context.temp_allocator)
	case: ext = ".tga"
	}
	b := strings.builder_make(context.temp_allocator)
	for r in wanted {
		if strings.builder_len(b) + utf8.rune_size(r) > 48 do break
		keep := unicode.is_letter(r) || unicode.is_digit(r) || r == ' ' || r == '-' || r == '_' || r == '(' || r == ')'
		strings.write_rune(&b, r if keep else '_')
	}
	base := strings.trim(strings.to_string(b), " _")
	if base == "" || !zip.name_safe(fmt.tprintf("%s%s", base, ext)) do base = "alpha"
	taken := make([dynamic]string, context.temp_allocator)
	if infos, err := os.read_directory_by_path(folder, -1, context.temp_allocator); err == nil {
		for fi in infos do append(&taken, filepath.stem(fi.name))
	}
	for n := 1; ; n += 1 {
		stem = base if n == 1 else fmt.tprintf("%s-%d", base, n)
		clash := false
		for t in taken do clash ||= strings.equal_fold(t, stem)
		if !clash do return stem, ext
	}
}

// Whether the alpha at `i` is one of the person's own in the library, which Remove from
// library takes out (a pack's go with their pack).
alpha_is_mine :: proc(app: ^App, i: int) -> bool {
	if i < 0 || i >= len(app.alphas) do return false
	e := app.alphas[i]
	return !e.gone && e.file != "" && strings.has_prefix(e.ref, LIBRARY_MINE + "/")
}

// Takes the person's alpha at index `i` out of the library: its file goes, and the brush
// and every preset that used it fall back to round, with a note counting those presets.
// Its slot stays, marked gone, so that every index held elsewhere stays valid.
alpha_remove :: proc(app: ^App, i: int) -> bool {
	if !alpha_is_mine(app, i) do return false
	e := &app.alphas[i]
	if err := os.remove(e.file); err != nil && os.exists(e.file) {
		file_note(app, true, "Cannot remove alpha %s from your library: %v", e.name, err)
		return false
	}
	e.gone = true
	app.library.alphas -= 1
	used := alphas_retarget(app)
	if used == 0 {
		file_note(app, false, "Removed alpha %s from your library", e.name)
	} else {
		file_note(app, false, "Removed alpha %s from your library; %d preset%s that used it %s round now", e.name, used, "" if used == 1 else "s", "is" if used == 1 else "are")
	}
	return true
}

// After alphas were taken out (marked gone), and maybe others of the same names added (a
// pack replaced): the brush, its plain values and every preset holding a gone alpha get
// the alpha now of that name, or round. Returns how many presets went round.
alphas_retarget :: proc(app: ^App) -> (dropped: int) {
	retarget :: proc(app: ^App, i: ^int) -> bool {
		if i^ < 0 || i^ >= len(app.alphas) || !app.alphas[i^].gone do return false
		i^ = alpha_find(app, app.alphas[i^].ref)
		return i^ < 0
	}
	_ = retarget(app, &app.brush.alpha)
	_ = retarget(app, &app.brush.plain.alpha)
	for &p in app.presets[:app.preset_count] do dropped += int(retarget(app, &p.values.alpha))
	for &p in app.library.presets do if !p.gone do _ = retarget(app, &p.preset.values.alpha)
	return
}
