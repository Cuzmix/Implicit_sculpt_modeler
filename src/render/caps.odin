package render

import "core:log"

import sdl "vendor:sdl3"

// What the GPU and the backend drawing with it can do, filled when the device is made and
// read by the app through `caps`, so it never asks a backend by name. A switch is true
// only once the backend has what it needs in hand, so a true switch works.
Gpu_Caps :: struct {
	// Frames the GPU may run behind the app, as last set (1 to 3; 2 when the device is
	// made). Changing it costs at most a wait for the GPU.
	frames_in_flight: u32,
	// How the backend learns when a frame reached the screen (present_times): .None where
	// it cannot, and then the app shows only the time to the submit.
	present_timing:   Present_Timing,
	// A display link can pace frames (renderer_set_display_link): the own Metal backend,
	// whose CAMetalDisplayLink hands each drawable over when the display wants the frame.
	display_link:     bool,
	// The GPU writes timestamps as it runs, so timestamps_frame gives each pass's GPU time
	// without frames waiting for the GPU (timing.odin): the own Vulkan backend where the
	// device times graphics and compute alike and resets queries from the CPU.
	timestamps:       bool,
	// Threads in a subgroup (Vulkan) or SIMD-group (Metal) that compute kernels can reduce
	// over with subgroup operations; 0 where the backend cannot tell. Nothing
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
	// Textures one compute array binding may hold (gpu_create_compute_pipeline_array): the
	// own Vulkan backend with descriptor indexing (runtime arrays, variable counts and
	// non-uniform indexing of sampled images); 0 elsewhere, where kernels name each texture.
	texture_arrays:    u32,
	// Whether compute work can go to its own queue (gpu_acquire_compute_command_buffer).
	async_compute:     Async_Compute,
	// Kernels can trace rays against acceleration structures the driver builds
	// (gpu_build_blas, gpu_build_tlas, gpu_create_compute_pipeline_traced): the own Vulkan
	// backend on a device with VK_KHR_ray_query, which hardware ray tracing GPUs have.
	ray_query:         bool,
	// Objects' chunks are culled on the GPU (gpu_cull.odin, Renderer.gpu_cull): see
	// gpu_cull_offered.
	gpu_cull:          bool,
}

Async_Compute :: enum u8 {
	// No compute queue: Metal (for now), and a Vulkan device with no second queue.
	Off,
	// The own Vulkan backend on a device whose graphics family has one queue: compute
	// submissions keep their own timeline and waits but share the queue, so nothing
	// overlaps. Only --async-compute uses it, to check the bookkeeping.
	Same_Queue,
	// A second queue of the graphics family: compute runs beside the frame.
	Second_Queue,
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
	// Metal's presented handlers (the own Metal backend, iPad and Mac): each drawable
	// reports when it reached the screen, or that it never did (frames_dropped).
	Presented_Handler,
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
	r.caps.present_timing = gpu_present_timing(r.device)
	r.caps.display_link = gpu_display_link_offered()
	r.caps.timestamps = gpu_timestamps_offered(r.device)
	r.caps.subgroup_size, r.caps.int64_atomics = gpu_compute_features(r.device)
	r.caps.shared_buffers = gpu_shared_buffers_offered(r.device)
	r.caps.transient_targets = gpu_transient_targets_offered(r.device)
	r.caps.texture_arrays = gpu_texture_arrays_offered(r.device)
	r.caps.async_compute = gpu_async_compute_offered(r.device)
	r.caps.ray_query = gpu_ray_query_offered(r.device)
	r.caps.gpu_cull = gpu_cull_offered(r.device)
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

// Frames that never reached the screen since the device was made, `known` false where the
// backend cannot tell.
frames_dropped :: proc(r: ^Renderer) -> (dropped: u64, known: bool) {
	if r.device == nil do return 0, false
	return gpu_frames_dropped()
}

// Lets a display link pace the frames where Gpu_Caps.display_link, while one frame is in
// flight under vsync (a trial: off unless asked for). Cheap to call every frame.
renderer_set_display_link :: proc(r: ^Renderer, on: bool) {
	if r.caps.display_link do gpu_set_display_link(on)
}

// Frames the display link handed over since the device was made; `known` false where
// there is no display link.
display_link_frames :: proc(r: ^Renderer) -> (frames: u64, known: bool) {
	if !r.caps.display_link do return 0, false
	return gpu_display_link_frames(), true
}
