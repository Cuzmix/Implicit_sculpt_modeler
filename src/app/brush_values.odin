package main

import "core:fmt"
import "core:math"
import "core:strings"

import "../sculpt"
import "../ui"

// The brush's values as items of any bar (Bolt, 29 Oct): Size, Strength, Focal shift,
// Spacing, Lazy and Pressure, each with its own icon, put on the off-hand island, the view
// rail, the shelf's tools or pages, or the brush pie, as Classic's toolbars held them. A
// value item is a bar slot of the Brush_Value command, so every bar, key, gesture and pie
// holds it as it holds any command; how it shows on a bar (its look) is the bar's
// (Bar_List.looks). A Slider is the island's tall slider; a Chip is the icon over the
// number, a tap opening the value's popover and a drag across the bar scrubbing it, as
// ZBrush for iPad's sliders scrub; an Icon is the icon alone. A long press on any of them
// opens its menu: how it shows, the brush's section, its moves and Remove. Exposure is the
// view's, not the brush's, and is one of them so that Render's shelf and dial hold it as
// they hold the brush's values (PR 3b).

Brush_Value :: enum u8 {
	Size,
	Strength,
	Focal_Shift,
	Spacing,
	Lazy,
	Pressure,
	Exposure, // the view's exposure, in stops: last, as keys and gestures name values by name
}

Value_Look :: enum u8 {
	Slider,
	Chip,
	Icon,
}

@(rodata)
BRUSH_VALUE_NAMES := [Brush_Value]string {
	.Size        = "Size",
	.Strength    = "Strength",
	.Focal_Shift = "Focal shift",
	.Spacing     = "Spacing",
	.Lazy        = "Lazy",
	.Pressure    = "Pressure",
	.Exposure    = "Exposure",
}

// Lucide's nearest glyphs: a radius, a gauge, a lens's focus, dabs in a row, the line
// trailing the pen, a pen's weighted line, and an aperture's blades.
@(rodata)
BRUSH_VALUE_ICONS := [Brush_Value]rune {
	.Size        = rune(0xe532), // radius
	.Strength    = rune(0xe1bf), // gauge
	.Focal_Shift = rune(0xe29e), // focus
	.Spacing     = rune(0xe0ba), // ellipsis
	.Lazy        = rune(0xe38f), // spline
	.Pressure    = rune(0xe5f7), // signature
	.Exposure    = rune(0xe044), // aperture
}

@(rodata)
VALUE_LOOK_NAMES := [Value_Look]string {
	.Slider = "Slider",
	.Chip   = "Chip",
	.Icon   = "Icon",
}

// The section each value's settings are in, which its menu's Brush settings opens.
@(rodata)
BRUSH_VALUE_SECTIONS := [Brush_Value]Kit_Section {
	.Size        = .Pen,
	.Strength    = .Pen,
	.Focal_Shift = .Falloff,
	.Spacing     = .Stroke,
	.Lazy        = .Stroke,
	.Pressure    = .Pen,
	.Exposure    = .Material,
}

// The values the popover's steps set, a tap each: the sizes doubling, the strength in
// quarters, the focal shift either way, the usual spacings and lazy strings, and a stop
// down, none and a stop up.
@(rodata)
VALUE_STEPS := [Brush_Value][]f32 {
	.Size        = {12, 24, 48, 96, 192},
	.Strength    = {0.25, 0.5, 0.75, 1},
	.Focal_Shift = {-50, 0, 50},
	.Spacing     = {0.05, 0.1, 0.2, 0.5},
	.Lazy        = {0, 10, 30, 60},
	.Pressure    = {},
	.Exposure    = {-1, 0, 1},
}

// A value item's width and height on a column bar, and how far a scrub must go to take
// the value across its whole range, points.
VALUE_CHIP :: [2]f32{52, 56}
VALUE_SCRUB_SPAN :: 240
// The longest lazy string, pixels, as the Stroke section's slider has it.
LAZY_MAX_PX :: 150

// A value item's bar slot.
value_slot :: proc(v: Brush_Value) -> Bar_Slot {
	return {.Brush_Value, int(v)}
}

// The value a slot holds, if it is a value item.
value_of :: proc(s: Bar_Slot) -> (v: Brush_Value, ok: bool) {
	if s.id != .Brush_Value || s.arg < 0 || s.arg >= len(Brush_Value) do return
	return Brush_Value(s.arg), true
}

