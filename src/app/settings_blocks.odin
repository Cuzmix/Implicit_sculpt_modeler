package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../camera"
import "../ui"

// Settings' blocks: each caption's group of rows, drawn and put back on its own, so
// the narrow panel's tabs and the sheet's sections (lens_settings.odin) list the same blocks in their own
// orders, and Search settings finds a block by its caption and the words of its rows.

Settings_Block :: enum u8 {
	// Interface.
	Look,
	Size,
	Clean_Dial,
	Hands,
	Motion,
	Starting,
	Brush_Ring,
	Symmetry_Line,
	Column_Popovers,
	View_Grid,
	Bars,
	Action_Bar,
	Wheel,
	Inspector,
	Pies,
	Panel_Places,
	// Camera.
	Orbit,
	Safe_Zone,
	Pan_Zoom,
	Mouse,
	// Touch.
	Finger_Model,
	Touch_Strength,
	Hold,
	Pen_Empty,
	Pen_Tips,
	Pen_Predict,
	Pen_Buttons,
	Pen_Areas,
	Palm,
	Gesture_Switches,
	Shapes,
	Gesture_Map,
	// Lens's Touch section: the gestures as rows with what each does, and the switches
	// that list leaves.
	Gesture_List,
	Gesture_More,
	Finger_Sculpts,
	// Keys.
	Keys,
	// System.
	Statistics,
	Frame_Rate,
	Anti_Aliasing,
	Graphics,
	Autosave,
	Earlier_Saves,
	Undo_History,
	History_Steps,
	History_Back,
	Blender_Link,
	Printer,
}

// A block in a tab or a section, under `caption` ("" goes on under the one before).
Settings_Entry :: struct {
	block:   Settings_Block,
	caption: string,
}

// The tabs of the Settings panel, which a window too small for the sheet (lens_settings.odin)
// shows, as they have always been laid out.
@(rodata)
SETTINGS_INTERFACE := [?]Settings_Entry {
	{.Look, "LOOK"},
	{.Size, "SIZE"},
	{.Clean_Dial, "CLEAN VIEW"},
	{.Hands, "SCREEN LAYOUT"},
	{.Motion, "MOTION"},
	{.Starting, "STARTING"},
	{.Brush_Ring, "BRUSH RING"},
	{.Symmetry_Line, "SYMMETRY"},
	{.Column_Popovers, "PANELS"},
	{.View_Grid, "VIEW GRID"},
	{.Bars, "BARS"},
	{.Action_Bar, "ACTION BAR"},
	{.Wheel, "MODIFIER WHEEL"},
	{.Inspector, "INSPECTOR"},
	{.Pies, "PIES"},
	{.Panel_Places, "PANELS"},
}
@(rodata)
SETTINGS_CAMERA := [?]Settings_Entry{{.Orbit, "ORBIT"}, {.Safe_Zone, "SAFE ZONE"}, {.Pan_Zoom, "PAN AND ZOOM"}, {.Mouse, "WITH A MOUSE"}}
@(rodata)
SETTINGS_TOUCH := [?]Settings_Entry {
	{.Finger_Model, "ONE FINGER"},
	{.Touch_Strength, ""},
	{.Hold, "PRESS AND HOLD"},
	{.Pen_Empty, "PEN AND MOUSE ON EMPTY SPACE"},
	{.Pen_Tips, "PEN"},
	{.Pen_Predict, ""},
	{.Pen_Buttons, ""},
	{.Palm, ""},
	{.Gesture_Switches, "GESTURES"},
	{.Shapes, "SHAPES"},
	// It draws its own caption.
	{.Gesture_Map, ""},
	{.Pen_Areas, "WHERE THE PEN POINTS"},
}
@(rodata)
SETTINGS_KEYS := [?]Settings_Entry{{.Keys, ""}}
@(rodata)
SETTINGS_SYSTEM := [?]Settings_Entry {
	{.Statistics, "STATISTICS"},
	{.Frame_Rate, "DISPLAY"},
	{.Anti_Aliasing, ""},
	{.Graphics, ""},
	{.Autosave, "AUTOSAVE"},
	{.Earlier_Saves, "EARLIER SAVES"},
	{.Undo_History, "UNDO HISTORY"},
	{.History_Steps, "WHAT BECOMES A STEP"},
	{.History_Back, "GOING BACK"},
	{.Blender_Link, "BLENDER LINK"},
	{.Printer, "3D PRINTER"},
}

// The blocks of the narrow panel's tab `tab`.
settings_tab_entries :: proc(tab: Settings_Tab) -> []Settings_Entry {
	switch tab {
	case .Interface:   return SETTINGS_INTERFACE[:]
	case .Camera:      return SETTINGS_CAMERA[:]
	case .Touch:       return SETTINGS_TOUCH[:]
	case .Keys:        return SETTINGS_KEYS[:]
	case .Performance: return SETTINGS_SYSTEM[:]
	}
	return nil
}

