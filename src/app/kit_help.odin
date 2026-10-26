package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The Help window (Menu > Help, F1, or "help" in the command palette): every shortcut,
// the mouse and the touch gestures, and a glossary of the app's words beside the names
// other apps give them. The keys come from the keymap (keymap.odin) and the gestures from
// command_gesture, as the tool and the Settings now have them, so the lists never drift
// from what works; only the controls that are no command (a right drag, a pinch) come
// from the tables below. It opens in Settings' place on the right, one or the other.
Help_Tab :: enum u8 {
	Keys,
	Gestures,
	Glossary,
}

HELP_TAB_NAMES := [Help_Tab]string {
	.Keys     = "Keys",
	.Gestures = "Gestures",
	.Glossary = "Glossary",
}

// The Help window's width: Settings', so swapping one for the other in their shared place
// keeps the panel's edge where it was.
KIT_HELP_W :: KIT_SETTINGS_W

// The registry's commands by the part of the app they act on, as Help groups their keys.
Command_Group :: enum u8 {
	File,
	Edit,
	Tools,
	Object,
	Scene,
	View,
	App,
}

COMMAND_GROUP_NAMES := [Command_Group]string {
	.File   = "FILE",
	.Edit   = "EDIT",
	.Tools  = "TOOLS AND THE BRUSH",
	.Object = "THE SELECTED OBJECT",
	.Scene  = "THE SCENE",
	.View   = "THE VIEW",
	.App    = "THE APP",
}

// The group follows the sections Command_Id is written in. The switch is complete, so
// the compiler names any command added outside these ranges.
command_group :: proc(id: Command_Id) -> Command_Group {
	switch id {
	case .None, .New_Scene ..= .Screenshot:   return .File
	case .Undo ..= .Duplicate_Object:         return .Edit
	case .Tool_Move ..= .Replay_Stroke:       return .Tools
	case .Remesh ..= .Reset_Transform:        return .Object
	case .Add_Object ..= .Rename_Object:      return .Scene
	case .View_Axis ..= .Studio_Render:       return .View
	case .Stats ..= .Brush_Pie:                     return .App
	}
	return .App
}

// One line of Help: what it does, and how.
Help_Row :: struct {
	group: string,
	what:  string,
	how:   string,
}

// A control in the tables: a command, whose gesture command_gesture gives (and whose
// name the palette's when `what` is empty), or one that is no command, shown while
// `show` says it works as the tool and the settings are now.
Help_Line :: struct {
	group:   string,
	what:    string,
	how:     string,
	command: Command_Id, // .None: no command
	arg:     int,
	show:    proc(app: ^App) -> bool, // nil: always
}

@(private = "file")
brush_tool :: proc(app: ^App) -> bool {return app.tool == .Brush}

@(private = "file")
move_tool :: proc(app: ^App) -> bool {return app.tool == .Move}

// Empty space turns the view for the brushes and the Move tool (drag_decide).
@(private = "file")
empty_turns :: proc(app: ^App) -> bool {return app.tool == .Brush || app.tool == .Move}

// The keys over the viewport that are no shortcut: they act where the pointer is.
@(rodata)
VIEWPORT_KEYS := [?]Help_Line {
	{group = "OVER THE VIEWPORT", what = "Brush pie", how = "Space, held or tapped"},
	{group = "OVER THE VIEWPORT", what = "Size the brush where it is", how = "S, move, then click", show = brush_tool},
	{group = "OVER THE VIEWPORT", what = "Set the strength where it is", how = "U, move, then click", show = brush_tool},
	{group = "OVER THE VIEWPORT", what = "Close a menu, stop a replay", how = "Esc"},
}

