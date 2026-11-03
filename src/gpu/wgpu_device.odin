#+build js
package gpu

import "base:runtime"
import "core:fmt"
import "core:log"

import sdl "vendor:sdl3"
import wgpu "vendor:wgpu"

// The WebGPU backend: answers the gpu_* procs of hal.odin in a browser (the web version,
// README "Web"), through vendor:wgpu's js backend, with the WGSL scripts/shaders_wgsl.py
// makes from the same Slang as the SPIR-V and the Metal source. WebGPU keeps the order of
// the queue and tracks every hazard itself, so unlike the Vulkan and Metal backends there
// is no cycling, no reference counts and no waiting: a write recorded after a read lands
// after it, a released object is destroyed once no open recording can name it, and a CPU
// readback is the only thing that must wait, which it does by polling its fence
// (query_fence), as every readback in render already does. The browser hands the
// device over asynchronously, so the page starts it (wgpu_start) before the renderer is
// made, and renderer_init takes the device that came back. Everything runs on the page's
// one thread; the browser's callbacks arrive between frames.

// What one pushed uniform block may hold, as SDL_GPU binds 4 KiB per slot; each push takes
// a fresh 256-byte aligned place in its recording's uniform chunk, bound by dynamic offset.
WGPU_UNIFORM_RANGE :: 4096
WGPU_UNIFORM_ALIGN :: 256
WGPU_UNIFORM_CHUNK :: 256 << 10
// Uploads pass through staging buffers a recording owns: chunks this size, reused, and
// any larger upload in a buffer of its own that goes when the recording is done.
WGPU_STAGING_CHUNK :: 8 << 20

Wgpu_State :: struct {
	ctx:              runtime.Context,
	instance:         wgpu.Instance,
	surface:          wgpu.Surface,
	adapter:          wgpu.Adapter,
	device:           wgpu.Device,
	queue:            wgpu.Queue,
	limits:           wgpu.Limits,
	// Optional features the device was made with.
	float32_filter:   bool,
	first_instance:   bool,
	depth_clip:       bool,
	rg11b10_target:   bool,
	depth32_stencil8: bool,
	// The canvas: its preferred format (BGRA on most desktops, RGBA on Android), the size
	// the page last gave (wgpu_canvas_resize), and what the surface was last configured as.
	canvas_format:    wgpu.TextureFormat,
	canvas_size:      [2]u32,
	configured:       [2]u32,
	srgb:             bool, // SDR_LINEAR: draws go through an sRGB view of the canvas
	swapchain:        ^Wgpu_Texture,
	swapchain_handle: Texture, // the canvas texture's handle, the same object every frame
	started:          bool,
	on_ready:         proc(ok: bool),
	// Recordings not yet submitted, and objects released while one was open: those are
	// destroyed once none is, as an open recording may still name them.
	open_cmds:        int,
	doomed_buffers:   [dynamic]wgpu.Buffer,
	doomed_textures:  [dynamic]^Wgpu_Texture,
	free_cmds:        [dynamic]^Wgpu_Cmd,
	free_uniforms:    [dynamic]^Wgpu_Uniform_Chunk,
	// The bind group layout of a stage's uniform blocks, by how many it has, and the
	// empty layout and group a stage without resources takes.
	uniform_layouts:  [Wgpu_Stage][5]wgpu.BindGroupLayout,
	empty_layout:     wgpu.BindGroupLayout,
	empty_group:      wgpu.BindGroup,
	// The mipmap generator's pieces (wgpu_generate_mipmaps_for_texture).
	mip_module:       wgpu.ShaderModule,
	mip_sampler:      wgpu.Sampler,
	mip_pipelines:    map[wgpu.TextureFormat]wgpu.RenderPipeline,
	errors:           int, // reported by WebGPU (validation_errors)
}

wgpu_state: Wgpu_State

