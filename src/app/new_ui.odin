package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

import "../geom"
import "../render"
import "../sculpt"
import "../ui"

// The interface: one layout for every screen, drawn by the ui kit over a viewport that
// fills the window (the design spec "Sculpt UI redesign"). Toolbars float at the top,
// the inspector (the tool, the object and the scene) on the right, size and strength on
// the left, the brush dock at the bottom, and the History over the dock when it is open.
// Everything the app shows is drawn by the kit (src/ui).

// The inspector's tabs.
Kit_Tab :: enum u8 {
	Tool,
	Object,
	Scene,
}

Kit_State :: struct {
	ctx:        ui.Context,
	pass:       render.Ui_Pass,
	scale:      f32, // window coordinates per point, this frame
	last_frame: time.Tick, // for the animations' clock
	inspector:  bool,
	tab:        Kit_Tab,
	tab_serial: u64, // counts tab changes, so each one fades its content in afresh
	menu:       bool,
	view_menu:  bool,
	browser:    bool, // every brush, in a popover over the dock
	stats:      bool, // the Stats panel (F11)
	history:    bool, // the History panel, over the dock
	text_input: bool, // SDL's text input is on, for the text field that has the keys
	// Where the viewport's overlay goes in the draw order: over the viewport image and
	// under the panels. Set while a frame is laid out, until the overlay is drawn.
	layer:      Maybe(ui.Layer),
	// The outliner's context menu: open, on which object, where.
	object_menu:    bool,
	object_menu_id: int,
	object_menu_at: ui.Rect,
	// Which inspector sections are open.
	open:       [Kit_Section]bool,
	scroll:     f32, // the inspector's scroll, where it is heading
	scroll_drag: bool, // a drag on the inspector is scrolling it...
	scroll_from: f32, // ...which puts the scroll at this less the pointer's height
	add_shape:  geom.Primitive,
	add_size:   int, // into SPHERE_PRESETS
	note_at:    time.Tick, // the file note last shown as a toast
	frame:      int, // frames drawn, for --ui-events
	events:     [dynamic]Kit_Event, // --ui-events, in frame order
	ms:         f64, // last frame's layout and tessellation, CPU
}

Kit_Section :: enum u8 {
	// The tool tab's.
	Stroke,
	Paint_Color,
	Falloff,
	Alpha,
	Pen,
	Options,
	Recorder,
	// The object tab's.
	Transform,
	Levels,
	Hd,
	Topology,
	Mask,
	Visibility,
	Paint,
	Morph,
	Layers,
	Deform,
	Remesh,
	Mirror,
	Retopo,
	Project,
	Booleans,
	Extract,
	// The scene tab's.
	Add,
	Material,
	Studio,
	Camera,
	// The Stats panel's.
	Frame,
	Drawing,
	Sculpting,
}

// One scripted pointer event (--ui-events), applied at the start of its frame.
Kit_Event :: struct {
	frame: int,
	kind:  enum u8 {
		Move,
		Down,
		Up,
		Right,
		Wheel,
	},
	at:    [2]f32,
	wheel: f32,
}

// Reads --ui-events. Returns false, after saying why, when the list is malformed.
kit_events_parse :: proc(app: ^App, spec: string) -> bool {
	if spec == "" do return true
	for item in strings.split(spec, ";", context.temp_allocator) {
		parts := strings.split(strings.trim_space(item), ":", context.temp_allocator)
		ev: Kit_Event
		ok := len(parts) >= 2
		frame: int
		if ok do frame, ok = strconv.parse_int(parts[0])
		ev.frame = frame
		if ok {
			switch parts[1] {
			case "move":
				xy := strings.split(parts[2], ",", context.temp_allocator) if len(parts) == 3 else nil
				ok = len(xy) == 2
				if ok {
					x, okx := strconv.parse_f32(xy[0])
					y, oky := strconv.parse_f32(xy[1])
					ev.kind, ev.at, ok = .Move, {x, y}, okx && oky
				}
			case "down":  ev.kind = .Down
			case "up":    ev.kind = .Up
			case "right": ev.kind = .Right
			case "wheel":
				ok = len(parts) == 3
				if ok do ev.wheel, ok = strconv.parse_f32(parts[2])
				ev.kind = .Wheel
			case:
				ok = false
			}
		}
		if !ok {
			log.errorf("--ui-events: cannot read %q", item)
			return false
		}
		append(&app.kit.events, ev)
	}
	slice.stable_sort_by(app.kit.events[:], proc(a, b: Kit_Event) -> bool {return a.frame < b.frame})
	return true
}

