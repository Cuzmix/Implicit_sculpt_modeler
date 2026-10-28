package render

import "core:log"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Windows the Vulkan backend presents to: a surface and swapchain each, remade when the
// window's size changes or the swapchain goes out of date. Up to VK_FRAMES frames are in
// flight per window; acquiring the next waits for the oldest, or with `wait` false finds
// none free and hands back no texture, as SDL_GPU's non-waiting acquire does.

Vk_Window :: struct {
	window:       ^sdl.Window,
	surface:      vk.SurfaceKHR,
	swapchain:    vk.SwapchainKHR,
	format:       vk.Format,
	sdl_format:   sdl.GPUTextureFormat,
	color_space:  vk.ColorSpaceKHR,
	present_mode: sdl.GPUPresentMode,
	width:        u32,
	height:       u32,
	textures:     []^Vk_Texture,
	render_done:  []vk.Semaphore, // one per image, signalled by the submission presenting it
	acquired:     [VK_FRAMES]vk.Semaphore,
	frame_serial: [VK_FRAMES]u64,
	frame:        int,
	stale:        bool, // remade before the next acquire
}

vk_window_find :: proc(window: ^sdl.Window) -> ^Vk_Window {
	for w in vk_state.windows do if w.window == window do return w
	return nil
}

@(private = "file")
vk_present_mode :: proc(mode: sdl.GPUPresentMode) -> vk.PresentModeKHR {
	switch mode {
	case .VSYNC:     return .FIFO
	case .IMMEDIATE: return .IMMEDIATE
	case .MAILBOX:   return .MAILBOX
	}
	return .FIFO
}

@(private = "file")
vk_swapchain_free :: proc(w: ^Vk_Window) {
	for t in w.textures {
		for img in t.backings {
			for view in img.level_views do vk.DestroyImageView(vk_state.device, view, nil)
			delete(img.level_views)
			free(img)
		}
		delete(t.backings)
		free(t)
	}
	delete(w.textures)
	for s in w.render_done do vk.DestroySemaphore(vk_state.device, s, nil)
	delete(w.render_done)
	w.textures, w.render_done = nil, nil
}

