package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../gizmo"
import "../sculpt"
import "../ui"

// The tray's first palette: the tool in use, and everything that sets it up.

// The palette's name, after the tool it shows.
kit_tool_name :: proc(tool: Tool) -> string {
	switch tool {
	case .Brush:  return "Brush"
	case .Move:   return "Move"
	case .Curve:  return "Curve"
	case .Insert: return "Insert"
	case .Model:  return "Model"
	}
	return ""
}

kit_tool_tab :: proc(app: ^App) {
	switch app.tool {
	case .Brush:  kit_brush_tab(app)
	case .Move:   kit_move_tab(app)
	case .Curve:  kit_curve_tab(app)
	case .Insert: kit_insert_tab(app)
	case .Model:  kit_model_tab(app)
	}
}

// The palette's heading: an icon on a badge, a title, and a line of help under them.
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
	help, _ := strings.replace_all(string(BRUSHES[kind].help), "\n", " ", context.temp_allocator)
	kit_tool_head(ctx, BRUSHES[kind].icon, BRUSHES[kind].name, help)
	shown := tray_section(app, .Tool)
	for sec in BRUSH_SECTIONS {
		if sec.section != shown do continue
		// The Preset section's title names the preset, and whether it has changed.
		title := sec.title
		if sec.section == .Preset {
			p, on := brush_preset(app)
			title = fmt.tprintf("Preset: %s%s", preset_name(p) if on else "none", " · changed" if preset_changed(app) else "")
		}
		kit_section_title(ctx, title)
		sec.draw(app)
	}
}

// One section of a palette that is not per object (the Brush and Scene palettes): which
// it is, its title, what it draws, and when it is offered (always, when nil).
Kit_Tab_Section :: struct {
	section: Kit_Section,
	title:   string,
	draw:    proc(app: ^App),
	shown:   proc(app: ^App) -> bool,
}

// The Brush palette's sections in the order shown.
@(rodata)
BRUSH_SECTIONS := [?]Kit_Tab_Section {
	{.Preset, "Preset", kit_preset, nil},
	{.Stroke, "Stroke", kit_stroke, nil},
	{.Paint_Color, "Colour", kit_brush_colors, nil},
	{.Recall, "History brush", kit_recall, proc(app: ^App) -> bool {return app.brush.kind == .History}},
	{.Falloff, "Falloff", kit_falloff, nil},
	{.Samples, "Samples", kit_samples, nil},
	{.Alpha, "Alpha", kit_alpha_section, nil},
	{.Pen, "Pen", kit_pen, nil},
	{.Options, "Options", kit_brush_options, nil},
	{.Recorder, "Stroke recorder", kit_replay_section, nil},
}

// The colours brushes paint and what the sculpting brushes change: the surface, it and
// its polypaint, or only the polypaint, and Open Colors for the Colors card (kit_colors.odin).
// The secondary colour and Swap are under More.
@(private = "file")
kit_brush_colors :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.brush
	if .Paint in BRUSHES[b.kind].flags {
		ui.paragraph(ctx, "Paint lays the main colour; Ctrl, or Subtract, takes paint off, and with Smooth blurs on, Shift, or Smooth, blurs it." if b.paint_dial else "Paint lays the main colour; Ctrl, or Subtract, takes paint off.")
	} else if channel_brush(b.kind) {
		names := [sculpt.Channel]string{.Sculpt = "Sculpt", .Both = "Both", .Color = "Paint"}
		options: [len(sculpt.Channel)]string
		for c in sculpt.Channel do options[c] = names[c]
		if picked := ui.tabs(ctx, "paint channel", options[:], int(b.channel), glyphs = {ICON_CHANNEL_SCULPT, ICON_CHANNEL_BOTH, ICON_CHANNEL_COLOR}); picked >= 0 do b.channel = sculpt.Channel(picked)
		ui.paragraph(ctx, CHANNEL_HELP[b.channel])
	} else {
		ui.paragraph(ctx, fmt.tprintf("%s keeps to what it changes; Sculpt, Both and Paint are for the sculpting brushes.", BRUSHES[b.kind].name))
	}
	_ = kit_color(app, "brush colour", &b.color)
	_ = command_button(app, .Colors_Card, label = "Open Colors", glyph = ICON_COLOUR, width = ui.fill_width(ctx))
	_ = ui.switch_row(ctx, "Smooth blurs, Invert erases", &b.paint_dial, .Paint in BRUSHES[b.kind].flags || channel_brush(b.kind))
	if kit_more(app, .Paint_Color) {
		ui.caption(ctx, "SECONDARY")
		_ = kit_color(app, "secondary colour", &b.color2)
		_ = command_button(app, .Swap_Colors, glyph = ICON_SWAP_COLORS)
		kit_more_end(app)
	}
}

