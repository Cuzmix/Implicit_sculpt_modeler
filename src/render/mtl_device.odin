#+build darwin
package render

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
// on the GPU) at SDL_GPU's binding slots; the kernel that must equal the CPU is compiled
// with fast maths off (gpu_create_compute_pipeline_exact), which SDL_GPU cannot do.
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
	windows:       [dynamic]^Mtl_Window,
	present_logs:  [MTL_PRESENT_LOGS]Mtl_Present_Log,
	properties_id: sdl.PropertiesID,
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

// The device handle the app holds stands for the one Metal device.
mtl_device_handle :: proc() -> ^sdl.GPUDevice {
	return (^sdl.GPUDevice)(&mtl_state)
}

// Makes the device and its queue, or returns false with the reason kept for
// backend_fallback (and the app then draws with SDL_GPU).
mtl_create_device :: proc(debug: bool) -> (^sdl.GPUDevice, bool) {
	NS.scoped_autoreleasepool()
	// Metal reads its API validation switch when the device is made; SDL_GPU sets it for a
	// debug device too.
	if debug do _ = sdl.setenv_unsafe("MTL_DEBUG_LAYER", "1", false)
	device := MTL.CreateSystemDefaultDevice()
	if device == nil {
		backend_fail("Metal", "no Metal device")
		return nil, false
	}
	// SDL_GPU's floor: the A9's family on the iPad, Mac2 on the Mac.
	family := MTL.GPUFamily.Apple3 when ODIN_PLATFORM_SUBTARGET_IOS else MTL.GPUFamily.Mac2
	if !MTL.Device_supportsFamily(device, family) {
		NS.release(device)
		backend_fail("Metal", "the GPU is older than the %v family", family)
		return nil, false
	}
	queue := MTL.Device_newCommandQueue(device)
	if queue == nil {
		NS.release(device)
		backend_fail("Metal", "no command queue")
		return nil, false
	}
	mtl_state.device, mtl_state.queue = device, queue
	mtl_state.frames = FRAMES_IN_FLIGHT_DEFAULT
	when !ODIN_PLATFORM_SUBTARGET_IOS {
		mtl_state.depth24 = bool(MTL.Device_isDepth24Stencil8PixelFormatSupported(device))
	}
	mtl_state.properties_id = sdl.CreateProperties()
	name := MTL.Device_name(device)
	if name != nil do _ = sdl.SetStringProperty(mtl_state.properties_id, sdl.PROP_GPU_DEVICE_NAME_STRING, NS.String_UTF8String(name))
	return mtl_device_handle(), true
}

// Waits for the GPU, then frees everything the backend still holds.
mtl_destroy_device :: proc(device: ^sdl.GPUDevice) {
	if mtl_state.device == nil do return
	_ = mtl_wait_for_idle(device)
	for len(mtl_state.windows) > 0 do mtl_release_window(device, mtl_state.windows[0].window)
	delete(mtl_state.windows)
	mtl_present_logs_destroy()
	for cmd in mtl_state.free_cmds do mtl_cmd_free(cmd)
	delete(mtl_state.free_cmds)
	delete(mtl_state.in_flight)
	if mtl_state.properties_id != 0 do sdl.DestroyProperties(mtl_state.properties_id)
	NS.release(mtl_state.queue)
	NS.release(mtl_state.device)
	mtl_state = {}
}

mtl_get_device_properties :: proc(device: ^sdl.GPUDevice) -> sdl.PropertiesID {
	return mtl_state.properties_id
}

mtl_get_device_driver :: proc(device: ^sdl.GPUDevice) -> cstring {
	return "metal (own backend)"
}

