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
	if !sdl.WaitForGPUIdle(r.device) do log.warnf("WaitForGPUIdle failed: %s", sdl.GetError())
}

// A command buffer to record into, or nil (logged) when the device has none to give.
cmd_begin :: proc(r: ^Renderer) -> Cmd {
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil do log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
	return cmd
}

// Sends the recorded work to the GPU; false (logged) when the device refused it.
cmd_submit :: proc(cmd: Cmd) -> bool {
	if sdl.SubmitGPUCommandBuffer(cmd) do return true
	log.errorf("submit failed: %s", sdl.GetError())
	return false
}

// Sends the recorded work with a fence that signals when the GPU has done it; nil
// (logged) when the device refused it.
cmd_submit_fenced :: proc(cmd: Cmd) -> Fence {
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil do log.errorf("submit failed: %s", sdl.GetError())
	return fence
}

// Drops a command buffer unsubmitted. One that holds a swapchain texture cannot be
// cancelled: submit it instead.
cmd_cancel :: proc(cmd: Cmd) -> bool {
	return sdl.CancelGPUCommandBuffer(cmd)
}

// Waits for the fence, releases it and clears the handle; nothing for nil.
fence_finish :: proc(r: ^Renderer, fence: ^Fence) {
	if fence^ == nil do return
	_ = sdl.WaitForGPUFences(r.device, true, fence, 1)
	sdl.ReleaseGPUFence(r.device, fence^)
	fence^ = nil
}

// The window's next swapchain texture for `cmd` and its size in pixels. With `wait`, waits
// until the display has one free (the main window, paced by it); without, `texture` is
// nil when none is free now (a view window, which then shows its last picture). False
// (logged) when the swapchain failed.
swapchain_acquire :: proc(cmd: Cmd, window: ^sdl.Window, wait: bool) -> (texture: Texture, size: [2]u32, ok: bool) {
	if wait {
		ok = sdl.WaitAndAcquireGPUSwapchainTexture(cmd, window, &texture, &size.x, &size.y)
	} else {
		ok = sdl.AcquireGPUSwapchainTexture(cmd, window, &texture, &size.x, &size.y)
	}
	if !ok do log.errorf("acquire swapchain failed: %s", sdl.GetError())
	return
}

// The pass a window presents: clears its swapchain texture to `clear` and, when `draw`
// (the interface was uploaded), draws the interface into it. Cleared either way, so a
// failed upload shows an empty frame rather than whatever the texture held.
ui_present :: proc(r: ^Renderer, up: ^Ui_Pass, cmd: Cmd, window: ^sdl.Window, swapchain: Texture, size: [2]u32, clear: [4]f32, draws: []Ui_Draw, draw: bool) {
	target := sdl.GPUColorTargetInfo {
		texture     = swapchain,
		clear_color = sdl.FColor(clear),
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
	if draw {
		format := sdl.GetGPUSwapchainTextureFormat(r.device, window)
		ui_pass_draw(r, up, cmd, pass, format, size, draws)
	}
	sdl.EndGPURenderPass(pass)
}

// Whether the device exists: false before renderer_init and in runs without a window.
renderer_ready :: proc(r: ^Renderer) -> bool {
	return r.device != nil
}
