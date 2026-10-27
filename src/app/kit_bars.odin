package main

import "core:fmt"
import "core:math"
import "core:path/filepath"

import "../sculpt"
import "../ui"

// The toolbars round the window's edges, laid out as a sculpting tablet app's: a strip
// across the top for files and the app, the object's readout under its left end, a
// column at the left for the brush, and two at the right for search, the panels and the
// view. Every button runs a registry command or opens a popover beside it; one marked
// with a small corner triangle opens its settings on a long press (or a right-click).

// The interface's colours (Settings > Interface): Studio's greys and orange, or
// Graphite's cool blue.
Look :: enum u8 {
	Studio,
	Graphite,
}

@(rodata)
LOOK_THEMES := [Look]ui.Theme {
	.Studio   = ui.THEME_STUDIO,
	.Graphite = ui.THEME_DARK,
}

@(rodata)
LOOK_NAMES := [Look]string {
	.Studio   = "Studio",
	.Graphite = "Graphite",
}

// The top bar's height, and how far the side bars sit from the window's edges, in points.
TOP_BAR_H :: 52
BAR_EDGE :: 4

// What a side bar's popover holds: one tray section, a value's tall slider, the
// three symmetry axes, or the save actions.
Bar_Pop_Kind :: enum u8 {
	Section,
	Size,
	Strength,
	Focal,
	Symmetry,
	Save,
}

// A finger's or the pen's long press on the brush bar's size, focal shift or strength,
// still held: dragging up raises the value and down lowers it, without opening anything,
// as the reference app's left bar does. Let go without dragging, it opens the long press's
// section instead (bar_value_button).
Bar_Scrub :: struct {
	active: bool,
	shown:  bool, // the readout beside the button, which fades out once let go
	kind:   Bar_Pop_Kind, // Size, Focal or Strength
	at:     ui.Rect, // the button
	from:   f32, // the pointer's height when the drag began (or the press, before it moved)
	start:  f32, // the value then
	moved:  bool, // past the slop: the drag sets the value
	// The pen hovering on the button and turned about its own length sets the value as a
	// drag would, its roll counting as SCRUB_ROLL points of drag a degree: `rolled` is how
	// far it has turned since it began and `roll_at` when it last turned, so the readout
	// goes once the pen rests or leaves the button (`at`).
	roll:    bool,
	rolled:  f32,
	roll_at: f64,
}

// Points of drag a degree of the pen's roll stands for: half a turn takes strength or
// focal shift across their range, and a quarter turn doubles the size.
SCRUB_ROLL :: f32(SCRUB_STRENGTH_FULL) / 180

// How long the readout stays after the pen last rolled, in seconds.
SCRUB_ROLL_SHOWN :: 0.8

// Points of drag up that double the size, take strength from 0 to 1, and focal shift
// across its whole range.
SCRUB_SIZE_DOUBLE :: 150
SCRUB_STRENGTH_FULL :: 300
SCRUB_FOCAL_FULL :: 300

// The one popover the bars open: one at a time, beside the button that opened it.
Bar_Pop :: struct {
	open:    bool,
	kind:    Bar_Pop_Kind,
	section: Kit_Section,
	at:      ui.Rect,
	side:    ui.Side,
	scroll:  f32,
}

// Opens the bars' popover with `kind` (and `section`) beside `at`, or closes it when it
// already shows that, as a second tap on its button does.
bar_pop_toggle :: proc(app: ^App, kind: Bar_Pop_Kind, at: ui.Rect, side: ui.Side, section := Kit_Section.Stroke) {
	k := &app.kit
	p := &k.bar_pop
	if p.open && p.kind == kind && (kind != .Section || p.section == section) {
		p.open = false
		return
	}
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = kind, section = section, at = at, side = side}
}

// Where the panels under the top bar start, from the top of the safe area.
kit_top :: proc() -> f32 {
	return TOP_BAR_H + 16
}

// How far in from the safe area's left edge the panels start, clear of the brush bar.
kit_left :: proc(app: ^App) -> f32 {
	bar, _ := ui.prev_layout(&app.kit.ctx, "brush bar")
	return BAR_EDGE + bar.x + 8
}

