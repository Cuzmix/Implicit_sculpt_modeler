package main

import "core:fmt"
import "core:strings"

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
	// "Performance" is wider than a fifth of the panel; the statistics and the frame rate are the
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
	top := kit_top()
	room := window_room(app, win^, top)
	if !win.moved do room -= side_panel_below(app, KIT_SETTINGS_W)
	inner := f32(KIT_SETTINGS_W - 2 * 16)

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "settings", "Settings", win, .End, .Start, {kit_right(app), top}, {direction = .Column, gap = 8, padding = 16, width = KIT_SETTINGS_W, radius = t.radius_large, background = .Panel, inert = !k.settings}, "Esc")
	raised = raised_now
	if closed do settings_close(app)
	if !body {
		ui.window_end(ctx)
		ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
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
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
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
		k.look = .Studio
		k.ui_scale = 1
		k.ctx.reduced_motion = false
		k.ctx.mirror = false
		k.surface_ring = true
		k.action_bar = true
		k.rail_side, k.wheel_size, k.wheel_offset = .Left, .Medium, {}
		k.wheel_labels, k.wheel_turn = .Icons, 0
		k.all_options = false
		k.dock = DOCK_DEFAULT
		windows_reset(k)
	case .Camera:
		n.orbit_style, n.limit_pitch, n.orbit_speed, n.pan_speed, n.zoom_speed = d.orbit_style, d.limit_pitch, d.orbit_speed, d.pan_speed, d.zoom_speed
		n.invert_x, n.invert_y, n.invert_wheel = d.invert_x, d.invert_y, d.invert_wheel
		n.pivot, n.edge_orbit, n.edge_size, n.edge_show = d.pivot, d.edge_orbit, d.edge_size, d.edge_show
		n.air_pivot, n.pivot_dot, n.wheel_toward = d.air_pivot, d.pivot_dot, d.wheel_toward
	case .Touch:
		n.finger_model, n.empty_drag, n.palm_rejection = d.finger_model, d.empty_drag, d.palm_rejection
		n.pinch_zoom, n.two_finger_pan, n.zoom_toward, n.twist_roll = d.pinch_zoom, d.two_finger_pan, d.zoom_toward, d.twist_roll
		n.three_finger, n.gestures, n.touch_strength, n.hold_delay = d.three_finger, d.gestures, d.touch_strength, d.hold_delay
		n.double_tap, n.lift_one_orbit = d.double_tap, d.lift_one_orbit
		n.shape_apply, n.pen_tips = d.shape_apply, d.pen_tips
	case .Keys:
		bind_reset_all(app)
		n.mouse_scheme = d.mouse_scheme
		k.keys_query = {}
	case .Performance:
		k.stats, k.stats_advanced = false, false
		app.frame_rate, app.frame_limit = .Match_Display, FRAME_LIMIT_DEFAULT
		app.idle_sleep = true
		app.msaa = MSAA_DEFAULT
		app.autosave.minutes = AUTOSAVE_DEFAULT_MINUTES
		app.versions_kept = VERSIONS_DEFAULT
		app.undo_steps = 0
	}
}