// Applies this frame's scripted events as SDL's would arrive, so the panels and the
// viewport both see them. `scale` turns their window points into window coordinates.
@(private = "file")
kit_events_apply :: proc(app: ^App, scale: f32) {
	k := &app.kit
	d := &app.device
	now := sdl.GetTicksNS()
	for ev in k.events {
		if ev.frame != k.frame do continue
		d.input_at = now
		switch ev.kind {
		case .Move:
			device_move(d, ev.at * scale)
		case .Down:
			device_button(d, .Left, true, now)
		case .Up:
			device_button(d, .Left, false, now)
		case .Right:
			device_button(d, .Right, true, now)
			device_button(d, .Right, false, now)
		case .Wheel:
			d.wheel += ev.wheel
		}
	}
}

// What the window shows where nothing is drawn (a screen dump's background).
KIT_CANVAS :: ui.Color{0x11, 0x12, 0x14, 0xff}

// The image id the viewport is drawn with; the kit hands it back in its draw commands.
KIT_VIEWPORT_IMAGE :: 1

// The brushes the dock shows; the rest are a tap away in the brush browser.
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

// The inspector's width, and the toolbars' height: one touch target.
KIT_INSPECTOR_W :: 312

kit_init :: proc(app: ^App) {
	ui.init(&app.kit.ctx)
	k := &app.kit
	k.inspector = true
	// The sections most reached for start open; the rest fold until asked for.
	for s in ([?]Kit_Section{.Stroke, .Paint_Color, .Falloff, .Transform, .Levels, .Mask, .Add, .Frame, .Sculpting}) do k.open[s] = true
	k.add_size = 2 // 1M
	k.last_frame = time.tick_now()
}

kit_destroy :: proc(app: ^App) {
	delete(app.kit.events)
	render.ui_pass_destroy(&app.renderer, &app.kit.pass)
	ui.destroy(&app.kit.ctx)
}

// Window coordinates per interface point. SDL gives the pointer and the window's size in
// window coordinates, which are pixels on Android and Windows; the display's content
// scale (Android's screen density, Windows' scaling setting) turns them into points, so
// a 48 point target is 48 dp on a tablet. 1 where window coordinates are already
// points (macOS, Wayland) or the display is not scaled.
kit_content_scale :: proc(window: ^sdl.Window) -> f32 {
	display := sdl.GetWindowDisplayScale(window)
	density := sdl.GetWindowPixelDensity(window)
	if display <= 0 || density <= 0 do return 1
	return max(display / density, 1)
}

// Starts the kit's frame with this frame's pointer, in points, and returns the window's
// size in window coordinates and in pixels.
@(private = "file")
kit_begin :: proc(app: ^App, window: ^sdl.Window) -> (size, pixels: [2]i32) {
	k := &app.kit
	w, h: i32
	_ = sdl.GetWindowSize(window, &w, &h)
	pw, ph: i32
	_ = sdl.GetWindowSizeInPixels(window, &pw, &ph)
	scale := kit_content_scale(window)
	kit_events_apply(app, scale)
	k.frame += 1
	d := &app.device
	in_ := ui.Input {
		mouse         = d.mouse / scale,
		mouse_valid   = d.over,
		down          = d.down,
		pressed       = d.pressed,
		released      = d.released,
		wheel         = d.wheel,
		shift         = d.shift,
		ctrl          = d.ctrl,
		alt           = d.alt,
		window        = [2]f32{f32(w), f32(h)} / scale,
		pixel_density = f32(pw) / f32(max(w, 1)) * scale,
		text          = string(d.text[:d.text_len]),
	}
	for key in d.keys {
		switch key.key {
		case sdl.K_BACKSPACE:                         in_.backspace += 1
		case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_ESCAPE: in_.text_end = true
		}
	}
	if safe: sdl.Rect; sdl.GetWindowSafeArea(window, &safe) {
		in_.safe = {f32(safe.x) / scale, f32(safe.y) / scale, f32(safe.w) / scale, f32(safe.h) / scale}
	}
	now := time.tick_now()
	in_.dt = f32(time.duration_seconds(time.tick_diff(k.last_frame, now)))
	k.last_frame = now
	k.scale = scale
	ui.frame_begin(&k.ctx, in_)
	return {w, h}, {pw, ph}
}