@(rodata)
MOUSE_HELP := [?]Help_Line {
	{group = "MOUSE", what = "Sculpt", how = "Left drag on the model", show = brush_tool},
	{group = "MOUSE", what = "Smooth", how = "Shift + left drag on the model", show = brush_tool},
	{group = "MOUSE", what = "Straight line from the press", how = "Shift mid-stroke", show = brush_tool},
	{group = "MOUSE", what = "Invert the brush", how = "Ctrl + left drag on the model", show = brush_tool},
	{group = "MOUSE", what = "Mask a rectangle or lasso", how = "Ctrl + drag empty space", show = brush_tool},
	{group = "MOUSE", what = "Unmask a rectangle or lasso", how = "Ctrl+Alt + drag empty space", show = brush_tool},
	{group = "MOUSE", what = "Invert the mask", how = "Ctrl + click empty space", show = brush_tool},
	{group = "MOUSE", what = "Hide, clip or slice", how = "Ctrl+Shift + drag", show = brush_tool},
	{group = "MOUSE", what = "Hide or clip the other side", how = "Add Alt", show = brush_tool},
	{group = "MOUSE", what = "Isolate a polygroup (Alt: mask it)", how = "Ctrl+Shift + click it", show = brush_tool},
	{group = "MOUSE", what = "Show everything", how = "Ctrl+Shift + click empty space", show = brush_tool},
	{group = "MOUSE", what = "Select an object", how = "Click it", show = move_tool},
	{group = "MOUSE", what = "Move it", how = "Drag it, a gizmo arm or square", show = move_tool},
	{group = "MOUSE", what = "Turn or scale it", how = "W again, then drag a ring or the middle", show = move_tool},
	{group = "MOUSE", what = "Snap a gizmo drag", how = "Ctrl while dragging", show = move_tool},
	{group = "MOUSE", what = "Put it back mid-drag", how = "Esc", show = move_tool},
	{group = "MOUSE", what = "Type a handle's value", how = "Click the handle without moving", show = move_tool},
	{group = "MOUSE", what = "Turn or scale about a point", how = "Pivot, then click the surface", show = move_tool},
	{group = "MOUSE", what = "Mask along the surface, to pose", how = "Ctrl + drag from the model", show = move_tool},
	{group = "MOUSE", what = "...the other way round", how = "Ctrl+Alt + drag from the model", show = move_tool},
	{group = "MOUSE", what = "Brush pie", how = "Right click"},
	{group = "MOUSE", what = "History brush back to before a step", how = "Right-click the step on the History bar"},
	{group = "MOUSE", what = "Turn the view", how = "Left drag on empty space", show = proc(app: ^App) -> bool {return empty_turns(app) && app.nav.empty_drag[.Mouse] == .Orbit}},
	{group = "MOUSE", what = "Turn the view", how = "Left drag from the edges", show = proc(app: ^App) -> bool {return app.nav.edge_orbit}},
	{group = "MOUSE", what = "Snap to a front, side or top view", how = "Shift while turning"},
	{group = "MOUSE", what = "Add to the selection, or take out", how = "Shift + click an object or a row"},
	{group = "MOUSE", what = "Move a row in the Scene tab", how = "Drag its grip"},
	{group = "MOUSE", what = "Hide or ghost a run of objects", how = "Drag down the eyes or ghosts"},
}

