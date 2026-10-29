package main

import "core:fmt"
import "core:math"

import "../ui"

// The Lens layout's floating chrome round the full-window view (round 2 of the mockups):
// the off-hand island of tall Size and Strength sliders above the dial, the view chips at
// the top corner on the same side, the view rail of one-tap view tools down the pen side,
// and the mini view under the panels. Each is laid out under the names the bars before them
// had ("brush bar", "points", "view bar"), so whatever keeps clear of those keeps clear of
// these. Left-handed, the kit's mirror swaps every side.

// Lucide's layout-grid, aperture and box, for the view layout, the passes and the object.
ICON_VIEW_LAYOUT :: ui.ICON_GRID
ICON_PASSES :: rune(0xe044)
ICON_MINI_VIEW :: ui.ICON_IMAGE
ICON_OBJECT_BOX :: rune(0xe065)
ICON_FLIP_VIEW :: rune(0xe361) // flip-horizontal

// The island's tall sliders' track, in points: short enough that both stand between the
// chips and the dial on a laptop's window.
OFFHAND_TRACK :: 96

// How far the island, the chips and the rail stand in from the window's edges, in points.
LENS_EDGE :: 12

// A chip's pill, in points: drawn this tall inside a touch target.
LENS_CHIP_H :: 32

// The mini view's picture, in points: portrait, as a silhouette of a head or a figure is.
MINI_W :: 168
MINI_H :: 200

// The off-hand island: a bar of the brush's values and any command (Bar_Which.Offhand),
// at first Size and Strength as tall sliders that a thumb drags without looking, each
// moving its value by how far the drag goes. A long press (or a right-click) on a value
// opens its menu (brush_values.odin). The pen held over Size or Strength without touching
// and turned about its own length on purpose sets it too (island_roll,
// ui.hover_roll). A window too short for every
// slider shows the last ones as chips.
kit_offhand :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	used := bar_used(app, .Offhand)
	if len(used) == 0 && !k.bars_edit do return
	sliders := 0
	tall: f32 = 2 * 6
	for s, i in used {
		_, value := value_of(s)
		switch {
		case !value: tall += t.target
		case bar_look(k, .Offhand, i) == .Slider: tall += OFFHAND_TRACK + 80; sliders += 1
		case bar_look(k, .Offhand, i) == .Chip: tall += VALUE_CHIP.y
		case: tall += t.target
		}
		tall += 6
	}
	area := ui.safe_area(ctx)
	room := area.h - points_bottom(app) - t.edge - dock_stack(app) - 16
	for sliders > 0 && tall > room {
		tall -= OFFHAND_TRACK + 80 - VALUE_CHIP.y
		sliders -= 1
	}
	ui.begin_anchored(ctx, "brush bar", .Start, .Start, {LENS_EDGE, brush_bar_top(app)}, {direction = .Column, gap = 6, padding = 6, radius = t.radius_large, background = .Panel, center = true})
	for s, i in used {
		v, value := value_of(s)
		switch {
		case !value:
			bar_slot_button(app, .Offhand, i, s)
		case bar_look(k, .Offhand, i) == .Slider && sliders > 0 && !k.bars_edit:
			offhand_slider(app, i, v)
			sliders -= 1
		case:
			value_item(app, .Offhand, i, v)
		}
	}
	if k.bars_edit do bar_add_button(app, .Offhand, len(used))
	ui.end(ctx)
}

