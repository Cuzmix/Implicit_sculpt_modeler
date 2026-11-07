package main

import "core:c"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

// The system services the app asks SDL for outside the device and window files: the
// last error, the settings folder, memory, the clipboard, the local time and reading a
// file Android may name by a content:// URI. With these here, the tools, panels and
// files never import SDL (scripts/boundary_check.py keeps it so).

// A window: SDL's, opaque to everything but the device and window files.
Window :: sdl.Window

// What SDL said went wrong last, for a log line or a note (SDL's memory, valid until its
// next call fails).
platform_error :: proc() -> string {
	return string(sdl.GetError())
}

// The folder the app keeps its own files in (settings, autosaves), ending in a separator,
// in temp memory; "" where the system gives none.
platform_folder :: proc() -> string {
	dir := sdl.GetPrefPath("Implicit", "Sculpt")
	if dir == nil do return ""
	defer sdl.free(dir)
	return strings.clone(string(cstring(dir)), context.temp_allocator)
}

// The device's memory in bytes.
platform_ram :: proc() -> int {
	return int(sdl.GetSystemRAM()) << 20
}

// Puts `text` on the system clipboard; false when it could not (platform_error says why).
platform_clipboard_set :: proc(text: string) -> bool {
	return sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

// Tells the person `text` in the system's message box over `window` (nil for none), and
// waits until they close it. Only for a start that cannot go on: a scripted run with no
// one to read it (`scripted`) only logs it, as the box would wait for ever.
platform_alert :: proc(window: ^Window, title, text: string, scripted: bool) {
	if scripted do return
	_ = sdl.ShowSimpleMessageBox({.ERROR}, strings.clone_to_cstring(title, context.temp_allocator), strings.clone_to_cstring(text, context.temp_allocator), window)
}

// Whether the system's own modifier is held: the Windows key, or Cmd on Linux.
platform_system_key_held :: proc() -> bool {
	return sdl.GetModState() & sdl.KMOD_GUI != {}
}

// Hides `window` at once, so the app looks closed while it finishes up.
window_hide :: proc(window: ^Window) {
	_ = sdl.HideWindow(window)
}

// A date and time on the device's clock.
Local_Time :: struct {
	year, month, day, hour, minute, second: int,
}

// `t` in the device's local time; SDL reads the time zone the system's own way (Android
// has no /etc/localtime for core:time to read). ok is false when neither the local nor
// the universal time can be had.
platform_local_time :: proc(t: time.Time) -> (lt: Local_Time, ok: bool) {
	dt: sdl.DateTime
	if !sdl.TimeToDateTime(sdl.Time(t._nsec), &dt, true) && !sdl.TimeToDateTime(sdl.Time(t._nsec), &dt, false) do return
	return {int(dt.year), int(dt.month), int(dt.day), int(dt.hour), int(dt.minute), int(dt.second)}, true
}

// A file open for reading through SDL's IO, which also opens Android's content:// URIs.
Read_File :: struct {
	io: ^sdl.IOStream,
}

read_file_open :: proc(path: string) -> (f: Read_File, ok: bool) {
	f.io = sdl.IOFromFile(strings.clone_to_cstring(document_uri(path), context.temp_allocator), "rb")
	return f, f.io != nil
}

// Reads up to len(buf) bytes from where the last read stopped; how many it read.
read_file_read :: proc(f: Read_File, buf: []u8) -> int {
	if len(buf) == 0 do return 0
	return int(sdl.ReadIO(f.io, raw_data(buf), uint(len(buf))))
}

read_file_close :: proc(f: Read_File) {
	_ = sdl.CloseIO(f.io)
}

// Whether `path` is an Android content:// document: the save dialog hands one back with
// leave to write it, but it has no folder, so it is written in place through SDL's IO
// (write_file_whole) and never by a partial copy beside it.
path_is_document :: proc(path: string) -> bool {
	return strings.has_prefix(path, "content://")
}

// The URI to open for `path`: a document whose URI names no file type carries the one
// its dialog's filter chose as a fragment ("content://…/document/42#.obj", file_dialog_done),
// so that every writer tells the format by filepath.ext as it does for a named file. A
// content URI escapes a '#' in its path as %23, so a bare one only ever starts that fragment.
document_uri :: proc(path: string) -> string {
	if !path_is_document(path) do return path
	if at := strings.index_byte(path, '#'); at >= 0 do return path[:at]
	return path
}

// Writes `data` over `path` through SDL's IO, which opens Android's content:// documents
// for writing ("wb" asks the content resolver for "wt", truncating), in chunks of `chunk`
// bytes, then flushes and closes it, where the provider commits it. "" when written, else
// why not, in temp memory.
write_file_whole :: proc(path: string, data: []u8, chunk: int) -> string {
	io := sdl.IOFromFile(strings.clone_to_cstring(document_uri(path), context.temp_allocator), "wb")
	if io == nil do return strings.concatenate({"cannot open the file: ", platform_error()}, context.temp_allocator)
	for at := 0; at < len(data); at += chunk {
		piece := data[at:min(at + chunk, len(data))]
		if sdl.WriteIO(io, raw_data(piece), uint(len(piece))) != uint(len(piece)) {
			why := strings.concatenate({"cannot write the file: ", platform_error()}, context.temp_allocator)
			_ = sdl.CloseIO(io)
			return why
		}
	}
	// A provider may refuse the bytes only when they are flushed or the file is closed, so
	// both results count.
	flushed := sdl.FlushIO(io)
	why := "" if flushed else strings.concatenate({"cannot write the file: ", platform_error()}, context.temp_allocator)
	if !sdl.CloseIO(io) && why == "" do why = strings.concatenate({"cannot close the file: ", platform_error()}, context.temp_allocator)
	return why
}

// The device's preferred languages, most preferred first, as ISO codes with an optional
// region ("de", "pt-BR"), in temp memory; empty when the system does not say.
platform_languages :: proc() -> []string {
	count: c.int
	list := sdl.GetPreferredLocales(&count)
	if list == nil do return nil
	defer sdl.free(list)
	out := make([]string, int(count), context.temp_allocator)
	for i in 0 ..< int(count) {
		l := list[i]
		if l == nil || l.language == nil do continue
		out[i] = strings.clone(string(l.language), context.temp_allocator)
		if l.country != nil do out[i] = strings.concatenate({out[i], "-", string(l.country)}, context.temp_allocator)
	}
	return out
}

// Whether the device is set to its dark appearance; a system that does not say counts as
// dark, as the app's own default theme is.
platform_dark :: proc() -> bool {
	return sdl.GetSystemTheme() != .LIGHT
}

// The picture on the system clipboard as an image file's bytes (owned by the caller), the
// first of the kinds the app reads that it holds; nil when it holds none. A copied image
// is offered as PNG by every system SDL speaks to, and a copied photo often as JPEG too.
platform_clipboard_image :: proc(allocator := context.allocator) -> []u8 {
	for mime in ([?]cstring{"image/png", "image/jpeg", "image/bmp"}) {
		if !sdl.HasClipboardData(mime) do continue
		size: uint
		data := sdl.GetClipboardData(mime, &size)
		if data == nil do continue
		defer sdl.free(data)
		if size == 0 do continue
		out := make([]u8, int(size), allocator)
		copy(out, ([^]u8)(data)[:size])
		return out
	}
	return nil
}

// The text on the system clipboard, in temp memory; "" when it holds none.
platform_clipboard_text :: proc() -> string {
	text := sdl.GetClipboardText()
	if text == nil do return ""
	defer sdl.free(rawptr(text))
	return strings.clone(string(cstring(text)), context.temp_allocator)
}
