package main

import "core:fmt"
import "core:time"

import imgui "deps:odin-imgui"
import sdl "vendor:sdl3"

import "../render"
import "../sculpt"
import "../ui"

// The new interface (--new-ui, View > New interface): the Figma design's one layout for
// every screen, drawn by the ui kit over a viewport that fills the window. It covers the
// brushes, their size and strength, falloff, symmetry, undo, objects and files; the
// classic panels (Menu > Classic panels) keep everything else until they are ported.
// ImGui still draws the brush circle, the pie and, on F11, the Stats panel.

// Which card the right side shows.
Kit_Card :: enum u8 {
	None,
	Brush, // the held brush's settings
	Brushes, // every brush, for those the dock has no room for
	Objects,
}

Kit_State :: struct {
	ctx:   ui.Context,
	pass:  render.Ui_Pass,
	input: ui.Input, // built up from this frame's events
	card:  Kit_Card,
	menu:  bool,
	stats: bool, // the ImGui Stats panel over the viewport (F11)
	ms:    f64, // last frame's layout and tessellation, CPU
}

// The image id the viewport is drawn with; the kit hands it back in its draw commands.
KIT_VIEWPORT_IMAGE :: 1

// The brushes the dock shows; the rest are a tap away on the grid button.
KIT_DOCK := [?]sculpt.Brush_Kind{.Draw, .Smooth, .Clay, .Flatten, .Inflate, .Grab, .Mask}

// Each brush's icon in the Lucide font.
KIT_BRUSH_ICONS := [sculpt.Brush_Kind]rune {
	.Draw       = 0xe1d3, // brush
	.Smooth     = 0xe283, // waves
	.Clay       = 0xe104, // layers
	.Flatten    = 0xe120, // minus
	.Inflate    = 0xe349, // circle-dot
	.Pinch      = 0xe220, // shrink
	.Crease     = 0xe522, // slash
	.Grab       = 0xe1d7, // hand
	.Mask       = 0xe0a1, // contrast
	.Layer      = 0xe52e, // layers-2
	.Snake_Hook = 0xe38f, // spline
	.Morph      = 0xe1f5, // history
	.Paint      = 0xe2e7, // paintbrush
	.Cloth      = 0xe1ca, // shirt
}

// The falloff presets the Brush card offers, from FALLOFF_PRESETS.
KIT_FALLOFFS := [?]int{0, 2, 4} // Smooth, Sharp, Flat

kit_init :: proc(app: ^App) {
	ui.init(&app.kit.ctx)
	app.kit.card = .Brush
}

kit_destroy :: proc(app: ^App) {
	render.ui_pass_destroy(&app.renderer, &app.kit.pass)
	ui.destroy(&app.kit.ctx)
}

// Folds one SDL event into the kit's input for this frame.
kit_event :: proc(app: ^App, e: ^sdl.Event) {
	in_ := &app.kit.input
	button :: proc(b: u8) -> (ui.Button, bool) {
		switch b {
		case sdl.BUTTON_LEFT:   return .Left, true
		case sdl.BUTTON_RIGHT:  return .Right, true
		case sdl.BUTTON_MIDDLE: return .Middle, true
		}
		return .Left, false
	}
	#partial switch e.type {
	case .MOUSE_MOTION:
		in_.mouse, in_.mouse_valid = {e.motion.x, e.motion.y}, true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		in_.mouse, in_.mouse_valid = {e.button.x, e.button.y}, true
		if b, ok := button(e.button.button); ok {
			if e.button.down {
				in_.pressed += {b}
				in_.down += {b}
			} else {
				in_.released += {b}
				in_.down -= {b}
			}
		}
	case .MOUSE_WHEEL:
		in_.wheel += e.wheel.y
	case .WINDOW_MOUSE_LEAVE:
		in_.mouse_valid = false
	}
}

// Lays out the new interface for this frame and returns what the viewport saw. Runs
// where ui_draw would, inside the ImGui frame.
kit_frame :: proc(app: ^App, window: ^sdl.Window) -> Viewport_Input {
	start := time.tick_now()
	k := &app.kit
	w, h: i32
	_ = sdl.GetWindowSize(window, &w, &h)
	pw, ph: i32
	_ = sdl.GetWindowSizeInPixels(window, &pw, &ph)
	io := imgui.GetIO()
	in_ := k.input
	in_.window = {f32(w), f32(h)}
	in_.pixel_density = f32(pw) / f32(max(w, 1))
	in_.shift, in_.ctrl, in_.alt = io.KeyShift, io.KeyCtrl, io.KeyAlt
	// The viewport fills the window, pixel for pixel.
	app.ui.viewport_request = {f32(max(pw, 1)), f32(max(ph, 1))}

	ctx := &k.ctx
	ui.frame_begin(ctx, in_)
	ui.image(ctx, {0, 0, in_.window.x, in_.window.y}, KIT_VIEWPORT_IMAGE)
	kit_layout(app)
	input := kit_viewport_input(app, in_.window)
	if k.stats do draw_stats_panel(app)
	handle_shortcuts(app)
	if imgui.IsKeyPressed(.F11, false) do k.stats = !k.stats

	// The next frame's events build on what is held now.
	k.input.pressed, k.input.released, k.input.wheel = {}, {}, 0
	k.ms = time.duration_milliseconds(time.tick_since(start))
	return input
}

