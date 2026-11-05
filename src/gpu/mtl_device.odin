#+build darwin
package gpu

import "core:strings"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import sdl "vendor:sdl3"

// The Metal backend: answers the gpu_* procs of hal.odin with Metal directly on Apple's
// platforms, mirroring SDL_GPU's own Metal backend (deps/sdl3-src/src/gpu/metal is the
// reference) in its binding slots, defaults and cycling, so both draw the same images from
// the same Metal shaders. Metal tracks the hazards between the resources made here, so
// unlike the Vulkan backend there are no layouts or barriers to keep. Objects are counted
// by hand: what a new* or alloc call returns is ours to release, and what Metal hands back
// autoreleased (command buffers, encoders, drawables) is retained for as long as it is
// kept. It draws frames and runs compute kernels (the traced studio, render mode, Smooth all
// on the GPU) at the slots each shader's Metal source names (Mtl_Slots); the kernel that must equal the CPU is compiled
// with fast maths off (create_compute_pipeline_exact), which SDL_GPU cannot do.
// Everything runs on the thread that drives render.

// What one pushed uniform block may hold; SDL_GPU binds 4 KiB per slot too, and Metal's
// set*Bytes takes at most that.
MTL_UNIFORM_RANGE :: 4096

Mtl_State :: struct {
	device:        ^MTL.Device,
	queue:         ^MTL.CommandQueue,
	depth24:       bool, // Depth24Unorm_Stencil8 is offered (some Macs only)
	frames:        u32, // frames a window may have in flight before its next acquire waits
	// Submissions are numbered in order. A queue runs its command buffers in the order they
	// were committed, so "has the GPU finished submission n" is one comparison with
	// `completed`, which mtl_collect moves on.
	submitted:     u64,
	completed:     u64,
	free_cmds:     [dynamic]^Mtl_Cmd,
	in_flight:     [dynamic]^Mtl_Cmd,
	// Recordings acquired and not yet committed or cancelled, and the pipelines, samplers and
	// shaders released meanwhile (mtl_release_later): a recording keeps a bound pipeline only
	// as a pointer until its next draw, so they go once no recording is open and the GPU has
	// run everything committed by then.
	recording:     int,
	doomed:        [dynamic]Mtl_Doomed,
	windows:       [dynamic]^Mtl_Window,
	present_logs:  [MTL_PRESENT_LOGS]Mtl_Present_Log,
	// Display-link pacing (mtl_link.odin): whether the app asked for it, the running link
	// (nil until an acquire wants it), whether it could not be made here, and the drawables
	// earlier links handed over.
	link:          ^Mtl_Link,
	link_wanted:   bool,
	link_failed:   bool,
	link_taken:    u64,
}

mtl_state: Mtl_State

// An Objective-C class of our own, which nothing uses. The pinned Odin only generates the
// runtime's class and selector lookups (objc_lookUpClass, sel_registerName) when a package
// implements a class, and otherwise asserts while compiling the Metal calls; declaring one
// makes it generate them.
@(objc_class = "SculptMetalBackend", objc_implement, objc_superclass = NS.Object)
Mtl_Objc_Anchor :: struct {
	using _: NS.Object,
}

