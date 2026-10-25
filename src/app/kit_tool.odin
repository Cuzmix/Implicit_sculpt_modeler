package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The inspector's first tab: the tool in use, and everything that sets it up.

// The tab's name, after the tool it shows.
kit_tool_name :: proc(tool: Tool) -> string {
	switch tool {
	case .Brush:  return "Brush"
	case .Move:   return "Move"
	case .Curve:  return "Curve"
	case .Insert: return "Insert"
	}
	return ""
}

kit_tool_tab :: proc(app: ^App) {
	switch app.tool {
	case .Brush:  kit_brush_tab(app)
	case .Move:   kit_move_tab(app)
	case .Curve:  kit_curve_tab(app)
	case .Insert: kit_insert_tab(app)
	}
}

// The tab's heading: an icon on a badge, a title, and a line of help under them.
kit_tool_head :: proc(ctx: ^ui.Context, glyph: rune, title, help: string) {
	t := ctx.theme
	ui.begin(ctx, "tool head", {direction = .Row, gap = 10, center = true})
	ui.begin(ctx, "tool badge", {width = 36, height = 36, radius = t.radius_medium, background = .Track})
	ui.end(ctx)
	r := ctx.last_rect
	ui.icon(ctx, glyph, {r.x + 18, r.y + 18}, t.icon_size, t.accent)
	ui.label(ctx, title, t.heading_size, t.text, .Semibold)
	ui.end(ctx)
	ui.paragraph(ctx, help)
	ui.spacer(ctx, 4)
}