// Value `v` in slot `slot` of the island as a tall slider. Size and Strength keep the
// names, keys and pen roll they always had.
@(private = "file")
offhand_slider :: proc(app: ^App, slot: int, v: Brush_Value) {
	ctx := &app.kit.ctx
	#partial switch v {
	case .Size:
		_ = ui.vslider(ctx, "Size##island", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f", app.brush.radius_px), keys = slider_hint(app, "S, [ ]", .Size_Up), track = OFFHAND_TRACK, roll = false)
		if roll := island_roll(ctx); roll != 0 do app.brush.radius_px = clamp(app.brush.radius_px * math.pow(2, roll * ROLL_POINTS / ROLL_SIZE_DOUBLE), MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Strength:
		strength := brush_strength(app)
		_ = ui.vslider(ctx, "Strength##island", strength, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", strength^), keys = slider_hint(app, "U, Shift+[ ]", .Strength_Up), track = OFFHAND_TRACK, roll = false)
		if roll := island_roll(ctx); roll != 0 do strength^ = clamp(strength^ + roll * ROLL_POINTS / ROLL_STRENGTH_FULL, MIN_STRENGTH, 1)
	case:
		lo, hi, scale := value_range(v)
		x := value_get(app, v)
		if ui.vslider(ctx, fmt.tprintf("%s##island %d", BRUSH_VALUE_NAMES[v], slot), &x, lo, hi, scale, value_short(app, v), keys = command_hint(app, .Brush_Value, int(v)), track = OFFHAND_TRACK) && value_enabled(app, v) do value_set(app, v, x)
	}
	if ui.secondary(ctx) do value_menu_open(app, .Offhand, slot, v, ctx.last_rect, .Right)
}

// A size or strength slider's tooltip: its keys, and the three-finger drag when that is on.
slider_hint :: proc(app: ^App, keys: string, step: Command_Id) -> string {
	return hint_join(keys, command_gesture(app, step))
}

// Points of drag a degree of the pen's roll stands for, and the points of drag that double
// the size and take the strength across its range: a quarter turn clockwise doubles the
// size and half a turn takes the strength from 0 to 1, as Windows Ink and some Android pens
// report the roll.
ROLL_POINTS :: f32(ROLL_STRENGTH_FULL) / 180
ROLL_SIZE_DOUBLE :: 150
ROLL_STRENGTH_FULL :: 300

// The degrees the pen's roll moves the slider just drawn this frame (ui.hover_roll), which
// its value follows by these figures rather than the kit's sweep, which its sliders are
// told to leave alone.
@(private = "file")
island_roll :: proc(ctx: ^ui.Context) -> f32 {
	return ui.hover_roll(ctx, ctx.last_id, ctx.hot == ctx.last_id)
}

// A chip over the view: a see-through pill a touch target tall holding an optional
// camera dot and icon, `text`, a dimmer `sub` and a chevron when it opens a menu. Lit
// (accent text) while what it opens shows. Its tooltip is `name` with `keys`.
lens_chip :: proc(ctx: ^ui.Context, name, text: string, sub := "", glyph: rune = 0, dot: Maybe(ui.Color) = nil, chevron := false, lit := false, keys := "") -> ui.Area {
	t := ctx.theme
	a := ui.area(ctx, name, {lens_chip_width(ctx, text, sub, glyph, dot != nil, chevron), t.target})
	pill := ui.Rect{a.rect.x, a.rect.y + (a.rect.h - LENS_CHIP_H) * 0.5, a.rect.w, LENS_CHIP_H}
	lens_chip_draw(ctx, pill, text, sub, glyph, dot, chevron, lit, a.held, a.hovered)
	ui.tip(ctx, a.id, a.rect, ui.label_text(name), keys)
	return a
}

// A chip's width for what it holds, in points.
lens_chip_width :: proc(ctx: ^ui.Context, text: string, sub := "", glyph: rune = 0, dot := false, chevron := false) -> f32 {
	t := ctx.theme
	w: f32 = 2 * LENS_CHIP_PAD
	if dot do w += 14
	if glyph != 0 do w += t.icon_small + 6
	if text != "" do w += ui.text_width(ctx, text, t.small_size, .Semibold)
	if sub != "" do w += 6 + ui.text_width(ctx, sub, t.small_size)
	if chevron do w += 18
	return w
}

LENS_CHIP_PAD :: 10

// Draws a chip's pill at `pill`, pressed or hovered as `held` and `hovered` say.
lens_chip_draw :: proc(ctx: ^ui.Context, pill: ui.Rect, text: string, sub := "", glyph: rune = 0, dot: Maybe(ui.Color) = nil, chevron := false, lit := false, held := false, hovered := false) {
	t := ctx.theme
	fill := ui.Color{t.frame.r, t.frame.g, t.frame.b, TOP_GLASS_ALPHA}
	ui.fill_rect(ctx, pill, t.radius_medium, fill)
	if held do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_pressed)
	else if hovered do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_hover)
	ui.stroke_rect(ctx, pill, t.radius_medium, t.border, 1)
	x := pill.x + LENS_CHIP_PAD
	cy := pill.y + pill.h * 0.5
	if c, ok := dot.?; ok {
		ui.fill_circle(ctx, {x + 4, cy}, 4, c)
		x += 14
	}
	if glyph != 0 {
		ui.icon(ctx, glyph, {x + t.icon_small * 0.5, cy}, t.icon_small, t.text_secondary)
		x += t.icon_small + 6
	}
	if text != "" {
		ui.text(ctx, text, x, cy, t.small_size, t.accent if lit else t.text, .Semibold)
		x += ui.text_width(ctx, text, t.small_size, .Semibold)
	}
	if sub != "" {
		ui.text(ctx, sub, x + 6, cy, t.small_size, t.text_tertiary)
		x += 6 + ui.text_width(ctx, sub, t.small_size)
	}
	if chevron do ui.icon(ctx, ui.ICON_CHEVRON_DOWN, {x + 10, cy}, t.icon_small - 2, t.text_tertiary)
}

