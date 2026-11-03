package main

import "core:fmt"

import "../ui"

// The view rail's cards: any card can stand on the rail (or any dock), as Open card. The
// Library's Cards (the dock ⋯'s Add a button) lists them all.

// The slot that shows panel `p` on a bar: Show panel for a card, Show section for a
// section's palette.
rail_panel_slot :: proc(p: Panel_Kind) -> Bar_Slot {
	if sec, ok := panel_section(p); ok do return {.Show_Section, int(sec)}
	return {.Show_Panel, int(p)}
}

// Where panel `p` stands on the rail; false when it is not there.
rail_panel_at :: proc(app: ^App, p: Panel_Kind) -> (int, bool) {
	s := rail_panel_slot(p)
	for u, i in bar_used(app, .View_Rail) do if u == s do return i, true
	return 0, false
}

// Puts panel `p` at the rail's foot, or takes it off when it is there. Returns whether it
// is on the rail now (false too when the rail is full, which says so).
rail_panel_toggle :: proc(app: ^App, p: Panel_Kind) -> bool {
	if at, on := rail_panel_at(app, p); on {
		bar_remove(app, .View_Rail, at)
		report(app, nil, {}, "%s is off the view rail", panel_kind_title(app, p))
		return false
	}
	n := len(bar_used(app, .View_Rail))
	bar_put(app, {which = .View_Rail, slot = n, add = true}, rail_panel_slot(p))
	_, on := rail_panel_at(app, p)
	return on
}

// The popover's width and padding, as a section's popover has them.
PANEL_POP_W :: KIT_INSPECTOR_W
PANEL_POP_PAD :: 12

// The room a popover's scrolling body has under its head: down to the window's foot, or
// above it up to the top bar where it opens above its button.
panel_pop_room :: proc(app: ^App, root, body: string) -> f32 {
	ctx := &app.kit.ctx
	p := &app.kit.bar_pop
	size, _ := ui.prev_layout(ctx, root)
	area := ui.safe_area(ctx)
	head := size.y - (ui.prev_rect(ctx, body).h if size.y > 0 else 0)
	if p.side == .Above_Center do return max(p.at.y - area.y - kit_top() - 8 - head, 160)
	return max(area.y + area.h - p.at.y - 8 - head, 160)
}

// A popover's head: its title and Close, with room for `extra` buttons the caller adds
// between them (begun here, ended by the caller after them).
panel_pop_head :: proc(app: ^App, name, title: string, extra: int) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.begin(ctx, name, {direction = .Row, center = true})
	room := PANEL_POP_W - 2 * PANEL_POP_PAD - f32(extra + 1) * t.target
	ui.begin(ctx, fmt.tprintf("%s title", name), {direction = .Column, width = room})
	ui.label(ctx, ui.text_fit(ctx, title, t.title_size, room, .Semibold), t.title_size, t.text, .Semibold)
	ui.end(ctx)
}

// Each section's icon, for its button on a bar and its tile in the Library: the
// look's own where a card shows it, else the nearest of the interface's glyphs, so a rail
// of sections is not a column of one panel icon (Lucide's download, camera, video and
// printer by their code points, as the Export card has them).
@(rodata)
SECTION_ICONS := [Kit_Section]rune {
	.Preset      = ICON_BOOKMARK,
	.Stroke      = ui.ICON_SPLINE,
	.Paint_Color = ICON_COLOUR,
	.Recall      = ui.ICON_HISTORY,
	.Falloff     = ICON_CIRCLE_DASHED,
	.Samples     = ui.ICON_ACTIVITY,
	.Alpha       = ui.ICON_IMAGE,
	.Pen         = ui.ICON_PENCIL,
	.Options     = ui.ICON_SETTINGS,
	.Recorder    = ui.ICON_RECORD,
	.Transform   = ui.ICON_MOVE,
	.Levels      = ICON_SUBDIVIDE,
	.Hd          = ui.ICON_ZOOM_IN,
	.Topology    = ICON_DYNTOPO,
	.Mask        = ICON_FILL,
	.Sets        = ui.ICON_TAG,
	.Visibility  = ui.ICON_EYE,
	.Paint       = ui.ICON_PAINTBRUSH,
	.Groups      = ui.ICON_GRID,
	.Morph       = ICON_FLIP_VIEW,
	.Layers      = ICON_LAYERS,
	.Deform      = ui.ICON_WAND,
	.Physics     = rune(0xe1ca), // shirt, as the Cloth brush
	.Deformers   = ui.ICON_ROTATE_3D,
	.Remesh      = ICON_REMESH,
	.Mirror      = ICON_SYMMETRY,
	.Voxels      = ICON_VOXEL_CLAY,
	.Retopo      = ICON_RETOPO,
	.Textures    = ICON_FILL_GRADIENT,
	.Project     = rune(0xe0b6), // download
	.Booleans    = ICON_BOOLEAN,
	.Extract     = ICON_SPLIT,
	.Objects     = ICON_OBJECTS_CARD,
	.Add         = ui.ICON_CIRCLE_PLUS,
	.Look        = ICON_SHADING,
	.Material    = ICON_MATERIAL,
	.Lights      = ui.ICON_SUN,
	.Environment = ui.ICON_IMAGE,
	.Render      = ICON_RENDER_PREVIEW,
	.Lens        = rune(0xe068), // camera
	.Finish      = ICON_SPARKLES,
	.Camera      = ICON_CAMERA,
	.Turntable   = rune(0xe1a5), // video
	.Print       = rune(0xe145), // printer
	.Floor       = ICON_FLOOR,
	.Background  = ui.ICON_FRAME,
	.Frame       = ui.ICON_ACTIVITY,
	.Drawing     = ui.ICON_ACTIVITY,
	.Sculpting   = ui.ICON_ACTIVITY,
	.Stats_Help  = ui.ICON_HELP,
}
