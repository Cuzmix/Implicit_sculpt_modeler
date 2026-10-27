package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"
import "../ui"

// The interface: one layout for every screen, drawn by the ui kit over a viewport that
// fills the window (the design spec "Sculpt UI redesign", laid out as ZBrush for iPad).
// The top bar holds files and the app's panels, the brush bar runs down the left and the
// view bar down the right, the palette tray (the tool, the object and the scene) sits
// beside the view bar, the bottom bar holds the brushes and the mesh tools, and the
// History opens over it. Everything the app shows is drawn by the kit (src/ui).

// The palette tray's palettes (kit_tray.odin).
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
	fixed_dt:   f32, // seconds a frame on that clock instead, when above 0 (--ui-dt)
	inspector:  bool, // the palette tray is open
	tab:        Kit_Tab, // ...on this palette
	section:    [Kit_Tab]Kit_Section, // the section each palette shows
	object_page: Object_Page, // the page of the Object palette's section, for the exit stats
	list_scroll: f32, // the tray's list of palettes and sections, scrolled
	list_reveal: int, // ...to the section shown, for this many more frames
	// Search's Show where (tray_show): the command whose control the tray marks, since
	// when; and whether the tray's content is being drawn, where the mark is looked for.
	pointed:    struct {
		id:    Command_Id,
		arg:   int,
		since: f64,
	},
	in_tray:    bool,
	nav:        Nav_State, // the navigation head (nav_head.odin)
	light_sphere: Light_Sphere_State, // a press on the Lights section's sphere (kit_lights.odin)
	tab_serial: u64, // counts tab changes, so each one fades its content in afresh
	recover_shown: bool, // the recovery card showed this frame (kit_recover.odin)
	menu:       bool,
	// Menu > Earlier saves (kit_versions), and the row a first tap armed while the scene had
	// work to lose (its index + 1) and when: a second tap soon after opens it.
	versions:   bool,
	menu_scroll: f32, // the menu's, on a window too short for all of it
	version_armed: int,
	version_armed_at: f64,
	view_menu:  bool,
	view_at:    ui.Rect, // the view menu opens beside this: the button a long press was on
	bar_pop:    Bar_Pop, // the side bars' popover (kit_bars.odin)
	bar_scrub:  Bar_Scrub, // a long press dragging a value on the brush bar (kit_bars.odin)
	look:       Look, // the interface's colours (Settings > Interface)
	browser:    bool, // every brush and preset, in a popover over the dock or beside the brush bar
	browser_at: Browser_At, // ...which of the two opened it
	// The dock's slots (dock.odin), and the popover a long press on one opens: open, on
	// which slot, over its tile; the brush grid's scroll, in it or in the browser.
	dock:       [DOCK_SLOTS]Dock_Slot,
	dock_page:  int, // the page the bottom bar shows
	dock_shown: [2]int, // ...as its first slot and how many (fewer in a narrow window)
	dock_seen:  Dock_Slot, // the brush last frame, to bring the page holding a new one
	dock_menu:  bool,
	dock_slot:  int,
	dock_at:    ui.Rect,
	grid_scroll: f32,
	grid_reveal: bool, // the grid scrolls to the lit tile as it opens
	bind:       Bind_Popover, // Assign key (kit_bind.odin)
	// The user's pies and the starred commands (user_pies.odin), and the pie editor: open,
	// with the command a tap puts in a slot (none: it only empties), beside the control it
	// was opened from, and its scroll.
	pies:       [USER_PIES][PIE_SLOTS]Pie_Slot,
	favourites: [MAX_FAVOURITES]Pie_Slot,
	favourite_count: int,
	pie_editor: bool,
	pie_put:    Pie_Slot,
	pie_editor_at: ui.Rect,
	pie_scroll: f32,
	pie_runs:   int, // commands run from a user pie, for the exit stats
	laying_out: bool, // kit_layout is running: a command run now came from a control
	stats:      bool, // the Stats panel (F11)
	stats_advanced: bool, // ...showing every measurement by its exact name, not the simple view
	settings:   bool, // the Settings panel (Menu > Settings)
	settings_tab: Settings_Tab,
	settings_scroll: f32,
	settings_body: ui.Rect, // the scrolling body as last laid out, for Settings > Keys' popover
	keys_query: [64]u8, // Settings > Keys' search
	settings_wipe: f64, // when Reset everything was first tapped: a second tap soon after resets
	// The New scene shape armed by a first run while the scene had work to lose (its
	// NEW_SCENE_SHAPES index + 1, 0 for none) and when: a second run soon after goes ahead.
	new_armed:    int,
	new_armed_at: f64,
	// The Preset section's name field: what is typed, and which preset (from 1) it renames
	// when typing ends; 0 while the field is not being typed in.
	preset_name:    [PRESET_NAME_MAX]u8,
	preset_editing: int,
	// A colour's hex field while it is typed in: the text, and the field's id (0 when no
	// hex field is being typed in), so a half-typed code survives the frames between keys.
	color_hex:    [8]u8,
	color_hex_of: ui.Id,
	// Which edge's colour Scene > Background's picker edits while the gradient is on.
	background_bottom: bool,
	help:       bool, // the Help window (Menu > Help, F1), in Settings' place
	action_bar: bool, // the contextual action bar over the dock (Settings > Interface)
	gizmo_entry: Gizmo_Entry, // the value a tap on a gizmo handle asks for (move_tool.odin)
	action_pop: bool, // a folded action group's popover is open...
	action_group: Action_Group, // ...for this group...
	action_anchor: ui.Rect, // ...over its button
	// The adjust popover (adjust_last.odin): open, over the action bar this frame (none while
	// the bar is hidden), and a slider moved that runs the operation once let go.
	adjust_pop:    bool,
	adjust_anchor: ui.Rect,
	adjust_dirty:  bool,
	help_tab:   Help_Tab,
	help_scroll: f32,
	ui_scale:   f32, // the interface's size, times what the display asks for (Settings > Interface)
	surface_ring: bool, // the brush ring lies on the surface rather than flat on the screen (cursor.odin)
	rail_side:  Rail_Side, // where the modifier wheel sits, if anywhere (modifiers.odin)
	wheel_size: Wheel_Size,
	wheel_labels: Wheel_Labels, // what its sectors show
	wheel_turn: f32, // how far it is turned clockwise, in degrees, -180 to 180
	wheel_offset: [2]f32, // how far its grip dragged it from its place, in points
	wheel_from: [2]f32, // ...where it was when the drag under way took hold
	// Its size across and its turn when two fingers began resizing and turning it.
	wheel_from_size: f32,
	wheel_from_turn: f32,
	history:    bool, // the History panel, over the dock
	// The command palette (palette.odin): open, what is typed, the picked result and the
	// first shown, the recents (most recent first), and for the exit stats how many
	// entries it ran and the last one.
	palette:        bool,
	palette_query:  [64]u8,
	palette_pick:   int,
	palette_first:  int,
	palette_recent: [PALETTE_RECENT]Palette_Entry,
	palette_recent_count: int,
	palette_runs:   int,
	palette_last:   Palette_Entry,
	palette_ran:    bool,
	// While set, the palette chooses what that gesture runs rather than running anything
	// (palette_open_for, from Settings > Touch's Any command...).
	palette_for:    Maybe(Gesture_Slot),
	// The panels as windows: where each was dragged to and whether it is folded
	// (remembered by settings.odin), and the order they are drawn in, the last on top.
	windows:    [Kit_Window]ui.Window,
	order:      [len(Kit_Window)]Kit_Window,
	text_input: bool, // SDL's text input is on, for the text field that has the keys
	// Where the viewport's overlay goes in the draw order: over the viewport image and
	// under the panels. Set while a frame is laid out, until the overlay is drawn.
	layer:      Maybe(ui.Layer),
	// The outliner's context menu: open, on which object, where.
	object_menu:    bool,
	object_menu_id: int,
	object_menu_at: ui.Rect,
	object_menu_side: ui.Side, // at the pointer from the Scene palette, above the status chip
	// A folder's menu in the Scene palette, the rename field over a row, and how many rows
	// the tree drew last (for the exit stats).
	folder_menu:    bool,
	folder_menu_id: int,
	folder_menu_at: ui.Rect,
	rename:         Rename_Entry,
	macro_save:     Macro_Save_Entry, // the name a stopped macro recording is saved under
	macro_chip:     ui.Rect, // the recording chip as last laid out, which that popover hangs under
	// The Macros panel (kit_macros.odin): open, how far its list is scrolled, and the slot
	// whose Delete a first tap armed (from 1), and when.
	macros:         bool,
	macros_scroll:  f32,
	macro_armed:    int,
	macro_armed_at: f64,
	// The Library panel (kit_library.odin): open, how far its list is scrolled, and the
	// pack whose Remove a first tap armed (from 1), and when.
	library:        bool,
	library_scroll: f32,
	pack_armed:     int,
	pack_armed_at:  f64,
	// The library alpha whose Remove from library a first tap armed (from 1), and when.
	alpha_armed:    int,
	alpha_armed_at: f64,
	tree_rows:      int,
	// Select several (the Scene palette's switch): a tap on a row, or with the Move tool on an
	// object, adds it to the selection or takes it out, as Shift does.
	select_several: bool,
	// A row dragged by its grip and an eye or ghost column being dragged down
	// (kit_scene.odin), and the inspector's body as last laid out and how far it scrolls,
	// which a drag near its edge scrolls.
	tree_drag:      Tree_Drag,
	tree_column:    Tree_Column,
	// The Objects card (kit_objects_card.odin): open, and its list, menus and size.
	objects_card:   bool,
	card:           Objects_Card,
	inspector_body: ui.Rect,
	inspector_limit:  f32,
	inspector_shown:  f32, // how far the body is scrolled as drawn (the scroll tweens toward k.scroll)
	// Which Stats sections are open, and which tray sections show their More options;
	// with all_options (Settings > Interface) every section shows everything.
	open:       [Kit_Section]bool,
	more:       [Kit_Section]bool,
	all_options: bool,
	// The first-run tips done (a bit per Coach_Step; COACH_DONE once over, remembered),
	// and whether a card showed last frame and which.
	coach:       i32,
	coach_shown: bool,
	coach_last:  Coach_Step,
	scroll:     f32, // the inspector's scroll, where it is heading
	add_shape:  geom.Primitive,
	add_mesh:   int, // a content pack's mesh to add instead (Library.meshes, from 1), or 0
	add_size:   int, // into SPHERE_PRESETS
	add_voxel:  bool, // Add object makes a voxel sphere of the size's resolution (voxel_object.odin)
	voxel_across: i32, // Convert to voxels' resolution; 0 takes the one the object's vertex count maps to
	note_at:    time.Tick, // the result last shown as a toast
	busy_toast: ui.Id, // the last "under way" toast (Report_Flag.Busy), dismissed by the next result
	undo_toast: struct {
		serial: ui.Id, // the last toast that offered Undo
		mark:   Undo_Mark, // the step its Undo takes back
	},
	frame:      int, // frames drawn, for --ui-events
	events_offset: int, // frames a start-up script took, which --ui-events frames count after
	events:     [dynamic]Kit_Event, // --ui-events, in frame order
	ms:         f64, // last frame's layout and tessellation, CPU
}

