package main

import "core:fmt"

import "../camera"
import "../ui"

// The Settings panel (Menu > Settings): the app's own preferences in one place, by
// category, each changed at once and remembered (settings.odin) when the panel closes,
// when the app goes to the background and on exit. It takes the inspector's place on the
// right while open, so the model stays in view and a change to the camera or the touch
// gestures can be tried as it is made. Brush and tool settings stay with the tool, in the
// inspector; the drawing switches for comparing speed stay in the Stats panel's
// Advanced view, being for development.
Settings_Tab :: enum u8 {
	Interface,
	Camera,
	Touch,
	Keys,
	Performance,
}

SETTINGS_TAB_NAMES := [Settings_Tab]string {
	.Interface   = "Interface",
	.Camera      = "Camera",
	.Touch       = "Touch",
	.Keys        = "Keys",
	// "Performance" is wider than a fifth of the panel; the statistics and VSync are the
	// system's side of things.
	.Performance = "System",
}

// The interface sizes on offer, times what the display asks for. None is smaller than
// what it asks for, so every touch target stays at least 48 points (sm-store).
UI_SCALES := [?]f32{1, 1.15, 1.3, 1.5}

// The Settings panel's width.
KIT_SETTINGS_W :: 400

// Seconds Reset everything waits for its second tap.
SETTINGS_WIPE_TIME :: 3

kit_settings :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "settings")
	shown := ui.presence(ctx, id, k.settings, t.panel_time)
	if shown <= 0 do return
	win := &k.windows[.Settings]
	top := t.edge + t.target + 8
	room := window_room(app, win^, top)
	if status, _ := ui.prev_layout(ctx, "status"); status.y > 0 && !win.moved do room -= status.y + 8
	inner := f32(KIT_SETTINGS_W - 2 * 16)

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "settings", "Settings", win, .End, .Start, {t.edge, top}, {direction = .Column, gap = 8, padding = 16, width = KIT_SETTINGS_W, radius = t.radius_large, background = .Panel, inert = !k.settings}, "Esc")
	raised = raised_now
	if closed do settings_close(app)
	if !body {
		ui.window_end(ctx)
		ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(win^, .End) * (1 - shown) * 16, 0})
		return
	}
	names: [len(Settings_Tab)]string
	for tab in Settings_Tab do names[int(tab)] = SETTINGS_TAB_NAMES[tab]
	if picked := ui.tabs(ctx, "settings tabs", names[:], int(k.settings_tab)); picked >= 0 && Settings_Tab(picked) != k.settings_tab {
		k.settings_tab = Settings_Tab(picked)
		k.settings_scroll = 0
	}

	// The category scrolls in the room left between the tabs and the buttons below.
	body_h := max(room - 2 * 16 - 3 * 8 - 3 * t.target, 120)
	scroll := kit_scroll_begin(ctx, "settings body", &k.settings_scroll, id, inner, body_h, 4)
	k.settings_body = scroll.at
	switch k.settings_tab {
	case .Interface:   settings_interface(app)
	case .Camera:      settings_camera(app)
	case .Touch:       settings_touch(app)
	case .Keys:        settings_keys(app)
	case .Performance: settings_performance(app)
	}
	ui.spacer(ctx, 4)
	if ui.button(ctx, fmt.tprintf("Reset %s settings", SETTINGS_TAB_NAMES[k.settings_tab]), .Bordered) do settings_reset(app, k.settings_tab)
	kit_scroll_end(ctx, scroll)

	// Everything goes back only on a second tap, so a stray finger never wipes it all.
	ui.begin(ctx, "settings foot", {direction = .Row, gap = 8, width = inner})
	armed := k.settings_wipe > 0 && ctx.time - k.settings_wipe < SETTINGS_WIPE_TIME
	if ui.button(ctx, "Tap again to reset all" if armed else "Reset everything", .Light, .Danger, width = (inner - 8) * 0.5) {
		if armed {
			for tab in Settings_Tab do settings_reset(app, tab)
			// Everything includes what the command palette remembers having run.
			k.palette_recent_count = 0
			k.settings_wipe = 0
		} else do k.settings_wipe = max(ctx.time, 1e-6)
	}
	if ui.button(ctx, "Done", .Solid, .Accent, width = (inner - 8) * 0.5) do settings_close(app)
	ui.end(ctx)
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(win^, .End) * (1 - shown) * 16, 0})
	return
}

