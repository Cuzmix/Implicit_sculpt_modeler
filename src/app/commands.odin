package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../render"
import "../gizmo"
import "../sculpt"
import "../ui"

// The command registry: every action the keyboard, the menus, the pie and the
// buttons run, in one table with its name, help, icon and state, and the key chords
// bound to it. A menu row or a shortcut names a command instead of calling its code,
// so the shortcut a menu shows is the one that works, and search, rebinding and
// scripts later read the same table. Strokes are not commands: they stay on the
// pointer's path (sculpt_tool.odin), which only reads the modifier keys.

Command_Id :: enum u8 {
	None,
	// File
	Home,
	New_Scene, // the argument is into NEW_SCENE_SHAPES
	Open_Scene,
	Save_Scene,
	Save_Scene_As,
	Save_Scene_Copy,
	Save_Scene_Next,
	Scene_Versions,
	Open_Last_Autosave,
	Import_Mesh,
	Export_Mesh,
	Export_Print,
	Screenshot,
	Screenshot_Transparent,
	Record_Turntable,
	Send_To_Blender,
	Get_From_Blender,
	// Edit
	Undo,
	Redo,
	Delete_Older_History,
	Delete_Object,
	Duplicate_Object,
	// Tools and the brush
	Tool_Move,
	Tool_Sculpt,
	Tool_Curve,
	Tool_Insert,
	Gizmo, // the argument is the gizmo.Mode
	Gizmo_Snap,
	Gizmo_Pivot,
	Gizmo_Pivot_Reset,
	Brush, // the argument is the sculpt.Brush_Kind
	Symmetry_X,
	Local_Symmetry,
	Radial_Symmetry,
	Brush_Add,
	Brush_Subtract,
	Paint_Channel,
	Swap_Colors,
	Colors_Card,
	Eyedropper,
	Front_Only,
	Lock_Plane,
	Connected,
	Size_Down,
	Size_Up,
	Strength_Down,
	Strength_Up,
	Preset_Save_New,
	Preset_Save,
	Preset_Revert,
	Preset_Delete,
	Brush_Reset,
	Replay_Stroke,
	// The selected object
	Remesh,
	Dyntopo_Toggle,
	Subdivide,
	Level_Up,
	Level_Down,
	Hd_Toggle,
	Group_Shortcut,
	Mask, // the argument is the sculpt.Mask_Command
	Mask_By, // the argument is the sculpt.Mask_By
	Mask_Adjust,
	Show_All,
	Invert_Hidden,
	Hide_Masked,
	Hide_Unmasked,
	Grow_Visible,
	Shrink_Visible,
	Grow_All_Visible,
	Outer_Ring,
	Grow_To_Groups,
	Show_Masked,
	Store_Selection_Set,
	Restore_Selection_Set, // the argument is the set's place, from 0
	Paint, // the argument is the sculpt.Paint_Command
	Group, // the argument is the sculpt.Group_Command
	Pick_Group,
	Delete_Lower_Levels,
	Delete_Higher_Levels,
	Hd_Divide,
	Hd_Delete,
	Hd_Sculpt,
	Hd_Leave,
	Morph_Store,
	Morph_Delete,
	New_Layer,
	Layer_Edit, // the argument is the Layer_Action, on the Layers section's selected layer
	Recall_Earlier,
	Recall_Later,
	Recall_Oldest,
	Smooth_All,
	Deformer, // the argument is the sculpt.Deform_Kind
	Deformation, // the argument is the Reshape_Choice
	Reshape_Repeat,
	Remesh_To, // the argument is the SPHERE_PRESETS size
	Decimate_To, // ...and here too
	Rebuild,
	Mirror_Weld,
	Close_Holes,
	Delete_Hidden,
	Weld_Points,
	Check_Mesh,
	Fix_Mesh,
	Delete_Half,
	Retopologize,
	Make_Boolean,
	Live_Boolean,
	Extract_Masked,
	Convert_To_Mesh,
	Convert_To_Voxels,
	Voxel_Res_Up,
	Voxel_Res_Down,
	Adjust_Last,
	Reset_Transform,
	// The scene
	Add_Object,
	Frame_All,
	Hide_Object,
	Ghost_Object,
	Show_All_Objects,
	Solo_Object,
	New_Folder,
	Objects_Card,
	Copy_Object,
	Paste_Object,
	Object_To_Top,
	Object_To_Bottom,
	Delete_Other_Objects,
	Delete_All_Objects,
	All_Lowest_Level,
	All_Highest_Level,
	Visibility_Slot, // the argument is the stored visibility, V1 being 0
	Split_Object, // the argument is the Split_Mode
	Merge_Down,
	Merge_Visible,
	Align_Objects, // the argument is the axis times 3 plus the edge (min, centre, max)
	Distribute_Objects, // as Align_Objects
	Rename_Object,
	// The view
	View_Axis, // the argument is the camera.Axis_View
	Ortho_Toggle,
	Focus_Selected,
	Reset_Camera,
	View_Back,
	View_Forward,
	Camera_Menu,
	Shading_Menu,
	Wireframe,
	Flat_Shading,
	Texture_View,
	Load_Texture, // the argument is the render.Texture_Map
	Remove_Textures,
	Polygroups,
	Studio_Render,
	Live_Occlusion,
	Render_Mode,
	Pick_Focus,
	Focus_Pivot,
	Viewport_Look, // the argument is the Look_Preset
	Floor_Grid,
	Thumbnail,
	Transparency,
	// The app
	Stats,
	Inspector,
	Show_Section, // the argument is the Kit_Section, below TRAY_SECTIONS
	Settings,
	Reduce_Motion,
	Command_Palette,
	Customise_Bars,
	Help, // the argument is the Help_Tab
	Coach_Tips,
	Pie, // the argument is the user pie, from 0 (user_pies.odin)
	Pie_Editor,
	Brush_Pie,
	Macro_Record,
	Run_Macro, // the argument is the slot, from 0 (macros.odin)
	Macros,
	Run_Script,
	Run_Plugin, // the argument is the slot, from 0 (plugins.odin)
	Reload_Plugins,
	Library,
	Pick_Pack,
	Save_Pack,
}

Command :: struct {
	label:   string, // what menus and search show
	help:    string, // one sentence on what it does
	icon:    rune, // 0 for none
	args:    int, // 0: takes no argument; n: takes 0 ..< n
	run:     proc(app: ^App, arg: int),
	enabled: proc(app: ^App, arg: int) -> bool, // nil: always
	checked: proc(app: ^App, arg: int) -> bool, // nil: not something that is on or off
}

Key_Mod :: enum u8 {
	Ctrl,
	Shift,
	Alt,
}

// A key and the modifiers held with it, matched exactly: Ctrl+Z is not Ctrl+Shift+Z,
// so one key never means two things (README "Controls").
Chord :: struct {
	key:    sdl.Keycode,
	mods:   bit_set[Key_Mod;u8],
	repeat: bool, // the key's auto-repeat runs it again
}

Binding :: struct {
	chord:   Chord,
	command: Command_Id,
	arg:     int,
}

has_object :: proc(app: ^App, _: int) -> bool {return selected_object(app) != nil}

// Whether a mesh object is selected (not a voxel one, which has its own repair).
has_mesh_object :: proc(app: ^App, _: int) -> bool {
	obj := selected_object(app)
	return obj != nil && obj.voxel == nil
}

// Whether any object has subdivision levels to step between.
any_levels :: proc(app: ^App, _: int) -> bool {
	for obj in app.scene.objects do if len(obj.levels.levels) > 1 do return true
	return false
}

// Moves the selected object to the top (or the bottom) of the list, or of its folder when
// it is in one: before the first object there, or after the last.
object_to_end :: proc(app: ^App, top: bool) {
	obj := selected_object(app)
	if obj == nil do return
	objects := app.scene.objects[:]
	first, end := 0, len(objects)
	if obj.folder != 0 do first, end = folder_span(app, obj.folder)
	before := 0
	if top do before = objects[first].id
	else if end < len(objects) do before = objects[end].id
	app.ui.scene_command = {kind = .Arrange, arrange = .Reorder, id = obj.id, before = before, folder = obj.folder}
}

// How many selection sets the commands reach by number, as keys 1 to 9 would.
SET_COMMANDS :: 9

// Whether the selected object can hide by its mask: it has one where it is sculpted, and
// it is neither in HD nor under dynamic topology, where hiding is refused.
has_mask :: proc(app: ^App, _: int) -> bool {
	obj := selected_object(app)
	return obj != nil && !object_in_hd(obj) && !object_dynamic(obj) && object_has_mask(app, obj)
}

// Whether the selected object can change what is hidden: not in HD or under dynamic
// topology.
hide_ready :: proc(app: ^App, _: int) -> bool {
	obj := selected_object(app)
	return obj != nil && !object_in_hd(obj) && !object_dynamic(obj)
}

// ...and has something hidden, to show.
has_hidden :: proc(app: ^App, arg: int) -> bool {
	return hide_ready(app, arg) && sculpt.sculptor_hidden_count(object_sculptor(selected_object(app))) > 0
}