// Starts WebGPU on the canvas `selector` names (a CSS selector such as "#viewport"), `width`
// by `height` device pixels. The adapter and device come back asynchronously; `on_ready`
// runs once both exist (true) or neither can (false, with backend_error saying why), and
// only then can renderer_init run.
wgpu_start :: proc(selector: string, width, height: u32, on_ready: proc(ok: bool)) {
	wgpu_state.ctx = context
	wgpu_state.on_ready = on_ready
	wgpu_state.canvas_size = {max(width, 1), max(height, 1)}
	wgpu_state.instance = wgpu.CreateInstance(nil)
	if wgpu_state.instance == nil {
		backend_fail("WebGPU", "this browser has no WebGPU")
		on_ready(false)
		return
	}
	wgpu_state.surface = wgpu.InstanceCreateSurface(wgpu_state.instance, &wgpu.SurfaceDescriptor {
		nextInChain = &wgpu.SurfaceSourceCanvasHTMLSelector{sType = .SurfaceSourceCanvasHTMLSelector, selector = selector},
	})
	wgpu.InstanceRequestAdapter(wgpu_state.instance, &{compatibleSurface = wgpu_state.surface, powerPreference = .HighPerformance}, {callback = wgpu_on_adapter})
}

// The canvas's new size in device pixels; the next acquire reconfigures the surface.
wgpu_canvas_resize :: proc(width, height: u32) {
	wgpu_state.canvas_size = {max(width, 1), max(height, 1)}
}

// wgpu.js reads a device descriptor's required limits 8 bytes after the pointer it is
// given (a layout from before Limits lost its wrapper), so the limits are asked for from
// 8 bytes into this, which keeps them where it reads.
@(private = "file")
Wgpu_Limits_Request :: struct {
	skipped: [8]u8,
	limits:  wgpu.Limits,
}

@(private = "file")
wgpu_limits_request: Wgpu_Limits_Request

@(private = "file")
wgpu_features: [8]wgpu.FeatureName

@(private = "file")
wgpu_on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1, userdata2: rawptr) {
	context = wgpu_state.ctx
	if status != .Success || adapter == nil {
		backend_fail("WebGPU", "no WebGPU adapter (%v): %s", status, message)
		wgpu_state.on_ready(false)
		return
	}
	wgpu_state.adapter = adapter
	// The optional features the renderer uses where they exist: filtering 32-bit float
	// textures (render mode's guides, the environment's table), instanced indirect draws,
	// unclipped depth, RG11B10 targets for the bloom.
	count := 0
	for f in ([?]wgpu.FeatureName{.Float32Filterable, .IndirectFirstInstance, .DepthClipControl, .RG11B10UfloatRenderable, .Depth32FloatStencil8}) {
		if wgpu.AdapterHasFeature(adapter, f) {
			wgpu_features[count] = f
			count += 1
		}
	}
	// The adapter's own limits where the renderer meets the defaults' edges: the size of a
	// mesh's buffers (positions of 10 million vertices are 120 MB, past the default
	// 128 MB binding by 20 million), storage buffers a stage reads, textures a stage samples.
	// Every other limit is left undefined (all ones), which asks for the default.
	adapter_limits, limits_status := wgpu.AdapterGetLimits(adapter)
	req := &wgpu_limits_request
	runtime.memset(&req.limits, 0xFF, size_of(req.limits))
	req.limits.nextInChain = nil
	if limits_status == .Success {
		req.limits.maxBufferSize = adapter_limits.maxBufferSize
		req.limits.maxStorageBufferBindingSize = adapter_limits.maxStorageBufferBindingSize
		req.limits.maxStorageBuffersPerShaderStage = adapter_limits.maxStorageBuffersPerShaderStage
		req.limits.maxSampledTexturesPerShaderStage = adapter_limits.maxSampledTexturesPerShaderStage
		req.limits.maxTextureDimension2D = adapter_limits.maxTextureDimension2D
		req.limits.maxComputeWorkgroupStorageSize = adapter_limits.maxComputeWorkgroupStorageSize
		req.limits.maxComputeInvocationsPerWorkgroup = adapter_limits.maxComputeInvocationsPerWorkgroup
	}
	wgpu.AdapterRequestDevice(adapter, &wgpu.DeviceDescriptor {
		requiredFeatureCount = uint(count),
		requiredFeatures = raw_data(wgpu_features[:]),
		requiredLimits = (^wgpu.Limits)(&req.skipped) if limits_status == .Success else nil,
		uncapturedErrorCallbackInfo = {callback = wgpu_on_error},
		deviceLostCallbackInfo = {callback = wgpu_on_lost},
	}, {callback = wgpu_on_device})
}

