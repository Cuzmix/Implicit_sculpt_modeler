package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../render"
import "../ui"

// Which GPU backend draws, as Settings > System > Graphics chooses it. The backend is fixed
// once the window exists, so a change applies when Sculpt next starts.
Graphics :: enum u8 {
	// render's own Vulkan backend, or on Apple's platforms its own Metal one, where the
	// platform and device allow it; SDL_GPU elsewhere.
	Auto,
	Vulkan,
	SDL_GPU,
	// render's own Metal backend, on Apple's platforms only.
	Metal,
}

// Whether the platform can run the Vulkan backend at all; Mac and iPad run render's own
// Metal backend instead, and both fall back to SDL_GPU where they cannot start.
GRAPHICS_VULKAN :: ODIN_OS != .Darwin
GRAPHICS_METAL :: ODIN_OS == .Darwin

// The choices the platform offers, in the order the menu lists them.
when GRAPHICS_VULKAN {
	@(rodata)
	GRAPHICS_OFFERED := [?]Graphics{.Auto, .Vulkan, .SDL_GPU}
} else {
	@(rodata)
	GRAPHICS_OFFERED := [?]Graphics{.Auto, .Metal, .SDL_GPU}
}

GRAPHICS_NAMES := [Graphics]string {
	.Auto    = "Automatic",
	.Vulkan  = "Vulkan",
	.SDL_GPU = "SDL_GPU",
	.Metal   = "Metal",
}

// Frames a start on render's own Metal backend must show before it counts as started:
// about two seconds at 60 Hz, past the first uploads, passes and presents.
GRAPHICS_TRIAL_FRAMES :: 120

// The file beside the settings that a start on render's own Metal backend leaves until it
// has shown its first frames. Found at the next start, it means that backend stopped
// Sculpt as it started, so that run, and the setting, draw with SDL_GPU instead: neither
// Automatic nor the menu can lock the person out of the app.
graphics_trial_path :: proc(settings: string) -> string {
	if settings == "" do return ""
	dir, base := filepath.split(settings)
	path, _ := filepath.join({dir, fmt.tprintf("%s-metal-trial", filepath.stem(base))}, context.temp_allocator)
	return path
}

// Leaves the marker for a Metal start the setting chose (Metal, or Automatic on Apple's
// platforms) and returns its path (temp), or, finding the marker a start before left,
// removes it and returns SDL_GPU with `failed` (the setting then moves to SDL_GPU too). A start --gpu chose is not guarded, since
// whoever typed the flag can leave it out.
graphics_trial_begin :: proc(choice: Graphics, flag, settings: string) -> (start: Graphics, marker: string, failed: bool) {
	path := graphics_trial_path(settings)
	metal := choice == .Metal || choice == .Auto && GRAPHICS_METAL
	if !metal || flag != "" || path == "" do return choice, "", false
	if os.exists(path) {
		_ = os.remove(path)
		return .SDL_GPU, "", true
	}
	if os.write_entire_file(path, transmute([]u8)string("metal trial starting\n")) != nil do return choice, "", false
	return choice, path, false
}

// The Metal start has shown its first frames (or the run ended without a crash): its marker goes.
graphics_trial_end :: proc(app: ^App) {
	if app.graphics_trial == "" do return
	_ = os.remove(app.graphics_trial)
	delete(app.graphics_trial)
	app.graphics_trial = ""
}

// The backend a choice asks for on this platform.
graphics_backend :: proc(choice: Graphics) -> render.Gpu_Backend {
	if choice == .SDL_GPU do return .SDL_GPU
	when GRAPHICS_METAL do return .Metal if choice == .Metal || choice == .Auto else .SDL_GPU
	else do return .SDL_GPU if choice == .Metal else .Vulkan
}

