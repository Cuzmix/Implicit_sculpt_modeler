package render

import "core:log"

import sdl "vendor:sdl3"

// The GPU objects the app holds and passes back without looking inside: a frame's
// command buffers, the textures it shows, fences, and a sample count. Only this package
// names the GPU API (AGENTS.md's package boundaries; `scripts/boundary_check.py` fails
// the check otherwise), so another backend changes these and the procs below, and the
// app stays as it is.
Cmd :: ^sdl.GPUCommandBuffer
Texture :: ^sdl.GPUTexture
Fence :: ^sdl.GPUFence
Sample_Count :: sdl.GPUSampleCount

// Waits until the GPU has finished everything submitted: before freeing a buffer or
// texture a frame in flight may still read.
wait_idle :: proc(r: ^Renderer) {
	if !gpu_wait_for_idle(r.device) do log.warnf("WaitForGPUIdle failed: %s", sdl.GetError())
}

// A command buffer to record into, or nil (logged) when the device has none to give.
cmd_begin :: proc(r: ^Renderer) -> Cmd {
	cmd := gpu_acquire_command_buffer(r.device)
	if cmd == nil do log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
	return cmd
}

// Sends the recorded work to the GPU; false (logged) when the device refused it.
cmd_submit :: proc(cmd: Cmd) -> bool {
	if gpu_submit_command_buffer(cmd) do return true
	log.errorf("submit failed: %s", sdl.GetError())
	return false
}

// Sends the recorded work with a fence that signals when the GPU has done it; nil
// (logged) when the device refused it.
cmd_submit_fenced :: proc(cmd: Cmd) -> Fence {
	fence := gpu_submit_command_buffer_and_acquire_fence(cmd)
	if fence == nil do log.errorf("submit failed: %s", sdl.GetError())
	return fence
}

// Drops a command buffer unsubmitted. One that holds a swapchain texture cannot be
// cancelled: submit it instead.
cmd_cancel :: proc(cmd: Cmd) -> bool {
	return gpu_cancel_command_buffer(cmd)
}

// Waits for the fence, releases it and clears the handle; nothing for nil.
fence_finish :: proc(r: ^Renderer, fence: ^Fence) {
	if fence^ == nil do return
	_ = gpu_wait_for_fences(r.device, true, fence, 1)
	gpu_release_fence(r.device, fence^)
	fence^ = nil
}

// The window's next swapchain texture for `cmd` and its size in pixels. With `wait`, waits
// until the display has one free (the main window, paced by it); without, `texture` is
// nil when none is free now (a view window, which then shows its last picture). False
// (logged) when the swapchain failed.
swapchain_acquire :: proc(cmd: Cmd, window: ^sdl.Window, wait: bool) -> (texture: Texture, size: [2]u32, ok: bool) {
	if wait {
		ok = gpu_wait_and_acquire_swapchain_texture(cmd, window, &texture, &size.x, &size.y)
	} else {
		ok = gpu_acquire_swapchain_texture(cmd, window, &texture, &size.x, &size.y)
	}
	if !ok do log.errorf("acquire swapchain failed: %s", sdl.GetError())
	return
}

// The pass a window presents: clears its swapchain texture to `clear` and, when `draw`
// (the interface was uploaded), draws the interface into it. Cleared either way, so a
// failed upload shows an empty frame rather than whatever the texture held. `size` is the
// window's; a pre-rotated swapchain's texture is turned from it (swapchain_turns).
ui_present :: proc(r: ^Renderer, up: ^Ui_Pass, cmd: Cmd, window: ^sdl.Window, swapchain: Texture, size: [2]u32, clear: [4]f32, draws: []Ui_Draw, draw: bool) {
	debug_group(cmd, "Interface")
	target := sdl.GPUColorTargetInfo {
		texture     = swapchain,
		clear_color = sdl.FColor(clear),
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	pass := gpu_begin_render_pass(cmd, &target, 1, nil)
	if draw {
		format := gpu_get_swapchain_texture_format(r.device, window)
		ui_pass_draw(r, up, cmd, pass, format, size, draws, gpu_swapchain_turns(window))
	}
	gpu_end_render_pass(pass)
}

// Quarter turns clockwise the window's swapchain images are drawn at (pre-rotation): 0
// upright, which is all but Android's own Vulkan backend on a turned tablet.
swapchain_turns :: proc(window: ^sdl.Window) -> int {
	return gpu_swapchain_turns(window)
}

// Lets the own Vulkan backend pre-rotate (on Android it does by default); set before the
// window is claimed. --no-pre-rotate turns it off to compare.
set_pre_rotate :: proc(on: bool) {
	vk_pre_rotate = on
}

// Whether the device exists: false before renderer_init and in runs without a window.
renderer_ready :: proc(r: ^Renderer) -> bool {
	return r.device != nil
}

// Names the commands recorded from here to the end of the enclosing scope for capture
// tools (Xcode's GPU capture, RenderDoc): a group pushed now and popped as the scope ends.
// Called outside any pass, so the group spans whole passes.
@(deferred_in = debug_group_end)
debug_group :: proc(cmd: ^sdl.GPUCommandBuffer, name: cstring) {
	gpu_push_debug_group(cmd, name)
}

@(private)
debug_group_end :: proc(cmd: ^sdl.GPUCommandBuffer, name: cstring) {
	gpu_pop_debug_group(cmd)
}