@(private = "file")
wgpu_on_error :: proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: string, userdata1, userdata2: rawptr) {
	context = wgpu_state.ctx
	wgpu_state.errors += 1
	log.errorf("WebGPU %v error: %s", type, message)
}

@(private = "file")
wgpu_on_lost :: proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: string, userdata1, userdata2: rawptr) {
	context = wgpu_state.ctx
	if reason != .Destroyed do log.errorf("WebGPU device lost (%v): %s", reason, message)
}

@(private = "file")
wgpu_on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1, userdata2: rawptr) {
	context = wgpu_state.ctx
	if status != .Success || device == nil {
		backend_fail("WebGPU", "no WebGPU device (%v): %s", status, message)
		wgpu_state.on_ready(false)
		return
	}
	s := &wgpu_state
	s.device = device
	s.queue = wgpu.DeviceGetQueue(device)
	s.limits, _ = wgpu.DeviceGetLimits(device)
	s.float32_filter = bool(wgpu.DeviceHasFeature(device, .Float32Filterable))
	s.first_instance = bool(wgpu.DeviceHasFeature(device, .IndirectFirstInstance))
	s.depth_clip = bool(wgpu.DeviceHasFeature(device, .DepthClipControl))
	s.rg11b10_target = bool(wgpu.DeviceHasFeature(device, .RG11B10UfloatRenderable))
	s.depth32_stencil8 = bool(wgpu.DeviceHasFeature(device, .Depth32FloatStencil8))
	s.canvas_format = .BGRA8Unorm
	if caps, caps_status := wgpu.SurfaceGetCapabilities(s.surface, s.adapter); caps_status == .Success && caps.formatCount > 0 {
		s.canvas_format = caps.formats[0]
	}
	if info, info_status := wgpu.AdapterGetInfo(s.adapter); info_status == .Success {
		name := info.description if info.description != "" else info.device
		if name == "" do name = info.vendor
		device_info_set(name, fmt.tprintf("%s %s", info.vendor, info.architecture))
	}
	s.empty_layout = wgpu.DeviceCreateBindGroupLayout(device, &{})
	s.empty_group = wgpu.DeviceCreateBindGroup(device, &{layout = s.empty_layout})
	s.started = true
	s.on_ready(true)
}

// The device wgpu_start made, or false with the reason kept for backend_error.
wgpu_create_device :: proc(debug: bool) -> bool {
	if !wgpu_state.started {
		// wgpu_start's own failure keeps its reason.
		if backend_error() == "" do backend_fail("WebGPU", "the device was not started (wgpu_start)")
		return false
	}
	return true
}

wgpu_destroy_device :: proc() {
	s := &wgpu_state
	if s.device == nil do return
	wgpu_reap()
	for cmd in s.free_cmds do wgpu_cmd_free(cmd)
	delete(s.free_cmds)
	for chunk in s.free_uniforms do wgpu_uniform_chunk_free(chunk)
	delete(s.free_uniforms)
	for stage in s.uniform_layouts do for l in stage do if l != nil do wgpu.BindGroupLayoutRelease(l)
	for _, p in s.mip_pipelines do wgpu.RenderPipelineRelease(p)
	delete(s.mip_pipelines)
	if s.mip_module != nil do wgpu.ShaderModuleRelease(s.mip_module)
	if s.mip_sampler != nil do wgpu.SamplerRelease(s.mip_sampler)
	wgpu.BindGroupRelease(s.empty_group)
	wgpu.BindGroupLayoutRelease(s.empty_layout)
	delete(s.doomed_buffers)
	delete(s.doomed_textures)
	_ = pool_remove(&pools.textures, u32(s.swapchain_handle))
	if s.swapchain != nil do free(s.swapchain)
	wgpu.QueueRelease(s.queue)
	wgpu.DeviceDestroy(s.device)
	wgpu.DeviceRelease(s.device)
	s.device = nil
}

