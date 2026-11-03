#+build js
package main

// The web version (README "Web"): the whole app in a browser tab, drawn with WebGPU by
// render's WebGPU backend (src/render/wgpu_*.odin). The page (web/index.html) answers
// SDL's procs with its own stand-in (web/sdl_web.js), which turns the canvas's DOM events
// into SDL events, so the app's windows, input and panels run as they do on the desktop.
//
// A browser never lets a page block, and the app's run is one long call from its set-up
// through its frame loop to its clean-up. So the start is split in two: main only asks the
// browser for a WebGPU device, which comes back later, and the page then calls step once
// a frame. The first step after the device is ready runs app_main, which sets everything
// up as on the desktop and, at the frame loop, keeps the app and the loop here (web_hold)
// and leaves app_main by an exception the page catches. The exception unwinds the wasm
// call stack without giving back the stack memory those calls hold in wasm's linear
// memory, so run's locals (the App among them) stay where they are, and each later step
// calls frame_step on them. The clean-up after the loop never runs: a closed tab takes
// the page's memory with it.

import "base:runtime"

import "../render"

// The canvas the app draws into (web/index.html).
WEB_CANVAS :: "#viewport"

@(private = "file")
Web_Gpu :: enum u8 {
	Starting,
	Ready,
	Failed,
}

@(private = "file")
Web_State :: struct {
	ctx:      runtime.Context,
	gpu:      Web_Gpu,
	launched: bool,
	app:      ^App,
	loop:     ^Frame_Loop,
}

@(private = "file")
web: Web_State

// The page's own procs (web/sdl_web.js answers the "sculpt_page" imports).
foreign import web_page "sculpt_page"

@(default_calling_convention = "contextless")
foreign web_page {
	// Throws the exception that leaves app_main at the frame loop; the page's step loop
	// catches it and nothing else.
	sculpt_page_unwind :: proc() ---
	// The canvas's size in device pixels, as the page last laid it out.
	sculpt_page_canvas_size :: proc(width, height: ^u32) ---
	// Tells the page the run ended (the app quit or failed), so it stops calling step.
	sculpt_page_ended :: proc(code: i32) ---
	// The run's flags from the page's address (?frames=120&vertices=1000000 gives
	// --frames=120 and --vertices=1000000), each ending in a zero byte, written into `buf`
	// while they fit; the bytes they take.
	sculpt_page_args :: proc(buf: []u8) -> i64 ---
}

// The program's arguments for the flags: its name, then the page's (sculpt_page_args).
// Kept for the whole run, as the flags' strings point into them.
web_args :: proc() -> []string {
	heap := runtime.heap_allocator()
	args := make([dynamic]string, 0, 8, heap)
	append(&args, "sculpt")
	buf := make([]u8, sculpt_page_args(nil), heap)
	_ = sculpt_page_args(buf)
	start := 0
	for b, i in buf do if b == 0 {
		append(&args, string(buf[start:i]))
		start = i + 1
	}
	return args[:]
}

// Memory the page fills for SDL's procs that hand back strings, lists and files
// (web/sdl_web.js), freed by SDL_free.
@(export)
sculpt_web_alloc :: proc "c" (size: i64) -> rawptr {
	context = web.ctx
	bytes, _ := runtime.mem_alloc(int(size), 16, runtime.heap_allocator())
	return raw_data(bytes)
}

@(export)
sculpt_web_free :: proc "c" (p: rawptr) {
	context = web.ctx
	_ = runtime.mem_free(p, runtime.heap_allocator())
}

// The web version's main: starts WebGPU, whose device comes back to web_gpu_ready.
web_main :: proc() {
	web.ctx = context
	width, height: u32
	sculpt_page_canvas_size(&width, &height)
	render.wgpu_start(WEB_CANVAS, width, height, web_gpu_ready)
}

@(private = "file")
web_gpu_ready :: proc(ok: bool) {
	web.gpu = .Ready if ok else .Failed
}

// One frame, from the page's requestAnimationFrame loop; false once the run has ended.
@(export)
step :: proc "c" (dt: f64) -> bool {
	context = web.ctx
	if web.gpu == .Starting do return true
	if !web.launched {
		// A device that failed still starts the app, whose renderer then says why it cannot
		// run (render.backend_error) as on the desktop.
		web.launched = true
		app_main()
		// app_main returns only when the run ended before its frame loop.
		sculpt_page_ended(1)
		return false
	}
	width, height: u32
	sculpt_page_canvas_size(&width, &height)
	render.wgpu_canvas_resize(width, height)
	if !web.app.running {
		sculpt_page_ended(0)
		return false
	}
	if !frame_step(web.app, web.loop) {
		sculpt_page_ended(1)
		return false
	}
	return true
}

// Called by run at its frame loop: keeps the app and the loop for step, with the context
// app_main set up (its logger and allocator), and leaves (see the note at the top).
web_hold :: proc(app: ^App, loop: ^Frame_Loop) {
	web.app, web.loop = app, loop
	web.ctx = context
	sculpt_page_unwind()
}