// The panels that behave as windows (ui.Window): each has a title bar to drag it by,
// Minimise and Close.
Kit_Window :: enum u8 {
	Inspector,
	Stats,
	History,
	Settings,
	Help,
	Macros,
	Library,
	Objects, // the Objects card (kit_objects_card.odin), a card rather than a window
}

// The order the windows start in, back to front: Settings, Help, Macros and Library over
// the rest, as they opened.
KIT_WINDOW_ORDER :: [len(Kit_Window)]Kit_Window{.Inspector, .Objects, .Stats, .History, .Settings, .Help, .Macros, .Library}

// Settings, Help, Macros and Library share the inspector's place on the right: one at a
// time, with the inspector hidden while one is open.
side_panel_open :: proc(k: ^Kit_State) -> bool {
	return k.settings || k.help || k.macros || k.library
}

// Closes Settings, Help, Macros or Library, whichever is open, giving the place back to
// the inspector.
side_panel_close :: proc(app: ^App) {
	if app.kit.settings do settings_close(app)
	app.kit.help, app.kit.macros, app.kit.library = false, false, false
}

// Brings `which` in front of the other windows.
window_raise :: proc(k: ^Kit_State, which: Kit_Window) {
	at := 0
	for w, i in k.order do if w == which do at = i
	for i in at ..< len(k.order) - 1 do k.order[i] = k.order[i + 1]
	k.order[len(k.order) - 1] = which
}

// Puts every window back where it starts, open and in the starting order.
windows_reset :: proc(k: ^Kit_State) {
	k.windows = {}
	k.order = KIT_WINDOW_ORDER
}

// The most height a window can have where it is: from its top edge to the bottom of the
// safe area, less the margin, or (kept to the bottom edge) from the top margin down to
// its bottom edge; `top` is its default distance from the top, which it keeps until moved.
window_room :: proc(app: ^App, w: ui.Window, top: f32) -> f32 {
	t := app.kit.ctx.theme
	area := ui.safe_area(&app.kit.ctx)
	return area.h - (w.offset.y if w.moved else top) - t.edge
}

// A window's body that scrolls when its content is taller than `height`: with the
// wheel, or by dragging it (a finger or a pen has no wheel), from where no control is at
// once and from a control once the drag goes up or down rather than sideways
// (ui.scroll_update). The scroll eases to where it is heading and a drag follows the
// finger exactly; a thin bar shows where it is. The inspector, Settings and Help all
// scroll through it, so they scroll alike.
Kit_Scroll :: struct {
	id, owner: ui.Id, // the body, and the window a press no control took drags it for
	value:     ^f32, // where the scroll is heading
	at:        ui.Rect, // the body as laid out
	height, natural, limit, shown: f32,
}

// Begins the scrolling body `name`, `width` wide and at most `height` tall; its content
// follows, then kit_scroll_end.
kit_scroll_begin :: proc(ctx: ^ui.Context, name: string, value: ^f32, owner: ui.Id, width, height, gap: f32) -> (s: Kit_Scroll) {
	s = {id = ui.id_of(ctx, name), owner = owner, value = value, height = height}
	_, natural := ui.prev_layout(ctx, name)
	s.natural = natural.y
	s.limit = max(natural.y - height, 0)
	dragging := ui.scroll_update(ctx, s.id, ui.prev_rect(ctx, name), value, s.limit)
	s.shown = ui.tween(ctx, ui.salt(s.id, 1), value^, 0 if dragging else ctx.theme.popover_time, .Out_Quart)
	ui.begin(ctx, name, {direction = .Column, gap = gap, width = width, height = height if natural.y > height else 0, clip = true, scroll = s.shown, drag_scroll = true})
	s.at = ctx.last_rect
	return
}

// Ends the body: a press on it that no control took starts a scroll drag, and the bar
// shows when there is more than fits.
kit_scroll_end :: proc(ctx: ^ui.Context, s: Kit_Scroll) {
	ui.end(ctx)
	ui.scroll_take(ctx, s.id, s.value^, s.limit, s.owner)
	if s.limit <= 0 do return
	r := s.at
	thumb := max(s.height * s.height / s.natural, 24)
	y := r.y + (s.height - thumb) * (s.shown / s.limit)
	ui.fill_rect(ctx, {r.x + r.w + 6, y, 3, thumb}, 1.5, ui.color_fade(ctx.theme.text_tertiary, 0.6))
}