// How far in from the safe area's right edge the panels on the right start, clear of
// the view bars.
kit_right :: proc(app: ^App) -> f32 {
	bar, _ := ui.prev_layout(&app.kit.ctx, "view bar")
	return BAR_EDGE + bar.x + 8
}

// Where a card under the top bar (the first-run tip, the recovery offer) goes: under the
// window's middle where that clears the brush bar on the left and the view bar and the
// inspector on the right, else in the middle of the room between them; lower down where
// it would meet the object's readout. Returns its shift from the middle, its width (at
// most `most`, at least `least`) and its top; false when even that does not fit.
kit_card_place :: proc(app: ^App, most, least: f32) -> (shift, w, top: f32, fits: bool) {
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	left := kit_left(app)
	right := kit_right(app) + (KIT_SETTINGS_W + 8 if side_panel_open(k) else tray_width(app) + 8 if k.inspector else 0)
	room := area.w - left - right
	if room < least do return
	w = min(most, room)
	if (area.w - w) * 0.5 < left || (area.w + w) * 0.5 > area.w - right do shift = left + room * 0.5 - area.w * 0.5
	top = kit_top() + 4
	points := ui.prev_rect(&k.ctx, "points")
	if points.w > 0 && area.w * 0.5 + shift - w * 0.5 < points.x - area.x + points.w + 8 do top = points_bottom(app)
	return shift, w, top, true
}

// How much a panel `width` wide on the right, where it starts, gives up at its foot so as
// to stay clear of the dock (and the action bar over it) where the two would meet.
side_panel_below :: proc(app: ^App, width: f32) -> f32 {
	ctx := &app.kit.ctx
	area := ui.safe_area(ctx)
	dock, _ := ui.prev_layout(ctx, "dock")
	if area.w * 0.5 + dock.x * 0.5 + 8 > area.w - kit_right(app) - width do return dock_stack(app) + 8
	return 0
}

// A bar's button for command `id`: its icon, the command's label as its tooltip (or
// `name`) with its keys, lit while the command is checked, greyed while it cannot run.
@(private = "file")
bar_command :: proc(app: ^App, id: Command_Id, glyph: rune, arg := 0, name := "", corner := false, selected := false) -> bool {
	ctx := &app.kit.ctx
	label := name if name != "" else command_label(id, arg)
	if ui.icon_button(ctx, label, glyph, selected || command_checked(app, id, arg), command_enabled(app, id, arg), command_hint(app, id, arg), corner = corner) {
		command_run(app, id, arg)
		return true
	}
	return false
}

// The strip across the top: the menu and the file actions at the left, the scene's file
// name in the middle, the History, pies, Help and Settings at the right. Returns the
// menu button, which the menu opens under.
kit_top_bar :: proc(app: ^App) -> (menu_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {0, 0}, {direction = .Row, width = area.w, height = TOP_BAR_H, padding = 2, background = .Panel, center = true})
	LEFT :: 4
	RIGHT :: 4
	if ui.icon_button(ctx, "Menu", ui.ICON_MENU, selected = k.menu) {
		k.menu = !k.menu
		k.menu_scroll = 0
	}
	menu_anchor = ctx.last_rect
	// A long press on Save offers the other ways to save, under it.
	_ = bar_command(app, .Save_Scene, ui.ICON_SAVE, corner = true)
	if ui.secondary(ctx) do bar_pop_toggle(app, .Save, ctx.last_rect, .Below)
	_ = bar_command(app, .Import_Mesh, ui.ICON_IMPORT, name = "Import a mesh")
	_ = bar_command(app, .Export_Mesh, ui.ICON_EXPORT, name = "Export the mesh")

	// The middle: the file the scene saves to, with a star while it holds changes the
	// file does not, centred in the room between the two ends.
	middle := area.w - 4 - f32(LEFT + RIGHT) * t.target
	r := ui.place(ctx, {max(middle, 0), TOP_BAR_H - 4})
	name := filepath.base(app.scene_path) if app.scene_path != "" else "Untitled"
	// A scene with no file is marked only once there is work in it to lose.
	unsaved := scene_unsaved(app) && (app.scene_path != "" || scene_has_work(app))
	shown := fmt.tprintf("%s%s", name, "*" if unsaved else "")
	if middle > ui.text_width(ctx, shown, t.text_size) + 16 do ui.text(ctx, shown, r.x + r.w * 0.5, r.y + r.h * 0.5, t.text_size, t.text_secondary, align = .Center)

	if ui.icon_button(ctx, "History", ui.ICON_HISTORY, selected = k.history) do k.history = !k.history
	if bar_command(app, .Pie_Editor, ui.ICON_PIE, name = "Edit pies") do k.pie_editor_at = ctx.last_rect
	_ = bar_command(app, .Help, ui.ICON_HELP, int(Help_Tab.Keys), name = "Help", selected = k.help)
	_ = bar_command(app, .Settings, ui.ICON_SETTINGS, name = "Settings", selected = k.settings)
	ui.end(ctx)
	return
}