@(rodata)
CHANNEL_HELP := [sculpt.Channel]string {
	.Sculpt = "The brushes move the surface and leave its colour.",
	.Both   = "The brushes move the surface and paint it the main colour under the same falloff.",
	.Color  = "The brushes paint the main colour under their falloff and move nothing.",
}

// What a dab works on, as Nomad's filter section: front faces only, Lock plane,
// Connected, and for Grab All depth and for Smooth which vertices it smooths. Each switch
// greys out on brushes it does nothing for, still showing how it is set; the first three
// are commands too (Front_Only, Lock_Plane, Connected) for keys and pies.
@(private = "file")
kit_brush_options :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.brush
	flags := BRUSHES[b.kind].flags
	_ = ui.switch_row(ctx, "Front faces only", &b.front_only, .Grab not_in flags, keys = command_hint(app, .Front_Only))
	locks := flags & {.Grab, .Cloth} == {} && sculpt.brush_locks_plane(b.kind, brush_alpha(app) != nil)
	_ = ui.switch_row(ctx, "Lock plane", &b.lock_plane, locks, keys = command_hint(app, .Lock_Plane))
	// All depth reaches past what Connected's flood keeps to, so on Grab it wins; so does
	// Topological, which reaches only what is joined anyway.
	// Elastic moves the solid round the press, joined or not.
	_ = ui.switch_row(ctx, "Connected only", &b.connected, .Cloth not_in flags && b.kind != .Elastic && !(b.kind == .Grab && (b.grab_depth || b.grab_topological)), keys = command_hint(app, .Connected))
	if b.kind == .Grab {
		_ = ui.switch_row(ctx, "All depth", &b.grab_depth)
		// Which way the drag moves it: Shift mid-grab takes Along normal and Alt Along
		// surface, whatever this says, for a pen with no keys to hand.
		if picked := ui.tabs(ctx, "grab moves", {"Free", "Along normal", "Along surface"}, int(b.grab_mode)); picked >= 0 do b.grab_mode = Grab_Mode(picked)
		if kit_more(app, .Options) {
			_ = ui.switch_row(ctx, "Topological", &b.grab_topological, !b.grab_depth)
			if b.grab_mode == .Free do _ = ui.slider(ctx, "Normal weight", &b.grab_normal, 0, 1, .Linear, fmt.tprintf("%.0f%%", b.grab_normal * 100))
			_ = ui.switch_row(ctx, "Same side", &b.grab_same_side)
			_ = ui.switch_row(ctx, "Silhouette", &b.grab_silhouette)
			ui.paragraph(ctx, "Free moves what Grab holds as the pointer goes; Along normal pulls it out along the surface's normal where it was pressed (Shift mid-grab), toward where that normal points on screen; Along surface slides it across the surface (Alt mid-grab). Normal weight moves a Free drag that much along the normal instead. Same side picks up only what faces the way the pressed surface does, never the far side of a thin part. Silhouette moves only what faces the way it is dragged, so pulling an edge out leaves the side behind it. Grab takes hold from just past the model's edge too, at the nearest point within the brush ring. Topological measures the falloff along the surface from the press, so it never reaches a part that only lies near, and bends round a fold.")
			kit_more_end(app)
		}
	}
	if b.kind == .Snake_Hook {
		label := fmt.tprintf("Magnify %.0f%%", -b.hook_pinch * 100) if b.hook_pinch < 0 else fmt.tprintf("%.0f%%", b.hook_pinch * 100)
		_ = ui.slider(ctx, "Pinch", &b.hook_pinch, -1, 1, .Linear, label)
		if kit_more(app, .Options) {
			_ = ui.slider(ctx, "Rake", &b.hook_rake, 0, 1, .Linear, fmt.tprintf("%.0f%%", b.hook_rake * 100))
			_ = ui.switch_row(ctx, "Elastic tip", &b.hook_elastic)
			ui.paragraph(ctx, "Pinch draws what the hook pulls in toward the line it is pulled along, for a horn that thins to a point; below zero it magnifies, fattening the tip as it goes. Rake turns what the hook drags as the hook turns, so a horn drawn round a bend twists with it instead of shearing flat. Elastic tip drags as the Elastic brush does, the surround stretching after the tip out to three times the ring (by Elastic's Volume).")
			kit_more_end(app)
		}
	}
	if b.kind == .Elastic {
		if picked := ui.tabs(ctx, "grab moves", {"Free", "Along normal", "Along surface"}, int(b.grab_mode)); picked >= 0 do b.grab_mode = Grab_Mode(picked)
		_ = ui.slider(ctx, "Volume", &b.elastic_volume, 0, 1, .Linear, fmt.tprintf("%.0f%%", b.elastic_volume * 100))
		ui.paragraph(ctx, "Elastic drags what is under the brush as a block of rubber pulled at that point would move: the part pulled keeps its shape and the rest stretches after it smoothly, out to three times the brush ring. Volume is how much of its volume the rubber keeps: at 100% the sides thin as it stretches, at 0% they stay put. Shift and Alt mid-drag work as Grab's.")
	}
	if b.kind == .Clay_Strips {
		_ = ui.slider(ctx, "Tip roundness", &b.tip_roundness, 0, 1, .Linear, fmt.tprintf("%.0f%%", b.tip_roundness * 100))
		_ = ui.slider(ctx, "Tip scale", &b.tip_scale, sculpt.CLAY_TIP_SCALE_MIN, 1, .Linear, fmt.tprintf("%.0f%%", b.tip_scale * 100))
		ui.paragraph(ctx, "Clay strips lays flat-topped strips with square ends that turn along the stroke, as ZBrush's ClayBuildup. Tip roundness rounds the square's corners, from a hard square to a disc; Tip scale shortens the tip along the stroke for thinner strips.")
	}
	if b.kind == .Trim_Dynamic {
		_ = ui.switch_row(ctx, "Dynamic angle", &b.trim_dynamic)
		_ = ui.slider(ctx, "Angle", &b.trim_angle, 0, math.to_degrees(f32(sculpt.TRIM_ANGLE_MAX)), .Linear, fmt.tprintf("%.0f°", b.trim_angle), enabled = !b.trim_dynamic)
		ui.paragraph(ctx, "Trim dynamic cuts what is under it into two flat planes meeting along the stroke, as ZBrush's TrimDynamic and Blender's Multiplane scrape: drawn along a rounded edge it makes it a crisp one. Dynamic angle reads the angle from the two sides as it goes and leaves hollows alone; off, Angle sets it. Ctrl turns the planes the other way, cutting a valley.")
	}
	if b.kind == .Flatten {
		height, depth := b.plane_height * 100, b.plane_depth * 100
		if ui.slider(ctx, "Plane height", &height, 0, 100, .Linear, fmt.tprintf("%.0f%%", height)) do b.plane_height = math.round(height) / 100
		if ui.slider(ctx, "Plane depth", &depth, 0, 100, .Linear, fmt.tprintf("%.0f%%", depth)) do b.plane_depth = math.round(depth) / 100
		ui.paragraph(ctx, "Plane height and depth are how far above and below its plane Flatten reaches, as a share of the radius: height 0 only fills the dips (the Fill preset), depth 0 only scrapes the bumps (the Scrape preset).")
	}
	if b.kind == .Smooth {
		// In the order a person reaches for them; the enum keeps Smooth all's order.
		modes := [3]sculpt.Smooth_Mode{.Smooth, .Relax, .Polish}
		chosen := 0
		for m, i in modes do if m == b.smooth_mode do chosen = i
		if picked := ui.tabs(ctx, "smooth mode", {"Smooth", "Relax", "Polish"}, chosen); picked >= 0 do b.smooth_mode = modes[picked]
		if kit_more(app, .Options) {
			if picked := ui.tabs(ctx, "smooth only", {"All", "Valleys", "Peaks"}, int(b.smooth_only)); picked >= 0 do b.smooth_only = sculpt.Smooth_Only(picked)
			_ = ui.switch_row(ctx, "Stable", &b.smooth_stable)
			kit_more_end(app)
		}
	}
	ui.paragraph(ctx, "Front faces only leaves the far side of a thin part (an ear, a fin). Lock plane keeps the plane the stroke began on, so long Flatten or Clay strokes do not drift. Connected only leaves what is near in space but not joined through the surface, such as the next finger. All depth lets Grab move everything under the brush however deep, the back too, and then Connected only does not apply. Smooth evens the surface out, Relax only evens out the spacing of its vertices across it, keeping the shape, and Polish takes the roughness off keeping the volume (Alt held while smoothing polishes too). Under More, Smooth can even out only the dents (Valleys) or only the bumps (Peaks), and Stable gives a dense mesh more passes and a coarse one fewer, so a dab evens out about as much at any density; Shift smoothing with any brush does the same.")
}