// Which way a window slides as it opens and closes: in from the side it keeps to (+1 the
// right, -1 the left), `default` until it is moved.
window_slide :: proc(w: ui.Window, default: ui.Anchor) -> f32 {
	return 1 if (w.x if w.moved else default) == .End else -1
}

// The sections of the tray's palettes, then the Stats panel's: the tray's come first and
// end with Background (TRAY_SECTIONS), each palette's together (section_palette).
Kit_Section :: enum u8 {
	// The Brush palette's.
	Preset,
	Stroke,
	Paint_Color,
	Recall,
	Falloff,
	Alpha,
	Pen,
	Options,
	Recorder,
	// The Object palette's.
	Transform,
	Levels,
	Hd,
	Topology,
	Mask,
	Sets,
	Visibility,
	Paint,
	Groups,
	Morph,
	Layers,
	Deform,
	Deformers,
	Remesh,
	Mirror,
	Voxels,
	Retopo,
	Textures,
	Project,
	Booleans,
	Extract,
	// The Scene palette's.
	Objects,
	Add,
	Material,
	Lights,
	Environment,
	Studio,
	Camera,
	Floor,
	Background,
	// The Stats panel's.
	Frame,
	Drawing,
	Sculpting,
	Stats_Help,
}

// One scripted input event (--ui-events), pushed into SDL's queue at the start of its
// frame so it takes the path a real one takes: through the Device, the fingers and the
// pen samples alike.
Kit_Event :: struct {
	frame:  int,
	kind:   Kit_Event_Kind,
	at:     [2]f32, // window points
	value:  f32, // a wheel's turn, or a pen's pressure
	finger: u64,
	key:    string, // a key's name, as SDL names keys
}

