package render

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// The Vulkan backend (notes/vulkan/backend-design.md): answers the gpu_* procs of hal.odin
// with Vulkan 1.3 directly, keeping SDL_GPU's model so the render code above it stays the
// same and both backends draw the same images from the same SPIR-V. It follows SDL_GPU's
// own Vulkan backend where the model leaves a choice open (descriptor set numbering,
// default layouts, cycling, the flipped viewport), since matching it pixel for pixel is
// the test. Everything runs on the thread that drives render, as the app's frame loop does.

// What one pushed uniform block may hold, and the size of the buffers they are packed
// into; SDL_GPU binds 4 KiB per slot too.
VK_UNIFORM_RANGE :: 4096
VK_UNIFORM_BLOCK :: 256 * 1024

Vk_State :: struct {
	instance:          vk.Instance,
	messenger:         vk.DebugUtilsMessengerEXT,
	physical:          vk.PhysicalDevice,
	device:            vk.Device,
	queue:             vk.Queue,
	family:            u32,
	frames:            u32, // frames a window may have in flight before its next acquire waits
	labels:            bool, // VK_EXT_debug_utils is on: passes and objects carry names for capture tools
	present_timing:    Present_Timing, // which present timing extension is on (vk_swapchain.odin)
	timing:            Vk_Timing, // GPU timestamps (vk_timing.odin); no pools where the device cannot time
	properties:        vk.PhysicalDeviceProperties,
	driver:            vk.PhysicalDeviceDriverProperties,
	memory:            vk.PhysicalDeviceMemoryProperties,
	multi_draw:        bool, // multiDrawIndirect; without it indirect draws are issued one by one
	wireframe:         bool, // fillModeNonSolid
	depth_clamp:       bool,
	anisotropy:        bool,
	subgroup_size:     u32, // 0 where compute shaders have no arithmetic subgroup operations
	int64_atomics:     bool, // shaderBufferInt64Atomics, enabled
	// A timeline semaphore counts submissions: each signals the next serial, so "has the GPU
	// finished submission n" is one comparison.
	timeline:          vk.Semaphore,
	submitted:         u64,
	completed:         u64,
	command_pool:      vk.CommandPool,
	free_cmds:         [dynamic]^Vk_Cmd,
	in_flight:         [dynamic]^Vk_Cmd,
	// New textures start in an undefined layout; this command buffer moves them to their
	// default one and goes to the GPU just ahead of the next submission.
	setup:             ^Vk_Cmd,
	windows:           [dynamic]^Vk_Window,
	set_layouts:       map[Vk_Set_Key]vk.DescriptorSetLayout,
	graphics_layouts:  map[Vk_Graphics_Layout_Key]^Vk_Pipeline_Layout,
	compute_layouts:   map[Vk_Compute_Layout_Key]^Vk_Pipeline_Layout,
	properties_id:     sdl.PropertiesID,
}

vk_state: Vk_State

// Validation errors the run has seen (--gpu-debug with the Khronos layer installed); kept
// past the device's end so the app can fail on them.
@(private = "file")
vk_validation_errors: int

validation_errors :: proc() -> int {
	return vk_validation_errors
}

// Logs why Vulkan cannot be used and keeps the reason for backend_fallback.
@(private = "file")
vk_fail :: proc(format: string, args: ..any) {
	backend_fail("Vulkan", format, ..args)
}

// The device handle the app holds stands for the one Vulkan device.
vk_device_handle :: proc() -> ^sdl.GPUDevice {
	return (^sdl.GPUDevice)(&vk_state)
}

@(private = "file")
vk_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user: rawptr) -> b32 {
	context = (^runtime.Context)(user)^
	if .ERROR in severity {
		vk_validation_errors += 1
		log.errorf("Vulkan validation: %s", data.pMessage)
	} else {
		log.warnf("Vulkan validation: %s", data.pMessage)
	}
	return false
}

@(private = "file")
vk_debug_context: runtime.Context