// Lays out the interface for this frame and returns what the viewport saw.
kit_frame :: proc(app: ^App, window: ^sdl.Window) -> Viewport_Input {
	start := time.tick_now()
	k := &app.kit
	// A text field that has the keys at the start of the frame takes them all, the Enter
	// or Escape that ends it too.
	typed := ui.typing(&k.ctx)
	size, pixels := kit_begin(app, window)
	// The viewport fills the window, pixel for pixel.
	app.ui.viewport_request = {f32(max(pixels.x, 1)), f32(max(pixels.y, 1))}

	ctx := &k.ctx
	// A new file note (saved, opened, refused) shows as a toast.
	if note := app.file_note; note.text != "" && note.at != k.note_at {
		k.note_at = note.at
		ui.toast(ctx, note.text, .Warning if note.warning else .Success)
	}
	ui.image(ctx, {0, 0, ctx.input.window.x, ctx.input.window.y}, KIT_VIEWPORT_IMAGE)
	k.layer = ui.layer_mark(ctx)
	kit_layout(app)
	input := kit_viewport_input(app, {f32(size.x), f32(size.y)})
	if !typed do handle_shortcuts(app)
	layer_drag_end(app)
	// Text input (and with it a tablet's on-screen keyboard) is on only while a text
	// field has the keys.
	if wanted := ui.typing(ctx); wanted != k.text_input {
		k.text_input = wanted
		_ = sdl.StartTextInput(window) if wanted else sdl.StopTextInput(window)
	}
	d := &app.device
	if !k.text_input && key_pressed(d, sdl.K_F11) do k.stats = !k.stats
	if !k.text_input && key_pressed(d, sdl.K_TAB) && !d.ctrl do k.inspector = !k.inspector
	// Escape, or Android's back gesture (the AC Back key), closes whatever floats, before
	// Escape stops a replay.
	if key_pressed(d, sdl.K_ESCAPE) || key_pressed(d, sdl.K_AC_BACK) {
		k.menu, k.view_menu, k.browser, k.object_menu = false, false, false, false
		ctx.select_open = 0
	}
	k.ms = time.duration_milliseconds(time.tick_since(start))
	return input
}

// What the viewport saw: everything the panels did not take.
@(private = "file")
kit_viewport_input :: proc(app: ^App, size: [2]f32) -> (input: Viewport_Input) {
	k := &app.kit
	d := &app.device
	input.size = size
	input.hovered = d.over && !ui.wants_pointer(&k.ctx)
	input.dragging = ui.viewport_dragging(&k.ctx)
	input.mouse_pos = d.mouse
	input.samples = make([]Input_Sample, len(app.samples), context.temp_allocator)
	copy(input.samples, app.samples[:])
	input.pen_tilt = app.pen_tilt
	input.mouse_delta = d.moved
	if input.hovered || input.dragging do input.wheel = d.wheel
	// A right press let go soon and about where it began is a tap, which opens the brush
	// pie, rather than an orbit.
	right_tap := input.dragging && d.right_tap && !d.shift
	// A press and its release can both come in one frame (a tap, or a click during a slow
	// frame): the press still holds for this frame, and the release among the samples
	// ends what it began; the next frame sees the button up.
	left := .Left in d.down || .Left in d.pressed
	right, middle := .Right in d.down, .Middle in d.down
	if input.dragging {
		input.orbit_drag = (right && !d.shift) || (left && d.alt && !d.ctrl)
		input.pan_drag = middle || (right && d.shift)
		input.primary = left && (!d.alt || d.ctrl)
		input.alt = input.primary && d.alt
		input.press = input.primary && .Left in d.pressed
		input.smooth = input.primary && d.shift
		input.invert = input.primary && d.ctrl
	}
	pie_update(app, &input, right_tap)
	adjust_update(app, &input)
	app.ui.viewport_mouse, app.ui.viewport_size, app.ui.viewport_hovered = input.mouse_pos, input.size, input.hovered
	return
}