// The brush's preset (presets.odin): which it is on, or none; on a plain brush, saving
// it as a preset and resetting it; on one of the person's own, its name, saving or
// reverting changes, saving a copy, and (under More) deleting it; on a built-in one or a
// content pack's (which pack it is from), reverting and saving a copy, as those are
// read-only.
@(private = "file")
kit_preset :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	b := &app.brush
	// The list: none, the person's own, the built-ins, then every pack's, each as the
	// number the brush keeps (PACK_PRESET, BUILT_IN_PRESET).
	names := make([dynamic]string, context.temp_allocator)
	numbers := make([dynamic]int, context.temp_allocator)
	append(&names, fmt.tprintf("None: the plain %s brush", BRUSHES[b.kind].name))
	append(&numbers, 0)
	for i in 0 ..< app.preset_count {
		append(&names, fmt.tprintf("%s (%s)", preset_name(&app.presets[i]), BRUSHES[app.presets[i].values.kind].name))
		append(&numbers, i + 1)
	}
	for r, j in BUILT_IN_PRESETS {
		append(&names, fmt.tprintf("%s (%s, built in)", r.name, BRUSHES[r.kind].name))
		append(&numbers, BUILT_IN_PRESET + j)
	}
	for pack in app.library.packs {
		for &p, j in app.library.presets {
			if p.gone || p.pack != pack.id do continue
			append(&names, fmt.tprintf("%s (%s, from %s)", preset_name(&p.preset), BRUSHES[p.preset.values.kind].name, pack.name))
			append(&numbers, PACK_PRESET + j)
		}
	}
	shown := 0
	for n, i in numbers do if n == b.preset do shown = i
	if picked := ui.select(ctx, "preset", names[:], shown); picked >= 0 && picked != shown {
		if numbers[picked] == 0 do command_run(app, .Brush, int(b.kind))
		else do preset_use(app, numbers[picked])
	}
	p, on := brush_preset(app)
	if !on {
		kit_command_pair(app, .Preset_Save_New, .Brush_Reset, label_a = "Save as preset", tone_a = .Accent)
		ui.paragraph(ctx, "A preset keeps this brush's strength, falloff, alpha, stroke kind and lazy mouse under a name, to pick again here. The size and the pen settings stay the same for every brush.")
		return
	}
	if preset_built_in(b.preset) {
		kit_command_pair(app, .Preset_Save_New, .Preset_Revert, label_a = "Save as new preset", label_b = "Revert", tone_a = .Accent)
		ui.paragraph(ctx, "A built-in preset, which stays as it came. Save as new preset keeps your changes as a preset of your own.")
		return
	}
	if preset_of_pack(b.preset) {
		pack := app.library.presets[b.preset - PACK_PRESET].pack
		for q in app.library.packs do if q.id == pack do pack = q.name
		kit_command_pair(app, .Preset_Save_New, .Preset_Revert, label_a = "Save as new preset", label_b = "Revert", tone_a = .Accent)
		ui.paragraph(ctx, fmt.tprintf("From the content pack %s, which keeps its presets as they came. Save as new preset keeps your changes as a preset of your own; Menu > Library lists the pack.", pack))
		return
	}
	// The name is typed into a copy, and renames the preset once typing ends (Enter, or a
	// press elsewhere); a name that is empty, taken or a brush's own is refused.
	id := ui.id_of(ctx, "name##preset")
	if k.preset_editing == 0 {
		k.preset_name = {}
		copy(k.preset_name[:PRESET_NAME_MAX - 1], preset_name(p))
	}
	_ = ui.text_field(ctx, "name##preset", k.preset_name[:], hint = "Preset name")
	if ctx.text_focus == id {
		if k.preset_editing == 0 do k.preset_editing = b.preset
	} else if k.preset_editing != 0 {
		typed := string(cstring(raw_data(k.preset_name[:])))
		if !preset_rename(app, k.preset_editing - 1, typed) {
			report(app, nil, {.Warning}, "A preset needs a name of its own, not empty and not a brush's: %q is not one", strings.trim_space(typed))
		}
		k.preset_editing = 0
	}
	kit_command_pair(app, .Preset_Save, .Preset_Revert, label_a = "Save changes", label_b = "Revert", tone_a = .Accent)
	_ = command_button(app, .Preset_Save_New, label = "Save as new preset")
	if kit_more(app, .Preset) {
		_ = command_button(app, .Preset_Delete, tone = .Danger)
		kit_more_end(app)
	}
}