// The commands' gestures, in groups with the touch controls that are no command. Each
// command with a gesture must have a line here (help_touch_rows_hold_every_gesture).
@(rodata)
TOUCH_HELP := [?]Help_Line {
	{group = "SCULPT", what = "Sculpt", how = "One finger on the model", show = proc(app: ^App) -> bool {return app.tool == .Brush && app.nav.finger_model == .Sculpt}},
	{group = "SCULPT", what = "Sculpt with pressure", how = "The pen on the model", show = brush_tool},
	{group = "SCULPT", what = "Ignore a resting hand", how = "While the pen is near", show = proc(app: ^App) -> bool {return app.nav.palm_rejection}},
	{group = "SCULPT", what = "Brush size", command = .Size_Down},
	{group = "SCULPT", command = .Size_Up},
	{group = "SCULPT", what = "Brush strength", command = .Strength_Down},
	{group = "SCULPT", command = .Strength_Up},
	{group = "SCULPT", what = "Smooth, invert, mask or hide", how = "Modifier buttons: tap or hold", show = proc(app: ^App) -> bool {return app.tool == .Brush && app.kit.rail_side != .Off}},
	{group = "SCULPT", what = "Mask or hide a shape", how = "Mask or Hide on, drag empty space", show = proc(app: ^App) -> bool {return app.tool == .Brush && app.kit.rail_side != .Off}},
	{group = "SCULPT", what = "Straight line from the press", how = "Hold Smooth mid-stroke", show = proc(app: ^App) -> bool {return app.tool == .Brush && app.kit.rail_side != .Off}},
	{group = "SCULPT", what = "Mask along the surface, to pose", how = "Mask on, drag from the model", show = proc(app: ^App) -> bool {return app.tool == .Move && app.kit.rail_side != .Off}},
	{group = "SCULPT", command = .Mask, arg = int(sculpt.Mask_Command.Invert)},
	{group = "SCULPT", command = .Mask, arg = int(sculpt.Mask_Command.Blur)},
	{group = "SCULPT", command = .Mask, arg = int(sculpt.Mask_Command.Sharpen)},
	{group = "VIEW", what = "Turn the view", how = "One finger on empty space", show = proc(app: ^App) -> bool {return empty_turns(app) && app.nav.finger_model == .Sculpt}},
	{group = "VIEW", what = "Turn the view", how = "One finger, on the model too", show = proc(app: ^App) -> bool {return app.nav.finger_model == .Orbit}},
	{group = "VIEW", what = "Turn the view", how = "One finger from the edges", show = proc(app: ^App) -> bool {return app.nav.edge_orbit && app.nav.finger_model == .Sculpt}},
	{group = "VIEW", what = "Turn the view", how = "Two fingers down, lift one", show = proc(app: ^App) -> bool {return app.nav.lift_one_orbit}},
	{group = "VIEW", what = "Turn the view", how = "The pen on empty space", show = proc(app: ^App) -> bool {return empty_turns(app) && app.nav.empty_drag[.Pen] == .Orbit}},
	{group = "VIEW", what = "Pan", how = "Drag two fingers", show = proc(app: ^App) -> bool {return app.nav.two_finger_pan}},
	{group = "VIEW", what = "Zoom", how = "Pinch two fingers", show = proc(app: ^App) -> bool {return app.nav.pinch_zoom}},
	{group = "VIEW", what = "Roll", how = "Twist two fingers", show = proc(app: ^App) -> bool {return app.nav.twist_roll && app.nav.orbit_style == .Free}},
	{group = "VIEW", what = "Turn about a point", how = "Double tap the model", show = proc(app: ^App) -> bool {return app.nav.double_tap && (app.tool == .Brush || app.nav.finger_model == .Orbit)}},
	{group = "SCULPT", what = "Brush pie", command = .Brush_Pie},
	{group = "VIEW", command = .Focus_Selected},
	{group = "VIEW", command = .Frame_All},
	{group = "VIEW", command = .Solo_Object},
	{group = "HISTORY", command = .Undo},
	{group = "HISTORY", command = .Redo},
	{group = "HISTORY", what = "Go to a step (History panel)", how = "Tap it on the bar, or drag along it"},
	{group = "HISTORY", what = "History brush back to before a step", how = "Long press the step on the bar"},
	{group = "SCENE TAB", what = "Select several objects", how = "Select several on, then tap"},
	{group = "SCENE TAB", what = "Move an object or a folder", how = "Drag its row's grip"},
	{group = "SCENE TAB", what = "Hide or ghost a run of objects", how = "Hold an eye or ghost, then slide"},
	{group = "ANY CONTROL", what = "Its name, or its second action", how = "Long press"},
}

// A word the app uses, the names other apps give the same thing, and what it means.
// `finds` are the commands the palette must put first for each of `searches`, the other
// apps' names typed into it (help_glossary_names_find_their_commands).
Glossary_Entry :: struct {
	word:     string,
	others:   string,
	means:    string,
	searches: string,
	finds:    bit_set[Command_Id],
}

