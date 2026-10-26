package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
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
	New_Scene, // the argument is into NEW_SCENE_SHAPES
	Open_Scene,
	Save_Scene,
	Save_Scene_As,
	Save_Scene_Copy,
	Scene_Versions,
	Open_Last_Autosave,
	Import_Mesh,
	Export_Mesh,
	Screenshot,
	// Edit
	Undo,
	Redo,
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
	Show_All,
	Invert_Hidden,
	Hide_Masked,
	Hide_Unmasked,
	Store_Selection_Set,
	Restore_Selection_Set, // the argument is the set's place, from 0
	Paint, // the argument is the sculpt.Paint_Command
	Group, // the argument is the sculpt.Group_Command
	Delete_Lower_Levels,
	Delete_Higher_Levels,
	Hd_Divide,
	Hd_Delete,
	Hd_Sculpt,
	Hd_Leave,
	Morph_Store,
	Morph_Delete,
	Smooth_All,
	Remesh_To, // the argument is the SPHERE_PRESETS size
	Decimate_To, // ...and here too
	Rebuild,
	Mirror_Weld,
	Retopologize,
	Make_Boolean,
	Extract_Masked,
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
	Rename_Object,
	// The view
	View_Axis, // the argument is the camera.Axis_View
	Ortho_Toggle,
	Focus_Selected,
	Reset_Camera,
	View_Back,
	View_Forward,
	Wireframe,
	Flat_Shading,
	Polygroups,
	Studio_Render,
	// The app
	Stats,
	Inspector,
	Settings,
	Reduce_Motion,
	Command_Palette,
	Help, // the argument is the Help_Tab
	Coach_Tips,
	Pie, // the argument is the user pie, from 0 (user_pies.odin)
	Pie_Editor,
	Brush_Pie,
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

// How many selection sets the commands reach by number, as keys 1 to 9 would.
SET_COMMANDS :: 9

// Whether the selected object can hide by its mask: it has one where it is sculpted, and
// it is neither in HD nor under dynamic topology, where hiding is refused.
has_mask :: proc(app: ^App, _: int) -> bool {
	obj := selected_object(app)
	return obj != nil && !object_in_hd(obj) && !object_dynamic(obj) && object_has_mask(app, obj)
}