@(rodata)
COMMANDS := [Command_Id]Command {
	.None = {},
	.Home = {
		label = "Home",
		help = "Shows the Home screen: new scenes, and the scenes saved lately and the autosaves of earlier sessions as pictures, to open one.",
		icon = ICON_HOME,
		run = proc(app: ^App, _: int) {
			if app.kit.home do home_close(app)
			else do home_open(app)
		},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.home},
	},
	.New_Scene = {
		label = "New scene",
		help = "Replaces the scene with this one shape at the Scene palette's Add size; with work to lose, it goes ahead on a second run.",
		icon = ui.ICON_SHAPES,
		args = len(NEW_SCENE_SHAPES),
		run = new_scene_run,
	},
	.Open_Scene = {
		label = "Open scene...",
		help = "Opens a saved .sculpt scene in place of this one.",
		icon = ui.ICON_OPEN,
		run = proc(app: ^App, _: int) {file_dialog(app, .Open)},
	},
	.Save_Scene = {
		label = "Save scene",
		help = "Saves the scene where it was last saved or opened, or asks where the first time.",
		icon = ui.ICON_SAVE,
		run = proc(app: ^App, _: int) {save_scene(app)},
	},
	.Save_Scene_As = {
		label = "Save scene as...",
		help = "Saves the scene to a new file.",
		run = proc(app: ^App, _: int) {file_dialog(app, .Save)},
	},
	.Save_Scene_Copy = {
		label = "Save a copy...",
		help = "Saves the scene to another file and keeps saving it where it was: a backup, or a variation to come back to.",
		icon = ui.ICON_SAVE,
		run = proc(app: ^App, _: int) {file_dialog(app, .Save_Copy)},
	},
	.Save_Scene_Next = {
		label = "Save next",
		help = "Saves the scene as the next numbered file beside its own (dragon_002.sculpt after dragon.sculpt or dragon_001.sculpt) and keeps saving there, so each stage of a sculpt stays a file of its own.",
		icon = ui.ICON_SAVE,
		enabled = proc(app: ^App, _: int) -> bool {return save_next_allowed(app)},
		run = proc(app: ^App, _: int) {save_scene_next(app)},
	},
	.Scene_Versions = {
		label = "Earlier saves...",
		help = "Lists the files earlier saves of this scene replaced, to open one again.",
		icon = ui.ICON_HISTORY,
		run = proc(app: ^App, _: int) {
			versions_refresh(app)
			k := &app.kit
			k.menu, k.versions, k.version_armed = false, true, 0
		},
		enabled = proc(app: ^App, _: int) -> bool {return app.scene_path != "" && len(app.versions) > 0},
	},
	.Open_Last_Autosave = {
		label = "Open the last autosave",
		help = "Opens the newest autosave an earlier run left, whether it crashed or closed without saving.",
		icon = ui.ICON_HISTORY,
		run = proc(app: ^App, _: int) {file_post(.Recover, "")},
		enabled = proc(app: ^App, _: int) -> bool {return app.autosave.on},
	},
	.Import_Mesh = {
		label = "Import mesh...",
		help = "Adds an OBJ, PLY or STL mesh to the scene.",
		icon = ui.ICON_IMPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Import)},
	},
	.Export_Mesh = {
		label = "Export mesh...",
		help = "Writes the selected object as OBJ, PLY, STL, glTF or USD.",
		icon = ui.ICON_EXPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Export)},
		enabled = has_object,
	},
	.Export_Print = {
		label = "Export for printing...",
		help = "Writes the selected object as an STL file for a 3D printer: at its print size in millimetres (Scene > 3D print), Z up, standing on the bed.",
		icon = ui.ICON_EXPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Export_Print)},
		enabled = has_object,
	},
	.Send_To_Blender = {
		label = "Send to Blender",
		help = "Writes the selected objects to the Blender link's folder, for Get from Sculpt in Blender's Sculpt tab (Settings > System > Blender link).",
		icon = ui.ICON_EXPORT,
		run = proc(app: ^App, _: int) {file_post(.Link_Send, "")},
		enabled = proc(app: ^App, _: int) -> bool {return link_can_send(app)},
	},
	.Get_From_Blender = {
		label = "Get from Blender",
		help = "Brings back what Blender's Send to Sculpt left in the link's folder: same triangles move the vertices, others rebuild the object, new ones are added; one undo step. Switching back to Sculpt does it too.",
		icon = ui.ICON_IMPORT,
		run = proc(app: ^App, _: int) {file_post(.Link_Get, "")},
		enabled = proc(app: ^App, _: int) -> bool {return link_can_get(app)},
	},
	.Screenshot = {
		label = "Save screenshot...",
		help = "Saves the window as a PNG image.",
		icon = ui.ICON_IMAGE,
		run = proc(app: ^App, _: int) {file_dialog(app, .Screenshot)},
	},
	.Screenshot_Transparent = {
		label = "Screenshots without background",
		help = "Saves screenshots with the objects alone on a see-through ground, soft at their edges, to lay over other pictures: no background, floor grid or environment picture.",
		icon = ui.ICON_IMAGE,
		run = proc(app: ^App, _: int) {app.screenshot_transparent = !app.screenshot_transparent},
		checked = proc(app: ^App, _: int) -> bool {return app.screenshot_transparent},
	},
	.Record_Turntable = {
		label = "Record turntable...",
		help = "Turns the camera once round the scene and saves every frame into a folder you pick, as numbered PNG pictures and one animated PNG that plays in a browser; again, while it records, stops it.",
		icon = ui.ICON_FILM,
		run = proc(app: ^App, _: int) {
			if turntable_recording(app) do turntable_stop(app, "stopped")
			else do file_dialog(app, .Turntable)
		},
		enabled = proc(app: ^App, _: int) -> bool {return !app.stroke.active && app.timeline.lapse.state == .Off},
		checked = proc(app: ^App, _: int) -> bool {return turntable_recording(app)},
	},
	.Undo = {
		label = "Undo",
		help = "Takes back the last step.",
		icon = ui.ICON_UNDO,
		run = proc(app: ^App, _: int) {history_undo(app)},
		enabled = proc(app: ^App, _: int) -> bool {return history_can_undo(app)},
	},
	.Redo = {
		label = "Redo",
		help = "Does the last undone step again.",
		icon = ui.ICON_REDO,
		run = proc(app: ^App, _: int) {history_redo(app)},
		enabled = proc(app: ^App, _: int) -> bool {return history_can_redo(app)},
	},
	.Delete_Older_History = {
		label = "Delete older history",
		help = "Forgets every step that can be undone, freeing the memory they hold; the steps that can be redone stay. It cannot be undone.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {history_delete_older(app)},
		enabled = proc(app: ^App, _: int) -> bool {return history_can_undo(app) && !timeline_busy(app)},
	},
	.Delete_Object = {
		label = "Delete",
		help = "Removes the selected objects; Undo brings them back.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Delete}},
		enabled = has_object,
	},
	.Duplicate_Object = {
		label = "Duplicate",
		help = "Adds a copy of each selected object, keeping their spacing.",
		icon = ui.ICON_COPY,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Duplicate}},
		enabled = has_object,
	},
	.Tool_Move = {
		label = "Move tool",
		help = "Selects objects and moves, turns or scales them with the gizmo; its key again steps the gizmo through the three.",
		icon = ui.ICON_MOVE,
		run = proc(app: ^App, _: int) {app.tool = .Move},
		checked = proc(app: ^App, _: int) -> bool {return app.tool == .Move},
	},
	.Tool_Sculpt = {
		label = "Sculpt tool",
		help = "Sculpts the object under the brush with the chosen brush.",
		icon = ui.ICON_BRUSH,
		run = proc(app: ^App, _: int) {app.tool = .Brush},
		checked = proc(app: ^App, _: int) -> bool {return app.tool == .Brush},
	},
	.Tool_Curve = {
		label = "Curve tool",
		help = "Draws a tube, stitches or a zipper over the surface.",
		icon = ui.ICON_SPLINE,
		run = proc(app: ^App, _: int) {app.tool = .Curve},
		checked = proc(app: ^App, _: int) -> bool {return app.tool == .Curve},
	},
	.Tool_Insert = {
		label = "Insert tool",
		help = "Places a shape on the surface where you tap.",
		icon = ui.ICON_SHAPES,
		run = proc(app: ^App, _: int) {app.tool = .Insert},
		checked = proc(app: ^App, _: int) -> bool {return app.tool == .Insert},
	},
	.Gizmo = {
		label = "Gizmo",
		help = "Picks the Move tool and what its gizmo's handles do: move along an arm or across a plane, turn about a ring, or scale from the middle. With a mask on the one object selected, they pose its unmasked part instead.",
		icon = ui.ICON_MOVE,
		args = len(gizmo.Mode),
		run = proc(app: ^App, arg: int) {
			app.tool = .Move
			app.move.mode = gizmo.Mode(arg)
		},
		checked = proc(app: ^App, arg: int) -> bool {return app.tool == .Move && app.move.mode == gizmo.Mode(arg)},
	},
	.Gizmo_Snap = {
		label = "Snap the gizmo",
		help = "Makes every gizmo drag snap: moves to steps of a grid that follows the zoom, turns to 15 degrees, scales to steps of 0.1. Ctrl snaps one drag.",
		icon = ui.ICON_GRID,
		run = proc(app: ^App, _: int) {app.move.snap = !app.move.snap},
		checked = proc(app: ^App, _: int) -> bool {return app.move.snap},
	},
	.Gizmo_Pivot = {
		label = "Set the pivot",
		help = "The next tap or click on a surface puts the gizmo there, so turns and scales go about that point; the selection stays.",
		icon = ui.ICON_FOCUS,
		run = proc(app: ^App, _: int) {
			app.tool = .Move
			app.move.pivot_latch = !app.move.pivot_latch
		},
		enabled = has_object,
		checked = proc(app: ^App, _: int) -> bool {return app.tool == .Move && app.move.pivot_latch},
	},
	.Gizmo_Pivot_Reset = {
		label = "Reset the pivot",
		help = "Puts the gizmo back on the selected object's origin.",
		run = proc(app: ^App, _: int) {app.move.pivot = {}},
		enabled = proc(app: ^App, _: int) -> bool {return gizmo_pivot_set(app)},
	},
	.Brush = {
		label = "Brush",
		help = "Picks a brush and the Sculpt tool.",
		icon = ui.ICON_BRUSH,
		args = len(sculpt.Brush_Kind),
		run = proc(app: ^App, arg: int) {
			// A plain brush: off any preset, with its own values back.
			preset_leave(app)
			app.brush.kind = sculpt.Brush_Kind(arg)
			app.tool = .Brush
		},
		checked = proc(app: ^App, arg: int) -> bool {return app.tool == .Brush && app.brush.kind == sculpt.Brush_Kind(arg) && app.brush.preset == 0},
	},
	.Symmetry_X = {
		label = "Symmetry across X",
		help = "Mirrors strokes across the X axis.",
		run = proc(app: ^App, _: int) {app.brush.symmetry ~= {.X}},
		checked = proc(app: ^App, _: int) -> bool {return .X in app.brush.symmetry},
	},
	.Local_Symmetry = {
		label = "Local symmetry",
		help = "Mirrors strokes about the object's own middle instead of its origin, so an object built or moved off centre keeps its symmetry.",
		run = proc(app: ^App, _: int) {app.brush.sym_local = !app.brush.sym_local},
		checked = proc(app: ^App, _: int) -> bool {return app.brush.sym_local},
	},
	.Radial_Symmetry = {
		label = "Radial symmetry",
		help = "Repeats every stroke evenly round an axis, as many times as the Symmetry settings say (a long press on Symmetry).",
		run = proc(app: ^App, _: int) {app.brush.radial_on = !app.brush.radial_on},
		checked = proc(app: ^App, _: int) -> bool {return app.brush.radial_on},
	},
	.Brush_Add = {
		label = "Add",
		help = "Brushes work their usual way: Draw raises, Clay builds up (as without Ctrl).",
		icon = ICON_ADD,
		run = proc(app: ^App, _: int) {app.rail.latched -= {.Invert}},
		checked = proc(app: ^App, _: int) -> bool {return .Invert not_in app.rail.latched},
	},
	.Brush_Subtract = {
		label = "Subtract",
		help = "Brushes work the other way until Add is chosen: Draw digs, Clay carves (as with Ctrl held, or the wheel's Invert latched).",
		icon = ICON_SUBTRACT,
		run = proc(app: ^App, _: int) {app.rail.latched += {.Invert}},
		checked = proc(app: ^App, _: int) -> bool {return .Invert in app.rail.latched},
	},
	.Paint_Channel = {
		label = "Sculpt and paint",
		help = "Steps the sculpting brushes from moving the surface, to moving and painting it with the colour, to only painting it (Paint, Mask, Grab and Cloth keep to their own).",
		icon = ICON_CHANNEL_BOTH,
		run = proc(app: ^App, _: int) {
			c := &app.brush.channel
			c^ = sculpt.Channel((int(c^) + 1) % len(sculpt.Channel))
		},
		checked = proc(app: ^App, _: int) -> bool {return app.brush.channel != .Sculpt},
	},
	.Swap_Colors = {
		label = "Swap colours",
		help = "Trades the main colour, which brushes paint, with the secondary one.",
		icon = ICON_SWAP_COLORS,
		run = proc(app: ^App, _: int) {swap_colors(app)},
	},
	.Colors_Card = {
		label = "Colors",
		help = "Opens the Colors card beside the brush bar: Disc, Classic, Harmony, Value and Palettes, the colours picked last, Fill and the Eyedropper.",
		icon = ICON_COLOUR,
		run = proc(app: ^App, _: int) {colors_card_toggle(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.colors_card},
	},
	.Eyedropper = {
		label = "Eyedropper",
		help = "Picks the colour of the surface under the pointer; from a button, the next press on the model picks it, and dragging shows it in a loupe first.",
		icon = ICON_EYEDROPPER,
		run = proc(app: ^App, _: int) {eyedropper_command(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.ui.eyedrop_armed || app.ui.eyedrop_held},
	},
	.Front_Only = {
		label = "Front faces only",
		help = "Brushes and mask shapes leave what faces away from you, such as the far side of a thin part.",
		run = proc(app: ^App, _: int) {app.brush.front_only = !app.brush.front_only},
		checked = proc(app: ^App, _: int) -> bool {return app.brush.front_only},
	},
	.Lock_Plane = {
		label = "Lock plane",
		help = "Keeps the plane a stroke's first dab finds for the whole stroke, so long Flatten, Clay and Draw strokes do not drift.",
		run = proc(app: ^App, _: int) {app.brush.lock_plane = !app.brush.lock_plane},
		checked = proc(app: ^App, _: int) -> bool {return app.brush.lock_plane},
	},
	.Connected = {
		label = "Connected only",
		help = "Brushes work only on the surface joined to where they press, leaving a finger or fold that is only near in space; Grab picks up only that part.",
		run = proc(app: ^App, _: int) {app.brush.connected = !app.brush.connected},
		checked = proc(app: ^App, _: int) -> bool {return app.brush.connected},
	},
	.Size_Down = {
		label = "Smaller brush",
		help = "Makes the brush a sixth smaller.",
		icon = ui.ICON_SIZE,
		run = proc(app: ^App, _: int) {brush_size_step(app, false)},
	},
	.Size_Up = {
		label = "Bigger brush",
		help = "Makes the brush a sixth bigger.",
		icon = ui.ICON_SIZE,
		run = proc(app: ^App, _: int) {brush_size_step(app, true)},
	},
	.Strength_Down = {
		label = "Weaker brush",
		help = "Lowers the brush's strength by 0.05.",
		icon = ui.ICON_STRENGTH,
		run = proc(app: ^App, _: int) {brush_strength_step(app, false)},
	},
	.Strength_Up = {
		label = "Stronger brush",
		help = "Raises the brush's strength by 0.05.",
		icon = ui.ICON_STRENGTH,
		run = proc(app: ^App, _: int) {brush_strength_step(app, true)},
	},
	.Preset_Save_New = {
		label = "Save brush as preset",
		help = "Keeps the brush as it is (strength, falloff, alpha, stroke) as a new preset, and puts the brush on it.",
		icon = ui.ICON_SAVE,
		run = proc(app: ^App, _: int) {_ = preset_save_new(app)},
		enabled = proc(app: ^App, _: int) -> bool {return app.preset_count < MAX_PRESETS},
	},
	.Preset_Save = {
		label = "Save preset changes",
		help = "Stores the brush's changes in the preset it is on.",
		run = proc(app: ^App, _: int) {preset_save(app)},
		enabled = proc(app: ^App, _: int) -> bool {return preset_changed(app) && !preset_read_only(app.brush.preset)},
	},
	.Preset_Revert = {
		label = "Revert preset",
		help = "Puts the brush back to the preset it is on, undoing changes made since it was saved.",
		icon = ui.ICON_UNDO,
		run = proc(app: ^App, _: int) {preset_revert(app)},
		enabled = proc(app: ^App, _: int) -> bool {return preset_changed(app)},
	},
	.Preset_Delete = {
		label = "Delete preset",
		help = "Deletes the preset the brush is on; the brush goes back to its plain self.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {preset_delete(app, app.brush.preset - 1)},
		enabled = proc(app: ^App, _: int) -> bool {return app.brush.preset > 0 && !preset_read_only(app.brush.preset)},
	},
	.Brush_Reset = {
		label = "Reset brush",
		help = "Puts the brush's strength and falloff back to where a fresh install has them.",
		run = proc(app: ^App, _: int) {brush_reset(app)},
		enabled = proc(app: ^App, _: int) -> bool {return brush_reset_needed(app)},
	},
	.Replay_Stroke = {
		label = "Replay stroke",
		help = "Replays the recorded strokes, or else the last stroke, at the pointer.",
		icon = ui.ICON_PLAY,
		run = proc(app: ^App, _: int) {replay_shortcut(app)},
		enabled = proc(app: ^App, _: int) -> bool {return app.tool == .Brush && app.ui.viewport_hovered},
	},
	.Remesh = {
		label = "Remesh",
		help = "Rebuilds the selected object as an even closed mesh of about as many vertices.",
		run = proc(app: ^App, _: int) {
			app.ui.scene_command = {kind = .Remesh, vertices = object_vertex_count(selected_object(app))}
		},
		enabled = has_object,
	},
	.Dyntopo_Toggle = {
		label = "Dynamic topology",
		help = "Turns dynamic topology on or off for the selected object.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Dyntopo, on = !object_dynamic(selected_object(app))}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && len(obj.levels.levels) == 1 && obj.levels.hd.steps == 0
		},
		checked = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && object_dynamic(obj)
		},
	},
	.Subdivide = {
		label = "Subdivide",
		help = "Adds a subdivision level to the selected object.",
		icon = ui.ICON_PLUS,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Subdivide}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && can_subdivide(obj)
		},
	},
	.Level_Up = {
		label = "Higher level",
		help = "Goes up a subdivision level.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Set_Level, level = selected_object(app).levels.current + 1}},
		enabled = has_object,
	},
	.Level_Down = {
		label = "Lower level",
		help = "Goes down a subdivision level.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Set_Level, level = selected_object(app).levels.current - 1}},
		enabled = has_object,
	},
	.Hd_Toggle = {
		label = "Sculpt HD",
		help = "Opens an HD detail window where the pointer is, or leaves HD.",
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil && object_in_hd(obj) {
				app.ui.scene_command = {kind = .Hd_Leave}
			} else {
				app.ui.scene_command = {kind = .Hd_Enter, at = app.ui.viewport_mouse, size = app.ui.viewport_size}
			}
		},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return (obj != nil && object_in_hd(obj)) || app.ui.viewport_hovered
		},
	},
	.Group_Shortcut = {
		label = "Group masked or visible",
		help = "Makes the masked part a polygroup and clears the mask, or else groups what is shown.",
		run = proc(app: ^App, _: int) {group_shortcut(app)},
		enabled = paint_ready,
	},
	.Mask = {
		label = "Mask",
		help = "Changes the selected object's mask as a whole: clear, invert, fill, by cavity, from what is hidden, the inside of a closed outline, or a step of blur, sharpen, grow or shrink.",
		args = len(sculpt.Mask_Command),
		run = proc(app: ^App, arg: int) {mask_command(app, sculpt.Mask_Command(arg))},
	},
	.Mask_By = {
		label = "Mask by",
		help = "Masks the selected object by its shape, the view, its polypaint or its edges, through the Mask section's curve, strength and blur.",
		args = len(sculpt.Mask_By),
		run = proc(app: ^App, arg: int) {mask_by_command(app, sculpt.Mask_By(arg))},
	},
	.Mask_Adjust = {
		label = "Mask adjust",
		help = "Reshapes the selected object's mask as it is through the Mask section's adjust curve, then blurs it, as one step.",
		run = proc(app: ^App, _: int) {mask_adjust_command(app)},
	},
	.Show_All = {
		label = "Show all",
		help = "Shows every hidden part of the object again.",
		icon = ui.ICON_EYE,
		run = proc(app: ^App, _: int) {hide_command(app, .Show_All)},
	},
	.Invert_Hidden = {
		label = "Invert hidden",
		help = "Hides what is shown and shows what is hidden.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {hide_command(app, .Invert)},
	},
	.Hide_Masked = {
		label = "Hide masked",
		help = "Hides the masked part of the object: each triangle masked at least half at every corner.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {hide_command(app, .Masked)},
		enabled = has_mask,
	},
	.Hide_Unmasked = {
		label = "Hide unmasked",
		help = "Hides all but the masked part of the object, to work on that part alone.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {hide_command(app, .Unmasked)},
		enabled = has_mask,
	},
	.Grow_Visible = {
		label = "Grow visibility",
		help = "Shows one ring more of the hidden triangles round what is shown.",
		icon = ui.ICON_EYE,
		run = proc(app: ^App, _: int) {hide_command(app, .Grow)},
		enabled = has_hidden,
	},
	.Shrink_Visible = {
		label = "Shrink visibility",
		help = "Hides one ring of triangles off the edge of what is shown, holes and open borders included.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {hide_command(app, .Shrink)},
		enabled = hide_ready,
	},
	.Grow_All_Visible = {
		label = "Grow all",
		help = "Shows the whole of each piece of the object that has anything shown.",
		icon = ui.ICON_EYE,
		run = proc(app: ^App, _: int) {hide_command(app, .Grow_All)},
		enabled = has_hidden,
	},
	.Outer_Ring = {
		label = "Outer ring",
		help = "Keeps only the ring of triangles along the edge of what is shown.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {hide_command(app, .Outer_Ring)},
		enabled = hide_ready,
	},
	.Grow_To_Groups = {
		label = "Grow to groups",
		help = "Shows the whole of each polygroup that has anything shown.",
		icon = ui.ICON_EYE,
		run = proc(app: ^App, _: int) {hide_command(app, .Grow_Groups)},
		enabled = proc(app: ^App, arg: int) -> bool {
			return has_hidden(app, arg) && sculpt.sculptor_has_groups(object_sculptor(selected_object(app)))
		},
	},
	.Show_Masked = {
		label = "Show masked",
		help = "Shows the hidden triangles masked at least half at every corner, undoing Hide masked.",
		icon = ui.ICON_EYE,
		run = proc(app: ^App, _: int) {hide_command(app, .Show_Masked)},
		enabled = proc(app: ^App, arg: int) -> bool {return has_hidden(app, arg) && has_mask(app, arg)},
	},
	.Store_Selection_Set = {
		label = "Store mask as set",
		help = "Keeps the selected object's mask as a selection set, to bring back later (Object palette > Selection sets).",
		run = proc(app: ^App, _: int) {set_store(app)},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && sculpt.levels_sets_ready(&obj.levels) && object_has_mask(app, obj)
		},
	},
	.Restore_Selection_Set = {
		label = "Restore selection set",
		help = "Makes one of the selected object's selection sets its mask again.",
		args = SET_COMMANDS,
		run = proc(app: ^App, arg: int) {if id := set_id_at(app, arg); id != 0 do set_restore(app, id, .Replace)},
		enabled = proc(app: ^App, arg: int) -> bool {
			obj := selected_object(app)
			return obj != nil && sculpt.levels_sets_ready(&obj.levels) && set_id_at(app, arg) != 0
		},
	},
	.Paint = {
		label = "Paint",
		help = "Fills the selected object with the paint colour, or with a gradient from it at the top to the secondary colour at the bottom as seen, or takes the paint off, skipping what is masked or hidden.",
		args = len(sculpt.Paint_Command),
		run = proc(app: ^App, arg: int) {paint_command(app, sculpt.Paint_Command(arg))},
		enabled = paint_ready,
	},
	.Group = {
		label = "Polygroups",
		help = "Makes polygroups from what is shown, what is masked, the creases, the pieces, the normals or the UV charts, merges similar ones, or clears them.",
		args = len(sculpt.Group_Command),
		run = proc(app: ^App, arg: int) {group_command(app, sculpt.Group_Command(arg))},
		enabled = proc(app: ^App, arg: int) -> bool {
			if !paint_ready(app, arg) do return false
			return sculpt.Group_Command(arg) != .Uv_Charts || sculpt.levels_has_uvs(&selected_object(app).levels)
		},
	},
	.Pick_Group = {
		label = "Pick a group",
		help = "The next press on the selected object picks the polygroup under it, for Scene > Material to give it a material of its own.",
		run = proc(app: ^App, _: int) {group_pick_toggle(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.ui.group_pick},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.voxel == nil && !object_in_hd(obj) && sculpt.sculptor_has_groups(object_sculptor(obj))
		},
	},
	.Delete_Lower_Levels = {
		label = "Delete lower levels",
		help = "Removes the subdivision levels below the current one.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Delete_Lower}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.levels.current > 0
		},
	},
	.Delete_Higher_Levels = {
		label = "Delete higher levels",
		help = "Removes the subdivision levels above the current one.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Delete_Higher}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.levels.current < len(obj.levels.levels) - 1
		},
	},
	.Hd_Divide = {
		label = "Divide HD",
		help = "Adds an HD step above the top level, sculpted a window at a time.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Hd_Steps, level = selected_object(app).levels.hd.steps + 1}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			if obj == nil do return false
			return obj.levels.hd.steps < sculpt.HD_MAX_STEPS && sculpt.levels_hd_stats(&obj.levels).stored_nodes == 0 && !object_dynamic(obj)
		},
	},
	.Hd_Delete = {
		label = "Delete HD",
		help = "Removes the HD steps and their detail.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Hd_Delete}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.levels.hd.steps > 0
		},
	},
	.Hd_Sculpt = {
		label = "Sculpt HD",
		help = "Opens an HD window around the middle of the view.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Hd_Enter, at = app.ui.viewport_size * 0.5, size = app.ui.viewport_size}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.levels.hd.steps > 0 && !object_in_hd(obj)
		},
	},
	.Hd_Leave = {
		label = "Leave HD",
		help = "Stores the HD window's detail and goes back to the top level.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Hd_Leave}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && object_in_hd(obj)
		},
	},
	.Morph_Store = {
		label = "Store morph target",
		help = "Keeps the surface as it is now, for the Morph brush to bring back.",
		run = proc(app: ^App, _: int) {
			stroke_finish(app)
			_ = sculpt.sculptor_morph_store(object_sculptor(selected_object(app)))
		},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && !object_dynamic(obj) && !object_in_hd(obj)
		},
	},
	.Morph_Delete = {
		label = "Delete morph target",
		help = "Forgets the stored morph target of this level.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {sculpt.sculptor_morph_clear(object_sculptor(selected_object(app)))},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && sculpt.sculptor_has_morph(object_sculptor(obj))
		},
	},
	.New_Layer = {
		label = "New layer",
		help = "Adds a sculpt layer on the current level, which the next strokes go into.",
		icon = ui.ICON_PLUS,
		run = proc(app: ^App, _: int) {layer_add(app)},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return layers_allowed(obj) && len(sculpt.sculptor_layers(object_sculptor(obj))) < sculpt.MAX_SCULPT_LAYERS
		},
	},
	.Layer_Edit = {
		label = "Layer",
		help = "Duplicates, inverts, merges down or moves the Layers section's selected layer, or bakes every layer.",
		args = len(Layer_Action),
		run = proc(app: ^App, arg: int) {layer_action(app, Layer_Action(arg))},
		enabled = proc(app: ^App, arg: int) -> bool {return layer_action_ready(app, Layer_Action(arg))},
	},
	.Recall_Earlier = {
		label = "History brush: earlier",
		help = "Moves what the History brush paints back to one step earlier in the History.",
		run = proc(app: ^App, _: int) {
			_, _, shown := recall_now(app)
			recall_move(app, shown + 1, true)
		},
		enabled = proc(app: ^App, _: int) -> bool {
			_, reach, shown := recall_now(app)
			return shown < reach
		},
	},
	.Recall_Later = {
		label = "History brush: later",
		help = "Moves what the History brush paints back to one step later in the History.",
		run = proc(app: ^App, _: int) {
			_, _, shown := recall_now(app)
			recall_move(app, shown - 1, true)
		},
		enabled = proc(app: ^App, _: int) -> bool {
			_, _, shown := recall_now(app)
			return shown > 1
		},
	},
	.Recall_Oldest = {
		label = "History brush: use the oldest",
		help = "Makes the History brush paint back to the oldest step this level's History holds.",
		run = proc(app: ^App, _: int) {
			_, reach, _ := recall_now(app)
			recall_move(app, reach, false)
		},
		enabled = proc(app: ^App, _: int) -> bool {
			back, reach, _ := recall_now(app)
			obj := selected_object(app)
			return reach > 0 && (back != reach || sculpt.sculptor_recall_pinned(object_sculptor(obj)))
		},
	},
	.Smooth_All = {
		label = "Smooth all",
		help = "Smooths the whole object by the Deformation section's steps and strength; masked parts stay.",
		run = proc(app: ^App, _: int) {smooth_command(app, int(app.ui.smooth_steps))},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && !object_dynamic(obj)
		},
	},
	.Deformer = {
		label = "Deformer",
		help = "Opens the Object palette's Deformers section on this deformer: drag Amount to bend, twist or taper the part the mask leaves free, or a lattice point with the Move tool.",
		args = DEFORMERS,
		run = proc(app: ^App, arg: int) {
			tray_open(app, .Deformers)
			deformer_pick(app, arg)
		},
		// Not while an Amount or a lattice point is dragged: either would lose its places.
		enabled = proc(app: ^App, _: int) -> bool {return selected_object(app) != nil && !app.ui.deform.drag.active && app.move.drag.lattice == 0},
	},
	.Deformation = {
		label = "Deformation",
		help = "Opens the Object palette's Deformation section on this one: drag Amount to offset, turn, size, skew, bend, squeeze, roughen, inflate, round, sag, polish or relax the part the mask leaves free.",
		args = len(Reshape_Choice),
		run = proc(app: ^App, arg: int) {
			tray_open(app, .Deform)
			if !app.ui.reshape.drag.active do app.ui.reshape.choice = Reshape_Choice(arg)
		},
		enabled = has_object,
	},
	.Reshape_Repeat = {
		label = "Repeat on the other objects",
		help = "Gives every other shown object the last deformation from the Deformation section, each over the part its mask leaves free, as one undo step.",
		run = proc(app: ^App, _: int) {_ = reshape_repeat(app)},
		enabled = proc(app: ^App, _: int) -> bool {return app.ui.reshape.last.valid && len(app.scene.objects) > 1 && !app.ui.reshape.drag.active},
	},
	.Remesh_To = {
		label = "Remesh to",
		help = "Rebuilds the selected object as an even closed mesh of this many vertices that keeps its shape.",
		args = len(SPHERE_PRESETS),
		run = proc(app: ^App, arg: int) {app.ui.scene_command = {kind = .Remesh, vertices = int(SPHERE_PRESETS[arg].vertices)}},
		enabled = has_object,
	},
	.Decimate_To = {
		label = "Decimate to",
		help = "Keeps the selected object's shape with about this many vertices, dense where the detail is.",
		args = len(SPHERE_PRESETS),
		run = proc(app: ^App, arg: int) {app.ui.scene_command = {kind = .Decimate, vertices = int(SPHERE_PRESETS[arg].vertices)}},
		enabled = has_object,
	},
	.Rebuild = {
		label = "Rebuild selected",
		help = "Rebuilds the selected object as Object > Shape > Rebuild is set: an even remesh, fewer polygons or quads, at its Density.",
		run = proc(app: ^App, _: int) {rebuild_command(app)},
		enabled = has_object,
	},
	.Mirror_Weld = {
		label = "Mirror and weld",
		help = "Replaces one half of the object with a mirror image of the other, across the axis and side the Mirror section picks.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Symmetrize, axis = int(app.ui.mirror_axis), on = !app.ui.mirror_negative}},
		enabled = has_object,
	},
	.Close_Holes = {
		label = "Close holes",
		help = "Caps every hole of the selected object with a surface as even as the one around it, each cap a polygroup of its own; Leave the largest hole keeps its biggest opening.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Repair, repair = .Close_Holes, on = app.ui.holes_leave_largest}},
		enabled = has_mesh_object,
	},
	.Delete_Hidden = {
		label = "Delete hidden",
		help = "Deletes the hidden part of the selected object, leaving holes Close holes can cap.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Repair, repair = .Delete_Hidden}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.voxel == nil && !object_dynamic(obj) && sculpt.sculptor_hidden_count(object_sculptor(obj)) > 0
		},
	},
	.Weld_Points = {
		label = "Weld points",
		help = "Joins vertices of the selected object closer together than the Weld distance, dropping the triangles that collapse.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Repair, repair = .Weld_Points, distance = app.ui.weld_distance}},
		enabled = has_mesh_object,
	},
	.Check_Mesh = {
		label = "Check mesh",
		help = "Counts the selected object's holes, pieces, edges of more than two triangles, triangles facing the wrong way and duplicates, changing nothing.",
		// It changes nothing, so it runs at once rather than as a scene command.
		run = proc(app: ^App, _: int) {if obj := selected_object(app); obj != nil do repair_check(app, obj)},
		enabled = has_mesh_object,
	},
	.Fix_Mesh = {
		label = "Fix mesh",
		help = "Drops the selected object's broken and duplicate triangles and loose vertices, and turns triangles and inside-out pieces to face the right way.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Repair, repair = .Fix_Mesh}},
		enabled = has_mesh_object,
	},
	.Delete_Half = {
		label = "Delete half",
		help = "Deletes the half of the selected object across its own plane on the Modify topology axis that Keep the - side does not keep, leaving it open there.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Repair, repair = .Delete_Half, axis = int(app.ui.mirror_axis), on = !app.ui.mirror_negative}},
		enabled = has_mesh_object,
	},
	.Retopologize = {
		label = "Retopologize",
		help = "Makes a new object of quads with UVs lying on the selected one.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Retopo, vertices = int(app.ui.retopo_quads)}},
		enabled = has_object,
	},
	.Make_Boolean = {
		label = "Make boolean mesh",
		help = "Applies the objects marked Union, Subtract or Intersect to the first unmarked one, as one mesh.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Boolean}},
		enabled = proc(app: ^App, _: int) -> bool {return boolean_base(app) != nil},
	},
	.Live_Boolean = {
		label = "Live boolean",
		help = "Shows the objects marked Union, Subtract or Intersect applied to the first unmarked one as you work, without changing them.",
		run = proc(app: ^App, _: int) {app.ui.boolean.live = !app.ui.boolean.live},
		checked = proc(app: ^App, _: int) -> bool {return app.ui.boolean.live},
	},
	.Extract_Masked = {
		label = "Extract masked",
		help = "Makes a new object: a shell over the masked part.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Extract}},
		enabled = has_object,
	},
	.Adjust_Last = {
		label = "Adjust last operation",
		help = "Opens the settings of the last remesh, decimate, mirror, retopology, extract or smooth all, to run it again from before it, or the amount of the last stroke.",
		run = proc(app: ^App, _: int) {
			if app.kit.adjust_pop do app.kit.adjust_pop = false
			else do adjust_open(app)
		},
		enabled = proc(app: ^App, _: int) -> bool {return adjust_live(app)},
	},
	.Convert_To_Mesh = {
		label = "Convert to mesh",
		help = "Rebuilds the selected voxel object as a mesh of its surface, for the mesh tools; its clay goes, as one undo step.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Voxel_To_Mesh}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.voxel != nil
		},
	},
	.Convert_To_Voxels = {
		label = "Convert to voxels",
		help = "Rebuilds the selected mesh object as clay sculpted as a volume, at the Voxels section's resolution; its levels, mask, layers and paint go, as one undo step.",
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil do app.ui.scene_command = {kind = .Mesh_To_Voxels, voxels = voxel_across_chosen(app, obj)}
		},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.voxel == nil
		},
	},
	.Voxel_Res_Up = {
		label = "Res+",
		help = "Doubles the selected voxel object's voxels along each side, the surface kept where it is, as one undo step.",
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil && obj.voxel != nil do app.ui.scene_command = {kind = .Voxel_Resample, voxels = obj.voxel.resolution * 2}
		},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.voxel != nil && obj.voxel.resolution * 2 <= VOXELS_MAX
		},
	},
	.Voxel_Res_Down = {
		label = "Res−",
		help = "Halves the selected voxel object's voxels along each side, dropping detail finer than the coarser voxel, as one undo step.",
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil && obj.voxel != nil do app.ui.scene_command = {kind = .Voxel_Resample, voxels = obj.voxel.resolution / 2}
		},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && obj.voxel != nil && obj.voxel.resolution / 2 >= VOXELS_MIN
		},
	},
	.Reset_Transform = {
		label = "Reset transform",
		help = "Puts each selected object back at the world's middle, unturned, at scale 1, as one undo step.",
		run = proc(app: ^App, _: int) {transform_reset(app)},
		enabled = has_object,
	},

	.Add_Object = {
		label = "Add object",
		help = "Adds the shape and size picked in the Scene palette's Add object section (with As voxels a voxel sphere of that size), or the content pack's mesh picked there.",
		icon = ui.ICON_PLUS,
		run = proc(app: ^App, _: int) {
			k := &app.kit
			vertices := int(SPHERE_PRESETS[k.add_size].vertices)
			if _, ok := pack_mesh_at(app, k.add_mesh - 1); ok {
				app.ui.scene_command = {kind = .Add, mesh = k.add_mesh}
				return
			}
			app.ui.scene_command = {kind = .Add, vertices = vertices, shape = k.add_shape, voxels = voxel_resolution_for(vertices) if k.add_voxel else 0}
		},
	},
	.Frame_All = {
		label = "Frame all",
		help = "Turns and zooms the view to show every object.",
		icon = ui.ICON_FRAME,
		run = proc(app: ^App, _: int) {frame_all(app)},
		enabled = proc(app: ^App, _: int) -> bool {return len(app.scene.objects) > 0},
	},
	.Hide_Object = {
		label = "Hide object",
		help = "Takes the selected object out of view and out of reach, and selects the next one; its eye in the Scene palette brings it back.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {view_command(app, .Hide)},
		enabled = has_object,
	},
	.Ghost_Object = {
		label = "Make a ghost",
		help = "Dims the selected object and lets presses go through it, to sculpt against it as a reference; its ghost in the Scene palette makes it solid again.",
		icon = ui.ICON_GHOST,
		run = proc(app: ^App, _: int) {view_command(app, .Ghost)},
		enabled = has_object,
	},
	.Show_All_Objects = {
		label = "Show all objects",
		help = "Turns every object's eye back on and Solo off; ghosts stay ghosts.",
		icon = ui.ICON_EYE,
		run = proc(app: ^App, _: int) {view_command(app, .Show_All)},
		enabled = proc(app: ^App, _: int) -> bool {
			off, _ := scene_view_counts(app)
			return off > 0 || app.scene.solo
		},
	},
	.Solo_Object = {
		label = "Solo",
		help = "Shows only the selected object, and whichever is selected next, until Solo is off again; the others keep their eyes as they were.",
		icon = ui.ICON_FOCUS,
		run = proc(app: ^App, _: int) {view_command(app, .Solo)},
		enabled = has_object,
		checked = proc(app: ^App, _: int) -> bool {return app.scene.solo},
	},
	.New_Folder = {
		label = "New folder",
		help = "Puts the selected object in a new folder in the Scene palette, whose eye and ghost then apply to everything in it; one undo step.",
		icon = ui.ICON_FOLDER_PLUS,
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil do app.ui.scene_command = {kind = .Arrange, arrange = .New_Folder, id = obj.id}
		},
		enabled = has_object,
	},
	.Objects_Card = {
		label = "Objects card",
		help = "Opens the card listing every object with its picture, beside the view bar; hold its dots to put it back in the Scene palette.",
		icon = ICON_OBJECTS,
		run = proc(app: ^App, _: int) {objects_card_toggle(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.objects_card},
	},
	.Copy_Object = {
		label = "Copy",
		help = "Copies the selected object, to paste into this scene or another one later, even once the object is deleted.",
		icon = ui.ICON_COPY,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Copy}},
		enabled = has_object,
	},
	.Paste_Object = {
		label = "Paste",
		help = "Adds a copy of the object last copied, below the selected one; one undo step.",
		icon = ui.ICON_PASTE,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Paste}},
		enabled = proc(app: ^App, _: int) -> bool {return len(app.clipboard) > 0},
	},
	.Object_To_Top = {
		label = "Bring to top",
		help = "Moves the selected object to the top of the list, or of its folder; one undo step.",
		icon = ui.ICON_TO_TOP,
		run = proc(app: ^App, _: int) {object_to_end(app, top = true)},
		enabled = has_object,
	},
	.Object_To_Bottom = {
		label = "Send to bottom",
		help = "Moves the selected object to the bottom of the list, or of its folder; one undo step.",
		icon = ui.ICON_TO_BOTTOM,
		run = proc(app: ^App, _: int) {object_to_end(app, top = false)},
		enabled = has_object,
	},
	.Delete_Other_Objects = {
		label = "Delete other",
		help = "Deletes every object but the selected ones; one undo step brings them all back.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Delete_Others}},
		enabled = proc(app: ^App, _: int) -> bool {return selected_object(app) != nil && len(app.scene.objects) > len(selection_ids(app))},
	},
	.Delete_All_Objects = {
		label = "Delete all",
		help = "Deletes every object in the scene; one undo step brings them all back.",
		icon = ui.ICON_TRASH,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Delete_Others, on = true}},
		enabled = proc(app: ^App, _: int) -> bool {return len(app.scene.objects) > 0},
	},
	.All_Lowest_Level = {
		label = "All low",
		help = "Shows every object at its lowest subdivision level, to keep a heavy scene light while posing or arranging it.",
		icon = ui.ICON_CHEVRON_DOWN,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Levels_All}},
		enabled = any_levels,
	},
	.All_Highest_Level = {
		label = "All high",
		help = "Shows every object at its highest subdivision level again.",
		icon = ui.ICON_CHEVRON_UP,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Levels_All, on = true}},
		enabled = any_levels,
	},
	.Visibility_Slot = {
		label = "Objects shown",
		help = "Keeps which objects are shown in the stored visibility chosen, and brings back the ones of another (V1 to V8); the selected object always stays in view.",
		icon = ui.ICON_EYE,
		args = VIS_SLOTS,
		run = proc(app: ^App, arg: int) {app.ui.scene_command = {kind = .View, view = .Visibility_Slot, id = arg + 1}},
		checked = proc(app: ^App, arg: int) -> bool {return app.scene.vis_slot == arg + 1},
	},
	.Split_Object = {
		label = "Split",
		help = "Makes part of the selected object an object of its own: its hidden part, its masked part, each polygroup or each connected piece; one undo step.",
		icon = ICON_SPLIT,
		args = len(Split_Mode),
		run = proc(app: ^App, arg: int) {app.ui.scene_command = {kind = .Split, split = Split_Mode(arg)}},
		// Each mode while there is something to split by (Split to parts finds out on the
		// press, as counting pieces takes a pass over the mesh).
		enabled = proc(app: ^App, arg: int) -> bool {
			obj := selected_object(app)
			if obj == nil || object_dynamic(obj) do return false
			s := object_sculptor(obj)
			switch Split_Mode(arg) {
			case .Hidden: return sculpt.sculptor_hidden_count(s) > 0
			case .Masked: return object_has_mask(app, obj)
			case .Groups: return sculpt.sculptor_has_groups(s)
			case .Parts:
			}
			return true
		},
	},
	.Merge_Down = {
		label = "Merge down",
		help = "Makes the selected object and the one below it in the list one object, each keeping its own polygroups; one undo step.",
		icon = ICON_MERGE,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Merge}},
		enabled = proc(app: ^App, _: int) -> bool {return app.scene.selected >= 0 && app.scene.selected + 1 < len(app.scene.objects)},
	},
	.Merge_Visible = {
		label = "Merge visible",
		help = "Adds one new object made of every shown object, each keeping its own polygroups; the objects stay as they are.",
		icon = ICON_MERGE,
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Merge, on = true}},
		enabled = proc(app: ^App, _: int) -> bool {
			shown := 0
			for obj in app.scene.objects do if object_shown(app, obj) do shown += 1
			return shown >= 2
		},
	},
	.Align_Objects = {
		label = "Align",
		help = "Lines objects up along an axis by their low sides, middles or high sides: the selected ones with the first selected, or one object with everything shown; one undo step.",
		args = 9,
		run = proc(app: ^App, arg: int) {app.ui.scene_command = {kind = .Align, axis = arg / 3, edge = arg % 3}},
		enabled = has_object,
	},
	.Distribute_Objects = {
		label = "Distribute",
		help = "Spaces objects evenly along an axis, by their low sides, middles or high sides: the selected ones when three or more are, or else every shown object; one undo step.",
		args = 9,
		run = proc(app: ^App, arg: int) {app.ui.scene_command = {kind = .Distribute, axis = arg / 3, edge = arg % 3}},
	},
	.Rename_Object = {
		label = "Rename...",
		help = "Gives the selected object a name of your own, shown in the Scene palette and kept in the scene file; one undo step.",
		icon = ui.ICON_PENCIL,
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil {
				w, h := app.kit.ctx.input.window.x, app.kit.ctx.input.window.y
				rename_open(app, obj.id, {w * 0.5 - 140, h * 0.25, 280, 0})
			}
		},
		enabled = has_object,
	},
	.View_Axis = {
		label = "View",
		help = "Looks at the scene straight along an axis.",
		args = len(camera.Axis_View),
		run = proc(app: ^App, arg: int) {camera.orbit_axis_view(&app.camera, camera.Axis_View(arg))},
	},
	.Ortho_Toggle = {
		label = "Orthographic",
		help = "Switches between perspective and parallel projection.",
		run = proc(app: ^App, _: int) {app.camera.ortho = !app.camera.ortho},
		checked = proc(app: ^App, _: int) -> bool {return app.camera.ortho},
	},
	.Focus_Selected = {
		label = "Focus selected",
		help = "Turns and zooms the view to frame the selected object.",
		icon = ui.ICON_FOCUS,
		run = proc(app: ^App, _: int) {focus_selected(app)},
		enabled = has_object,
	},
	.Reset_Camera = {
		label = "Reset camera",
		help = "Goes back to the starting view, keeping the projection and the field of view.",
		icon = ui.ICON_SUN,
		run = proc(app: ^App, _: int) {reset_camera(app)},
	},
	.View_Back = {
		label = "Previous view",
		help = "Goes back to the view before, as the camera last rested; the work stays as it is.",
		run = proc(app: ^App, _: int) {camera_back(app)},
		enabled = proc(app: ^App, _: int) -> bool {return camera_can_back(app)},
	},
	.View_Forward = {
		label = "Next view",
		help = "Goes forward again to the view Previous view left.",
		run = proc(app: ^App, _: int) {camera_forward(app)},
		enabled = proc(app: ^App, _: int) -> bool {return camera_can_forward(app)},
	},
	.Camera_Menu = {
		label = "Camera",
		help = "Opens the camera's menu beside its button: orthographic, the field of view, framing, resetting and stepping between views.",
		icon = ICON_CAMERA,
		run = proc(app: ^App, _: int) {bar_menu_toggle(app, .Camera)},
		checked = proc(app: ^App, _: int) -> bool {return bar_pop_showing(app, .Camera)},
	},
	.Shading_Menu = {
		label = "Shading",
		help = "Opens the shading menu beside its button: wireframe, flat shading, polygroups, the studio render, the looks and the texture views.",
		icon = ICON_SHADING,
		run = proc(app: ^App, _: int) {bar_menu_toggle(app, .Shading)},
		checked = proc(app: ^App, _: int) -> bool {return bar_pop_showing(app, .Shading)},
	},
	.Wireframe = {
		label = "Wireframe",
		help = "Shows the selected object's polyframe: its edges, its polygroups in their colours, or both (a long press on its button picks).",
		run = proc(app: ^App, _: int) {app.wireframe = !app.wireframe},
		checked = proc(app: ^App, _: int) -> bool {return app.wireframe},
	},
	.Flat_Shading = {
		label = "Flat shading",
		help = "Shows the triangles as flat facets.",
		run = proc(app: ^App, _: int) {app.flat = !app.flat},
		checked = proc(app: ^App, _: int) -> bool {return app.flat},
	},
	.Texture_View = {
		label = "Texture view",
		help = "Shows objects with texture maps as clay, with their maps, with their normal map alone, or with a checker laid out by their UVs.",
		args = len(render.Texture_View),
		run = proc(app: ^App, arg: int) {
			// Picking the view on again goes back to clay.
			v := render.Texture_View(arg)
			app.texture_view = .Off if app.texture_view == v else v
		},
		checked = proc(app: ^App, arg: int) -> bool {return app.texture_view == render.Texture_View(arg)},
	},
	.Load_Texture = {
		label = "Load map",
		help = "Loads an image (PNG, JPEG, BMP, TGA or QOI) as the selected object's base colour, ORM or normal map, drawn and exported through its UVs.",
		args = len(render.Texture_Map),
		run = proc(app: ^App, arg: int) {file_dialog(app, TEXTURE_FILE_KINDS[render.Texture_Map(arg)])},
		enabled = proc(app: ^App, _: int) -> bool {return texture_target_check(selected_object(app)) == ""},
	},
	.Remove_Textures = {
		label = "Remove maps",
		help = "Removes the selected object's texture maps (undo brings them back).",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Remove_Textures}},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && object_has_textures(obj)
		},
	},
	.Polygroups = {
		label = "Polygroups",
		help = "Colours each polygroup differently.",
		run = proc(app: ^App, _: int) {app.show_groups = !app.show_groups},
		checked = proc(app: ^App, _: int) -> bool {return app.show_groups},
	},
	.Floor_Grid = {
		label = "Floor grid",
		help = "Draws a grid under the scene, and behind it on the walls you pick, with the axes in their colours.",
		run = proc(app: ^App, _: int) {app.floor.on = !app.floor.on},
		checked = proc(app: ^App, _: int) -> bool {return app.floor.on},
	},
	.Thumbnail = {
		label = "Thumbnail",
		help = "Shows the scene small in a window of its own, as a silhouette or shaded, and flipped if you like: to judge the whole form as if from across the room.",
		icon = rune(0xe3b2), // picture-in-picture
		run = proc(app: ^App, _: int) {app.kit.thumbnail = !app.kit.thumbnail},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.thumbnail},
	},
	.Transparency = {
		label = "Transparency",
		help = "Shows every object but the selected one see-through, so the selected one shows through what stands before it.",
		run = proc(app: ^App, _: int) {app.see_through = !app.see_through},
		checked = proc(app: ^App, _: int) -> bool {return app.see_through},
	},
	.Studio_Render = {
		label = "Studio render",
		help = "Renders the view with soft shadows while it is still.",
		run = proc(app: ^App, _: int) {studio_toggle(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.studio_on},
	},
	.Live_Occlusion = {
		label = "Occlusion while working",
		help = "Darkens creases and contact every frame, sculpting too, with screen-space ambient occlusion.",
		run = proc(app: ^App, _: int) {app.live_ao_on = !app.live_ao_on},
		checked = proc(app: ^App, _: int) -> bool {return app.live_ao_on},
	},
	.Render_Mode = {
		label = "Render mode",
		help = "Path traces the view while it is still: every light with soft shadows, the environment, and light bounced between surfaces.",
		run = proc(app: ^App, _: int) {render_toggle(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.render_on},
	},
	.Pick_Focus = {
		label = "Pick focus",
		help = "Render mode's depth of field focuses where the next press meets the model; dragging moves the focus with the finger.",
		run = proc(app: ^App, _: int) {focus_pick_command(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.ui.focus_armed || app.ui.focus_held},
	},
	.Focus_Pivot = {
		label = "Focus on the pivot",
		help = "Render mode's depth of field focuses on the pivot the view turns about again, instead of a picked point.",
		run = proc(app: ^App, _: int) {app.focus = nil},
		enabled = proc(app: ^App, _: int) -> bool {_, picked := app.focus.?; return picked},
	},
	.Viewport_Look = {
		label = "Look",
		help = "Puts on a look: the material, lights, background, shading style, occlusion and studio render together.",
		args = len(Look_Preset),
		run = proc(app: ^App, arg: int) {look_apply(app, Look_Preset(arg), true)},
		checked = proc(app: ^App, arg: int) -> bool {p, ok := look_current(app).?; return ok && int(p) == arg},
	},
	.Stats = {
		label = "Stats",
		help = "Shows how smoothly the app runs.",
		icon = ui.ICON_ACTIVITY,
		run = proc(app: ^App, _: int) {app.kit.stats = !app.kit.stats},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.stats},
	},
	.Inspector = {
		label = "Palettes",
		help = "Shows or hides the palette tray: the tool's, the object's and the scene's settings, a section at a time.",
		icon = ui.ICON_PANEL,
		// While Settings or Help has its place, it comes back in their place rather than
		// changing unseen.
		run = proc(app: ^App, _: int) {
			k := &app.kit
			if side_panel_open(k) {
				side_panel_close(app)
				k.inspector = true
			} else do k.inspector = !k.inspector
		},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.inspector},
	},
	.Show_Section = {
		label = "Show section",
		help = "Opens the palette tray on this section, switching to the brush for the brush's sections.",
		icon = ui.ICON_PANEL,
		args = TRAY_SECTIONS,
		run = proc(app: ^App, arg: int) {
			sec := Kit_Section(arg)
			if section_palette(sec) == .Tool && app.tool != .Brush do command_run(app, .Tool_Sculpt)
			tray_open(app, sec)
		},
		// The brush's Colour and History brush sections only for the brushes that have them.
		enabled = proc(app: ^App, arg: int) -> bool {return tray_offers(app, Kit_Section(arg))},
	},
	.Settings = {
		label = "Settings...",
		help = "Opens the app's settings.",
		icon = ui.ICON_SETTINGS,
		// Unfolded and in front, wherever it was left, in Help's place (they share it).
		run = proc(app: ^App, _: int) {
			k := &app.kit
			k.settings, k.help, k.macros, k.library = true, false, false, false
			k.windows[.Settings].minimized = false
			window_raise(k, .Settings)
		},
	},
	.Reduce_Motion = {
		label = "Reduce motion",
		help = "Turns off the interface's animations.",
		run = proc(app: ^App, _: int) {app.kit.ctx.reduced_motion = !app.kit.ctx.reduced_motion},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.ctx.reduced_motion},
	},
	.Command_Palette = {
		label = "Search commands",
		help = "Finds any command or setting by typing part of its name.",
		icon = ui.ICON_SEARCH,
		run = proc(app: ^App, _: int) {palette_open(app)},
	},
	.Customise_Bars = {
		label = "Customise bars",
		help = "Turns on customising: tap a ringed button on the right bar, the bottom bar or the dock to put another command there, move it or remove it, or + to add one; Done ends it.",
		icon = ICON_CUSTOMISE,
		run = proc(app: ^App, _: int) {
			k := &app.kit
			k.bars_edit = !k.bars_edit
			// The bars show whole: Settings, over the right bar's side, closes (saving).
			if k.bars_edit && k.settings do settings_close(app)
			kit_floats_close(k)
		},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.bars_edit},
	},
	.Help = {
		label = "Help",
		help = "Lists every shortcut, the mouse and touch controls, and what the app's words mean.",
		icon = ui.ICON_HELP,
		args = len(Help_Tab),
		run = proc(app: ^App, arg: int) {help_open(app, Help_Tab(arg))},
	},
	.Coach_Tips = {
		label = "Show the first-run tips",
		help = "Shows the three tips a first run starts with again: sculpt, turn the view, move and zoom it.",
		icon = ui.ICON_HELP,
		run = proc(app: ^App, _: int) {
			coach_restart(app)
			// The card shows only with nothing open over its place.
			side_panel_close(app)
			if app.kit.palette do palette_close(app)
			app.kit.menu = false
		},
	},
	.Pie = {
		label = "Pie",
		help = "Opens this pie of your own commands at the pointer: tap a slice to run it. Put commands in it from Search.",
		icon = ui.ICON_PIE,
		args = USER_PIES,
		run = pie_toggle_user,
		enabled = proc(app: ^App, _: int) -> bool {return !pie_busy(app)},
	},
	.Brush_Pie = {
		label = "Brush pie",
		help = "Opens the brush pie at the pointer, for a tap on a brush: what Space and a right click open.",
		icon = ui.ICON_PIE,
		run = proc(app: ^App, _: int) {pie_toggle(app, 0)},
		enabled = proc(app: ^App, _: int) -> bool {return !pie_busy(app)},
	},
	.Macro_Record = {
		label = "Record macro",
		help = "Starts keeping the commands you run as a macro, or stops and names it; strokes and view changes are not recorded.",
		icon = ui.ICON_RECORD,
		run = proc(app: ^App, _: int) {macro_record_toggle(app)},
		enabled = proc(app: ^App, _: int) -> bool {return !app.script.running},
		checked = proc(app: ^App, _: int) -> bool {return app.macro.recording},
	},
	.Run_Macro = {
		label = "Run macro",
		help = "Runs a recorded macro's commands on what is selected, each its own undo step.",
		icon = ui.ICON_PLAY,
		args = MACRO_SLOTS,
		run = proc(app: ^App, arg: int) {macro_run(app, arg)},
		enabled = macro_can_run,
	},
	.Macros = {
		label = "Macros...",
		help = "Lists your macros, to run, rename, delete or give a key, runs script files, and lists the script plugins.",
		icon = ui.ICON_FILM,
		run = proc(app: ^App, _: int) {macros_open(app)},
	},
	.Run_Script = {
		label = "Run script...",
		help = "Runs a command script file (.cmd) on what is selected, each command its own undo step.",
		icon = ui.ICON_OPEN,
		run = proc(app: ^App, _: int) {file_dialog(app, .Run_Script)},
		enabled = proc(app: ^App, _: int) -> bool {return script_can_start(app)},
	},
	.Run_Plugin = {
		label = "Run plugin",
		help = "Runs a script plugin's command on what is selected, each command it runs its own undo step.",
		icon = ui.ICON_PLAY,
		args = PLUGIN_COMMANDS_MAX,
		run = proc(app: ^App, arg: int) {plugin_run(app, arg)},
		enabled = plugin_can_run,
	},
	.Reload_Plugins = {
		label = "Reload plugins",
		help = "Reads the script plugins in the plugins folder beside the settings again, after you change one.",
		icon = ui.ICON_REDO,
		run = proc(app: ^App, _: int) {plugins_reload_request(app)},
		enabled = proc(app: ^App, _: int) -> bool {return PLUGINS_AVAILABLE && app.plugins.folder != "" && script_can_start(app)},
	},
	.Library = {
		label = "Library...",
		help = "Lists the content packs installed and your own alphas, to install a pack or remove one.",
		icon = ui.ICON_FOLDER,
		run = proc(app: ^App, _: int) {library_open(app)},
	},
	.Pick_Pack = {
		label = "Install pack...",
		help = "Adds a content pack (.sculptpack) to your library: its alphas, brush presets and meshes join the app under its name.",
		icon = ui.ICON_IMPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Install_Pack)},
		enabled = proc(app: ^App, _: int) -> bool {return app.library.folder != "" && !pack_busy(app)},
	},
	.Save_Pack = {
		label = "Make a pack...",
		help = "Writes your own alphas and brush presets as a content pack (.sculptpack) named after its file, to install on another device or pass on.",
		icon = ui.ICON_EXPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Make_Pack)},
		enabled = proc(app: ^App, _: int) -> bool {return app.library.alphas > 0 || app.preset_count > 0},
	},
	.Pie_Editor = {
		label = "Edit pies",
		help = "Shows the four pies' slots, to empty them or put the defaults back.",
		icon = ui.ICON_PIE,
		run = proc(app: ^App, _: int) {pie_editor_open(app, .None, 0, {})},
	},
}