Kit_Event_Kind :: enum u8 {
	Move,
	Down,
	Up,
	Right,
	// The middle and right buttons held and let go apart, for drags with them.
	Middle_Down,
	Middle_Up,
	Right_Down,
	Right_Up,
	Wheel,
	Key,
	Key_Up,
	Text, // typed text, as a keyboard sends it while text input is on
	Finger_Down,
	Finger_Move,
	Finger_Up,
	Finger_Cancel,
	Pen_Down,
	Pen_Move,
	Pen_Up,
	Pen_Near,
	Pen_Far,
	Pen_Right, // the pen's side button pressed and let go, hovering where the pointer is
	Pen_Pressure, // how hard the pen presses from then on, 0 to 1
	Pen_Roll, // the pen's turn about its own length from then on, degrees from -180 to 180
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
		// FRAME:kind, then the kind's own fields: a finger's id, then X,Y.
		point :: proc(s: string) -> (at: [2]f32, ok: bool) {
			xy := strings.split(s, ",", context.temp_allocator)
			if len(xy) != 2 do return
			x, okx := strconv.parse_f32(xy[0])
			y, oky := strconv.parse_f32(xy[1])
			return {x, y}, okx && oky
		}
		finger :: proc(s: string) -> (id: u64, ok: bool) {
			n, okn := strconv.parse_u64(s)
			return n + 1, okn // 0 is no finger
		}
		if ok {
			switch parts[1] {
			case "move", "pdown", "pmove":
				ok = len(parts) == 3
				if ok do ev.at, ok = point(parts[2])
				ev.kind = .Move if parts[1] == "move" else (.Pen_Down if parts[1] == "pdown" else .Pen_Move)
			case "down":   ev.kind = .Down
			case "up":     ev.kind = .Up
			case "right":  ev.kind = .Right
			case "mdown":  ev.kind = .Middle_Down
			case "mup":    ev.kind = .Middle_Up
			case "rdown":  ev.kind = .Right_Down
			case "rup":    ev.kind = .Right_Up
			case "pup":    ev.kind = .Pen_Up
			case "pnear":  ev.kind = .Pen_Near
			case "pfar":   ev.kind = .Pen_Far
			case "pright": ev.kind = .Pen_Right
			case "wheel", "ppress", "proll":
				ok = len(parts) == 3
				if ok do ev.value, ok = strconv.parse_f32(parts[2])
				switch parts[1] {
				case "wheel":  ev.kind = .Wheel
				case "ppress": ev.kind = .Pen_Pressure
				case:          ev.kind = .Pen_Roll
				}
			case "text":
				// Everything after the kind, colons and spaces too (from the untrimmed item).
				raw := strings.trim_left_space(item)
				rest := raw[min(len(parts[0]) + len(":text:"), len(raw)):]
				ok = len(parts) >= 3 && rest != ""
				if ok do ev.key = strings.clone(rest)
				ev.kind = .Text
			case "key", "keyup":
				ok = len(parts) == 3 && parts[2] != ""
				if ok do ev.key = strings.clone(parts[2])
				ev.kind = .Key if parts[1] == "key" else .Key_Up
			case "fdown", "fmove":
				ok = len(parts) == 4
				if ok do ev.finger, ok = finger(parts[2])
				if ok do ev.at, ok = point(parts[3])
				ev.kind = .Finger_Down if parts[1] == "fdown" else .Finger_Move
			case "fup", "fcancel":
				ok = len(parts) == 3
				if ok do ev.finger, ok = finger(parts[2])
				ev.kind = .Finger_Up if parts[1] == "fup" else .Finger_Cancel
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

// Pushes the scripted events of the frame about to start into SDL's queue, as SDL's own
// would arrive: the mouse as the mouse, fingers from a touch screen (TOUCH_SCRIPTED) and
// the pen as its proximity and contact events and its mouse events. Call it before the
// frame's events are read. The modifiers a script holds (key:shift) stay held until it
// lets them go.
kit_events_push :: proc(app: ^App, window: ^sdl.Window) {
	k := &app.kit
	d := &app.device
	scale := kit_content_scale(window) * k.ui_scale
	w, h: i32
	_ = sdl.GetWindowSize(window, &w, &h)
	win := sdl.GetWindowID(window)
	now := sdl.GetTicksNS()
	push :: proc(e: sdl.Event) {
		e := e
		_ = sdl.PushEvent(&e)
	}
	SCRIPTED_MOUSE :: sdl.MouseID(1)
	for ev in k.events {
		if ev.frame + k.events_offset != k.frame do continue
		at := ev.at * scale
		e: sdl.Event
		switch ev.kind {
		case .Move:
			e.motion = {type = .MOUSE_MOTION, timestamp = now, windowID = win, which = SCRIPTED_MOUSE, x = at.x, y = at.y}
			push(e)
		case .Down, .Up:
			e.button = {type = .MOUSE_BUTTON_DOWN if ev.kind == .Down else .MOUSE_BUTTON_UP, timestamp = now, windowID = win, which = SCRIPTED_MOUSE, button = u8(sdl.BUTTON_LEFT), down = ev.kind == .Down, clicks = 1, x = d.mouse.x, y = d.mouse.y}
			push(e)
		case .Middle_Down, .Middle_Up, .Right_Down, .Right_Up:
			down := ev.kind == .Middle_Down || ev.kind == .Right_Down
			button := sdl.BUTTON_MIDDLE if ev.kind == .Middle_Down || ev.kind == .Middle_Up else sdl.BUTTON_RIGHT
			e.button = {type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP, timestamp = now, windowID = win, which = SCRIPTED_MOUSE, button = u8(button), down = down, clicks = 1, x = d.mouse.x, y = d.mouse.y}
			push(e)
		case .Pen_Right:
			// SDL sends the side button as the pen's right click.
			e.motion = {type = .MOUSE_MOTION, timestamp = now, windowID = win, which = sdl.PEN_MOUSEID, x = d.mouse.x, y = d.mouse.y}
			push(e)
			for down in ([2]bool{true, false}) {
				e = {}
				e.button = {type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP, timestamp = now, windowID = win, which = sdl.PEN_MOUSEID, button = u8(sdl.BUTTON_RIGHT), down = down, clicks = 1, x = d.mouse.x, y = d.mouse.y}
				push(e)
			}
		case .Right:
			for down in ([2]bool{true, false}) {
				e.button = {type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP, timestamp = now, windowID = win, which = SCRIPTED_MOUSE, button = u8(sdl.BUTTON_RIGHT), down = down, clicks = 1, x = d.mouse.x, y = d.mouse.y}
				push(e)
			}
		case .Wheel:
			e.wheel = {type = .MOUSE_WHEEL, timestamp = now, windowID = win, which = SCRIPTED_MOUSE, y = ev.value, mouse_x = d.mouse.x, mouse_y = d.mouse.y}
			push(e)
		case .Key, .Key_Up:
			mod: sdl.Keymod
			switch ev.key {
			case "shift": mod = sdl.KMOD_LSHIFT
			case "ctrl":  mod = sdl.KMOD_LCTRL
			case "alt":   mod = sdl.KMOD_LALT
			}
			if mod != {} {
				if ev.kind == .Key do d.script_mods += mod
				else do d.script_mods -= mod
				continue
			}
			key := sdl.GetKeyFromName(strings.clone_to_cstring(ev.key, context.temp_allocator))
			code := sdl.GetScancodeFromKey(key, nil)
			e.key = {type = .KEY_DOWN if ev.kind == .Key else .KEY_UP, timestamp = now, windowID = win, scancode = code, key = key, mod = d.script_mods, down = ev.kind == .Key}
			push(e)
		case .Text:
			// As SDL's own keyboard does, text arrives only while text input is on (a text
			// field has the keys). The text lives until this frame's events are read.
			if !sdl.TextInputActive(window) do continue
			e.text = {type = .TEXT_INPUT, timestamp = now, windowID = win, text = strings.clone_to_cstring(ev.key, context.temp_allocator)}
			push(e)
		case .Finger_Down, .Finger_Move, .Finger_Up, .Finger_Cancel:
			kinds := [4]sdl.EventType{.FINGER_DOWN, .FINGER_MOTION, .FINGER_UP, .FINGER_CANCELED}
			kind := kinds[int(ev.kind) - int(Kit_Event_Kind.Finger_Down)]
			// A lifted finger lifts where it last was.
			pos := at
			if kind == .FINGER_UP || kind == .FINGER_CANCELED {
				pos = {}
				for f in app.touch.fingers.down[:app.touch.fingers.count] do if f.id == ev.finger do pos = f.at
			}
			e.tfinger = {type = kind, timestamp = now, touchID = TOUCH_SCRIPTED, fingerID = sdl.FingerID(ev.finger), x = pos.x / f32(max(w, 1)), y = pos.y / f32(max(h, 1)), pressure = 1, windowID = win}
			push(e)
		case .Pen_Near, .Pen_Far:
			e.pproximity = {type = .PEN_PROXIMITY_IN if ev.kind == .Pen_Near else .PEN_PROXIMITY_OUT, timestamp = now, windowID = win, which = 1}
			push(e)
		case .Pen_Pressure:
			e.paxis = {type = .PEN_AXIS, timestamp = now, windowID = win, which = 1, x = d.mouse.x, y = d.mouse.y, axis = .PRESSURE, value = clamp(ev.value, 0, 1)}
			push(e)
		case .Pen_Roll:
			e.paxis = {type = .PEN_AXIS, timestamp = now, windowID = win, which = 1, x = d.mouse.x, y = d.mouse.y, axis = .ROTATION, value = clamp(ev.value, -180, 180)}
			push(e)
		case .Pen_Down, .Pen_Move, .Pen_Up:
			if ev.kind != .Pen_Up {
				e.motion = {type = .MOUSE_MOTION, timestamp = now, windowID = win, which = sdl.PEN_MOUSEID, x = at.x, y = at.y}
				push(e)
			}
			if ev.kind == .Pen_Move do continue
			down := ev.kind == .Pen_Down
			e = {}
			e.ptouch = {type = .PEN_DOWN if down else .PEN_UP, timestamp = now, windowID = win, which = 1, x = at.x if down else d.mouse.x, y = at.y if down else d.mouse.y, down = down}
			push(e)
			e = {}
			e.button = {type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP, timestamp = now, windowID = win, which = sdl.PEN_MOUSEID, button = u8(sdl.BUTTON_LEFT), down = down, clicks = 1, x = at.x if down else d.mouse.x, y = at.y if down else d.mouse.y}
			push(e)
			// And the stand-in finger SDL sends for a pen by default, which must change nothing.
			e = {}
			p := at if down else d.mouse
			e.tfinger = {type = .FINGER_DOWN if down else .FINGER_UP, timestamp = now, touchID = sdl.PEN_TOUCHID, fingerID = 1, x = p.x / f32(max(w, 1)), y = p.y / f32(max(h, 1)), pressure = 1, windowID = win}
			push(e)
		}
	}
}

// What the window shows where nothing is drawn (a screen dump's background).
KIT_CANVAS :: ui.Color{0x11, 0x12, 0x14, 0xff}

// The image id the viewport is drawn with; the kit hands it back in its draw commands.
KIT_VIEWPORT_IMAGE :: 1
// ...and the navigation head's (nav_head.odin).
KIT_NAV_HEAD_IMAGE :: 2
// ...and the atlas of the Objects card's pictures of objects (object_thumbs.odin).
KIT_THUMBS_IMAGE :: 3

// The inspector's width, and the toolbars' height: one touch target.
KIT_INSPECTOR_W :: 312

kit_init :: proc(app: ^App) {
	ui.init(&app.kit.ctx)
	k := &app.kit
	k.inspector = true
	k.look = .Studio
	// Each palette starts on its section most reached for, and the Stats panel with its
	// commonest sections open.
	k.section = {.Tool = .Stroke, .Object = .Transform, .Scene = .Objects}
	for s in ([?]Kit_Section{.Frame, .Sculpting}) do k.open[s] = true
	k.add_size = 2 // 1M
	k.ui_scale = 1
	k.surface_ring = true
	k.rail_side, k.wheel_size = .Left, .Medium
	k.action_bar = true
	k.dock = DOCK_DEFAULT
	k.pies = PIE_DEFAULTS
	k.order = KIT_WINDOW_ORDER
	k.last_frame = time.tick_now()
}

// Closes every menu, popover and open list that floats over the panels (not the palette,
// which gives the keys back as it closes: palette_close). The one list, so that a new
// popover added here closes whenever another opens and on Escape.
kit_floats_close :: proc(k: ^Kit_State) {
	k.menu, k.versions, k.view_menu, k.browser, k.dock_menu, k.object_menu, k.action_pop = false, false, false, false, false, false, false
	k.bar_pop.open = false
	k.bind.open, k.pie_editor, k.adjust_pop, k.gizmo_entry.open = false, false, false, false
	k.folder_menu, k.rename.open, k.macro_save.open = false, false, false
	k.ctx.select_open = 0
}

// Whether something floats over the interface: a menu, the palette, the pie, the S/U
// adjust, a popover or an open list. Escape closes it before Settings or Help, and the
// first-run tip hides under it.
kit_floating :: proc(app: ^App) -> bool {
	k := &app.kit
	return app.ui.pie.open || app.ui.adjust.kind != .None || k.action_pop || k.adjust_pop || k.menu || k.versions || k.view_menu || k.browser || k.dock_menu || k.bind.open || k.pie_editor || k.object_menu || k.folder_menu || k.rename.open || k.macro_save.open || k.palette || k.gizmo_entry.open || k.bar_pop.open || k.ctx.select_open != 0
}

kit_destroy :: proc(app: ^App) {
	for ev in app.kit.events do delete(ev.key)
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

// Whether a hovering pen shows tooltips now, as Settings > Touch says.
pen_tips_shown :: proc(tips: Pen_Tips) -> bool {
	switch tips {
	case .Always:        return true
	case .With_Keyboard: return sdl.HasKeyboard()
	case .Never:         return false
	}
	return true
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
	scale := kit_content_scale(window) * k.ui_scale
	k.frame += 1
	d := &app.device
	in_ := ui.Input {
		mouse         = d.mouse / scale,
		mouse_valid   = device_pointing(d),
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
		pointer       = d.pointer,
		cancel        = d.cancel,
		no_hover_tips = d.pointer == .Pen && !pen_tips_shown(app.nav.pen_tips),
	}
	// An open pie, and the click that picked from it until it is let go, are over the
	// panels too: nothing under them is pressed or hovered.
	if app.ui.pie.open || app.ui.pie.swallow {
		in_.mouse_valid = false
		in_.down, in_.pressed, in_.released = {}, {}, {}
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
	if k.fixed_dt > 0 do in_.dt = k.fixed_dt
	k.last_frame = now
	k.scale = scale
	k.ctx.theme = LOOK_THEMES[k.look]
	ui.frame_begin(&k.ctx, in_)
	return {w, h}, {pw, ph}
}

// A new result (saved, opened, remeshed, deleted) shows as a toast, with Undo when it
// left an undo step; that Undo runs only while it is still the latest step.
@(private = "file")
kit_results :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if serial := ui.toast_take_action(ctx); serial != 0 && serial == k.undo_toast.serial {
		if undo_mark_on_top(app.history.done[:], k.undo_toast.mark) do command_run(app, .Undo)
		k.undo_toast = {}
	}
	// Once its step is no longer the newest (undone, or another made since), the toast
	// stays but its Undo goes: it would take back something else.
	if k.undo_toast.serial != 0 && !undo_mark_on_top(app.history.done[:], k.undo_toast.mark) {
		ui.toast_drop_action(ctx, k.undo_toast.serial)
		k.undo_toast = {}
	}
	r := app.result
	if r.text == "" || r.at == k.note_at do return
	k.note_at = r.at
	// Whatever comes next is how the work under way ended, or says it is no longer news.
	if k.busy_toast != 0 do ui.toast_dismiss(ctx, k.busy_toast)
	k.busy_toast = 0
	if .Quiet in r.flags do return
	// The adjust popover shows its operation's results itself, where the toast would cover it.
	if section, ok := r.section.?; ok && k.adjust_pop && section == ADJUST_SECTIONS[app.adjustable.op] do return
	kind := ui.Toast_Kind.Warning if .Warning in r.flags else .Info if .Busy in r.flags else .Success
	mark, undoable := r.undo.?
	if !undoable {
		serial := ui.toast(ctx, r.text, kind)
		if .Busy in r.flags do k.busy_toast = serial
		return
	}
	k.undo_toast = {ui.toast(ctx, r.text, kind, "Undo"), mark}
}

// Lays out the interface for this frame and returns what the viewport saw.
kit_frame :: proc(app: ^App, window: ^sdl.Window) -> Viewport_Input {
	start := time.tick_now()
	k := &app.kit
	// The system can hide the on-screen keyboard and stop text input behind the app's back
	// (Android's Back while the keyboard is up, iPadOS's hide-keyboard key), and the Back
	// never reaches the app. Then the field that had the keys lets them go and the palette
	// closes, as one Back closes it when no keyboard is up; restarting text input instead
	// would bring the keyboard straight back.
	if k.text_input && !sdl.TextInputActive(window) {
		k.text_input = false
		k.ctx.text_focus = 0
		if k.palette do palette_close(app)
	}
	// A text field that has the keys at the start of the frame takes them all, the Enter
	// or Escape that ends it too.
	typed := ui.typing(&k.ctx)
	size, pixels := kit_begin(app, window)
	// The viewport fills the window, pixel for pixel.
	app.ui.viewport_request = {f32(max(pixels.x, 1)), f32(max(pixels.y, 1))}

	ctx := &k.ctx
	kit_results(app)
	ui.image(ctx, {0, 0, ctx.input.window.x, ctx.input.window.y}, KIT_VIEWPORT_IMAGE)
	k.layer = ui.layer_mark(ctx)
	k.laying_out = true
	kit_layout(app)
	k.laying_out = false
	// Whether something floated before the pie read this frame's Escape and closed itself:
	// that Escape is the pie's, not Settings'.
	floating := kit_floating(app)
	input := kit_viewport_input(app, {f32(size.x), f32(size.y)})
	if !typed do commands_handle_keys(app)
	layer_drag_end(app)
	deform_drag_end(app)
	lattice_frame(app)
	transform_drag_end(app)
	tree_column_send(app)
	// Text input (and with it a tablet's on-screen keyboard) is on only while a text
	// field has the keys.
	if wanted := ui.typing(ctx); wanted != k.text_input {
		k.text_input = wanted
		if wanted do text_input_start(window)
		else do _ = sdl.StopTextInput(window)
	}
	d := &app.device
	// A shape waiting for Apply takes Enter, and Escape after what floats; neither while
	// a field or the palette had the keys, nor over a menu.
	shape_waits := app.shape_pending.kind != .None && app.tool == .Brush
	quiet := !floating && !kit_floating(app) && !typed
	if shape_waits && quiet && (key_pressed(d, sdl.K_RETURN) || key_pressed(d, sdl.K_KP_ENTER)) do app.shape_pending.request = .Apply
	// Escape, or Android's back gesture (the AC Back key), closes whatever floats, before
	// Escape stops a replay; during a gizmo drag or a topological mask Escape only puts
	// the object or the mask back (move_tool_frame).
	if (key_pressed(d, sdl.K_ESCAPE) && app.move.drag.handle == .None && !topo_held(app)) || key_pressed(d, sdl.K_AC_BACK) {
		// The topmost goes first: what floats, then a waiting shape, and only then
		// Settings or Help. An Escape that ended typing in a field (Settings > Keys'
		// search) was the field's. The recovery card, when nothing is above it, waits
		// for the next start.
		if k.recover_shown && quiet && !shape_waits && !side_panel_open(k) do app.autosave.offer_hidden = true
		if shape_waits && quiet do app.shape_pending.request = .Cancel
		else if side_panel_open(k) && quiet do side_panel_close(app)
		if k.palette do palette_close(app)
		kit_floats_close(k)
	}
	k.ms = time.duration_milliseconds(time.tick_since(start))
	return input
}

// Turns on text input for the field that has the keys, with a tablet keyboard's
// autocorrect and capitals off: the fields hold names and search words (zremesher,
// dynamesh), which autocorrect would "fix" as they are typed.
text_input_start :: proc(window: ^sdl.Window) {
	props := sdl.CreateProperties()
	defer if props != 0 do sdl.DestroyProperties(props)
	if props != 0 {
		_ = sdl.SetNumberProperty(props, sdl.PROP_TEXTINPUT_TYPE_NUMBER, sdl.Sint64(sdl.TextInputType.TEXT))
		_ = sdl.SetNumberProperty(props, sdl.PROP_TEXTINPUT_CAPITALIZATION_NUMBER, sdl.Sint64(sdl.Capitalization.NONE))
		_ = sdl.SetBooleanProperty(props, sdl.PROP_TEXTINPUT_AUTOCORRECT_BOOLEAN, false)
	}
	_ = sdl.StartTextInputWithProperties(window, props)
}

// What the viewport saw: everything the panels did not take.
@(private = "file")
kit_viewport_input :: proc(app: ^App, size: [2]f32) -> (input: Viewport_Input) {
	k := &app.kit
	d := &app.device
	input.size = size
	input.hovered = device_pointing(d) && !ui.wants_pointer(&k.ctx)
	input.dragging = ui.viewport_dragging(&k.ctx)
	input.mouse_pos = d.mouse
	input.samples = make([]Input_Sample, len(app.samples), context.temp_allocator)
	copy(input.samples, app.samples[:])
	input.pen_tilt = app.pen_tilt
	input.mouse_delta = d.moved
	// An orbit turns about the target unless pointer_route decided another pivot.
	input.orbit_pivot = app.camera.target
	if input.hovered || input.dragging do input.wheel = d.wheel
	// A right press let go soon and about where it began is a tap, which opens the brush
	// pie, rather than an orbit.
	// While a pie is open the panels take no press (kit_begin), so a right tap anywhere is
	// the pie's.
	right_tap := (input.dragging || app.ui.pie.open) && d.right_tap && !d.shift
	// A press and its release can both come in one frame (a tap, or a click during a slow
	// frame): the press still holds for this frame, and the release among the samples
	// ends what it began; the next frame sees the button up.
	left := .Left in d.down || .Left in d.pressed
	if input.dragging {
		// What the right and middle buttons do to the view is pointer_route's to say
		// (mouse_button_owner), by the mouse scheme in Settings > Keys.
		input.primary = left && (!d.alt || d.ctrl)
		input.alt = input.primary && d.alt
		input.press = input.primary && .Left in d.pressed
		input.smooth = input.primary && d.shift
		input.invert = input.primary && d.ctrl
		input.mask_shape = input.invert && !d.shift
		// The modifier rail sets what the keys would, for this press (modifiers.odin).
		rail_press(app, &input)
	}
	// Who has the touch and the drag, then what they do this frame (touch.odin,
	// navigate.odin); the pie and the S/U adjust may still take the pointer after.
	touch_route(app, &input)
	pointer_route(app, &input)
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

	// First, so that every panel and popover laid out after it is above it.
	kit_shape_bar(app)

	// Round the edges: the top bar, the object's readout under it, the brush bar at the
	// left, and the navigation head and the view bars under it at the right (kit_bars.odin,
	// nav_head.odin).
	menu_anchor := kit_top_bar(app)
	kit_points(app)
	browser_anchor := kit_brush_bar(app)
	kit_nav_head(app)
	palette_anchor, view_anchor := kit_view_bar(app)

	kit_modifier_rail(app)

	// Bottom middle: a page of the brush dock, then the mesh tools (kit_bars.odin).
	dock_anchor := kit_bottom_bar(app)
	// Over the dock, the next steps for what is active (kit_action_bar.odin); notes rise
	// above both.
	kit_action_bar(app)
	stack_h := dock_stack(app)
	ctx.toast_bottom = E + stack_h + 12

	// Under the tool bar, the first-run tip; under the windows, which cover it if moved
	// there.
	coach_update(app)
	kit_coach(app)
	kit_recover(app)
	kit_macro_chip(app)

	// The windows, back to front: the last drawn is hit tested first. One pressed comes to
	// the front from the next frame on.
	top: Maybe(Kit_Window)
	for which in k.order {
		raised: bool
		switch which {
		case .Inspector: raised = kit_inspector(app)
		case .Stats:     raised = kit_stats(app)
		case .History:   raised = kit_history_panel(app)
		case .Settings:  raised = kit_settings(app)
		case .Help:      raised = kit_help(app)
		case .Macros:    raised = kit_macros(app)
		case .Library:   raised = kit_library(app)
		case .Objects:   raised = kit_objects_card(app)
		}
		if raised do top = which
	}
	if which, ok := top.?; ok do window_raise(k, which)

	// What floats over the panels comes last, so it is drawn and hit tested on top.
	if k.browser_at == .Dock do kit_brush_browser(app, dock_anchor, .Above_Center)
	else do kit_brush_browser(app, browser_anchor, .Right)
	kit_bar_popover(app)
	kit_bar_scrub(app)
	kit_dock_menu(app)
	kit_menu(app, menu_anchor)
	kit_versions(app, menu_anchor)
	kit_view_menu(app, view_anchor, .Left)
	kit_object_menu(app)
	kit_objects_card_menus(app)
	kit_folder_menu(app)
	kit_rename(app)
	kit_palette(app, palette_anchor, .Left)
	kit_action_popover(app)
	kit_gizmo_entry(app)
	kit_adjust_popover(app)
	kit_bind_popover(app)
	kit_macro_save(app)
	kit_pie_editor(app)
}

// The palette tray (kit_tray.odin): the tool's, the object's or the scene's palette, a
// section at a time, sliding in from the right, in a window (Tab or Close hides it, the
// Palettes button brings it back). On a wide window the list of palettes and their
// sections runs down its left; on a narrow one a select over the content holds it. When
// the content is taller than the room under the title bar it scrolls, with the wheel or
// by dragging it (a finger or a pen has no wheel): from where no control is, at once, and
// from a control once the drag goes up or down rather than sideways (ui.scroll_update).
// Returns true when a press landed on it, to bring it to the front.
@(private = "file")
kit_inspector :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "inspector")
	// Settings or Help takes its place while open.
	shown := ui.presence(ctx, id, k.inspector && !side_panel_open(k), t.panel_time)
	if shown <= 0 do return
	win := &k.windows[.Inspector]
	top := kit_top()
	right := kit_right(app)
	room := window_room(app, win^, top)
	width := tray_width(app)
	if !win.moved {
		// Where it starts, clear of what sits below it: the modifier wheel when it is on
		// the right, and the dock when the window is narrow enough for them to meet.
		area := ui.safe_area(ctx)
		dock_size, _ := ui.prev_layout(ctx, "dock")
		below: f32 = 0
		stack_h := dock_stack(app)
		if area.w * 0.5 + dock_size.x * 0.5 + 8 > area.w - right - width do below = max(below, stack_h + 8)
		if reach := rail_reach(app, .Right); reach > 0 do below = max(below, reach - t.edge + 8)
		room -= below
	}
	PADDING :: 12
	GAP :: 6
	inner := f32(KIT_INSPECTOR_W - 2 * PADDING)
	wide := tray_wide(app)

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "inspector", palette_title(app, k.tab), win, .End, .Start, {right, top}, {direction = .Column, gap = GAP, padding = PADDING, width = width, radius = t.radius_large, background = .Panel, inert = !k.inspector || side_panel_open(k)}, "Tab")
	raised = raised_now
	if closed do k.inspector = false
	if body {
		// The list and the section scroll apart under the title bar, in the room left.
		body_h := max(room - 2 * PADDING - t.target - GAP, 120)
		if wide {
			ui.begin(ctx, "tray", {direction = .Row, gap = TRAY_NAV_GAP})
			kit_tray_list(app, body_h)
		}
		scroll := kit_scroll_begin(ctx, "inspector body", &k.scroll, id, inner, body_h, GAP)
		k.inspector_body, k.inspector_limit, k.inspector_shown = scroll.at, scroll.limit, scroll.shown
		if !wide do kit_tray_select(app)
		// A new section's content fades in: each change starts a tween of its own from 0.
		content := ui.vertex_mark(ctx)
		k.in_tray = true
		switch k.tab {
		case .Tool:   kit_tool_tab(app)
		case .Object: kit_object_tab(app)
		case .Scene:  kit_scene_tab(app)
		}
		k.in_tray = false
		fade := ui.tween_from(ctx, ui.salt(id, 1000 + k.tab_serial), 0, 1, t.indicator_time)
		ui.transform_since(ctx, content, fade)
		tray_mark_draw(app)
		kit_scroll_end(ctx, scroll)
		if wide do ui.end(ctx)
	}
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(win^, .End) * (1 - shown) * 16, 0})
	return
}

