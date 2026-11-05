package main

import "core:fmt"

import "../ui"

// The readout: plain text in the view's top corner on the off-hand side (the top left,
// right-handed), as Blender and Nomad show theirs. Its first line is the camera and the
// shading, each a word that opens its menu (the Camera menu: the projection, the lens,
// framing, the view grid, Clean view; the Shading menu: the passes, the wireframe, the
// lights); then, small and faded, the scene's vertices, the memory the app holds with a
// thin bar against the device's, and the GPU's time a frame. It is part of the view, not a
// dock: it holds no buttons and nothing carries it. The object's name is the top bar's, so
// it is not repeated. Menu > More > Viewport readout hides it. It stands aside while another
// pane is maximised over the main view, whose head has its own camera and shading.

Readout :: struct {
	shown:  bool, // laid out this frame (an exit stat)
	at:     [2]f32, // where, in points (an exit stat)
	menus:  int, // the menus its words opened (an exit stat)
	memory: int, // the app's memory when last read, in bytes
	read:   int, // the frame it was last read in
}

// How many frames apart the readout reads the app's memory: the number changes slowly and
// reading it is a system call, so a frame in thirty is often enough.
READOUT_MEMORY_EVERY :: 30

// The thin memory bar's width and height, in points.
READOUT_BAR_W :: 36
READOUT_BAR_H :: 3

kit_readout :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	r := &k.readout
	r.shown = false
	if k.readout_hidden do return
	if k.grid.maximised != 0 && grid_panes(&k.grid) > 1 do return
	r.shown = true
	at := [2]f32{LENS_EDGE + 4, TOP_BAR_H + 6}
	// On the main pane's own corner while a view pane is worked in too, so it never stands
	// over that pane's head.
	if g := &k.grid; grid_panes(g) > 1 && g.maximised == 0 && g.home.w > 0 {
		win := ctx.input.window
		edge := win.x - (g.home.x + g.home.w) if ctx.mirror else g.home.x
		at = {LENS_EDGE + 4 + edge, max(TOP_BAR_H + 6, g.home.y + 8)}
	}
	r.at = at
	if r.memory == 0 || k.frame - r.read >= READOUT_MEMORY_EVERY {
		r.memory, r.read = process_memory(), k.frame
	}
	ui.begin_anchored(ctx, "points", .Start, .Start, at, {direction = .Column})
	ui.begin(ctx, "readout lines", {direction = .Column, gap = 0})
	ui.begin(ctx, "readout", {direction = .Row, gap = ui.SPACE_2XS, center = true})
	c := main_camera(app)
	camera := "Ortho" if c.ortho else fmt.tprintf("Persp · %.0f mm", lens_focal_mm(c.fov_y))
	if a := readout_word(ctx, "Camera##readout", camera, bar_pop_showing(app, .Camera), command_hint(app, .Camera_Menu)); a.clicked {
		if !bar_pop_showing(app, .Camera) do r.menus += 1
		k.bar_at[.Camera], k.bar_side[.Camera] = a.rect, .Below
		bar_pop_toggle(app, .Camera, a.rect, .Below)
	}
	shown := viewport_pass(k) if k.grid.work == 0 else k.passes.pass
	pass := readout_word(ctx, "Shading##readout", pass_label(app, shown), k.passes.menu, command_hint(app, .Pass_Menu))
	if pass.clicked && !k.passes.menu do r.menus += 1
	pass_chip_follow(k, pass.rect, pass.clicked)
	ui.end(ctx)
	vertices := 0
	for obj in app.scene.objects do vertices += object_vertex_count(obj)
	readout_line(ctx, fmt.tprintf("Vertices %s", readout_count(vertices)))
	if r.memory > 0 {
		ram := platform_ram()
		text := fmt.tprintf("%s / %s", readout_bytes(r.memory), readout_bytes(ram)) if ram > 0 else readout_bytes(r.memory)
		w := READOUT_BAR_W + 6 + ui.text_width(ctx, text, t.small_size)
		line := ui.place(ctx, {w, ui.line_height(t.small_size)})
		bar := ui.Rect{line.x + 6, line.y + (line.h - READOUT_BAR_H) * 0.5, READOUT_BAR_W, READOUT_BAR_H}
		_, faint := readout_inks(t)
		ui.fill_rect(ctx, bar, READOUT_BAR_H * 0.5, ui.color_fade(faint, 0.3))
		if ram > 0 {
			full := clamp(f32(r.memory) / f32(ram), 0.02, 1)
			ui.fill_rect(ctx, {bar.x, bar.y, bar.w * full, bar.h}, READOUT_BAR_H * 0.5, faint)
		}
		ui.text(ctx, text, bar.x + bar.w + 6, line.y + line.h * 0.5, t.small_size, faint)
	}
	if k.readout_gpu {
		if ms, ok := readout_gpu_ms(app); ok do readout_line(ctx, fmt.tprintf("GPU %.1f ms", ms))
	}
	ui.end(ctx)
	ui.end(ctx)
}