// Under the top bar's left end: the selected object, its level, and how many vertices
// it and the whole scene have. A tap shows it in the tray's Object palette; a long press
// (or a right-click) opens its menu under it.
kit_points :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	obj := selected_object(app)
	if obj == nil do return
	total := 0
	for o in app.scene.objects do total += object_vertex_count(o)
	lines := make([dynamic]string, context.temp_allocator)
	head := object_label(obj)
	if n := len(obj.levels.levels); n > 1 do head = fmt.tprintf("%s · Level %d of %d", head, obj.levels.current + 1, n)
	if object_dynamic(obj) do head = fmt.tprintf("%s · Dynamic", head)
	if object_in_hd(obj) do head = fmt.tprintf("%s · HD", head)
	append(&lines, head, fmt.tprintf("Active vertices: %s", count_label(object_vertex_count(obj))))
	if len(app.scene.objects) > 1 do append(&lines, fmt.tprintf("Total vertices: %s", count_label(total)))
	// Beside the brush bar rather than over it when a short window brings the bar up to it.
	x: f32 = BAR_EDGE
	if bar := ui.prev_rect(ctx, "brush bar"); bar.h > 0 && bar.y - ui.safe_area(ctx).y < points_bottom(app) do x = kit_left(app)
	ui.begin_anchored(ctx, "points", .Start, .Start, {x, TOP_BAR_H + 4}, {direction = .Column})
	if ui.readout(ctx, "Object settings", lines[:]) {
		tray_open(app, tray_section(app, .Object))
	}
	if ui.secondary(ctx) do object_menu_open(app, obj.id, ctx.last_rect, .Below)
	ui.end(ctx)
}

// How far down from the safe area's top the readout reaches, with a margin under it.
points_bottom :: proc(app: ^App) -> f32 {
	points, _ := ui.prev_layout(&app.kit.ctx, "points")
	return TOP_BAR_H + 4 + points.y + 8
}