// Size, strength, then the stroke mode (with Spray's spread) or, for the brushes that
// lay no dabs along the path, the cloth brush's mode; under More, how the path is
// followed: the lazy mouse, straight lines and joined strokes.
@(private = "file")
kit_stroke :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kind := app.brush.kind
	// Lens's Brush card shows Radius and Strength above its groups, and its readers know the
	// keys from the island's tooltips.
	stack := app.kit.in_stack
	if !stack {
		_ = ui.slider(ctx, "Size", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
		s := brush_strength(app)
		_ = ui.slider(ctx, "Strength", s, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", s^))
	}
	// Grab, Snake hook and Cloth move what they pick up rather than laying dabs, so a
	// stroke mode means nothing to them.
	if BRUSHES[kind].flags & {.Grab, .Hook, .Cloth} == {} {
		strokes: [len(Stroke_Mode)]string
		for m, i in Stroke_Mode do strokes[i] = STROKE_MODE_NAMES[m]
		if picked := ui.tabs(ctx, "stroke kind", strokes[:], int(app.brush.stroke)); picked >= 0 do app.brush.stroke = Stroke_Mode(picked)
		switch app.brush.stroke {
		case .Dots:
		case .Drag_Rect:
			ui.paragraph(ctx, "One stamp where the drag starts: its size is how far you drag and, with an alpha, its top faces the pointer. For placing alphas; not with dynamic topology.")
		case .Spray:
			_ = ui.slider(ctx, "Spread", &app.brush.spray_spread, 0, SPRAY_MAX_SPREAD, .Linear, fmt.tprintf("%.2f", app.brush.spray_spread))
			_ = ui.slider(ctx, "Colour spray", &app.brush.color_spray, 0, 1, .Linear, "off" if app.brush.color_spray <= 0 else fmt.tprintf("%.0f%%", app.brush.color_spray * 100))
			ui.paragraph(ctx, "Dabs scatter up to the spread (in brush sizes) from the path, each a little smaller or weaker and, with an alpha, turned its own way: texture without a visible repeat. Colour spray makes each dab's paint a little lighter or darker in each channel, for mottled skin and stone.")
		case .Roll:
			ui.paragraph(ctx, "Dabs a brush width apart with the alpha's top along the stroke, so an alpha tiles like a tape rolled out: stitches, zips, chains.")
		case .Drag_Dot:
			ui.paragraph(ctx, "One stamp at the brush's size that slides with the pointer until you let go, so you can place a detail exactly before it stays. Not with dynamic topology.")
		}
		// Rectangle and Drag dot lay one stamp, so how a path is followed means nothing
		// to them.
		if app.brush.stroke != .Drag_Rect && app.brush.stroke != .Drag_Dot {
			// Said while folded too, since it changes every stroke.
			if app.brush.line do ui.paragraph(ctx, "Line is on (under More): every stroke is a straight line from its press (not with dynamic topology).")
			kit_stroke_path(app)
		}
	}
	if .Cloth in BRUSHES[kind].flags {
		modes: [len(sculpt.Cloth_Mode)]string
		for m, i in sculpt.Cloth_Mode do modes[i] = string(CLOTH_MODE_NAMES[m])
		if picked := ui.tabs(ctx, "cloth mode", modes[:], int(app.brush.cloth_mode)); picked >= 0 do app.brush.cloth_mode = sculpt.Cloth_Mode(picked)
		cloth, _ := strings.replace_all(string(CLOTH_MODE_HELP[app.brush.cloth_mode]), "\n", " ", context.temp_allocator)
		ui.paragraph(ctx, cloth)
	}
	if !stack do ui.paragraph(ctx, "S or U over the viewport sizes the brush or sets its strength there; [ and ] step the size, Shift with them the strength. Each brush keeps its own strength. Space, or a right click without dragging (a pen's side button), opens the brush pie.")
}

// The Stroke section's More: how the stroke follows the pointer's path.
@(private = "file")
kit_stroke_path :: proc(app: ^App) {
	ctx := &app.kit.ctx
	if !kit_more(app, .Stroke) do return
	kit_stabiliser(app, full = true)
	// Spray and Roll space their dabs for their own look.
	if app.brush.stroke == .Dots {
		if app.brush.spacing <= 0 do app.brush.spacing = DAB_SPACING
		_ = ui.slider(ctx, "Spacing", &app.brush.spacing, MIN_SPACING, MAX_SPACING, .Logarithmic, fmt.tprintf("%.0f%%", app.brush.spacing * 100))
		_ = ui.switch_row(ctx, "Even strength", &app.brush.even_strength)
		_ = ui.switch_row(ctx, "Scene spacing", &app.brush.scene_spacing)
		_ = ui.switch_row(ctx, "No back and forth", &app.brush.one_way)
		_ = ui.switch_row(ctx, "Directional", &app.brush.directional)
	}
	_ = ui.switch_row(ctx, "Line", &app.brush.line)
	_ = ui.switch_row(ctx, "Join strokes", &app.brush.join)
	// Turned on, the size is taken afresh from the view as it is, so nothing jumps.
	if ui.switch_row(ctx, "Size fixed in the scene", &app.brush.size_world) do app.brush.size_ref = 0
	_ = kit_stroke_amount(app, "Last stroke")
	ui.paragraph(ctx, "Lazy mouse trails the brush behind the pointer on a string; Smoothing makes it follow the average of the pointer's last few positions and Pressure smoothing the pen's last few pressures, for steadier lines and swells; the rope shows where the brush is. Catch up on lift carries the stroke on to where the pen lifted. Shift (or holding the Smooth button) mid-stroke lays the stroke again as a straight line from where it began to the pointer; letting go carries on freehand. Line makes every stroke one. Spacing is how far apart the dabs are, as a share of the brush's radius: wider gaps make a dotted line, narrower a smoother one; Even strength keeps a stroke's height the same at any spacing, and Scene spacing measures the gaps on the model, so they stay as far apart where the surface turns away. No back and forth lays dabs only while the stroke goes the way it first went, so a zigzag lays parallel hatching; Directional only while it moves away from where it was pressed. Join strokes carries a stroke on from where the last one ended when you press near it, so a line drawn in pieces has no blob at the joins. Last stroke sets how much of the newest stroke stays, from none to half as much again. Size fixed in the scene keeps the brush the same size on the model as the view zooms, as ZBrush's Dynamic size: the ring grows as you zoom in.")
	kit_more_end(app)
}

// The stabiliser's controls: the lazy string, Smoothing, and with `full` Pressure
// smoothing and Catch up on lift.
kit_stabiliser :: proc(app: ^App, full: bool) {
	ctx := &app.kit.ctx
	b := &app.brush
	_ = ui.slider(ctx, "Lazy mouse", &b.lazy_px, 0, 150, .Linear, "off" if b.lazy_px < 0.5 else fmt.tprintf("%.0f px", b.lazy_px))
	steady_slider :: proc(ctx: ^ui.Context, name: string, v: ^f32) {
		if v^ < 1 do v^ = 1
		if ui.slider(ctx, name, v, 1, STEADY_MAX, .Linear, "off" if steady_count(v^) <= 1 else fmt.tprintf("%d samples", steady_count(v^))) {
			v^ = f32(steady_count(v^))
		}
	}
	steady_slider(ctx, "Smoothing", &b.smoothing)
	if !full do return
	steady_slider(ctx, "Pressure smoothing", &b.pressure_smoothing)
	_ = ui.switch_row(ctx, "Catch up on lift", &b.catch_up)
}

@(private = "file")
kit_falloff :: proc(app: ^App) {
	ctx := &app.kit.ctx
	// Elastic's falloff is how the rubber stretches, which Volume shapes, not a curve.
	if app.brush.kind == .Elastic {
		ui.paragraph(ctx, "Elastic has no falloff curve: how far the pull reaches and how it fades is how rubber stretches, which the brush's size and Volume (under Options) decide.")
		return
	}
	shape := &app.brush.falloffs[app.brush.kind]
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
		shape.drawn, shape.curve = p.drawn, p.curve
	}
	ui.paragraph(ctx, "The centre is on the left and the rim on the right. Drag a handle to draw your own; each brush keeps its own.")
	focal_slider(app)
	hard := shape.hardness * 100
	if ui.slider(ctx, "Hardness", &hard, 0, sculpt.HARDNESS_MAX * 100, .Linear, fmt.tprintf("%.0f%%", hard)) do shape.hardness = math.round(hard) / 100
	if picked := ui.tabs(ctx, "falloff shape", {"Sphere", "Projected"}, 1 if shape.projected else 0); picked >= 0 do shape.projected = picked == 1
	ui.paragraph(ctx, "Focal shift reshapes the curve: up to 100 pulls the brush to a point, down to -100 spreads it into a flat top with a hard edge. Hardness keeps that much of the radius at full strength. The cursor's inner ring shows where it works at half strength. Projected measures the falloff across the view, so the brush covers the ring on screen however the surface curves away; Grab, Elastic, Cloth, Snake hook and alphas stay Sphere.")
}

