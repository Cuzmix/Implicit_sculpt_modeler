package render

import "core:log"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Windows the Vulkan backend presents to: a surface and swapchain each, remade when the
// window's size changes or the swapchain goes out of date. Up to vk_state.frames frames are
// in flight per window (gpu_set_allowed_frames_in_flight); acquiring the next waits for the oldest, or with `wait` false finds
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
	acquired:     [FRAMES_IN_FLIGHT_MAX]vk.Semaphore,
	frame_serial: [FRAMES_IN_FLIGHT_MAX]u64,
	frame:        int,
	stale:        bool, // remade before the next acquire
	turns:        int, // quarter turns clockwise the images' content is drawn at (pre-rotation; 0 upright)
	// Present timing (Gpu_Caps.present_timing): each present takes the next id, counting
	// from 1 across the window's swapchains; ids before present_base went to an earlier one,
	// whose presents are never waited for. present_seen is the newest id known shown (or
	// given up on), present_input the input time for the next present, and pending the
	// input times of the latest presents by id.
	present_id:    u64,
	present_base:  u64,
	present_seen:  u64,
	present_input: u64,
	pending:       [VK_PENDING]Vk_Pending,
	shown:         [VK_PENDING]Present_Time, // learned, not yet taken by vk_present_times
	shown_count:   int,
	pace_misses:   int, // pacing waits in a row that timed out; at VK_PACE_MISSES the window stops pacing
}

// Presents whose screen time is still to learn, at most. More than a swapchain has images,
// so a present is learned or given up on before its slot is taken again.
VK_PENDING :: 8
// A present not shown after this long is taken as never to be (a hidden window, a driver
// that holds frames); after VK_PACE_MISSES such waits in a row the window stops pacing
// until its swapchain is remade.
VK_PACE_TIMEOUT_NS :: 100_000_000
VK_PACE_MISSES :: 3

Vk_Pending :: struct {
	id:       u64,
	input_ns: u64,
}

// Pre-rotation (on Android, unless --no-pre-rotate): a swapchain takes the screen's own
// orientation and the interface pass turns what it draws to match (ui_pass_draw), so the
// compositor has no rotation pass to run, which costs a tablet GPU time and clock speed.
// Only the interface pass draws into a swapchain image; the 3D view goes through it as a
// texture. Desktop surfaces report no rotation, so they stay upright either way.
vk_pre_rotate := ODIN_PLATFORM_SUBTARGET == .Android

// The quarter turns the surface asks images to be drawn at now, and the transform to
// make the swapchain with: the surface's own where pre-rotation is on and it is a plain
// turn the surface takes, otherwise identity (the compositor turns them), as SDL_GPU does.
@(private = "file")
vk_pick_transform :: proc(caps: vk.SurfaceCapabilitiesKHR) -> (vk.SurfaceTransformFlagsKHR, int) {
	turns := 0
	if caps.currentTransform == {.ROTATE_90} do turns = 1
	else if caps.currentTransform == {.ROTATE_180} do turns = 2
	else if caps.currentTransform == {.ROTATE_270} do turns = 3
	if vk_pre_rotate && turns > 0 && caps.currentTransform <= caps.supportedTransforms do return caps.currentTransform, turns
	return {.IDENTITY} if .IDENTITY in caps.supportedTransforms else caps.currentTransform, 0
}

// Whether the surface now asks for other turns than the swapchain was made with: a
// suboptimal acquire or present after the device turned (180 degrees keeps the size, so
// only this tells). Without pre-rotation every turned screen reports suboptimal, which is
// no reason to remake anything.
@(private = "file")
vk_turns_moved :: proc(w: ^Vk_Window) -> bool {
	if !vk_pre_rotate do return false
	caps: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk_state.physical, w.surface, &caps) != .SUCCESS do return false
	_, turns := vk_pick_transform(caps)
	return turns != w.turns
}