// The column at the left: the brush and what shapes its stroke, then its falloff, size
// and strength, then undo and redo. Returns the Brushes button, which the brush browser
// opens beside.
kit_brush_bar :: proc(app: ^App) -> (brushes_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	// Centred down the left edge, kept between the readout and the dock where it fits;
	// a window too short for that keeps it clear of the dock and puts the readout beside it.
	area := ui.safe_area(ctx)
	bar, _ := ui.prev_layout(ctx, "brush bar")
	low := area.h - ctx.theme.edge - dock_stack(app) - 8 - bar.y
	top := clamp((area.h - bar.y) * 0.5, points_bottom(app), max(low, points_bottom(app)))
	if low < points_bottom(app) do top = max(low, TOP_BAR_H + 4)
	ui.begin_anchored(ctx, "brush bar", .Start, .Start, {BAR_EDGE, top}, {direction = .Column, padding = 3, radius = ctx.theme.radius_large, background = .Panel, center = true})
	// The brush in use; a tap shows every brush and preset beside it, a long press the
	// brush's settings.
	if ui.icon_button(ctx, "Brushes", BRUSHES[app.brush.kind].icon, selected = k.browser && k.browser_at == .Bar, corner = true) {
		was := k.browser && k.browser_at == .Bar
		kit_floats_close(k)
		k.browser, k.browser_at, k.grid_scroll, k.grid_reveal = !was, .Bar, 0, true
	}
	brushes_anchor = ctx.last_rect
	if ui.secondary(ctx) do brush_settings_open(app, app.brush.kind)
	section_button :: proc(app: ^App, name: string, glyph: rune, sec: Kit_Section) {
		ctx := &app.kit.ctx
		p := &app.kit.bar_pop
		if ui.icon_button(ctx, name, glyph, selected = p.open && p.kind == .Section && p.section == sec) do bar_pop_toggle(app, .Section, ctx.last_rect, .Right, sec)
	}
	section_button(app, "Stroke", ICON_STROKE, .Stroke)
	section_button(app, "Alpha", ICON_ALPHA, .Alpha)
	section_button(app, "Material", ICON_MATERIAL, .Material)
	section_button(app, "Colour", ICON_COLOUR, .Paint_Color)
	ui.divider(ctx, 32, across = true)
	// Focal shift, size and strength open their tall sliders; a long press dragged sets
	// them on the spot, and one let go still opens the falloff curve, or the pen's settings
	// that scale size and strength by pressure.
	bar_value_button(app, .Focal, fmt.tprintf("Focal shift %.0f##focal", focal_shift(app)^), ICON_FOCAL, focal_hint(app), .Falloff)
	bar_value_button(app, .Size, fmt.tprintf("Draw size %.0f##size", app.brush.radius_px), ui.ICON_SIZE, slider_hint(app, "S, [ ]", .Size_Up), .Pen)
	bar_value_button(app, .Strength, fmt.tprintf("Strength %.2f##strength", brush_strength(app)^), ui.ICON_STRENGTH, slider_hint(app, "U, Shift+[ ]", .Strength_Up), .Pen)
	bar_scrub_update(app)
	ui.divider(ctx, 32, across = true)
	// A long press on either opens the History panel, to go back or forward many steps.
	undo := fmt.tprintf("Undo %s##undo", history_next_label(app.history.done[:]))
	redo := fmt.tprintf("Redo %s##redo", history_next_label(app.history.undone[:]))
	if ui.icon_button(ctx, undo, ui.ICON_UNDO, enabled = command_enabled(app, .Undo), keys = command_hint(app, .Undo)) do command_run(app, .Undo)
	if ui.secondary(ctx) do k.history = true
	if ui.icon_button(ctx, redo, ui.ICON_REDO, enabled = command_enabled(app, .Redo), keys = command_hint(app, .Redo)) do command_run(app, .Redo)
	if ui.secondary(ctx) do k.history = true
	ui.end(ctx)
	return
}

// A brush bar button for a value (Size, Focal or Strength): a tap opens its tall slider
// beside it; a finger's or the pen's long press starts a Bar_Scrub, and the mouse's right
// click, which has no drag to follow, opens section `still` as a long press let go does.
@(private = "file")
bar_value_button :: proc(app: ^App, kind: Bar_Pop_Kind, name: string, glyph: rune, keys: string, still: Kit_Section) {
	k := &app.kit
	ctx := &k.ctx
	pop := &k.bar_pop
	if ui.icon_button(ctx, name, glyph, selected = pop.open && pop.kind == kind || k.bar_scrub.active && k.bar_scrub.kind == kind, keys = keys, corner = true) do bar_pop_toggle(app, kind, ctx.last_rect, .Right)
	bar_roll(app, kind)
	if !ui.secondary(ctx) do return
	in_ := ctx.input
	if in_.pointer == .Mouse || .Left not_in in_.down {
		bar_pop_toggle(app, .Section, ctx.last_rect, .Right, still)
		return
	}
	kit_floats_close(k)
	k.bar_scrub = {active = true, shown = true, kind = kind, at = ctx.last_rect, from = in_.mouse.y, start = bar_value(app, kind)^}
}

// The pen hovering on the button just drawn and turned about its own length sets its value,
// as dragging it after a long press does, and shows the same readout.
@(private = "file")
bar_roll :: proc(app: ^App, kind: Bar_Pop_Kind) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.bar_scrub
	in_ := ctx.input
	// The button's id carries its value, so it is found by where it is.
	if app.pen_roll == 0 || ctx.hot != ctx.last_id || in_.pointer != .Pen || in_.down != {} || s.active do return
	if !s.roll || s.kind != kind {
		kit_floats_close(k)
		s^ = {shown = true, kind = kind, start = bar_value(app, kind)^, roll = true}
	}
	s.at = ctx.last_rect
	s.rolled += app.pen_roll
	s.roll_at = ctx.time
	bar_value(app, kind)^ = bar_value_dragged(kind, s.start, s.rolled * SCRUB_ROLL)
}

