package render

import "core:fmt"
import "core:log"

import sdl "vendor:sdl3"

// Which GPU API render drives, chosen before any window exists (windows drawn by Vulkan
// need SDL_WINDOW_VULKAN, by Metal SDL_WINDOW_METAL) and kept for the run. SDL_GPU is the
// fallback every other backend hands the run to when it cannot start.
Gpu_Backend :: enum u8 {
	SDL_GPU,
	Vulkan, // vk_*.odin, everywhere but Apple's platforms
	Metal,  // mtl_*.odin, Apple's platforms only
}

gpu_backend: Gpu_Backend

// Why the backend asked for did not start, in words for the settings and the exit stats;
// empty when it started or was not asked for. Kept in a buffer of its own, as the reasons
// are formatted in temp memory the frame loop frees.
@(private = "file")
fallback_text: [200]u8
@(private = "file")
fallback_len: int

backend_fallback :: proc() -> string {
	return string(fallback_text[:fallback_len])
}

// Logs why the backend `name` cannot be used and keeps the reason for backend_fallback.
backend_fail :: proc(name: string, format: string, args: ..any) {
	text := fmt.tprintf(format, ..args)
	log.warnf("%s: %s; drawing with SDL_GPU", name, text)
	fallback_len = copy(fallback_text[:], text)
}

// Asks for a backend for this run; called before any window is created. False, keeping
// SDL_GPU, where the platform cannot run it.
backend_select :: proc(backend: Gpu_Backend) -> bool {
	gpu_backend = .SDL_GPU
	fallback_len = 0
	switch backend {
	case .SDL_GPU:
		return true
	case .Vulkan:
		if !sdl.Vulkan_LoadLibrary(nil) {
			backend_fail("Vulkan", "no Vulkan loader (%s)", sdl.GetError())
			return false
		}
	case .Metal:
		if ODIN_OS != .Darwin {
			backend_fail("Metal", "Metal runs only on Apple's platforms")
			return false
		}
	}
	gpu_backend = backend
	return true
}

// The flags windows need for the backend in use.
window_flags :: proc() -> sdl.WindowFlags {
	switch gpu_backend {
	case .SDL_GPU:
	case .Vulkan: return {.VULKAN}
	case .Metal:  return {.METAL}
	}
	return {}
}

// The backend's name for logs and the exit stats.
backend_name :: proc() -> string {
	switch gpu_backend {
	case .SDL_GPU:
	case .Vulkan: return "vulkan"
	case .Metal:  return "metal"
	}
	return "sdl_gpu"
}