// ZBrush's Samples: how a dab reads the surface under it. Stabilize orientation and
// Sample radius grey out on brushes that do not work along the area under them, and
// Accumulate on those it does nothing for.
@(private = "file")
kit_samples :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.brush
	area := samples_apply(b.kind)
	steady := b.stabilize * 100
	if ui.slider(ctx, "Stabilize orientation", &steady, 0, sculpt.STABILIZE_MAX * 100, .Linear, fmt.tprintf("%.0f%%", steady), enabled = area && !b.lock_plane) {
		b.stabilize = math.round(steady) / 100
	}
	sample := max(b.sample_radius, sculpt.SAMPLE_RADIUS_MIN) * 100
	if ui.slider(ctx, "Sample radius", &sample, sculpt.SAMPLE_RADIUS_MIN * 100, 100, .Linear, fmt.tprintf("%.0f%%", sample), enabled = area) {
		b.sample_radius = math.round(sample) / 100
	}
	accumulate := !b.no_accumulate[b.kind]
	if ui.switch_row(ctx, "Accumulate", &accumulate, accumulate_applies(b.kind)) do b.no_accumulate[b.kind] = !accumulate
	ui.paragraph(ctx, "Stabilize orientation keeps that much of the direction and plane the stroke has worked along so far, so a stroke over rough ground stays steady (Lock plane keeps all of it). Sample radius is how much of the brush reads that direction: less follows a narrow ridge. Accumulate off: going over the same place within a stroke adds nothing more, as ZBrush's and Nomad's Draw; each brush keeps its own.")
}

