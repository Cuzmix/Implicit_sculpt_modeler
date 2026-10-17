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
	no_cull:   bool `usage:"Draw every triangle instead of skipping off-screen and back-facing chunks (for comparison)."`,
	dump_viewport: string `usage:"On exit, write the last viewport image to this path as a binary PPM (for checking renders)."`,
	no_partial: bool `usage:"Redraw the whole viewport every frame instead of only what changed (for comparison)."`,
	bench_stroke: int `usage:"Run a synthetic brush stroke over this many frames, print brush stats, then exit."`,
	no_vsync:  bool `usage:"Show each frame as soon as it is ready instead of waiting for the display's refresh, so frame times are not capped at the refresh rate."`,
	time_gpu:  bool `usage:"Measure the GPU time of the 3D viewport every frame. Waits for the GPU each frame, so frames no longer overlap."`,
	gpubench:  string `usage:"Time the GPU and CPU while orbiting and sculpting one sphere at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given), with each speed setting on and off; write the markdown tables to this path and exit."`,
	gpubench_frames: int `usage:"Measured frames per --gpubench case (default 120, at most 240)."`,
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
	history:  History,
	cache_idle: bool, // draw unselected objects from the viewport cache while they stay put
	vsync:    bool, // wanted present mode, applied at the start of the next frame
	time_gpu: bool, // wait for each frame's 3D work, to measure its GPU time
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
	opts := opts
	bench: Gpubench
	defer gpubench_destroy(&bench)
	if opts.gpubench != "" {
		gpubench_init(&bench, opts.gpubench, opts.vertices, opts.gpubench_frames)
		opts.vertices, opts.spheres = bench.sizes[0], 1
	}

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
	defer history_destroy(&app.history)
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
	app.renderer.cull = !opts.no_cull
	app.renderer.partial = !opts.no_partial
	app.vsync = !opts.no_vsync && opts.gpubench == ""
	app.time_gpu = opts.time_gpu || opts.gpubench != ""
	app.ui = ui_state_default()
	app.brush = {kind = .Draw, radius_px = 60, strength = 0.5}
	app.tool = .Brush
	app.running = true
	last_input_ns: u64 // SDL timestamp of the newest mouse event, for latency
	frame_index := 0
	// The previous frame's, kept while timing the GPU so the next frame can wait for it.
	present_fence: ^sdl.GPUFence
	defer if present_fence != nil {
		_ = sdl.WaitForGPUFences(app.renderer.device, true, &present_fence, 1)
		sdl.ReleaseGPUFence(app.renderer.device, present_fence)
	}

	for app.running {
		frame_start := time.tick_now()
		if command := app.ui.scene_command; command.kind != .None {
			app.ui.scene_command = {}
			if !scene_apply(&app, command) do return false
		}
		// Changing the present mode recreates the swapchain, so it happens before this
		// frame acquires a swapchain texture.
		if app.vsync != (app.renderer.present_mode == .VSYNC) {
			if !render.renderer_set_vsync(&app.renderer, app.vsync) do app.vsync = app.renderer.present_mode == .VSYNC
		}

		// Wait for the display, and while timing the GPU for the previous frame too,
		// before reading input: the frame then shows the newest input rather than input
		// that sat through the wait.
		wait_start := time.tick_now()
		if present_fence != nil {
			_ = sdl.WaitForGPUFences(app.renderer.device, true, &present_fence, 1)
			sdl.ReleaseGPUFence(app.renderer.device, present_fence)
			present_fence = nil
		}
		present_cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
		if present_cmd == nil {
			log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
			return false
		}
		swapchain: ^sdl.GPUTexture
		if !sdl.WaitAndAcquireGPUSwapchainTexture(present_cmd, window, &swapchain, nil, nil) {
			log.errorf("acquire swapchain failed: %s", sdl.GetError())
			_ = sdl.CancelGPUCommandBuffer(present_cmd)
			return false
		}
		waited := time.tick_since(wait_start)

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
		} else if opts.gpubench != "" {
			input = gpubench_input(&app, &bench, {f32(app.target.width), f32(app.target.height)})
			last_input_ns = sdl.GetTicksNS()
		}
		camera_apply_input(&app.camera, input)
		sculpted: Sculpt_Frame_Result
		switch app.tool {
		case .Brush:
			sculpted = sculpt_frame(&app, input)
		case .Move:
			stroke_finish(&app)
			move_tool_frame(&app, input)
		}
		draw_viewport_overlay(&app, input)
		imgui.Render()

		// The 3D viewport goes in its own command buffer, submitted ahead of the one that
		// presents, so its GPU time can be measured on its own.
		cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
		if cmd == nil {
			log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
			_ = sdl.SubmitGPUCommandBuffer(present_cmd) // holds a swapchain texture: cannot be cancelled
			return false
		}
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
			draws[i] = {mesh = &obj.mesh_gpu, model = transform_matrix(obj.transform), color = color, live = selected, chunks = obj.sculptor.chunks, damage = obj.sculptor.changed_bounds}
		}
		aspect := f32(app.target.width) / f32(app.target.height)
		drawn := render.render_viewport(&app.renderer, cmd, &app.target,
			camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect), draws, app.cache_idle)

		gpu_wait: time.Duration
		if app.time_gpu {
			// Nothing else is queued (the previous frame was waited for above), so the
			// time from submit to the fence is the GPU time of this work.
			submit_start := time.tick_now()
			fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
			if fence == nil {
				log.errorf("submit failed: %s", sdl.GetError())
				_ = sdl.SubmitGPUCommandBuffer(present_cmd)
				return false
			}
			_ = sdl.WaitForGPUFences(app.renderer.device, true, &fence, 1)
			sdl.ReleaseGPUFence(app.renderer.device, fence)
			gpu_wait = time.tick_since(submit_start)
			ring_push(&app.stats.gpu_ms, time.duration_milliseconds(gpu_wait))
		} else if !sdl.SubmitGPUCommandBuffer(cmd) {
			log.errorf("submit failed: %s", sdl.GetError())
			_ = sdl.SubmitGPUCommandBuffer(present_cmd)
			return false
		}

		draw_data := imgui.GetDrawData()
		if swapchain != nil && draw_data.DisplaySize.x > 0 && draw_data.DisplaySize.y > 0 {
			imgui_impl_sdlgpu3.PrepareDrawData(draw_data, present_cmd)
			target := sdl.GPUColorTargetInfo {
				texture     = swapchain,
				clear_color = {0.08, 0.08, 0.09, 1},
				load_op     = .CLEAR,
				store_op    = .STORE,
			}
			pass := sdl.BeginGPURenderPass(present_cmd, &target, 1, nil)
			imgui_impl_sdlgpu3.RenderDrawData(draw_data, present_cmd, pass)
			sdl.EndGPURenderPass(pass)
		}
		// Some drivers wait for the display here rather than when the swapchain texture
		// is acquired, so this counts as waiting too.
		present_start := time.tick_now()
		submitted := false
		if app.time_gpu {
			present_fence = sdl.SubmitGPUCommandBufferAndAcquireFence(present_cmd)
			submitted = present_fence != nil
		} else {
			submitted = sdl.SubmitGPUCommandBuffer(present_cmd)
		}
		if !submitted {
			log.errorf("submit failed: %s", sdl.GetError())
			return false
		}

		submitted_ns := sdl.GetTicksNS()
		waited += time.tick_since(present_start)

		frame_time := time.tick_since(frame_start)
		cpu_time := frame_time - waited - gpu_wait
		ring_push(&app.stats.frame_ms, time.duration_milliseconds(frame_time))
		ring_push(&app.stats.wait_ms, time.duration_milliseconds(waited))
		ring_push(&app.stats.cpu_ms, time.duration_milliseconds(cpu_time))
		app.stats.viewport = drawn
		app.stats.cache_redraws += int(drawn.cache_redrawn)
		app.stats.partial_frames += int(drawn.partial)
		if sculpted.dabs > 0 {
			ring_push(&app.stats.raycast_ms, sculpted.raycast_ms)
			ring_push(&app.stats.brush_ms, sculpted.brush_ms)
			ring_push(&app.stats.normals_ms, normals_ms)
			ring_push(&app.stats.upload_kb, f64(uploaded * render.VERTEX_BYTES) / 1024)
			ring_push(&app.stats.latency_ms, f64(submitted_ns - last_input_ns) / 1e6)
			app.stats.dabs_total += sculpted.dabs
		}
		free_all(context.temp_allocator)

		frame_index += 1
		if (opts.frames > 0 && frame_index >= opts.frames) || (opts.bench_stroke > 0 && frame_index >= opts.bench_stroke) {
			app.running = false
		}
		if opts.gpubench != "" && gpubench_end_frame(&app, &bench, time.duration_milliseconds(gpu_wait), time.duration_milliseconds(cpu_time), sculpted.dabs) {
			app.running = false
			if !gpubench_write(&app, &bench) do return false
		}
	}
	if opts.gpubench != "" && !bench.done {
		log.warn("gpubench: stopped before every case ran; nothing written")
		return false
	}

	if opts.dump_viewport != "" {
		pixels := render.viewport_download(&app.renderer, &app.target, context.temp_allocator)
		if pixels == nil || !write_ppm(opts.dump_viewport, pixels, int(app.target.width), int(app.target.height)) {
			log.errorf("could not write %s", opts.dump_viewport)
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
	v := app.stats.viewport
	fmt.printfln("cull=%v last_frame_draws=%d chunks=%d culled_view=%d culled_back=%d cull_ms=%.3f", app.renderer.cull, v.draws, v.chunks, v.culled_view, v.culled_back, v.cull_ms)
	fmt.printfln("partial=%v partial_frames=%d last_frame_partial=%v last_frame_redrawn_px=%d viewport_px=%d", app.renderer.partial, app.stats.partial_frames, v.partial, v.redrawn_px, app.target.width * app.target.height)
	print_stat("frame_ms", app.stats.frame_ms)
	print_stat("cpu_ms", app.stats.cpu_ms)
	print_stat("wait_ms", app.stats.wait_ms)
	if app.time_gpu do print_stat("gpu_ms", app.stats.gpu_ms)
	if app.stats.dabs_total > 0 {
		print_stat("raycast_ms", app.stats.raycast_ms)
		print_stat("brush_ms", app.stats.brush_ms)
		print_stat("normals_ms", app.stats.normals_ms)
		print_stat("upload_kb", app.stats.upload_kb)
		print_stat("latency_ms", app.stats.latency_ms)
	}
	if opts.bench_stroke > 0 {
		// The synthetic stroke never lifts the button: end it, then time undo and redo
		// of the whole stroke, each including the normal update that follows.
		stroke_finish(&app)
		undo_bytes := 0
		for obj in app.scene.objects do undo_bytes += sculpt.sculptor_undo_bytes(&obj.sculptor)
		t0 := time.tick_now()
		history_undo(&app)
		for obj in app.scene.objects do _ = sculpt.sculptor_flush(&obj.sculptor)
		t1 := time.tick_now()
		history_redo(&app)
		for obj in app.scene.objects do _ = sculpt.sculptor_flush(&obj.sculptor)
		fmt.printfln("undo_mb=%.2f undo_ms=%.3f redo_ms=%.3f", f64(undo_bytes) / (1 << 20),
			time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_since(t1)))
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

// Writes RGBA8 pixels as a binary PPM (alpha dropped).
write_ppm :: proc(path: string, rgba: []u8, width, height: int) -> bool {
	out := make([dynamic]u8, 0, width * height * 3 + 32, context.temp_allocator)
	append(&out, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", width, height))
	for i := 0; i < len(rgba); i += 4 do append(&out, rgba[i], rgba[i + 1], rgba[i + 2])
	return os.write_entire_file(path, out[:]) == nil
}