// Makes the device and its queue, or returns false with the reason kept for
// backend_error (and the app then says why it cannot start).
mtl_create_device :: proc(debug: bool) -> bool {
	NS.scoped_autoreleasepool()
	// Metal reads its API validation switch when the device is made; SDL_GPU sets it for a
	// debug device too.
	if debug do _ = sdl.setenv_unsafe("MTL_DEBUG_LAYER", "1", false)
	device := MTL.CreateSystemDefaultDevice()
	if device == nil {
		backend_fail("Metal", "no Metal device")
		return false
	}
	// The floor SDL_GPU kept, which the app was tried on: the A9's family on the iPad, Mac2 on the Mac.
	family := MTL.GPUFamily.Apple3 when ODIN_PLATFORM_SUBTARGET_IOS else MTL.GPUFamily.Mac2
	if !MTL.Device_supportsFamily(device, family) {
		NS.release(device)
		backend_fail("Metal", "the GPU is older than the %v family", family)
		return false
	}
	queue := MTL.Device_newCommandQueue(device)
	if queue == nil {
		NS.release(device)
		backend_fail("Metal", "no command queue")
		return false
	}
	mtl_state.device, mtl_state.queue = device, queue
	mtl_state.frames = FRAMES_IN_FLIGHT_DEFAULT
	when !ODIN_PLATFORM_SUBTARGET_IOS {
		mtl_state.depth24 = bool(MTL.Device_isDepth24Stencil8PixelFormatSupported(device))
	}
	name := MTL.Device_name(device)
	device_info_set(string(NS.String_UTF8String(name)) if name != nil else "", "")
	return true
}

// Waits for the GPU, then frees everything the backend still holds.
mtl_destroy_device :: proc() {
	if mtl_state.device == nil do return
	_ = mtl_wait_for_idle()
	for len(mtl_state.windows) > 0 do mtl_release_window(mtl_state.windows[0].window)
	mtl_link_stop()
	delete(mtl_state.windows)
	mtl_present_logs_destroy()
	for cmd in mtl_state.free_cmds do mtl_cmd_free(cmd)
	delete(mtl_state.free_cmds)
	delete(mtl_state.in_flight)
	mtl_state.recording = 0
	mtl_reap_doomed()
	delete(mtl_state.doomed)
	NS.release(mtl_state.queue)
	NS.release(mtl_state.device)
	mtl_state = {}
}


// The Metal format of each of the gpu package's formats. Depth24 exists only on some
// Macs and never on the iPad, where SDL_GPU refuses D24 too.
mtl_pixel_format :: proc(format: Format) -> MTL.PixelFormat {
	#partial switch format {
	case .RGBA8_Unorm:      return .RGBA8Unorm
	case .RGBA8_Srgb: return .RGBA8Unorm_sRGB
	case .BGRA8_Unorm:      return .BGRA8Unorm
	case .BGRA8_Srgb: return .BGRA8Unorm_sRGB
	case .R8_Unorm:            return .R8Unorm
	case .RG8_Unorm:          return .RG8Unorm
	case .R16_Float:           return .R16Float
	case .RG16_Float:        return .RG16Float
	case .RGBA16_Float:  return .RGBA16Float
	case .RG11B10_Float:    return .RG11B10Float
	case .R32_Float:           return .R32Float
	case .RG32_Float:        return .RG32Float
	case .RGBA32_Float:  return .RGBA32Float
	case .R32_Uint:            return .R32Uint
	case .RGB10A2_Unorm:   return .RGB10A2Unorm
	case .D16_Unorm:           return .Depth16Unorm
	case .D32_Float:           return .Depth32Float
	case .D32_Float_S8:   return .Depth32Float_Stencil8
	case .D24_Unorm, .D24_Unorm_S8:
		when !ODIN_PLATFORM_SUBTARGET_IOS do return .Depth24Unorm_Stencil8
	}
	return .Invalid
}

// The bytes one texel of `format` takes in a transfer buffer.
mtl_texel_size :: proc(format: Format) -> u32 {
	#partial switch format {
	case .R8_Unorm:                                   return 1
	case .RG8_Unorm, .R16_Float, .D16_Unorm:         return 2
	case .RGBA16_Float, .RG32_Float:          return 8
	case .RGBA32_Float:                         return 16
	case .D32_Float_S8:                          return 8
	}
	return 4
}

mtl_is_stencil :: proc(format: Format) -> bool {
	return format == .D24_Unorm_S8 || format == .D32_Float_S8
}

