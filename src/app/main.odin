package main

import "core:flags"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
@(require) import "core:mem" // only used when ODIN_DEBUG
import "core:os"
import "core:slice"
import "core:strings"
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
	subdivide: int `usage:"Give each starting sphere this many subdivision levels above it, as Ctrl+D does (e.g. --vertices=40000 --subdivide=4 tops out at 10M)."`,
	level:     int `usage:"Start on this subdivision level, 1 being the base (default: the top one)."`,
	hd:        int `usage:"Give each starting sphere an HD level this many Loop steps (1 to 3) above its top level, as Divide HD does."`,
	hd_open:   bool `usage:"Start sculpting HD on the first sphere, in a window around the side facing the camera (needs --hd)."`,
	hd_window: int `usage:"Vertices an HD window holds (default 4000000)."`,
	no_cache:  bool `usage:"Draw every object every frame instead of caching the idle ones (for comparison)."`,
	no_cull:   bool `usage:"Draw every triangle instead of skipping off-screen and back-facing chunks (for comparison)."`,
	dump_viewport: string `usage:"On exit, write the last viewport image to this path as a binary PPM (for checking renders)."`,
	check_mesh: bool `usage:"On exit, check every object's current mesh (closed, consistently wound, no degenerate triangles or NaN) and print the counts as mesh_* lines (slow on large meshes)."`,
	no_partial: bool `usage:"Redraw the whole viewport every frame instead of only what changed (for comparison)."`,
	no_simplify: bool `usage:"Draw every chunk at full detail while the view moves too, instead of simplified copies of the far ones (for comparison)."`,
	orbit:     bool `usage:"Turn the camera around the scene by itself, once every 240 frames (to watch or time drawing while the view moves)."`,
	bench_stroke: int `usage:"Run a synthetic brush stroke over this many frames, print brush stats, then exit."`,
	bench_samples: int `usage:"Give each --bench-stroke frame this many pointer samples along the path, like a high-rate mouse (default: one position a frame)."`,
	bench_loops: int `usage:"Make --bench-stroke this many circles around the middle of the sphere instead of a wavy line."`,
	brush:     string `usage:"Start with this brush: draw, smooth, clay, flatten, inflate, pinch, crease, grab or mask (also what --bench-stroke uses)."`,
	symmetry:  string `usage:"Start with brush symmetry across these axes, e.g. x or xz."`,
	remesh:    int `usage:"Voxel remesh the first sphere to about this many vertices before starting, as Remesh selected does (after --subdivide and --level)."`,
	dyntopo:   bool `usage:"Turn dynamic topology on for the first sphere before starting (after --remesh), as Ctrl+T does."`,
	detail:    f32 `usage:"Dynamic topology detail: edges longer than this many pixels on screen split (default 10)."`,
	tilt_strength: f32 `usage:"How far a leaning pen turns the brush, 0 to 1 (default 0: not at all), as the Tools panel's Tilt slider sets."`,
	bench_tilt: f32 `usage:"Lean the synthetic pen of --bench-stroke this many degrees to the right (with --tilt-strength)."`,
	no_vsync:  bool `usage:"Show each frame as soon as it is ready instead of waiting for the display's refresh, so frame times are not capped at the refresh rate."`,
	time_gpu:  bool `usage:"Measure the GPU time of the 3D viewport every frame. Waits for the GPU each frame, so frames no longer overlap."`,
	gpubench:  string `usage:"Time the GPU and CPU while orbiting and sculpting one sphere at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given), with each speed setting on and off; write the markdown tables to this path and exit."`,
	gpubench_frames: int `usage:"Measured frames per --gpubench case (default 120, at most 240)."`,
	open:      string `usage:"Start with the scene saved in this .sculpt file instead of spheres, as File > Open scene does."`,
	import_mesh: string `args:"name=import" usage:"Start with the mesh in this .obj or .ply file instead of spheres (after any --open), as File > Import mesh does."`,
	export:    string `usage:"On exit, write the selected object's shown level to this .obj or .ply file, as File > Export selected does."`,
	save:      string `usage:"On exit, save the scene to this .sculpt file, as File > Save scene does."`,
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
	samples:  [dynamic]Input_Sample, // this frame's pointer samples, in window coordinates
	pen_pressure: f32, // the pen's latest pressure
	pen_tilt: [2]f32, // the pen's latest lean in degrees, x to the right and y down
	pen_seen: bool,
	camera:   camera.Orbit,
	ui:       Ui_State,
	stats:    Frame_Stats,
	history:  History,
	cache_idle: bool, // draw unselected objects from the viewport cache while they stay put
	hd_window_vertices: int, // size of the HD windows the A key opens
	// While the view moves, draw far groups of chunks from simplified copies that stray
	// at most simplify_px pixels; full detail once it has stayed put for LOD_SETTLE.
	simplify:    bool,
	simplify_px: f32,
	lod_finish:  bool, // build every pending copy each frame, not a batch (gpubench)
	view_key:    u64,       // camera, viewport size and object transforms last frame
	view_moved:  time.Tick, // when view_key last changed
	vsync:    bool, // wanted present mode, applied at the start of the next frame
	time_gpu: bool, // wait for each frame's 3D work, to measure its GPU time
	window:   ^sdl.Window, // what file dialogs belong to
	scene_path: string, // where the scene was last saved or opened from, for Ctrl+S (owned)
	file_note:  File_Note,
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
	app.window = window
	defer delete(app.scene_path)
	defer file_shutdown(&app)
	if !render.renderer_init(&app.renderer, window, opts.gpu_debug) do return false
	defer render.renderer_destroy(&app.renderer)

	jobs.pool_init(&app.pool, opts.threads - 1 if opts.threads > 0 else 0)
	defer jobs.pool_destroy(&app.pool)
	log.infof("sculpt threads: %d", jobs.pool_size(&app.pool))
	app.scene.selected = -1
	defer scene_destroy(&app)
	defer history_destroy(&app.history)
	defer delete(app.samples)
	defer delete(app.stroke.pending)
	app.hd_window_vertices = opts.hd_window if opts.hd_window > 0 else sculpt.HD_WINDOW_VERTICES
	if opts.open != "" {
		opened, ok := scene_open(&app, opts.open)
		if !ok || !opened do return false
		scene_remember_path(&app, opts.open)
	}
	if opts.import_mesh != "" {
		before := len(app.scene.objects)
		if !scene_import(&app, opts.import_mesh) || len(app.scene.objects) == before do return false
	}
	// Spheres unless a file gave the scene; then the steps below apply to its objects.
	starting := 0 if opts.open != "" || opts.import_mesh != "" else max(opts.spheres, 1)
	for _ in 0 ..< starting {
		if !scene_add_sphere(&app, opts.vertices, opts.subdiv, {position = next_free_position(&app), scale = 1}) do return false
	}
	for obj in app.scene.objects {
		defer if opts.hd > 0 && !sculpt.levels_hd_set_steps(&obj.levels, opts.hd) do log.warn("HD: the top level is not a closed manifold mesh")
		if opts.subdivide <= 0 && opts.level <= 0 do continue
		start := time.tick_now()
		for _ in 0 ..< opts.subdivide {
			if !sculpt.levels_subdivide(&obj.levels) do break
			free_all(context.temp_allocator)
		}
		log.infof("levels: %d, top level %d vertices, built in %.0f ms", len(obj.levels.levels),
			geom.mesh_vertex_count(object_mesh(obj)^), time.duration_milliseconds(time.tick_since(start)))
		if opts.level > 0 do sculpt.levels_set_current(&obj.levels, opts.level - 1)
		if !object_show_level(&app, obj, start) do return false
	}
	if len(app.scene.objects) == 0 {
		log.error("the scene has no objects to start with")
		return false
	}
	// The first sphere; otherwise what the file selected, or the import.
	if starting > 0 do app.scene.selected = 0
	if opts.remesh > 0 && !object_remesh(&app, app.scene.objects[0], opts.remesh) do return false
	if opts.dyntopo {
		obj := app.scene.objects[0]
		if !object_set_dyntopo(&app, obj, true) do return false
		if !object_dynamic(obj) do return false // refused, with the reason logged
	}
	defer render.viewport_target_destroy(&app.renderer, &app.target)
	app.camera = camera.orbit_default()
	if opts.hd_open {
		obj := app.scene.objects[0]
		toward := camera.orbit_eye(app.camera) - obj.transform.position
		if !object_hd_enter(&app, obj, linalg.normalize(toward)) do return false
	}

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

	if len(app.scene.objects) > 1 do frame_all(&app)
	app.cache_idle = !opts.no_cache
	app.renderer.cull = !opts.no_cull
	app.renderer.partial = !opts.no_partial
	app.simplify = !opts.no_simplify
	app.simplify_px = 1
	app.vsync = !opts.no_vsync && opts.gpubench == ""
	app.time_gpu = opts.time_gpu || opts.gpubench != ""
	app.ui = ui_state_default()
	app.brush = {kind = .Draw, radius_px = 60, strength = 0.5, pressure_strength = true, pressure_curve = geom.CURVE_LINEAR, detail_px = 10, collapse = true}
	if opts.detail > 0 do app.brush.detail_px = opts.detail
	app.brush.tilt_strength = clamp(opts.tilt_strength, 0, 1)
	if opts.brush != "" {
		kind, found := brush_by_name(opts.brush)
		if !found {
			log.errorf("unknown brush %q", opts.brush)
			return false
		}
		app.brush.kind = kind
	}
	for c in strings.to_lower(opts.symmetry, context.temp_allocator) {
		switch c {
		case 'x': app.brush.symmetry += {.X}
		case 'y': app.brush.symmetry += {.Y}
		case 'z': app.brush.symmetry += {.Z}
		case:
			log.errorf("unknown symmetry axis %q in %q", c, opts.symmetry)
			return false
		}
	}
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
		if req, ok := file_take(&app); ok {
			applied := file_apply(&app, req)
			file_request_free(req)
			if !applied do return false
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

		// Every pointer sample, not only where the pointer ended up, so the brush can
		// follow the whole path. A pen also sends mouse events, marked PEN_MOUSEID; its
		// pressure arrives separately as an axis event.
		clear(&app.samples)
		e: sdl.Event
		for sdl.PollEvent(&e) {
			// Space over the viewport is the brush pie's (pie.odin) and never reaches
			// ImGui, whose keyboard navigation would also take it as a press of whatever
			// widget has focus. Once it went down there, its release is the pie's too.
			if (e.type == .KEY_DOWN || e.type == .KEY_UP) && e.key.scancode == .SPACE {
				pie := &app.ui.pie
				if pie.space_down || (e.key.down && app.ui.viewport_hovered && !imgui.GetIO().WantTextInput) {
					if e.key.down && !e.key.repeat do pie.space_pressed = true
					if !e.key.down do pie.space_released = true
					pie.space_down = e.key.down
					continue
				}
			}
			imgui_impl_sdl3.ProcessEvent(&e)
			#partial switch e.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				app.running = false
			case .MOUSE_MOTION:
				last_input_ns = e.common.timestamp
				pen := e.motion.which == sdl.PEN_MOUSEID
				append(&app.samples, Input_Sample{{e.motion.x, e.motion.y}, app.pen_pressure if pen else 1, .Move, app.pen_tilt if pen else {}})
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				if e.button.down do last_input_ns = e.common.timestamp
				if e.button.button == sdl.BUTTON_LEFT {
					pen := e.button.which == sdl.PEN_MOUSEID
					append(&app.samples, Input_Sample{{e.button.x, e.button.y}, app.pen_pressure if pen else 1, .Press if e.button.down else .Release, app.pen_tilt if pen else {}})
				}
			case .PEN_AXIS:
				#partial switch e.paxis.axis {
				case .PRESSURE:
					app.pen_pressure = e.paxis.value
				case .XTILT:
					app.pen_tilt.x = e.paxis.value
				case .YTILT:
					app.pen_tilt.y = e.paxis.value
				}
				app.pen_seen = true
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
			input = bench_input(&app, frame_index, opts.bench_stroke, opts.bench_samples, opts.bench_loops, {opts.bench_tilt, 0}, {f32(app.target.width), f32(app.target.height)})
			last_input_ns = sdl.GetTicksNS()
		} else if opts.gpubench != "" {
			input = gpubench_input(&app, &bench, {f32(app.target.width), f32(app.target.height)})
			last_input_ns = sdl.GetTicksNS()
		}
		camera_apply_input(&app.camera, input)
		if opts.orbit do app.camera.yaw += 2 * math.PI / 240
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
		uploaded: int // bytes
		normals_ms: f64
		lod_ms := -1.0 // time building simplified copies; none built when negative
		draws := make([dynamic]render.Draw_Item, 0, 2 * len(app.scene.objects), context.temp_allocator)
		for obj, i in app.scene.objects {
			// An object sculpting HD shows its top level around the window.
			parts := [2]^sculpt.Level{sculpt.levels_current(&obj.levels), obj.levels.hd.window}
			gpus := [2]^render.Mesh_Buffers{&obj.gpu[obj.levels.current], &obj.hd_gpu}
			for lv, part in parts {
				if lv == nil do continue
				gpu := gpus[part]
				t_flush := time.tick_now()
				ranges := sculpt.sculptor_flush(&lv.sculptor)
				normals_ms += time.duration_milliseconds(time.tick_since(t_flush))
				bytes, uploaded_ok := level_upload(&app, cmd, gpu, lv, ranges)
				if !uploaded_ok {
					_ = sdl.SubmitGPUCommandBuffer(cmd)
					_ = sdl.SubmitGPUCommandBuffer(present_cmd)
					return false
				}
				uploaded += bytes
				// Simplified copies are built a batch a frame, for one level at a time, and
				// never during a stroke, whose frames should stay as short as they can be.
				if app.simplify && !app.stroke.active && lod_ms < 0 && sculpt.sculptor_lod_pending(&lv.sculptor) > 0 {
					t_lod := time.tick_now()
					lod_ranges, all := sculpt.sculptor_lod_update(&lv.sculptor, app.lod_finish)
					render.mesh_buffers_upload_lod(&app.renderer, cmd, gpu, lv.sculptor.lod.indices[:], lod_ranges, all, len(lv.mesh.indices) / 2)
					lod_ms = time.duration_milliseconds(time.tick_since(t_lod))
				}
				// The selected object is in clay; the others are a muted grey. Only the
				// selected one is sculpted or moved, so the rest can come from the cache.
				selected := i == app.scene.selected
				color := [4]f32{0.55, 0.40, 0.32, 1} if selected else {0.42, 0.42, 0.44, 1}
				append(&draws, render.Draw_Item {
					mesh   = gpu,
					model  = transform_matrix(obj.transform),
					color  = color,
					live   = selected,
					chunks = lv.sculptor.chunks,
					damage = lv.sculptor.changed_bounds,
					lod    = lv.sculptor.lod.tree,
					hidden = sculpt.levels_hd_hidden(&obj.levels) if part == 0 else nil,
				})
			}
		}
		aspect := f32(app.target.width) / f32(app.target.height)
		view, proj := camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect)
		if view_changed(&app, view, proj) do app.view_moved = time.tick_now()
		moving := time.tick_since(app.view_moved) < LOD_SETTLE
		app.renderer.lod_px = app.simplify_px if app.simplify && moving else 0
		drawn := render.render_viewport(&app.renderer, cmd, &app.target, view, proj, draws[:], app.cache_idle)

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
		if lod_ms >= 0 do ring_push(&app.stats.lod_ms, lod_ms)
		if sculpted.dabs > 0 {
			ring_push(&app.stats.raycast_ms, sculpted.raycast_ms)
			ring_push(&app.stats.brush_ms, sculpted.brush_ms)
			ring_push(&app.stats.normals_ms, normals_ms)
			ring_push(&app.stats.upload_kb, f64(uploaded) / 1024)
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

	if opts.export != "" {
		obj := selected_object(&app)
		if obj == nil || !object_export(&app, obj, opts.export) do return false
	}
	if opts.save != "" && !scene_save(&app, opts.save) do return false

	print_stat :: proc(name: string, r: Sample_Ring) {
		p50, p99 := ring_percentiles(r)
		fmt.printfln("%s_p50=%.3f %s_p99=%.3f", name, p50, name, p99)
	}
	vertices: int
	for obj in app.scene.objects do vertices += object_vertex_count(obj)
	fmt.printfln("frames=%d dabs=%d objects=%d vertices=%d", frame_index, app.stats.dabs_total, len(app.scene.objects), vertices)
	if opts.check_mesh {
		for obj in app.scene.objects {
			if !object_dynamic(obj) {
				geom.mesh_report_print(geom.mesh_check(object_mesh(obj)^))
				continue
			}
			// Without the unused slots of the dynamic layout, which are not part of the surface.
			packed, mask := sculpt.sculptor_compact_mesh(object_sculptor(obj))
			geom.mesh_report_print(geom.mesh_check(packed))
			geom.mesh_destroy(&packed)
			delete(mask)
		}
	}
	for obj in app.scene.objects {
		if !object_dynamic(obj) do continue
		splits, collapses := sculpt.sculptor_dyn_edits(object_sculptor(obj))
		fmt.printfln("dyntopo object=%d triangles=%d splits=%d collapses=%d pages=%d gpu_regrows=%d", obj.id, object_triangle_count(obj),
			splits, collapses, sculpt.sculptor_dyn_pages(object_sculptor(obj)), app.stats.gpu_regrows)
	}
	if s := app.stats; s.file_read_ms > 0 || s.file_write_ms > 0 {
		fmt.printfln("file_read_ms=%.1f file_parse_ms=%.1f file_write_ms=%.1f", s.file_read_ms, s.file_parse_ms, s.file_write_ms)
	}
	fmt.printfln("idle_cache=%v cache_redraws=%d last_frame_triangles=%d", app.cache_idle, app.stats.cache_redraws, app.stats.viewport.triangles)
	v := app.stats.viewport
	fmt.printfln("cull=%v last_frame_draws=%d chunks=%d culled_view=%d culled_back=%d cull_ms=%.3f", app.renderer.cull, v.draws, v.chunks, v.culled_view, v.culled_back, v.cull_ms)
	fmt.printfln("partial=%v partial_frames=%d last_frame_partial=%v last_frame_redrawn_px=%d viewport_px=%d", app.renderer.partial, app.stats.partial_frames, v.partial, v.redrawn_px, app.target.width * app.target.height)
	lod_pending := 0
	for obj in app.scene.objects do lod_pending += sculpt.sculptor_lod_pending(object_sculptor(obj))
	fmt.printfln("simplify=%v last_frame_lod_px=%.2f last_frame_simplified=%d lod_pending=%d", app.simplify, app.renderer.lod_px, v.simplified, lod_pending)
	if app.stats.lod_ms.count > 0 do print_stat("lod_build_ms", app.stats.lod_ms)
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
		for obj in app.scene.objects do undo_bytes += sculpt.sculptor_undo_bytes(object_sculptor(obj))
		t0 := time.tick_now()
		history_undo(&app)
		for obj in app.scene.objects do _ = sculpt.sculptor_flush(object_sculptor(obj))
		t1 := time.tick_now()
		history_redo(&app)
		for obj in app.scene.objects do _ = sculpt.sculptor_flush(object_sculptor(obj))
		fmt.printfln("undo_mb=%.2f undo_ms=%.3f redo_ms=%.3f", f64(undo_bytes) / (1 << 20),
			time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_since(t1)))
		// With levels: step down to the base, carrying the stroke along, then jump back.
		// Each change prints the time to update the levels plus the time to show the new one.
		obj := app.scene.objects[0]
		if start := obj.levels.current; len(obj.levels.levels) > 1 {
			fmt.printf("level_changes_ms=")
			for to := start - 1; to >= -1; to -= 1 {
				from := obj.levels.current
				target := to if to >= 0 else start
				if !object_set_level(&app, obj, target) do return false
				fmt.printf("%d->%d:%.1f+%.1f ", from + 1, target + 1, app.stats.level_sync_ms, app.stats.level_show_ms)
				free_all(context.temp_allocator)
			}
			fmt.println()
		}
	}
	return true
}

// How long the view has to stay put before simplified drawing gives way to full detail.
LOD_SETTLE :: 250 * time.Millisecond

// Whether the camera, the viewport size or any object's transform changed since the
// last call.
view_changed :: proc(app: ^App, view, proj: render.Mat4) -> bool {
	Key :: struct {
		view, proj:    render.Mat4,
		width, height: u32,
	}
	key := Key{view, proj, app.target.width, app.target.height}
	h := hash.fnv64a(slice.bytes_from_ptr(&key, size_of(key)))
	for obj in app.scene.objects {
		t := obj.transform
		h = hash.fnv64a(slice.bytes_from_ptr(&t, size_of(t)), h)
	}
	changed := h != app.view_key
	app.view_key = h
	return changed
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
