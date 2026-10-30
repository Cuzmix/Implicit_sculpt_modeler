#+build darwin
package render

import NS "core:sys/darwin/Foundation"
import CA "vendor:darwin/QuartzCore"
import sdl "vendor:sdl3"

// Windows the Metal backend presents to: SDL's Metal view of each window and its
// CAMetalLayer, which hands out one drawable a frame. Up to mtl_state.frames frames are in
// flight per window (gpu_set_allowed_frames_in_flight); acquiring the next waits for the oldest, or with `wait` false finds none free
// and hands back no texture, as SDL_GPU's non-waiting acquire does.

foreign import core_graphics "system:CoreGraphics.framework"

@(private = "file", default_calling_convention = "c")
foreign core_graphics {
	CGColorSpaceCreateWithName :: proc(name: NS.id) -> rawptr ---
	CGColorSpaceRelease :: proc(space: rawptr) ---
	kCGColorSpaceSRGB: NS.id
}

Mtl_Window :: struct {
	window:       ^sdl.Window,
	view:         sdl.MetalView,
	layer:        ^CA.MetalLayer,
	format:       sdl.GPUTextureFormat,
	present_mode: sdl.GPUPresentMode,
	// The texture the app draws the window into: a container whose one backing is pointed
	// at each frame's drawable.
	texture:      Mtl_Texture,
	backing:      Mtl_Texture_Backing,
	frame_serial: [FRAMES_IN_FLIGHT_MAX]u64,
	frame:        int,
}

mtl_window_find :: proc(window: ^sdl.Window) -> ^Mtl_Window {
	for w in mtl_state.windows do if w.window == window do return w
	return nil
}

// The Mac turns vsync off by not syncing the layer to the display; the iPad always syncs.
@(private = "file")
mtl_layer_present_mode :: proc(w: ^Mtl_Window, mode: sdl.GPUPresentMode) {
	when !ODIN_PLATFORM_SUBTARGET_IOS {
		CA.MetalLayer_setDisplaySyncEnabled(w.layer, mode != .IMMEDIATE)
	}
	w.present_mode = mode
}

mtl_claim_window :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> bool {
	NS.scoped_autoreleasepool()
	if mtl_window_find(window) != nil do return true
	view := sdl.Metal_CreateView(window)
	if view == nil do return false
	w := new(Mtl_Window)
	w.window, w.view = window, view
	w.layer = (^CA.MetalLayer)(sdl.Metal_GetLayer(view))
	CA.MetalLayer_setDevice(w.layer, mtl_state.device)
	mtl_layer_present_mode(w, .VSYNC)
	// SDL_GPU's SDR composition: BGRA8 in the sRGB colour space.
	w.format = .B8G8R8A8_UNORM
	CA.MetalLayer_setPixelFormat(w.layer, .BGRA8Unorm)
	if space := CGColorSpaceCreateWithName(kCGColorSpaceSRGB); space != nil {
		CA.MetalLayer_setColorSpace(w.layer, NS.id(space))
		CGColorSpaceRelease(space)
	}
	w.texture.info = {type = .D2, format = w.format, usage = {.COLOR_TARGET}, layer_count_or_depth = 1, num_levels = 1}
	w.texture.swapchain = true
	w.texture.active = &w.backing
	w.backing.owner = &w.texture
	append(&mtl_state.windows, w)
	return true
}

mtl_release_window :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) {
	w := mtl_window_find(window)
	if w == nil do return
	_ = mtl_wait_for_idle(device)
	sdl.Metal_DestroyView(w.view)
	for other, i in mtl_state.windows do if other == w {
		ordered_remove(&mtl_state.windows, i)
		break
	}
	free(w)
}

// Vsync everywhere, and no sync on the Mac only, as SDL_GPU offers.
mtl_window_supports_present_mode :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, present_mode: sdl.GPUPresentMode) -> bool {
	switch present_mode {
	case .VSYNC:     return true
	case .IMMEDIATE: return !ODIN_PLATFORM_SUBTARGET_IOS
	case .MAILBOX:   return false
	}
	return false
}

mtl_set_swapchain_parameters :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window, swapchain_composition: sdl.GPUSwapchainComposition, present_mode: sdl.GPUPresentMode) -> bool {
	w := mtl_window_find(window)
	if w == nil || swapchain_composition != .SDR || !mtl_window_supports_present_mode(device, window, present_mode) {
		sdl.SetError("this swapchain composition or present mode is not offered")
		return false
	}
	_ = mtl_wait_for_idle(device)
	mtl_layer_present_mode(w, present_mode)
	return true
}

// As SDL_GPU's Metal: the GPU is waited for, then each window starts again at its first
// frame slot.
mtl_set_allowed_frames_in_flight :: proc(device: ^sdl.GPUDevice, allowed_frames_in_flight: u32) -> bool {
	if !mtl_wait_for_idle(device) do return false
	mtl_state.frames = clamp(allowed_frames_in_flight, 1, FRAMES_IN_FLIGHT_MAX)
	for w in mtl_state.windows do w.frame = 0
	return true
}

mtl_get_swapchain_texture_format :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) -> sdl.GPUTextureFormat {
	w := mtl_window_find(window)
	return w.format if w != nil else .INVALID
}

mtl_acquire_swapchain :: proc(command_buffer: ^sdl.GPUCommandBuffer, window: ^sdl.Window, texture: ^^sdl.GPUTexture, width, height: ^u32, wait: bool) -> bool {
	NS.scoped_autoreleasepool()
	cmd := (^Mtl_Cmd)(command_buffer)
	texture^ = nil
	w := mtl_window_find(window)
	if w == nil {
		sdl.SetError("the window was not claimed")
		return false
	}
	// SDL's Metal view keeps the drawable size in step with the window's pixels.
	size := CA.MetalLayer_drawableSize(w.layer)
	w.texture.info.width, w.texture.info.height = u32(size.width), u32(size.height)
	if width != nil do width^ = w.texture.info.width
	if height != nil do height^ = w.texture.info.height
	slot := w.frame
	if w.frame_serial[slot] > mtl_state.completed {
		if wait {
			if !mtl_wait_serial(w.frame_serial[slot]) do return false
		} else {
			mtl_collect()
			if w.frame_serial[slot] > mtl_state.completed do return true
		}
	}
	// nextDrawable gives up after a second without one (a hidden window); the frame is then
	// skipped, as a busy swapchain is.
	drawable := CA.MetalLayer_nextDrawable(w.layer)
	if drawable == nil do return true
	NS.retain(drawable)
	w.backing.texture = CA.MetalDrawable_texture(drawable)
	append(&cmd.presents, Mtl_Present{w, drawable, slot})
	w.frame = (w.frame + 1) % int(mtl_state.frames)
	texture^ = (^sdl.GPUTexture)(&w.texture)
	return true
}