// What a bar value that was `start` becomes dragged `up` points.
@(private = "file")
bar_value_dragged :: proc(kind: Bar_Pop_Kind, start, up: f32) -> f32 {
	#partial switch kind {
	case .Size:  return clamp(start * math.pow(2, up / SCRUB_SIZE_DOUBLE), MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Focal: return math.round(clamp(start + up * f32(sculpt.FOCAL_MAX - sculpt.FOCAL_MIN) / SCRUB_FOCAL_FULL, sculpt.FOCAL_MIN, sculpt.FOCAL_MAX))
	}
	return clamp(start + up / SCRUB_STRENGTH_FULL, MIN_STRENGTH, 1)
}

// The value a bar button sets.
@(private = "file")
bar_value :: proc(app: ^App, kind: Bar_Pop_Kind) -> ^f32 {
	#partial switch kind {
	case .Size:  return &app.brush.radius_px
	case .Focal: return focal_shift(app)
	}
	return brush_strength(app)
}

// Follows a Bar_Scrub while it is held, and ends it when it is let go: dragged, the value
// stays where it was left; never dragged, the long press's section opens.
@(private = "file")
bar_scrub_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.bar_scrub
	if s.roll && (ctx.time - s.roll_at > SCRUB_ROLL_SHOWN || !ctx.input.mouse_valid || !ui.rect_contains(s.at, ctx.input.mouse)) {
		s.roll, s.shown = false, false
	}
	if !s.active do return
	in_ := ctx.input
	if in_.cancel {
		// The system or a palm took the touch back: as a cancelled press does nothing, the
		// value goes back to where it was.
		s.active, s.shown = false, false
		bar_value(app, s.kind)^ = s.start
		return
	}
	if .Left not_in in_.down {
		s.active, s.shown = false, false
		if !s.moved do bar_pop_toggle(app, .Section, s.at, .Right, .Falloff if s.kind == .Focal else .Pen)
		return
	}
	up := s.from - in_.mouse.y
	if !s.moved {
		if abs(up) <= ctx.theme.slop do return
		// From where the pointer is now, so the value does not jump by the slop.
		s.moved, s.from, up = true, in_.mouse.y, 0
	}
	bar_value(app, s.kind)^ = bar_value_dragged(s.kind, s.start, up)
}

// The readout beside the button while a Bar_Scrub runs: the value's name, its number and
// a gauge of where it sits in its range.
kit_bar_scrub :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.bar_scrub
	if !ui.popover_begin(ctx, "bar scrub", &s.shown, s.at, .Right, {direction = .Column, gap = 2, padding = 10, width = 132}) do return
	defer ui.popover_end(ctx)
	v := bar_value(app, s.kind)^
	name, shown: string
	fraction: f32
	#partial switch s.kind {
	case .Size:
		name, shown = "DRAW SIZE", fmt.tprintf("%.0f", v)
		fraction = ui.slider_fraction(v, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic)
	case .Focal:
		name, shown = "FOCAL SHIFT", fmt.tprintf("%.0f", v)
		fraction = ui.slider_fraction(v, sculpt.FOCAL_MIN, sculpt.FOCAL_MAX, .Linear)
	case:
		name, shown = "STRENGTH", fmt.tprintf("%.2f", v)
		fraction = ui.slider_fraction(v, MIN_STRENGTH, 1, .Linear)
	}
	ui.caption(ctx, name)
	ui.label(ctx, shown, t.title_size, t.text, .Semibold)
	ui.gauge(ctx, fraction)
	ui.label(ctx, "Roll the pen" if s.roll else "Drag up or down", t.small_size, t.text_secondary)
}

