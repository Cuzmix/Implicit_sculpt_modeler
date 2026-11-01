#+build js
// Package main is the web build's entry (README "Web"): the sculpt engine (geom, sculpt,
// camera) running in a browser tab, drawn with WebGPU by render/webgpu, fed by the
// browser's pointer, wheel and key events through Odin's js runtime. It is the first
// stage of the web port: one sphere to sculpt with the main brushes, the pen's pressure,
// orbit, pan and zoom, undo and redo, X symmetry. The app's interface, files and threads
// come in later stages. scripts/web_build.py builds it into build/web/site.
package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:sys/wasm/js"
import "core:time"

import "../camera"
import "../geom"
import "../jobs"
import "../render/webgpu"
import "../sculpt"

Vec2 :: [2]f32
Vec3 :: [3]f32

// The id of the page's canvas (web/index.html) and the elements the page reads back.
CANVAS_ID :: "viewport"
CANVAS_SELECTOR :: "#viewport"
STATE_ID :: "state"

DEFAULT_VERTICES :: 250_000
MAX_VERTICES :: 8_000_000
// The background, the desktop app's dark blue-grey, linear.
BACKGROUND :: [3]f32{0.030, 0.034, 0.044}
CLAY :: [4]f32{0.50, 0.33, 0.25, 1}

// The brushes the page offers, in the order of its buttons and number keys 1 to 9.
@(rodata)
BRUSHES := [?]sculpt.Brush_Kind{.Draw, .Clay, .Clay_Strips, .Smooth, .Inflate, .Pinch, .Crease, .Flatten, .Grab, .Layer}

MIN_RADIUS_PX :: 4
MAX_RADIUS_PX :: 400

Drag :: enum u8 {
	None,
	Stroke,
	Orbit,
	Pan,
	Pinch,
}

Pointer :: struct {
	id:   int,
	at:   Vec2, // CSS pixels from the canvas's top-left
	kind: js.Pointer_Type,
	used: bool,
}

Stroke :: struct {
	kind:     sculpt.Brush_Kind,
	invert:   bool,
	pointer:  int,
	// Where the last dab went, on screen and on the surface, for the spacing and for the
	// brushes that turn along the stroke.
	last_px:  Vec2,
	last_hit: Vec3,
	last_set: bool,
	pressure: f32,
	// Grab: where it picked the surface up.
	anchor:   Vec3,
	grabbing: bool,
}

State :: struct {
	ctx:        runtime.Context,
	started:    bool,
	pool:       jobs.Pool,
	mesh:       ^geom.Mesh,
	sculptor:   ^sculpt.Sculptor,
	view:       webgpu.Viewport,
	cam:        camera.Orbit,
	// The canvas in CSS pixels, and device pixels per CSS pixel.
	size:       Vec2,
	dpr:        f32,
	// The brush.
	kind:       sculpt.Brush_Kind,
	radius_px:  f32,
	strengths:  [sculpt.Brush_Kind]f32,
	symmetry_x: bool,
	// Input.
	pointers:   [10]Pointer,
	drag:       Drag,
	drag_from:  Vec2,
	pinch_span: f32,
	pinch_mid:  Vec2,
	stroke:     Stroke,
	hover:      Vec2,
	hovering:   bool,
	cursor:     Vec3,
	cursor_ok:  bool,
	// A new sphere waits for the next frame, as the desktop applies scene changes.
	new_vertices: int,
	// Timings for the page's status line, reset each time it is written.
	frames:     int,
	dabs:       int,
	dab_ms:     f64,
	frame_ms:   f64,
	upload_kb:  f64,
	last_status: time.Tick,
	shown_fps:  f64,
	shown_dab:  f64,
	ready_ms:   f64,
}

state: State