// The choice `--gpu` makes for this run, or the one the settings file at `path` holds when
// the flag is not given. False for a value the flag does not know.
graphics_choice :: proc(flag, path: string) -> (Graphics, bool) {
	switch flag {
	case "":       return graphics_saved(path), true
	case "auto":   return .Auto, true
	case "vulkan": return .Vulkan, true
	case "sdl":    return .SDL_GPU, true
	case "metal":  return .Metal, GRAPHICS_METAL
	}
	return .Auto, false
}

// The graphics line of the settings file at `path`, read on its own before the window is
// made, as the backend decides how windows are made; settings_load reads it again with the
// rest. Automatic when there is no file or no such line.
graphics_saved :: proc(path: string) -> Graphics {
	if path == "" do return .Auto
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return .Auto
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 2 || f[0] != "graphics" do continue
		for g in Graphics do if strings.equal_fold(fmt.tprint(g), f[1]) do return g
	}
	return .Auto
}

// The backend a choice named, for the words of a fallback: Automatic asks for Vulkan, or
// Metal on Apple's platforms.
graphics_asked :: proc(choice: Graphics) -> Graphics {
	if choice != .Auto do return choice
	return .Metal if GRAPHICS_METAL else .Vulkan
}

// The Graphics block of Settings > System: the menu, what draws now and why.
graphics_controls :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	names: [len(GRAPHICS_OFFERED)]string
	chosen := 0
	for g, i in GRAPHICS_OFFERED {
		names[i] = GRAPHICS_NAMES[g]
		if g == app.graphics do chosen = i
	}
	ui.spacer(ctx, 8)
	ui.label(ctx, "Graphics")
	if picked := ui.select(ctx, "Graphics", names[:], chosen); picked >= 0 do app.graphics = GRAPHICS_OFFERED[picked]
	running := "SDL_GPU"
	switch render.backend_name() {
	case "vulkan": running = "Vulkan"
	case "metal":  running = "Metal"
	}
	status := fmt.tprintf("Drawing with %s.", running)
	if app.graphics_trial_failed do status = fmt.tprintf("%s Metal stopped Sculpt as it started last time, so Graphics is now SDL_GPU; choose Automatic or Metal to try it again.", status)
	if why := render.backend_fallback(); why != "" {
		asked := GRAPHICS_NAMES[graphics_asked(app.graphics_start)]
		status = fmt.tprintf("Drawing with SDL_GPU: %s could not start here (%s).", asked, why)
	}
	if app.graphics_start != app.graphics_loaded do status = fmt.tprintf("%s --gpu chose it for this run.", status)
	pending := app.graphics != app.graphics_loaded
	if pending do status = fmt.tprintf("%s The change applies when Sculpt next starts.", status)
	ui.paragraph(ctx, status, color = t.warning if pending else t.text_secondary)
	if render.caps(&app.renderer).async_compute == .Second_Queue {
		_ = ui.switch_row(ctx, "Async compute", &app.async_compute)
		ui.paragraph(ctx, "Render mode traces on a second GPU queue beside the frame, so panels and the first orbit after a still view stay smooth while it builds up. Off traces in the frame, for comparing the two.")
	}
	if render.caps(&app.renderer).ray_query {
		_ = ui.switch_row(ctx, "Ray tracing hardware", &app.ray_query)
		ui.paragraph(ctx, "The studio render's shadows and occlusion trace the GPU's own ray tracing structures, built by its driver, instead of the app's. Off walks the app's own, for comparing the two.")
	}
	when GRAPHICS_VULKAN {
		ui.paragraph(ctx, "Automatic draws with Vulkan, the app's own renderer, and with SDL_GPU on a device whose Vulkan lacks what it needs. Both draw the same image; SDL_GPU is there in case a driver misbehaves.")
	} else {
		ui.paragraph(ctx, "Automatic draws with Metal, the app's own renderer, and with SDL_GPU where Metal cannot start; if Metal stops Sculpt as it starts, the next start switches to SDL_GPU. Both draw the same image; SDL_GPU is there in case a driver misbehaves, and leaves out Smooth all on the GPU.")
	}
}
