package main

import "core:log"

import sdl "vendor:sdl3"

import "../render"

// Anti-aliasing: how many samples each viewport pixel takes (MSAA), which smooths the
// edges of silhouettes, creases seen side on and wireframe lines for more GPU memory and
// bandwidth. Shading inside a surface is one sample a pixel either way; the specular
// anti-aliasing in mesh.frag looks after that.
Msaa :: enum u8 {
	Off,
	X2,
	X4,
}

// In the order of Msaa, for the Settings panel.
MSAA_NAMES := [len(Msaa)]string{"Off", "2x", "4x"}

// 4x where the GPU has bandwidth to spare. Android's tiled GPUs pay for keeping the
// samples between frames (partial redraw and the idle cache load them again), so 2x there.
MSAA_DEFAULT :: Msaa.X2 when ODIN_PLATFORM_SUBTARGET == .Android else Msaa.X4

msaa_samples :: proc(m: Msaa) -> sdl.GPUSampleCount {
	switch m {
	case .Off: return ._1
	case .X2:  return ._2
	case .X4:  return ._4
	}
	return ._1
}

msaa_of :: proc(samples: sdl.GPUSampleCount) -> Msaa {
	#partial switch samples {
	case ._2: return .X2
	case ._4, ._8: return .X4
	}
	return .Off
}

// Applies the setting before the frame sizes the viewport, which then remakes its target
// at the new count. Where the device gives another count, the setting says what it gave.
msaa_apply :: proc(app: ^App) {
	want := msaa_samples(app.msaa)
	if want == app.renderer.samples do return
	app.msaa = msaa_of(render.renderer_set_msaa(&app.renderer, want))
}

// Sizes the viewport target to `w` by `h` at the renderer's sample count. When the
// device has no memory for the samples it goes on without them rather than stopping
// the app; false only when even that fails.
msaa_viewport_resize :: proc(app: ^App, w, h: u32) -> bool {
	if render.viewport_target_resize(&app.renderer, &app.target, w, h, app.renderer.samples) do return true
	if app.renderer.samples == ._1 do return false
	log.warnf("anti-aliasing turned off: no room for a %d x %d viewport at %v", w, h, app.msaa)
	app.msaa = msaa_of(render.renderer_set_msaa(&app.renderer, ._1))
	return render.viewport_target_resize(&app.renderer, &app.target, w, h, app.renderer.samples)
}
