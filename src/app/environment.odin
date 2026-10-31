package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

import "../camera"
import "../render"
import "../ui"

// Image environments (stage 4.1, notes/rendering/stage4-design.md): a panorama file the
// physically based materials reflect and take their diffuse light from in place of the
// built-in studio, optionally shown behind the scene. A view setting, as a MatCap image
// is: remembered in the settings, never in the scene file. Files decode on a thread
// (environment_file.odin), one at a time, the newest request winning; the GPU copy is
// made at the start of the frame that finds the decode done.

// The panorama the GPU holds is halved until it is at most this wide: reflections and
// the background are blurred enough by then that more costs memory for nothing (a 2048
// source and its prefiltered copy take about 27 MB, the tablet's 1024 a quarter).
ENVIRONMENT_SOURCE_WIDTH :: 1024 when MOBILE else 2048
// The Strength slider's reach either way, in stops.
ENVIRONMENT_STRENGTH_RANGE :: 4
// How far Tilt leans the panorama either way, in degrees: past a right angle the sky would
// stand on its side.
ENVIRONMENT_TILT_RANGE :: 90
// The panoramas loaded last, for the section's list to swap between.
ENVIRONMENT_RECENT_MAX :: 5
// Degrees a Shift and right drag turns the panorama for each point the pointer moves:
// across a 1280-point view is a little under a full turn.
ENVIRONMENT_DRAG_TURN :: 0.25

Environment_Kind :: enum u8 {
	Built_In, // the procedural studio in the mesh shader
	Image,    // the loaded panorama, while there is one
}

@(rodata)
ENVIRONMENT_KIND_LABELS := [len(Environment_Kind)]string{"Built-in", "Image"}

Environment_State :: struct {
	kind:       Environment_Kind,
	strength:   f32, // stops
	background: bool,
	blur:       f32, // 0 to 1: which prefiltered roughness the background shows
	// The panorama stays with the scene, as the lights fixed to it do, rather than turning
	// with the camera (lights_fix).
	fixed:      bool,
	// Its own turn about the up axis and lean toward the camera, in degrees, on top of the
	// lights' Turn all: the panorama's sun lines up with the model without moving a light.
	turn:       f32,
	tilt:       f32,
	path:       string, // the file the GPU copy came from (heap), "" while there is none
	// The files loaded last, the newest first, heap strings (ENVIRONMENT_RECENT_MAX).
	recent:     [dynamic]string,
	turns:      int, // Shift and right drags that turned it, for the exit stats
	gpu:        render.Environment,
	decode:     ^Environment_Decode,
	// A file asked for while another decodes, started when that one is done (heap).
	next:       string,
	next_quiet: bool,
}

// A decode on its thread: it owns its path and leaves the panorama, its harmonics and
// why it failed, all in the heap allocator, for the frame loop to take.
Environment_Decode :: struct {
	path:   string,
	quiet:  bool,
	image:  Environment_Image,
	sh:     [9][3]f32,
	why:    string,
	done:   bool, // atomic
	thread: ^thread.Thread,
}

environment_settings_default :: proc(app: ^App) {
	app.env.kind, app.env.strength, app.env.background, app.env.blur = .Built_In, 0, false, 0.3
	app.env.turn, app.env.tilt = 0, 0
}

// Puts `path` first among the recent panoramas, once, dropping the oldest past the list's
// length.
environment_recent_add :: proc(app: ^App, path: string) {
	heap := runtime.heap_allocator()
	r := &app.env.recent
	if r.allocator.procedure == nil do r.allocator = heap
	for p, i in r do if p == path {
		delete(p, heap)
		ordered_remove(r, i)
		break
	}
	inject_at(r, 0, strings.clone(path, heap))
	for len(r) > ENVIRONMENT_RECENT_MAX do delete(pop(r), heap)
}