vk_swapchain_turns :: proc(window: ^sdl.Window) -> int {
	w := vk_window_find(window)
	return w.turns if w != nil else 0
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
	// The new swapchain's presents start at the next id; the old one's are not waited for.
	w.present_base = w.present_id + 1
	w.present_seen = w.present_id
	w.pace_misses = 0
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
	transform, turns := vk_pick_transform(caps)
	// A turned swapchain's images are as the screen is built, a quarter turn from the
	// window. Which way the surface reports its extent differs between drivers, so the
	// window's own shape decides.
	if turns % 2 == 1 && pw != ph && (extent.width > extent.height) == (pw > ph) do extent = {extent.height, extent.width}
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
	// The app sees the window's size; only the images are turned.
	w.width, w.height = extent.width, extent.height
	if turns % 2 == 1 do w.width, w.height = extent.height, extent.width
	w.turns = turns
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

// As SDL_GPU's: a frame slot per allowed frame. The GPU is waited for first, so every slot
// is free and each window starts again at its first; the swapchains stay as they are.
vk_set_allowed_frames_in_flight :: proc(device: ^sdl.GPUDevice, allowed_frames_in_flight: u32) -> bool {
	if !vk_wait_for_idle(device) do return false
	vk_state.frames = clamp(allowed_frames_in_flight, 1, FRAMES_IN_FLIGHT_MAX)
	for w in vk_state.windows do w.frame = 0
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
	vk_present_learn(w, wait)
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
	// reports suboptimal for every rotation it composites itself), or when pre-rotation
	// finds the screen turned.
	if r == .SUBOPTIMAL_KHR && vk_turns_moved(w) do w.stale = true
	t := w.textures[index]
	vk_cmd_track_image(cmd, t.active)
	vk_image_barrier(cmd, t.active, .UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL)
	append(&cmd.presents, Vk_Present{w, index, slot})
	w.frame = (w.frame + 1) % int(vk_state.frames)
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
	w.present_id += 1
	id := w.present_id
	w.pending[id % VK_PENDING] = {id, w.present_input}
	w.present_input = 0
	present_id := vk.PresentIdKHR{sType = .PRESENT_ID_KHR, swapchainCount = 1, pPresentIds = &id}
	time := vk.PresentTimeGOOGLE{presentID = u32(id)}
	times := vk.PresentTimesInfoGOOGLE{sType = .PRESENT_TIMES_INFO_GOOGLE, swapchainCount = 1, pTimes = &time}
	switch vk_state.present_timing {
	case .Present_Wait:   info.pNext = &present_id
	case .Display_Timing: info.pNext = &times
	case .None, .Presented_Handler:
	}
	r := vk.QueuePresentKHR(vk_state.queue, &info)
	if r == .ERROR_OUT_OF_DATE_KHR || r == .ERROR_SURFACE_LOST_KHR || (r == .SUBOPTIMAL_KHR && vk_turns_moved(w)) do w.stale = true
}

vk_present_input :: proc(window: ^sdl.Window, input_ns: u64) {
	if w := vk_window_find(window); w != nil do w.present_input = input_ns
}

vk_present_times :: proc(window: ^sdl.Window, out: []Present_Time) -> int {
	w := vk_window_find(window)
	if w == nil do return 0
	n := min(w.shown_count, len(out))
	copy(out, w.shown[:n])
	w.shown_count = 0
	return n
}

// Present id `id` reached the screen at `shown_ns` (SDL nanoseconds): kept for
// vk_present_times when it was tagged with an input time.
@(private = "file")
vk_present_shown :: proc(w: ^Vk_Window, id, shown_ns: u64) {
	p := w.pending[id % VK_PENDING]
	if p.id != id || p.input_ns == 0 || shown_ns < p.input_ns do return
	if w.shown_count == VK_PENDING {
		copy(w.shown[:], w.shown[1:])
		w.shown_count -= 1
	}
	w.shown[w.shown_count] = {p.input_ns, shown_ns}
	w.shown_count += 1
}

// Learns which presents reached the screen, before the window's next acquire. Under
// present_wait and vsync, a waiting acquire first waits for the present frames_in_flight
// back to be shown: then no more frames than are allowed in flight queue for the screen,
// and the input read after this wait shows sooner. Without waiting, presents already shown
// are found and timed now, so a time is late by at most the frame between.
@(private = "file")
vk_present_learn :: proc(w: ^Vk_Window, wait: bool) {
	switch vk_state.present_timing {
	case .None, .Presented_Handler:
	case .Present_Wait:
		back := u64(vk_state.frames - 1)
		if wait && w.present_mode == .VSYNC && w.pace_misses < VK_PACE_MISSES && w.present_id > back {
			target := w.present_id - back
			if target >= w.present_base && target > w.present_seen {
				r := vk.WaitForPresentKHR(vk_state.device, w.swapchain, target, VK_PACE_TIMEOUT_NS)
				#partial switch r {
				case .SUCCESS, .SUBOPTIMAL_KHR:
					w.pace_misses = 0
					w.present_seen = target
					vk_present_shown(w, target, sdl.GetTicksNS())
				case .TIMEOUT:
					w.pace_misses += 1
					if w.pace_misses == VK_PACE_MISSES do log.warnf("Vulkan: presents are not shown within %d ms; pacing by them stops until the swapchain is remade", VK_PACE_TIMEOUT_NS / 1_000_000)
				case .ERROR_OUT_OF_DATE_KHR, .ERROR_SURFACE_LOST_KHR:
					w.stale = true
					return
				}
			}
		}
		// Presents older than a slot's reach are given up on; the rest are asked without waiting.
		if w.present_id > VK_PENDING do w.present_seen = max(w.present_seen, w.present_id - VK_PENDING)
		for id := w.present_seen + 1; id <= w.present_id; id += 1 {
			if vk.WaitForPresentKHR(vk_state.device, w.swapchain, id, 0) != .SUCCESS do break
			w.present_seen = id
			vk_present_shown(w, id, sdl.GetTicksNS())
		}
	case .Display_Timing:
		timings: [VK_PENDING]vk.PastPresentationTimingGOOGLE
		count := u32(len(timings))
		r := vk.GetPastPresentationTimingGOOGLE(vk_state.device, w.swapchain, &count, &timings[0])
		if r != .SUCCESS && r != .INCOMPLETE do return
		for t in timings[:count] {
			// The 32-bit id stands for the newest present it matches.
			slot := w.pending[u64(t.presentID) % VK_PENDING]
			if u32(slot.id) != t.presentID do continue
			if shown := vk_monotonic_to_ticks(t.actualPresentTime); shown != 0 do vk_present_shown(w, slot.id, shown)
		}
	}
}