// What the viewport saw: everything the panels did not take. Buttons, keys and the
// wheel come from ImGui's view of the events, as draw_viewport's do.
@(private = "file")
kit_viewport_input :: proc(app: ^App, size: [2]f32) -> (input: Viewport_Input) {
	k := &app.kit
	io := imgui.GetIO()
	input.size = size
	input.hovered = k.ctx.input.mouse_valid && !ui.wants_pointer(&k.ctx)
	input.dragging = ui.viewport_dragging(&k.ctx)
	input.mouse_pos = {io.MousePos.x, io.MousePos.y}
	input.samples = make([]Input_Sample, len(app.samples), context.temp_allocator)
	copy(input.samples, app.samples[:])
	input.pen_tilt = app.pen_tilt
	input.mouse_delta = {io.MouseDelta.x, io.MouseDelta.y}
	if input.hovered || input.dragging do input.wheel = io.MouseWheel
	// A right press let go soon and about where it began is a tap, which opens the brush
	// pie, rather than an orbit.
	right_tap :=
		input.dragging && .Right in k.ctx.input.released && !io.KeyShift &&
		io.MouseDownDurationPrev[imgui.MouseButton.Right] < f32(time.duration_seconds(PIE_TAP)) &&
		io.MouseDragMaxDistanceSqr[imgui.MouseButton.Right] < PIE_TAP_PX * PIE_TAP_PX
	left := imgui.IsMouseDown(.Left)
	right := imgui.IsMouseDown(.Right)
	middle := imgui.IsMouseDown(.Middle)
	if input.dragging {
		input.orbit_drag = (right && !io.KeyShift) || (left && io.KeyAlt && !io.KeyCtrl)
		input.pan_drag = middle || (right && io.KeyShift)
		input.primary = left && (!io.KeyAlt || io.KeyCtrl)
		input.alt = input.primary && io.KeyAlt
		input.press = input.primary && .Left in k.ctx.input.pressed
		input.smooth = input.primary && io.KeyShift
		input.invert = input.primary && io.KeyCtrl
	}
	pie_update(app, &input, right_tap)
	adjust_update(app, &input)
	app.ui.viewport_draw_list = imgui.GetBackgroundDrawList()
	app.ui.viewport_origin = {}
	app.ui.viewport_mouse, app.ui.viewport_size, app.ui.viewport_hovered = input.mouse_pos, input.size, input.hovered
	return
}

