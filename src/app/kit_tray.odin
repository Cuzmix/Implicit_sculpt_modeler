package main


import "../ui"

// The sections of the three palettes, the tool's, the object's and the scene's, as ZBrush
// for iPad's Tool palette has them. The tray that showed them one at a time is gone (round
// 3, PR 9): each section is a card of the panel stack (Panel_Kind), which Show section
// brings in (tray_open) and Search's Show where opens on the control it marks (tray_show).
// The names keep "tray" since commands, tests and the skills know them by it.

// How many sections the tray has: Kit_Section's first ones, before the Stats panel's.
TRAY_SECTIONS :: int(Kit_Section.Background) + 1

// The narrowest safe area where the docked stack stands beside the view rather than pops
// over it (stack_narrow).
COLUMNS_MIN_W :: 1180

// What a section is called: its card's title, and its name in Search.
tray_section_title :: proc(sec: Kit_Section) -> string {
	if sec == .Objects do return "Objects"
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title
	for s in SCENE_SECTIONS do if s.section == sec do return s.title
	return ""
}

// The palette that holds section `sec`.
section_palette :: proc(sec: Kit_Section) -> Kit_Tab {
	#partial switch sec {
	case .Preset ..= .Recorder:   return .Tool
	case .Transform ..= .Extract: return .Object
	}
	return .Scene
}

// A palette's name where it stands for every tool's (search, Show where): the brush's,
// whose sections it lists.
palette_name :: proc(tab: Kit_Tab) -> string {
	switch tab {
	case .Tool:   return "Brush"
	case .Object: return "Object"
	case .Scene:  return "Scene"
	}
	return ""
}

// Whether the tray offers section `sec`: the brush's own ones only on the brushes that
// have them (whatever the tool, which Show section switches to the brush).
tray_offers :: proc(app: ^App, sec: Kit_Section) -> bool {
	if section_palette(sec) != .Tool do return int(sec) < TRAY_SECTIONS
	for s in BRUSH_SECTIONS do if s.section == sec do return s.shown == nil || s.shown(app)
	return false
}

// Opens the stack on section `sec`, closing Settings or Help, which share its place: its
// card, or its own palette as the visit (stack_reveal; `exact` as stack_card_of has it).
tray_open :: proc(app: ^App, sec: Kit_Section, exact := false) {
	side_panel_close(app)
	app.kit.inspector = true
	stack_reveal(app, sec, exact)
}

// Where each command's control is in the tray, for search's Show where: the section
// that shows it (with every option, since Show where opens the section's More). Commands
// that are not here have no control there, or only one that comes and goes with the
// brush (the History brush's steps), or live on the bars alone.
@(rodata)
COMMAND_HOMES := #partial [Command_Id]Maybe(Kit_Section) {
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
	.Duplicate_Object      = .Objects,
	.Delete_Object         = .Objects,
	.Add_Object            = .Add,
	.Studio_Render         = .Render,
	.Live_Occlusion        = .Look,
	.Render_Mode           = .Render,
	.Pick_Focus            = .Lens,
	.Place_Light           = .Lights,
	.Focus_Pivot           = .Lens,
	.Finish_Reset          = .Finish,
	.Viewport_Look         = .Look,
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
	tray_open(app, sec, exact = true)
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