// The two columns at the right, under the navigation head: search, the palette tray and
// the objects; then the view: studio render, orthographic, symmetry, framing, wireframe,
// ghost and solo. Returns the Search button and the view menu's anchor (a long press on
// Orthographic or Wireframe).
kit_view_bar :: proc(app: ^App) -> (search_anchor, view_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ui.begin_anchored(ctx, "view bar", .End, .Start, {BAR_EDGE, nav_head_bottom()}, {direction = .Column, gap = 12})
	column := ui.Box{direction = .Column, padding = 3, radius = t.radius_large, background = .Panel, center = true}
	ui.begin(ctx, "panel column", column)
	if ui.icon_button(ctx, "Search commands", ui.ICON_SEARCH, selected = k.palette, keys = command_hint(app, .Command_Palette)) {
		if k.palette do palette_close(app)
		else do palette_open(app)
	}
	search_anchor = ctx.last_rect
	_ = bar_command(app, .Inspector, ui.ICON_PANEL, selected = k.inspector && !side_panel_open(k))
	// Objects: the Objects card beside the bar; a second tap puts it away.
	_ = bar_command(app, .Objects_Card, ICON_OBJECTS, name = "Objects")
	ui.end(ctx)

	ui.begin(ctx, "view column", column)
	_ = bar_command(app, .Studio_Render, ui.ICON_SUN, corner = true)
	if ui.secondary(ctx) do bar_pop_toggle(app, .Section, ctx.last_rect, .Left, .Studio)
	_ = bar_command(app, .Ortho_Toggle, ICON_ORTHO, corner = true)
	if ui.secondary(ctx) {
		kit_floats_close(k)
		k.view_menu, k.view_at = true, ctx.last_rect
	}
	sym := &app.brush.symmetry
	_ = bar_command(app, .Symmetry_X, ICON_SYMMETRY, selected = sym^ != {}, corner = true)
	if ui.secondary(ctx) do bar_pop_toggle(app, .Symmetry, ctx.last_rect, .Left)
	_ = bar_command(app, .Focus_Selected, ui.ICON_FRAME)
	_ = bar_command(app, .Wireframe, ICON_WIREFRAME, corner = true)
	if ui.secondary(ctx) {
		kit_floats_close(k)
		k.view_menu, k.view_at = true, ctx.last_rect
	}
	_ = bar_command(app, .Ghost_Object, ui.ICON_GHOST)
	_ = bar_command(app, .Solo_Object, ICON_SOLO)
	ui.end(ctx)
	ui.end(ctx)
	view_anchor = k.view_at
	return
}

// The bar at the bottom middle: a page of the brush dock and All brushes, then the gizmo
// (the Move tool) and the mesh tools: Remesh, Dynamic topology, Retopologize, Subdivide and
// Live boolean. A long press (or a right-click) on a slot changes what it holds; on a tool,
// it opens the tool's settings over it. The dots under the bar pick the dock's page.
// Returns All brushes, which the brush browser opens over.
kit_bottom_bar :: proc(app: ^App) -> (browser_anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	first, count := dock_page_slots(app)
	// The dots sit in the window's edge margin, the bar just above them.
	pages := dock_pages(app)
	ui.begin_anchored(ctx, "dock pages", .Center, .End, {0, max(t.edge - 8, 2)}, {direction = .Row})
	if page := ui.page_dots(ctx, "Dock page", pages, k.dock_page); page >= 0 do k.dock_page = page
	ui.end(ctx)
	ui.begin_anchored(ctx, "dock", .Center, .End, {0, t.edge + DOCK_LIFT}, {direction = .Row, gap = 0, padding = 4, radius = t.radius_large + 4, background = .Panel, center = true})
	// Each slot's tile has an id of its own: a brush or preset may sit in two slots.
	for s, i in k.dock[first:][:count] {
		slot := first + i
		hint := command_hint(app, .Brush, int(s.kind)) if s.preset == 0 else ""
		if ui.brush_tile(ctx, fmt.tprintf("%s##slot %d", dock_slot_label(app, s), slot), BRUSHES[s.kind].icon, dock_slot_on(app, s), hint) do dock_slot_pick(app, s)
		if ui.secondary(ctx) do dock_menu_open(app, slot, ctx.last_rect)
	}
	if ui.icon_button(ctx, "All brushes", ui.ICON_GRID, selected = k.browser && k.browser_at == .Dock || (!dock_has_brush(app) && app.tool == .Brush), size = 58) {
		was := k.browser
		kit_floats_close(k)
		k.browser, k.browser_at, k.grid_scroll, k.grid_reveal = !was, .Dock, 0, true
	}
	browser_anchor = ctx.last_rect
	ui.divider(ctx, 32)
	if ui.icon_button(ctx, "Gizmo", ICON_GIZMO, selected = app.tool == .Move, keys = command_hint(app, .Tool_Move), size = MESH_TOOL, corner = true) do command_run(app, .Tool_Move)
	if ui.secondary(ctx) do tool_settings_open(app, .Move)
	ui.divider(ctx, 32)
	mesh_tool(app, .Remesh, ICON_REMESH, .Remesh)
	mesh_tool(app, .Dyntopo_Toggle, ICON_DYNTOPO, .Topology)
	mesh_tool(app, .Retopologize, ICON_RETOPO, .Retopo, opens = true)
	mesh_tool(app, .Subdivide, ICON_SUBDIVIDE, .Levels)
	mesh_tool(app, .Live_Boolean, ICON_BOOLEAN, .Booleans)
	ui.end(ctx)
	return
}

