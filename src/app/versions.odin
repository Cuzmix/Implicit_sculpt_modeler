package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// Earlier saves of a scene file. Saving over a file keeps the one it replaces as
// "<folder>/<stem> versions/<stem> YYYY-MM-DD HH.MM.SS.sculpt", stamped with when that
// file was saved, and keeps the newest app.versions_kept of them: ZBrush's advice to save
// incrementally and keep a few versions, without having to.

VERSIONS_KEPT := [?]i32{0, 3, 5, 10}
VERSIONS_KEPT_NAMES := [?]string{"Off", "Keep 3", "Keep 5", "Keep 10"}
// Five saves back covers an evening's work at a save every half hour or so; at 10M that
// is about 1.8 GB beside the file, which the System tab says.
VERSIONS_DEFAULT :: 5
// "YYYY-MM-DD HH.MM.SS": dots, since Windows refuses colons in names.
@(private = "file")
STAMP_LEN :: 19

// The kept count snapped to the nearest choice, so a hand-edited settings file still
// shows in the select.
versions_kept :: proc(n: i32) -> i32 {
	best := VERSIONS_KEPT[0]
	for k in VERSIONS_KEPT do if abs(k - n) < abs(best - n) do best = k
	return best
}

// Where the earlier saves of `path` go.
versions_folder :: proc(path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({filepath.dir(path), fmt.tprintf("%s versions", filepath.stem(path))}, allocator) or_else ""
}

// `t` in the device's local time as a version's stamp. SDL reads the time zone the
// system's own way (Android has no /etc/localtime for core:time to read).
version_stamp :: proc(t: time.Time) -> string {
	dt: sdl.DateTime
	if !sdl.TimeToDateTime(sdl.Time(t._nsec), &dt, true) && !sdl.TimeToDateTime(sdl.Time(t._nsec), &dt, false) do return "0000-00-00 00.00.00"
	return fmt.tprintf("%04d-%02d-%02d %02d.%02d.%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
}

// Whether `name` is one of `stem`'s versions: "<stem> <stamp>.sculpt" or, for a second
// save in the same second, "<stem> <stamp>-N.sculpt". Nothing else in the folder is
// ever listed or deleted.
version_name_matches :: proc(name, stem: string) -> bool {
	if !strings.has_prefix(name, stem) || !strings.has_suffix(name, ".sculpt") do return false
	rest := name[len(stem):len(name) - len(".sculpt")]
	if len(rest) < 1 + STAMP_LEN || rest[0] != ' ' do return false
	PATTERN :: "dddd-dd-dd dd.dd.dd"
	for c, i in PATTERN {
		r := rest[1 + i]
		if c == 'd' && (r < '0' || r > '9') do return false
		if c != 'd' && r != u8(c) do return false
	}
	tail := rest[1 + STAMP_LEN:]
	if tail == "" do return true
	if len(tail) < 2 || tail[0] != '-' do return false
	for r in tail[1:] do if r < '0' || r > '9' do return false
	return true
}

// The versions of `path` on the disk, newest first (by their stamps, then their
// numbers, so that "-10" comes after "-9"): full paths in `allocator`.
versions_found :: proc(path: string, allocator := context.temp_allocator) -> []string {
	infos, err := os.read_directory_by_path(versions_folder(path), -1, context.temp_allocator)
	if err != nil do return nil
	stem := filepath.stem(path)
	Found :: struct {
		path:  string,
		stamp: string,
		n:     int,
	}
	found := make([dynamic]Found, context.temp_allocator)
	for fi in infos {
		if fi.type != .Regular || !version_name_matches(fi.name, stem) do continue
		stamp, n := version_parse(fi.name, stem)
		append(&found, Found{fi.fullpath, stamp, n})
	}
	slice.sort_by(found[:], proc(a, b: Found) -> bool {return a.stamp > b.stamp || (a.stamp == b.stamp && a.n > b.n)})
	paths := make([]string, len(found), allocator)
	for f, i in found do paths[i] = strings.clone(f.path, allocator)
	return paths
}

// A version name's stamp and number (none counts as 1); the name must match.
@(private = "file")
version_parse :: proc(name, stem: string) -> (stamp: string, n: int) {
	rest := name[len(stem) + 1:len(name) - len(".sculpt")]
	n = 1
	if len(rest) > STAMP_LEN do n = strconv.parse_int(rest[STAMP_LEN + 1:]) or_else 1
	return rest[:STAMP_LEN], n
}

// Keeps the file at `path`, about to be replaced, as a version: a hard link (no copy,
// no time), or where the file system has none (FAT cards, some network drives) a copy
// written beside it, synced and renamed in. The folder entry is synced so that it lasts
// as long as the replacement does. Returns the version's path, or what went wrong.
version_keep :: proc(path: string) -> (kept: string, err: string) {
	saved, terr := os.modification_time_by_path(path)
	if terr != nil do saved = time.now()
	folder := versions_folder(path)
	made := !os.exists(folder)
	if merr := os.make_directory_all(folder); merr != nil && !os.is_dir(folder) {
		return "", fmt.tprintf("cannot make %s: %v", filepath.base(folder), merr)
	}
	stem, stamp := filepath.stem(path), version_stamp(saved)
	// Saves within one second take the next number after the highest there, never a gap
	// a pruned one left, so the numbers stay in the order the saves came.
	n := 0
	for p in versions_found(path) {
		pstamp, pn := version_parse(filepath.base(p), stem)
		if pstamp == stamp do n = max(n, pn)
	}
	name := fmt.tprintf("%s %s.sculpt", stem, stamp) if n == 0 else fmt.tprintf("%s %s-%d.sculpt", stem, stamp, n + 1)
	target := filepath.join({folder, name}, context.temp_allocator) or_else ""
	if lerr := os.link(path, target); lerr != nil {
		partial := strings.concatenate({target, ".partial"}, context.temp_allocator)
		if cerr := os.copy_file(partial, path); cerr != nil {
			_ = os.remove(partial)
			return "", fmt.tprintf("cannot copy it into %s: %v", filepath.base(folder), cerr)
		}
		if f, oerr := os.open(partial, {.Read, .Write}); oerr == nil {
			_ = os.sync(f)
			os.close(f)
		}
		if rerr := os.rename(partial, target); rerr != nil {
			_ = os.remove(partial)
			return "", fmt.tprintf("cannot keep it in %s: %v", filepath.base(folder), rerr)
		}
	}
	sync_folder(folder)
	if made do sync_folder(filepath.dir(folder))
	return target, ""
}

// Deletes the oldest versions of `path` beyond `kept`; with none to keep (Off) it
// leaves the folder as it is, so turning versions off never deletes old saves.
versions_prune :: proc(path: string, kept: int) {
	if kept <= 0 do return
	found := versions_found(path)
	for p in found[min(kept, len(found)):] do _ = os.remove(p)
}