@(private = "file")
vk_has_layer :: proc(name: string) -> bool {
	count: u32
	if vk.EnumerateInstanceLayerProperties(&count, nil) != .SUCCESS do return false
	layers := make([]vk.LayerProperties, count, context.temp_allocator)
	if vk.EnumerateInstanceLayerProperties(&count, raw_data(layers)) != .SUCCESS do return false
	for &layer in layers {
		if strings.truncate_to_byte(string(layer.layerName[:]), 0) == name do return true
	}
	return false
}

@(private = "file")
vk_has_extension :: proc(extensions: []vk.ExtensionProperties, name: string) -> bool {
	for &e in extensions {
		if strings.truncate_to_byte(string(e.extensionName[:]), 0) == name do return true
	}
	return false
}

// Why a physical device cannot run the backend, or "" when it can.
@(private = "file")
vk_unfit :: proc(physical: vk.PhysicalDevice, family: ^u32) -> string {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical, &props)
	if props.apiVersion < vk.API_VERSION_1_3 do return "Vulkan 1.3 is missing"
	f12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}
	f13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, pNext = &f12}
	features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &f13}
	vk.GetPhysicalDeviceFeatures2(physical, &features)
	if !f13.dynamicRendering || !f13.synchronization2 || !f12.timelineSemaphore do return "dynamic rendering, synchronization2 or timeline semaphores are missing"
	if !features.features.independentBlend do return "independent blending is missing"
	count: u32
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, nil)
	extensions := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, raw_data(extensions))
	if !vk_has_extension(extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME) do return "it cannot present"
	vk.GetPhysicalDeviceQueueFamilyProperties(physical, &count, nil)
	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(physical, &count, raw_data(families))
	for f, i in families {
		if f.queueFlags >= {.GRAPHICS, .COMPUTE} && sdl.Vulkan_GetPresentationSupport(vk_state.instance, physical, u32(i)) {
			family^ = u32(i)
			return ""
		}
	}
	return "no queue both draws and presents"
}

