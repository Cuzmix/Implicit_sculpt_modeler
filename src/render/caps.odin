package render

import "../gpu"
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
	// Loads write mesh buffers in place, with no copy through a transfer buffer and no
	// wait for the GPU (gpu.create_buffer_mapped): memory both the CPU and GPU reach at
	// full speed, which unified-memory GPUs and Resizable BAR desktops have.
	shared_buffers:   bool,
	// Transient render targets (gpu.create_texture_transient) take no memory: a tile GPU
	// under the own Vulkan backend with lazily allocated memory, or any Apple GPU under
	// the own Metal backend. Elsewhere they are ordinary targets.
	transient_targets: bool,
	// Textures one compute array binding may hold (gpu.create_compute_pipeline_array): the
	// own Vulkan backend with descriptor indexing (runtime arrays, variable counts and
	// non-uniform indexing of sampled images); 0 elsewhere, where kernels name each texture.
	texture_arrays:    u32,
	// Whether compute work can go to its own queue (gpu.acquire_compute_command_buffer).
	async_compute:     Async_Compute,
	// Kernels can trace rays against acceleration structures the driver builds
	// (gpu.build_blas, gpu.build_tlas, gpu.create_compute_pipeline_traced): the own Vulkan
	// backend on a device with VK_KHR_ray_query, which hardware ray tracing GPUs have.
	ray_query:         bool,
	// Fragment shaders know where the pixel lies between the triangle's corners and which
	// triangle it is (its primitive id, and the draw's first instance), so the wireframe,
	// a polygon level's edges too, is drawn in the shading pass itself (wire_pipeline)
	// instead of as lines in a second pass: VK_KHR_fragment_shader_barycentric with
	// geometryShader and drawIndirectFirstInstance (desktop GPUs of the last years),
	// Metal's barycentric coordinates (Apple silicon).
	barycentric:       bool,
	// Objects' chunks are culled on the GPU (gpu_cull.odin, Renderer.gpu_cull): see
	// gpu.cull_offered.
	gpu_cull:          bool,
	// GPU culling starts on (gpu.cull_by_default); off where it is offered for trying.
	gpu_cull_default:  bool,
	// A stroke's vertex normals are recomputed by a kernel and read back (sculpt_gpu.odin,
	// Stats > Drawing's Sculpt on the GPU, --gpu-sculpt): see sculpt_gpu_offered.
	gpu_sculpt:        bool,
}

// The seam's own words for what a device offers, named here as the app knows them.
Async_Compute :: gpu.Async_Compute
Present_Timing :: gpu.Present_Timing
Present_Time :: gpu.Present_Time
FRAMES_IN_FLIGHT_DEFAULT :: gpu.FRAMES_IN_FLIGHT_DEFAULT
FRAMES_IN_FLIGHT_MAX :: gpu.FRAMES_IN_FLIGHT_MAX

caps :: proc(r: ^Renderer) -> Gpu_Caps {
	return r.caps
}

// Fills r.caps for the device just made.
@(private)
caps_fill :: proc(r: ^Renderer) {
	r.caps.frames_in_flight = FRAMES_IN_FLIGHT_DEFAULT
	r.caps.present_timing = gpu.present_timing(r.device)
	r.caps.display_link = gpu.display_link_offered()
	r.caps.timestamps = gpu.timestamps_offered(r.device)
	r.caps.shared_buffers = gpu.shared_buffers_offered(r.device)
	r.caps.transient_targets = gpu.transient_targets_offered(r.device)
	r.caps.texture_arrays = gpu.texture_arrays_offered(r.device)
	r.caps.async_compute = gpu.async_compute_offered(r.device)
	r.caps.ray_query = gpu.ray_query_offered(r.device)
	r.caps.barycentric = gpu.barycentric_offered(r.device)
	r.caps.gpu_cull = gpu.cull_offered(r.device)
	r.caps.gpu_cull_default = r.caps.gpu_cull && gpu.cull_by_default(r.device)
	r.caps.gpu_sculpt = sculpt_gpu_offered(r)
}

// Tags the window's next present with when the input it shows came (SDL nanoseconds), so
// present_times can tell how long the input took to reach the screen; 0 tags a frame with
// no input to time. Call it before the command buffer presenting the window is submitted.
present_input :: proc(r: ^Renderer, window: ^sdl.Window, input_ns: u64) {
	if r.caps.present_timing != .None do gpu.present_input(window, input_ns)
}

// The window's tagged frames the backend has seen reach the screen since the last call,
// oldest first, into `out`; how many. Untagged frames are left out.
present_times :: proc(r: ^Renderer, window: ^sdl.Window, out: []Present_Time) -> int {
	if r.caps.present_timing == .None do return 0
	return gpu.present_times(window, out)
}

// Lets the GPU run `n` frames (1 to 3) behind the app: 1 shows each frame a display period
// sooner, 2 lets a heavy frame overlap the next. Every backend waits for the GPU first,
// so the change is made between frames, before the next acquire.
renderer_set_frames_in_flight :: proc(r: ^Renderer, frames: u32) -> bool {
	n := clamp(frames, 1, FRAMES_IN_FLIGHT_MAX)
	if n == r.caps.frames_in_flight do return true
	if !gpu.set_allowed_frames_in_flight(r.device, n) {
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
	return gpu.frames_dropped()
}

// Lets a display link pace the frames where Gpu_Caps.display_link, while one frame is in
// flight under vsync (a trial: off unless asked for). Cheap to call every frame.
renderer_set_display_link :: proc(r: ^Renderer, on: bool) {
	if r.caps.display_link do gpu.set_display_link(on)
}

// Frames the display link handed over since the device was made; `known` false where
// there is no display link.
display_link_frames :: proc(r: ^Renderer) -> (frames: u64, known: bool) {
	if !r.caps.display_link do return 0, false
	return gpu.display_link_frames(), true
}