// The main camera's lens as a full-frame camera's would be, in millimetres: the focal
// length that gives its vertical field of view on a 24 mm tall frame.
lens_focal_mm :: proc(fov_y: f32) -> f32 {
	return 12 / math.tan(fov_y * 0.5)
}

// The view chips at the top corner on the off-hand side: the camera (its dot, Persp or
// Ortho and its lens; a tap opens the Camera menu), the pass (a tap opens the list, a hold
// peeks at the last other one) and Clean view. They are the main view's, so they stand
// aside while another pane is maximised over it: that pane's head has its own. The
// selected object is the chip bar's (object_chip.odin).
kit_view_chips :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ps := &k.passes
	k.view_chips_shown = false
	if k.grid.maximised != 0 && grid_panes(&k.grid) > 1 do return
	k.view_chips_shown = true
	at := [2]f32{LENS_EDGE, TOP_BAR_H + 2}
	if g := &k.grid; grid_panes(g) > 1 && g.maximised == 0 && g.main.w > 0 {
		win := ctx.input.window
		edge := win.x - (g.main.x + g.main.w) if ctx.mirror else g.main.x
		at = {LENS_EDGE + edge, max(TOP_BAR_H + 2, g.main.y + 8)}
	}
	ui.begin_anchored(ctx, "points", .Start, .Start, at, {direction = .Column})
	ui.begin(ctx, "view chips", {direction = .Row, gap = 6})
	c := &app.camera
	projection := "Ortho" if c.ortho else "Persp"
	sub := "" if c.ortho else fmt.tprintf("%.0f mm", lens_focal_mm(c.fov_y))
	if a := lens_chip(ctx, "Camera##chip", projection, sub, dot = t.camera[0], chevron = true, lit = bar_pop_showing(app, .Camera), keys = command_hint(app, .Camera_Menu)); a.clicked {
		k.bar_at[.Camera], k.bar_side[.Camera] = a.rect, .Below
		bar_pop_toggle(app, .Camera, a.rect, .Below)
	}
	shown := viewport_pass(k)
	pass := lens_chip(ctx, "Pass##chip", PASS_LABELS[shown], chevron = true, lit = shown != .Shaded || ps.menu, keys = command_hint(app, .View_Pass, int(ps.pass)))
	pass_chip_follow(k, pass.rect, pass.clicked)
	if a := lens_chip(ctx, "Clean view##chip", "", glyph = ICON_CLEAN_VIEW, keys = command_hint(app, .Clean_View)); a.clicked do clean_view_set(app, true)
	ui.end(ctx)
	ui.end(ctx)
}

// The view rail down the pen side, under the top bar: the tray's button, then the rail's
// slots the user arranges (bars.odin, at first the eight view tools), each opening what it
// opens beside the rail. A rail taller than the room down to the window's edge scrolls.
kit_view_rail :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	owner := ui.id_of(ctx, "view bar")
	top: f32 = TOP_BAR_H + 6
	ui.begin_anchored(ctx, "view bar", .End, .Start, {BAR_EDGE + 6, top}, {direction = .Column, padding = 3, radius = t.radius_large, background = .Panel, center = true})
	// The panels collapse rather than close once the stack has its headers; until then the
	// tray needs a way back.
	_ = bar_command_lens(app, .Inspector, ui.ICON_PANEL, tray_shown(app))
	ui.divider(ctx, 32, across = true)
	area := ui.safe_area(ctx)
	room := area.y + area.h - t.edge - top - t.target - 12
	used := bar_used(app, .View_Rail)
	scroll := kit_scroll_begin(ctx, "view rail body", &k.rail_scroll, owner, t.target, max(room, t.target * 3), 0)
	for s, i in used do bar_slot_button(app, .View_Rail, i, s)
	if k.bars_edit do bar_add_button(app, .View_Rail, len(used))
	kit_scroll_end(ctx, scroll)
	ui.end(ctx)
}

