package main

import "core:fmt"
import "core:strings"

import "../ui"

// The object chip in the chip bar (the overhaul's round 3): what is selected, as ZBrush's
// SubTool name and Forger's object button show it, with what kind of thing it is and the
// facts a sculptor checks before a stroke. A tap opens the object's menu under it; a long
// press (or a right-click) opens the Scene palette, where the objects are. With nothing
// selected it names the scene's object count, and a tap opens the Scene palette.

// How much of the chip shows, from all of it down to its icon, as the bar's room allows.
Object_Chip_Fit :: enum u8 {
	None,
	Icon, // the type's icon alone
	Name, // and the name
	Tag,  // and the type ("Sculpt mesh")
	Full, // and the badges (level, HD, dynamic, layers)
}

// What the chip says: the type's icon and name, the object's name, and up to three badges.
Object_Chip :: struct {
	glyph:  rune,
	name:   string,
	tag:    string,
	badges: [3]string,
	count:  int,
	empty:  bool, // nothing is selected
}

OBJECT_CHIP_BADGE_GAP :: 4

// Each type's icon, as the mock draws them: a mesh's triangle, a cage's box and clay's cuboid.
ICON_SCULPT_MESH :: rune(0xe192) // triangle
ICON_CAGE :: rune(0xe065) // box
ICON_VOXEL_CLAY :: ICON_ORTHO // cuboid

object_chip_of :: proc(app: ^App) -> (c: Object_Chip) {
	obj := selected_object(app)
	if obj == nil {
		n := len(app.scene.objects)
		c.glyph, c.empty = ICON_OBJECTS, true
		c.name = "No selection" if n == 0 else fmt.tprintf("%d object%s", n, "" if n == 1 else "s")
		return
	}
	c.name = object_label(obj)
	badge :: proc(c: ^Object_Chip, text: string) {
		if c.count < len(c.badges) {
			c.badges[c.count] = text
			c.count += 1
		}
	}
	kind := object_type(obj)
	c.glyph, c.tag = OBJECT_TYPE_ICONS[kind], OBJECT_TYPE_NAMES[kind]
	switch kind {
	case .Voxel_Clay:
	case .Cage:
		if s := obj.cage.look.smooth; s > 0 do badge(&c, fmt.tprintf("Smooth %d", s))
	case .Sculpt_Mesh:
		if n := len(obj.levels.levels); n > 1 do badge(&c, fmt.tprintf("L%d", obj.levels.current + 1))
		if object_in_hd(obj) do badge(&c, "HD")
		if object_dynamic(obj) do badge(&c, "Dynamic")
		if n := len(object_sculptor(obj).layers.list); n > 0 do badge(&c, fmt.tprintf("%d layer%s", n, "" if n == 1 else "s"))
	}
	return
}

// The chip's width at `fit`, in points.
object_chip_width :: proc(ctx: ^ui.Context, c: Object_Chip, fit: Object_Chip_Fit) -> f32 {
	t := ctx.theme
	if fit == .None do return 0
	if fit == .Icon do return t.target
	w := 2 * LENS_CHIP_PAD + t.icon_small + 6 + ui.text_width(ctx, c.name, t.small_size, .Semibold) + 18
	if fit >= .Tag && c.tag != "" do w += 8 + object_chip_pill_width(ctx, c.tag)
	if fit >= .Full do for i in 0 ..< c.count do w += OBJECT_CHIP_BADGE_GAP + object_chip_pill_width(ctx, c.badges[i])
	return w
}

// The most of the chip that fits in `room` points.
object_chip_fit :: proc(ctx: ^ui.Context, c: Object_Chip, room: f32) -> Object_Chip_Fit {
	for fit := Object_Chip_Fit.Full; fit > .None; fit = Object_Chip_Fit(int(fit) - 1) {
		if object_chip_width(ctx, c, fit) <= room do return fit
	}
	return .None
}

@(private = "file")
object_chip_pill_width :: proc(ctx: ^ui.Context, text: string) -> f32 {
	return ui.text_width(ctx, text, ctx.theme.caption_size, .Semibold) + 12
}

