package main

import "core:log"
import sdl "vendor:sdl3"

// What differs when the app runs as an Android app (android/ holds the Gradle project
// that packages it), and the SDL hints every platform shares.

// On Android standard output goes nowhere, so log lines go through SDL_Log, which
// writes them to logcat (`adb logcat -s SDL/APP`). Elsewhere the console logger.
platform_logger :: proc() -> log.Logger {
	when ODIN_PLATFORM_SUBTARGET == .Android {
		return log.Logger{procedure = logcat_logger_proc, lowest_level = .Info when !ODIN_DEBUG else .Debug}
	} else {
		return log.create_console_logger(.Info when !ODIN_DEBUG else .Debug)
	}
}

platform_logger_destroy :: proc(logger: log.Logger) {
	when ODIN_PLATFORM_SUBTARGET != .Android do log.destroy_console_logger(logger)
}

@(private = "file")
logcat_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
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
}

// The main window's flags: a tablet app fills the screen, with the system bars hidden
// until swiped in; panels stay inside the safe area either way.
platform_window_flags :: proc() -> sdl.WindowFlags {
	flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}
	when ODIN_PLATFORM_SUBTARGET == .Android do flags += {.FULLSCREEN}
	return flags
}