@(private = "file")
kit_layout :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	TOP :: 24
	EDGE :: 24

	// Top left: the menu, then undo and redo.
	ui.begin_anchored(ctx, "top left", .Start, .Start, {EDGE, TOP}, {direction = .Row, gap = 8})
	ui.begin(ctx, "menu button", {padding = 4, radius = 16, background = .Panel})
	if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) do k.menu = !k.menu
	ui.end(ctx)
	ui.begin(ctx, "history", {direction = .Row, gap = 2, padding = 4, radius = 16, background = .Panel})
	if ui.icon_button(ctx, "Undo", ui.ICON_UNDO, enabled = history_can_undo(app)) do history_undo(app)
	if ui.icon_button(ctx, "Redo", ui.ICON_REDO, enabled = history_can_redo(app)) do history_redo(app)
	ui.end(ctx)
	ui.end(ctx)

	// Top middle: symmetry, any mix of the three axes.
	ui.begin_anchored(ctx, "symmetry", .Center, .Start, {0, TOP}, {direction = .Row, padding = 4, radius = 16, background = .Panel})
	for axis in sculpt.Axis {
		if ui.segment_button(ctx, fmt.tprint(axis), axis in app.brush.symmetry, 56, 48) do app.brush.symmetry ~= {axis}
	}
	ui.end(ctx)

	// Top right: which card shows.
	ui.begin_anchored(ctx, "cards", .End, .Start, {EDGE, TOP}, {direction = .Row, gap = 8})
	if ui.text_button(ctx, "Objects", 56, selected = k.card == .Objects) do k.card = .None if k.card == .Objects else .Objects
	if ui.text_button(ctx, "Brush", 56, selected = k.card == .Brush) do k.card = .None if k.card == .Brush else .Brush
	ui.end(ctx)

	// Left edge: size and strength.
	ui.begin_anchored(ctx, "sliders", .Start, .Center, {EDGE, 0}, {direction = .Row, gap = 12})
	_ = ui.vslider(ctx, "Size", &app.brush.radius_px, 5, 500, .Logarithmic, fmt.tprintf("%.0f", app.brush.radius_px))
	strength := brush_strength(app)
	_ = ui.vslider(ctx, "Strength", strength, 0, 1, .Linear, fmt.tprintf("%.2f", strength^))
	ui.end(ctx)

	// Bottom middle: the dock of brushes.
	ui.begin_anchored(ctx, "dock", .Center, .End, {0, EDGE}, {direction = .Row, gap = 4, padding = 6, radius = 20, background = .Panel, center = true})
	for kind in KIT_DOCK {
		if ui.brush_tile(ctx, BRUSH_NAMES[kind], KIT_BRUSH_ICONS[kind], app.brush.kind == kind) do kit_pick_brush(app, kind)
	}
	ui.divider(ctx)
	if ui.icon_button(ctx, "All brushes", ui.ICON_GRID, 64, selected = k.card == .Brushes) do k.card = .None if k.card == .Brushes else .Brushes
	ui.end(ctx)

	// Bottom right: what is being sculpted.
	if obj := selected_object(app); obj != nil {
		ui.begin_anchored(ctx, "status", .End, .End, {EDGE, EDGE}, {direction = .Row, gap = 16, padding = 10, radius = 18, background = .Panel})
		ui.label(ctx, fmt.tprintf("%s vertices", count_label(object_vertex_count(obj))), 12)
		if n := len(obj.levels.levels); n > 1 do ui.label(ctx, fmt.tprintf("Level %d of %d", obj.levels.current + 1, n), 12)
		if object_dynamic(obj) do ui.label(ctx, "Dynamic topology", 12)
		ui.end(ctx)
	}

	if k.card != .None do kit_card(app)
	if k.menu do kit_menu(app)
}

@(private = "file")
kit_pick_brush :: proc(app: ^App, kind: sculpt.Brush_Kind) {
	app.brush.kind = kind
	app.tool = .Brush
}

// The card on the right: the brush's settings, every brush, or the objects.
@(private = "file")
kit_card :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.begin_anchored(ctx, "card", .End, .Start, {24, 24 + 56 + 24}, {direction = .Column, gap = 12, padding = 18, width = 336, radius = 20, background = .Panel})
	switch k.card {
	case .None:
	case .Brush:
		kind := app.brush.kind
		ui.label(ctx, BRUSH_NAMES[kind], t.title_size, t.text, .Semibold)
		ui.label(ctx, "Falloff")
		shape := &app.brush.falloffs[kind]
		chosen := -1
		options: [len(KIT_FALLOFFS)]string
		for preset, i in KIT_FALLOFFS {
			p := FALLOFF_PRESETS[preset]
			options[i] = string(p.label)
			if shape.drawn == p.drawn && (!p.drawn || shape.curve == p.curve) do chosen = i
		}
		if picked := ui.segmented(ctx, "falloff", options[:], chosen); picked >= 0 {
			p := FALLOFF_PRESETS[KIT_FALLOFFS[picked]]
			shape^ = {drawn = p.drawn, curve = p.curve}
		}
		ui.spacer(ctx, 4)
		_ = ui.toggle_row(ctx, "Front faces only", &app.brush.front_only)
		_ = ui.toggle_row(ctx, "Pressure changes size", &app.brush.pressure_size)
		_ = ui.toggle_row(ctx, "Pressure changes strength", &app.brush.pressure_strength)
	case .Brushes:
		ui.label(ctx, "Brushes", t.title_size, t.text, .Semibold)
		row := 0
		for kind, i in sculpt.Brush_Kind {
			if i % 4 == 0 do ui.begin(ctx, fmt.tprintf("row %d", row), {direction = .Row, gap = 4})
			if ui.brush_tile(ctx, BRUSH_NAMES[kind], KIT_BRUSH_ICONS[kind], app.brush.kind == kind) do kit_pick_brush(app, kind)
			if i % 4 == 3 || i == len(sculpt.Brush_Kind) - 1 {
				ui.end(ctx)
				row += 1
			}
		}
	case .Objects:
		ui.label(ctx, "Objects", t.title_size, t.text, .Semibold)
		for obj, i in app.scene.objects {
			name := fmt.tprintf("%s##%d", object_label(obj), obj.id)
			if ui.list_row(ctx, name, count_label(object_vertex_count(obj)), i == app.scene.selected) do app.scene.selected = i
		}
	}
	ui.end(ctx)
}