// SDL_GPU's answer: every format it maps is offered, a depth target only in a depth format,
// and D24 only where the Mac has it.
mtl_texture_supports_format :: proc(format: Format, type: Texture_Type, usage: Texture_Usages) -> bool {
	if mtl_pixel_format(format) == .Invalid do return false
	if .Depth_Target in usage && !format_is_depth(format) do return false
	if format == .D24_Unorm || format == .D24_Unorm_S8 do return mtl_state.depth24
	return true
}

mtl_samples :: proc(count: Sample_Count) -> NS.UInteger {
	switch count {
	case ._1: return 1
	case ._2: return 2
	case ._4: return 4
	case ._8: return 8
	}
	return 1
}

mtl_texture_supports_sample_count :: proc(format: Format, sample_count: Sample_Count) -> bool {
	return bool(MTL.Device_supportsTextureSampleCount(mtl_state.device, mtl_samples(sample_count)))
}

// Records the GPU's progress and recycles the command buffers it has finished, oldest
// first, stopping at the first one still running.
mtl_collect :: proc() {
	for len(mtl_state.in_flight) > 0 {
		cmd := mtl_state.in_flight[0]
		status := MTL.CommandBuffer_status(cmd.cb)
		// A command buffer that failed is finished too; Metal reports it as Error.
		if status != .Completed && status != .Error do break
		ordered_remove(&mtl_state.in_flight, 0)
		mtl_state.completed = cmd.serial
		mtl_cmd_recycle(cmd)
	}
	mtl_reap_doomed()
}

// An object released while the GPU or a recording may still use it, and the submission
// after which neither can (0 until no recording is open).
Mtl_Doomed :: struct {
	object:  rawptr,
	release: proc(object: rawptr),
	after:   u64,
}

// Calls `release` on `object` now when nothing can be using it, else once mtl_reap_doomed
// finds every recording that could have bound it run.
mtl_release_later :: proc(object: rawptr, release: proc(object: rawptr)) {
	if object == nil do return
	append(&mtl_state.doomed, Mtl_Doomed{object = object, release = release})
	mtl_reap_doomed()
}

@(private = "file")
mtl_reap_doomed :: proc() {
	for i := 0; i < len(mtl_state.doomed); {
		d := &mtl_state.doomed[i]
		if d.after == 0 && mtl_state.recording == 0 do d.after = mtl_state.submitted + 1
		if d.after != 0 && d.after - 1 <= mtl_state.completed {
			d.release(d.object)
			unordered_remove(&mtl_state.doomed, i)
			continue
		}
		i += 1
	}
}

// Waits until submission `serial` has finished.
mtl_wait_serial :: proc(serial: u64) -> bool {
	if serial <= mtl_state.completed do return true
	for cmd in mtl_state.in_flight {
		if cmd.serial > serial do break
		MTL.CommandBuffer_waitUntilCompleted(cmd.cb)
	}
	mtl_collect()
	return serial <= mtl_state.completed
}

mtl_wait_for_idle :: proc() -> bool {
	return mtl_wait_serial(mtl_state.submitted)
}

// A Foundation string of `text`, autoreleased by the caller's pool. It reads `text` in
// place without copying it, so `text` must outlive the pool.
mtl_string :: proc(text: string) -> ^NS.String {
	s := NS.String_initWithOdinString(NS.String_alloc(), text)
	if s != nil do NS.autorelease(s)
	return s
}

// The description of a Metal error, for logs.
mtl_error_text :: proc(err: ^NS.Error) -> string {
	if err == nil do return "no reason given"
	text := NS.Error_localizedDescription(err)
	return strings.clone(NS.String_odinString(text), context.temp_allocator) if text != nil else "no reason given"
}

mtl_shared_buffers_offered :: proc() -> bool {
	return bool(MTL.Device_hasUnifiedMemory(mtl_state.device))
}

mtl_memory_budget :: proc() -> (bytes: u64, unified: bool) {
	return MTL.Device_recommendedMaxWorkingSetSize(mtl_state.device), bool(MTL.Device_hasUnifiedMemory(mtl_state.device))
}