// Creates the instance and the device, or returns false with the reason logged and kept for
// backend_fallback (and the app then draws with SDL_GPU).
vk_create_device :: proc(debug: bool, want_anisotropy: bool) -> (^sdl.GPUDevice, bool) {
	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))
	if vk.CreateInstance == nil {
		vk_fail("the loader has no vkCreateInstance")
		return nil, false
	}
	count: u32
	sdl_extensions := sdl.Vulkan_GetInstanceExtensions(&count)
	extensions := make([dynamic]cstring, context.temp_allocator)
	for i in 0 ..< count do append(&extensions, sdl_extensions[i])
	layers := make([dynamic]cstring, context.temp_allocator)
	validation := debug && vk_has_layer("VK_LAYER_KHRONOS_validation")
	if validation {
		append(&layers, "VK_LAYER_KHRONOS_validation")
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		append(&extensions, vk.EXT_VALIDATION_FEATURES_EXTENSION_NAME)
	} else if debug {
		log.warn("Vulkan: the validation layer is not installed; running without it")
	}
	// Names for capture tools (RenderDoc, Nsight) wherever the loader offers them, as
	// SDL_GPU does; they cost nothing when no tool is attached.
	vk_state.labels = validation
	if !validation {
		instance_count: u32
		if vk.EnumerateInstanceExtensionProperties(nil, &instance_count, nil) == .SUCCESS {
			offered := make([]vk.ExtensionProperties, instance_count, context.temp_allocator)
			if vk.EnumerateInstanceExtensionProperties(nil, &instance_count, raw_data(offered)) == .SUCCESS && vk_has_extension(offered, vk.EXT_DEBUG_UTILS_EXTENSION_NAME) {
				append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
				vk_state.labels = true
			}
		}
	}
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "Sculpt",
		pEngineName      = "Sculpt",
		apiVersion       = vk.API_VERSION_1_3,
	}
	// Synchronization validation too: a missing barrier is the backend's likeliest bug.
	sync_validation := vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION
	validation_features := vk.ValidationFeaturesEXT {
		sType                         = .VALIDATION_FEATURES_EXT,
		enabledValidationFeatureCount = 1,
		pEnabledValidationFeatures    = &sync_validation,
	}
	instance_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = &validation_features if validation else nil,
		pApplicationInfo        = &app,
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	if r := vk.CreateInstance(&instance_info, nil, &vk_state.instance); r != .SUCCESS {
		vk_fail("vkCreateInstance failed (%v)", r)
		return nil, false
	}
	vk.load_proc_addresses_instance(vk_state.instance)
	if validation {
		vk_debug_context = context
		messenger := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.WARNING, .ERROR},
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_debug_callback,
			pUserData       = &vk_debug_context,
		}
		if vk.CreateDebugUtilsMessengerEXT(vk_state.instance, &messenger, nil, &vk_state.messenger) != .SUCCESS {
			log.warn("Vulkan: no debug messenger; validation messages go unseen")
		}
	}

	// The first discrete GPU that qualifies, else the first that does.
	vk.EnumeratePhysicalDevices(vk_state.instance, &count, nil)
	physicals := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(vk_state.instance, &count, raw_data(physicals))
	best_rank := -1
	reason := "no Vulkan device"
	for physical in physicals {
		family: u32
		why := vk_unfit(physical, &family)
		if why != "" {
			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(physical, &props)
			reason = fmt.tprintf("%s: %s", strings.truncate_to_byte(string(props.deviceName[:]), 0), why)
			continue
		}
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(physical, &props)
		rank := 2 if props.deviceType == .DISCRETE_GPU else 1 if props.deviceType == .INTEGRATED_GPU else 0
		if rank > best_rank {
			best_rank = rank
			vk_state.physical, vk_state.family = physical, family
		}
	}
	if vk_state.physical == nil {
		vk_fail("no device qualifies (%s)", reason)
		vk_destroy_instance()
		return nil, false
	}

	// Present timing (Gpu_Caps.present_timing): present_wait where offered, which also
	// paces the frames queued for the screen; otherwise display timing, whose times are
	// CLOCK_MONOTONIC's and so read only on Linux and Android (vk_clock_linux.odin).
	vk.EnumerateDeviceExtensionProperties(vk_state.physical, nil, &count, nil)
	offered := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(vk_state.physical, nil, &count, raw_data(offered))
	have_wait := vk.PhysicalDevicePresentWaitFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR}
	have_id := vk.PhysicalDevicePresentIdFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR, pNext = &have_wait}
	have := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2}
	if vk_has_extension(offered, vk.KHR_PRESENT_ID_EXTENSION_NAME) && vk_has_extension(offered, vk.KHR_PRESENT_WAIT_EXTENSION_NAME) do have.pNext = &have_id
	vk.GetPhysicalDeviceFeatures2(vk_state.physical, &have)
	device_extensions := make([dynamic]cstring, context.temp_allocator)
	append(&device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	want_id := vk.PhysicalDevicePresentIdFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR, presentId = true}
	want_wait := vk.PhysicalDevicePresentWaitFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR, pNext = &want_id, presentWait = true}
	if have_id.presentId && have_wait.presentWait {
		append(&device_extensions, vk.KHR_PRESENT_ID_EXTENSION_NAME, vk.KHR_PRESENT_WAIT_EXTENSION_NAME)
		vk_state.present_timing = .Present_Wait
	} else if VK_CLOCK_MONOTONIC && vk_has_extension(offered, vk.GOOGLE_DISPLAY_TIMING_EXTENSION_NAME) {
		append(&device_extensions, vk.GOOGLE_DISPLAY_TIMING_EXTENSION_NAME)
		vk_state.present_timing = .Display_Timing
	}
	// Host query reset lets GPU timestamps reset their pools without a command buffer.
	have12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}
	have_chain := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &have12}
	vk.GetPhysicalDeviceFeatures2(vk_state.physical, &have_chain)
	f12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, timelineSemaphore = true, hostQueryReset = have12.hostQueryReset, shaderBufferInt64Atomics = have12.shaderBufferInt64Atomics}
	vk_state.int64_atomics = bool(have12.shaderBufferInt64Atomics)
	f13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, pNext = &f12, dynamicRendering = true, synchronization2 = true}
	features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &f13}
	if vk_state.present_timing == .Present_Wait do f12.pNext = &want_wait
	// The optional features SDL_GPU asks for, each where offered.
	features.features.independentBlend = true
	features.features.imageCubeArray = have.features.imageCubeArray
	features.features.depthClamp = have.features.depthClamp
	features.features.shaderClipDistance = have.features.shaderClipDistance
	features.features.drawIndirectFirstInstance = have.features.drawIndirectFirstInstance
	features.features.samplerAnisotropy = have.features.samplerAnisotropy && b32(want_anisotropy)
	features.features.fillModeNonSolid = have.features.fillModeNonSolid
	features.features.multiDrawIndirect = have.features.multiDrawIndirect
	vk_state.multi_draw = bool(have.features.multiDrawIndirect)
	vk_state.wireframe = bool(have.features.fillModeNonSolid)
	vk_state.depth_clamp = bool(have.features.depthClamp)
	vk_state.anisotropy = bool(features.features.samplerAnisotropy)
	priority: f32 = 1
	queue := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = vk_state.family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	device_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
	}
	if r := vk.CreateDevice(vk_state.physical, &device_info, nil, &vk_state.device); r != .SUCCESS {
		vk_fail("vkCreateDevice failed (%v)", r)
		vk_destroy_instance()
		return nil, false
	}
	vk.load_proc_addresses_device(vk_state.device)
	vk.GetDeviceQueue(vk_state.device, vk_state.family, 0, &vk_state.queue)

	p11 := vk.PhysicalDeviceVulkan11Properties{sType = .PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES}
	vk_state.driver = {sType = .PHYSICAL_DEVICE_DRIVER_PROPERTIES, pNext = &p11}
	props2 := vk.PhysicalDeviceProperties2{sType = .PHYSICAL_DEVICE_PROPERTIES_2, pNext = &vk_state.driver}
	vk.GetPhysicalDeviceProperties2(vk_state.physical, &props2)
	vk_state.driver.pNext = nil // p11 is gone after this proc
	vk_state.properties = props2.properties
	// Subgroups are Vulkan 1.1 core, but a device may offer them to other stages only, or
	// without the arithmetic (reduce and scan) operations a kernel would want.
	if .COMPUTE in p11.subgroupSupportedStages && .ARITHMETIC in p11.subgroupSupportedOperations do vk_state.subgroup_size = p11.subgroupSize
	vk.GetPhysicalDeviceMemoryProperties(vk_state.physical, &vk_state.memory)

	timeline_type := vk.SemaphoreTypeCreateInfo{sType = .SEMAPHORE_TYPE_CREATE_INFO, semaphoreType = .TIMELINE}
	semaphore := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO, pNext = &timeline_type}
	pool := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = vk_state.family}
	if vk.CreateSemaphore(vk_state.device, &semaphore, nil, &vk_state.timeline) != .SUCCESS || vk.CreateCommandPool(vk_state.device, &pool, nil, &vk_state.command_pool) != .SUCCESS {
		vk_fail("the timeline semaphore or command pool could not be made")
		vk_destroy_device(vk_device_handle())
		return nil, false
	}

	vk_state.properties_id = sdl.CreateProperties()
	name := strings.clone_to_cstring(strings.truncate_to_byte(string(vk_state.properties.deviceName[:]), 0), context.temp_allocator)
	driver := strings.clone_to_cstring(strings.truncate_to_byte(string(vk_state.driver.driverInfo[:]), 0), context.temp_allocator)
	_ = sdl.SetStringProperty(vk_state.properties_id, sdl.PROP_GPU_DEVICE_NAME_STRING, name)
	_ = sdl.SetStringProperty(vk_state.properties_id, sdl.PROP_GPU_DEVICE_DRIVER_VERSION_STRING, driver)
	vk_state.frames = FRAMES_IN_FLIGHT_DEFAULT
	if have12.hostQueryReset {
		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(vk_state.physical, &family_count, nil)
		families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(vk_state.physical, &family_count, raw_data(families))
		_ = vk_timing_init(families[vk_state.family].timestampValidBits)
	}
	log.infof("Vulkan: present timing: %v; GPU timestamps: %v", vk_state.present_timing, vk_state.timing.slots[0].pool != 0)
	return vk_device_handle(), true
}