// Opens Settings as Menu > Settings does, on `tab` from its top; returns whether it ran.
settings_open :: proc(app: ^App, tab: Settings_Tab) -> bool {
	if !command_run(app, .Settings) do return false
	app.kit.settings_tab, app.kit.settings_scroll = tab, 0
	return true
}

// Closes the Settings panel and remembers what it holds.
settings_close :: proc(app: ^App) {
	app.kit.settings = false
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// Puts one category's settings back as a fresh install has them.
settings_reset :: proc(app: ^App, tab: Settings_Tab) {
	k := &app.kit
	n := &app.nav
	d := NAV_DEFAULT
	switch tab {
	case .Interface:
		k.ui_scale = 1
		k.ctx.reduced_motion = false
		k.surface_ring = true
		k.action_bar = true
		k.rail_side = .Left
		k.all_options = false
		k.dock = DOCK_DEFAULT
		windows_reset(k)
	case .Camera:
		n.orbit_style, n.limit_pitch, n.orbit_speed, n.pan_speed, n.zoom_speed = d.orbit_style, d.limit_pitch, d.orbit_speed, d.pan_speed, d.zoom_speed
		n.invert_x, n.invert_y, n.invert_wheel = d.invert_x, d.invert_y, d.invert_wheel
		n.pivot, n.edge_orbit, n.edge_size, n.edge_show = d.pivot, d.edge_orbit, d.edge_size, d.edge_show
	case .Touch:
		n.finger_model, n.empty_drag, n.palm_rejection = d.finger_model, d.empty_drag, d.palm_rejection
		n.pinch_zoom, n.two_finger_pan, n.zoom_toward, n.twist_roll = d.pinch_zoom, d.two_finger_pan, d.zoom_toward, d.twist_roll
		n.three_finger, n.tap_history = d.three_finger, d.tap_history
		n.double_tap, n.lift_one_orbit, n.hold_history = d.double_tap, d.lift_one_orbit, d.hold_history
	case .Keys:
		bind_reset_all(app)
		n.mouse_scheme = d.mouse_scheme
		k.keys_query = {}
	case .Performance:
		k.stats, k.stats_advanced = false, false
		app.vsync = true
	}
}

@(private = "file")
settings_interface :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, "SIZE")
	names: [len(UI_SCALES)]string
	chosen := 0
	for s, i in UI_SCALES {
		names[i] = fmt.tprintf("%.0f%%", s * 100)
		if abs(s - k.ui_scale) < 0.01 do chosen = i
	}
	if picked := ui.select(ctx, "Interface size", names[:], chosen); picked >= 0 do k.ui_scale = UI_SCALES[picked]
	ui.paragraph(ctx, "How big panels, text and touch targets are, on top of the size the screen asks for.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "MOTION")
	_ = ui.switch_row(ctx, "Reduce motion", &ctx.reduced_motion)
	ui.paragraph(ctx, "Panels and menus appear and change without animating.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "BRUSH RING")
	_ = ui.switch_row(ctx, "Lay the brush ring on the surface", &k.surface_ring)
	ui.paragraph(ctx, "Over the model the ring tilts with the surface under it, with a tick showing which way it faces, as in ZBrush; off, it stays a flat circle on the screen.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "ACTION BAR")
	_ = ui.switch_row(ctx, "Show next steps over the dock", &k.action_bar)
	ui.paragraph(ctx, "While the selected object has a mask, hidden parts or an HD window open, buttons over the brushes offer what usually comes next: invert or blur the mask, show everything, leave HD.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "MODIFIER BUTTONS")
	sides := [len(Rail_Side)]string{"Off", "Left", "Right"}
	if picked := ui.tabs(ctx, "Modifier buttons", sides[:], int(k.rail_side)); picked >= 0 do k.rail_side = Rail_Side(picked)
	ui.paragraph(ctx, "Smooth, Invert, Mask and Hide at the bottom left or right, for what Shift, Ctrl and Alt do. Tap one to keep it on until tapped again; hold one with a finger to use it only while held, sculpting with the pen or another finger.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "INSPECTOR")
	_ = ui.switch_row(ctx, "Show every option", &k.all_options)
	ui.paragraph(ctx, "Each section of the inspector shows its common controls and keeps the rest under More options. On, every section shows everything.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PIES")
	// Beside the button that opened it, rather than at the top of the window.
	if command_button(app, .Pie_Editor, variant = .Bordered, glyph = ui.ICON_PIE) do k.pie_editor_at = ctx.last_rect
	ui.paragraph(ctx, fmt.tprintf("%s opens Pie 1 at the pointer and %s Pie 2; tap a slice to run it. Search puts any command in a pie (Put in a pie); here you can empty slots or put the defaults back.", key_or(command_keys(app, .Pie, 0), "Pie 1's key"), key_or(command_keys(app, .Pie, 1), "Pie 2's")))
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PANELS")
	if ui.button(ctx, "Reset panel positions", .Bordered) do windows_reset(k)
	ui.paragraph(ctx, "Drag a panel by its title bar to move it; Minimise folds it to its title bar, Close hides it until it is opened again. This puts every panel back where it starts, unfolded.")
}

@(private = "file")
settings_camera :: proc(app: ^App) {
	ctx := &app.kit.ctx
	n := &app.nav
	ui.caption(ctx, "ORBIT")
	styles := [len(camera.Orbit_Style)]string{"Free", "Turntable"}
	if picked := ui.tabs(ctx, "Orbit style", styles[:], int(n.orbit_style)); picked >= 0 do n.orbit_style = camera.Orbit_Style(picked)
	switch n.orbit_style {
	case .Free:
		ui.paragraph(ctx, "As ZBrush's default (Rot XYZ): a drag turns the model about the screen's own axes, so any view is one drag away, all the way round both ways.")
	case .Turntable:
		ui.paragraph(ctx, "As ZBrush's Rot Y: sideways turns about the model's up axis and up and down tilts, so the horizon stays level. Goes all the way round both ways, over the top too.")
	}
	_ = ui.switch_row(ctx, "Stop at the top and bottom", &n.limit_pitch, enabled = n.orbit_style == .Turntable)
	speed_slider(ctx, "Orbit speed", &n.orbit_speed)
	_ = ui.switch_row(ctx, "Invert sideways orbit", &n.invert_x)
	_ = ui.switch_row(ctx, "Invert up and down orbit", &n.invert_y)
	ui.label(ctx, "Turn about")
	pivots := [len(Orbit_Pivot)]string{"Last stroke", "Pointer", "Centre"}
	if picked := ui.tabs(ctx, "Orbit pivot", pivots[:], int(n.pivot)); picked >= 0 do n.pivot = Orbit_Pivot(picked)
	switch n.pivot {
	case .Stroke:
		ui.paragraph(ctx, "The view turns about the middle of your last stroke, which stays where it is on screen, as ZBrush's Local and Blender's Orbit Around Selection do. Before any stroke, and after Focus, about the selected object's middle.")
	case .Pointer:
		ui.paragraph(ctx, "A drag that starts on the model turns about the spot under it; one on empty space turns about the last stroke.")
	case .Centre:
		ui.paragraph(ctx, "The view turns about the middle of the screen, wherever the model is.")
	}
	ui.spacer(ctx, 8)
	ui.caption(ctx, "SAFE ZONE")
	_ = ui.switch_row(ctx, "Edges always turn the view", &n.edge_orbit)
	_ = ui.slider(ctx, "Edge width", &n.edge_size, EDGE_MIN, EDGE_MAX, .Linear, fmt.tprintf("%.0f pt", n.edge_size), enabled = n.edge_orbit)
	_ = ui.switch_row(ctx, "Show the edges", &n.edge_show, enabled = n.edge_orbit)
	ui.paragraph(ctx, "A drag that starts this close to an edge of the screen turns the view even over the model, so when the model fills the screen there is still somewhere to turn it from. Ctrl keeps the edges for mask and hide shapes.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PAN AND ZOOM")
	speed_slider(ctx, "Pan speed", &n.pan_speed)
	speed_slider(ctx, "Zoom speed", &n.zoom_speed)
	_ = ui.switch_row(ctx, "Invert the mouse wheel", &n.invert_wheel)
	ui.spacer(ctx, 8)
	ui.caption(ctx, "WITH A MOUSE")
	ui.paragraph(ctx, "Help > Keys lists every mouse control, as the tool now has them.")
	if ui.button(ctx, "Mouse controls", .Bordered, glyph = ui.ICON_HELP, keys = command_hint(app, .Help, int(Help_Tab.Keys))) do command_run(app, .Help, int(Help_Tab.Keys))
}

@(private = "file")
settings_touch :: proc(app: ^App) {
	ctx := &app.kit.ctx
	n := &app.nav
	ui.caption(ctx, "ONE FINGER")
	model := [len(Finger_Model)]string{"Sculpts", "Turns the view"}
	ui.label(ctx, "On the model")
	if picked := ui.tabs(ctx, "Finger on the model", model[:], int(n.finger_model)); picked >= 0 do n.finger_model = Finger_Model(picked)
	ui.paragraph(ctx, "On empty space one finger always turns the view. Turns the view leaves sculpting to the pen, as on a drawing tablet.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PEN AND MOUSE ON EMPTY SPACE")
	empty := [len(Empty_Drag)]string{"Turns the view", "Waits for the model"}
	ui.label(ctx, "Pen")
	if picked := ui.tabs(ctx, "Pen on empty space", empty[:], int(n.empty_drag[.Pen])); picked >= 0 do n.empty_drag[.Pen] = Empty_Drag(picked)
	ui.label(ctx, "Mouse")
	if picked := ui.tabs(ctx, "Mouse on empty space", empty[:], int(n.empty_drag[.Mouse])); picked >= 0 do n.empty_drag[.Mouse] = Empty_Drag(picked)
	ui.paragraph(ctx, "Waits for the model: a stroke that starts off the model begins once it reaches it.")
	_ = ui.switch_row(ctx, "Ignore the hand while the pen is near", &n.palm_rejection)
	ui.paragraph(ctx, "A single finger does nothing while the pen is near the screen; two fingers still move the view.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "GESTURES")
	_ = ui.switch_row(ctx, "Pinch to zoom", &n.pinch_zoom)
	_ = ui.switch_row(ctx, "Zoom toward the fingers", &n.zoom_toward, enabled = n.pinch_zoom)
	_ = ui.switch_row(ctx, "Two-finger drag pans", &n.two_finger_pan)
	_ = ui.switch_row(ctx, "Twist two fingers to roll", &n.twist_roll, enabled = n.orbit_style == .Free)
	if n.orbit_style != .Free do ui.paragraph(ctx, "Rolling needs the Free orbit style (Camera).")
	_ = ui.switch_row(ctx, "Three fingers: size and strength", &n.three_finger)
	ui.paragraph(ctx, "Drag three fingers up and down for the brush size, sideways for its strength.")
	_ = ui.switch_row(ctx, "Tap two fingers to undo", &n.tap_history)
	ui.paragraph(ctx, "And three fingers to redo.")
	_ = ui.switch_row(ctx, "Hold two fingers to keep undoing", &n.hold_history)
	ui.paragraph(ctx, "Held still, two fingers undo again and again, three redo; a ring fills first. Never while the pen is near.")
	_ = ui.switch_row(ctx, "Lift one of two fingers to turn", &n.lift_one_orbit)
	ui.paragraph(ctx, "Put two fingers down, lift one, and the other turns the view: for when the model fills the screen.")
	_ = ui.switch_row(ctx, "Double tap to frame or pin", &n.double_tap)
	ui.paragraph(ctx, "Double tap empty space to frame the selected object, or the model to turn about that point. A single tap's dab then lands a moment later, once no second tap came.")
}

@(private = "file")
settings_performance :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, "STATISTICS")
	_ = ui.switch_row(ctx, "Show statistics", &k.stats, keys = command_hint(app, .Stats))
	detail := [2]string{"Simple", "Advanced"}
	if picked := ui.tabs(ctx, "Statistics detail", detail[:], int(k.stats_advanced)); picked >= 0 do k.stats_advanced = picked == 1
	ui.paragraph(ctx, "Simple shows how smooth the app runs in plain words; Advanced shows every measurement by its exact name, the drawing switches for comparing speed included. F11 shows and hides the panel.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "DISPLAY")
	_ = ui.switch_row(ctx, "VSync", &app.vsync)
	ui.paragraph(ctx, "Draws in step with the screen's refresh: no tearing, and no frames drawn that the screen would never show. Off, frames come as fast as they can, which lowers input delay a little.")
}

// A speed from a quarter to four times the default, equal steps doubling it.
@(private = "file")
speed_slider :: proc(ctx: ^ui.Context, label: string, value: ^f32) {
	_ = ui.slider(ctx, label, value, 0.25, 4, .Logarithmic, fmt.tprintf("%.2fx", value^))
}

// A command's keys for a sentence, or `fallback` when it has none (the user took them).
@(private = "file")
key_or :: proc(keys, fallback: string) -> string {
	return keys if keys != "" else fallback
}