// The bottom bar's tool buttons' size, the touch target, which keeps the bar narrow enough
// to leave the inspector beside it in a 1600-point window; and how far above the edge's
// margin the bar sits, for the page dots under it.
MESH_TOOL :: 48
DOCK_LIFT :: 12

// A mesh tool's button on the bottom bar: a tap runs `id`, or with `opens` set opens
// section `sec` over the button, as a long press (or a right-click) always does.
@(private = "file")
mesh_tool :: proc(app: ^App, id: Command_Id, glyph: rune, sec: Kit_Section, opens := false) {
	ctx := &app.kit.ctx
	p := &app.kit.bar_pop
	open := p.open && p.kind == .Section && p.section == sec
	enabled := opens || command_enabled(app, id)
	if ui.icon_button(ctx, command_label(id), glyph, selected = open || command_checked(app, id), enabled = enabled, keys = command_hint(app, id), size = MESH_TOOL, corner = true) {
		if opens do bar_pop_toggle(app, .Section, ctx.last_rect, .Above_Center, sec)
		else do command_run(app, id)
	}
	// A disabled button takes no press, so it has no long press either.
	if enabled && ui.secondary(ctx) do bar_pop_toggle(app, .Section, ctx.last_rect, .Above_Center, sec)
}

// The bars' popover (Bar_Pop), beside the button that opened it.
kit_bar_popover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p := &k.bar_pop
	switch p.kind {
	case .Size, .Strength, .Focal:
		if !ui.popover_begin(ctx, "bar slider", &p.open, p.at, p.side, {direction = .Column, padding = 6, center = true}) do return
		defer ui.popover_end(ctx)
		// A long press (or a right-click) on either puts it back to where a new brush starts.
		track := slider_track(app)
		if p.kind == .Size {
			_ = ui.vslider(ctx, "Brush size", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f", app.brush.radius_px), ui.ICON_SIZE, slider_hint(app, "S, [ ]", .Size_Up), track, DEFAULT_RADIUS_PX)
		} else if p.kind == .Focal {
			focal := focal_shift(app)
			if ui.vslider(ctx, "Focal shift", focal, sculpt.FOCAL_MIN, sculpt.FOCAL_MAX, .Linear, fmt.tprintf("%.0f", focal^), ICON_FOCAL, focal_hint(app), track, 0) do focal^ = math.round(focal^)
		} else {
			strength := brush_strength(app)
			_ = ui.vslider(ctx, "Brush strength", strength, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", strength^), ui.ICON_STRENGTH, slider_hint(app, "U, Shift+[ ]", .Strength_Up), track, BRUSHES[app.brush.kind].strength)
		}
	case .Symmetry:
		if !ui.popover_begin(ctx, "bar symmetry", &p.open, p.at, p.side, {direction = .Column, gap = 4, padding = 10}) do return
		defer ui.popover_end(ctx)
		ui.caption(ctx, "SYMMETRY")
		ui.begin(ctx, "symmetry axes", {direction = .Row, gap = 4})
		for axis in sculpt.Axis {
			name := fmt.tprint(axis)
			tip := fmt.tprintf("Symmetry across %s", name)
			if ui.toggle_button(ctx, name, axis in app.brush.symmetry, 48, command_hint(app, .Symmetry_X) if axis == .X else "", tip) do app.brush.symmetry ~= {axis}
		}
		ui.end(ctx)
	case .Save:
		if !ui.popover_begin(ctx, "bar save", &p.open, p.at, p.side, {direction = .Column, padding = 6, width = 268}) do return
		defer ui.popover_end(ctx)
		for id in ([?]Command_Id{.Save_Scene_As, .Save_Scene_Copy, .Scene_Versions, .Open_Last_Autosave}) {
			if command_menu_item(app, id) do p.open = false
		}
	case .Section:
		WIDTH :: KIT_INSPECTOR_W
		PADDING :: 12
		owner := ui.id_of(ctx, "bar section")
		size, _ := ui.prev_layout(ctx, "bar section")
		if !ui.popover_begin(ctx, "bar section", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = PADDING, width = WIDTH}) do return
		defer ui.popover_end(ctx)
		title, draw, obj_draw, found := bar_section(app, p.section)
		ui.begin(ctx, "bar section head", {direction = .Row, center = true})
		ui.begin(ctx, "bar section title", {direction = .Column, width = WIDTH - 2 * PADDING - t.target})
		ui.label(ctx, title, t.title_size, t.text, .Semibold)
		ui.end(ctx)
		if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do p.open = false
		ui.end(ctx)
		// The body scrolls in the room the window leaves under the popover's top, or over
		// the bottom bar up to the top bar.
		area := ui.safe_area(ctx)
		head := size.y - (ui.prev_rect(ctx, "bar section body").h if size.y > 0 else 0)
		room := max(area.y + area.h - p.at.y - 8 - head, 160)
		if p.side == .Above_Center do room = max(p.at.y - area.y - kit_top() - 8 - head, 160)
		scroll := kit_scroll_begin(ctx, "bar section body", &p.scroll, owner, WIDTH - 2 * PADDING, room, 6)
		obj := selected_object(app)
		switch {
		case !found:
			ui.paragraph(ctx, "Nothing to show here.")
		case obj_draw != nil && obj == nil:
			ui.paragraph(ctx, "Add or select an object first.")
		case obj_draw != nil:
			obj_draw(app, obj)
		case:
			draw(app)
		}
		kit_scroll_end(ctx, scroll)
	}
}