// The shortcuts (README "Controls"), in the order the keys are read each frame: when
// two commands run in one frame (both setting the next scene command, or Undo before a
// mask change) the later one acts last, as it did before the registry. The keypad's 1,
// 3 and 7 look from the front, right and top, and with Ctrl from the opposite side, as
// in Blender; P is ZBrush's Persp and the keypad's 5 Blender's.
@(rodata)
DEFAULT_BINDINGS := [?]Binding {
	{{sdl.K_Z, {.Ctrl}, true}, .Undo, 0},
	{{sdl.K_Z, {.Ctrl, .Shift}, true}, .Redo, 0},
	{{sdl.K_Y, {.Ctrl}, true}, .Redo, 0},
	{{sdl.K_S, {.Ctrl}, false}, .Save_Scene, 0},
	{{sdl.K_S, {.Ctrl, .Shift}, false}, .Save_Scene_As, 0},
	{{sdl.K_O, {.Ctrl}, false}, .Open_Scene, 0},
	{{sdl.K_F12, {}, false}, .Screenshot, 0},
	{{sdl.K_W, {.Ctrl}, false}, .Group_Shortcut, 0},
	{{sdl.K_W, {.Shift}, false}, .Polygroups, 0},
	{{sdl.K_W, {}, false}, .Tool_Move, 0},
	{{sdl.K_B, {}, false}, .Tool_Sculpt, 0},
	{{sdl.K_C, {}, false}, .Tool_Curve, 0},
	{{sdl.K_I, {}, false}, .Tool_Insert, 0},
	{{sdl.K_1, {}, false}, .Brush, 0},
	{{sdl.K_2, {}, false}, .Brush, 1},
	{{sdl.K_3, {}, false}, .Brush, 2},
	{{sdl.K_4, {}, false}, .Brush, 3},
	{{sdl.K_5, {}, false}, .Brush, 4},
	{{sdl.K_6, {}, false}, .Brush, 5},
	{{sdl.K_7, {}, false}, .Brush, 6},
	{{sdl.K_8, {}, false}, .Brush, 7},
	{{sdl.K_9, {}, false}, .Brush, 8},
	{{sdl.K_0, {}, false}, .Brush, 9},
	{{sdl.K_X, {}, false}, .Symmetry_X, 0},
	{{sdl.K_V, {}, false}, .Swap_Colors, 0},
	{{sdl.K_C, {.Shift}, false}, .Eyedropper, 0},
	{{sdl.K_LEFTBRACKET, {}, true}, .Size_Down, 0},
	{{sdl.K_RIGHTBRACKET, {}, true}, .Size_Up, 0},
	{{sdl.K_LEFTBRACKET, {.Shift}, true}, .Strength_Down, 0},
	{{sdl.K_RIGHTBRACKET, {.Shift}, true}, .Strength_Up, 0},
	{{sdl.K_M, {.Alt}, false}, .Mask, int(sculpt.Mask_Command.Clear)},
	{{sdl.K_R, {.Ctrl}, false}, .Remesh, 0},
	{{sdl.K_T, {.Ctrl}, false}, .Dyntopo_Toggle, 0},
	{{sdl.K_I, {.Ctrl}, false}, .Mask, int(sculpt.Mask_Command.Invert)},
	{{sdl.K_H, {.Ctrl}, false}, .Show_All, 0},
	{{sdl.K_H, {.Ctrl, .Shift}, false}, .Invert_Hidden, 0},
	{{sdl.K_H, {}, false}, .Hide_Object, 0},
	{{sdl.K_H, {.Alt}, false}, .Show_All_Objects, 0},
	{{sdl.K_S, {.Shift}, false}, .Solo_Object, 0},
	{{sdl.K_G, {.Ctrl}, false}, .New_Folder, 0},
	{{sdl.K_F2, {}, false}, .Rename_Object, 0},
	{{sdl.K_C, {.Ctrl}, false}, .Copy_Object, 0},
	{{sdl.K_V, {.Ctrl}, false}, .Paste_Object, 0},
	{{sdl.K_KP_1, {}, false}, .View_Axis, int(camera.Axis_View.Front)},
	{{sdl.K_KP_1, {.Ctrl}, false}, .View_Axis, int(camera.Axis_View.Back)},
	{{sdl.K_KP_3, {}, false}, .View_Axis, int(camera.Axis_View.Right)},
	{{sdl.K_KP_3, {.Ctrl}, false}, .View_Axis, int(camera.Axis_View.Left)},
	{{sdl.K_KP_7, {}, false}, .View_Axis, int(camera.Axis_View.Top)},
	{{sdl.K_KP_7, {.Ctrl}, false}, .View_Axis, int(camera.Axis_View.Bottom)},
	{{sdl.K_P, {}, false}, .Ortho_Toggle, 0},
	{{sdl.K_KP_5, {}, false}, .Ortho_Toggle, 0},
	{{sdl.K_F, {.Shift}, false}, .Wireframe, 0},
	{{sdl.K_P, {.Shift}, false}, .Floor_Grid, 0},
	{{sdl.K_F, {}, false}, .Focus_Selected, 0},
	{{sdl.K_R, {.Shift}, false}, .Studio_Render, 0},
	{{sdl.K_LEFT, {.Alt}, false}, .View_Back, 0},
	{{sdl.K_RIGHT, {.Alt}, false}, .View_Forward, 0},
	{{sdl.K_R, {}, false}, .Replay_Stroke, 0},
	{{sdl.K_G, {.Shift}, false}, .Flat_Shading, 0},
	{{sdl.K_DELETE, {}, false}, .Delete_Object, 0},
	{{sdl.K_A, {}, false}, .Hd_Toggle, 0},
	{{sdl.K_D, {.Ctrl, .Shift}, false}, .Duplicate_Object, 0},
	{{sdl.K_D, {.Ctrl}, false}, .Subdivide, 0},
	{{sdl.K_D, {.Shift}, false}, .Level_Down, 0},
	{{sdl.K_D, {}, false}, .Level_Up, 0},
	{{sdl.K_F11, {}, false}, .Stats, 0},
	{{sdl.K_F1, {}, false}, .Help, 0},
	{{sdl.K_TAB, {}, false}, .Inspector, 0},
	{{sdl.K_K, {.Ctrl}, false}, .Command_Palette, 0},
	{{sdl.K_SLASH, {}, false}, .Command_Palette, 0},
	{{sdl.K_Q, {}, false}, .Pie, 0},
	{{sdl.K_Q, {.Shift}, false}, .Pie, 1},
}