@(private = "file")
vk_destroy_instance :: proc() {
	if vk_state.messenger != 0 do vk.DestroyDebugUtilsMessengerEXT(vk_state.instance, vk_state.messenger, nil)
	if vk_state.instance != nil do vk.DestroyInstance(vk_state.instance, nil)
	vk_state = {}
}

// Waits for the GPU, then frees everything the backend still holds.
vk_destroy_device :: proc(device: ^sdl.GPUDevice) {
	if vk_state.device == nil {
		vk_destroy_instance()
		return
	}
	vk_wait_for_idle(device)
	for len(vk_state.windows) > 0 do vk_release_window(device, vk_state.windows[0].window)
	delete(vk_state.windows)
	for cmd in vk_state.free_cmds do vk_cmd_free(cmd)
	delete(vk_state.free_cmds)
	delete(vk_state.in_flight)
	for _, layout in vk_state.graphics_layouts {
		vk.DestroyPipelineLayout(vk_state.device, layout.layout, nil)
		free(layout)
	}
	for _, layout in vk_state.compute_layouts {
		vk.DestroyPipelineLayout(vk_state.device, layout.layout, nil)
		free(layout)
	}
	for _, layout in vk_state.set_layouts do vk.DestroyDescriptorSetLayout(vk_state.device, layout, nil)
	delete(vk_state.graphics_layouts)
	delete(vk_state.compute_layouts)
	delete(vk_state.set_layouts)
	vk_timing_destroy()
	if vk_state.command_pool != 0 do vk.DestroyCommandPool(vk_state.device, vk_state.command_pool, nil)
	if vk_state.timeline != 0 do vk.DestroySemaphore(vk_state.device, vk_state.timeline, nil)
	if vk_state.properties_id != 0 do sdl.DestroyProperties(vk_state.properties_id)
	vk.DestroyDevice(vk_state.device, nil)
	vk_destroy_instance()
}