@(private = "file")
settings_interface :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ui.caption(ctx, "LOOK")
	looks: [len(Look)]string
	for l in Look do looks[int(l)] = LOOK_NAMES[l]
	if picked := ui.tabs(ctx, "Look", looks[:], int(k.look)); picked >= 0 do k.look = Look(picked)
	ui.paragraph(ctx, "Studio is neutral grey with an orange accent, so the clay's own colour reads true; Graphite is the cooler dark grey with a blue accent.")
	ui.spacer(ctx, 8)
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
	ui.caption(ctx, "SCREEN LAYOUT")
	hands := [2]string{"Right-handed", "Left-handed"}
	if picked := ui.tabs(ctx, "Screen layout", hands[:], int(ctx.mirror)); picked >= 0 do ctx.mirror = picked == 1
	ui.paragraph(ctx, "Left-handed swaps the sides: the brush bar, the wheel and the readouts go to the right; the navigation, the view bar and the palettes to the left.")
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
	ui.caption(ctx, "MODIFIER WHEEL")
	// The tabs name the sides as they are on the screen: in the left-handed layout the
	// wheel's place by the brush bar is on the right.
	sides := [len(Rail_Side)]string{"Off", "Left", "Right"}
	on_screen :: proc(side: int, mirror: bool) -> int {
		return 3 - side if mirror && side > 0 else side
	}
	if picked := ui.tabs(ctx, "Modifier wheel", sides[:], on_screen(int(k.rail_side), ctx.mirror)); picked >= 0 {
		k.rail_side, k.wheel_offset = Rail_Side(on_screen(picked, ctx.mirror)), {}
	}
	ui.label(ctx, "Size")
	sizes: [len(Wheel_Size)]string
	for name, s in WHEEL_SIZE_NAMES do sizes[s] = name
	if picked := ui.tabs(ctx, "Wheel size", sizes[:], int(k.wheel_size)); picked >= 0 do k.wheel_size = Wheel_Size(picked)
	ui.label(ctx, "Sectors show")
	labels := [len(Wheel_Labels)]string{"Icons", "Icons and names", "Names"}
	if picked := ui.tabs(ctx, "Wheel sectors show", labels[:], int(k.wheel_labels)); picked >= 0 do k.wheel_labels = Wheel_Labels(picked)
	if ui.slider(ctx, "Wheel turn", &k.wheel_turn, -180, 180, .Linear, fmt.tprintf("%.0f°", k.wheel_turn)) do k.wheel_turn = wheel_turn_snapped(k.wheel_turn)
	ui.paragraph(ctx, "Smooth (top), Mask (left) and Invert (bottom) for what Shift, Ctrl and Alt do, and the brush pie on the right. Tap one to keep it on until tapped again; hold one with a finger to use it only while held, sculpting with the pen or another finger. Smooth and Mask together hide, as Shift and Ctrl do. Drag the middle to move the wheel; picking a side puts it back. Two fingers on the ring spread or pinch to resize it and twist to turn it.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "INSPECTOR")
	_ = ui.switch_row(ctx, "Show every option", &k.all_options)
	ui.paragraph(ctx, "Each section of the tray shows its common controls and keeps the rest under More options. On, every section shows everything.")
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
	// The default first; Free is the trackball.
	order := [len(camera.Orbit_Style)]camera.Orbit_Style{.Turntable, .Free, .Axis_X, .Axis_Z}
	styles := [len(camera.Orbit_Style)]string{"Turntable", "Trackball", "X axis", "Z axis"}
	at := 0
	for style, i in order do if style == n.orbit_style do at = i
	if picked := ui.tabs(ctx, "Orbit style", styles[:], at); picked >= 0 do n.orbit_style = order[picked]
	switch n.orbit_style {
	case .Turntable:
		ui.paragraph(ctx, "The default, as most 3D apps orbit: sideways turns about the model's up axis (Y) and up and down tilts, so the horizon stays level. Goes all the way round both ways, over the top too.")
	case .Free:
		ui.paragraph(ctx, "ZBrush's own: a drag turns the model about the screen's own axes, like rolling a ball, so any view is one drag away and the view may end up tilted. Two fingers twist to roll only in this style.")
	case .Axis_X, .Axis_Z:
		ui.paragraph(ctx, fmt.tprintf("Sideways turns about the world's %s axis; up and down turns freely, as Trackball does. Which way round is decided as each drag begins, so the model follows the pointer.", "X" if n.orbit_style == .Axis_X else "Z"))
	}
	_ = ui.switch_row(ctx, "Stop at the top and bottom", &n.limit_pitch, enabled = n.orbit_style == .Turntable)
	speed_slider(ctx, "Orbit speed", &n.orbit_speed)
	_ = ui.switch_row(ctx, "Invert sideways orbit", &n.invert_x)
	_ = ui.switch_row(ctx, "Invert up and down orbit", &n.invert_y)
	ui.label(ctx, "Turn about")
	// Too many for tabs at the panel's width: a list, the default first and the fixed
	// points last.
	pivot_order := [len(Orbit_Pivot)]Orbit_Pivot{.Stroke, .Pointer, .Selection, .Scene, .Centre}
	pivots := [len(Orbit_Pivot)]string{"Last stroke", "Pointer", "Selected objects", "Whole scene", "View centre"}
	pivot_at := 0
	for p, i in pivot_order do if p == n.pivot do pivot_at = i
	if picked := ui.select(ctx, "Orbit pivot", pivots[:], pivot_at); picked >= 0 do n.pivot = pivot_order[picked]
	switch n.pivot {
	case .Stroke:
		ui.paragraph(ctx, "The default: the view turns about the middle of your last stroke, which stays where it is on screen, so the part you work on stays in view. Before any stroke, and after Focus, about the selected object's middle.")
	case .Pointer:
		ui.paragraph(ctx, "A drag that starts on the model turns about the spot under it.")
	case .Selection:
		ui.paragraph(ctx, "The view turns about the middle of the selected objects, wherever you sculpt.")
	case .Scene:
		ui.paragraph(ctx, "The view turns about the middle of everything shown, so the scene turns as one piece.")
	case .Centre:
		ui.paragraph(ctx, "The view turns about the middle of the screen, wherever the model is.")
	}
	_ = ui.switch_row(ctx, "Off the model, turn about the air", &n.air_pivot, enabled = n.pivot == .Pointer)
	if n.pivot == .Pointer do ui.paragraph(ctx, "A drag that starts off the model turns about the point under it, as deep as the middle of the view." if n.air_pivot else "A drag that starts off the model turns about the last stroke.")
	_ = ui.switch_row(ctx, "Show the pivot dot", &n.pivot_dot)
	ui.paragraph(ctx, "A double tap on the model pins the pivot there until the next stroke, whatever Turn about says.")
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
	_ = ui.switch_row(ctx, "Wheel zooms toward the pointer", &n.wheel_toward)
	ui.paragraph(ctx, "What is under the pointer stays there as the wheel zooms, as a pinch keeps what is between the fingers. Off, the wheel zooms toward the middle.")
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
	_ = ui.slider(ctx, "Touch strength", &n.touch_strength, TOUCH_STRENGTH_MIN, 1, .Linear, fmt.tprintf("%.0f%%", 100 * n.touch_strength), enabled = n.finger_model == .Sculpt)
	ui.paragraph(ctx, "A finger's strokes work at this much of the brush's strength, so a finger can soften what the pen builds up. The pen and the mouse always work at full strength.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PRESS AND HOLD")
	// In steps of 0.05 s, so the value shown is the value used.
	if ui.slider(ctx, "Hold delay", &n.hold_delay, HOLD_DELAY_MIN, HOLD_DELAY_MAX, .Linear, fmt.tprintf("%.2f s", n.hold_delay)) do n.hold_delay = f32(int(n.hold_delay * 20 + 0.5)) / 20
	ui.paragraph(ctx, "How long a finger or the pen holds a button still before its long press: dragging Draw size, Strength or Focal shift on the brush bar, a button's menu, a name and shortcut. Shorter is quicker; longer leaves more time for a slow tap.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PEN AND MOUSE ON EMPTY SPACE")
	empty := [len(Empty_Drag)]string{"Turns the view", "Waits for the model"}
	ui.label(ctx, "Pen")
	if picked := ui.tabs(ctx, "Pen on empty space", empty[:], int(n.empty_drag[.Pen])); picked >= 0 do n.empty_drag[.Pen] = Empty_Drag(picked)
	ui.label(ctx, "Mouse")
	if picked := ui.tabs(ctx, "Mouse on empty space", empty[:], int(n.empty_drag[.Mouse])); picked >= 0 do n.empty_drag[.Mouse] = Empty_Drag(picked)
	ui.paragraph(ctx, "Waits for the model: a stroke that starts off the model begins once it reaches it.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "PEN")
	ui.label(ctx, "Names while the pen hovers")
	tips := [len(Pen_Tips)]string{"Always", "With a keyboard", "Never"}
	if picked := ui.tabs(ctx, "Pen hover names", tips[:], int(n.pen_tips)); picked >= 0 do n.pen_tips = Pen_Tips(picked)
	ui.paragraph(ctx, "The pen held over a control without touching shows its name and shortcut, as the mouse resting on it does. With a keyboard shows them only while one is connected; a long press always shows them.")
	_ = ui.switch_row(ctx, "Ignore the hand while the pen is near", &n.palm_rejection)
	ui.paragraph(ctx, "A single finger does nothing while the pen is near the screen; two fingers still move the view.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "GESTURES")
	_ = ui.switch_row(ctx, "Pinch to zoom", &n.pinch_zoom)
	_ = ui.switch_row(ctx, "Zoom toward the fingers", &n.zoom_toward, enabled = n.pinch_zoom)
	_ = ui.switch_row(ctx, "Two-finger drag pans", &n.two_finger_pan)
	_ = ui.switch_row(ctx, "Twist two fingers to roll", &n.twist_roll, enabled = n.orbit_style == .Free)
	if n.orbit_style != .Free do ui.paragraph(ctx, "Rolling needs the Trackball orbit style (Camera).")
	_ = ui.switch_row(ctx, "Three fingers: size and focal shift", &n.three_finger)
	ui.paragraph(ctx, "Drag three fingers up and down for the brush size, sideways for its focal shift. Strength, like size and focal shift, follows a long press dragged up or down on its button on the brush bar.")
	_ = ui.switch_row(ctx, "Lift one of two fingers to turn", &n.lift_one_orbit)
	ui.paragraph(ctx, "Put two fingers down, lift one, and the other turns the view: for when the model fills the screen.")
	_ = ui.switch_row(ctx, "Double tap to frame or pin", &n.double_tap)
	ui.paragraph(ctx, "Double tap empty space to frame the selected object, or the model to turn about that point. A single tap's dab then lands a moment later, once no second tap came.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "SHAPES")
	applies := [len(Shape_Apply)]string{"Mouse at once", "Always at once", "Always after Apply"}
	ui.label(ctx, "Mask, hide and clip shapes apply")
	if picked := ui.tabs(ctx, "Shapes apply", applies[:], int(n.shape_apply)); picked >= 0 do n.shape_apply = Shape_Apply(picked)
	ui.paragraph(ctx, "Mouse at once: a shape drawn with the mouse applies as it lets go; one drawn with a finger or the pen waits with Apply, Flip and Cancel under it, its corners and middle to drag and the view free to turn first.")
	ui.spacer(ctx, 8)
	settings_gesture_map(app)
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
	frame_rate_controls(app)
	_ = ui.switch_row(ctx, "Rest when idle", &app.idle_sleep)
	ui.paragraph(ctx, "When nothing on screen has changed for a second, waits for your next touch, key or pen instead of drawing the same frame again, which saves the battery and keeps the fans quiet. The first stroke after a rest is not delayed.")
	ui.label(ctx, "Anti-aliasing")
	if picked := ui.tabs(ctx, "Anti-aliasing", MSAA_NAMES[:], int(app.msaa)); picked >= 0 do app.msaa = Msaa(picked)
	ui.paragraph(ctx, "Smooths the stepped edges of outlines and wireframe lines by taking 2 or 4 samples a pixel. It costs GPU memory and a little time every frame; Off draws as fast as it can.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "AUTOSAVE")
	a := &app.autosave
	chosen := 0
	minutes := autosave_minutes(a.minutes)
	for m, i in AUTOSAVE_MINUTES do if m == minutes do chosen = i
	ui.label(ctx, "Save a recovery copy")
	if picked := ui.select(ctx, "Autosave interval", AUTOSAVE_MINUTE_NAMES[:], chosen); picked >= 0 do a.minutes = AUTOSAVE_MINUTES[picked]
	ui.paragraph(ctx, autosave_status(app), color = ctx.theme.warning if a.failed else ctx.theme.text_secondary)
	ui.paragraph(ctx, "Written in the background once you pause, never during a stroke. If Sculpt closes unexpectedly, the next start offers it back.")
	_ = command_button(app, .Open_Last_Autosave)
	ui.spacer(ctx, 8)
	ui.caption(ctx, "EARLIER SAVES")
	kept := versions_kept(app.versions_kept)
	chosen = 0
	for n, i in VERSIONS_KEPT do if n == kept do chosen = i
	ui.label(ctx, "Keep the files a save replaces")
	if picked := ui.select(ctx, "Earlier saves kept", VERSIONS_KEPT_NAMES[:], chosen); picked >= 0 do app.versions_kept = VERSIONS_KEPT[picked]
	ui.paragraph(ctx, "Saving over a scene file first keeps the old one in a folder beside it (for head.sculpt, \"head versions\"), the newest ones kept. Off keeps none and deletes none already there.")
	ui.spacer(ctx, 8)
	ui.caption(ctx, "UNDO HISTORY")
	chosen = 0
	for n, i in UNDO_STEPS do if n == app.undo_steps do chosen = i
	ui.label(ctx, "Undo steps kept")
	if picked := ui.select(ctx, "Undo steps kept", UNDO_STEPS_NAMES[:], chosen); picked >= 0 do app.undo_steps = UNDO_STEPS[picked]
	ui.paragraph(ctx, "Past this many steps the oldest are forgotten, and the memory their strokes hold comes back. No limit keeps steps until they fill the memory set aside for them. The History panel's Delete older history forgets them all at once.")
	when LINK_AVAILABLE {
		ui.spacer(ctx, 8)
		ui.caption(ctx, "BLENDER LINK")
		folder := app.link.folder
		// A path has no spaces to wrap at: its end, which names the folder, is what shows,
		// and Copy path gives the whole of it.
		shown := "This run keeps no settings, so it has no link folder." if folder == "" else text_fit_end(ctx, folder, ctx.theme.small_size, KIT_SETTINGS_W - 2 * 16)
		ui.paragraph(ctx, shown, color = ctx.theme.text_secondary)
		if ui.button(ctx, "Copy path", .Bordered, enabled = folder != "") {
			link_copy_path(app)
		}
		half := (KIT_SETTINGS_W - 2 * 16 - 8) / f32(2)
		ui.begin(ctx, "link buttons", {direction = .Row, gap = 8})
		_ = command_button(app, .Send_To_Blender, width = half)
		_ = command_button(app, .Get_From_Blender, width = half)
		ui.end(ctx)
		ui.paragraph(ctx, "Install the add-on in tools/blender in Blender, give it this folder, then Send to Blender here and Get from Sculpt there; Send to Sculpt there comes back here when you switch to Sculpt, or with Get from Blender.")
	}
}

// `s` as it fits in `width` points: whole, or its end with "..." before it.
@(private = "file")
text_fit_end :: proc(ctx: ^ui.Context, s: string, size, width: f32) -> string {
	if ui.text_width(ctx, s, size) <= width do return s
	room := width - ui.text_width(ctx, "...", size)
	start := len(s)
	for _, i in s {
		if ui.text_width(ctx, s[i:], size) <= room {
			start = i
			break
		}
	}
	return strings.concatenate({"...", s[start:]}, context.temp_allocator)
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