// Adds `path` last among the recent panoramas (the settings file lists them newest first),
// unless it is there or the list is full.
environment_recent_append :: proc(app: ^App, path: string) {
	heap := runtime.heap_allocator()
	r := &app.env.recent
	if r.allocator.procedure == nil do r.allocator = heap
	if len(r) >= ENVIRONMENT_RECENT_MAX do return
	for p in r do if p == path do return
	append(r, strings.clone(path, heap))
}

// Decodes `path` as the environment, on a thread; until it is done the one there shows.
// With `wait`, finishes it here (startup and scripts, so what follows sees it) and says
// why it failed, "" when it did not. A file asked for while another decodes waits its
// turn, replacing any other waiting one.
environment_load :: proc(app: ^App, path: string, wait := false, quiet := false) -> string {
	e := &app.env
	if e.decode != nil && !wait {
		delete(e.next, runtime.heap_allocator())
		e.next, e.next_quiet = strings.clone(path, runtime.heap_allocator()), quiet
		return ""
	}
	if e.decode != nil do environment_poll(app, wait = true)
	environment_decode_start(app, path, quiet)
	if !wait do return ""
	return environment_poll(app, wait = true)
}

@(private = "file")
environment_decode_start :: proc(app: ^App, path: string, quiet: bool) {
	d := new(Environment_Decode, runtime.heap_allocator())
	d.path, d.quiet = strings.clone(path, runtime.heap_allocator()), quiet
	app.env.decode = d
	d.thread = thread.create_and_start_with_data(d, proc(data: rawptr) {
		d := (^Environment_Decode)(data)
		// What it leaves is freed by the frame loop with the same heap allocator, and its
		// temp memory is its own, freed at the end.
		context.allocator = runtime.heap_allocator()
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		defer sync.atomic_store(&d.done, true)
		bytes, err := file_read_any(d.path)
		if err != nil {
			d.why = fmt.aprintf("%v", err)
			return
		}
		defer delete(bytes)
		d.image, d.why = environment_decode(bytes, ENVIRONMENT_SOURCE_WIDTH)
		if d.why == "" do d.sh = environment_sh9(d.image)
	}, context, .Low, name = "environment decode")
}

// Takes a finished decode: makes its GPU copy and shows it, or says why not, keeping the
// environment there was. With `wait`, waits for one still running. Starts a waiting
// request after it. Returns the decode's failure, "" for none (or nothing done).
environment_poll :: proc(app: ^App, wait := false) -> (why: string) {
	e := &app.env
	d := e.decode
	if d == nil || (!wait && !sync.atomic_load(&d.done)) do return ""
	thread.join(d.thread)
	thread.destroy(d.thread)
	e.decode = nil
	heap := runtime.heap_allocator()
	defer {
		delete(d.path, heap)
		delete(d.why, heap)
		environment_image_destroy(&d.image, heap)
		free(d, heap)
	}
	name := filepath.base(d.path)
	superseded := e.next != ""
	switch {
	case superseded:
		// A newer request decides what shows; this one is dropped unseen.
	case d.why != "":
		why = fmt.tprintf("Cannot load environment %s: %s", name, d.why)
		file_note(app, true, "%s", why)
	case:
		gpu, ok := render.environment_create(&app.renderer, d.image.pixels, d.image.width, d.image.height, d.sh)
		if !ok {
			why = fmt.tprintf("Cannot load environment %s: the GPU refused a %d x %d panorama", name, d.image.width, d.image.height)
			file_note(app, true, "%s", why)
			break
		}
		render.environment_destroy(&app.renderer, &e.gpu)
		e.gpu = gpu
		delete(e.path, heap)
		e.path = strings.clone(d.path, heap)
		e.kind = .Image
		environment_recent_add(app, d.path)
		if !d.quiet do file_note(app, false, "Loaded environment %s (%d x %d)", name, d.image.width, d.image.height)
	}
	if superseded {
		next, quiet := e.next, e.next_quiet
		e.next = ""
		defer delete(next, heap)
		environment_decode_start(app, next, quiet)
		if wait do return environment_poll(app, wait = true)
	}
	return
}

