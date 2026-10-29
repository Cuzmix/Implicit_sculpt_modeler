package main

@(require) import "base:runtime"
@(require) import "core:c"
@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:os"
@(require) import "core:sync"
@(require) import sdl "vendor:sdl3"

// What differs when the app runs on the iPad: ios/ holds its Info.plist and the native code
// SDL lacks there, and `./build.sh ios` packages it. The imports serve the iOS build alone.

when ODIN_PLATFORM_SUBTARGET_IOS {
	// Without a Mac the iPad's system log is out of reach, so there every log line also goes
	// to sculpt-log.txt in the app's Documents folder, which the Files app shows (On My iPad >
	// Sculpt). The run before keeps its log as sculpt-log-previous.txt: the log of a run that
	// crashed would otherwise be replaced by the next launch. Worker threads log too, hence
	// the lock; each line is written as it comes, so a crash loses none.
	@(private = "file")
	ios_log: struct {
		file: ^os.File,
		lock: sync.Mutex,
	}

	ios_log_open :: proc() {
		// SDL's Documents folder on iOS is the app's own, and ends with a slash.
		documents := string(sdl.GetUserFolder(.DOCUMENTS))
		if documents == "" do return
		buf: [1024]u8
		path := fmt.bprintf(buf[:512], "%ssculpt-log.txt", documents)
		_ = os.rename(path, fmt.bprintf(buf[512:], "%ssculpt-log-previous.txt", documents))
		if file, err := os.create(path); err == nil do ios_log.file = file
	}

	ios_log_write :: proc(level: log.Level, text: string) {
		name: string
		switch level {
		case .Debug:   name = "debug"
		case .Info:    name = "info"
		case .Warning: name = "warning"
		case .Error:   name = "error"
		case .Fatal:   name = "fatal"
		}
		// One write a line, built on the stack: a worker's temp allocator is never freed.
		buf: [2048]u8
		line := fmt.bprintf(buf[:], "%s: %s\n", name, text)
		// The file is looked at under the lock: a worker may log while ios_log_close runs.
		sync.guard(&ios_log.lock)
		if ios_log.file != nil do _, _ = os.write(ios_log.file, transmute([]u8)line)
	}

	ios_log_close :: proc() {
		sync.guard(&ios_log.lock)
		if ios_log.file != nil do _ = os.close(ios_log.file)
		ios_log.file = nil
	}
	// SDL_RunApp enters UIApplicationMain, which never returns: UIKit takes the main thread
	// and its run loop, and calls ios_main on that thread once the app has launched.
	ios_start :: proc() {
		args := runtime.args__
		_ = sdl.RunApp(c.int(len(args)), raw_data(args), ios_main, nil)
	}

	// SDL's call into the app. app_main returns only after the system asked the app to end
	// (SDL's quit at applicationWillTerminate), and exits by itself on a failure.
	@(private = "file")
	ios_main :: proc "c" (argc: c.int, argv: [^]cstring) -> c.int {
		context = runtime.default_context()
		app_main()
		return 0
	}

	// ios/sculpt_ios.m: SDL 3.4 has no file dialogs on iOS, so the first three stand in for
	// its three (files.odin) with the same callback and answers: the document picker for a
	// file or a folder, and for a save a name first, then the folder it goes in. The last
	// says whether the app may write beside a path: inside its own container or a folder
	// picked this run, never beside a file picked alone (file_writable_beside).
	@(default_calling_convention = "c")
	foreign {
		sculpt_ios_open_file_dialog :: proc(callback: sdl.DialogFileCallback, userdata: rawptr, window: ^sdl.Window, filters: [^]sdl.DialogFileFilter, nfilters: c.int) ---
		sculpt_ios_save_file_dialog :: proc(callback: sdl.DialogFileCallback, userdata: rawptr, window: ^sdl.Window, filters: [^]sdl.DialogFileFilter, nfilters: c.int, default_location: cstring) ---
		sculpt_ios_open_folder_dialog :: proc(callback: sdl.DialogFileCallback, userdata: rawptr, window: ^sdl.Window) ---
		sculpt_ios_writable_beside :: proc(path: cstring) -> bool ---
	}

	// ios/sculpt_ios.m, the Apple Pencil's pieces SDL lacks (pencil.odin): the double-tap
	// and squeeze sent as SDL user events of `event_type`, whether the iPad's Only Draw
	// with Apple Pencil is on, and the Pencil Pro's haptics at a point in window coordinates.
	@(default_calling_convention = "c")
	foreign {
		sculpt_ios_pencil_start :: proc(window: ^sdl.Window, event_type: u32) ---
		sculpt_ios_pencil_only :: proc() -> bool ---
		sculpt_ios_haptic :: proc(kind: c.int, x, y: f32) ---
		// From then on sends the pencil's coalesced samples as `event_type` (pen_samples.odin).
		sculpt_ios_samples_start :: proc(window: ^sdl.Window, event_type: u32) ---
	}
}