@(rodata)
GLOSSARY := [?]Glossary_Entry {
	{"Object", "SubTool (ZBrush), object (Blender, Nomad), layer (3DCoat)", "One mesh in the scene, sculpted, moved, hidden and saved on its own. The Scene tab lists them.", "subtool", {.Delete_Object, .Duplicate_Object, .Add_Object}},
	{"Folder", "Folder (ZBrush), collection (Blender), group (Nomad, Maya)", "A row in the Scene tab that gathers objects, one level deep; its eye and ghost apply to all of them.", "collection", {.New_Folder}},
	{"Solo", "Solo (ZBrush, Nomad), local view (Blender), isolate (Maya)", "Only the selected object shown, whichever that is, until Solo is off; the others keep their eyes as they were.", "isolate", {.Solo_Object}},
	{"Ghost", "Transparent (ZBrush), in front and wire display (Blender)", "An object dimmed and out of reach, to sculpt another against it.", "transparent", {.Ghost_Object}},
	{"Brush", "Brush (ZBrush, Blender), tool (Nomad)", "What a stroke does to the surface: Draw, Clay, Smooth and the rest, each with its own size and strength. Keys 1 to 9 and 0 pick the first ten.", "", {}},
	{"Adjust last stroke", "Adjust Last (ZBrush), Adjust Last Operation (Blender)", "How much of the newest stroke stays, set after drawing it, from none to half as much again (Stroke > More, or the palette's Adjust last operation).", "", {}},
	{"History brush", "HistoryRecall brush (ZBrush), history brush (Photoshop)", "A local undo: the History brush paints the surface back to how it was before an earlier step, only where you brush (Brush tab > History brush says which step).", "historyrecall", {.Recall_Earlier, .Recall_Later, .Recall_Oldest}},
	{"Connected only", "Topological auto masking (ZBrush), auto-masking topology (Blender), connected (Nomad)", "A brush working only on the surface joined to where it presses, leaving a finger or fold beside it that is only near in space (Brush tab > Options).", "automasking", {.Connected}},
	{"Lock plane", "Original plane (ZBrush), plane lock (Nomad), original normal (Blender)", "A stroke keeping the plane its first dab found, so a long Flatten or Clay stroke does not drift with the surface (Brush tab > Options).", "original", {.Lock_Plane}},
	{"Mask", "Mask (ZBrush, Blender, Nomad), freeze (3DCoat)", "Paint on the surface that no brush can move. Masked parts show darker.", "freeze", {.Mask}},
	{"Pose", "Gizmo 3D with a mask (ZBrush), Pose brush (Blender, Nomad), Pose tool (3DCoat)", "The Move tool's handles bending the unmasked part of an object about the gizmo, the mask's soft edge as the joint, instead of moving the whole object. Ctrl + drag from the model masks along the surface for it (a topological mask).", "posing", {.Gizmo}},
	{"Selection set", "Selection set (ZBrush), stored freeze (3DCoat)", "A mask kept by name with the object, to make the mask again later or add to it (Object tab > Select > Selection sets).", "selection", {.Store_Selection_Set, .Restore_Selection_Set}},
	{"Hide", "Hide (ZBrush, Nomad), visibility (Blender)", "Parts taken out of view, which brushes then leave alone, until shown again.", "visibility unhide", {.Show_All, .Invert_Hidden, .Hide_Masked, .Hide_Unmasked}},
	{"Group", "Polygroup (ZBrush), face set (Blender, Nomad)", "A set of faces in one colour, for masking, hiding or picking by.", "polygroup", {.Group_Shortcut, .Group, .Polygroups}},
	{"Level", "Subdivision level (ZBrush), Multires (Blender), multiresolution (Nomad)", "A finer copy of the object made by Subdivide. Detail sculpted on one level shows on the rest.", "subdivision multires", {.Subdivide, .Level_Up, .Level_Down, .Delete_Lower_Levels, .Delete_Higher_Levels}},
	{"Layer", "Layer (ZBrush, Nomad), shape key (Blender)", "Changes kept apart from the sculpt under them, which can be faded or turned off (Object tab > Layers). Not the Layer brush, which raises the surface evenly.", "", {}},
	{"Remesh", "DynaMesh (ZBrush), voxel remesh (Blender, Nomad), voxelize (3DCoat)", "Rebuilds the object as an even mesh that keeps its shape, joining what overlaps.", "dynamesh voxelize", {.Remesh, .Remesh_To}},
	{"Retopologize", "ZRemesher (ZBrush), QuadriFlow (Blender), auto-retopo (3DCoat)", "Builds a light mesh of quads over the sculpt, for animation, UVs and baking.", "zremesher quadriflow", {.Retopologize}},
}

