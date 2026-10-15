package main

import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:time"
import sdl "vendor:sdl3"

import imgui "deps:odin-imgui"
import "deps:odin-imgui/imgui_impl_sdl3"
import "deps:odin-imgui/imgui_impl_sdlgpu3"

import "../camera"
import "../geom"
import "../render"

Options :: struct {
	frames:    int `usage:"Exit after this many frames (0 runs until the window closes)."`,
	gpu_debug: bool `usage:"Create the GPU device in debug mode (enables validation where available)."`,
	subdiv:    int `usage:"Icosphere subdivision level (default 6)."`,
	width:     int `usage:"Initial window width (default 1600)."`,
	height:    int `usage:"Initial window height (default 900)."`,
}

// Everything the app owns. ImGui only ever sees copies or pointers handed to it per frame.
App :: struct {
	renderer: render.Renderer,
	target:   render.Viewport_Target,
	mesh:     geom.Mesh,
	mesh_gpu: render.Mesh_Buffers,
	camera:   camera.Orbit,
	ui:       Ui_State,
	stats:    Frame_Stats,
	running:  bool,
}

main :: proc() {
	context.logger = log.create_console_logger(.Info when !ODIN_DEBUG else .Debug)
	defer log.destroy_console_logger(context.logger)

	when ODIN_DEBUG {
		tracking: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking, context.allocator)
		context.allocator = mem.tracking_allocator(&tracking)
	}

	opts := Options{subdiv = 6, width = 1600, height = 900}
	flags.parse_or_exit(&opts, os.args, .Unix)
	ok := run(opts)

	when ODIN_DEBUG {
		leaks := len(tracking.allocation_map)
		for _, entry in tracking.allocation_map {
			log.errorf("leak: %v bytes at %v", entry.size, entry.location)
		}
		for entry in tracking.bad_free_array {
			log.errorf("bad free at %v", entry.location)
		}
		if leaks == 0 && len(tracking.bad_free_array) == 0 {
			log.info("allocation tracking: no leaks")
		}
		ok = ok && leaks == 0 && len(tracking.bad_free_array) == 0
		mem.tracking_allocator_destroy(&tracking)
	}
	if !ok do os.exit(1)
}

run :: proc(opts: Options) -> bool {
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("Sculpt", i32(opts.width), i32(opts.height), {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		log.errorf("CreateWindow failed: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyWindow(window)

	app: App
	if !render.renderer_init(&app.renderer, window, opts.gpu_debug) do return false
	defer render.renderer_destroy(&app.renderer)

	build_start := time.tick_now()
	app.mesh = geom.icosphere(opts.subdiv)
	defer geom.mesh_destroy(&app.mesh)
	log.infof("icosphere level %d: %d vertices, %d triangles in %.2f ms",
		opts.subdiv, geom.mesh_vertex_count(app.mesh), geom.mesh_triangle_count(app.mesh),
		time.duration_milliseconds(time.tick_since(build_start)))
	free_all(context.temp_allocator)

	mesh_gpu, mesh_ok := render.mesh_buffers_create(&app.renderer, app.mesh)
	if !mesh_ok do return false
	app.mesh_gpu = mesh_gpu
	defer render.mesh_buffers_destroy(&app.renderer, &app.mesh_gpu)
	defer render.viewport_target_destroy(&app.renderer, &app.target)

	// Dear ImGui. Its context and backends are torn down before the renderer (defers run LIFO).
	imgui.CHECKVERSION()
	imgui.CreateContext()
	defer imgui.DestroyContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}
	io.IniFilename = nil // layout is rebuilt in code each run until there is a settings story
	imgui.StyleColorsDark()
	imgui_impl_sdl3.InitForSDLGPU(window)
	defer imgui_impl_sdl3.Shutdown()
	init_info := imgui_impl_sdlgpu3.InitInfo {
		Device            = app.renderer.device,
		ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(app.renderer.device, window),
		MSAASamples       = ._1,
	}
	if !imgui_impl_sdlgpu3.Init(&init_info) {
		log.error("ImGui SDL_GPU backend init failed")
		return false
	}
	defer imgui_impl_sdlgpu3.Shutdown()

	app.camera = camera.orbit_default()
	app.ui = ui_state_default()
	app.running = true
	upload_all := true
	frame_index := 0

	for app.running {
		frame_start := time.tick_now()

		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)
			#partial switch e.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				app.running = false
			}
		}

		// Resize to the size the viewport panel asked for last frame, before the UI
		// references the texture, so ImGui never draws a texture released this frame.
		want := app.ui.viewport_request
		if !render.viewport_target_resize(&app.renderer, &app.target, u32(want.x), u32(want.y)) do return false

		imgui_impl_sdlgpu3.NewFrame()
		imgui_impl_sdl3.NewFrame()
		imgui.NewFrame()
		input := ui_draw(&app)
		imgui.Render()

		camera_apply_input(&app.camera, input)

		cpu_done := time.tick_now()
		cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
		if upload_all {
			render.mesh_buffers_upload_vertices(&app.renderer, cmd, &app.mesh_gpu, app.mesh, 0, u32(len(app.mesh.positions)))
			upload_all = false
		}
		aspect := f32(app.target.width) / f32(app.target.height)
		render.render_viewport(&app.renderer, cmd, app.target, app.mesh_gpu,
			camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect))

		swapchain: ^sdl.GPUTexture
		if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain, nil, nil) {
			log.errorf("acquire swapchain failed: %s", sdl.GetError())
			_ = sdl.CancelGPUCommandBuffer(cmd)
			return false
		}
		draw_data := imgui.GetDrawData()
		if swapchain != nil && draw_data.DisplaySize.x > 0 && draw_data.DisplaySize.y > 0 {
			imgui_impl_sdlgpu3.PrepareDrawData(draw_data, cmd)
			target := sdl.GPUColorTargetInfo {
				texture     = swapchain,
				clear_color = {0.08, 0.08, 0.09, 1},
				load_op     = .CLEAR,
				store_op    = .STORE,
			}
			pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
			imgui_impl_sdlgpu3.RenderDrawData(draw_data, cmd, pass)
			sdl.EndGPURenderPass(pass)
		}
		if !sdl.SubmitGPUCommandBuffer(cmd) {
			log.errorf("submit failed: %s", sdl.GetError())
			return false
		}

		frame_stats_push(&app.stats,
			time.duration_milliseconds(time.tick_since(frame_start)),
			time.duration_milliseconds(time.tick_diff(frame_start, cpu_done)))
		free_all(context.temp_allocator)

		frame_index += 1
		if opts.frames > 0 && frame_index >= opts.frames {
			app.running = false
		}
	}

	p50, p99 := frame_stats_percentiles(&app.stats)
	fmt.printfln("frames=%d frame_ms_p50=%.3f frame_ms_p99=%.3f", frame_index, p50, p99)
	return true
}

camera_apply_input :: proc(c: ^camera.Orbit, in_: Viewport_Input) {
	if !in_.hovered && !in_.dragging do return
	switch {
	case in_.orbit_drag:
		camera.orbit_rotate(c, in_.mouse_delta)
	case in_.pan_drag:
		camera.orbit_pan(c, in_.mouse_delta, in_.size.y)
	}
	if in_.hovered && in_.wheel != 0 {
		camera.orbit_zoom(c, in_.wheel)
	}
}
