package render

import "core:log"

import sdl "vendor:sdl3"

// What the GPU and the backend drawing with it can do, filled when the device is made and
// read by the app through `caps`, so it never asks a backend by name. A switch is true
// only once the backend has what it needs in hand, so a true switch works.
Gpu_Caps :: struct {
	// Frames the GPU may run behind the app, as last set (1 to 3; 2 when the device is
	// made, as SDL_GPU's default).
	frames_in_flight: u32,
	// Changing frames_in_flight costs at most a wait for the GPU: true for the own Vulkan
	// and Metal backends and for SDL_GPU's Metal, false for SDL_GPU's Vulkan, which remakes
	// every swapchain for it.
	frames_cheap:     bool,
}

FRAMES_IN_FLIGHT_DEFAULT :: 2
FRAMES_IN_FLIGHT_MAX :: 3

caps :: proc(r: ^Renderer) -> Gpu_Caps {
	return r.caps
}

// Fills r.caps for the device just made.
@(private)
caps_fill :: proc(r: ^Renderer) {
	r.caps.frames_in_flight = FRAMES_IN_FLIGHT_DEFAULT
	r.caps.frames_cheap = gpu_backend != .SDL_GPU || gpu_get_device_driver(r.device) == "metal"
}

// Lets the GPU run `n` frames (1 to 3) behind the app: 1 shows each frame a display period
// sooner, 2 lets a heavy frame overlap the next. Every backend waits for the GPU first,
// so the change is made between frames, before the next acquire.
renderer_set_frames_in_flight :: proc(r: ^Renderer, frames: u32) -> bool {
	n := clamp(frames, 1, FRAMES_IN_FLIGHT_MAX)
	if n == r.caps.frames_in_flight do return true
	if !gpu_set_allowed_frames_in_flight(r.device, n) {
		log.warnf("frames in flight stay at %d: %s", r.caps.frames_in_flight, sdl.GetError())
		return false
	}
	r.caps.frames_in_flight = n
	return true
}