// Whether the tray has room for its list beside the content.
tray_wide :: proc(app: ^App) -> bool {
	return ui.safe_area(&app.kit.ctx).w >= TRAY_NAV_MIN_W
}

// The tray's width: the content's, and the list's beside it when there is room.
tray_width :: proc(app: ^App) -> f32 {
	return KIT_INSPECTOR_W + (TRAY_NAV_W + TRAY_NAV_GAP if tray_wide(app) else 0)
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
	owner := ui.id_of(ctx, "menu")
	if !ui.popover_begin(ctx, "menu", &k.menu, anchor, .Below, {direction = .Column, padding = 6, width = 268}) do return
	// On a short window (a phone or a tablet held sideways) the menu scrolls rather than
	// running off the bottom: it holds every file action, the starters and the app's own.
	area := ui.safe_area(ctx)
	room := max(area.y + area.h - (anchor.y + anchor.h + 6) - 4 - 2 * 6, 4 * ctx.theme.target)
	// When it scrolls, its bar takes a strip inside the right edge.
	_, natural := ui.prev_layout(ctx, "menu body")
	body_w := 268 - 2 * 6 - (f32(10) if natural.y > room else 0)
	scroll := kit_scroll_begin(ctx, "menu body", &k.menu_scroll, owner, body_w, room, 0)
	pick := false
	ui.caption(ctx, "  FILE")
	for id in ([?]Command_Id{.Open_Scene, .Save_Scene, .Save_Scene_As, .Save_Scene_Copy, .Scene_Versions, .Open_Last_Autosave, .Import_Mesh, .Export_Mesh, .Screenshot}) {
		if command_menu_item(app, id) do pick = true
	}
	ui.divider(ctx, across = true)
	ui.caption(ctx, "  NEW SCENE")
	// Three to a row, each its shape's name; one armed by a first tap (the scene has work
	// to lose) turns red and asks, and the menu stays open for the second tap.
	w := (body_w - 2 * 6) / 3
	for row in 0 ..< len(NEW_SCENE_SHAPES) / 3 {
		ui.begin(ctx, fmt.tprintf("new scene row %d", row), {direction = .Row, gap = 6})
		for i in row * 3 ..< row * 3 + 3 {
			armed := new_scene_armed(app, i)
			label := "Discard?" if armed else fmt.tprint(NEW_SCENE_SHAPES[i])
			if command_button(app, .New_Scene, i, label = label, variant = .Solid if armed else .Flat, tone = .Danger if armed else .Neutral, width = w) && !new_scene_armed(app, i) do pick = true
		}
		ui.end(ctx)
	}
	// Each content pack's meshes, three to a row under its name, armed the same way.
	for pack, p in app.library.packs {
		if pack.meshes == 0 do continue
		ui.caption(ctx, ui.text_fit(ctx, fmt.tprintf("  %s", strings.to_upper(pack.name, context.temp_allocator)), ctx.theme.caption_size, body_w - 8, .Semibold))
		n := 0
		for m, j in app.library.meshes {
			if m.gone || m.pack != pack.id do continue
			if n % 3 == 0 do ui.begin(ctx, fmt.tprintf("new scene pack %d row %d", p, n / 3), {direction = .Row, gap = 6})
			armed := new_mesh_armed(app, j)
			label := "Discard?" if armed else ui.text_fit(ctx, m.stem, ctx.theme.text_size, w - 12)
			if ui.button(ctx, fmt.tprintf("%s##new scene mesh %d", label, j), .Solid if armed else .Flat, .Danger if armed else .Neutral, width = w) {
				new_mesh_run(app, j)
				if !new_mesh_armed(app, j) do pick = true
			}
			n += 1
			if n % 3 == 0 || n == pack.meshes do ui.end(ctx)
		}
	}
	ui.divider(ctx, across = true)
	ui.caption(ctx, "  APP")
	_ = command_menu_item(app, .Reduce_Motion)
	if command_menu_item(app, .Settings) do pick = true
	_ = command_menu_item(app, .Stats)
	if command_menu_item(app, .Help, int(Help_Tab.Keys), "Help...") do pick = true
	if command_menu_item(app, .Macros) do pick = true
	if command_menu_item(app, .Library) do pick = true
	kit_scroll_end(ctx, scroll)
	ui.popover_end(ctx)
	if pick do k.menu = false
}

