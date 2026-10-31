package main

import "core:fmt"

import "../render"
import "../ui"

// Render draws with its own Metal backend on Mac and iPad and its own Vulkan backend
// everywhere else; nothing chooses between them (SDL_GPU, the fallback both once had, is
// retired).
GRAPHICS_METAL :: ODIN_OS == .Darwin

// Whether Ray tracing hardware starts on. On Apple's platforms it starts off: Metal's ray
// tracing has not been measured on an Apple GPU, and the M1 and M2 trace in software.
RAY_QUERY_DEFAULT :: !GRAPHICS_METAL

// What a device that cannot run the backend is told before Sculpt closes: what the app
// needs and why it stopped, shown in the system's message box (platform_alert).
graphics_failed_text :: proc() -> string {
	needs := "a GPU with Metal (an A9, any Apple silicon Mac or a Mac with Metal 2)" if GRAPHICS_METAL else "a GPU and driver with Vulkan 1.3 (dynamic rendering, synchronization2 and timeline semaphores)"
	why := render.backend_error()
	if why == "" do why = "the GPU could not be started"
	return fmt.tprintf("Sculpt needs %s. It cannot draw here: %s.", needs, why)
}

// The Graphics block of Settings > System: what draws, and the switches its GPU offers.
graphics_controls :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.spacer(ctx, 8)
	ui.label(ctx, "Graphics")
	ui.paragraph(ctx, fmt.tprintf("Drawing with %s, the app's own renderer, on %s.", render.backend_title(), render.gpu_name(&app.renderer)))
	if render.caps(&app.renderer).async_compute == .Second_Queue {
		_ = ui.switch_row(ctx, "Async compute", &app.async_compute)
		ui.paragraph(ctx, "Render mode traces on a second GPU queue beside the frame, so panels and the first orbit after a still view stay smooth while it builds up. Off traces in the frame, for comparing the two.")
	}
	if render.caps(&app.renderer).ray_query {
		_ = ui.switch_row(ctx, "Ray tracing hardware", &app.ray_query)
		ui.paragraph(ctx, "The studio render's shadows and occlusion trace the GPU's own ray tracing structures, built by its driver, instead of the app's. Off walks the app's own, for comparing the two.")
		when GRAPHICS_METAL do ui.paragraph(ctx, "A trial on iPad and Mac, off at first: compare samples a second in Stats with it on and off. The M3, M4 and A17 Pro trace in hardware; older Apple GPUs in software.")
	}
}