// Section `sec` of the tray, wherever its palette lists it: its title and what draws it
// (for the Object palette's, with the object).
@(private = "file")
bar_section :: proc(app: ^App, sec: Kit_Section) -> (title: string, draw: proc(app: ^App), obj_draw: proc(app: ^App, obj: ^Object), found: bool) {
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title, s.draw, nil, true
	for s in SCENE_SECTIONS do if s.section == sec do return s.title, s.draw, nil, true
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title, nil, s.draw, true
	return
}

// The bars' icons that the kit does not name, in the Lucide font.
ICON_STROKE :: rune(0xe547) // waypoints
ICON_ALPHA :: rune(0xe3bf) // stamp
ICON_MATERIAL :: rune(0xe5a2) // eclipse: a lit sphere
ICON_COLOUR :: rune(0xe1dd) // palette
ICON_FOCAL :: rune(0xe349) // circle-dot: the cursor's ring round its inner one
ICON_OBJECTS :: rune(0xe104) // layers
ICON_SPLIT :: rune(0xe445) // split
ICON_MERGE :: rune(0xe444) // merge
ICON_ORTHO :: rune(0xe529) // cuboid
ICON_SYMMETRY :: rune(0xe362) // flip-horizontal-2
ICON_WIREFRAME :: rune(0xe0ec) // grid-3x3
ICON_SOLO :: rune(0xe53b) // scan-eye
ICON_GIZMO :: rune(0xe2e5) // move-3d
ICON_REMESH :: rune(0xe0eb) // globe: a sphere of even lines
ICON_DYNTOPO :: rune(0xe129) // network
ICON_RETOPO :: rune(0xe504) // grid-2x2
ICON_SUBDIVIDE :: rune(0xe62d) // grid-2x2-plus
ICON_BOOLEAN :: rune(0xe5a1) // blend