main :: proc() {
	state.ctx = context
	state.cam = camera.orbit_default()
	state.radius_px = 60
	state.kind = .Draw
	state.strengths = default_strengths()
	state.dpr = f32(js.device_pixel_ratio())
	state.size = canvas_size()
	// No workers on the web yet: jobs runs every loop on this thread (src/jobs/cores_js.odin).
	jobs.pool_init(&state.pool)
	state.new_vertices = clamp(option_int("vertices", DEFAULT_VERTICES), 1000, MAX_VERTICES)

	listen()
	w, h := device_size()
	webgpu.init(&state.view, CANVAS_SELECTOR, w, h, on_gpu_ready)
	if state.view.failed != "" do show_failure(state.view.failed)
}

// The brushes' strengths as the page starts, close to the desktop's built-in presets.
default_strengths :: proc() -> (s: [sculpt.Brush_Kind]f32) {
	for &x in s do x = 0.5
	s[.Draw] = 0.35
	s[.Clay] = 0.45
	s[.Clay_Strips] = 0.6
	s[.Smooth] = 0.5
	s[.Inflate] = 0.3
	s[.Pinch] = 0.45
	s[.Crease] = 0.45
	s[.Flatten] = 0.5
	s[.Grab] = 1
	s[.Layer] = 0.5
	return
}

on_gpu_ready :: proc() {
	state.started = true
}

// One frame, from the page's requestAnimationFrame loop: a new sphere if one was asked
// for, the surface's changes uploaded, then the drawing.
@(export)
step :: proc "c" (dt: f64) -> bool {
	context = state.ctx
	defer free_all(context.temp_allocator)
	if state.view.failed != "" {
		show_failure(state.view.failed)
		return false
	}
	if !state.started do return true
	t0 := time.tick_now()

	size := canvas_size()
	dpr := f32(js.device_pixel_ratio())
	if size != state.size || dpr != state.dpr {
		state.size, state.dpr = size, dpr
		w, h := device_size()
		webgpu.resize(&state.view, w, h)
	}
	if state.new_vertices > 0 {
		new_sphere(state.new_vertices)
		state.new_vertices = 0
	}
	if state.sculptor != nil {
		ranges := sculpt.sculptor_flush(state.sculptor)
		state.upload_kb += f64(webgpu.update(&state.view, state.mesh, ranges)) / 1024
	}
	webgpu.draw(&state.view, frame_uniforms(), BACKGROUND)

	state.frames += 1
	state.frame_ms += time.duration_milliseconds(time.tick_since(t0))
	status(dt)
	return true
}

frame_uniforms :: proc() -> webgpu.Frame {
	aspect := state.size.x / max(state.size.y, 1)
	view := camera.orbit_view(state.cam)
	proj := camera.orbit_proj(state.cam, aspect)
	f := webgpu.Frame {
		view_proj = proj * view,
		view      = view,
		clay      = CLAY,
	}
	// The ring under the pointer, or where the stroke is, sized as the next dab would be.
	if state.cursor_ok && (state.hovering || state.drag == .Stroke) {
		r := state.radius_px * camera.orbit_world_per_px(state.cam, state.cursor, state.size.y)
		f.cursor = {state.cursor.x, state.cursor.y, state.cursor.z, r}
	}
	return f
}

// Replaces the mesh with a geodesic sphere of about `vertices` vertices.
new_sphere :: proc(vertices: int) {
	t0 := time.tick_now()
	end_stroke()
	if state.sculptor != nil {
		sculpt.sculptor_destroy(state.sculptor)
		free(state.sculptor)
		state.sculptor = nil
	}
	if state.mesh != nil {
		geom.mesh_destroy(state.mesh)
		free(state.mesh)
	}
	state.mesh = new(geom.Mesh)
	state.mesh^ = geom.geodesic_sphere(geom.geodesic_frequency_for(vertices), &state.pool)
	state.sculptor = new(sculpt.Sculptor)
	sculpt.sculptor_init(state.sculptor, state.mesh, &state.pool)
	free_all(context.temp_allocator)
	if !webgpu.set_mesh(&state.view, state.mesh) {
		show_failure(fmt.tprintf("A mesh of %d vertices is larger than this GPU allows a buffer to be.", len(state.mesh.positions)))
	}
	state.ready_ms = time.duration_milliseconds(time.tick_since(t0))
	fmt.printfln("mesh: %d vertices, %d triangles; ready to sculpt in %.0f ms", len(state.mesh.positions), len(state.mesh.indices) / 3, state.ready_ms)
}