// A button on the rail that runs command `id`, lit with `selected`.
@(private = "file")
bar_command_lens :: proc(app: ^App, id: Command_Id, glyph: rune, selected: bool) -> bool {
	ctx := &app.kit.ctx
	if ui.icon_button(ctx, bar_label({id, 0}), glyph, selected, command_enabled(app, id), command_hint(app, id)) {
		command_run(app, id)
		return true
	}
	return false
}

// How far in from the pen side's edge the navigation head stands in Lens: left of whatever
// stands at that side's top (the rail, the panels' column, a panel shown there last frame),
// as the mockups have it, so it never sits on the panels.
lens_nav_offset :: proc(app: ^App) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	mid := area.x + area.w * 0.5
	reach: f32 = LENS_EDGE
	near_top := area.y + kit_top() + 40
	take :: proc(r: ui.Rect, area: ui.Rect, mid, near_top: f32, mirror: bool, reach: ^f32) {
		if r.w <= 0 || r.y > near_top do return
		pen_side := (r.x + r.w * 0.5 > mid) != mirror
		if !pen_side do return
		from := area.x + area.w - r.x if !mirror else r.x + r.w - area.x
		reach^ = max(reach^, from + 8)
	}
	take(ui.prev_rect(ctx, "view bar"), area, mid, near_top, ctx.mirror, &reach)
	for c in k.panels.rect do take(c, area, mid, near_top, ctx.mirror, &reach)
	for s in k.panels.seen do if s.frame >= k.frame - 1 do take(s.rect, area, mid, near_top, ctx.mirror, &reach)
	return reach
}

// How tall a band at the pen side's bottom is kept clear for the pen hand's palm, in
// points: a fifth of the window on a tablet-shaped one (no wider than 1.5 times its
// height), where the hand rests on the glass, else none.
lens_palm :: proc(app: ^App) -> f32 {
	area := ui.safe_area(&app.kit.ctx)
	if area.w > area.h * 1.5 do return 0
	return area.h * 0.2
}

// How far up from the safe area's bottom the mini view reaches where it sits in its place
// in Lens, for the panels' column above it to stop short of; zero when it is not there.
lens_mini_reach :: proc(app: ^App) -> f32 {
	k := &app.kit
	if !k.thumbnail || k.windows[.Thumbnail].moved do return 0
	if _, _, docked := panel_docked(k, Kit_Window.Thumbnail); docked do return 0
	r := panel_rect(app, Kit_Window.Thumbnail)
	if r.h <= 0 do return 0
	area := ui.safe_area(&k.ctx)
	return area.y + area.h - r.y
}