// Records a failure the WebGPU API reported, for last_error.
wgpu_fail :: proc(format: string, args: ..any) {
	fail(.Refused, format, ..args)
}

// ---- Formats ------------------------------------------------------------------------

wgpu_format :: proc(format: Format) -> wgpu.TextureFormat {
	#partial switch format {
	case .RGBA8_Unorm:      return .RGBA8Unorm
	case .RGBA8_Srgb: return .RGBA8UnormSrgb
	case .BGRA8_Unorm:      return .BGRA8Unorm
	case .BGRA8_Srgb: return .BGRA8UnormSrgb
	case .R8_Unorm:            return .R8Unorm
	case .RG8_Unorm:          return .RG8Unorm
	case .R16_Float:           return .R16Float
	case .RG16_Float:        return .RG16Float
	case .RGBA16_Float:  return .RGBA16Float
	case .RG11B10_Float:    return .RG11B10Ufloat
	case .R32_Float:           return .R32Float
	case .RG32_Float:        return .RG32Float
	case .RGBA32_Float:  return .RGBA32Float
	case .R32_Uint:            return .R32Uint
	case .RGB10A2_Unorm:   return .RGB10A2Unorm
	case .D16_Unorm:           return .Depth16Unorm
	case .D24_Unorm:           return .Depth24Plus
	case .D32_Float:           return .Depth32Float
	case .D24_Unorm_S8:   return .Depth24PlusStencil8
	case .D32_Float_S8:   return .Depth32FloatStencil8 if wgpu_state.depth32_stencil8 else .Undefined
	}
	return .Undefined
}

// The bytes one texel of `format` takes in a transfer buffer.
wgpu_texel_size :: proc(format: Format) -> u32 {
	#partial switch format {
	case .R8_Unorm:                                   return 1
	case .RG8_Unorm, .R16_Float, .D16_Unorm:         return 2
	case .RGBA16_Float, .RG32_Float:          return 8
	case .RGBA32_Float:                         return 16
	case .D32_Float_S8:                          return 8
	}
	return 4
}

wgpu_is_stencil :: proc(format: Format) -> bool {
	return format == .D24_Unorm_S8 || format == .D32_Float_S8
}

// The formats WebGPU can write as storage textures without optional features.
@(private = "file")
wgpu_storage_format :: proc(format: Format) -> bool {
	#partial switch format {
	case .RGBA8_Unorm, .RGBA16_Float, .R32_Float, .RG32_Float, .RGBA32_Float, .R32_Uint:
		return true
	}
	return false
}

// What WebGPU offers: a depth texture is a target only (sampling one needs a depth binding
// the shaders do not declare), 32-bit float textures are sampled only with the
// float32-filterable feature (the shaders filter every texture they sample), RG11B10 is a
// target only with its feature, and storage writes take WebGPU's core storage formats.
wgpu_texture_supports_format :: proc(format: Format, type: Texture_Type, usage: Texture_Usages) -> bool {
	if type != .D2 || wgpu_format(format) == .Undefined do return false
	depth := format_is_depth(format)
	if .Depth_Target in usage && !depth do return false
	if depth && usage & {.Sampled, .Color_Target, .Graphics_Storage_Read, .Storage_Read, .Storage_Write, .Storage_Read_Write} != {} do return false
	if .Sampled in usage {
		#partial switch format {
		case .R32_Float, .RG32_Float, .RGBA32_Float:
			if !wgpu_state.float32_filter do return false
		case .R32_Uint:
			return false
		}
	}
	if .Color_Target in usage && format == .RG11B10_Float && !wgpu_state.rg11b10_target do return false
	if usage & {.Storage_Write, .Storage_Read_Write, .Storage_Read, .Graphics_Storage_Read} != {} && !wgpu_storage_format(format) do return false
	return true
}