// Waits for any decode, dropping what it made unseen (the app is closing), and releases
// the environment.
environment_destroy :: proc(app: ^App) {
	e := &app.env
	heap := runtime.heap_allocator()
	delete(e.next, heap)
	e.next = ""
	if d := e.decode; d != nil {
		thread.join(d.thread)
		thread.destroy(d.thread)
		delete(d.path, heap)
		delete(d.why, heap)
		environment_image_destroy(&d.image, heap)
		free(d, heap)
		e.decode = nil
	}
	render.environment_destroy(&app.renderer, &e.gpu)
	delete(e.path, heap)
	e.path = ""
	for p in e.recent do delete(p, heap)
	delete(e.recent)
	e.recent = {}
}

// Hands the renderer this frame's environment and how it shows: the panorama while Image
// is picked and one is loaded, else the studio.
environment_view :: proc(app: ^App) {
	r := &app.renderer
	e := &app.env
	if e.kind != .Image || e.gpu.source == nil {
		r.environment, r.environment_look = nil, {}
		return
	}
	r.environment = &e.gpu
	r.environment_look = {
		rotation   = environment_rotation(app),
		strength   = math.pow(2, clamp(e.strength, -ENVIRONMENT_STRENGTH_RANGE, ENVIRONMENT_STRENGTH_RANGE)),
		blur       = clamp(e.blur, 0, 1),
		exposure   = app.exposure,
		background = b32(e.background),
	}
}

// The panorama's axes in view space: turned about the up axis by the lights' Turn all and
// its own Turn (never tilted by the lights' Height, as a world's rotation spins it), leaned
// by its own Tilt, and fixed to the scene with the lights, so the camera then orbits inside
// it.
environment_rotation :: proc(app: ^App) -> [3][4]f32 {
	e := &app.env
	turn := linalg.matrix3_rotate_f32(math.to_radians(app.light_turn + e.turn), {0, 1, 0})
	rig := turn * linalg.matrix3_rotate_f32(math.to_radians(clamp(e.tilt, -ENVIRONMENT_TILT_RANGE, ENVIRONMENT_TILT_RANGE)), {1, 0, 0})
	if e.fixed {
		v := camera.orbit_view(app.camera)
		rig = linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]} * rig
	}
	return {{rig[0, 0], rig[1, 0], rig[2, 0], 0}, {rig[0, 1], rig[1, 1], rig[2, 1], 0}, {rig[0, 2], rig[1, 2], rig[2, 2], 0}}
}

// Whether a Shift and right drag on the view turns the panorama (Substance's gesture) rather
// than panning: while one is loaded, picked and the view worked in shows the materials
// whole (Material Preview or Rendered), where it is seen. Alt and right still pans.
environment_drag_turns :: proc(app: ^App) -> bool {
	e := &app.env
	if e.kind != .Image || e.gpu.source == nil do return false
	s, pane := main_draw_shading(app)
	m := shading_mode_shown(app, s, pane)
	return m == .Material_Preview || m == .Rendered
}

// Turns the panorama by a drag of `delta` points across the view: the sky follows the
// pointer as if held.
environment_drag :: proc(app: ^App, delta: [2]f32) {
	if delta.x == 0 do return
	e := &app.env
	e.turn = wrap_degrees(e.turn - delta.x / max(app.kit.scale, 0.01) * ENVIRONMENT_DRAG_TURN)
}

// `degrees` brought into -180 to 180.
wrap_degrees :: proc(degrees: f32) -> f32 {
	return math.mod(math.mod(degrees + 180, 360) + 360, 360) - 180
}

// How the background shows behind the scene, as the section's choice reads it.
Environment_Backdrop :: enum u8 {
	Plain,   // the flat or gradient background
	Shown,   // the panorama, sharp
	Blurred, // the panorama, as soft as Blur says
}