command_enabled :: proc(app: ^App, id: Command_Id, arg := 0) -> bool {
	c := &COMMANDS[id]
	return c.enabled == nil || c.enabled(app, arg)
}

command_checked :: proc(app: ^App, id: Command_Id, arg := 0) -> bool {
	c := &COMMANDS[id]
	return c.checked != nil && c.checked(app, arg)
}

// Runs the command unless it cannot run now; returns whether it ran.
command_run :: proc(app: ^App, id: Command_Id, arg := 0) -> bool {
	c := &COMMANDS[id]
	assert(c.args == 0 ? arg == 0 : arg >= 0 && arg < c.args, "command argument out of range")
	// Ctrl+Alt+click on a control gives the command a key instead of running it.
	if bind_click(app) {
		bind_open(app, id, arg, app.kit.ctx.clicked_rect)
		return false
	}
	if !command_enabled(app, id, arg) do return false
	// A drag held in the inspector ends first, as its own step, so the command acts on
	// what it left (a mask change would otherwise reweigh a deformation mid-drag).
	inspector_drags_end(app)
	before := macro_before(app)
	c.run(app, arg)
	macro_log(app, id, arg, before)
	return true
}

// What menus and search call the command: a brush or a view by its own name.
command_label :: proc(id: Command_Id, arg := 0) -> string {
	#partial switch id {
	case .New_Scene:
		return fmt.tprintf("New scene: %v", NEW_SCENE_SHAPES[arg])
	case .Brush:
		return fmt.tprintf("%s brush", BRUSHES[sculpt.Brush_Kind(arg)].name)
	case .View_Axis:
		return fmt.tprintf("%v view", camera.Axis_View(arg))
	case .Viewport_Look:
		return fmt.tprintf("Look: %s", LOOK_PRESET_NAMES[Look_Preset(arg)])
	case .Mask:
		return MASK_COMMAND_LABELS[sculpt.Mask_Command(arg)]
	case .Mask_By:
		return MASK_BY_NAMES[sculpt.Mask_By(arg)]
	case .Texture_View:
		return TEXTURE_VIEW_NAMES[render.Texture_View(arg)]
	case .Load_Texture:
		return TEXTURE_LOAD_NAMES[render.Texture_Map(arg)]
	case .Layer_Edit:
		return LAYER_ACTION_NAMES[Layer_Action(arg)]
	case .Restore_Selection_Set:
		return fmt.tprintf("Restore selection set %d", arg + 1)
	case .Paint:
		return PAINT_COMMAND_NAMES[sculpt.Paint_Command(arg)]
	case .Group:
		return GROUP_COMMAND_NAMES[sculpt.Group_Command(arg)]
	case .Deformation:
		return RESHAPE_NAMES[Reshape_Choice(arg)]
	case .Deformer:
		// The bare name: a longer label matched typed words fuzzily that it has nothing to
		// do with ("wire" in "Twist (deformer)"); the help line says it is a deformer.
		return deformer_name(arg)
	case .Remesh_To, .Decimate_To:
		return fmt.tprintf("%s to %s vertices", "Remesh" if id == .Remesh_To else "Decimate", SPHERE_PRESETS[arg].label)
	case .Help:
		return fmt.tprintf("Help: %s", HELP_TAB_NAMES[Help_Tab(arg)])
	case .Show_Section:
		sec := Kit_Section(arg)
		return fmt.tprintf("%s: %s", palette_name(section_palette(sec)), tray_section_title(sec))
	case .Gizmo:
		return fmt.tprintf("%v gizmo", gizmo.Mode(arg))
	case .Pie:
		return fmt.tprintf("Pie %d", arg + 1)
	case .Run_Macro:
		return fmt.tprintf("Macro %d", arg + 1)
	case .Run_Plugin:
		return fmt.tprintf("Plugin %d", arg + 1)
	case .Visibility_Slot:
		return fmt.tprintf("Objects shown V%d", arg + 1)
	case .Split_Object:
		return SPLIT_NAMES[Split_Mode(arg)]
	case .Align_Objects, .Distribute_Objects:
		return fmt.tprintf("%s %s %s", COMMANDS[id].label, AXIS_NAMES[arg / 3], EDGE_NAMES[arg % 3])
	}
	return COMMANDS[id].label
}