@(rodata)
COMMANDS := [Command_Id]Command {
	.None = {},
	.New_Scene = {
		label = "New scene",
		help = "Replaces the scene with this one shape at the Scene tab's Add size; with work to lose, it goes ahead on a second run.",
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
		help = "Adds an OBJ or PLY mesh to the scene.",
		icon = ui.ICON_IMPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Import)},
	},
	.Export_Mesh = {
		label = "Export mesh...",
		help = "Writes the selected object as OBJ or PLY.",
		icon = ui.ICON_EXPORT,
		run = proc(app: ^App, _: int) {file_dialog(app, .Export)},
		enabled = has_object,
	},
	.Screenshot = {
		label = "Save screenshot...",
		help = "Saves the window as a PNG image.",
		icon = ui.ICON_IMAGE,
		run = proc(app: ^App, _: int) {file_dialog(app, .Screenshot)},
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
		enabled = proc(app: ^App, _: int) -> bool {return preset_changed(app)},
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
		enabled = proc(app: ^App, _: int) -> bool {return app.brush.preset > 0},
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
		help = "Changes the selected object's mask as a whole: clear, invert, fill, by cavity, from what is hidden, or a step of blur, sharpen, grow or shrink.",
		args = len(sculpt.Mask_Command),
		run = proc(app: ^App, arg: int) {mask_command(app, sculpt.Mask_Command(arg))},
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
	.Store_Selection_Set = {
		label = "Store mask as set",
		help = "Keeps the selected object's mask as a selection set, to bring back later (Object tab > Select > Selection sets).",
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
		help = "Fills the selected object with the paint colour, or takes the paint off, skipping what is masked or hidden.",
		args = len(sculpt.Paint_Command),
		run = proc(app: ^App, arg: int) {paint_command(app, sculpt.Paint_Command(arg))},
		enabled = paint_ready,
	},
	.Group = {
		label = "Polygroups",
		help = "Makes polygroups from what is shown, what is masked or the creases, or clears them.",
		args = len(sculpt.Group_Command),
		run = proc(app: ^App, arg: int) {group_command(app, sculpt.Group_Command(arg))},
		enabled = paint_ready,
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
	.Smooth_All = {
		label = "Smooth all",
		help = "Smooths the whole object by the Deformation section's steps and strength; masked parts stay.",
		run = proc(app: ^App, _: int) {smooth_command(app, int(app.ui.smooth_steps))},
		enabled = proc(app: ^App, _: int) -> bool {
			obj := selected_object(app)
			return obj != nil && !object_dynamic(obj)
		},
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
	.Extract_Masked = {
		label = "Extract masked",
		help = "Makes a new object: a shell over the masked part.",
		run = proc(app: ^App, _: int) {app.ui.scene_command = {kind = .Extract}},
		enabled = has_object,
	},
	.Adjust_Last = {
		label = "Adjust last operation",
		help = "Opens the settings of the last remesh, decimate, mirror, retopology, extract or smooth all, to run it again from before it.",
		run = proc(app: ^App, _: int) {
			if app.kit.adjust_pop do app.kit.adjust_pop = false
			else do adjust_open(app)
		},
		enabled = proc(app: ^App, _: int) -> bool {return adjust_live(app)},
	},
	.Reset_Transform = {
		label = "Reset transform",
		help = "Puts each selected object back at the world's middle, unturned, at scale 1, as one undo step.",
		run = proc(app: ^App, _: int) {transform_reset(app)},
		enabled = has_object,
	},

	.Add_Object = {
		label = "Add object",
		help = "Adds the shape and size picked in the Scene tab's Add object section.",
		icon = ui.ICON_PLUS,
		run = proc(app: ^App, _: int) {
			k := &app.kit
			app.ui.scene_command = {kind = .Add, vertices = int(SPHERE_PRESETS[k.add_size].vertices), shape = k.add_shape}
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
		help = "Takes the selected object out of view and out of reach, and selects the next one; its eye in the Scene tab brings it back.",
		icon = ui.ICON_EYE_OFF,
		run = proc(app: ^App, _: int) {view_command(app, .Hide)},
		enabled = has_object,
	},
	.Ghost_Object = {
		label = "Make a ghost",
		help = "Dims the selected object and lets presses go through it, to sculpt against it as a reference; its ghost in the Scene tab makes it solid again.",
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
		help = "Puts the selected object in a new folder in the Scene tab, whose eye and ghost then apply to everything in it; one undo step.",
		icon = ui.ICON_FOLDER_PLUS,
		run = proc(app: ^App, _: int) {
			if obj := selected_object(app); obj != nil do app.ui.scene_command = {kind = .Arrange, arrange = .New_Folder, id = obj.id}
		},
		enabled = has_object,
	},
	.Rename_Object = {
		label = "Rename...",
		help = "Gives the selected object a name of your own, shown in the Scene tab and kept in the scene file; one undo step.",
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
		help = "Goes back to the starting view, keeping the projection.",
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
	.Wireframe = {
		label = "Wireframe",
		help = "Shows the mesh's edges over the surface.",
		run = proc(app: ^App, _: int) {app.wireframe = !app.wireframe},
		checked = proc(app: ^App, _: int) -> bool {return app.wireframe},
	},
	.Flat_Shading = {
		label = "Flat shading",
		help = "Shows the triangles as flat facets.",
		run = proc(app: ^App, _: int) {app.flat = !app.flat},
		checked = proc(app: ^App, _: int) -> bool {return app.flat},
	},
	.Polygroups = {
		label = "Polygroups",
		help = "Colours each polygroup differently.",
		run = proc(app: ^App, _: int) {app.show_groups = !app.show_groups},
		checked = proc(app: ^App, _: int) -> bool {return app.show_groups},
	},
	.Studio_Render = {
		label = "Studio render",
		help = "Renders the view with soft shadows while it is still.",
		run = proc(app: ^App, _: int) {studio_toggle(app)},
		checked = proc(app: ^App, _: int) -> bool {return app.studio_on},
	},
	.Stats = {
		label = "Stats",
		help = "Shows how smoothly the app runs.",
		icon = ui.ICON_ACTIVITY,
		run = proc(app: ^App, _: int) {app.kit.stats = !app.kit.stats},
		checked = proc(app: ^App, _: int) -> bool {return app.kit.stats},
	},
	.Inspector = {
		label = "Inspector",
		help = "Shows or hides the panel with the tool's, the object's and the scene's settings.",
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
	.Settings = {
		label = "Settings...",
		help = "Opens the app's settings.",
		icon = ui.ICON_SETTINGS,
		// Unfolded and in front, wherever it was left, in Help's place (they share it).
		run = proc(app: ^App, _: int) {
			k := &app.kit
			k.settings, k.help = true, false
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
	{{sdl.K_KP_1, {}, false}, .View_Axis, int(camera.Axis_View.Front)},
	{{sdl.K_KP_1, {.Ctrl}, false}, .View_Axis, int(camera.Axis_View.Back)},
	{{sdl.K_KP_3, {}, false}, .View_Axis, int(camera.Axis_View.Right)},
	{{sdl.K_KP_3, {.Ctrl}, false}, .View_Axis, int(camera.Axis_View.Left)},
	{{sdl.K_KP_7, {}, false}, .View_Axis, int(camera.Axis_View.Top)},
	{{sdl.K_KP_7, {.Ctrl}, false}, .View_Axis, int(camera.Axis_View.Bottom)},
	{{sdl.K_P, {}, false}, .Ortho_Toggle, 0},
	{{sdl.K_KP_5, {}, false}, .Ortho_Toggle, 0},
	{{sdl.K_F, {.Shift}, false}, .Wireframe, 0},
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
	c.run(app, arg)
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
	case .Mask:
		return MASK_COMMAND_LABELS[sculpt.Mask_Command(arg)]
	case .Restore_Selection_Set:
		return fmt.tprintf("Restore selection set %d", arg + 1)
	case .Paint:
		return "Fill with colour" if sculpt.Paint_Command(arg) == .Fill else "Clear paint"
	case .Group:
		return GROUP_COMMAND_NAMES[sculpt.Group_Command(arg)]
	case .Remesh_To, .Decimate_To:
		return fmt.tprintf("%s to %s vertices", "Remesh" if id == .Remesh_To else "Decimate", SPHERE_PRESETS[arg].label)
	case .Help:
		return fmt.tprintf("Help: %s", HELP_TAB_NAMES[Help_Tab(arg)])
	case .Gizmo:
		return fmt.tprintf("%v gizmo", gizmo.Mode(arg))
	case .Pie:
		return fmt.tprintf("Pie %d", arg + 1)
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
		if n.three_finger do builtin = "Three fingers up or down"
	case .Strength_Up, .Strength_Down:
		if n.three_finger do builtin = "Three fingers sideways"
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
// "Ctrl+Z · Two-finger tap", either alone, or "".
command_hint :: proc(app: ^App, id: Command_Id, arg := 0) -> string {
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
command_menu_item :: proc(app: ^App, id: Command_Id, arg := 0, label := "", tone := ui.Tone.Neutral) -> bool {
	c := &COMMANDS[id]
	text := label if label != "" else command_label(id, arg)
	gesture := command_gesture(app, id, arg)
	hint := hint_join(command_keys(app, id, arg), gesture) if gesture != "" else ""
	if !ui.menu_item(&app.kit.ctx, text, command_keys(app, id, arg), c.icon, command_checked(app, id, arg), tone, command_enabled(app, id, arg), hint = hint) do return false
	return command_run(app, id, arg)
}

// A button for the command: its label (or the table's), the shortcut and gesture in its
// tooltip, enabled while the command can run (and `enabled`). Runs it when clicked and
// returns true then. Every panel button that runs a command is one of these, so none
// leaves out its shortcut.
command_button :: proc(app: ^App, id: Command_Id, arg := 0, label := "", variant := ui.Variant.Flat, tone := ui.Tone.Neutral, width: f32 = 0, glyph: rune = 0, enabled := true) -> bool {
	text := label if label != "" else command_label(id, arg)
	can := enabled && command_enabled(app, id, arg)
	if !ui.button(&app.kit.ctx, text, variant, tone, width, glyph, can, command_hint(app, id, arg)) do return false
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