// The mini view (the thumbnail window, in Lens): the second camera's picture alone in the
// pen side's lower corner, under the panels and above the palm. A chip on it names what it
// shows; a tap on the chip shows the camera and pass choices under the picture, and a tap
// on the picture swaps it with the main view. A drag turns it, as the thumbnail's does.
kit_mini_view :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sv := &k.second
	shown := ui.presence(ctx, panel_id(Kit_Window.Thumbnail), k.thumbnail, t.panel_time)
	k.thumbnail_px = {}
	if shown <= 0 do return
	win := &k.windows[.Thumbnail]
	PADDING :: 4
	below := max(t.edge, lens_palm(app), side_panel_below(app, MINI_W + 2 * PADDING))
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, Kit_Window.Thumbnail, "", .End, .End, {kit_right(app), below}, {direction = .Column, gap = 6, padding = PADDING, width = MINI_W + 2 * PADDING, radius = t.radius_large, background = .Panel, inert = !k.thumbnail}, card = true)
	raised = p.raised
	if p.closed do k.thumbnail = false
	if p.dock do panel_menu_open(app, Kit_Window.Thumbnail)
	if p.body {
		a := ui.area(ctx, "second view picture", {MINI_W, MINI_H})
		pic := a.rect
		d := ctx.input.pixel_density
		k.thumbnail_px = {u32(pic.w * d + 0.5), u32(pic.h * d + 0.5)}
		ui.fill_rect(ctx, pic, t.radius_small, t.fill)
		if app.thumbnail.shown != nil {
			lo, hi := [2]f32{0, 0}, [2]f32{1, 1}
			if k.thumbnail_flip do lo.x, hi.x = 1, 0
			ui.image_part(ctx, pic, KIT_THUMBNAIL_IMAGE, lo, hi)
			kit_guides(app, pic, app.thumbnail.orbit, "thumbnail")
		}
		second_view_input(app, ctx, k.scale, sv, a)
		// The chip over the picture's corner is part of the picture's press: a tap on it
		// shows the choices, a tap elsewhere swaps.
		dot, _ := second_color(t, sv, 1)
		label := fmt.tprintf("%s · %s", SECOND_CAMERA_NAMES[sv.camera], SECOND_PASS_NAMES[sv.pass])
		// A render says how far it has come, as round 2's studio2 screen: "Render · 64/256".
		if have, want := picture_samples(app, sv, &app.thumbnail); want > 0 do label = fmt.tprintf("%s · %d/%d", SECOND_PASS_NAMES[sv.pass], min(have, want), want)
		room := pic.w - 12
		label = ui.text_fit(ctx, label, t.small_size, room - lens_chip_width(ctx, "", dot = true, chevron = true), .Semibold)
		w := min(lens_chip_width(ctx, label, dot = true, chevron = true), room)
		chip := ui.Rect{pic.x + 6, pic.y + 6, w, LENS_CHIP_H - 4}
		on_chip := ui.rect_contains(chip, a.mouse)
		lens_chip_draw(ctx, chip, label, dot = dot, chevron = true, lit = k.mini_rows, held = a.held && on_chip, hovered = a.hovered && on_chip)
		if a.clicked && !sv.dragging {
			if on_chip do k.mini_rows = !k.mini_rows
			else do mini_swap(app)
		}
		if k.mini_rows do kit_mini_rows(app)
	}
	panel_end(app, &p)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .End) * (1 - shown) * 16, 0})
	return
}

// The mini view's choices under its picture: its camera and pass, then Flip, Link and Close.
@(private = "file")
kit_mini_rows :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	sv := &k.second
	cameras := make([]string, len(Second_Camera), context.temp_allocator)
	for name, c in SECOND_CAMERA_NAMES do cameras[c] = name
	if picked := ui.select(ctx, "Mini view camera", cameras, int(sv.camera), MINI_W); picked >= 0 && Second_Camera(picked) != sv.camera {
		if Second_Camera(picked) == .Free do second_free(app, sv)
		else do sv.camera = Second_Camera(picked)
	}
	passes := make([]string, len(Second_Pass), context.temp_allocator)
	for name, kind in SECOND_PASS_NAMES do passes[kind] = name
	if picked := ui.select(ctx, "Mini view shows", passes, int(sv.pass), MINI_W); picked >= 0 do sv.pass = Second_Pass(picked)
	ui.begin(ctx, "mini view row", {direction = .Row, center = true, gap = 4})
	if ui.icon_button(ctx, "Flip left to right", ICON_FLIP_VIEW, selected = k.thumbnail_flip) do k.thumbnail_flip = !k.thumbnail_flip
	linked := second_linked(sv)
	if ui.icon_button(ctx, "Unlink from the main camera" if linked else "Link to the main camera", ICON_LINK, selected = linked) do second_link_toggle(app, sv)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE) do k.thumbnail = false
	ui.end(ctx)
}

// A tap on the mini view's picture: the main view takes the camera the mini view sees
// through, and the mini view keeps the main view's as a free camera, so a second tap swaps
// them back. A linked view already shows the main camera, so it has nothing to swap.
mini_swap :: proc(app: ^App) {
	k := &app.kit
	sv := &k.second
	if second_linked(sv) {
		report(app, nil, {.Quiet}, "The mini view shows the main camera: pick another camera to swap with it")
		return
	}
	other := second_orbit(app, sv)
	main := app.camera
	other.shift, main.shift = main.shift, {}
	app.camera = other
	sv.orbit, sv.camera = main, .Free
	k.mini_swaps += 1
}