// The brush's focal shift as a slider, in whole steps (Falloff_Setting.focal).
@(private = "file")
focal_slider :: proc(app: ^App) {
	ctx := &app.kit.ctx
	f := focal_shift(app)
	if ui.slider(ctx, "Focal shift", f, sculpt.FOCAL_MIN, sculpt.FOCAL_MAX, .Linear, fmt.tprintf("%.0f", f^)) do f^ = math.round(f^)
}

@(private = "file")
kit_pen :: proc(app: ^App) {
	ctx := &app.kit.ctx
	// Four pages, so none holds more than the section's five controls: what pressure does
	// to the strength, to the size, the response as a whole with whose pressure it is,
	// and the pen's lean.
	pages := [4]string{"Strength", "Size", "Response", "Lean"}
	if picked := ui.tabs(ctx, "pen page", pages[:], app.kit.pen_page); picked >= 0 do app.kit.pen_page = picked
	b := &app.brush
	at := pressure_edit(b)
	whose := fmt.tprintf("%s keeps its own pressure (Response page).", BRUSHES[b.kind].name) if b.pressures[b.kind].own else "Every brush using the global pressure follows this (Response page)."
	switch app.kit.pen_page {
	case 3:
		kit_tilt(app)
		return
	case 2:
		global := !b.pressures[b.kind].own
		if ui.switch_row(ctx, "Use global", &global) do brush_pressure_own(b, b.kind, !global)
		names: [len(PRESSURE_RESPONSES)]string
		for r, i in PRESSURE_RESPONSES do names[i] = string(r.label)
		if picked := ui.tabs(ctx, "response", names[:], pressure_response(at)); picked >= 0 do pressure_put(at, PRESSURE_RESPONSES[picked].pressure)
		floor := at.size_floor^ * 100
		if ui.slider(ctx, "Smallest size", &floor, MIN_PRESSURE_SIZE * 100, 100, .Linear, fmt.tprintf("%.0f%%", max(floor, MIN_PRESSURE_SIZE * 100)), enabled = at.size^) {
			at.size_floor^ = math.round(floor) / 100
		}
		ui.paragraph(ctx, fmt.tprintf("With Use global off, %s keeps its own switches and curves. Clay: the size follows the cube of the pressure, at least a fifth of the radius, as Blender's Clay. Steady: nearly full strength from half pressure on, so a stroke keeps an even height. Light: a light touch goes far, for size and strength.", BRUSHES[b.kind].name))
		return
	}
	size := app.kit.pen_page == 1
	_ = ui.switch_row(ctx, "Pressure changes size" if size else "Pressure changes strength", at.size if size else at.strength)
	curve := at.size_curve if size else at.strength_curve
	counts :: proc(app: ^App, size: bool, x: f32) -> f32 {return pressure_sized(app, x) if size else pressure_curved(app, x)}
	dot: Maybe([2]f32)
	if app.pen_seen {
		x := clamp(app.pen_pressure, 0, 1)
		dot = [2]f32{x, counts(app, size, x)}
	}
	_ = kit_curve_editor(ctx, "pressure curve", curve, &app.ui.curve_handle, false, dot)
	names: [len(PRESSURE_PRESETS)]string
	chosen := -1
	for p, i in PRESSURE_PRESETS {
		names[i] = string(p.label)
		if curve^ == p.curve do chosen = i
	}
	if picked := ui.tabs(ctx, "pressure", names[:], chosen); picked >= 0 do curve^ = PRESSURE_PRESETS[picked].curve
	ui.paragraph(ctx, fmt.tprintf("Along: how hard the pen presses. Up: what that counts as for the %s. %s", "size" if size else "strength", whose))
	if app.pen_seen {
		ui.paragraph(ctx, fmt.tprintf("Pen: pressure %.2f counts as %.2f.", app.pen_pressure, counts(app, size, app.pen_pressure)))
	} else {
		ui.paragraph(ctx, "No pen seen yet; a mouse always presses fully.")
	}
}