// (Re)makes the window's swapchain at its current size; false leaves it without one (a
// minimised window), to be tried again at the next acquire.
@(private = "file")
vk_swapchain_make :: proc(w: ^Vk_Window) -> bool {
	_ = vk_wait_for_idle(vk_device_handle())
	caps: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk_state.physical, w.surface, &caps) != .SUCCESS do return false
	pw, ph: i32
	_ = sdl.GetWindowSizeInPixels(w.window, &pw, &ph)
	extent := caps.currentExtent
	if extent.width == max(u32) {
		extent = {clamp(u32(max(pw, 0)), caps.minImageExtent.width, caps.maxImageExtent.width), clamp(u32(max(ph, 0)), caps.minImageExtent.height, caps.maxImageExtent.height)}
	}
	old := w.swapchain
	vk_swapchain_free(w)
	if extent.width == 0 || extent.height == 0 {
		if old != 0 do vk.DestroySwapchainKHR(vk_state.device, old, nil)
		w.swapchain = 0
		w.stale = true
		return false
	}
	images := caps.minImageCount + 1
	if caps.maxImageCount > 0 do images = min(images, caps.maxImageCount)
	usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT} + (caps.supportedUsageFlags & {.TRANSFER_SRC, .TRANSFER_DST})
	alpha := vk.CompositeAlphaFlagsKHR{.OPAQUE}
	if .OPAQUE not_in caps.supportedCompositeAlpha {
		for flag in vk.CompositeAlphaFlagKHR do if flag in caps.supportedCompositeAlpha {
			alpha = {flag}
			break
		}
	}
	// Identity where offered: the app draws upright and lets the compositor rotate, as
	// SDL_GPU does on Android.
	transform := vk.SurfaceTransformFlagsKHR{.IDENTITY} if .IDENTITY in caps.supportedTransforms else caps.currentTransform
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = w.surface,
		minImageCount    = images,
		imageFormat      = w.format,
		imageColorSpace  = w.color_space,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = usage,
		imageSharingMode = .EXCLUSIVE,
		preTransform     = transform,
		compositeAlpha   = alpha,
		presentMode      = vk_present_mode(w.present_mode),
		clipped          = true,
		oldSwapchain     = old,
	}
	r := vk.CreateSwapchainKHR(vk_state.device, &info, nil, &w.swapchain)
	if old != 0 do vk.DestroySwapchainKHR(vk_state.device, old, nil)
	if r != .SUCCESS {
		log.errorf("Vulkan: vkCreateSwapchainKHR failed: %v", r)
		w.swapchain = 0
		w.stale = true
		return false
	}
	count: u32
	vk.GetSwapchainImagesKHR(vk_state.device, w.swapchain, &count, nil)
	handles := make([]vk.Image, count, context.temp_allocator)
	vk.GetSwapchainImagesKHR(vk_state.device, w.swapchain, &count, raw_data(handles))
	w.textures = make([]^Vk_Texture, count)
	w.render_done = make([]vk.Semaphore, count)
	semaphore := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	for handle, i in handles {
		t := new(Vk_Texture)
		t.info = {type = .D2, format = w.sdl_format, usage = {.COLOR_TARGET}, width = extent.width, height = extent.height, layer_count_or_depth = 1, num_levels = 1}
		t.format, t.aspect, t.usage = w.format, {.COLOR}, usage
		t.default_layout = .COLOR_ATTACHMENT_OPTIMAL
		t.swapchain = true
		img := new(Vk_Image)
		img.image, img.owner = handle, t
		view := vk.ImageViewCreateInfo{sType = .IMAGE_VIEW_CREATE_INFO, image = handle, viewType = .D2, format = w.format, subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}}
		img.level_views = make([]vk.ImageView, 1)
		_ = vk.CreateImageView(vk_state.device, &view, nil, &img.level_views[0])
		append(&t.backings, img)
		t.active = img
		w.textures[i] = t
		_ = vk.CreateSemaphore(vk_state.device, &semaphore, nil, &w.render_done[i])
	}
	w.width, w.height = extent.width, extent.height
	w.stale = false
	return true
}

vk_claim_window :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> bool {
	if vk_window_find(window) != nil do return true
	w := new(Vk_Window)
	w.window = window
	if !sdl.Vulkan_CreateSurface(window, vk_state.instance, nil, &w.surface) {
		free(w)
		return false
	}
	supported: b32
	if vk.GetPhysicalDeviceSurfaceSupportKHR(vk_state.physical, vk_state.family, w.surface, &supported) != .SUCCESS || !supported {
		vk.DestroySurfaceKHR(vk_state.instance, w.surface, nil)
		free(w)
		sdl.SetError("the Vulkan queue cannot present to this window")
		return false
	}
	// SDL_GPU's SDR composition: BGRA8, else RGBA8, in sRGB colour space.
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(vk_state.physical, w.surface, &count, nil)
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(vk_state.physical, w.surface, &count, raw_data(formats))
	w.format = .UNDEFINED
	for want in ([2]vk.Format{.B8G8R8A8_UNORM, .R8G8B8A8_UNORM}) {
		for f in formats do if f.format == want && f.colorSpace == .SRGB_NONLINEAR {
			w.format, w.color_space = f.format, f.colorSpace
			break
		}
		if w.format != .UNDEFINED do break
	}
	if w.format == .UNDEFINED {
		vk.DestroySurfaceKHR(vk_state.instance, w.surface, nil)
		free(w)
		sdl.SetError("the window offers no 8-bit sRGB swapchain format")
		return false
	}
	w.sdl_format = .B8G8R8A8_UNORM if w.format == .B8G8R8A8_UNORM else .R8G8B8A8_UNORM
	w.present_mode = .VSYNC
	semaphore := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	for &s in w.acquired do _ = vk.CreateSemaphore(vk_state.device, &semaphore, nil, &s)
	append(&vk_state.windows, w)
	vk_swapchain_make(w)
	return true
}

