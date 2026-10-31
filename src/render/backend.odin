package render

import "core:fmt"
import "core:log"

import sdl "vendor:sdl3"

// Render draws with one GPU API a platform: its own Metal backend (mtl_*.odin) on Apple's
// platforms, its own Vulkan backend (vk_*.odin) everywhere else. Windows are made for it
// (SDL_WINDOW_METAL or SDL_WINDOW_VULKAN), and a device that cannot run it cannot run the
// app: there is no other backend to hand the run to.

// Why the backend did not start, in words for the message the app shows before it closes;
// empty while it has not failed. Kept in a buffer of its own, as the reasons are formatted
// in temp memory the frame loop frees.
@(private = "file")
error_text: [200]u8
@(private = "file")
error_len: int

backend_error :: proc() -> string {
	return string(error_text[:error_len])
}

// Logs why the backend `name` cannot start and keeps the reason for backend_error.
backend_fail :: proc(name: string, format: string, args: ..any) {
	text := fmt.tprintf(format, ..args)
	log.errorf("%s: %s", name, text)
	error_len = copy(error_text[:], text)
}

// Readies the backend before any window is created: Vulkan's loader must be found first,
// as SDL makes Vulkan windows with it. False, with backend_error saying why, where it is not.
backend_select :: proc() -> bool {
	error_len = 0
	when !METAL {
		if !sdl.Vulkan_LoadLibrary(nil) {
			backend_fail("Vulkan", "no Vulkan loader (%s)", sdl.GetError())
			return false
		}
	}
	return true
}

// The flags windows need for the backend.
window_flags :: proc() -> sdl.WindowFlags {
	when METAL do return {.METAL}
	else do return {.VULKAN}
}

// The backend's name for logs and the exit stats.
backend_name :: proc() -> string {
	return "metal" when METAL else "vulkan"
}

// The backend's name for people, in the settings and the message a failed start shows.
backend_title :: proc() -> string {
	return "Metal" when METAL else "Vulkan"
}
