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
	// How the backend learns when a frame reached the screen (present_times): .None where
	// it cannot, and then the app shows only the time to the submit.
	present_timing:   Present_Timing,
	// The GPU writes timestamps as it runs, so timestamps_frame gives each pass's GPU time
	// without frames waiting for the GPU (timing.odin): the own Vulkan backend where the
	// device times graphics and compute alike and resets queries from the CPU.
	timestamps:       bool,
	// Threads in a subgroup (Vulkan) or SIMD-group (Metal) that compute kernels can reduce
	// over with subgroup operations; 0 where the backend cannot tell (SDL_GPU). Nothing
	// uses it yet: it is reported so a kernel designed for it knows which devices have it.
	subgroup_size:    u32,
	// 64-bit atomic operations on storage buffers: Vulkan's shaderBufferInt64Atomics
	// (enabled where offered), Metal's Apple9 family (min and max only). Reported for a
	// future GPU dynamic topology or BVH refit; never for summing floats, whose order
	// would break the bit-identical rule.
	int64_atomics:    bool,
	// Loads write mesh buffers in place, with no copy through a transfer buffer and no
	// wait for the GPU (gpu_create_buffer_mapped): memory both the CPU and GPU reach at
	// full speed, which unified-memory GPUs and Resizable BAR desktops have.
	shared_buffers:   bool,
	// Transient render targets (gpu_create_texture_transient) take no memory: a tile GPU
	// under the own Vulkan backend with lazily allocated memory, or any Apple GPU under
	// the own Metal backend. Elsewhere they are ordinary targets.
	transient_targets: bool,
}

Present_Timing :: enum u8 {
	None,
	// VK_KHR_present_wait (desktop Vulkan): the wait for a frame's present returns once it
	// is on the screen. The backend waits for the frame frames_in_flight back before each
	// acquire under vsync, so no more frames than that queue for the screen either.
	Present_Wait,
	// VK_GOOGLE_display_timing (Android's Vulkan): the screen reports each frame's time
	// afterwards. Nothing waits for it.
	Display_Timing,
}

// A frame that reached the screen: the input it showed and when, both SDL nanoseconds
// (sdl.GetTicksNS). Present_Wait's times are when the waiting backend saw the frame shown,
// a frame late at most when it saw it without waiting.
Present_Time :: struct {
	input_ns: u64,
	shown_ns: u64,
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
	r.caps.present_timing = gpu_present_timing(r.device)
	r.caps.timestamps = gpu_timestamps_offered(r.device)
	r.caps.subgroup_size, r.caps.int64_atomics = gpu_compute_features(r.device)
	r.caps.shared_buffers = gpu_shared_buffers_offered(r.device)
	r.caps.transient_targets = gpu_transient_targets_offered(r.device)
}

// Tags the window's next present with when the input it shows came (SDL nanoseconds), so
// present_times can tell how long the input took to reach the screen; 0 tags a frame with
// no input to time. Call it before the command buffer presenting the window is submitted.
present_input :: proc(r: ^Renderer, window: ^sdl.Window, input_ns: u64) {
	if r.caps.present_timing != .None do gpu_present_input(window, input_ns)
}

// The window's tagged frames the backend has seen reach the screen since the last call,
// oldest first, into `out`; how many. Untagged frames are left out.
present_times :: proc(r: ^Renderer, window: ^sdl.Window, out: []Present_Time) -> int {
	if r.caps.present_timing == .None do return 0
	return gpu_present_times(window, out)
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