vk_get_device_properties :: proc(device: ^sdl.GPUDevice) -> sdl.PropertiesID {
	return vk_state.properties_id
}

vk_get_device_driver :: proc(device: ^sdl.GPUDevice) -> cstring {
	return "vulkan (own backend)"
}

// SDL_GPU's format table, for the formats this app uses.
vk_format :: proc(format: sdl.GPUTextureFormat) -> vk.Format {
	#partial switch format {
	case .R8G8B8A8_UNORM:      return .R8G8B8A8_UNORM
	case .R8G8B8A8_UNORM_SRGB: return .R8G8B8A8_SRGB
	case .B8G8R8A8_UNORM:      return .B8G8R8A8_UNORM
	case .B8G8R8A8_UNORM_SRGB: return .B8G8R8A8_SRGB
	case .R8_UNORM:            return .R8_UNORM
	case .R8G8_UNORM:          return .R8G8_UNORM
	case .R16_FLOAT:           return .R16_SFLOAT
	case .R16G16_FLOAT:        return .R16G16_SFLOAT
	case .R16G16B16A16_FLOAT:  return .R16G16B16A16_SFLOAT
	case .R11G11B10_UFLOAT:    return .B10G11R11_UFLOAT_PACK32
	case .R32_FLOAT:           return .R32_SFLOAT
	case .R32G32_FLOAT:        return .R32G32_SFLOAT
	case .R32G32B32A32_FLOAT:  return .R32G32B32A32_SFLOAT
	case .R32_UINT:            return .R32_UINT
	case .R10G10B10A2_UNORM:   return .A2B10G10R10_UNORM_PACK32
	case .D16_UNORM:           return .D16_UNORM
	case .D24_UNORM:           return .X8_D24_UNORM_PACK32
	case .D32_FLOAT:           return .D32_SFLOAT
	case .D24_UNORM_S8_UINT:   return .D24_UNORM_S8_UINT
	case .D32_FLOAT_S8_UINT:   return .D32_SFLOAT_S8_UINT
	}
	return .UNDEFINED
}

vk_is_depth :: proc(format: sdl.GPUTextureFormat) -> bool {
	#partial switch format {
	case .D16_UNORM, .D24_UNORM, .D32_FLOAT, .D24_UNORM_S8_UINT, .D32_FLOAT_S8_UINT:
		return true
	}
	return false
}