// Each value's range and how a slider maps it.
value_range :: proc(v: Brush_Value) -> (lo, hi: f32, scale: ui.Scale) {
	switch v {
	case .Size:        return MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic
	case .Strength:    return MIN_STRENGTH, 1, .Linear
	case .Focal_Shift: return sculpt.FOCAL_MIN, sculpt.FOCAL_MAX, .Linear
	case .Spacing:     return MIN_SPACING, MAX_SPACING, .Logarithmic
	case .Lazy:        return 0, LAZY_MAX_PX, .Linear
	case .Pressure:    return 0, 1, .Linear
	case .Exposure:    return -EXPOSURE_RANGE, EXPOSURE_RANGE, .Linear
	}
	return 0, 1, .Linear
}

// The value now: the same fields the Pen, Stroke and Falloff sections' sliders change.
value_get :: proc(app: ^App, v: Brush_Value) -> f32 {
	b := &app.brush
	switch v {
	case .Size:        return b.radius_px
	case .Strength:    return brush_strength(app)^
	case .Focal_Shift: return focal_shift(app)^
	case .Spacing:     return b.spacing if b.spacing > 0 else DAB_SPACING
	case .Lazy:        return b.lazy_px
	case .Pressure:    return 1 if b.pressure_size || b.pressure_strength else 0
	case .Exposure:    return app.exposure
	}
	return 0
}

// Sets the value, within its range and in the steps its section's slider takes (the focal
// shift in whole steps, the exposure in tenths of a stop, as its slider's text shows it).
// Pressure is its popover's two switches, not a number.
value_set :: proc(app: ^App, v: Brush_Value, to: f32) {
	lo, hi, _ := value_range(v)
	x := clamp(to, lo, hi)
	b := &app.brush
	switch v {
	case .Size:        b.radius_px = x
	case .Strength:    brush_strength(app)^ = x
	case .Focal_Shift: focal_shift(app)^ = math.round(x)
	case .Spacing:     b.spacing = x
	case .Lazy:        b.lazy_px = x
	case .Pressure:
	case .Exposure:    app.exposure = math.round(x * 10) / 10
	}
}

// Whether the value does anything with this brush: Spacing only for a stroke of dabs
// (Spray and Roll space their own), as the Stroke section shows it.
value_enabled :: proc(app: ^App, v: Brush_Value) -> bool {
	return v != .Spacing || app.brush.stroke == .Dots
}

// The value as the popover and the tooltip say it, with its unit.
value_text :: proc(app: ^App, v: Brush_Value) -> string {
	x := value_get(app, v)
	switch v {
	case .Size:        return fmt.tprintf("%.0f px", x)
	case .Strength:    return fmt.tprintf("%.2f", x)
	case .Focal_Shift: return fmt.tprintf("%.0f", x)
	case .Spacing:     return fmt.tprintf("%.0f%%", x * 100)
	case .Lazy:        return "off" if x < 0.5 else fmt.tprintf("%.0f px", x)
	case .Pressure:    return "on" if x > 0 else "off"
	case .Exposure:    return fmt.tprintf("%+.1f stops", x)
	}
	return ""
}

// The value as a chip says it, in its little room: no unit, Strength without its 0.
value_short :: proc(app: ^App, v: Brush_Value) -> string {
	x := value_get(app, v)
	#partial switch v {
	case .Size:     return fmt.tprintf("%.0f", x)
	case .Strength: return strings.trim_prefix(fmt.tprintf("%.2f", x), "0")
	case .Lazy:     return "off" if x < 0.5 else fmt.tprintf("%.0f", x)
	case .Exposure: return fmt.tprintf("%+.1f", x)
	}
	return value_text(app, v)
}

// How far along its range the value is, 0 to 1, for a chip's hairline.
value_fraction :: proc(app: ^App, v: Brush_Value) -> f32 {
	lo, hi, scale := value_range(v)
	return ui.slider_fraction(value_get(app, v), lo, hi, scale)
}

