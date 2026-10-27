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
ENVIRONMENT_SOURCE_WIDTH :: 1024 when ODIN_PLATFORM_SUBTARGET == .Android else 2048
// The Strength slider's reach either way, in stops.
ENVIRONMENT_STRENGTH_RANGE :: 4

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
	path:       string, // the file the GPU copy came from (heap), "" while there is none
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
	delete(e.path, runtime.heap_allocator())
	e.path = ""
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

// The panorama's axes in view space: turned with the lights' Turn all about the up axis
// (never tilted by its Height, as a world's rotation spins it), and fixed to the scene
// with the lights, so the camera then orbits inside it.
environment_rotation :: proc(app: ^App) -> [3][4]f32 {
	rig := linalg.matrix3_rotate_f32(math.to_radians(app.light_turn), {0, 1, 0})
	if app.env.fixed {
		v := camera.orbit_view(app.camera)
		rig = linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]} * rig
	}
	return {{rig[0, 0], rig[1, 0], rig[2, 0], 0}, {rig[0, 1], rig[1, 1], rig[2, 1], 0}, {rig[0, 2], rig[1, 2], rig[2, 2], 0}}
}

// The Scene palette's Environment section: the built-in studio or the loaded image, the
// file, its strength, and under More whether the background shows it and how blurred.
kit_environment :: proc(app: ^App) {
	ctx := &app.kit.ctx
	e := &app.env
	labels := ENVIRONMENT_KIND_LABELS
	if picked := ui.tabs(ctx, "environment", labels[:], int(e.kind)); picked >= 0 do e.kind = Environment_Kind(picked)
	if ui.button(ctx, "Load environment...", .Bordered, glyph = ui.ICON_IMAGE) do file_dialog(app, .Environment)
	_ = ui.slider(ctx, "Strength", &e.strength, -ENVIRONMENT_STRENGTH_RANGE, ENVIRONMENT_STRENGTH_RANGE, .Linear, fmt.tprintf("%+.1f stops", e.strength))
	if kit_more(app, .Environment) {
		_ = ui.switch_row(ctx, "Background", &e.background)
		_ = ui.slider(ctx, "Blur", &e.blur, 0, 1, .Linear, fmt.tprintf("%.2f", e.blur))
		kit_more_end(app)
	}
	switch {
	case e.decode != nil:
		ui.paragraph(ctx, fmt.tprintf("Reading %s...", filepath.base(e.decode.path)))
	case e.gpu.source != nil:
		mb := f32(render.environment_bytes(e.gpu)) / (1024 * 1024)
		ui.paragraph(ctx, fmt.tprintf("%s, %d x %d (%.1f MB on the GPU).", filepath.base(e.path), e.gpu.width, e.gpu.height, mb))
	case:
		ui.paragraph(ctx, "No image loaded: Load environment picks a panorama (Radiance .hdr, PNG or JPEG, twice as wide as tall).")
	}
	ui.paragraph(ctx, "Physically based materials reflect the environment and take their light from it; Lights' Turn all spins it, and All fixed to the scene keeps it with the scene. MatCaps and the clay materials are not lit by it.")
}