// The words Search settings finds a block by, besides its caption: its rows' labels and
// what they are called elsewhere, in lower case.
@(rodata)
SETTINGS_BLOCK_WORDS := [Settings_Block]string {
	.Look             = "look theme colour color lens studio graphite accent dark",
	.Size             = "size interface scale bigger text touch targets zoom",
	.Clean_Dial       = "keep the dial in clean view tab four-finger",
	.Hands            = "left-handed right-handed hand mirror screen layout",
	.Motion           = "reduce motion animation",
	.Starting         = "start at home starting launch",
	.Brush_Ring       = "brush ring cursor surface circle",
	.Symmetry_Line    = "symmetry line plane mirror mirrored brush ring point radial axis",
	.Column_Popovers  = "stack columns pop over narrow window panels",
	.View_Grid        = "view grid panes views run under panels work in any view",
	.Bars             = "bars customise customize buttons dock",
	.Action_Bar       = "action bar next steps",
	.Wheel            = "dial modifier wheel side size sectors turn smooth mask invert",
	.Inspector        = "inspector show every option",
	.Pies             = "pies pie editor slices",
	.Panel_Places     = "reset panel positions panels move",
	.Orbit            = "orbit turntable trackball speed invert turn about pivot",
	.Safe_Zone        = "safe zone edges edge width",
	.Pan_Zoom         = "pan zoom speed mouse wheel pointer",
	.Mouse            = "mouse controls",
	.Finger_Model     = "one finger on the model sculpts turns the view tap switch object mesh select",
	.Touch_Strength   = "touch strength finger",
	.Hold             = "press and hold delay long press",
	.Pen_Empty        = "pen mouse empty space waits for the model",
	.Pen_Tips         = "pen hover names tooltips",
	.Pen_Predict      = "predict the cursor brush ring ahead latency lag pen",
	.Pen_Buttons      = "pen barrel eraser end flip",
	.Pen_Areas        = "apple pencil pen roll barrel twist turn hover model empty space double tap squeeze where side second button",
	.Palm             = "palm rejection ignore the hand pen near",
	.Gesture_Switches = "gestures pinch zoom two-finger pan twist roll three fingers lift double tap",
	.Shapes           = "shapes mask hide clip apply",
	.Gesture_Map      = "gesture map tap hold fingers pen side button undo redo",
	.Gesture_List     = "gestures one finger empty space two fingers three fingers tap hold pen side button undo redo clean view pinch zoom pan roll",
	.Gesture_More     = "zoom about the fingers lift one of two fingers double tap frame pin",
	.Finger_Sculpts   = "palm pen ignore touches finger can sculpt tap switch object mesh",
	.Keys             = "keys shortcuts keyboard bindings mouse buttons",
	.Statistics       = "statistics stats simple advanced",
	.Frame_Rate       = "frame rate fps limit unlimited match display rest when idle battery low latency frames in flight lag",
	.Anti_Aliasing    = "anti-aliasing antialiasing msaa display",
	.Graphics         = "graphics gpu backend vulkan sdl_gpu metal driver renderer async compute ray tracing hardware rtx",
	.Autosave         = "autosave recovery copy",
	.Earlier_Saves    = "earlier saves versions kept",
	.Undo_History     = "undo history steps memory limit may use mb gb meshes textures device",
	.History_Steps    = "history steps lights scene tree names folders order undo",
	.History_Back     = "history camera follows restore view group repeated strokes list scrub slide two fingers quick step pictures thumbnails",
	.Blender_Link     = "blender link add-on folder",
	.Printer          = "3d printer bed plate size wall thickness thinnest print checks",
}

// Whether block `e` matches the search `q` (lower case, trimmed): by its caption, its
// words, or the section it is in (`section`, lower case).
settings_entry_matches :: proc(e: Settings_Entry, q, section: string) -> bool {
	if q == "" do return true
	if strings.contains(strings.to_lower(e.caption, context.temp_allocator), q) do return true
	if strings.contains(SETTINGS_BLOCK_WORDS[e.block], q) do return true
	return strings.contains(section, q)
}

// Draws `entries` one after another, each caption after a gap, the blocks without
// one going on under the block before.
settings_entries_draw :: proc(app: ^App, entries: []Settings_Entry, q := "", section := "") {
	ctx := &app.kit.ctx
	first := true
	for e in entries {
		if !settings_entry_matches(e, q, section) do continue
		if e.caption != "" {
			if !first do ui.spacer(ctx, 8)
			ui.caption(ctx, e.caption)
		}
		settings_block(app, e.block)
		first = false
	}
}