@(private = "file")
kit_brush_tab :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	kind := app.brush.kind
	help, _ := strings.replace_all(string(BRUSH_HELP[kind]), "\n", " ", context.temp_allocator)
	kit_tool_head(ctx, KIT_BRUSH_ICONS[kind], BRUSH_NAMES[kind], help)

	if ui.section(ctx, "Stroke", &k.open[.Stroke]) {
		_ = ui.slider(ctx, "Size", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
		s := brush_strength(app)
		_ = ui.slider(ctx, "Strength", s, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", s^))
		_ = ui.slider(ctx, "Lazy mouse", &app.brush.lazy_px, 0, 150, .Linear, "off" if app.brush.lazy_px < 0.5 else fmt.tprintf("%.0f px", app.brush.lazy_px))
		strokes := [2]string{"Dots", "Drag rectangle"}
		if picked := ui.tabs(ctx, "stroke kind", strokes[:], 0 if app.brush.stroke == .Dots else 1); picked >= 0 {
			app.brush.stroke = .Dots if picked == 0 else .Drag_Rect
		}
		if app.brush.stroke == .Drag_Rect {
			ui.paragraph(ctx, "One stamp where the drag starts: its size is how far you drag and, with an alpha, its top faces the pointer. For placing alphas; not with dynamic topology, Grab or Snake hook.")
		}
		if kind == .Cloth {
			modes: [len(sculpt.Cloth_Mode)]string
			for m, i in sculpt.Cloth_Mode do modes[i] = string(CLOTH_MODE_NAMES[m])
			if picked := ui.tabs(ctx, "cloth mode", modes[:], int(app.brush.cloth_mode)); picked >= 0 do app.brush.cloth_mode = sculpt.Cloth_Mode(picked)
			cloth, _ := strings.replace_all(string(CLOTH_MODE_HELP[app.brush.cloth_mode]), "\n", " ", context.temp_allocator)
			ui.paragraph(ctx, cloth)
		}
		ui.paragraph(ctx, "S or U over the viewport sizes the brush or sets its strength there; [ and ] step the size, Shift with them the strength. Each brush keeps its own strength. Space, or a right click without dragging (a pen's side button), opens the brush pie.")
		ui.section_end(ctx)
	}
	if kind == .Paint && ui.section(ctx, "Colour", &k.open[.Paint_Color]) {
		_ = kit_color(ctx, "brush colour", &app.brush.color)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Falloff", &k.open[.Falloff]) {
		shape := &app.brush.falloffs[kind]
		smooth :: proc(x: f32) -> f32 {
			// The built-in falloff over how far in from the rim, as the curve is read.
			d := 1 - x
			return sculpt.falloff(d * d)
		}
		// Dragging a handle of the built-in shape starts a drawn one close to it.
		if !shape.drawn do shape.curve = FALLOFF_SMOOTH_CURVE
		if kit_curve_editor(ctx, "falloff curve", &shape.curve, &app.ui.falloff_handle, true, nil, nil if shape.drawn else smooth) do shape.drawn = true
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
		ui.paragraph(ctx, "The centre is on the left and the rim on the right. Drag a handle to draw your own; each brush keeps its own.")
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Alpha", &k.open[.Alpha]) {
		kit_alpha_section(app)
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Pen", &k.open[.Pen]) {
		_ = ui.switch_row(ctx, "Pressure changes strength", &app.brush.pressure_strength)
		_ = ui.switch_row(ctx, "Pressure changes size", &app.brush.pressure_size)
		dot: Maybe([2]f32)
		if app.pen_seen {
			x := clamp(app.pen_pressure, 0, 1)
			dot = [2]f32{x, pressure_curved(app, x)}
		}
		_ = kit_curve_editor(ctx, "pressure curve", &app.brush.pressure_curve, &app.ui.curve_handle, false, dot)
		names: [len(PRESSURE_PRESETS)]string
		chosen := -1
		for p, i in PRESSURE_PRESETS {
			names[i] = string(p.label)
			if app.brush.pressure_curve == p.curve do chosen = i
		}
		if picked := ui.tabs(ctx, "pressure", names[:], chosen); picked >= 0 do app.brush.pressure_curve = PRESSURE_PRESETS[picked].curve
		ui.paragraph(ctx, "Along: how hard the pen presses. Up: what that counts as.")
		_ = ui.slider(ctx, "Tilt", &app.brush.tilt_strength, 0, 1, .Linear, "off" if app.brush.tilt_strength <= 0 else fmt.tprintf("%.2f", app.brush.tilt_strength))
		if app.pen_seen {
			ui.paragraph(ctx, fmt.tprintf("Pen: pressure %.2f counts as %.2f; leaning %.0f° across, %.0f° down.", app.pen_pressure, pressure_curved(app, app.pen_pressure), app.pen_tilt.x, app.pen_tilt.y))
		} else {
			ui.paragraph(ctx, "No pen seen yet; a mouse always presses fully. Tilt turns the brush as the pen leans.")
		}
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Options", &k.open[.Options]) {
		_ = ui.switch_row(ctx, "Front faces only", &app.brush.front_only)
		ui.paragraph(ctx, "Brushes and mask shapes leave what faces away from you, so a stroke on a thin part (an ear, a fin) leaves its far side alone. Grab is not affected.")
		ui.section_end(ctx)
	}
	if ui.section(ctx, "Stroke recorder", &k.open[.Recorder]) {
		kit_replay_section(app)
		ui.section_end(ctx)
	}
}

@(private = "file")
kit_move_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_tool_head(ctx, ui.ICON_MOVE, "Move", "Click an object to select it. Drag it to move it across the view, or drag an arm of the gizmo to move it along that axis; the middle square moves it across the view.")
	half := (ui.fill_width(ctx) - 8) * 0.5
	ui.begin(ctx, "move actions", {direction = .Row, gap = 8})
	if ui.button(ctx, "Focus selected", .Flat, width = half, glyph = ui.ICON_FOCUS, enabled = selected_object(app) != nil) do focus_selected(app)
	if ui.button(ctx, "Frame all", .Flat, width = half, glyph = ui.ICON_FRAME, enabled = len(app.scene.objects) > 0) do frame_all(app)
	ui.end(ctx)
	ui.paragraph(ctx, "The Object tab places the selected object exactly: position, turn and scale.")
}

@(private = "file")
kit_curve_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_tool_head(ctx, ui.ICON_SPLINE, "Curve", "Drag over the surface: when you let go, a new object follows the path. Its width is a share of the brush's diameter (S changes the brush size).")
	kit_curve_settings(app)
}

@(private = "file")
kit_insert_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_tool_head(ctx, ui.ICON_SHAPES, "Insert", "Click the surface to put the shape there, standing on it, the brush's size; drag to size it. Mark it Subtract with Live boolean on (Object tab) to cut it out.")
	kit_insert_settings(app)
}
