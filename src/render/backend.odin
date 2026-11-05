package render

import "../gpu"

// The backend's procs the app calls, named here so the app reaches the GPU only through
// render (AGENTS.md section 5); the backends themselves live in package gpu.

backend_error :: gpu.backend_error
backend_name :: gpu.backend_name
backend_select :: gpu.backend_select
backend_title :: gpu.backend_title
validation_errors :: gpu.validation_errors
window_flags :: gpu.window_flags
gpu_counters :: gpu.counters
Gpu_Counters :: gpu.Counters

// The web version's start: the canvas's device comes asynchronously (wgpu_device.odin).
when gpu.WEBGPU {
	wgpu_start :: gpu.wgpu_start
	wgpu_canvas_resize :: gpu.wgpu_canvas_resize
}