// How the viewport shows the scene.
@(private = "file")
kit_view_menu :: proc(app: ^App, anchor: ui.Rect, side: ui.Side) {
	k := &app.kit
	ctx := &k.ctx
	if !ui.popover_begin(ctx, "view menu", &k.view_menu, anchor, side, {direction = .Column, padding = 6, width = 268}) do return
	ui.caption(ctx, "  SHADING")
	for id in ([?]Command_Id{.Wireframe, .Flat_Shading, .Polygroups, .Studio_Render}) do _ = command_menu_item(app, id)
	// Objects with maps: their maps, the normal map alone or the UV checker (none ticked is clay).
	for v in render.Texture_View.Textured ..= render.Texture_View.Uv_Checker do _ = command_menu_item(app, .Texture_View, int(v))
	ui.divider(ctx, across = true)
	ui.caption(ctx, "  CAMERA")
	_ = command_menu_item(app, .Ortho_Toggle)
	// Inset as the menu's rows are.
	ui.begin(ctx, "view menu fov", {direction = .Column, padding = 10})
	kit_field_of_view(app)
	ui.end(ctx)
	if command_menu_item(app, .Focus_Selected) do k.view_menu = false
	if command_menu_item(app, .Reset_Camera) do k.view_menu = false
	// The menu stays open over these, to step back or forward several views.
	_ = command_menu_item(app, .View_Back)
	_ = command_menu_item(app, .View_Forward)
	ui.popover_end(ctx)
}