// SDL_GPU's Metal format table, for the formats this app uses. Depth24 exists only on some
// Macs and never on the iPad, where SDL_GPU refuses D24 too.
mtl_pixel_format :: proc(format: sdl.GPUTextureFormat) -> MTL.PixelFormat {
	#partial switch format {
	case .R8G8B8A8_UNORM:      return .RGBA8Unorm
	case .R8G8B8A8_UNORM_SRGB: return .RGBA8Unorm_sRGB
	case .B8G8R8A8_UNORM:      return .BGRA8Unorm
	case .B8G8R8A8_UNORM_SRGB: return .BGRA8Unorm_sRGB
	case .R8_UNORM:            return .R8Unorm
	case .R8G8_UNORM:          return .RG8Unorm
	case .R16_FLOAT:           return .R16Float
	case .R16G16_FLOAT:        return .RG16Float
	case .R16G16B16A16_FLOAT:  return .RGBA16Float
	case .R11G11B10_UFLOAT:    return .RG11B10Float
	case .R32_FLOAT:           return .R32Float
	case .R32G32_FLOAT:        return .RG32Float
	case .R32G32B32A32_FLOAT:  return .RGBA32Float
	case .R32_UINT:            return .R32Uint
	case .R10G10B10A2_UNORM:   return .RGB10A2Unorm
	case .D16_UNORM:           return .Depth16Unorm
	case .D32_FLOAT:           return .Depth32Float
	case .D32_FLOAT_S8_UINT:   return .Depth32Float_Stencil8
	case .D24_UNORM, .D24_UNORM_S8_UINT:
		when !ODIN_PLATFORM_SUBTARGET_IOS do return .Depth24Unorm_Stencil8
	}
	return .Invalid
}

// The bytes one texel of `format` takes in a transfer buffer.
mtl_texel_size :: proc(format: sdl.GPUTextureFormat) -> u32 {
	#partial switch format {
	case .R8_UNORM:                                   return 1
	case .R8G8_UNORM, .R16_FLOAT, .D16_UNORM:         return 2
	case .R16G16B16A16_FLOAT, .R32G32_FLOAT:          return 8
	case .R32G32B32A32_FLOAT:                         return 16
	case .D32_FLOAT_S8_UINT:                          return 8
	}
	return 4
}

mtl_is_stencil :: proc(format: sdl.GPUTextureFormat) -> bool {
	return format == .D24_UNORM_S8_UINT || format == .D32_FLOAT_S8_UINT
}

mtl_is_depth :: proc(format: sdl.GPUTextureFormat) -> bool {
	#partial switch format {
	case .D16_UNORM, .D24_UNORM, .D32_FLOAT, .D24_UNORM_S8_UINT, .D32_FLOAT_S8_UINT:
		return true
	}
	return false
}

// SDL_GPU's answer: every format it maps is offered, a depth target only in a depth format,
// and D24 only where the Mac has it.
mtl_texture_supports_format :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, type: sdl.GPUTextureType, usage: sdl.GPUTextureUsageFlags) -> bool {
	if mtl_pixel_format(format) == .Invalid do return false
	if .DEPTH_STENCIL_TARGET in usage && !mtl_is_depth(format) do return false
	if format == .D24_UNORM || format == .D24_UNORM_S8_UINT do return mtl_state.depth24
	return true
}

mtl_samples :: proc(count: sdl.GPUSampleCount) -> NS.UInteger {
	switch count {
	case ._1: return 1
	case ._2: return 2
	case ._4: return 4
	case ._8: return 8
	}
	return 1
}

mtl_texture_supports_sample_count :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, sample_count: sdl.GPUSampleCount) -> bool {
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

mtl_wait_for_idle :: proc(device: ^sdl.GPUDevice) -> bool {
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

// Every Apple GPU runs SIMD-groups of 32 threads (the width a compute pipeline reports as
// threadExecutionWidth); other Macs' GPUs vary, and are not told apart here. 64-bit
// atomics (min and max) come with the Apple9 family, which Odin's enum does not name yet.
mtl_compute_features :: proc() -> (subgroup_size: u32, int64_atomics: bool) {
	if !MTL.Device_supportsFamily(mtl_state.device, .Apple3) do return 0, false
	APPLE9 :: MTL.GPUFamily(1009)
	return 32, bool(MTL.Device_supportsFamily(mtl_state.device, APPLE9))
}

mtl_shared_buffers_offered :: proc() -> bool {
	return bool(MTL.Device_hasUnifiedMemory(mtl_state.device))
}
