package main

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
	f.io = sdl.IOFromFile(strings.clone_to_cstring(path, context.temp_allocator), "rb")
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