@(private = "file")
kit_layout :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	E := t.edge
	bar := ui.Box{direction = .Row, radius = t.radius_large, background = .Panel, center = true}

	// Top left: the menu, then undo and redo.
	menu_anchor, view_anchor: ui.Rect
	ui.begin_anchored(ctx, "top left", .Start, .Start, {E, E}, {direction = .Row, gap = 8})
	ui.begin(ctx, "menu bar", bar)
	if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) do k.menu = !k.menu
	menu_anchor = ctx.last_rect
	ui.end(ctx)
	ui.begin(ctx, "history", bar)
	undo := fmt.tprintf("Undo %s##undo", history_next_label(app.history.done[:]))
	redo := fmt.tprintf("Redo %s##redo", history_next_label(app.history.undone[:]))
	if ui.icon_button(ctx, undo, ui.ICON_UNDO, enabled = history_can_undo(app), keys = "Ctrl+Z") do history_undo(app)
	if ui.icon_button(ctx, redo, ui.ICON_REDO, enabled = history_can_redo(app), keys = "Ctrl+Shift+Z") do history_redo(app)
	if ui.icon_button(ctx, "History", ui.ICON_HISTORY, selected = k.history) do k.history = !k.history
	ui.end(ctx)
	ui.end(ctx)

	// Top middle: the tool, then symmetry (any mix of the three axes).
	ui.begin_anchored(ctx, "tools", .Center, .Start, {0, E}, bar)
	ui.spacer(ctx, 6)
	// In Tool's order: W, B, C and I pick them from the keyboard.
	tool_names := [len(Tool)]string{"Move", "Sculpt", "Curve", "Insert"}
	tool_icons := [len(Tool)]rune{ui.ICON_MOVE, ui.ICON_BRUSH, ui.ICON_SPLINE, ui.ICON_SHAPES}
	if picked := ui.tabs(ctx, "tool", tool_names[:], int(app.tool), accent = true, glyphs = tool_icons[:]); picked >= 0 do app.tool = Tool(picked)
	ui.spacer(ctx, 2)
	ui.divider(ctx)
	ui.spacer(ctx, 2)
	for axis in sculpt.Axis {
		name := fmt.tprint(axis)
		tip := fmt.tprintf("Symmetry across %s", name)
		if ui.toggle_button(ctx, name, axis in app.brush.symmetry, 40, "X" if axis == .X else "", tip) do app.brush.symmetry ~= {axis}
	}
	ui.spacer(ctx, 6)
	ui.end(ctx)

	// Top right: view options and the inspector.
	ui.begin_anchored(ctx, "top right", .End, .Start, {E, E}, bar)
	if ui.icon_button(ctx, "View", ui.ICON_EYE, selected = k.view_menu) do k.view_menu = !k.view_menu
	view_anchor = ctx.last_rect
	if ui.icon_button(ctx, "Inspector", ui.ICON_PANEL, selected = k.inspector, keys = "Tab") do k.inspector = !k.inspector
	ui.end(ctx)

	// Left edge: size and strength, for a thumb or a pen.
	ui.begin_anchored(ctx, "sliders", .Start, .Center, {E, 0}, {direction = .Row, gap = 0})
	_ = ui.vslider(ctx, "Brush size", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f", app.brush.radius_px), ui.ICON_SIZE, "S, [ ]")
	strength := brush_strength(app)
	_ = ui.vslider(ctx, "Brush strength", strength, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", strength^), ui.ICON_STRENGTH, "U, Shift+[ ]")
	ui.end(ctx)

	// Bottom middle: the brush dock.
	browser_anchor: ui.Rect
	ui.begin_anchored(ctx, "dock", .Center, .End, {0, E}, {direction = .Row, gap = 0, padding = 4, radius = t.radius_large + 4, background = .Panel, center = true})
	for kind in KIT_DOCK {
		if ui.brush_tile(ctx, BRUSH_NAMES[kind], KIT_BRUSH_ICONS[kind], app.brush.kind == kind && app.tool == .Brush, kit_brush_keys(kind)) do kit_pick_brush(app, kind)
	}
	ui.divider(ctx, 32)
	in_dock := false
	for kind in KIT_DOCK do in_dock ||= kind == app.brush.kind
	if ui.icon_button(ctx, "All brushes", ui.ICON_GRID, selected = k.browser || (!in_dock && app.tool == .Brush), size = 58) do k.browser = !k.browser
	browser_anchor = ctx.last_rect
	ui.end(ctx)
	dock_size, _ := ui.prev_layout(ctx, "dock")
	ctx.toast_bottom = E + dock_size.y + 12

	// Bottom right: what is being sculpted.
	if obj := selected_object(app); obj != nil {
		ui.begin_anchored(ctx, "status", .End, .End, {E, E}, {direction = .Row, gap = 10, padding = 10, radius = t.radius_large, background = .Panel, center = true})
		ui.label(ctx, object_label(obj), t.small_size, t.text, .Semibold)
		ui.label(ctx, fmt.tprintf("%s vertices", count_label(object_vertex_count(obj))), t.small_size)
		if n := len(obj.levels.levels); n > 1 do ui.label(ctx, fmt.tprintf("Level %d/%d", obj.levels.current + 1, n), t.small_size)
		if object_dynamic(obj) do ui.label(ctx, "Dynamic", t.small_size, t.accent)
		if object_in_hd(obj) do ui.label(ctx, "HD", t.small_size, t.accent)
		ui.end(ctx)
	}

	kit_inspector(app)
	kit_stats(app)
	kit_history_panel(app)

	// What floats over the panels comes last, so it is drawn and hit tested on top.
	if ui.popover_begin(ctx, "brush browser", &k.browser, browser_anchor, .Above_Center, {direction = .Column, gap = 2, padding = 10}) {
		ui.caption(ctx, "BRUSHES")
		row := 0
		PER_ROW :: 5
		for kind, i in sculpt.Brush_Kind {
			if i % PER_ROW == 0 do ui.begin(ctx, fmt.tprintf("row %d", row), {direction = .Row, gap = 0})
			if ui.brush_tile(ctx, BRUSH_NAMES[kind], KIT_BRUSH_ICONS[kind], app.brush.kind == kind && app.tool == .Brush, kit_brush_keys(kind)) {
				kit_pick_brush(app, kind)
				k.browser = false
			}
			if i % PER_ROW == PER_ROW - 1 || i == len(sculpt.Brush_Kind) - 1 {
				ui.end(ctx)
				row += 1
			}
		}
		ui.popover_end(ctx)
	}
	kit_menu(app, menu_anchor)
	kit_view_menu(app, view_anchor)
	kit_object_menu(app)
}

// The shortcut that picks `kind`, if it has one: 1 to 9 and 0 in Brush_Kind's order.
@(private = "file")
kit_brush_keys :: proc(kind: sculpt.Brush_Kind) -> string {
	i := int(kind)
	if i >= 10 do return ""
	return fmt.tprintf("%d", (i + 1) % 10)
}

@(private = "file")
kit_pick_brush :: proc(app: ^App, kind: sculpt.Brush_Kind) {
	app.brush.kind = kind
	app.tool = .Brush
}

// The inspector: the tool, the selected object or the scene, in tabs, sliding in from
// the right. When its content is taller than the room it scrolls, with the wheel or by
// a drag that starts where no control takes it (a finger or a pen has no wheel).
@(private = "file")
kit_inspector :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "inspector")
	shown := ui.presence(ctx, id, k.inspector, t.panel_time)
	if shown <= 0 do return
	top := t.edge + t.target + 8
	area := ui.safe_area(ctx)
	window := [2]f32{area.w, area.h}
	dock_size, _ := ui.prev_layout(ctx, "dock")
	room := window.y - top - t.edge
	// Clear of what sits below it: the object's status at the bottom right, and the dock
	// when the window is narrow enough for them to meet.
	below: f32 = 0
	if status, _ := ui.prev_layout(ctx, "status"); status.y > 0 do below = status.y + 8
	if window.x * 0.5 + dock_size.x * 0.5 + 8 > window.x - t.edge - KIT_INSPECTOR_W do below = max(below, dock_size.y + 8)
	room -= below
	size, natural := ui.prev_layout(ctx, "inspector")
	_ = size
	height := min(natural.y, room) if natural.y > 0 else 0
	// The wheel over the inspector scrolls it; the scroll eases to where it is heading.
	limit := max(natural.y - room, 0)
	inspector_rect := ui.Rect{area.x + window.x - t.edge - KIT_INSPECTOR_W, area.y + top, KIT_INSPECTOR_W, height}
	if ctx.input.wheel != 0 && ui.rect_contains(inspector_rect, ctx.input.mouse) do k.scroll -= ctx.input.wheel * 64
	if k.scroll_drag {
		if .Left in ctx.input.down {
			k.scroll = k.scroll_from - ctx.input.mouse.y
		} else {
			k.scroll_drag = false
		}
	}
	k.scroll = clamp(k.scroll, 0, limit)
	// A drag follows the finger exactly; the wheel's steps ease.
	scroll := ui.tween(ctx, ui.salt(id, 5), k.scroll, 0 if k.scroll_drag else t.popover_time, .Out_Quart)

	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "inspector", .End, .Start, {t.edge, top}, {direction = .Column, gap = 6, padding = 12, width = KIT_INSPECTOR_W, height = height, radius = t.radius_large, background = .Panel, clip = true, scroll = scroll, inert = !k.inspector})
	tab_names := [len(Kit_Tab)]string{kit_tool_name(app.tool), "Object", "Scene"}
	if picked := ui.tabs(ctx, "inspector tabs", tab_names[:], int(k.tab)); picked >= 0 {
		if Kit_Tab(picked) != k.tab do k.tab_serial += 1
		k.tab = Kit_Tab(picked)
		k.scroll = 0
	}
	ui.spacer(ctx, 4)
	// A new tab's content fades in: each change starts a tween of its own from 0.
	content := ui.vertex_mark(ctx)
	switch k.tab {
	case .Tool:   kit_tool_tab(app)
	case .Object: kit_object_tab(app)
	case .Scene:  kit_scene_tab(app)
	}
	fade := ui.tween_from(ctx, ui.salt(id, 1000 + k.tab_serial), 0, 1, t.indicator_time)
	ui.transform_since(ctx, content, fade)
	ui.end(ctx)
	// A press on the inspector that no control took starts a scroll drag.
	if .Left in ctx.input.pressed && ctx.active == 0 && ctx.pointer_root == id && limit > 0 {
		k.scroll_drag, k.scroll_from = true, k.scroll + ctx.input.mouse.y
	}
	// A thin scroll bar when the content is taller than the room, showing where it is.
	if limit > 0 && height > 0 {
		r := inspector_rect
		track := height - 24
		thumb := max(track * height / natural.y, 24)
		y := r.y + 12 + (track - thumb) * (scroll / limit)
		ui.fill_rect(ctx, {r.x + r.w - 6, y, 3, thumb}, 1.5, ui.color_fade(t.text_tertiary, 0.6))
	}
	ui.transform_since(ctx, mark, shown, 1, {}, {(1 - shown) * 16, 0})
}