// The first key chord bound to the command, as menus and tooltips show it, or "".
command_keys :: proc(app: ^App, id: Command_Id, arg := 0) -> string {
	for b in keymap(app) do if b.command == id && b.arg == arg do return chord_text(b.chord)
	return ""
}

// Every key chord bound to the command, in binding order ("Ctrl+Shift+Z, Ctrl+Y"), as
// Help lists them, or "".
command_chords :: proc(app: ^App, id: Command_Id, arg := 0) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k in keymap(app) {
		if k.command != id || k.arg != arg do continue
		if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, chord_text(k.chord))
	}
	return strings.to_string(b)
}

// The touch gesture that runs the command as the Settings and the tool now have them, or
// "": what a tablet without a keyboard has in place of the shortcut (README "Touch and
// pen").
command_gesture :: proc(app: ^App, id: Command_Id, arg := 0) -> string {
	n := &app.nav
	// A finger on empty space belongs to the Curve and Insert tools, so a double tap there
	// frames only with Move or Sculpt, or when one finger always turns the view.
	empty_taps := app.tool == .Move || app.tool == .Brush || n.finger_model == .Orbit
	// The gesture map's first: a gesture the user gave the command comes before its own.
	mapped := gesture_text(app, id, arg)
	builtin := ""
	#partial switch id {
	case .Focus_Selected:
		if n.double_tap && empty_taps do builtin = "Double tap empty space"
	case .Frame_All:
		if n.double_tap && empty_taps do builtin = "Double tap empty space, nothing selected"
	case .Size_Up, .Size_Down:
		builtin = "Three fingers up or down" if n.three_finger else "Long press the bar's Size and drag"
	case .Strength_Up, .Strength_Down:
		builtin = "Long press the bar's Strength and drag"
	case .Mask:
		// The mask taps are the Sculpt tool's (mask_tap_act), and only the modifier
		// buttons' Mask turns them on: with the buttons off there is no way to do them.
		if app.tool != .Brush || app.kit.rail_side == .Off do break
		#partial switch sculpt.Mask_Command(arg) {
		case .Invert:  builtin = "With Mask on, tap off the model"
		case .Blur:    builtin = "With Mask on, tap the mask"
		case .Sharpen: builtin = "With Mask on, tap an unmasked part"
		}
	}
	if mapped == "" do return builtin
	if builtin == "" do return mapped
	return fmt.tprintf("%s; %s", mapped, builtin)
}