@(rodata)
ENVIRONMENT_BACKDROP_LABELS := [len(Environment_Backdrop)]string{"Plain", "Shown", "Blurred"}

// What Background shows: kept as the switch and Blur it always was, so older settings read
// the same.
environment_backdrop :: proc(e: ^Environment_State) -> Environment_Backdrop {
	if !e.background do return .Plain
	return .Blurred if e.blur > 0 else .Shown
}

// The Scene palette's Environment section: the built-in studio or the loaded image, the
// file and the ones loaded before it, its strength, its own turn and tilt (the pen's roll
// turns it too), and whether the background shows it plain, sharp or blurred.
kit_environment :: proc(app: ^App) {
	ctx := &app.kit.ctx
	e := &app.env
	labels := ENVIRONMENT_KIND_LABELS
	if picked := ui.tabs(ctx, "environment", labels[:], int(e.kind)); picked >= 0 do e.kind = Environment_Kind(picked)
	if ui.button(ctx, "Load environment...", .Bordered, glyph = ui.ICON_IMAGE) do file_dialog(app, .Environment)
	// The files loaded before, to swap back to with one tap; the one showing is left out.
	captioned := false
	for p in e.recent {
		if p == e.path do continue
		if !captioned do ui.caption(ctx, "RECENT")
		captioned = true
		if ui.button(ctx, fmt.tprintf("%s##recent %s", filepath.base(p), p), glyph = ui.ICON_IMAGE) do environment_load(app, p)
	}
	_ = ui.slider(ctx, "Strength", &e.strength, -ENVIRONMENT_STRENGTH_RANGE, ENVIRONMENT_STRENGTH_RANGE, .Linear, fmt.tprintf("%+.1f stops", e.strength))
	_ = ui.slider(ctx, "Turn", &e.turn, -180, 180, .Linear, fmt.tprintf("%+.0f°", e.turn), wrap = true)
	backdrops := ENVIRONMENT_BACKDROP_LABELS
	was := environment_backdrop(e)
	if picked := ui.tabs(ctx, "environment background", backdrops[:], int(was)); picked >= 0 && Environment_Backdrop(picked) != was {
		switch Environment_Backdrop(picked) {
		case .Plain:   e.background = false
		case .Shown:   e.background, e.blur = true, 0
		case .Blurred: e.background, e.blur = true, 0.3 if e.blur <= 0 else e.blur
		}
	}
	if environment_backdrop(e) == .Blurred do _ = ui.slider(ctx, "Blur", &e.blur, 0.01, 1, .Linear, fmt.tprintf("%.2f", e.blur))
	if kit_more(app, .Environment) {
		_ = ui.slider(ctx, "Tilt", &e.tilt, -ENVIRONMENT_TILT_RANGE, ENVIRONMENT_TILT_RANGE, .Linear, fmt.tprintf("%+.0f°", e.tilt))
		kit_more_end(app)
	}
	switch {
	case e.decode != nil:
		ui.paragraph(ctx, fmt.tprintf("Reading %s...", filepath.base(e.decode.path)))
	case e.gpu.source != nil:
		mb := f32(render.environment_bytes(e.gpu)) / (1024 * 1024)
		ui.paragraph(ctx, fmt.tprintf("%s, %d x %d (%.1f MB on the GPU).", filepath.base(e.path), e.gpu.width, e.gpu.height, mb))
	case:
		ui.paragraph(ctx, "No image loaded: Load environment picks a panorama (OpenEXR, Radiance .hdr, PNG or JPEG, twice as wide as tall).")
	}
	ui.paragraph(ctx, "Physically based materials reflect the environment and take their light from it; Turn spins it alone and Lights' Turn all spins it with the lights, and All fixed to the scene keeps it with the scene. Shift and a right drag on the view turns it in Material Preview and Rendered. MatCaps and the clay materials are not lit by it.")
}