// A small pill: the type tag filled, a badge outlined.
@(private = "file")
object_chip_pill :: proc(ctx: ^ui.Context, x, cy: f32, text: string, filled: bool) -> f32 {
	t := ctx.theme
	w := object_chip_pill_width(ctx, text)
	r := ui.Rect{x, cy - 10, w, 20}
	if filled do ui.fill_rect(ctx, r, t.radius_small, t.fill)
	else do ui.stroke_rect(ctx, r, t.radius_small, t.border_strong, 1)
	ui.text(ctx, text, x + 6, cy, t.caption_size, t.text_secondary, .Semibold)
	return w
}

// Lays the chip out at `fit` in the bar's row and answers taps on it.
top_object_chip :: proc(app: ^App, c: Object_Chip, fit: Object_Chip_Fit) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if fit == .None do return
	obj := selected_object(app)
	a := ui.area(ctx, "Object##chip", {object_chip_width(ctx, c, fit), t.target})
	pill := ui.Rect{a.rect.x, a.rect.y + (a.rect.h - LENS_CHIP_H) * 0.5, a.rect.w, LENS_CHIP_H}
	lit := k.object_menu && obj != nil && k.object_menu_id == obj.id
	if a.held do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_pressed)
	else if a.hovered || lit do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_hover)
	// The selection does not fit the space: the chip rings in amber, and its tooltip says
	// what the offer line over the dock says (offers.odin).
	fits, offer := space_fit(app)
	if !fits do ui.stroke_rect(ctx, pill, t.radius_medium, t.warning, 1.5)
	cy := pill.y + pill.h * 0.5
	if fit == .Icon {
		ui.icon(ctx, c.glyph, {pill.x + pill.w * 0.5, cy}, t.icon_small, t.text_tertiary if c.empty else t.text)
	} else {
		x := pill.x + LENS_CHIP_PAD
		ui.icon(ctx, c.glyph, {x + t.icon_small * 0.5, cy}, t.icon_small, t.text_tertiary if c.empty else t.text)
		x += t.icon_small + 6
		ui.text(ctx, c.name, x, cy, t.small_size, t.text_tertiary if c.empty else (t.accent if lit else t.text), .Semibold)
		x += ui.text_width(ctx, c.name, t.small_size, .Semibold)
		if fit >= .Tag && c.tag != "" {
			x += 8
			x += object_chip_pill(ctx, x, cy, c.tag, true)
		}
		if fit >= .Full do for i in 0 ..< c.count {
			x += OBJECT_CHIP_BADGE_GAP
			x += object_chip_pill(ctx, x, cy, c.badges[i], false)
		}
		ui.icon(ctx, ui.ICON_CHEVRON_DOWN, {x + 10, cy}, t.icon_small - 2, t.text_tertiary)
	}
	tip := c.name if fit < .Tag || c.tag == "" else fmt.tprintf("%s · %s", c.name, c.tag)
	if !fits do tip = fmt.tprintf("%s · %s", offer.what, offer.needs)
	ui.tip(ctx, a.id, a.rect, tip, "")
	k.object_chip_fit, k.object_chip_at = fit, a.rect
	if a.clicked {
		kit_floats_close(k)
		if obj != nil && !lit do object_menu_open(app, obj.id, a.rect, .Below, .Chip)
		else if obj == nil do tray_open(app, tray_section(app, .Scene))
	}
	if ui.secondary(ctx) do tray_open(app, tray_section(app, .Scene))
}

// The exit stats' object_chip: how much of it showed, then its tag and badges.
object_chip_stat :: proc(app: ^App) -> string {
	c := object_chip_of(app)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%v", app.kit.object_chip_fit)
	if c.tag != "" do fmt.sbprintf(&b, ",%s", c.tag)
	for i in 0 ..< c.count do fmt.sbprintf(&b, ",%s", c.badges[i])
	s, _ := strings.replace_all(strings.to_string(b), " ", "_", context.temp_allocator)
	return s
}
