package main

import "core:fmt"

import "../ui"

// The view rail's panels: any card of the stack or section palette can stand on the rail,
// opening beside its button. The rail's + opens the Panels picker, every panel as a tile
// lit where it is on the rail, so a person adds and takes off panels without knowing a
// command's name; More buttons... still offers any command through Search. The cards open
// through Show panel, the section palettes through Show section as before.

// The slot that shows panel `p` on a bar: Show panel for a card, Show section for a
// section's palette.
rail_panel_slot :: proc(p: Panel_Kind) -> Bar_Slot {
	if sec, ok := panel_section(p); ok do return {.Show_Section, int(sec)}
	return {.Show_Panel, int(p)}
}

// The cards whose section's palette a fresh rail holds (Layers, Material) or the View
// island does (Lights): the picker shows the card's tile alone and counts either button as
// the card on the rail, so a fresh rail's Layers lights the Layers tile.
@(rodata)
CARD_SECTIONS := #partial [Panel_Kind]Maybe(Kit_Section) {
	.Layers = .Layers, .Material = .Material, .Lights = .Lights, .Environment = .Environment,
}

// Where panel `p` stands on the rail; false when it is not there.
rail_panel_at :: proc(app: ^App, p: Panel_Kind) -> (int, bool) {
	s := rail_panel_slot(p)
	also := Bar_Slot{.Show_Panel, -1}
	if sec, ok := CARD_SECTIONS[p].?; ok do also = {.Show_Section, int(sec)}
	for u, i in bar_used(app, .View_Rail) do if u == s || u == also do return i, true
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

// The rail's + (outside Arrange, which keeps its own Add a button): opens the Panels
// picker beside it.
rail_panels_button :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	if ui.icon_button(ctx, "Add panels##add panels", ui.ICON_PLUS, bar_pop_showing(app, .Panels), named = "Panels" if rail_labelled(app) else "", width = width) {
		bar_pop_toggle(app, .Panels, ctx.last_rect, bar_side(app, .View_Rail))
	}
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

// A card beside the bar button that opened it (Show panel): its head with Keep in the
// stack and Close, and the card's content scrolling under it.
kit_panel_pop :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.bar_pop
	owner := ui.id_of(ctx, "bar panel")
	if !ui.popover_begin(ctx, "bar panel", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = PANEL_POP_PAD, width = PANEL_POP_W}) do return
	defer ui.popover_end(ctx)
	panel_pop_head(app, "bar panel head", panel_kind_title(app, p.panel), 1)
	s := &k.stack
	kept := s.set && p.panel not_in s.hidden
	// Keep puts the card in the stack's column too, where it stays.
	if ui.icon_button(ctx, "Keep in the panel stack", ui.ICON_PANEL, selected = kept) {
		if !kept do stack_keep(k, p.panel, true)
		k.inspector = true
		stack_reveal_card(app, p.panel)
		p.open = false
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do p.open = false
	ui.end(ctx)
	room := panel_pop_room(app, "bar panel", "bar panel body")
	scroll := kit_scroll_begin(ctx, "bar panel body", &p.scroll, owner, PANEL_POP_W - 2 * PANEL_POP_PAD, room, 6)
	panel_body(app, p.panel, PANEL_POP_W - 2 * PANEL_POP_PAD)
	kit_scroll_end(ctx, scroll)
}

// The Panels picker: every panel as a tile, the stack's cards first and then each
// palette's sections, lit where it is on the rail; a tap puts it on or takes it off.
kit_panels_picker :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.bar_pop
	owner := ui.id_of(ctx, "rail panels")
	if !ui.popover_begin(ctx, "rail panels", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = PANEL_POP_PAD, width = PANEL_POP_W}) do return
	defer ui.popover_end(ctx)
	panel_pop_head(app, "rail panels head", "Panels", 0)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do p.open = false
	ui.end(ctx)
	full := bar_count(app, .View_Rail)^ >= bar_capacity(.View_Rail)
	ui.paragraph(ctx, "The view rail is full: take a panel off first." if full else "Tap a panel to put it on the view rail, again to take it off.")
	inner: f32 = PANEL_POP_W - 2 * PANEL_POP_PAD
	room := panel_pop_room(app, "rail panels", "rail panels body")
	scroll := kit_scroll_begin(ctx, "rail panels body", &p.scroll, owner, inner, room, 6)
	panels_picker_group(app, "CARDS", .Tool, true, inner, full)
	for tab in ([?]Kit_Tab{.Tool, .Object, .Scene}) do panels_picker_group(app, fmt.tprintf("%s PALETTE", palette_caps(tab)), tab, false, inner, full)
	if ui.menu_item(ctx, "More buttons...", glyph = ui.ICON_SEARCH) {
		p.open = false
		bar_choose(app, {which = .View_Rail, slot = len(bar_used(app, .View_Rail)), add = true})
	}
	kit_scroll_end(ctx, scroll)
}

// "BRUSH", "OBJECT", "SCENE": a palette's name as a caption.
@(private = "file")
palette_caps :: proc(tab: Kit_Tab) -> string {
	#partial switch tab {
	case .Tool:   return "BRUSH"
	case .Object: return "OBJECT"
	}
	return "SCENE"
}

// One group of the picker's tiles under its caption, three to a row for room for most
// names: the cards, or the sections of palette `tab`.
@(private = "file")
panels_picker_group :: proc(app: ^App, caption: string, tab: Kit_Tab, cards: bool, inner: f32, full: bool) {
	ctx := &app.kit.ctx
	PER_ROW :: 3
	GAP :: 4
	list: [len(Panel_Kind)]Panel_Kind
	n := 0
	for c in Panel_Kind {
		if cards != (c in STACK_CARDS) do continue
		// The full sections beside a card are its tile's, above.
		if c == .Layer_Settings || c == .Material_Settings || c == .Light_Settings do continue
		if sec, ok := panel_section(c); ok && section_palette(sec) != tab do continue
		list[n] = c
		n += 1
	}
	if n == 0 do return
	ui.caption(ctx, caption)
	tile := (inner - GAP * (PER_ROW - 1)) / PER_ROW
	for row := 0; row < n; row += PER_ROW {
		ui.begin(ctx, fmt.tprintf("panels %s %d", caption, row), {direction = .Row, gap = GAP})
		for c in list[row:min(row + PER_ROW, n)] {
			_, on := rail_panel_at(app, c)
			name := fmt.tprintf("%s##panel %v", panel_kind_title(app, c), c)
			if ui.brush_tile(ctx, name, panel_kind_icon(app, c), on, enabled = on || !full, width = tile) do rail_panel_toggle(app, c)
		}
		ui.end(ctx)
	}
}

// Each section's icon, for its button on a bar and its tile in the Panels picker: the
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