// The Pen section's Lean page: turn the brush the way the pen leans, and, laid toward the
// screen, grow it and soften it, as a pencil's side shades wide and light.
@(private = "file")
kit_tilt :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.brush
	_ = ui.slider(ctx, "Tilt", &b.tilt_strength, 0, 1, .Linear, "off" if b.tilt_strength <= 0 else fmt.tprintf("%.2f", b.tilt_strength))
	_ = ui.slider(ctx, "Lean grows the size", &b.tilt_size, 0, 1, .Linear, "off" if b.tilt_size <= 0 else fmt.tprintf("up to ×%.2f", 1 + b.tilt_size))
	_ = ui.slider(ctx, "Lean softens", &b.tilt_soften, 0, 1, .Linear, "off" if b.tilt_soften <= 0 else fmt.tprintf("up to %.0f%%", 100 * b.tilt_soften))
	if app.pen_seen {
		ui.paragraph(ctx, fmt.tprintf("Pen: leaning %.0f° across, %.0f° down; laid %.0f%% of the way down.", app.pen_tilt.x, app.pen_tilt.y, 100 * lean_of(app.pen_tilt)))
	} else {
		ui.paragraph(ctx, "No pen seen yet. Tilt turns the brush as the pen leans; laid toward the screen, the pen can also grow the brush and soften it, in full from 60° off upright.")
	}
}