// The field of view, in degrees: the eye moves along its line as it changes, so the model
// keeps its size on screen and only the perspective strengthens or flattens.
kit_field_of_view :: proc(app: ^App) {
	ctx := &app.kit.ctx
	degrees := math.to_degrees(app.camera.fov_y)
	lo, hi := math.to_degrees(camera.FOV_MIN), math.to_degrees(camera.FOV_MAX)
	if ui.slider(ctx, "Field of view", &degrees, lo, hi, .Linear, fmt.tprintf("%.0f°", degrees)) do camera.orbit_set_fov(&app.camera, math.to_radians(math.round(degrees)))
}

// A size or strength slider's tooltip: its keys, and the three-finger drag when that is on.
slider_hint :: proc(app: ^App, keys: string, step: Command_Id) -> string {
	return hint_join(keys, command_gesture(app, step))
}

// Picks brush `kind` and shows its settings: the tray, on the tool's palette, from the top.
brush_settings_open :: proc(app: ^App, kind: sculpt.Brush_Kind) {
	k := &app.kit
	command_run(app, .Brush, int(kind))
	side_panel_close(app)
	k.inspector, k.tab, k.scroll = true, .Tool, 0
}

// Opens the object menu on object `id`, `side` of `at`.
object_menu_open :: proc(app: ^App, id: int, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	k.object_menu, k.object_menu_id, k.object_menu_at, k.object_menu_side = true, id, at, side
}