// The shortcut and the gesture, as a tooltip shows them beside a control's name:
// "Ctrl+Z · Two-finger tap", either alone, or "". Every control that runs a command
// asks for it just before it is laid out, which is where search's Show where finds the
// control to mark (tray_mark).
command_hint :: proc(app: ^App, id: Command_Id, arg := 0) -> string {
	tray_mark(app, id, arg)
	return hint_join(command_keys(app, id, arg), command_gesture(app, id, arg))
}

// Keys and a gesture as one tooltip hint, either alone, or "".
hint_join :: proc(keys, gesture: string) -> string {
	if keys != "" && gesture != "" do return fmt.tprintf("%s · %s", keys, gesture)
	return keys if keys != "" else gesture
}

// "Ctrl+Shift+S", "Shift+F", "F12", "Num 1": in the temp allocator.
chord_text :: proc(c: Chord) -> string {
	b := strings.builder_make(context.temp_allocator)
	if .Ctrl in c.mods do strings.write_string(&b, "Ctrl+")
	if .Shift in c.mods do strings.write_string(&b, "Shift+")
	if .Alt in c.mods do strings.write_string(&b, "Alt+")
	strings.write_string(&b, key_text(c.key))
	return strings.to_string(b)
}

@(private = "file")
key_text :: proc(key: sdl.Keycode) -> string {
	switch key {
	case sdl.K_A ..= sdl.K_Z:
		return fmt.tprintf("%c", rune(key) - 'a' + 'A')
	case sdl.K_0 ..= sdl.K_9:
		return fmt.tprintf("%c", rune(key))
	case sdl.K_F1 ..= sdl.K_F12:
		return fmt.tprintf("F%d", int(key - sdl.K_F1) + 1)
	case sdl.K_KP_1 ..= sdl.K_KP_9:
		return fmt.tprintf("Num %d", int(key - sdl.K_KP_1) + 1)
	case sdl.K_KP_0:
		return "Num 0"
	case sdl.K_LEFTBRACKET:
		return "["
	case sdl.K_RIGHTBRACKET:
		return "]"
	case sdl.K_DELETE:
		return "Del"
	case sdl.K_TAB:
		return "Tab"
	case sdl.K_ESCAPE:
		return "Esc"
	case sdl.K_SPACE:
		return "Space"
	case sdl.K_SLASH:
		return "/"
	}
	return string(sdl.GetKeyName(key))
}

