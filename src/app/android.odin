package main

@(require) import "base:runtime"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

import "../render"

// What differs when the app runs as an Android app (android/ holds the Gradle project
// that packages it) or on any tablet, and the SDL hints every platform shares. The iPad's
// own pieces are in ios.odin.

// A tablet build, Android's or the iPad's: less memory and a tiled GPU, a finger before a
// mouse, the whole screen. What only Android needs tests `.Android` instead.
MOBILE :: ODIN_PLATFORM_SUBTARGET != .Default

// A tablet app's standard output goes nowhere, so log lines go through SDL_Log, which
// writes them to logcat on Android (`adb logcat -s SDL/APP`) and to the system log on the
// iPad; elsewhere the console logger. With a `log_path` every line also goes to that file,
// and a crash is written there too (crash_log.odin).
platform_logger :: proc(log_path: string) -> log.Logger {
	inner: log.Logger
	when MOBILE {
		inner = log.Logger{procedure = system_logger_proc, lowest_level = .Info when !ODIN_DEBUG else .Debug}
	} else {
		// From the heap: the debug build's leak tracking starts before the logger and reports
		// after it is gone.
		inner = log.create_console_logger(.Info when !ODIN_DEBUG else .Debug, allocator = runtime.heap_allocator())
	}
	if log_path == "" || !crash_log_open(log_path, crash_log_header()) do return inner
	return crash_logger(inner)
}

platform_logger_destroy :: proc(logger: log.Logger) {
	inner := logger
	if crash_log.file != nil {
		inner = crash_log.inner
		crash_log_close()
	}
	when !MOBILE do log.destroy_console_logger(inner, runtime.heap_allocator())
}

// Where an interactive run's log goes: the app's folder, which on the iPad is its Documents
// folder, since Files shows it (On My iPad > Sculpt) and the log can be read on the iPad
// itself. "" where the system gives no folder.
platform_log_path :: proc() -> string {
	when ODIN_PLATFORM_SUBTARGET_IOS {
		// SDL's Documents folder on iOS is the app's own, and ends with a slash.
		documents := string(sdl.GetUserFolder(.DOCUMENTS))
		return "" if documents == "" else strings.concatenate({documents, CRASH_LOG_NAME}, context.temp_allocator)
	} else {
		folder := platform_folder()
		return "" if folder == "" else strings.concatenate({folder, CRASH_LOG_NAME}, context.temp_allocator)
	}
}

@(private = "file")
system_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	priority: sdl.LogPriority
	switch level {
	case .Debug:   priority = .DEBUG
	case .Info:    priority = .INFO
	case .Warning: priority = .WARN
	case .Error:   priority = .ERROR
	case .Fatal:   priority = .CRITICAL
	}
	// A copy on the stack: worker threads log too, and their temp allocators are never freed.
	buf: [2048]u8
	n := copy(buf[:len(buf) - 1], text)
	buf[n] = 0
	sdl.LogMessage(i32(sdl.LogCategory.APPLICATION), priority, "%s", cstring(&buf[0]))
}

// Hints that must be set before SDL_Init.
platform_hints :: proc() {
	// Fingers reach the pointer through touch.odin, which keeps the touch's first finger as
	// the pointer and never counts it landing somewhere new as a drag; SDL's own turning
	// of fingers into the mouse does neither.
	_ = sdl.SetHint(sdl.HINT_TOUCH_MOUSE_EVENTS, "0")
	// Nor the other way round: the pen and (on Android, by default) the mouse also come as
	// stand-in fingers, which would join a real finger's touch as a second finger and
	// pinch the view mid-stroke. The pen arrives as the pen and as the mouse (Pen kind).
	_ = sdl.SetHint(sdl.HINT_PEN_TOUCH_EVENTS, "0")
	_ = sdl.SetHint(sdl.HINT_MOUSE_TOUCH_EVENTS, "0")
	when ODIN_PLATFORM_SUBTARGET == .Android {
		// Back closes the open menu instead of leaving the app, which would drop unsaved
		// work without asking (the store rules); the home gesture still leaves.
		_ = sdl.SetHint(sdl.HINT_ANDROID_TRAP_BACK_BUTTON, "1")
	}
	when ODIN_PLATFORM_SUBTARGET_IOS {
		// SDL holds back every edge swipe of a fullscreen window unless told otherwise, so
		// that the first swipe up from the bottom only shows the home indicator and a second
		// goes home, and likewise at the top for the Notification and Control Centers.
		// Nothing in the app needs the screen's very edge (the safe zone's orbit is a band
		// along the viewport, wider than the system's strip), so no edge is held back: the
		// indicator stays, and one swipe goes home, to the app switcher or to the Centers,
		// as in any iPad app.
		_ = sdl.SetHint(sdl.HINT_IOS_HIDE_HOME_INDICATOR, "0")
	}
}

// The main window's flags: a tablet app fills the screen, with the system bars hidden
// until swiped in; panels stay inside the safe area either way.
platform_window_flags :: proc() -> sdl.WindowFlags {
	flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY} + render.window_flags()
	when MOBILE do flags += {.FULLSCREEN}
	return flags
}

when ODIN_PLATFORM_SUBTARGET == .Android {
	// android/app/jni/android_main.c: from then on sends the pen's lean, which
	// SculptActivity reads from Android and SDL leaves out, as SDL user events of
	// `event_type` (pencil.odin).
	@(default_calling_convention = "c")
	foreign {
		sculpt_android_pen_lean_start :: proc(event_type: u32) ---
		// The same, from then on, for the pen's older samples of each move (pen_samples.odin).
		sculpt_android_samples_start :: proc(event_type: u32) ---
	}
}
