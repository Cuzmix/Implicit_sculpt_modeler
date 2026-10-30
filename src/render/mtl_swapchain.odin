#+build darwin
package render

import "base:runtime"
import "core:sync"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import sdl "vendor:sdl3"

// Windows the Metal backend presents to: SDL's Metal view of each window and its
// CAMetalLayer, which hands out one drawable a frame. Up to mtl_state.frames frames are in
// flight per window (gpu_set_allowed_frames_in_flight); acquiring the next waits for the oldest, or with `wait` false finds none free
// and hands back no texture, as SDL_GPU's non-waiting acquire does. While one frame is in
// flight the layer keeps two drawables instead of three, so nextDrawable waits for the
// display to let one go and the frame reads its input a refresh later, closer to when it is
// shown. Each drawable reports when it reached the screen (Mtl_Present_Log).

foreign import core_graphics "system:CoreGraphics.framework"
foreign import quartz_core "system:QuartzCore.framework"

@(private = "file", default_calling_convention = "c")
foreign quartz_core {
	// Seconds of mach time, the clock a drawable's presentedTime counts in.
	CACurrentMediaTime :: proc() -> f64 ---
}

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
	log:          ^Mtl_Present_Log, // nil when every log is taken
	input_ns:     u64, // the input the next present shows (gpu_present_input), 0 for none
}

// Windows timed at once, and presents a log follows until they reach the screen.
MTL_PRESENT_LOGS :: 8
@(private = "file")
MTL_PRESENT_PENDING :: 8
@(private = "file")
MTL_PRESENT_SHOWN :: 32

// When a window's frames reached the screen, filled by Metal's presented handlers on a
// thread of Metal's. Logs live in mtl_state and outlive their windows, since a handler can
// run after the window is gone: a log is only marked free, and a handler whose drawable
// the log no longer holds does nothing. Its block is made once and freed with the device.
Mtl_Present_Log :: struct {
	lock:      sync.Mutex,
	block:     ^NS.Block,
	in_use:    bool,
	offset_ns: i64, // SDL's ticks minus CACurrentMediaTime, both in nanoseconds
	pending:   [MTL_PRESENT_PENDING]struct {
		drawable: rawptr,
		input_ns: u64,
	},
	shown:     [MTL_PRESENT_SHOWN]Present_Time,
	shown_len: int,
	dropped:   u64, // frames presented that never reached the screen
}

// The presented handler: matches the drawable to the frame it showed, and keeps the time it
// reached the screen (0: never, dropped). A full log forgets its oldest time.
@(private = "file")
mtl_presented :: proc "c" (user_data: rawptr, drawable: ^MTL.Drawable) {
	context = runtime.default_context()
	log := (^Mtl_Present_Log)(user_data)
	at := MTL.Drawable_presentedTime(drawable)
	sync.guard(&log.lock)
	for &p in log.pending {
		if p.drawable != rawptr(drawable) do continue
		p.drawable = nil
		if at <= 0 {
			log.dropped += 1
		} else if p.input_ns != 0 {
			if log.shown_len == MTL_PRESENT_SHOWN {
				copy(log.shown[:], log.shown[1:])
				log.shown_len -= 1
			}
			log.shown[log.shown_len] = {p.input_ns, u64(i64(at * 1e9) + log.offset_ns)}
			log.shown_len += 1
		}
		return
	}
}

// Called by mtl_submit before the drawable is presented, as Metal requires.
mtl_present_log_add :: proc(w: ^Mtl_Window, drawable: ^CA.MetalDrawable) {
	log := w.log
	input := w.input_ns
	w.input_ns = 0
	if log == nil do return
	{
		sync.guard(&log.lock)
		free_slot := -1
		for p, i in log.pending do if p.drawable == nil {
			free_slot = i
			break
		}
		// Every slot waits on a frame Metal never answered for; that frame goes untimed.
		if free_slot < 0 do return
		log.pending[free_slot] = {rawptr(drawable), input}
	}
	MTL.Drawable_addPresentedHandler(drawable, log.block)
}

@(private = "file")
mtl_present_log_claim :: proc(w: ^Mtl_Window) {
	for &log in mtl_state.present_logs {
		sync.guard(&log.lock)
		if log.in_use do continue
		if log.block == nil {
			log.block = NS.Block_createGlobalWithParam(&log, mtl_presented, runtime.heap_allocator())
			if log.block == nil do return
		}
		log.in_use = true
		log.pending, log.shown_len = {}, 0
		log.offset_ns = i64(sdl.GetTicksNS()) - i64(CACurrentMediaTime() * 1e9)
		w.log = &log
		return
	}
}

// Frees each log's block; the GPU is idle and every window released, so the handlers that
// could still come name drawables no log holds, and they come before Metal lets the
// drawables go.
mtl_present_logs_destroy :: proc() {
	for &log in mtl_state.present_logs {
		if log.block != nil do free(log.block, runtime.heap_allocator())
		log.block = nil
	}
}

mtl_present_input :: proc(window: ^sdl.Window, input_ns: u64) {
	if w := mtl_window_find(window); w != nil do w.input_ns = input_ns
}

mtl_present_times :: proc(window: ^sdl.Window, out: []Present_Time) -> int {
	w := mtl_window_find(window)
	if w == nil || w.log == nil do return 0
	sync.guard(&w.log.lock)
	n := min(len(out), w.log.shown_len)
	copy(out, w.log.shown[:n])
	copy(w.log.shown[:], w.log.shown[n:w.log.shown_len])
	w.log.shown_len -= n
	return n
}

// Frames presented to every window that never reached the screen.
mtl_frames_dropped :: proc() -> u64 {
	dropped: u64
	for &log in mtl_state.present_logs {
		sync.guard(&log.lock)
		dropped += log.dropped
	}
	return dropped
}

// Two drawables while one frame is in flight, so the acquire waits for the display; three
// otherwise, as SDL_GPU's Metal keeps.
@(private = "file")
mtl_layer_drawables :: proc(w: ^Mtl_Window) {
	CA.MetalLayer_setMaximumDrawableCount(w.layer, 2 if mtl_state.frames == 1 else 3)
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
	mtl_layer_drawables(w)
	mtl_present_log_claim(w)
	append(&mtl_state.windows, w)
	return true
}

mtl_release_window :: proc(device: ^sdl.GPUDevice, window: ^sdl.Window) {
	w := mtl_window_find(window)
	if w == nil do return
	_ = mtl_wait_for_idle(device)
	if w.log != nil {
		sync.guard(&w.log.lock)
		w.log.in_use = false
		w.log.pending = {}
	}
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
	for w in mtl_state.windows {
		w.frame = 0
		mtl_layer_drawables(w)
	}
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
