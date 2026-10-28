package main

import "core:fmt"
import "core:os"
import "core:strings"

import "../render"
import "../ui"

// Which GPU backend draws, as Settings > System > Graphics chooses it. The backend is fixed
// once the window exists, so a change applies when Sculpt next starts.
Graphics :: enum u8 {
	// Vulkan where the platform and device allow it, SDL_GPU elsewhere.
	Auto,
	Vulkan,
	SDL_GPU,
}

// Whether the platform can run the Vulkan backend at all. Mac and iPad draw with SDL_GPU
// (Metal) until render has a Metal backend of its own.
GRAPHICS_VULKAN :: ODIN_OS != .Darwin

// The choices the platform offers, in the order the menu lists them.
when GRAPHICS_VULKAN {
	@(rodata)
	GRAPHICS_OFFERED := [?]Graphics{.Auto, .Vulkan, .SDL_GPU}
} else {
	@(rodata)
	GRAPHICS_OFFERED := [?]Graphics{.Auto, .SDL_GPU}
}

GRAPHICS_NAMES := [Graphics]string {
	.Auto    = "Automatic",
	.Vulkan  = "Vulkan",
	.SDL_GPU = "SDL_GPU",
}

// The backend a choice asks for on this platform.
graphics_backend :: proc(choice: Graphics) -> render.Gpu_Backend {
	if !GRAPHICS_VULKAN || choice == .SDL_GPU do return .SDL_GPU
	return .Vulkan
}

// The choice `--gpu` makes for this run, or the one the settings file at `path` holds when
// the flag is not given. False for a value the flag does not know.
graphics_choice :: proc(flag, path: string) -> (Graphics, bool) {
	switch flag {
	case "":       return graphics_saved(path), true
	case "auto":   return .Auto, true
	case "vulkan": return .Vulkan, true
	case "sdl":    return .SDL_GPU, true
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
	running := "Vulkan" if render.backend_name() == "vulkan" else "SDL_GPU"
	status := fmt.tprintf("Drawing with %s.", running)
	if why := render.backend_fallback(); why != "" {
		status = fmt.tprintf("Drawing with SDL_GPU: Vulkan could not start here (%s).", why)
	}
	if app.graphics_start != app.graphics_loaded do status = fmt.tprintf("%s --gpu chose it for this run.", status)
	pending := app.graphics != app.graphics_loaded
	if pending do status = fmt.tprintf("%s The change applies when Sculpt next starts.", status)
	ui.paragraph(ctx, status, color = t.warning if pending else t.text_secondary)
	when GRAPHICS_VULKAN {
		ui.paragraph(ctx, "Automatic draws with Vulkan, the app's own renderer, and with SDL_GPU on a device whose Vulkan lacks what it needs. Both draw the same image; SDL_GPU is there in case a driver misbehaves.")
	} else {
		ui.paragraph(ctx, "This device draws with SDL_GPU (Metal).")
	}
}