@(private = "file")
kit_move_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_tool_head(ctx, ui.ICON_MOVE, "Move", "Tap or click an object to select it, and drag it to move it across the view. The gizmo moves it along an arm or across a plane square, turns it about a ring, or scales it from the middle.")
	// The camera's buttons first, where they always are, then the gizmo's settings.
	half := (ui.fill_width(ctx) - 8) * 0.5
	ui.begin(ctx, "move actions", {direction = .Row, gap = 8})
	_ = command_button(app, .Focus_Selected, width = half, glyph = ui.ICON_FOCUS)
	_ = command_button(app, .Frame_All, width = half, glyph = ui.ICON_FRAME)
	ui.end(ctx)
	modes := [len(gizmo.Mode)]string{"Move", "Turn", "Scale"}
	hints: [len(gizmo.Mode)]string
	for &h, i in hints do h = command_hint(app, .Gizmo, i)
	if picked := ui.tabs(ctx, "gizmo mode", modes[:], int(app.move.mode), keys = hints[:]); picked >= 0 do command_run(app, .Gizmo, picked)
	_ = ui.switch_row(ctx, "Snap", &app.move.snap)
	kit_command_pair(app, .Gizmo_Pivot, .Gizmo_Pivot_Reset, label_a = "Set pivot", label_b = "Reset pivot")
	ui.paragraph(ctx, fmt.tprintf("%s again steps through the three. Snap (or Ctrl for one drag) moves in steps of a grid that follows the zoom, turns 15° at a time and scales in steps of 0.1. Esc puts the object back mid-drag; %s undoes a drag. Tap a handle without moving it to type its value. Set pivot, then a tap on a surface, turns and scales about that point.", command_keys(app, .Tool_Move), command_keys(app, .Undo)))
	// Posing changes what the handles do, so it says so while it is on.
	if pose_mode(app) {
		ui.paragraph(ctx, "Posing: a mask is on, so the handles bend the unmasked part about the gizmo, which sits on the mask's soft edge; a drag on the object still moves all of it. Clear the mask to move the object with the handles again.")
	}
	ui.paragraph(ctx, "Ctrl + drag from the model (or with the rail's Mask on) masks along the surface: free near the press, masked as far as the drag reaches, ready to pose. Alt the other way round.")
	ui.paragraph(ctx, "The Object palette places the selected object exactly: position, turn and scale.")
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
	kit_tool_head(ctx, ui.ICON_SHAPES, "Insert", "Click the surface to put the shape there, standing on it, the brush's size; drag to size it. Mark it Subtract with Live boolean on (Object palette) to cut it out.")
	kit_insert_settings(app)
}