// A word of the readout's first line that opens a menu: the text with a small chevron,
// lit while its menu shows, a touch target's height.
@(private = "file")
readout_word :: proc(ctx: ^ui.Context, name, text: string, lit: bool, keys: string) -> ui.Area {
	t := ctx.theme
	w := 12 + ui.text_width(ctx, text, t.small_size, .Semibold) + 16
	a := ui.area(ctx, name, {w, t.target * 0.75}, drag = false)
	if a.held do ui.fill_rect(ctx, a.rect, t.radius_small, t.fill_pressed)
	else if a.hovered do ui.fill_rect(ctx, a.rect, t.radius_small, t.fill_hover)
	cy := a.rect.y + a.rect.h * 0.5
	ink, faint := readout_inks(t)
	ui.text(ctx, text, a.rect.x + 6, cy, t.small_size, t.accent if lit else ink, .Semibold)
	ui.icon(ctx, ui.ICON_CHEVRON_DOWN, {a.rect.x + a.rect.w - 10, cy}, t.icon_small - 4, faint)
	ui.tip(ctx, a.id, a.rect, name[:len(name) - len("##readout")], keys)
	return a
}

// A faded line of the readout, inset to the words' text.
@(private = "file")
readout_line :: proc(ctx: ^ui.Context, text: string) {
	t := ctx.theme
	r := ui.place(ctx, {ui.text_width(ctx, text, t.small_size) + 6, ui.line_height(t.small_size)})
	_, faint := readout_inks(t)
	ui.text(ctx, text, r.x + 6, r.y + r.h * 0.5, t.small_size, faint)
}

// The readout's inks, its words' and its faint lines'. It stands on the view itself, not
// on a panel, and the view's ground is dark under every theme, so a light theme's dark
// inks would sink into it: there they are taken from its light surfaces instead, at
// about the steps a dark theme's labels and hints stand from its text.
@(private = "file")
readout_inks :: proc(t: ui.Theme) -> (ink, faint: ui.Color) {
	if ui.color_luminance(t.text) > ui.color_luminance(t.surface) do return t.text_secondary, t.text_tertiary
	return ui.color_mix(t.surface_raised, t.text, 0.25), ui.color_mix(t.surface_raised, t.text, 0.42)
}

// The GPU's typical time a frame: the 3D drawing while the GPU is timed, else the frame's
// whole GPU work from timestamps where the device has them; false where neither is measured.
readout_gpu_ms :: proc(app: ^App) -> (f32, bool) {
	s := &app.stats
	if app.time_gpu && s.gpu_ms.count > 0 {
		p50, _ := ring_percentiles(s.gpu_ms)
		return p50, true
	}
	if s.gpu_spans[.None].count > 0 {
		p50, _ := ring_percentiles(s.gpu_spans[.None])
		return p50, true
	}
	return 0, false
}

// A count as the readout shows it: 980, 98.3k, 1.25M.
readout_count :: proc(n: int) -> string {
	switch {
	case n >= 1_000_000: return fmt.tprintf("%.2fM", f64(n) / 1e6)
	case n >= 1_000:     return fmt.tprintf("%.1fk", f64(n) / 1e3)
	}
	return fmt.tprintf("%d", n)
}

// Bytes as the readout shows them: 92.8 MB, 11.9 GB.
readout_bytes :: proc(n: int) -> string {
	if n >= 1 << 30 do return fmt.tprintf("%.1f GB", f64(n) / (1 << 30))
	return fmt.tprintf("%.1f MB", f64(n) / (1 << 20))
}
