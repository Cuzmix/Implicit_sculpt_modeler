package main

import "core:fmt"
import "core:math"

import "../ui"

// The palette tray, on the right where the inspector was: the tool's palette, the
// object's and the scene's, each a list of sections shown one at a time, as ZBrush for
// iPad's Tool palette does. A wide window lists every palette down the tray's left, with
// the open one's sections under it; a narrow one keeps the content's width and puts the
// same list in a select over it. Search's Show where opens the palette holding a
// command and marks its control (tray_show).

// How many sections the tray has: Kit_Section's first ones, before the Stats panel's.
TRAY_SECTIONS :: int(Kit_Section.Background) + 1

// The list's width, the gap after it (where its scroll bar goes), and the narrowest safe
// area with room for it beside the content.
TRAY_NAV_W :: 164
TRAY_NAV_GAP :: 12
TRAY_NAV_MIN_W :: 1180

// How long Show where marks a control, in seconds.
TRAY_MARK_TIME :: 1.8

// A section a palette offers: what it is and what the list calls it.
Tray_Section :: struct {
	section: Kit_Section,
	title:   string,
}

// The sections palette `tab` offers now, in the order listed: only the brush has
// sections on the tool's palette (the other tools' settings fill it), and the brush's
// own Colour and History brush sections only while it paints or recalls.
tray_sections :: proc(app: ^App, tab: Kit_Tab) -> []Tray_Section {
	out := make([dynamic]Tray_Section, 0, len(OBJECT_SECTIONS), context.temp_allocator)
	switch tab {
	case .Tool:
		if app.tool != .Brush do break
		for s in BRUSH_SECTIONS do if s.shown == nil || s.shown(app) do append(&out, Tray_Section{s.section, s.title})
	case .Object:
		for s in OBJECT_SECTIONS do if object_section_offered(app, s.section) do append(&out, Tray_Section{s.section, s.title})
	case .Scene:
		append(&out, Tray_Section{.Objects, "Objects"})
		for s in SCENE_SECTIONS do append(&out, Tray_Section{s.section, s.title})
	}
	return out[:]
}

// What the tray's list calls section `sec`.
tray_section_title :: proc(sec: Kit_Section) -> string {
	if sec == .Objects do return "Objects"
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title
	for s in SCENE_SECTIONS do if s.section == sec do return s.title
	return ""
}