// SPHERE_PRESETS' labels as strings, for selects.
kit_size_names :: proc() -> []string {
	names := make([]string, len(SPHERE_PRESETS), context.temp_allocator)
	for p, i in SPHERE_PRESETS do names[i] = fmt.tprintf("%s vertices", p.label)
	return names
}

// The menu under the menu button: files, and the app's own settings.
@(private = "file")
kit_menu :: proc(app: ^App, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	if !ui.popover_begin(ctx, "menu", &k.menu, anchor, .Below, {direction = .Column, padding = 6, width = 268}) do return
	pick := false
	ui.caption(ctx, "  FILE")
	if ui.menu_item(ctx, "Open scene...", "Ctrl+O", ui.ICON_OPEN) {
		file_dialog(app, .Open)
		pick = true
	}
	if ui.menu_item(ctx, "Save scene", "Ctrl+S", ui.ICON_SAVE) {
		save_scene(app)
		pick = true
	}
	if ui.menu_item(ctx, "Save scene as...", "Ctrl+Shift+S") {
		file_dialog(app, .Save)
		pick = true
	}
	if ui.menu_item(ctx, "Import mesh...", "", ui.ICON_IMPORT) {
		file_dialog(app, .Import)
		pick = true
	}
	if ui.menu_item(ctx, "Export mesh...", "", ui.ICON_EXPORT, enabled = selected_object(app) != nil) {
		file_dialog(app, .Export)
		pick = true
	}
	if ui.menu_item(ctx, "Save screenshot...", "F12", ui.ICON_IMAGE) {
		file_dialog(app, .Screenshot)
		pick = true
	}
	ui.divider(ctx, across = true)
	ui.caption(ctx, "  APP")
	if ui.menu_item(ctx, "Reduce motion", checked = ctx.reduced_motion) do ctx.reduced_motion = !ctx.reduced_motion
	// Off, one finger turns the view and only the pen sculpts, as on a drawing tablet.
	if ui.menu_item(ctx, "Finger sculpts", checked = app.touch.finger_sculpt) do app.touch.finger_sculpt = !app.touch.finger_sculpt
	if ui.menu_item(ctx, "Stats", "F11", ui.ICON_ACTIVITY, checked = k.stats) do k.stats = !k.stats
	ui.popover_end(ctx)
	if pick do k.menu = false
}