// A step's label in the popover.
@(private = "file")
value_step_text :: proc(v: Brush_Value, x: f32) -> string {
	#partial switch v {
	case .Strength: return strings.trim_prefix(fmt.tprintf("%.2f", x), "0")
	case .Spacing:  return fmt.tprintf("%.0f%%", x * 100)
	case .Lazy:     return "off" if x < 0.5 else fmt.tprintf("%.0f", x)
	case .Exposure: return fmt.tprintf("%+.0f", x) if x != 0 else "0"
	}
	return fmt.tprintf("%.0f", x)
}

// The look a value put on bar `which` takes: the island's tall slider, a chip elsewhere.
bar_default_look :: proc(which: Bar_Which) -> Value_Look {
	return .Slider if which == .Offhand else .Chip
}

// Whether bar `which` can show a value as a tall slider: only the island, which neither
// scrolls nor swipes, so the slider's drag is never a scroll's or a page's.
bar_offers_slider :: proc(which: Bar_Which) -> bool {
	return which == .Offhand
}

// How slot `slot` of bar `which` shows, if it holds a value: a Slider where the bar has no
// room for one shows as a Chip.
bar_look :: proc(k: ^Kit_State, which: Bar_Which, slot: int) -> Value_Look {
	l := bar_list_k(k, which)
	look := l.looks[slot]
	// Pressure is on or off, not a number to slide.
	if look == .Slider && (!bar_offers_slider(which) || l.slots[slot] == value_slot(.Pressure)) do return .Chip
	return look
}

// Opens the value's popover beside `at`, or closes it when it shows that value already.
value_pop_toggle :: proc(app: ^App, v: Brush_Value, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	p := &k.bar_pop
	if p.open && p.kind == .Value && p.value == v {
		p.open = false
		return
	}
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = .Value, value = v, at = at, side = side}
	k.value_pops += 1
}

// The value's command, from a key, a gesture, the pie or Search: its popover at the
// pointer.
value_command :: proc(app: ^App, arg: int) {
	v, ok := value_of({.Brush_Value, arg})
	if !ok do return
	m := app.kit.ctx.input.mouse
	value_pop_toggle(app, v, {m.x, m.y, 1, 1}, .Pointer)
}

// Opens the menu of slot `slot` of bar `which`, a value item, beside `at`.
value_menu_open :: proc(app: ^App, which: Bar_Which, slot: int, v: Brush_Value, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	kit_floats_close(k)
	k.bar_pop = {open = true, kind = .Value_Menu, value = v, which = which, slot = slot, at = at, side = side}
}