// The Keys tab's rows: every command with a shortcut, by group and with all its chords,
// then the keys over the viewport and the mouse as the tool has them. In temp memory.
help_key_rows :: proc(app: ^App) -> []Help_Row {
	out := make([dynamic]Help_Row, 0, 128, context.temp_allocator)
	for group in Command_Group {
		for id in Command_Id {
			if command_group(id) != group do continue
			for arg in 0 ..< max(COMMANDS[id].args, 1) {
				chords := command_chords(app, id, arg)
				if chords != "" do append(&out, Help_Row{COMMAND_GROUP_NAMES[group], help_name(id, arg), chords})
			}
		}
	}
	help_lines(app, VIEWPORT_KEYS[:], &out)
	help_lines(app, MOUSE_HELP[:], &out)
	// Turn, pan and zoom as the mouse scheme in Settings > Keys has them.
	for how, i in MOUSE_SCHEME_HOW[app.nav.mouse_scheme] do append(&out, Help_Row{"MOUSE", MOUSE_ACTIONS[i], how})
	return out[:]
}

// The Gestures tab's rows, as the tool and the Settings have them now. In temp memory.
help_touch_rows :: proc(app: ^App) -> []Help_Row {
	out := make([dynamic]Help_Row, 0, 64, context.temp_allocator)
	help_lines(app, TOUCH_HELP[:], &out)
	// What the gesture map runs that the table above has no line for, once a command.
	listed: for slot in Gesture_Slot {
		s := app.nav.gestures[slot]
		if s.id == .None || (slot == .Pen_Button && s.id == .Brush_Pie) do continue
		for l in TOUCH_HELP do if l.command == s.id && l.arg == s.arg do continue listed
		for earlier in Gesture_Slot {
			if earlier >= slot do break
			if app.nav.gestures[earlier] == s do continue listed
		}
		append(&out, Help_Row{"YOUR GESTURES", pie_slot_label(s), gesture_text(app, s.id, s.arg)})
	}
	return out[:]
}

// The table's lines that apply now. A command line with no gesture now is left out, and
// so is one with the same gesture as the line before it (both size steps are one drag).
@(private = "file")
help_lines :: proc(app: ^App, lines: []Help_Line, out: ^[dynamic]Help_Row) {
	last := ""
	for l in lines {
		row := Help_Row{l.group, l.what, l.how}
		if l.command != .None {
			row.how = command_gesture(app, l.command, l.arg)
			if row.how == "" || row.how == last do continue
			if row.what == "" do row.what = help_name(l.command, l.arg)
		} else if l.show != nil && !l.show(app) {
			continue
		}
		append(out, row)
		last = row.how
	}
}

// The command's name as the palette shows it, without a menu's "...".
help_name :: proc(id: Command_Id, arg: int) -> string {
	return strings.trim_suffix(palette_label({.Command, id, arg}), "...")
}

// Opens Help on `tab` from its top, in Settings' place, unfolded and in front.
help_open :: proc(app: ^App, tab: Help_Tab) {
	k := &app.kit
	if k.settings do settings_close(app)
	k.help, k.help_tab, k.help_scroll = true, tab, 0
	k.windows[.Help].minimized = false
	window_raise(k, .Help)
}