// Draws block `b`'s rows.
settings_block :: proc(app: ^App, b: Settings_Block) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	n := &app.nav
	switch b {
	case .Look:
		looks: [len(Look)]string
		for l in Look do looks[int(l)] = LOOK_NAMES[l]
		if picked := ui.tabs(ctx, "Look", looks[:], int(k.look)); picked >= 0 do k.look = Look(picked)
		ui.paragraph(ctx, "Lens frames the views in near-black with a sea-green accent no clay is near; Studio is neutral grey with an orange accent; Graphite is the cooler dark grey with a blue accent.")
	case .Size:
		names: [len(UI_SCALES)]string
		chosen := 0
		for s, i in UI_SCALES {
			names[i] = fmt.tprintf("%.0f%%", s * 100)
			if abs(s - k.ui_scale) < 0.01 do chosen = i
		}
		if picked := ui.select(ctx, "Interface size", names[:], chosen); picked >= 0 do k.ui_scale = UI_SCALES[picked]
		ui.paragraph(ctx, "How big panels, text and touch targets are, on top of the size the screen asks for.")
	case .Clean_Dial:
		_ = ui.switch_row(ctx, "Keep the dial in clean view", &k.clean_dial)
		ui.paragraph(ctx, "Clean view (Tab, or a four-finger tap) hides every control so you can judge the form; the dial stays unless this is off, so you can still smooth and mask.")
	case .Hands:
		hands := [2]string{"Right-handed", "Left-handed"}
		if picked := ui.tabs(ctx, "Screen layout", hands[:], int(ctx.mirror)); picked >= 0 do ctx.mirror = picked == 1
		ui.paragraph(ctx, "Left-handed swaps the sides: Size and Strength, the dial and the view chips go to the right; the navigation, the view rail and the panels to the left.")
	case .Motion:
		settings_motion(app)
	case .Starting:
		_ = ui.switch_row(ctx, "Start at Home", &app.start_home)
		ui.paragraph(ctx, "Opens on the Home screen, with new scenes and pictures of the scenes you saved lately; off, it opens straight on a sphere. Opening a scene file with the app skips Home either way.")
	case .Brush_Ring:
		_ = ui.switch_row(ctx, "Lay the brush ring on the surface", &k.surface_ring)
		ui.paragraph(ctx, "Over the model the ring tilts with the surface under it, with a tick showing which way it faces, as in ZBrush; off, it stays a flat circle on the screen.")
	case .Symmetry_Line:
		_ = ui.switch_row(ctx, "Show the symmetry line", &k.symmetry_line)
		ui.paragraph(ctx, "While symmetry is on, a thin line in each plane's colour (X red, Y green, Z blue) runs where the plane crosses the selected object, and with Radial a line along its axis. The brush ring always shows a copy with a dot at every mirrored spot.")
	case .Column_Popovers:
		_ = ui.switch_row(ctx, "The stack pops over a narrow window", &k.column_popovers)
		ui.paragraph(ctx, "On a window under 1180 points wide, the docked panel stack shows only while you ask for it: from the tab at its top, by opening a card or a section, or with Palettes; a press on the view, or Escape, puts it away. Off, it stays beside the view as on a wide window.")
	case .View_Grid:
		_ = ui.switch_row(ctx, "Work in any view", &k.panes_work)
		ui.paragraph(ctx, "A press in any pane works there, as Blender's quad views each take the tools; off, the other panes only show.")
	case .Bars:
		_ = command_button(app, .Customise_Bars, glyph = ICON_CUSTOMISE)
		ui.paragraph(ctx, "Choose the buttons down the view rail, on each of the shelf's pages and in its tools after All: any command, in any order.")
	case .Action_Bar:
		_ = ui.switch_row(ctx, "Show next steps over the shelf", &k.action_bar)
		ui.paragraph(ctx, "While the selected object has a mask, hidden parts or an HD window open, buttons over the brushes offer what usually comes next: invert or blur the mask, show everything, leave HD.")
	case .Wheel:
		// The tabs name the sides as they are on the screen: in the left-handed layout the
		// wheel's place by the off-hand island is on the right.
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
		ui.paragraph(ctx, "As it comes: Smooth (top), Mask (left) and Invert (bottom) for what Shift, Ctrl and Alt do, and the brush pie on the right; Arrange's Library > Dial puts any of them, Hide or a command on each sector. Tap one to keep it on until tapped again; hold one with a finger to use it only while held, sculpting with the pen or another finger. Smooth and Mask together hide, as Shift and Ctrl do. Drag the middle to move the wheel; picking a side puts it back. Two fingers on the ring spread or pinch to resize it and twist to turn it.")
	case .Inspector:
		_ = ui.switch_row(ctx, "Show every option", &k.all_options)
		ui.paragraph(ctx, "Each section of the tray shows its common controls and keeps the rest under More options. On, every section shows everything.")
	case .Pies:
		// Beside the button that opened it, rather than at the top of the window.
		if command_button(app, .Pie_Editor, variant = .Bordered, glyph = ui.ICON_PIE) do k.pie_editor_at = ctx.last_rect
		ui.paragraph(ctx, fmt.tprintf("%s opens Pie 1 at the pointer and %s Pie 2; tap a slice to run it. Search puts any command in a pie (Put in a pie); here you can empty slots or put the defaults back.", key_or(command_keys(app, .Pie, 0), "Pie 1's key"), key_or(command_keys(app, .Pie, 1), "Pie 2's")))
	case .Panel_Places:
		if ui.button(ctx, "Reset panel positions", .Bordered) do windows_reset(k)
		ui.paragraph(ctx, "Drag a panel by its title bar to move it; Minimise folds it to its title bar, Close hides it until it is opened again. This puts every panel back where it starts, unfolded.")

	case .Orbit:
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
			ui.paragraph(ctx, "ZBrush's own: a drag turns the model about the screen's own axes, like rolling a ball, so any view is one drag away and the view may end up tilted. Two fingers twist to roll.")
		case .Axis_X, .Axis_Z:
			ui.paragraph(ctx, fmt.tprintf("Sideways turns about the world's %s axis; up and down turns freely, as Trackball does. Which way round is decided as each drag begins, so the model follows the pointer.", "X" if n.orbit_style == .Axis_X else "Z"))
		}
		_ = ui.switch_row(ctx, "Stop at the top and bottom", &n.limit_pitch, enabled = n.orbit_style == .Turntable)
		_ = ui.switch_row(ctx, "Twist two fingers to roll the turntable", &n.turntable_roll, enabled = n.orbit_style == .Turntable)
		if n.orbit_style == .Turntable && n.turntable_roll do ui.paragraph(ctx, "Twisting two fingers tilts the turntable on screen, about the point between them; a drag still turns the model about its up axis, along the tilted screen, so it follows the finger. Twist back near level and it holds level.")
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
	case .Safe_Zone:
		_ = ui.switch_row(ctx, "Edges always turn the view", &n.edge_orbit)
		_ = ui.slider(ctx, "Edge width", &n.edge_size, EDGE_MIN, EDGE_MAX, .Linear, fmt.tprintf("%.0f pt", n.edge_size), enabled = n.edge_orbit)
		_ = ui.switch_row(ctx, "Show the edges", &n.edge_show, enabled = n.edge_orbit)
		ui.paragraph(ctx, "A drag that starts this close to an edge of the screen turns the view even over the model, so when the model fills the screen there is still somewhere to turn it from. Ctrl keeps the edges for mask and hide shapes.")
	case .Pan_Zoom:
		speed_slider(ctx, "Pan speed", &n.pan_speed)
		speed_slider(ctx, "Zoom speed", &n.zoom_speed)
		_ = ui.switch_row(ctx, "Invert the mouse wheel", &n.invert_wheel)
		_ = ui.switch_row(ctx, "Wheel zooms toward the pointer", &n.wheel_toward)
		ui.paragraph(ctx, "What is under the pointer stays there as the wheel zooms, as a pinch keeps what is between the fingers. Off, the wheel zooms toward the middle.")
	case .Mouse:
		ui.paragraph(ctx, "Help > Keys lists every mouse control, as the tool now has them.")
		if ui.button(ctx, "Mouse controls", .Bordered, glyph = ui.ICON_HELP, keys = command_hint(app, .Help, int(Help_Tab.Keys))) do command_run(app, .Help, int(Help_Tab.Keys))

	case .Finger_Model:
		model := [len(Finger_Model)]string{"Sculpts", "Turns the view"}
		ui.label(ctx, "On the model")
		if picked := ui.tabs(ctx, "Finger on the model", model[:], int(n.finger_model)); picked >= 0 do n.finger_model = Finger_Model(picked)
		ui.paragraph(ctx, "On empty space one finger always turns the view. Turns the view leaves sculpting to the pen, as on a drawing tablet.")
		pencil_only_note(app)
		_ = ui.switch_row(ctx, "Tap another object to switch to it", &n.tap_switches)
		ui.paragraph(ctx, "A quick finger tap on an object that is not the selected one selects it and sculpts nothing, so a finger switches meshes while the pen keeps sculpting. A tap on the selected object still lays a dab.")
	case .Touch_Strength:
		_ = ui.slider(ctx, "Touch strength", &n.touch_strength, TOUCH_STRENGTH_MIN, 1, .Linear, fmt.tprintf("%.0f%%", 100 * n.touch_strength), enabled = finger_model_now(app) == .Sculpt)
		ui.paragraph(ctx, "A finger's strokes work at this much of the brush's strength, so a finger can soften what the pen builds up. The pen and the mouse always work at full strength.")
	case .Hold:
		// In steps of 0.05 s, so the value shown is the value used.
		if ui.slider(ctx, "Hold delay", &n.hold_delay, HOLD_DELAY_MIN, HOLD_DELAY_MAX, .Linear, fmt.tprintf("%.2f s", n.hold_delay)) do n.hold_delay = f32(int(n.hold_delay * 20 + 0.5)) / 20
		ui.paragraph(ctx, "How long a finger or the pen holds a button still before its long press: a button's menu, a name and shortcut, or a brush value's menu (a drag on the island's sliders or across a value chip sets the value at once, with no hold). Shorter is quicker; below about 0.2 s a slow tap may open the menu instead, so longer leaves more time for one.")
	case .Pen_Empty:
		empty := [len(Empty_Drag)]string{"Turns the view", "Waits for the model"}
		ui.label(ctx, "Pen")
		if picked := ui.tabs(ctx, "Pen on empty space", empty[:], int(n.empty_drag[.Pen])); picked >= 0 do n.empty_drag[.Pen] = Empty_Drag(picked)
		ui.label(ctx, "Mouse")
		if picked := ui.tabs(ctx, "Mouse on empty space", empty[:], int(n.empty_drag[.Mouse])); picked >= 0 do n.empty_drag[.Mouse] = Empty_Drag(picked)
		ui.paragraph(ctx, "Waits for the model: a stroke that starts off the model begins once it reaches it.")
	case .Pen_Tips:
		ui.label(ctx, "Names while the pen hovers")
		tips := [len(Pen_Tips)]string{"Always", "With a keyboard", "Never"}
		if picked := ui.tabs(ctx, "Pen hover names", tips[:], int(n.pen_tips)); picked >= 0 do n.pen_tips = Pen_Tips(picked)
		ui.paragraph(ctx, "The pen held over a control without touching shows its name and shortcut, as the mouse resting on it does. With a keyboard shows them only while one is connected; a long press always shows them.")
	case .Pen_Predict:
		_ = ui.switch_row(ctx, "Predict the cursor", &n.predict_cursor)
		ui.paragraph(ctx, "While a stroke draws, the brush ring runs ahead to where the pen will be when the screen shows it, so it keeps up with a fast stroke. Only the ring: the stroke goes where the pen went.")
	case .Pen_Buttons:
		settings_pen_buttons(app)
	case .Pen_Areas:
		settings_pen_areas(app)
	case .Palm:
		_ = ui.switch_row(ctx, "Ignore the hand while the pen is near", &n.palm_rejection)
		ui.paragraph(ctx, "A single finger does nothing while the pen is near the screen; two fingers still move the view.")
	case .Gesture_Switches:
		_ = ui.switch_row(ctx, "Pinch to zoom", &n.pinch_zoom)
		_ = ui.switch_row(ctx, "Zoom and roll about the fingers", &n.zoom_toward, enabled = n.pinch_zoom || twist_rolls(n^))
		_ = ui.switch_row(ctx, "Two-finger drag pans", &n.two_finger_pan)
		_ = ui.switch_row(ctx, "Twist two fingers to roll", &n.twist_roll, enabled = n.orbit_style == .Free || n.orbit_style == .Turntable && n.turntable_roll)
		if n.twist_roll && !twist_rolls(n^) do ui.paragraph(ctx, "Rolling needs the Trackball orbit style, or Twist two fingers to roll the turntable (Camera).")
		_ = ui.switch_row(ctx, "Three fingers: size and focal shift", &n.three_finger)
		ui.paragraph(ctx, "Drag three fingers up and down for the brush size, sideways for its focal shift. Size and strength follow a drag up or down on the off-hand island's sliders too.")
		_ = ui.switch_row(ctx, "Lift one of two fingers to turn", &n.lift_one_orbit)
		ui.paragraph(ctx, "Put two fingers down, lift one, and the other turns the view: for when the model fills the screen.")
		_ = ui.switch_row(ctx, "Double tap to frame or pin", &n.double_tap)
		ui.paragraph(ctx, "Double tap empty space to frame the selected object, or the model to turn about that point. A single tap's dab then lands a moment later, once no second tap came.")
	case .Shapes:
		applies := [len(Shape_Apply)]string{"Mouse at once", "Always at once", "Always after Apply"}
		ui.label(ctx, "Mask, hide and clip shapes apply")
		if picked := ui.tabs(ctx, "Shapes apply", applies[:], int(n.shape_apply)); picked >= 0 do n.shape_apply = Shape_Apply(picked)
		ui.paragraph(ctx, "Mouse at once: a shape drawn with the mouse applies as it lets go; one drawn with a finger or the pen waits with Apply, Flip and Cancel under it, its corners and middle to drag and the view free to turn first.")
	case .Gesture_Map:
		ui.spacer(ctx, 8)
		settings_gesture_map(app)
	case .Gesture_List:
		lens_gesture_list(app)
	case .Gesture_More:
		_ = ui.switch_row(ctx, "Zoom and roll about the fingers", &n.zoom_toward, enabled = n.pinch_zoom || twist_rolls(n^))
		_ = ui.switch_row(ctx, "Lift one of two fingers to turn", &n.lift_one_orbit)
		_ = ui.switch_row(ctx, "Double tap to frame or pin", &n.double_tap)
		ui.paragraph(ctx, "Lift one of two fingers: the other turns the view, for when the model fills the screen. Double tap empty space to frame the selected object, or the model to turn about that point.")
	case .Finger_Sculpts:
		_ = ui.switch_row(ctx, "Ignore touches while the pen is near", &n.palm_rejection)
		sculpts := n.finger_model == .Sculpt
		if ui.switch_row(ctx, "Finger can sculpt when no pen is used", &sculpts) do n.finger_model = .Sculpt if sculpts else .Orbit
		_ = ui.switch_row(ctx, "Tap another object to switch to it", &n.tap_switches)
		ui.paragraph(ctx, "With the pen near, a resting hand does nothing; two fingers still move the view. Off, only the pen sculpts and a finger turns the view, as on a drawing tablet.")
		pencil_only_note(app)

	case .Keys:
		settings_keys(app)

	case .Statistics:
		_ = ui.switch_row(ctx, "Show statistics", &k.stats, keys = command_hint(app, .Stats))
		detail := [2]string{"Simple", "Advanced"}
		if picked := ui.tabs(ctx, "Statistics detail", detail[:], int(k.stats_advanced)); picked >= 0 do k.stats_advanced = picked == 1
		ui.paragraph(ctx, "Simple shows how smooth the app runs in plain words; Advanced shows every measurement by its exact name, the drawing switches for comparing speed included. F11 shows and hides the panel.")
		if app.diag.allowed {
			_ = command_button(app, .Input_Diagnostics)
			ui.paragraph(ctx, "A developer's screen of guided touch, Pencil and keyboard tests, with a report to export.")
		}
	case .Frame_Rate:
		frame_rate_controls(app)
		_ = ui.switch_row(ctx, "Rest when idle", &app.idle_sleep)
		ui.paragraph(ctx, "When nothing on screen has changed for a second, waits for your next touch, key or pen instead of drawing the same frame again, which saves the battery and keeps the fans quiet. The first stroke after a rest is not delayed.")
	case .Anti_Aliasing:
		ui.label(ctx, "Anti-aliasing")
		if picked := ui.tabs(ctx, "Anti-aliasing", MSAA_NAMES[:], int(app.msaa)); picked >= 0 do app.msaa = Msaa(picked)
		ui.paragraph(ctx, "Smooths the stepped edges of outlines and wireframe lines by taking 2 or 4 samples a pixel. It costs GPU memory and a little time every frame; Off draws as fast as it can.")
	case .Graphics:
		graphics_controls(app)
	case .Autosave:
		a := &app.autosave
		chosen := 0
		minutes := autosave_minutes(a.minutes)
		for m, i in AUTOSAVE_MINUTES do if m == minutes do chosen = i
		ui.label(ctx, "Save a recovery copy")
		if picked := ui.select(ctx, "Autosave interval", AUTOSAVE_MINUTE_NAMES[:], chosen); picked >= 0 do a.minutes = AUTOSAVE_MINUTES[picked]
		ui.paragraph(ctx, autosave_status(app), color = t.warning if a.failed else t.text_secondary)
		ui.paragraph(ctx, "Written in the background once you pause, never during a stroke. If Sculpt closes unexpectedly, the next start offers it back.")
		_ = command_button(app, .Open_Last_Autosave)
	case .Earlier_Saves:
		kept := versions_kept(app.versions_kept)
		chosen := 0
		for v, i in VERSIONS_KEPT do if v == kept do chosen = i
		ui.label(ctx, "Keep the files a save replaces")
		if picked := ui.select(ctx, "Earlier saves kept", VERSIONS_KEPT_NAMES[:], chosen); picked >= 0 do app.versions_kept = VERSIONS_KEPT[picked]
		ui.paragraph(ctx, "Saving over a scene file first keeps the old one in a folder beside it (for head.sculpt, \"head versions\"), the newest ones kept. Off keeps none and deletes none already there.")
	case .Undo_History:
		limit := 0
		for mb, i in HISTORY_LIMITS do if mb == app.history_limit_mb do limit = i
		ui.label(ctx, "History may use")
		if picked := ui.select(ctx, "History may use", HISTORY_LIMITS_NAMES[:], limit); picked >= 0 do app.history_limit_mb = HISTORY_LIMITS[picked]
		chosen := 0
		for steps, i in UNDO_STEPS do if steps == app.undo_steps do chosen = i
		ui.label(ctx, "Undo steps kept")
		if picked := ui.select(ctx, "Undo steps kept", UNDO_STEPS_NAMES[:], chosen); picked >= 0 do app.undo_steps = UNDO_STEPS[picked]
		ui.paragraph(ctx, "Past either limit the oldest steps are forgotten, and the memory their strokes hold comes back; a bookmarked step is kept, and a note says so. Automatic gives each object's strokes and the rebuild copies their own share. A step's menu in the History panel has Delete everything older.")
		history_memory_rows(app)
	case .History_Steps:
		lights, tree := !app.history_no_lights, !app.history_no_tree
		if ui.switch_row(ctx, "Light changes", &lights) do app.history_no_lights = !lights
		if ui.switch_row(ctx, "Scene tree changes (names, folders, order)", &tree) do app.history_no_tree = !tree
		ui.paragraph(ctx, "Off, those changes still happen and are saved, but undo walks past them, as Nomad's include switches leave them out.")
	case .History_Back:
		grouped := !app.history_ungrouped
		_ = ui.switch_row(ctx, "Camera follows the History", &app.history_camera)
		if ui.switch_row(ctx, "Group repeated strokes in the list", &grouped) do app.history_ungrouped = !grouped
		_ = ui.switch_row(ctx, "Step pictures in the list", &app.history_pictures)
		fingers := !app.history_no_finger_scrub
		if ui.switch_row(ctx, "Two fingers held, then slid, scrub", &fingers) do app.history_no_finger_scrub = !fingers
		ui.paragraph(ctx, "With the camera following, undo, redo and a tap in the History put the view back where it was when that step was made, as Nomad's Restore camera does. Step pictures show each step as the view saw it, round what it changed, in place of its icon; the strip and a step's menu always show them. Holding Undo or Redo and sliding sideways scrubs the History; two fingers held until they undo, then slid, do the same anywhere.")
	case .Blender_Link:
		when LINK_AVAILABLE {
			folder := app.link.folder
			width := ui.fill_width(ctx)
			// A path has no spaces to wrap at: its end, which names the folder, is what shows,
			// and Copy path gives the whole of it.
			shown := "This run keeps no settings, so it has no link folder." if folder == "" else text_fit_end(ctx, folder, t.small_size, width)
			ui.paragraph(ctx, shown, color = t.text_secondary)
			if ui.button(ctx, "Copy path", .Bordered, enabled = folder != "") {
				link_copy_path(app)
			}
			half := (width - 8) / 2
			ui.begin(ctx, "link buttons", {direction = .Row, gap = 8})
			_ = command_button(app, .Send_To_Blender, width = half)
			_ = command_button(app, .Get_From_Blender, width = half)
			ui.end(ctx)
			ui.paragraph(ctx, "Install the add-on in tools/blender in Blender, give it this folder, then Send to Blender here and Get from Sculpt there; Send to Sculpt there comes back here when you switch to Sculpt, or with Get from Blender.")
		}
	case .Printer:
		bed := print_bed(app)
		sides := [3]string{"Bed width", "Bed depth", "Bed height"}
		for name, k in sides {
			v := bed[k]
			if ui.drag_value(ctx, name, &v, 1, PRINT_BED_MIN, PRINT_BED_MAX, fmt.tprintf("%s mm", print_number(v))) do app.print_bed[k] = math.round(v)
		}
		wall := print_wall_least(app)
		if ui.drag_value(ctx, "Thinnest wall", &wall, 0.01, PRINT_WALL_MIN, PRINT_WALL_MAX, fmt.tprintf("%s mm", print_number(wall))) do app.print_wall = math.round(wall * 10) / 10
		ui.paragraph(ctx, "What the Export sheet's 3D print checks a print against: whether it fits the bed, turned a quarter round if need be, and whether its walls are at least this thick (two lines of a 0.4 mm nozzle make about 1 mm).")
	}
}