// The page's status line, twice a second, and the state its controls show.
status :: proc(dt: f64) {
	if time.duration_seconds(time.tick_since(state.last_status)) < 0.5 && state.last_status != {} do return
	elapsed := time.duration_seconds(time.tick_since(state.last_status)) if state.last_status != {} else 0.5
	state.last_status = time.tick_now()
	state.shown_fps = f64(state.frames) / max(elapsed, 1e-3)
	if state.dabs > 0 do state.shown_dab = state.dab_ms / f64(state.dabs)
	vertices := len(state.mesh.positions) if state.mesh != nil else 0
	undo_steps, redo_steps := 0, 0
	if state.sculptor != nil {
		undo_steps, redo_steps = len(state.sculptor.history.done), len(state.sculptor.history.undone)
	}
	text := fmt.tprintf("brush=%v radius=%.0f strength=%.2f symmetry=%d vertices=%d fps=%.0f frame_ms=%.2f dab_ms=%.2f upload_kb=%.0f undo=%d redo=%d ready_ms=%.0f yaw=%.2f pitch=%.2f",
		state.kind, state.radius_px, state.strengths[state.kind], int(state.symmetry_x), vertices, state.shown_fps,
		state.frame_ms / f64(max(state.frames, 1)), state.shown_dab, state.upload_kb, undo_steps, redo_steps, state.ready_ms, state.cam.yaw, state.cam.pitch)
	js.set_element_key_string(STATE_ID, "textContent", text)
	state.frames, state.dabs, state.dab_ms, state.frame_ms, state.upload_kb = 0, 0, 0, 0, 0
}

show_failure :: proc(message: string) {
	js.set_element_key_string(STATE_ID, "textContent", strings.concatenate({"failed=", message}, context.temp_allocator))
}

canvas_size :: proc() -> Vec2 {
	r := js.get_bounding_client_rect(CANVAS_ID)
	return {max(f32(r.width), 1), max(f32(r.height), 1)}
}

device_size :: proc() -> (u32, u32) {
	return u32(math.round(state.size.x * state.dpr)), u32(math.round(state.size.y * state.dpr))
}

// A number from the page's options: web/index.html copies the address's query into
// hidden fields named after its keys (?vertices=1000000 into #vertices), or `fallback`.
// Read as a float, since odin.js's string reads mix up BigInt lengths for wasm64p32.
option_int :: proc(name: string, fallback: int) -> int {
	x := js.get_element_value_f64(name)
	if math.is_nan(x) || x <= 0 do return fallback
	return int(x)
}

// The ray from the eye through the point `p` CSS pixels from the canvas's top-left.
screen_ray :: proc(p: Vec2) -> (origin, dir: Vec3) {
	right, up, back := camera.orbit_basis(state.cam)
	h := state.size.y
	ndc := Vec2{2 * p.x / state.size.x - 1, 1 - 2 * p.y / h}
	tan_half := math.tan(state.cam.fov_y / 2)
	aspect := state.size.x / max(h, 1)
	if state.cam.ortho {
		half := state.cam.distance * tan_half
		origin = camera.orbit_eye(state.cam) + right * (ndc.x * half * aspect) + up * (ndc.y * half)
		return origin, -back
	}
	dir = linalg.normalize(-back + right * (ndc.x * tan_half * aspect) + up * (ndc.y * tan_half))
	return camera.orbit_eye(state.cam), dir
}

pick :: proc(p: Vec2) -> (hit: Vec3, ok: bool) {
	if state.sculptor == nil do return
	origin, dir := screen_ray(p)
	return sculpt.sculptor_raycast(state.sculptor, origin, dir)
}