// The object's context menu: at the pointer from the Scene palette, above the status chip.
@(private = "file")
kit_object_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	// The object it was opened on has gone (deleted, undone): the menu goes with it.
	found := false
	for obj in app.scene.objects do found ||= obj.id == k.object_menu_id
	if !found do k.object_menu = false
	if !ui.popover_begin(ctx, "object menu", &k.object_menu, k.object_menu_at, k.object_menu_side, {direction = .Column, padding = 6, width = 232}) do return
	picked := command_menu_item(app, .Focus_Selected, label = "Focus")
	if command_menu_item(app, .Duplicate_Object) do picked = true
	if command_menu_item(app, .Rename_Object) do picked = true
	if command_menu_item(app, .Solo_Object) do picked = true
	if command_menu_item(app, .Ghost_Object) do picked = true
	if command_menu_item(app, .Hide_Object) do picked = true
	// Where it can go in the tree: a new folder, each other folder, or out of its own.
	ui.divider(ctx, across = true)
	if command_menu_item(app, .New_Folder) do picked = true
	if obj := object_by_id(app, k.object_menu_id); obj != nil {
		for &f in app.scene.folders {
			if f.id == obj.folder do continue
			if ui.menu_item(ctx, fmt.tprintf("Move to %s##into %d", folder_label(&f), f.id), glyph = ui.ICON_FOLDER) {
				app.ui.scene_command = {kind = .Arrange, arrange = .Into_Folder, id = obj.id, folder = f.id}
				picked = true
			}
		}
		if obj.folder != 0 && ui.menu_item(ctx, "Take out of folder", glyph = ui.ICON_FOLDER) {
			app.ui.scene_command = {kind = .Arrange, arrange = .Out_Of_Folder, id = obj.id}
			picked = true
		}
	}
	ui.divider(ctx, across = true)
	if command_menu_item(app, .Delete_Object, tone = .Danger) do picked = true
	if picked do k.object_menu = false
	ui.popover_end(ctx)
}

// Opens folder `id`'s menu at `at`.
folder_menu_open :: proc(app: ^App, id: int, at: ui.Rect) {
	k := &app.kit
	k.folder_menu, k.folder_menu_id, k.folder_menu_at = true, id, at
}

// A folder's menu in the Scene palette: rename it, empty it into the list, or delete it with
// what is in it.
@(private = "file")
kit_folder_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	f := folder_by_id(app, k.folder_menu_id)
	if f == nil do k.folder_menu = false
	if !ui.popover_begin(ctx, "folder menu", &k.folder_menu, k.folder_menu_at, .Pointer, {direction = .Column, padding = 6, width = 232}) do return
	defer ui.popover_end(ctx)
	if ui.menu_item(ctx, "Rename...##folder", glyph = ui.ICON_PENCIL) {
		rename_open(app, -f.id, k.folder_menu_at)
		k.folder_menu = false
		return
	}
	picked := false
	// The menu still draws as it closes, after its folder went.
	first, end: int
	if f != nil do first, end = folder_span(app, f.id)
	if end > first && ui.menu_item(ctx, "Select its objects", glyph = ui.ICON_FRAME) {
		// Only those in reach can be selected; the first of them carries the gizmo.
		ids := make([dynamic]int, 0, end - first, context.temp_allocator)
		for obj in app.scene.objects[first:end] do if object_pickable(app, obj) do append(&ids, obj.id)
		if len(ids) > 0 do selection_set(app, ids[:])
		picked = true
	}
	if ui.menu_item(ctx, "Ungroup", glyph = ui.ICON_FOLDER) {
		app.ui.scene_command = {kind = .Arrange, arrange = .Ungroup, id = f.id}
		picked = true
	}
	// Polypaint for every object in it at once, as ZBrush's folder menu offers.
	if end > first && ui.menu_item(ctx, "Show polypaint##folder", glyph = ui.ICON_PAINTBRUSH) {
		app.ui.scene_command = {kind = .View, view = .Folder_Paint_Show, id = f.id}
		picked = true
	}
	if end > first && ui.menu_item(ctx, "Hide polypaint##folder", glyph = ui.ICON_PAINTBRUSH) {
		app.ui.scene_command = {kind = .View, view = .Folder_Paint_Hide, id = f.id}
		picked = true
	}
	// Its shown objects as one new object at the end of the list, as ZBrush's Merge Folder.
	if end - first >= 2 && ui.menu_item(ctx, "Merge folder", glyph = ICON_MERGE) {
		app.ui.scene_command = {kind = .Merge, on = true, id = f.id}
		picked = true
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Delete folder and its objects", glyph = ui.ICON_TRASH, tone = .Danger) {
		app.ui.scene_command = {kind = .Arrange, arrange = .Delete_Folder, id = f.id}
		picked = true
	}
	if picked do k.folder_menu = false
}

// The rename field over a row: what an object or a folder (a negative id) is called.
Rename_Entry :: struct {
	open:   bool,
	typing: bool, // its field had the keys, which go back when it closes
	id:     int, // the object, or minus the folder; the slot for a macro
	macro:  bool,
	at:     ui.Rect,
	text:   [NAME_BYTES]u8,
}

// Opens the rename field for object `id` (or folder -`id`) over `at`, empty, with the
// name it has as the field's hint.
rename_open :: proc(app: ^App, id: int, at: ui.Rect) {
	app.kit.rename = {open = true, id = id, at = at}
}

@(private = "file")
kit_rename :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	r := &k.rename
	gone := object_by_id(app, r.id) == nil && folder_by_id(app, -r.id) == nil
	if r.macro do gone = app.macro.slots[r.id].name == ""
	if r.open && gone do r.open = false
	if !r.open && r.typing {
		ctx.text_focus = 0
		r.typing = false
	}
	if !ui.popover_begin(ctx, "rename", &r.open, r.at, .Below, {direction = .Column, gap = 4, padding = 12, width = 280}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "RENAME MACRO" if r.macro else "RENAME FOLDER" if r.id < 0 else "RENAME OBJECT")
	now := ""
	if r.macro {
		now = app.macro.slots[r.id].name
	} else {
		if obj := object_by_id(app, r.id); obj != nil do now = object_label(obj)
		if f := folder_by_id(app, -r.id); f != nil do now = folder_label(f)
	}
	_ = ui.text_field(ctx, "name##rename", r.text[:len(r.text) - 1], hold = r.open, hint = fmt.tprintf("Now %s", now))
	r.typing ||= r.open
	ui.paragraph(ctx, "Enter applies it; left empty, the name stays as it is.")
	apply, cancel := kit_button_pair(ctx, "Apply", "Cancel", tone_a = .Accent)
	d := &app.device
	apply ||= r.open && (key_pressed(d, sdl.K_RETURN) || key_pressed(d, sdl.K_KP_ENTER))
	if apply && r.open && r.macro && rename_text(r.text[:]) != "" {
		// A macro is no part of the scene: its file changes at once, outside the History.
		_ = macro_rename(app, r.id, rename_text(r.text[:]))
	} else if apply && r.open && rename_text(r.text[:]) != "" {
		cmd := Scene_Command{kind = .Arrange, arrange = .Rename_Folder if r.id < 0 else .Rename_Object, id = abs(r.id)}
		copy(cmd.name[:], r.text[:])
		app.ui.scene_command = cmd
	}
	if apply || cancel do r.open = false
}

// The interface's draw commands for the renderer: the viewport's texture (or the
// studio render's, while it is on) where the kit drew KIT_VIEWPORT_IMAGE, the
// navigation head's where it drew KIT_NAV_HEAD_IMAGE, and the objects' pictures where it
// drew KIT_THUMBS_IMAGE.
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
		if c.texture == .Image && c.image == KIT_NAV_HEAD_IMAGE {
			draws[i].image, draws[i].smooth = app.nav_shown, true
			// Without its texture, the head is not drawn at all: a nil image is the atlas.
			if app.nav_shown == nil do draws[i].index_count = 0
		}
		if c.texture == .Image && c.image == KIT_THUMBS_IMAGE {
			draws[i].image, draws[i].smooth = app.thumbs.atlas, true
			if app.thumbs.atlas == nil do draws[i].index_count = 0
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