// Whether a block has anything to show on this build: the Blender link is desktop only.
settings_block_shown :: proc(b: Settings_Block) -> bool {
	return b != .Blender_Link || LINK_AVAILABLE
}

// Puts block `b`'s settings back as a fresh install has them.
settings_block_reset :: proc(app: ^App, b: Settings_Block) {
	k := &app.kit
	n := &app.nav
	d := NAV_DEFAULT
	switch b {
	case .Look:            k.look = .Lens
	case .Size:            k.ui_scale = 1
	case .Clean_Dial:      k.clean_dial = true
	case .Hands:           k.ctx.mirror = false
	case .Motion:          k.ctx.motion, k.ctx.motion_off = .Full, {}
	case .Starting:        app.start_home = true
	case .Brush_Ring:      k.surface_ring = true
	case .Symmetry_Line:   k.symmetry_line = true
	case .Column_Popovers: k.column_popovers = true
	case .View_Grid:       k.panes_work = true
	case .Bars:
		bars_reset(k)
		k.bars_edit = false
	case .Action_Bar:      k.action_bar = true
	case .Wheel:
		k.rail_side, k.wheel_size, k.wheel_offset = .Left, .Medium, {}
		k.wheel_labels, k.wheel_turn = .Icons, 0
		k.dials = DIAL_DEFAULTS
	case .Inspector:       k.all_options = false
	case .Pies, .Mouse, .Blender_Link:
	case .Printer:         app.print_bed, app.print_wall = {}, 0
	case .Panel_Places:    windows_reset(k)
	case .Orbit:
		n.orbit_style, n.limit_pitch, n.turntable_roll, n.orbit_speed = d.orbit_style, d.limit_pitch, d.turntable_roll, d.orbit_speed
		n.invert_x, n.invert_y = d.invert_x, d.invert_y
		n.pivot, n.air_pivot, n.pivot_dot = d.pivot, d.air_pivot, d.pivot_dot
	case .Safe_Zone:       n.edge_orbit, n.edge_size, n.edge_show = d.edge_orbit, d.edge_size, d.edge_show
	case .Pan_Zoom:        n.pan_speed, n.zoom_speed, n.invert_wheel, n.wheel_toward = d.pan_speed, d.zoom_speed, d.invert_wheel, d.wheel_toward
	case .Finger_Model:    n.finger_model, n.tap_switches = d.finger_model, d.tap_switches
	case .Touch_Strength:  n.touch_strength = d.touch_strength
	case .Hold:            n.hold_delay = d.hold_delay
	case .Pen_Empty:       n.empty_drag = d.empty_drag
	case .Pen_Tips:        n.pen_tips = d.pen_tips
	case .Pen_Predict:     n.predict_cursor = d.predict_cursor
	case .Pen_Buttons:     n.eraser = d.eraser
	case .Pen_Areas:
		n.pen_roll, n.grab_twist = d.pen_roll, d.grab_twist
		for slots in PEN_AREA_SLOTS do for slot in slots do n.gestures[slot] = d.gestures[slot]
		n.gestures[.Pen_Button_Empty] = d.gestures[.Pen_Button_Empty]
	case .Palm:            n.palm_rejection = d.palm_rejection
	case .Gesture_Switches:
		n.pinch_zoom, n.two_finger_pan, n.zoom_toward, n.twist_roll = d.pinch_zoom, d.two_finger_pan, d.zoom_toward, d.twist_roll
		n.three_finger, n.double_tap, n.lift_one_orbit = d.three_finger, d.double_tap, d.lift_one_orbit
	case .Shapes:          n.shape_apply = d.shape_apply
	case .Gesture_Map:     gesture_map_reset(n)
	case .Gesture_List:
		n.finger_model, n.pinch_zoom, n.two_finger_pan, n.twist_roll = d.finger_model, d.pinch_zoom, d.two_finger_pan, d.twist_roll
		n.three_finger, n.tap_switches = d.three_finger, d.tap_switches
		gesture_map_reset(n)
	case .Gesture_More:    n.zoom_toward, n.lift_one_orbit, n.double_tap = d.zoom_toward, d.lift_one_orbit, d.double_tap
	case .Finger_Sculpts:  n.palm_rejection, n.finger_model, n.tap_switches = d.palm_rejection, d.finger_model, d.tap_switches
	case .Keys:
		bind_reset_all(app)
		n.mouse_scheme, n.right_click = d.mouse_scheme, d.right_click
		k.keys_query = {}
	case .Statistics:      k.stats, k.stats_advanced = false, false
	case .Frame_Rate:
		app.frame_rate, app.frame_limit = .Match_Display, FRAME_LIMIT_DEFAULT
		app.low_latency = .During_Strokes
		app.display_link = false
		app.idle_sleep = true
	case .Anti_Aliasing:   app.msaa = MSAA_DEFAULT
	case .Graphics:        app.graphics, app.async_compute, app.ray_query = .Auto, true, true
	case .Autosave:        app.autosave.minutes = AUTOSAVE_DEFAULT_MINUTES
	case .Earlier_Saves:   app.versions_kept = VERSIONS_DEFAULT
	case .Undo_History:    app.undo_steps, app.history_limit_mb = 0, 0
	case .History_Steps:   app.history_no_lights, app.history_no_tree = false, false
	case .History_Back:    app.history_camera, app.history_ungrouped, app.history_no_finger_scrub, app.history_pictures = false, false, false, false
	}
}

// Puts every setting back, as Reset everything (the narrow panel) and Reset all settings
// (the sheet) do: every block, and what the command palette remembers having run.
settings_reset_all :: proc(app: ^App) {
	for b in Settings_Block do settings_block_reset(app, b)
	app.kit.palette_recent_count = 0
}