// A value item on bar `which`, in its look: `cell` is the item's size on that bar (0 for
// a column bar's chip), `column` whether the bar runs down the window. A scrub runs across
// the bar, so it never fights the rail's scroll or the shelf's page swipe.
value_item :: proc(app: ^App, which: Bar_Which, slot: int, v: Brush_Value, cell: [2]f32 = {}, column := true) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	look := bar_look(k, which, slot)
	side := bar_side(app, which)
	name := fmt.tprintf("%s##value %v %d", BRUSH_VALUE_NAMES[v], which, slot)
	enabled := k.bars_edit || value_enabled(app, v)
	lit := bar_pop_showing(app, .Value) && k.bar_pop.value == v
	hint := hint_join(value_text(app, v), command_hint(app, .Brush_Value, int(v)))
	if look == .Icon {
		if ui.icon_button(ctx, name, BRUSH_VALUE_ICONS[v], lit, enabled, hint, cell.x) {
			if k.bars_edit do bar_slot_open(app, which, slot, ctx.last_rect)
			else do value_pop_toggle(app, v, ctx.last_rect, side)
		}
		if k.bars_edit do bar_edit_ring(app, ctx.last_rect)
		else if ctx.last_id != 0 && ui.secondary(ctx) do value_menu_open(app, which, slot, v, ctx.last_rect, side)
		return
	}
	size := cell if cell.x > 0 else VALUE_CHIP
	a := ui.area(ctx, name, size, drag = false)
	pill := ui.Rect{a.rect.x + 2, a.rect.y + 2, a.rect.w - 4, a.rect.h - 4}
	axis := 0 if column else 1
	scrubbing := false
	if enabled && !k.bars_edit && v != .Pressure {
		if a.pressed do ctx.press_value = value_fraction(app, v)
		if a.held && ui.claim_drag(ctx, axis) {
			d := ctx.input.mouse - ctx.won_mouse
			moved := d.x if column else -d.y
			if abs(moved) > 0 {
				lo, hi, scale := value_range(v)
				f := clamp(ctx.press_value + moved / VALUE_SCRUB_SPAN, 0, 1)
				before := value_get(app, v)
				value_set(app, v, ui.slider_value(f, lo, hi, scale))
				if value_get(app, v) != before do ui.long_cancel(ctx)
				scrubbing = true
				if k.value_scrubbing != a.id {
					k.value_scrubbing = a.id
					k.value_scrubs += 1
				}
			}
		}
	}
	if !a.held && k.value_scrubbing == a.id do k.value_scrubbing = 0
	if a.held && enabled do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_pressed)
	else if lit do ui.fill_rect(ctx, pill, t.radius_medium, t.accent_soft)
	else if a.hovered && enabled do ui.fill_rect(ctx, pill, t.radius_medium, t.fill_hover)
	fg := t.accent if lit || scrubbing else t.text
	if !enabled do fg = ui.color_fade(t.text_secondary, 0.35)
	cx := pill.x + pill.w * 0.5
	ui.icon(ctx, BRUSH_VALUE_ICONS[v], {cx, pill.y + pill.h * 0.36}, t.icon_size - 2, fg)
	ui.text(ctx, value_short(app, v), cx, pill.y + pill.h * 0.72, t.caption_size, fg if lit || scrubbing else t.text_secondary, .Semibold, .Center)
	// The hairline of how far the value is set, under the number.
	line := ui.Rect{pill.x + 8, pill.y + pill.h - 5, pill.w - 16, 2}
	ui.fill_rect(ctx, line, 1, t.track)
	if enabled do ui.fill_rect(ctx, {line.x, line.y, line.w * value_fraction(app, v), line.h}, 1, t.accent)
	ui.tip(ctx, a.id, pill, BRUSH_VALUE_NAMES[v], hint)
	if k.bars_edit {
		bar_edit_ring(app, a.rect)
		if a.clicked do bar_slot_open(app, which, slot, a.rect)
		return
	}
	// A scrub that won the drag is not also a tap.
	moved := ctx.input.mouse - ctx.press_mouse
	if a.clicked && enabled && abs(moved[axis]) <= t.slop do value_pop_toggle(app, v, a.rect, side)
	if a.id != 0 && ui.secondary(ctx) do value_menu_open(app, which, slot, v, a.rect, side)
}

// The value's popover: its icon, name and exact value, a wide slider and the steps; for
// Pressure the two switches it is.
kit_value_pop :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p := &k.bar_pop
	v := p.value
	if !ui.popover_begin(ctx, "bar value", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = 12, width = VALUE_POP_W}) do return
	defer ui.popover_end(ctx)
	ui.begin(ctx, "value head", {direction = .Row, center = true, gap = 8})
	g := ui.area(ctx, "value glyph", {t.icon_small, t.target}, drag = false)
	ui.icon(ctx, BRUSH_VALUE_ICONS[v], {g.rect.x + g.rect.w * 0.5, g.rect.y + g.rect.h * 0.5}, t.icon_small, t.accent)
	ui.label(ctx, BRUSH_VALUE_NAMES[v], t.text_size, t.text, .Semibold)
	ui.label(ctx, value_text(app, v), t.text_size, t.text_secondary)
	ui.end(ctx)
	if v == .Pressure {
		_ = ui.switch_row(ctx, "Pressure changes the size", &app.brush.pressure_size)
		_ = ui.switch_row(ctx, "Pressure changes the strength", &app.brush.pressure_strength)
		return
	}
	enabled := value_enabled(app, v)
	lo, hi, scale := value_range(v)
	x := value_get(app, v)
	// The head names it, so the slider itself goes unlabelled.
	if ui.slider(ctx, fmt.tprintf("##value pop %v", v), &x, lo, hi, scale, "", enabled) do value_set(app, v, x)
	steps := VALUE_STEPS[v]
	if len(steps) == 0 do return
	ui.begin(ctx, "value steps", {direction = .Row, gap = 6})
	w := (VALUE_POP_W - 24 - 6 * f32(len(steps) - 1)) / f32(len(steps))
	for s in steps {
		on := abs(value_get(app, v) - s) < 1e-3 * max(1, abs(s))
		if ui.toggle_button(ctx, fmt.tprintf("%s##value step %v", value_step_text(v, s), s), on, w) && enabled do value_set(app, v, s)
	}
	ui.end(ctx)
	if !enabled do ui.paragraph(ctx, "Spacing is for a stroke of dabs: Spray and Roll space their own.")
}