// How the viewport shows the scene.
@(private = "file")
kit_view_menu :: proc(app: ^App, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	if !ui.popover_begin(ctx, "view menu", &k.view_menu, anchor, .Below_End, {direction = .Column, padding = 6, width = 268}) do return
	ui.caption(ctx, "  SHADING")
	if ui.menu_item(ctx, "Wireframe", "Shift+F", checked = app.wireframe) do app.wireframe = !app.wireframe
	if ui.menu_item(ctx, "Flat shading", "Shift+G", checked = app.flat) do app.flat = !app.flat
	if ui.menu_item(ctx, "Polygroups", "Shift+W", checked = app.show_groups) do app.show_groups = !app.show_groups
	if ui.menu_item(ctx, "Studio render", "Shift+R", checked = app.studio_on) do studio_toggle(app)
	ui.divider(ctx, across = true)
	ui.caption(ctx, "  CAMERA")
	if ui.menu_item(ctx, "Orthographic", "P", checked = app.camera.ortho) do app.camera.ortho = !app.camera.ortho
	if ui.menu_item(ctx, "Focus selected", "F", ui.ICON_FOCUS, enabled = selected_object(app) != nil) {
		focus_selected(app)
		k.view_menu = false
	}
	if ui.menu_item(ctx, "Reset camera", "", ui.ICON_SUN) {
		reset_camera(app)
		k.view_menu = false
	}
	ui.popover_end(ctx)
}

