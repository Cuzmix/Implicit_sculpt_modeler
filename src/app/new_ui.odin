package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import imgui "deps:odin-imgui"
import sdl "vendor:sdl3"

import "../geom"
import "../render"
import "../sculpt"
import "../ui"

// The interface: one layout for every screen, drawn by the ui kit over a viewport that
// fills the window (the design spec "Sculpt UI redesign"). Toolbars float at the top,
// the inspector (brush, object and scene) on the right, size and strength on the left
// and the brush dock at the bottom. The classic ImGui panels (Menu > Classic panels)
// keep the tools not yet here; ImGui still draws the brush circle, the pie and, on F11,
// the Stats panel, styled to match.

// The inspector's tabs.
Kit_Tab :: enum u8 {
	Brush,
	Object,
	Scene,
}

Kit_State :: struct {
	ctx:        ui.Context,
	pass:       render.Ui_Pass,
	input:      ui.Input, // built up from this frame's events
	last_frame: time.Tick, // for the animations' clock
	inspector:  bool,
	tab:        Kit_Tab,
	tab_serial: u64, // counts tab changes, so each one fades its content in afresh
	menu:       bool,
	view_menu:  bool,
	browser:    bool, // every brush, in a popover over the dock
	stats:      bool, // the ImGui Stats panel over the viewport (F11)
	// The outliner's context menu: open, on which object, where.
	object_menu:    bool,
	object_menu_id: int,
	object_menu_at: ui.Rect,
	// Which inspector sections are open.
	open:       [Kit_Section]bool,
	scroll:     f32, // the inspector's scroll, where it is heading
	add_shape:  geom.Primitive,
	add_size:   int, // into SPHERE_PRESETS
	note_at:    time.Tick, // the file note last shown as a toast
	frame:      int, // frames drawn, for --ui-events
	events:     [dynamic]Kit_Event, // --ui-events, in frame order
	ms:         f64, // last frame's layout and tessellation, CPU
}

