package main


import "../ui"

// The sections of the three palettes, the tool's, the object's and the scene's, as ZBrush
// for iPad's Tool palette has them. The tray that showed them one at a time is gone (round
// 3, PR 9): each section is a card of the panel stack (Panel_Kind), which Open card
// brings in (tray_open) and Search's Show where opens on the control it marks (tray_show).
// The names keep "tray" since commands, tests and the skills know them by it.

// The narrowest safe area where the docked stack stands beside the view rather than pops
// over it (stack_narrow).
COLUMNS_MIN_W :: 1180

// What a section is called: its card's title, and its name in Search.
tray_section_title :: proc(sec: Panel_Kind) -> string {
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title
	for s in SCENE_SECTIONS do if s.section == sec do return s.title
	return ""
}

// The palette that holds section `sec` (Layers' card is the object's, the look's cards the
// scene's).
section_palette :: proc(sec: Panel_Kind) -> Kit_Tab {
	#partial switch sec {
	case .Preset ..= .Recorder:           return .Tool
	case .Transform ..= .Extract, .Layers: return .Object
	}
	return .Scene
}

// Whether the tray offers section `sec`: the brush's own ones only on the brushes that
// have them (whatever the tool, which Open card switches to the brush).
tray_offers :: proc(app: ^App, sec: Panel_Kind) -> bool {
	if !panel_is_section(sec) || section_palette(sec) != .Tool do return true
	for s in BRUSH_SECTIONS do if s.section == sec do return s.shown == nil || s.shown(app)
	return false
}

// Opens the stack on section `sec`, closing Settings or Help, which share its place: its
// card, or its own palette as the visit (stack_reveal).
tray_open :: proc(app: ^App, sec: Panel_Kind) {
	side_panel_close(app)
	app.kit.inspector = true
	stack_reveal(app, sec)
}

// Where each command's control is in the tray, for search's Show where: the section
// that shows it (with every option, since Show where opens the section's More). Commands
// that are not here have no control there, or only one that comes and goes with the
// brush (the History brush's steps), or live on the bars alone.
@(rodata)
COMMAND_HOMES := #partial [Command_Id]Maybe(Panel_Kind) {
	.Front_Only            = .Options,
	.Lock_Plane            = .Options,
	.Connected             = .Options,
	.Preset_Save_New       = .Preset,
	.Brush_Reset           = .Preset,
	.Reset_Transform       = .Transform,
	.Subdivide             = .Levels,
	.Level_Up              = .Levels,
	.Level_Down            = .Levels,
	.Delete_Lower_Levels   = .Levels,
	.Delete_Higher_Levels  = .Levels,
	.Hd_Divide             = .Hd,
	.Detail_Skin           = .Hd,
	.Skin_Apply            = .Hd,
	.Skin_Squeeze          = .Hd,
	.Hd_Delete             = .Hd,
	.Dyntopo_Toggle        = .Topology,
	.Rebuild               = .Remesh,
	.Mirror_Weld           = .Mirror,
	.Close_Holes           = .Mirror,
	.Delete_Hidden         = .Mirror,
	.Weld_Points           = .Mirror,
	.Check_Mesh            = .Mirror,
	.Fix_Mesh              = .Mirror,
	.Delete_Half           = .Mirror,
	.Mask                  = .Mask,
	.Store_Selection_Set   = .Sets,
	.Group                 = .Groups,
	.Polygroups            = .Groups,
	.Show_All              = .Visibility,
	.Invert_Hidden         = .Visibility,
	.Hide_Masked           = .Visibility,
	.Hide_Unmasked         = .Visibility,
	.Grow_Visible          = .Visibility,
	.Shrink_Visible        = .Visibility,
	.Grow_All_Visible      = .Visibility,
	.Outer_Ring            = .Visibility,
	.Grow_To_Groups        = .Visibility,
	.Show_Masked           = .Visibility,
	.New_Layer             = .Layers,
	.Layer_Edit            = .Layers,
	.New_Paint_Layer       = .Layers,
	.Paint_Layer_Edit      = .Layers,
	.Paint                 = .Paint,
	.Morph_Store           = .Morph,
	.Morph_Delete          = .Morph,
	.Smooth_All            = .Deform,
	.Make_Boolean          = .Booleans,
	.Extract_Masked        = .Extract,
	.Convert_To_Mesh       = .Voxels,
	.Convert_To_Voxels     = .Voxels,
	.Voxel_Res_Up          = .Voxels,
	.Voxel_Res_Down        = .Voxels,
	.Duplicate_Object      = .Scene,
	.Delete_Object         = .Scene,
	.Studio_Render         = .Render,
	.Live_Occlusion        = .Look,
	.Render_Mode           = .Render,
	.Pick_Focus            = .Lens,
	.Place_Light           = .Lights,
	.Focus_Pivot           = .Lens,
	.Finish_Reset          = .Finish,
	.Ortho_Toggle          = .Camera,
	.View_Axis             = .Camera,
	.Focus_Selected        = .Camera,
	.Reset_Camera          = .Camera,
	.Record_Turntable      = .Turntable,
	.Export_Print          = .Print,
	.Floor_Grid            = .Floor,
	.Screenshot_Transparent = .Background,
}

// Opens the stack where command `id` (with `arg`) has its control and marks the control
// for a moment: on its section as the tray drew it, with the More options open, the tool
// switched to the brush for the brush's sections. False for a command with no home there.
tray_show :: proc(app: ^App, id: Command_Id, arg := 0) -> bool {
	sec, ok := COMMAND_HOMES[id].?
	if !ok do return false
	k := &app.kit
	if section_palette(sec) == .Tool && app.tool != .Brush do command_run(app, .Tool_Sculpt)
	// The Layers card's tab that holds the command.
	#partial switch id {
	case .New_Layer, .Layer_Edit:            app.ui.layers_paint = false
	case .New_Paint_Layer, .Paint_Layer_Edit: app.ui.layers_paint = true
	}
	tray_open(app, sec)
	k.more[sec] = true
	k.pointed = {id, arg, k.ctx.time}
	return true
}

// Marks the next control as the one Show where points at when it runs command `id`
// with `arg` and the tray's content is being drawn (command_hint calls it).
tray_mark :: proc(app: ^App, id: Command_Id, arg: int) {
	k := &app.kit
	if k.in_tray && k.pointed.id == id && k.pointed.arg == arg do ui.mark_next(&k.ctx)
}