// The section palette `tab` shows: the one last picked there, or its first while that
// one is not offered (Colour, once the brush no longer paints).
tray_section :: proc(app: ^App, tab: Kit_Tab) -> Kit_Section {
	list := tray_sections(app, tab)
	for s in list do if s.section == app.kit.section[tab] do return s.section
	return list[0].section if len(list) > 0 else app.kit.section[tab]
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

// A palette's name in the list and the tray's title: the tool's for the first.
palette_title :: proc(app: ^App, tab: Kit_Tab) -> string {
	switch tab {
	case .Tool:   return kit_tool_name(app.tool)
	case .Object: return "Object"
	case .Scene:  return "Scene"
	}
	return ""
}

@(private = "file")
palette_glyph :: proc(app: ^App, tab: Kit_Tab) -> rune {
	switch tab {
	case .Tool:   return TOOL_ICONS[app.tool]
	case .Object: return ICON_REMESH
	case .Scene:  return ICON_OBJECTS
	}
	return 0
}

// Shows section `sec` of palette `tab` from its top, fading it in when it changes.
tray_pick :: proc(app: ^App, tab: Kit_Tab, sec: Kit_Section) {
	k := &app.kit
	if tab != k.tab || sec != tray_section(app, tab) do k.tab_serial += 1
	k.tab, k.section[tab], k.scroll = tab, sec, 0
}

// Opens the tray on section `sec`, closing Settings or Help, which share its place.
tray_open :: proc(app: ^App, sec: Kit_Section) {
	side_panel_close(app)
	app.kit.inspector, app.kit.list_reveal = true, 3
	tray_pick(app, section_palette(sec), sec)
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
	.Studio_Render         = .Studio,
	.Live_Occlusion        = .Studio,
	.Render_Mode           = .Render,
	.Pick_Focus            = .Lens,
	.Focus_Pivot           = .Lens,
	.Viewport_Look         = .Look,
	.Ortho_Toggle          = .Camera,
	.View_Axis             = .Camera,
	.Focus_Selected        = .Camera,
	.Reset_Camera          = .Camera,
	.Record_Turntable      = .Turntable,
	.Floor_Grid            = .Floor,
	.Screenshot_Transparent = .Background,
}

// Opens the tray where command `id` (with `arg`) has its control and marks the control
// for a moment: on its section with the More options open, the tool switched to the
// brush for the brush's sections. False for a command with no home there.
tray_show :: proc(app: ^App, id: Command_Id, arg := 0) -> bool {
	sec, ok := COMMAND_HOMES[id].?
	if !ok do return false
	k := &app.kit
	if section_palette(sec) == .Tool && app.tool != .Brush do command_run(app, .Tool_Sculpt)
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

// The ring round the control Show where points at, pulsing twice and then fading, with
// the body scrolled to bring it into view as it appears. Called after the content,
// inside its scrolling body.
tray_mark_draw :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if k.pointed.id == .None do return
	age := f32(ctx.time - k.pointed.since)
	if age > TRAY_MARK_TIME {
		k.pointed = {}
		return
	}
	m := ctx.marked
	if !m.found do return
	if age < 0.4 {
		body := k.inspector_body
		if m.rect.y + m.rect.h > body.y + body.h do k.scroll = clamp(k.scroll + m.rect.y + m.rect.h - (body.y + body.h) + 12, 0, k.inspector_limit)
		if m.rect.y < body.y do k.scroll = clamp(k.scroll - (body.y - m.rect.y) - 12, 0, k.inspector_limit)
	}
	pulse := 0.5 + 0.5 * math.cos(age * 2 * math.PI * 2 / (TRAY_MARK_TIME * 0.6))
	fade := clamp((TRAY_MARK_TIME - age) / 0.4, 0, 1)
	r := m.rect
	ui.stroke_rect(ctx, {r.x - 3, r.y - 3, r.w + 6, r.h + 6}, t.radius_medium + 3, ui.color_fade(t.accent, fade * (0.55 + 0.45 * pulse)), 2)
}

// The list beside the content on a wide window: each palette, and under the open one
// its sections; a tap on a palette opens it on the section it last showed.
kit_tray_list :: proc(app: ^App, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	scroll := kit_scroll_begin(ctx, "tray list", &k.list_scroll, ui.id_of(ctx, "inspector"), TRAY_NAV_W, height, 0)
	for tab in Kit_Tab {
		// The open palette is lit itself only when it has no sections to light instead.
		lit := tab == k.tab && len(tray_sections(app, tab)) == 0
		if row := ui.list_row(ctx, fmt.tprintf("%s##palette %v", palette_title(app, tab), tab), selected = lit, glyph = palette_glyph(app, tab)); row.clicked {
			tray_pick(app, tab, tray_section(app, tab))
		}
		if tab != k.tab do continue
		shown := tray_section(app, tab)
		for s in tray_sections(app, tab) {
			row := ui.tree_row(ctx, fmt.tprintf("%s##section", s.title), selected = s.section == shown, depth = 1)
			if row.clicked do tray_pick(app, tab, s.section)
			// A section opened from elsewhere (Show where, a long press on a bar) is
			// scrolled into the list's view.
			if k.list_reveal > 0 && s.section == shown {
				at := scroll.at
				if row.rect.y + row.rect.h > at.y + at.h do k.list_scroll += row.rect.y + row.rect.h - (at.y + at.h)
				if row.rect.y < at.y do k.list_scroll -= at.y - row.rect.y
				k.list_scroll = clamp(k.list_scroll, 0, scroll.limit)
			}
		}
	}
	// The list's height is last frame's, so a palette just opened takes a frame or two to
	// scroll as far as it can.
	if k.list_reveal > 0 do k.list_reveal -= 1
	kit_scroll_end(ctx, scroll)
}

// The same list in a select over the content, on a window too narrow for it beside:
// every palette's sections as "Palette: Section", and a palette without any by name.
kit_tray_select :: proc(app: ^App) {
	k := &app.kit
	names := make([dynamic]string, context.temp_allocator)
	picks := make([dynamic]Tray_Section, context.temp_allocator)
	tabs := make([dynamic]Kit_Tab, context.temp_allocator)
	chosen := 0
	for tab in Kit_Tab {
		list := tray_sections(app, tab)
		if len(list) == 0 {
			if tab == k.tab do chosen = len(names)
			append(&names, palette_title(app, tab))
			append(&picks, Tray_Section{section = k.section[tab]})
			append(&tabs, tab)
			continue
		}
		shown := tray_section(app, tab)
		for s in list {
			if tab == k.tab && s.section == shown do chosen = len(names)
			append(&names, fmt.tprintf("%s: %s", palette_title(app, tab), s.title))
			append(&picks, s)
			append(&tabs, tab)
		}
	}
	if picked := ui.select(&k.ctx, "tray sections", names[:], chosen); picked >= 0 && picked != chosen {
		tray_pick(app, tabs[picked], picks[picked].section)
	}
	ui.spacer(&k.ctx, 4)
}

// A section's name over its content in the tray.
kit_section_title :: proc(ctx: ^ui.Context, title: string) {
	ui.label(ctx, title, ctx.theme.title_size, ctx.theme.text, .Semibold)
}