vk_texture_supports_format :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, type: sdl.GPUTextureType, usage: sdl.GPUTextureUsageFlags) -> bool {
	f := vk_format(format)
	if f == .UNDEFINED do return false
	flags: vk.ImageUsageFlags
	if .SAMPLER in usage do flags += {.SAMPLED}
	if .COLOR_TARGET in usage do flags += {.COLOR_ATTACHMENT}
	if .DEPTH_STENCIL_TARGET in usage do flags += {.DEPTH_STENCIL_ATTACHMENT}
	if usage & {.GRAPHICS_STORAGE_READ, .COMPUTE_STORAGE_READ, .COMPUTE_STORAGE_WRITE, .COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE} != {} do flags += {.STORAGE}
	create: vk.ImageCreateFlags
	if type == .CUBE || type == .CUBE_ARRAY do create += {.CUBE_COMPATIBLE}
	props: vk.ImageFormatProperties
	return vk.GetPhysicalDeviceImageFormatProperties(vk_state.physical, f, .D3 if type == .D3 else .D2, .OPTIMAL, flags, create, &props) == .SUCCESS
}

vk_texture_supports_sample_count :: proc(device: ^sdl.GPUDevice, format: sdl.GPUTextureFormat, sample_count: sdl.GPUSampleCount) -> bool {
	limits := &vk_state.properties.limits
	counts := limits.framebufferDepthSampleCounts if vk_is_depth(format) else limits.framebufferColorSampleCounts
	return vk_samples(sample_count) <= counts
}

vk_samples :: proc(count: sdl.GPUSampleCount) -> vk.SampleCountFlags {
	switch count {
	case ._1: return {._1}
	case ._2: return {._2}
	case ._4: return {._4}
	case ._8: return {._8}
	}
	return {._1}
}

// A memory type among `bits` with every property in `want`, preferring one that also has
// those in `prefer`.
vk_memory_type :: proc(bits: u32, want, prefer: vk.MemoryPropertyFlags) -> (u32, bool) {
	for pass in 0 ..< 2 {
		need := want + prefer if pass == 0 else want
		for i in 0 ..< vk_state.memory.memoryTypeCount {
			if bits & (1 << i) != 0 && vk_state.memory.memoryTypes[i].propertyFlags >= need do return i, true
		}
	}
	return 0, false
}

vk_allocate :: proc(reqs: vk.MemoryRequirements, want, prefer: vk.MemoryPropertyFlags) -> (vk.DeviceMemory, bool) {
	index, ok := vk_memory_type(reqs.memoryTypeBits, want, prefer)
	if !ok do return 0, false
	info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = reqs.size, memoryTypeIndex = index}
	memory: vk.DeviceMemory
	if vk.AllocateMemory(vk_state.device, &info, nil, &memory) != .SUCCESS do return 0, false
	return memory, true
}

// Records the GPU's progress and recycles the command buffers it has finished.
vk_collect :: proc() {
	value: u64
	if vk.GetSemaphoreCounterValue(vk_state.device, vk_state.timeline, &value) == .SUCCESS do vk_state.completed = value
	for i := 0; i < len(vk_state.in_flight); {
		cmd := vk_state.in_flight[i]
		if cmd.serial > vk_state.completed {
			i += 1
			continue
		}
		ordered_remove(&vk_state.in_flight, i)
		vk_cmd_recycle(cmd)
	}
}

vk_wait_serial :: proc(serial: u64) -> bool {
	if serial <= vk_state.completed do return true
	value := serial
	info := vk.SemaphoreWaitInfo{sType = .SEMAPHORE_WAIT_INFO, semaphoreCount = 1, pSemaphores = &vk_state.timeline, pValues = &value}
	ok := vk.WaitSemaphores(vk_state.device, &info, max(u64)) == .SUCCESS
	vk_collect()
	return ok
}

vk_wait_for_idle :: proc(device: ^sdl.GPUDevice) -> bool {
	ok := vk_wait_serial(vk_state.submitted)
	vk_collect()
	return ok
}