VALUE_POP_W :: 300

// A value item's menu: how it shows, its brush settings, its moves, another value after
// it, and Remove.
kit_value_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.bar_pop
	v, which, slot := p.value, p.which, p.slot
	used := bar_used(app, which)
	if slot >= len(used) || used[slot] != value_slot(v) {
		p.open = false
		return
	}
	if !ui.popover_begin(ctx, "bar value menu", &p.open, p.at, p.side, {direction = .Column, padding = 6, width = 268}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, fmt.tprintf("%s · SHOW AS", strings.to_upper(BRUSH_VALUE_NAMES[v], context.temp_allocator)))
	look := bar_look(k, which, slot)
	for l in Value_Look {
		if l == .Slider && (!bar_offers_slider(which) || v == .Pressure) do continue
		if ui.menu_item(ctx, fmt.tprintf("%s##value look", VALUE_LOOK_NAMES[l]), checked = l == look) {
			bar_list(app, which).looks[slot] = l
			p.open = false
		}
	}
	ui.divider(ctx, across = true)
	// Exposure is the view's: its slider is in Material's More options, opened with it.
	if ui.menu_item(ctx, "Material settings" if v == .Exposure else "Brush settings", glyph = ui.ICON_PANEL) {
		at, side := p.at, p.side
		if v == .Exposure do k.more[.Material] = true
		bar_pop_toggle(app, .Section, at, side, BRUSH_VALUE_SECTIONS[v])
		return
	}
	column := bar_column(which)
	earlier, later := "Move up", "Move down"
	if !column do earlier, later = "Move left", "Move right"
	if ui.menu_item(ctx, earlier, glyph = ui.ICON_CHEVRON_UP if column else ICON_CHEVRON_LEFT, enabled = slot > 0) do p.slot = bar_move(app, which, slot, -1)
	if ui.menu_item(ctx, later, glyph = ui.ICON_CHEVRON_DOWN if column else ui.ICON_CHEVRON_RIGHT, enabled = slot < len(used) - 1) do p.slot = bar_move(app, which, slot, 1)
	room := len(used) < bar_capacity(which)
	if ui.menu_item(ctx, "Add another value", glyph = ui.ICON_PLUS, enabled = room && value_missing(app, which) != {}) do p.adding = !p.adding
	if p.adding {
		for other in value_missing(app, which) {
			if ui.menu_item(ctx, fmt.tprintf("    %s##value add", BRUSH_VALUE_NAMES[other]), glyph = BRUSH_VALUE_ICONS[other]) {
				if bar_insert(app, which, p.slot + 1) {
					bar_list(app, which).slots[p.slot + 1] = value_slot(other)
					bar_list(app, which).looks[p.slot + 1] = bar_list(app, which).looks[p.slot]
				}
				p.adding = false
			}
		}
	}
	if ui.menu_item(ctx, "Remove from the bar", glyph = ui.ICON_TRASH, tone = .Danger) {
		bar_remove(app, which, slot)
		p.open = false
	}
}

// The values bar `which` does not hold yet.
value_missing :: proc(app: ^App, which: Bar_Which) -> (out: bit_set[Brush_Value]) {
	out = ~bit_set[Brush_Value]{}
	for s in bar_used(app, which) do if v, ok := value_of(s); ok do out -= {v}
	return
}

// How many value items the bars hold, for the exit stats.
values_on_bars :: proc(app: ^App) -> (n: int) {
	for which in Bar_Which do for s in bar_used(app, which) do if _, ok := value_of(s); ok do n += 1
	return
}

// How bar `which`'s items show, comma separated, for the exit stats: a value's look, or
// "command" for any other ("none" for none).
bar_looks :: proc(app: ^App, which: Bar_Which) -> string {
	used := bar_used(app, which)
	if len(used) == 0 do return "none"
	b := strings.builder_make(context.temp_allocator)
	for s, i in used {
		if i > 0 do strings.write_byte(&b, ',')
		_, value := value_of(s)
		strings.write_string(&b, fmt.tprint(bar_look(&app.kit, which, i)) if value else "command")
	}
	return strings.to_string(b)
}