// The menu under the menu button: files, and the way back to the classic panels.
@(private = "file")
Kit_Menu_Item :: enum u8 {
	Open,
	Save,
	Save_As,
	Import,
	Export,
	Screenshot,
	Stats,
	Classic,
}

@(private = "file")
KIT_MENU := [Kit_Menu_Item]struct {
	label, keys: string,
} {
	.Open       = {"Open scene...", "Ctrl+O"},
	.Save       = {"Save scene", "Ctrl+S"},
	.Save_As    = {"Save scene as...", "Ctrl+Shift+S"},
	.Import     = {"Import mesh...", ""},
	.Export     = {"Export mesh...", ""},
	.Screenshot = {"Save screenshot...", ""},
	.Stats      = {"Stats", "F11"},
	.Classic    = {"Classic panels", ""},
}

@(private = "file")
kit_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ui.begin_anchored(ctx, "menu", .Start, .Start, {24, 24 + 56 + 12}, {direction = .Column, gap = 2, padding = 8, width = 300, radius = 16, background = .Panel})
	picked: Maybe(Kit_Menu_Item)
	for item in Kit_Menu_Item {
		if ui.list_row(ctx, KIT_MENU[item].label, KIT_MENU[item].keys, selected = item == .Stats && k.stats) do picked = item
	}
	ui.end(ctx)
	item, ok := picked.?
	if !ok do return
	k.menu = false
	switch item {
	case .Open:       file_dialog(app, .Open)
	case .Save:
		if app.scene_path != "" {
			file_post(.Save, app.scene_path)
		} else {
			file_dialog(app, .Save)
		}
	case .Save_As:    file_dialog(app, .Save)
	case .Import:     file_dialog(app, .Import)
	case .Export:     file_dialog(app, .Export)
	case .Screenshot: file_dialog(app, .Screenshot)
	case .Stats:      k.stats = !k.stats
	case .Classic:    app.new_ui = false
	}
}

// Turns the kit's draw commands into the renderer's, with the viewport image (or the
// studio render's, while it is on) where the kit drew KIT_VIEWPORT_IMAGE.
kit_draws :: proc(app: ^App, dl: ^ui.Draw_List) -> []render.Ui_Draw {
	shown := app.target.color
	if app.studio_on {
		if tex := render.studio_texture(&app.studio); tex != nil do shown = tex
	}
	draws := make([]render.Ui_Draw, len(dl.cmds), context.temp_allocator)
	for c, i in dl.cmds {
		draws[i] = {
			first_index = c.first_index,
			index_count = c.index_count,
			clip        = {i32(c.clip.x), i32(c.clip.y), i32(c.clip.w + 0.5), i32(c.clip.h + 0.5)},
			image       = shown if c.texture == .Image else nil,
		}
	}
	return draws
}

// Uploads this frame's interface on `cmd`, ahead of the render pass that draws it.
kit_upload :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer) -> bool {
	k := &app.kit
	dl := ui.frame_end(&k.ctx)
	pixels, w, h, dirty, changed := ui.atlas_take(&k.ctx)
	vertices := transmute([]render.Ui_Vertex)dl.vertices[:]
	return render.ui_pass_upload(&app.renderer, &k.pass, cmd, vertices, dl.indices[:], pixels, {u32(w), u32(h)}, dirty, changed)
}

// Writes the whole window as the new interface last drew it (viewport and panels,
// without what ImGui adds) to a PNG, or a PPM when the path ends in .ppm.
kit_screen_save :: proc(app: ^App, path: string, size: [2]u32) -> bool {
	k := &app.kit
	dl := &k.ctx.draw
	vertices := transmute([]render.Ui_Vertex)dl.vertices[:]
	atlas, aw, ah := ui.atlas_pixels(&k.ctx)
	t := k.ctx.theme.canvas
	clear := [4]f32{f32(t.r) / 255, f32(t.g) / 255, f32(t.b) / 255, 1}
	pixels := render.ui_pass_capture(&app.renderer, &k.pass, size, clear, kit_draws(app, dl), vertices, dl.indices[:], atlas, {u32(aw), u32(ah)}, context.temp_allocator)
	if pixels == nil {
		file_note(app, true, "Could not read the screen back: %s", sdl.GetError())
		return false
	}
	return image_save(app, path, pixels, int(size.x), int(size.y))
}