// The outliner's context menu, at the pointer.
@(private = "file")
kit_object_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	// The object it was opened on has gone (deleted, undone): the menu goes with it.
	found := false
	for obj in app.scene.objects do found ||= obj.id == k.object_menu_id
	if !found do k.object_menu = false
	if !ui.popover_begin(ctx, "object menu", &k.object_menu, k.object_menu_at, .Pointer, {direction = .Column, padding = 6, width = 232}) do return
	if ui.menu_item(ctx, "Focus", "F", ui.ICON_FOCUS) {
		focus_selected(app)
		k.object_menu = false
	}
	if ui.menu_item(ctx, "Duplicate", "Ctrl+Shift+D", ui.ICON_COPY) {
		app.ui.scene_command = {kind = .Duplicate}
		k.object_menu = false
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Delete", "Del", ui.ICON_TRASH, tone = .Danger) {
		app.ui.scene_command = {kind = .Delete}
		k.object_menu = false
	}
	ui.popover_end(ctx)
}

// The interface's draw commands for the renderer: the viewport's texture (or the
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

// Writes the whole window as the interface last drew it (the viewport, its overlay and
// the panels) to a PNG, or a PPM when the path ends in .ppm.
kit_screen_save :: proc(app: ^App, path: string, size: [2]u32) -> bool {
	k := &app.kit
	dl := &k.ctx.draw
	vertices := transmute([]render.Ui_Vertex)dl.vertices[:]
	atlas, aw, ah := ui.atlas_pixels(&k.ctx)
	t := KIT_CANVAS
	clear := [4]f32{f32(t.r) / 255, f32(t.g) / 255, f32(t.b) / 255, 1}
	pixels := render.ui_pass_capture(&app.renderer, &k.pass, size, clear, kit_draws(app, dl), vertices, dl.indices[:], atlas, {u32(aw), u32(ah)}, context.temp_allocator)
	if pixels == nil {
		file_note(app, true, "Could not read the screen back: %s", sdl.GetError())
		return false
	}
	return image_save(app, path, pixels, int(size.x), int(size.y))
}