Kit_Section :: enum u8 {
	Stroke,
	Falloff,
	Options,
	Alpha,
	Levels,
	Topology,
	Mask,
	Remesh,
	Add,
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

// Applies this frame's scripted events to the kit's input, as SDL events would.
@(private = "file")
kit_events_apply :: proc(k: ^Kit_State) {
	in_ := &k.input
	for ev in k.events {
		if ev.frame != k.frame do continue
		switch ev.kind {
		case .Move:
			in_.mouse, in_.mouse_valid = ev.at, true
		case .Down:
			in_.pressed += {.Left}
			in_.down += {.Left}
		case .Up:
			in_.released += {.Left}
			in_.down -= {.Left}
		case .Right:
			in_.pressed += {.Right}
			in_.released += {.Right}
		case .Wheel:
			in_.wheel += ev.wheel
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
	k.open = {.Stroke = true, .Falloff = true, .Options = true, .Alpha = false, .Levels = true, .Topology = false, .Mask = true, .Remesh = false, .Add = true}
	k.add_size = 2 // 1M
	k.last_frame = time.tick_now()
}

kit_destroy :: proc(app: ^App) {
	delete(app.kit.events)
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
	kit_events_apply(k)
	k.frame += 1
	in_ := k.input
	in_.window = {f32(w), f32(h)}
	in_.pixel_density = f32(pw) / f32(max(w, 1))
	in_.shift, in_.ctrl, in_.alt = io.KeyShift, io.KeyCtrl, io.KeyAlt
	now := time.tick_now()
	in_.dt = f32(time.duration_seconds(time.tick_diff(k.last_frame, now)))
	k.last_frame = now
	// The viewport fills the window, pixel for pixel.
	app.ui.viewport_request = {f32(max(pw, 1)), f32(max(ph, 1))}

	ctx := &k.ctx
	ui.frame_begin(ctx, in_)
	// A new file note (saved, opened, refused) shows as a toast.
	if note := app.file_note; note.text != "" && note.at != k.note_at {
		k.note_at = note.at
		ui.toast(ctx, note.text, .Warning if note.warning else .Success)
	}
	ui.image(ctx, {0, 0, in_.window.x, in_.window.y}, KIT_VIEWPORT_IMAGE)
	kit_layout(app)
	input := kit_viewport_input(app, in_.window)
	if k.stats do draw_stats_panel(app)
	handle_shortcuts(app)
	if imgui.IsKeyPressed(.F11, false) do k.stats = !k.stats
	if !io.WantTextInput && imgui.IsKeyPressed(.Tab, false) && !io.KeyCtrl do k.inspector = !k.inspector
	// Escape closes whatever floats, before it stops a replay.
	if imgui.IsKeyPressed(.Escape, false) {
		k.menu, k.view_menu, k.browser, k.object_menu = false, false, false, false
		ctx.select_open = 0
	}

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
	if ui.icon_button(ctx, "Undo", ui.ICON_UNDO, enabled = history_can_undo(app), keys = "Ctrl+Z") do history_undo(app)
	if ui.icon_button(ctx, "Redo", ui.ICON_REDO, enabled = history_can_redo(app), keys = "Ctrl+Shift+Z") do history_redo(app)
	ui.end(ctx)
	ui.end(ctx)

	// Top middle: the tool, then symmetry (any mix of the three axes).
	ui.begin_anchored(ctx, "tools", .Center, .Start, {0, E}, bar)
	ui.spacer(ctx, 6)
	tool_index := 0 if app.tool == .Move else 1
	if app.tool == .Brush || app.tool == .Move {
		tool_names := [2]string{"Move", "Sculpt"}
		tool_icons := [2]rune{ui.ICON_MOVE, ui.ICON_BRUSH}
		if picked := ui.tabs(ctx, "tool", tool_names[:], tool_index, accent = true, glyphs = tool_icons[:]); picked >= 0 {
			app.tool = .Move if picked == 0 else .Brush
		}
	} else {
		// Curve and Insert live in the classic panels; show which is on and a way back.
		other := [1]string{"Curve" if app.tool == .Curve else "Insert"}
		if ui.tabs(ctx, "tool other", other[:], 0, accent = true) >= 0 do app.tool = .Brush
	}
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

// The inspector: the brush, the selected object or the scene, in tabs, sliding in from
// the right. It scrolls with the wheel when its content is taller than the window.
@(private = "file")
kit_inspector :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "inspector")
	shown := ui.presence(ctx, id, k.inspector, t.panel_time)
	if shown <= 0 do return
	top := t.edge + t.target + 8
	window := ctx.input.window
	dock_size, _ := ui.prev_layout(ctx, "dock")
	room := window.y - top - t.edge
	// Clear of the dock when the window is narrow enough for them to meet.
	if window.x * 0.5 + dock_size.x * 0.5 + 8 > window.x - t.edge - KIT_INSPECTOR_W do room -= dock_size.y + 8
	size, natural := ui.prev_layout(ctx, "inspector")
	_ = size
	height := min(natural.y, room) if natural.y > 0 else 0
	// The wheel over the inspector scrolls it; the scroll eases to where it is heading.
	limit := max(natural.y - room, 0)
	inspector_rect := ui.Rect{window.x - t.edge - KIT_INSPECTOR_W, top, KIT_INSPECTOR_W, height}
	if ctx.input.wheel != 0 && ui.rect_contains(inspector_rect, ctx.input.mouse) do k.scroll -= ctx.input.wheel * 64
	k.scroll = clamp(k.scroll, 0, limit)
	scroll := ui.tween(ctx, ui.salt(id, 5), k.scroll, t.popover_time, .Out_Quart)

	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "inspector", .End, .Start, {t.edge, top}, {direction = .Column, gap = 6, padding = 12, width = KIT_INSPECTOR_W, height = height, radius = t.radius_large, background = .Panel, clip = true, scroll = scroll, inert = !k.inspector})
	tab_names := [len(Kit_Tab)]string{"Brush", "Object", "Scene"}
	if picked := ui.tabs(ctx, "inspector tabs", tab_names[:], int(k.tab)); picked >= 0 {
		if Kit_Tab(picked) != k.tab do k.tab_serial += 1
		k.tab = Kit_Tab(picked)
		k.scroll = 0
	}
	ui.spacer(ctx, 4)
	// A new tab's content fades in: each change starts a tween of its own from 0.
	content := ui.vertex_mark(ctx)
	switch k.tab {
	case .Brush:  kit_brush_tab(app)
	case .Object: kit_object_tab(app)
	case .Scene:  kit_scene_tab(app)
	}
	fade := ui.tween_from(ctx, ui.salt(id, 1000 + k.tab_serial), 0, 1, t.indicator_time)
	ui.transform_since(ctx, content, fade)
	ui.end(ctx)
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

@(private = "file")
kit_brush_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	kind := app.brush.kind
	ui.begin(ctx, "brush head", {direction = .Row, gap = 10, center = true})
	ui.begin(ctx, "brush badge", {width = 36, height = 36, radius = t.radius_medium, background = .Track})
	ui.end(ctx)
	r := ctx.last_rect
	ui.icon(ctx, KIT_BRUSH_ICONS[kind], {r.x + 18, r.y + 18}, t.icon_size, t.accent)
	ui.label(ctx, BRUSH_NAMES[kind], t.heading_size, t.text, .Semibold)
	ui.end(ctx)
	help, _ := strings.replace_all(string(BRUSH_HELP[kind]), "\n", " ", context.temp_allocator)
	ui.paragraph(ctx, help)
	ui.spacer(ctx, 4)

	if ui.section(ctx, "Stroke", &k.open[.Stroke]) {
		_ = ui.slider(ctx, "Size", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
		s := brush_strength(app)
		_ = ui.slider(ctx, "Strength", s, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", s^))
		_ = ui.slider(ctx, "Lazy mouse", &app.brush.lazy_px, 0, 150, .Linear, "off" if app.brush.lazy_px < 0.5 else fmt.tprintf("%.0f px", app.brush.lazy_px))
		strokes := [2]string{"Dots", "Drag rectangle"}
		if picked := ui.tabs(ctx, "stroke kind", strokes[:], 0 if app.brush.stroke == .Dots else 1); picked >= 0 {
			app.brush.stroke = .Dots if picked == 0 else .Drag_Rect
		}
		if kind == .Cloth {
			modes: [len(sculpt.Cloth_Mode)]string
			for m, i in sculpt.Cloth_Mode do modes[i] = string(CLOTH_MODE_NAMES[m])
			if picked := ui.tabs(ctx, "cloth mode", modes[:], int(app.brush.cloth_mode)); picked >= 0 do app.brush.cloth_mode = sculpt.Cloth_Mode(picked)
		}
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Falloff", &k.open[.Falloff]) {
		shape := &app.brush.falloffs[kind]
		names: [len(FALLOFF_PRESETS)]string
		chosen := -1
		for p, i in FALLOFF_PRESETS {
			names[i] = string(p.label)
			if shape.drawn == p.drawn && (!p.drawn || shape.curve == p.curve) do chosen = i
		}
		if picked := ui.tabs(ctx, "falloff", names[:], chosen); picked >= 0 {
			p := FALLOFF_PRESETS[picked]
			shape^ = {drawn = p.drawn, curve = p.curve}
		}
		if chosen < 0 do ui.paragraph(ctx, "A drawn curve (edit it in the classic Tools panel).")
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Alpha", &k.open[.Alpha]) {
		names := make([]string, len(app.alphas) + 1, context.temp_allocator)
		names[0] = "Round (no alpha)"
		for a, i in app.alphas do names[i + 1] = a.name
		chosen := app.brush.alpha + 1 if app.brush.alpha >= 0 && app.brush.alpha < len(app.alphas) else 0
		if picked := ui.select(ctx, "alpha", names, chosen); picked >= 0 do app.brush.alpha = picked - 1
		if brush_alpha(app) != nil {
			modes: [len(Alpha_Mode)]string
			for m, i in Alpha_Mode do modes[i] = ALPHA_MODE_NAMES[m]
			if picked := ui.tabs(ctx, "alpha mode", modes[:], int(app.brush.alpha_mode)); picked >= 0 do app.brush.alpha_mode = Alpha_Mode(picked)
			_ = ui.slider(ctx, "Angle", &app.brush.alpha_angle, -180, 180, .Linear, fmt.tprintf("%.0f°", app.brush.alpha_angle))
		}
		if ui.button(ctx, "Load image...", .Bordered, glyph = ui.ICON_IMAGE) do file_dialog(app, .Alpha)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Options", &k.open[.Options]) {
		_ = ui.switch_row(ctx, "Front faces only", &app.brush.front_only)
		_ = ui.switch_row(ctx, "Pressure changes size", &app.brush.pressure_size)
		_ = ui.switch_row(ctx, "Pressure changes strength", &app.brush.pressure_strength)
		ui.section_end(ctx)
	}
}

@(private = "file")
kit_object_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	obj := selected_object(app)
	if obj == nil {
		ui.spacer(ctx, 12)
		ui.label(ctx, "No object selected", t.title_size, t.text, .Semibold)
		ui.paragraph(ctx, "Click an object in the viewport with Move, or pick one in the Scene tab.")
		return
	}
	ui.label(ctx, object_label(obj), t.heading_size, t.text, .Semibold)
	ui.paragraph(ctx, fmt.tprintf("%s vertices, %s triangles", count_label(object_vertex_count(obj)), count_label(object_triangle_count(obj))))
	ui.spacer(ctx, 4)

	if ui.section(ctx, "Subdivision levels", &k.open[.Levels]) {
		levels := &obj.levels
		count := len(levels.levels)
		dyntopo := object_dynamic(obj)
		ui.label(ctx, fmt.tprintf("Level %d of %d", levels.current + 1, count), t.text_size, t.text, .Semibold)
		half := (ui.fill_width(ctx) - 8) * 0.5
		ui.begin(ctx, "level steps", {direction = .Row, gap = 8})
		if ui.button(ctx, "Lower##level", .Flat, width = half, enabled = levels.current > 0) do app.ui.scene_command = {kind = .Set_Level, level = levels.current - 1}
		if ui.button(ctx, "Higher##level", .Flat, width = half, enabled = levels.current < count - 1) do app.ui.scene_command = {kind = .Set_Level, level = levels.current + 1}
		ui.end(ctx)
		vertices, _, bytes := sculpt.levels_subdivide_estimate(levels)
		can := count < sculpt.MAX_LEVELS && bytes <= MAX_SUBDIVIDE_BYTES && levels.hd.steps == 0 && !dyntopo
		if ui.button(ctx, "Subdivide", .Solid, .Accent, glyph = ui.ICON_PLUS, enabled = can) do app.ui.scene_command = {kind = .Subdivide}
		if dyntopo {
			ui.paragraph(ctx, "Turn dynamic topology off to subdivide.")
		} else if can {
			ui.paragraph(ctx, fmt.tprintf("Adds a level of %s vertices, about %s.  Ctrl+D", count_label(vertices), bytes_label(bytes)))
		}
		ui.begin(ctx, "level deletes", {direction = .Row, gap = 8})
		if ui.button(ctx, "Delete lower", .Light, .Danger, width = half, enabled = levels.current > 0) do app.ui.scene_command = {kind = .Delete_Lower}
		if ui.button(ctx, "Delete higher", .Light, .Danger, width = half, enabled = levels.current < count - 1) do app.ui.scene_command = {kind = .Delete_Higher}
		ui.end(ctx)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Dynamic topology", &k.open[.Topology]) {
		on := object_dynamic(obj)
		can := len(obj.levels.levels) == 1 && obj.levels.hd.steps == 0
		if ui.switch_row(ctx, "Dynamic topology", &on, enabled = can) do app.ui.scene_command = {kind = .Dyntopo, on = on}
		if !can do ui.paragraph(ctx, "Needs a single subdivision level and no HD level.")
		_ = ui.slider(ctx, "Detail", &app.brush.detail_px, 2, 40, .Logarithmic, fmt.tprintf("%.1f px", app.brush.detail_px))
		_ = ui.switch_row(ctx, "Collapse short edges", &app.brush.collapse)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Mask", &k.open[.Mask]) {
		commands := [?]sculpt.Mask_Command{.Clear, .Invert, .Fill, .Cavity, .Blur, .Sharpen, .Grow, .Shrink}
		labels := [?]string{"Clear", "Invert", "Mask all", "Cavities", "Blur", "Sharpen", "Grow", "Shrink"}
		half := (ui.fill_width(ctx) - 8) * 0.5
		for i := 0; i < len(commands); i += 2 {
			ui.begin(ctx, fmt.tprintf("mask row %d", i), {direction = .Row, gap = 8})
			for j in i ..< i + 2 {
				if ui.button(ctx, labels[j], .Flat, width = half) do mask_command(app, commands[j])
			}
			ui.end(ctx)
		}
		steps := f32(app.ui.mask_steps)
		if ui.slider(ctx, "Steps", &steps, 1, 50, .Linear, fmt.tprintf("%d", app.ui.mask_steps)) do app.ui.mask_steps = i32(steps + 0.5)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Remesh", &k.open[.Remesh]) {
		sizes := kit_size_names()
		if picked := ui.select(ctx, "remesh size", sizes, k.add_size); picked >= 0 do k.add_size = picked
		vertices := int(SPHERE_PRESETS[k.add_size].vertices)
		half := (ui.fill_width(ctx) - 8) * 0.5
		ui.begin(ctx, "remesh row", {direction = .Row, gap = 8})
		if ui.button(ctx, "Remesh", .Flat, .Accent, width = half) do app.ui.scene_command = {kind = .Remesh, vertices = vertices}
		if ui.button(ctx, "Decimate", .Flat, width = half) do app.ui.scene_command = {kind = .Decimate, vertices = vertices}
		ui.end(ctx)
		ui.paragraph(ctx, "Rebuilds the object as an even mesh of this many vertices that keeps its shape (Ctrl+R: at its own count). Ctrl+Z brings levels and mask back.")
		ui.section_end(ctx)
	}
}

// SPHERE_PRESETS' labels as strings, for selects.
@(private = "file")
kit_size_names :: proc() -> []string {
	names := make([]string, len(SPHERE_PRESETS), context.temp_allocator)
	for p, i in SPHERE_PRESETS do names[i] = fmt.tprintf("%s vertices", p.label)
	return names
}

@(private = "file")
kit_scene_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.caption(ctx, fmt.tprintf("OBJECTS  %d", len(app.scene.objects)))
	for obj, i in app.scene.objects {
		name := fmt.tprintf("%s##%d", object_label(obj), obj.id)
		row := ui.list_row(ctx, name, count_label(object_vertex_count(obj)), i == app.scene.selected, ui.ICON_FRAME)
		if row.clicked do app.scene.selected = i
		if row.menu {
			app.scene.selected = i
			k.object_menu = true
			k.object_menu_id = obj.id
			k.object_menu_at = {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}
		}
	}
	if len(app.scene.objects) == 0 do ui.paragraph(ctx, "The scene is empty. Add a shape below or open a scene from the menu.")
	half := (ui.fill_width(ctx) - 8) * 0.5
	ui.begin(ctx, "object actions", {direction = .Row, gap = 8})
	has := selected_object(app) != nil
	if ui.button(ctx, "Duplicate", .Flat, width = half, glyph = ui.ICON_COPY, enabled = has) do app.ui.scene_command = {kind = .Duplicate}
	if ui.button(ctx, "Delete", .Flat, .Danger, width = half, glyph = ui.ICON_TRASH, enabled = has) do app.ui.scene_command = {kind = .Delete}
	ui.end(ctx)
	ui.spacer(ctx, 4)
	if ui.section(ctx, "Add object", &k.open[.Add]) {
		shapes: [len(geom.Primitive)]string
		for s, i in geom.Primitive do shapes[i] = fmt.tprint(s)
		if picked := ui.select(ctx, "add shape", shapes[:], int(k.add_shape)); picked >= 0 do k.add_shape = geom.Primitive(picked)
		sizes := kit_size_names()
		if picked := ui.select(ctx, "add size", sizes, k.add_size); picked >= 0 do k.add_size = picked
		vertices := int(SPHERE_PRESETS[k.add_size].vertices)
		if ui.button(ctx, fmt.tprintf("Add %v", k.add_shape), .Solid, .Accent, glyph = ui.ICON_PLUS) do app.ui.scene_command = {kind = .Add, vertices = vertices, shape = k.add_shape}
		ui.section_end(ctx)
	}
	_ = t
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
	if ui.menu_item(ctx, "Stats", "F11", ui.ICON_ACTIVITY, checked = k.stats) do k.stats = !k.stats
	if ui.menu_item(ctx, "Classic panels", "", ui.ICON_SETTINGS) {
		app.new_ui = false
		pick = true
	}
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
	t := KIT_CANVAS
	clear := [4]f32{f32(t.r) / 255, f32(t.g) / 255, f32(t.b) / 255, 1}
	pixels := render.ui_pass_capture(&app.renderer, &k.pass, size, clear, kit_draws(app, dl), vertices, dl.indices[:], atlas, {u32(aw), u32(ah)}, context.temp_allocator)
	if pixels == nil {
		file_note(app, true, "Could not read the screen back: %s", sdl.GetError())
		return false
	}
	return image_save(app, path, pixels, int(size.x), int(size.y))
}
