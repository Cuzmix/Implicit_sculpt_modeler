package main

import "core:flags"
import "core:fmt"
import "core:log"
@(require) import "core:mem" // only used when ODIN_DEBUG
import "core:os"
import "core:time"
import sdl "vendor:sdl3"

import imgui "deps:odin-imgui"
import "deps:odin-imgui/imgui_impl_sdl3"
import "deps:odin-imgui/imgui_impl_sdlgpu3"

import "../camera"
import "../geom"
import "../jobs"
import "../render"
import "../sculpt"

Options :: struct {
	frames:    int `usage:"Exit after this many frames (0 runs until the window closes)."`,
	gpu_debug: bool `usage:"Create the GPU device in debug mode (enables validation where available)."`,
	subdiv:    int `usage:"Icosphere subdivision level (default 6)."`,
	vertices:  int `usage:"Start with a geodesic sphere of about this many vertices instead (e.g. 10000000)."`,
	threads:   int `usage:"Worker threads for sculpting, including the main thread (default: one per core)."`,
	width:     int `usage:"Initial window width (default 1600)."`,
	height:    int `usage:"Initial window height (default 900)."`,
	spheres:   int `usage:"Start with this many spheres side by side, all of the starting size (default 1)."`,
	no_cache:  bool `usage:"Draw every object every frame instead of caching the idle ones (for comparison)."`,
	bench_stroke: int `usage:"Run a synthetic brush stroke over this many frames, print brush stats, then exit."`,
}

// Everything the app owns. ImGui only ever sees copies or pointers handed to it per frame.
App :: struct {
	renderer: render.Renderer,
	pool:     jobs.Pool,
	target:   render.Viewport_Target,
	scene:    Scene,
	tool:     Tool,
	move:     Move_Tool,
	brush:    Brush_Settings,
	stroke:   Stroke,
	camera:   camera.Orbit,
	ui:       Ui_State,
	stats:    Frame_Stats,
	cache_idle: bool, // draw unselected objects from the viewport cache while they stay put
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

	opts := Options{subdiv = 6, width = 1600, height = 900, spheres = 1}
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

	jobs.pool_init(&app.pool, opts.threads - 1 if opts.threads > 0 else 0)
	defer jobs.pool_destroy(&app.pool)
	log.infof("sculpt threads: %d", jobs.pool_size(&app.pool))
	app.scene.selected = -1
	defer scene_destroy(&app)
	for _ in 0 ..< max(opts.spheres, 1) {
		if !scene_add_sphere(&app, opts.vertices, opts.subdiv, {position = next_free_position(&app), scale = 1}) do return false
	}
	app.scene.selected = 0
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
	if len(app.scene.objects) > 1 do frame_all(&app)
	app.cache_idle = !opts.no_cache
	app.ui = ui_state_default()
	app.brush = {kind = .Draw, radius_px = 60, strength = 0.5}
	app.tool = .Brush
	app.running = true
	last_input_ns: u64 // SDL timestamp of the newest mouse event, for latency
	frame_index := 0

	for app.running {
		frame_start := time.tick_now()
		if command := app.ui.scene_command; command.kind != .None {
			app.ui.scene_command = {}
			if !scene_apply(&app, command) do return false
		}

		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)
			#partial switch e.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				app.running = false
			case .MOUSE_MOTION, .MOUSE_BUTTON_DOWN:
				last_input_ns = e.common.timestamp
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
		if opts.bench_stroke > 0 {
			input = bench_input(&app, frame_index, opts.bench_stroke, {f32(app.target.width), f32(app.target.height)})
			last_input_ns = sdl.GetTicksNS()
		}
		camera_apply_input(&app.camera, input)
		sculpted: Sculpt_Frame_Result
		switch app.tool {
		case .Brush:
			sculpted = sculpt_frame(&app, input)
		case .Move:
			app.stroke.active = false
			move_tool_frame(&app, input)
		}
		draw_viewport_overlay(&app, input)
		imgui.Render()

		cpu_done := time.tick_now()
		cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
		uploaded: u32
		normals_ms: f64
		draws := make([]render.Draw_Item, len(app.scene.objects), context.temp_allocator)
		for obj, i in app.scene.objects {
			t_flush := time.tick_now()
			ranges := sculpt.sculptor_flush(&obj.sculptor)
			normals_ms += time.duration_milliseconds(time.tick_since(t_flush))
			render.mesh_buffers_upload_ranges(&app.renderer, cmd, &obj.mesh_gpu, obj.mesh, ranges)
			for r in ranges do uploaded += r.count
			// The selected object is in clay; the others are a muted grey. Only the
			// selected one is sculpted or moved, so the rest can come from the cache.
			selected := i == app.scene.selected
			color := [4]f32{0.55, 0.40, 0.32, 1} if selected else {0.42, 0.42, 0.44, 1}
			draws[i] = {mesh = &obj.mesh_gpu, model = transform_matrix(obj.transform), color = color, live = selected}
		}
		aspect := f32(app.target.width) / f32(app.target.height)
		drawn := render.render_viewport(&app.renderer, cmd, &app.target,
			camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect), draws, app.cache_idle)

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

		submitted_ns := sdl.GetTicksNS()

		ring_push(&app.stats.frame_ms, time.duration_milliseconds(time.tick_since(frame_start)))
		ring_push(&app.stats.cpu_ms, time.duration_milliseconds(time.tick_diff(frame_start, cpu_done)))
		app.stats.viewport = drawn
		app.stats.cache_redraws += int(drawn.cache_redrawn)
		if sculpted.dabs > 0 {
			ring_push(&app.stats.raycast_ms, sculpted.raycast_ms)
			ring_push(&app.stats.brush_ms, sculpted.brush_ms)
			ring_push(&app.stats.normals_ms, normals_ms)
			ring_push(&app.stats.upload_kb, f64(2 * uploaded * size_of(geom.Vec3)) / 1024)
			ring_push(&app.stats.latency_ms, f64(submitted_ns - last_input_ns) / 1e6)
			app.stats.dabs_total += sculpted.dabs
		}
		free_all(context.temp_allocator)

		frame_index += 1
		if (opts.frames > 0 && frame_index >= opts.frames) || (opts.bench_stroke > 0 && frame_index >= opts.bench_stroke) {
			app.running = false
		}
	}

	print_stat :: proc(name: string, r: Sample_Ring) {
		p50, p99 := ring_percentiles(r)
		fmt.printfln("%s_p50=%.3f %s_p99=%.3f", name, p50, name, p99)
	}
	vertices: int
	for obj in app.scene.objects do vertices += geom.mesh_vertex_count(obj.mesh)
	fmt.printfln("frames=%d dabs=%d objects=%d vertices=%d", frame_index, app.stats.dabs_total, len(app.scene.objects), vertices)
	fmt.printfln("idle_cache=%v cache_redraws=%d last_frame_triangles=%d", app.cache_idle, app.stats.cache_redraws, app.stats.viewport.triangles)
	print_stat("frame_ms", app.stats.frame_ms)
	if app.stats.dabs_total > 0 {
		print_stat("raycast_ms", app.stats.raycast_ms)
		print_stat("brush_ms", app.stats.brush_ms)
		print_stat("normals_ms", app.stats.normals_ms)
		print_stat("upload_kb", app.stats.upload_kb)
		print_stat("latency_ms", app.stats.latency_ms)
	}
	return true
}

camera_apply_input :: proc(c: ^camera.Orbit, in_: Viewport_Input) {
	if !in_.hovered && !in_.dragging do return
	if in_.primary do return
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