// Whether the chord's key went down this frame with exactly its modifiers held. Each
// press keeps the modifiers held when it went down, so in a slow frame "B, then Ctrl+Z"
// is still B and Ctrl+Z.
chord_down :: proc(d: ^Device, c: Chord) -> bool {
	for k in d.keys do if k.key == c.key && k.mods == c.mods && (c.repeat || !k.repeat) do return true
	return false
}

// The Ctrl, Shift and Alt among SDL's modifiers (Num Lock, Caps Lock and the system key
// are left out, so they never stop a shortcut).
key_mods :: proc(m: sdl.Keymod) -> (mods: bit_set[Key_Mod;u8]) {
	if m & sdl.KMOD_CTRL != {} do mods += {.Ctrl}
	if m & sdl.KMOD_SHIFT != {} do mods += {.Shift}
	if m & sdl.KMOD_ALT != {} do mods += {.Alt}
	return
}

// Runs every command whose chord went down this frame, in binding order, then lets
// Escape stop a replay (before kit_frame's Escape closes what floats). None of it runs
// while a text field has the keys.
commands_handle_keys :: proc(app: ^App) {
	if typing(app) do return
	for b in keymap(app) {
		if !chord_down(&app.device, b.chord) do continue
		// Home stands in for the panels and the scene: only its own keys and opening a file
		// reach past it.
		if app.kit.home && b.command != .Home && b.command != .Open_Scene do continue
		// The Move tool's key, pressed again with it on, steps the gizmo's mode; the
		// toolbar's button only ever picks the tool.
		if b.command == .Tool_Move && app.tool == .Move {
			gizmo_cycle(app)
			continue
		}
		command_run(app, b.command, b.arg)
	}
	if key_pressed(&app.device, sdl.K_ESCAPE) do replay_stop(app)
}