// WebGPU multisamples with 4 samples or none.
wgpu_texture_supports_sample_count :: proc(format: Format, sample_count: Sample_Count) -> bool {
	return sample_count == ._1 || sample_count == ._4
}

wgpu_samples :: proc(count: Sample_Count) -> u32 {
	return 4 if count == ._4 else 1
}

// ---- Fences and waits ---------------------------------------------------------------

// A submission's fence: done once the queue has run it and every download it made has
// reached its transfer buffer. It lives until both the app has released it and the
// browser has answered for it, as a callback may still name it.
Wgpu_Fence :: struct {
	waiting:  int, // answers still to come: the queue's, then each download's
	released: bool,
}

wgpu_fence_answered :: proc(f: ^Wgpu_Fence) {
	f.waiting -= 1
	if f.waiting <= 0 && f.released do free(f)
}

wgpu_query_fence :: proc(fence: Fence) -> bool {
	f := (^Wgpu_Fence)(fence)
	return f == nil || f.waiting <= 0
}

wgpu_release_fence :: proc(fence: Fence) {
	f := (^Wgpu_Fence)(fence)
	if f == nil do return
	f.released = true
	if f.waiting <= 0 do free(f)
}

// A page cannot block on the GPU. What a wait is for everywhere but a CPU readback (an
// upload finished before the texture is drawn, a buffer idle before it is freed) the
// queue's order already gives, so the waits answer true at once; a readback polls its
// fence (query_fence) instead, which is what render's readbacks do.
wgpu_wait_for_fences :: proc(wait_all: bool, fences: [^]Fence, num_fences: u32) -> bool {
	return true
}

wgpu_wait_for_idle :: proc() -> bool {
	wgpu_reap()
	return true
}

// Destroys what was released while a recording was open, once none is.
wgpu_reap :: proc() {
	s := &wgpu_state
	if s.open_cmds > 0 do return
	for b in s.doomed_buffers {
		wgpu.BufferDestroy(b)
		wgpu.BufferRelease(b)
	}
	clear(&s.doomed_buffers)
	for t in s.doomed_textures do wgpu_texture_free(t)
	clear(&s.doomed_textures)
}

// ---- What WebGPU does not offer -----------------------------------------------------

// No barycentrics, ray queries, shared memory, subgroups or 64-bit atomics in core
// WebGPU, and no times for presents: the renderer takes its other path for each.
wgpu_barycentric_offered :: proc() -> bool {
	return false
}

wgpu_ray_query_offered :: proc() -> bool {
	return false
}

wgpu_shared_buffers_offered :: proc() -> bool {
	return false
}

wgpu_create_buffer_mapped :: proc(#by_ptr info: Buffer_Desc) -> (rawptr, rawptr) {
	return nil, nil
}

wgpu_present_input :: proc(window: ^sdl.Window, input_ns: u64) {}

wgpu_present_times :: proc(window: ^sdl.Window, out: []Present_Time) -> int {
	return 0
}

// WGSL has no switch for fused arithmetic; a kernel that must equal the CPU is compiled as
// any other, and render's checks of it say whether it does on this GPU.
wgpu_create_compute_pipeline_exact :: proc(#by_ptr info: Compute_Pipeline_Desc) -> rawptr {
	return wgpu_create_compute_pipeline(info)
}

// How many errors WebGPU reported, for the exit stats and the smoke run, as the Vulkan
// backend counts its validation layer's.
validation_errors :: proc() -> int {
	return wgpu_state.errors
}