kit_help :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	id := ui.id_of(ctx, "help")
	shown := ui.presence(ctx, id, k.help, t.panel_time)
	if shown <= 0 do return
	win := &k.windows[.Help]
	top := kit_top()
	room := window_room(app, win^, top)
	if !win.moved do room -= side_panel_below(app, KIT_HELP_W)
	inner := f32(KIT_HELP_W - 2 * 16)

	mark := ui.vertex_mark(ctx)
	body, closed, raised_now := ui.window_begin(ctx, "help", "Help", win, .End, .Start, {kit_right(app), top}, {direction = .Column, gap = 8, padding = 16, width = KIT_HELP_W, radius = t.radius_large, background = .Panel, inert = !k.help}, "Esc")
	raised = raised_now
	if closed do k.help = false
	if body {
		names: [len(Help_Tab)]string
		for tab in Help_Tab do names[int(tab)] = HELP_TAB_NAMES[tab]
		if picked := ui.tabs(ctx, "help tabs", names[:], int(k.help_tab)); picked >= 0 && Help_Tab(picked) != k.help_tab {
			k.help_tab = Help_Tab(picked)
			k.help_scroll = 0
		}
		body_h := max(room - 2 * 16 - 2 * 8 - 2 * t.target, 120)
		scroll := kit_scroll_begin(ctx, "help body", &k.help_scroll, id, inner, body_h, 4)
		tool := kit_tool_name(app.tool)
		switch k.help_tab {
		case .Keys:
			help_rows(app, help_key_rows(app), inner)
			ui.paragraph(ctx, fmt.tprintf("The viewport keys and the mouse are as the %s tool has them; they change with the tool.", tool))
			ui.paragraph(ctx, "To give a command another key, Ctrl+Alt+click its button or menu row, tap it in Settings > Keys, or pick it in Search and tap Assign key. Settings > Keys also makes the mouse turn, pan and zoom as Blender or Maya does.")
			if ui.button(ctx, "Keys settings", .Bordered, glyph = ui.ICON_KEYBOARD) do settings_open(app, .Keys)
		case .Gestures:
			ui.paragraph(ctx, fmt.tprintf("With the %s tool and the settings as they are now: a gesture turned off is not listed.", tool))
			ui.spacer(ctx, 4)
			help_rows(app, help_touch_rows(app), inner)
			ui.paragraph(ctx, "Gestures turn on and off in Settings > Touch, the edges that turn the view in Settings > Camera, and the modifier buttons in Settings > Interface.")
			if ui.button(ctx, "Touch settings", .Bordered, glyph = ui.ICON_SETTINGS) do settings_open(app, .Touch)
			_ = command_button(app, .Coach_Tips, variant = .Bordered, glyph = ui.ICON_HELP)
		case .Glossary:
			help_glossary(app)
		}
		kit_scroll_end(ctx, scroll)
	}
	ui.window_end(ctx)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(win^, .End) * (1 - shown) * 16, 0})
	return
}

// The rows under a caption for each group. A row whose two halves fit side by side is one
// line; a longer one puts how under what.
@(private = "file")
help_rows :: proc(app: ^App, rows: []Help_Row, width: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	group := ""
	for r in rows {
		if r.group != group {
			if group != "" do ui.spacer(ctx, 8)
			ui.caption(ctx, r.group)
			group = r.group
		}
		if ui.text_width(ctx, r.what, t.small_size) + ui.text_width(ctx, r.how, t.small_size) + 24 <= width {
			ui.value_row(ctx, r.what, r.how)
		} else {
			ui.label(ctx, r.what, t.small_size)
			ui.label(ctx, r.how, t.small_size, t.text)
		}
	}
	ui.spacer(ctx, 8)
}

@(private = "file")
help_glossary :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.paragraph(ctx, fmt.tprintf("The words this app uses, and what other apps call the same thing. Search (%s) finds a command by either.", command_keys(app, .Command_Palette)))
	for g in GLOSSARY {
		ui.spacer(ctx, 6)
		ui.label(ctx, g.word, 0, t.text, .Semibold)
		ui.paragraph(ctx, g.means)
		ui.paragraph(ctx, fmt.tprintf("Elsewhere: %s.", g.others), color = t.text_tertiary)
	}
}