vk_release_window :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) {
	w := vk_window_find(window)
	if w == nil do return
	_ = vk_wait_for_idle(device)
	vk_swapchain_free(w)
	if w.swapchain != 0 do vk.DestroySwapchainKHR(vk_state.device, w.swapchain, nil)
	for s in w.acquired do vk.DestroySemaphore(vk_state.device, s, nil)
	vk.DestroySurfaceKHR(vk_state.instance, w.surface, nil)
	for other, i in vk_state.windows do if other == w {
		ordered_remove(&vk_state.windows, i)
		break
	}
	free(w)
}

vk_window_supports_present_mode :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, present_mode: sdl.GPUPresentMode) -> bool {
	if present_mode == .VSYNC do return true
	w := vk_window_find(window)
	if w == nil do return false
	count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(vk_state.physical, w.surface, &count, nil)
	modes := make([]vk.PresentModeKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(vk_state.physical, w.surface, &count, raw_data(modes))
	want := vk_present_mode(present_mode)
	for m in modes do if m == want do return true
	return false
}

vk_set_swapchain_parameters :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, swapchain_composition: sdl.GPUSwapchainComposition, present_mode: sdl.GPUPresentMode) -> bool {
	w := vk_window_find(window)
	if w == nil || swapchain_composition != .SDR || !vk_window_supports_present_mode(device, window, present_mode) {
		sdl.SetError("this swapchain composition or present mode is not offered")
		return false
	}
	w.present_mode = present_mode
	vk_swapchain_make(w)
	return true
}

vk_get_swapchain_texture_format :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> sdl.GPUTextureFormat {
	w := vk_window_find(window)
	return w.sdl_format if w != nil else .INVALID
}

vk_acquire_swapchain :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, texture: ^^sdl.GPUTexture, width, height: ^u32, wait: bool) -> bool {
	cmd := (^Vk_Cmd)(command_buffer)
	texture^ = nil
	w := vk_window_find(window)
	if w == nil {
		sdl.SetError("the window was not claimed")
		return false
	}
	pw, ph: i32
	_ = sdl.GetWindowSizeInPixels(window, &pw, &ph)
	if w.stale || w.swapchain == 0 || u32(pw) != w.width || u32(ph) != w.height {
		if !vk_swapchain_make(w) do return true
	}
	slot := w.frame
	if w.frame_serial[slot] > vk_state.completed {
		if wait {
			vk_wait_serial(w.frame_serial[slot])
		} else {
			vk_collect()
			if w.frame_serial[slot] > vk_state.completed do return true
		}
	}
	index: u32
	r := vk.AcquireNextImageKHR(vk_state.device, w.swapchain, max(u64), w.acquired[slot], 0, &index)
	if r == .ERROR_OUT_OF_DATE_KHR || r == .ERROR_SURFACE_LOST_KHR {
		w.stale = true
		return true
	}
	if r != .SUCCESS && r != .SUBOPTIMAL_KHR {
		log.errorf("Vulkan: vkAcquireNextImageKHR failed: %v", r)
		return true
	}
	// A suboptimal swapchain still presents; it is remade at the next size change (Android
	// reports suboptimal for every rotation it composites itself).
	t := w.textures[index]
	vk_cmd_track_image(cmd, t.active)
	vk_image_barrier(cmd, t.active, .UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL)
	append(&cmd.presents, Vk_Present{w, index, slot})
	w.frame = (w.frame + 1) % VK_FRAMES
	texture^ = (^sdl.GPUTexture)(t)
	if width != nil do width^ = w.width
	if height != nil do height^ = w.height
	return true
}

vk_present :: proc(p: Vk_Present) {
	w := p.window
	index := p.image
	info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &w.render_done[index],
		swapchainCount     = 1,
		pSwapchains        = &w.swapchain,
		pImageIndices      = &index,
	}
	r := vk.QueuePresentKHR(vk_state.queue, &info)
	if r == .ERROR_OUT_OF_DATE_KHR || r == .ERROR_SURFACE_LOST_KHR do w.stale = true
}