// A menu row for the command, with its icon, shortcut and state from the table, and a
// tooltip with the shortcut and gesture when it has a gesture; `label` replaces the
// table's where the menu words it its own way. Runs it when picked and returns true then.
command_menu_item :: proc(app: ^App, id: Command_Id, arg := 0, label := "", tone := ui.Tone.Neutral, trailing := false) -> bool {
	c := &COMMANDS[id]
	text := label if label != "" else command_label(id, arg)
	gesture := command_gesture(app, id, arg)
	keys := command_keys(app, id, arg)
	// With the icon where the shortcut goes, the shortcut moves to the tooltip.
	hint := hint_join(keys, gesture) if gesture != "" || (trailing && keys != "") else ""
	if !ui.menu_item(&app.kit.ctx, text, keys, c.icon, command_checked(app, id, arg), tone, command_enabled(app, id, arg), hint = hint, trailing = trailing) do return false
	return command_run(app, id, arg)
}

// A button for the command: its label (or the table's), the shortcut and gesture in its
// tooltip, enabled while the command can run (and `enabled`). Runs it when clicked and
// returns true then. Every panel button that runs a command is one of these, so none
// leaves out its shortcut.
command_button :: proc(app: ^App, id: Command_Id, arg := 0, label := "", variant := ui.Variant.Flat, tone := ui.Tone.Neutral, width: f32 = 0, glyph: rune = 0, enabled := true, icon_only := false) -> bool {
	text := label if label != "" else command_label(id, arg)
	can := enabled && command_enabled(app, id, arg)
	if !ui.button(&app.kit.ctx, text, variant, tone, width, glyph, can, command_hint(app, id, arg), icon_only) do return false
	return command_run(app, id, arg)
}

// What search and menus call each mask command (the Mask section's buttons keep their
// short names).
@(rodata)
MASK_COMMAND_LABELS := [sculpt.Mask_Command]string {
	.Clear   = "Clear mask",
	.Invert  = "Invert mask",
	.Fill    = "Mask all",
	.Cavity  = "Mask cavities",
	.Region  = "Mask region",
	.Hidden  = "Mask hidden",
	.Blur    = "Blur mask",
	.Sharpen = "Sharpen mask",
	.Grow    = "Grow mask",
	.Shrink  = "Shrink mask",
}

// Whether a level can be added: within the memory limit, with no HD step and dynamic
// topology off (the Subdivide button's and Ctrl+D's rule).
can_subdivide :: proc(obj: ^Object) -> bool {
	levels := &obj.levels
	_, _, bytes := sculpt.levels_subdivide_estimate(levels)
	return len(levels.levels) < sculpt.MAX_LEVELS && bytes <= MAX_SUBDIVIDE_BYTES && levels.hd.steps == 0 && !object_dynamic(obj)
}

brush_size_step :: proc(app: ^App, up: bool) {
	app.brush.radius_px = clamp(app.brush.radius_px * (7.0 / 6 if up else 6.0 / 7), MIN_RADIUS_PX, MAX_RADIUS_PX)
}

brush_strength_step :: proc(app: ^App, up: bool) {
	s := brush_strength(app)
	s^ = clamp(s^ + (0.05 if up else -0.05), MIN_STRENGTH, 1)
}

// What Menu > New scene starts from: a sphere, or a starter (geom.starter).
@(rodata)
NEW_SCENE_SHAPES := [?]geom.Primitive{.Sphere, .Head, .Bust, .Figure, .Hand, .Creature}

// A second run within this many seconds of the first goes ahead with a New scene that
// discards work.
NEW_SCENE_ARM_TIME :: 4

// Whether starting a new scene would lose something: any undo step (done or undone), or
// more than one object.
scene_has_work :: proc(app: ^App) -> bool {
	return len(app.history.done) > 0 || len(app.history.undone) > 0 || len(app.scene.objects) > 1
}

// Whether New scene with `arg` was run once and a second run now goes ahead.
new_scene_armed :: proc(app: ^App, arg: int) -> bool {
	k := &app.kit
	return k.new_armed == arg + 1 && k.ctx.time - k.new_armed_at < NEW_SCENE_ARM_TIME
}

// Starts a new scene of NEW_SCENE_SHAPES[arg] at the next frame. With work to lose, the
// first run only arms it and says so, so neither a stray tap nor a palette row wipes
// the scene; a second run of the same shape within NEW_SCENE_ARM_TIME goes ahead.
new_scene_run :: proc(app: ^App, arg: int) {
	k := &app.kit
	if scene_has_work(app) && !new_scene_armed(app, arg) {
		k.new_armed, k.new_armed_at = arg + 1, max(k.ctx.time, 1e-6)
		report(app, nil, {.Warning}, "New scene discards this scene and its History: run New scene: %v again to go ahead", NEW_SCENE_SHAPES[arg])
		return
	}
	k.new_armed = 0
	app.ui.scene_command = {kind = .New, shape = NEW_SCENE_SHAPES[arg], vertices = int(SPHERE_PRESETS[k.add_size].vertices)}
}
