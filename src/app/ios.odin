package main

@(require) import "base:runtime"
@(require) import "core:c"
@(require) import sdl "vendor:sdl3"

@(require) import "../ui"

// What differs when the app runs on the iPad: ios/ holds its Info.plist and the native code
// SDL lacks there, and `./build.sh ios` packages it. The imports serve the iOS build alone.

when ODIN_PLATFORM_SUBTARGET_IOS {
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

	// ios/sculpt_ios.m, Scribble (the Apple Pencil's handwriting) for the kit's text fields,
	// which UIKit cannot see since the kit draws them: the bridge learns each frame where
	// the fields show and which has the keys, says which field the pencil began to write in,
	// and once that one has the keys and SDL's text input is on, hands Scribble SDL's own
	// text field to write into, whose text SDL sends as it does the keyboard's.
	@(default_calling_convention = "c")
	foreign {
		sculpt_ios_scribble_start :: proc(window: ^sdl.Window) ---
		sculpt_ios_scribble_fields :: proc(ids: [^]u64, rects: [^][4]f32, count: c.int, focused: u64, typing: bool) ---
		sculpt_ios_scribble_wanted :: proc() -> u64 ---
	}

	// The field the pencil began to write in takes the keys, as a tap on it would, before
	// the frame lays the fields out (kit_frame).
	scribble_focus :: proc(app: ^App) {
		if id := sculpt_ios_scribble_wanted(); id != 0 do app.kit.ctx.text_focus = ui.Id(id)
	}

	// Tells the bridge where this frame's fields show, in the view's points (the kit's
	// points times `scale`), and which has the keys, once the frame laid them out and
	// turned text input on or off.
	scribble_frame :: proc(app: ^App) {
		ctx := &app.kit.ctx
		s := app.kit.scale
		ids: [ui.MAX_TEXT_FIELDS]u64
		rects: [ui.MAX_TEXT_FIELDS][4]f32
		for f, i in ctx.text_fields[:ctx.text_field_count] {
			ids[i] = u64(f.id)
			rects[i] = {f.rect.x * s, f.rect.y * s, f.rect.w * s, f.rect.h * s}
		}
		sculpt_ios_scribble_fields(&ids[0], &rects[0], c.int(ctx.text_field_count), u64(ctx.text_focus), app.kit.text_input)
	}

	// ios/sculpt_ios.m: the system and its version, the model's identifier and the IPA's build
	// number, for the Input diagnostics report (diagnostics.odin), each in `size` bytes.
	@(default_calling_convention = "c")
	foreign {
		sculpt_ios_device_info :: proc(os_name, model, build: [^]u8, size: c.int) ---
	}

	// ios/sculpt_ios.m: keeps a folder out of iCloud and computer backups (the autosave folder,
	// autosave.odin), as Apple asks of files the app can make again.
	@(default_calling_convention = "c")
	foreign {
		sculpt_ios_exclude_from_backup :: proc(path: cstring) -> bool ---
	}
}
