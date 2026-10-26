package ui

Color :: [4]u8

// The design tokens: every colour, size and duration the widgets use. Widgets name
// tokens, never values, so another theme (a light one) is another constant of this
// struct. The values follow the design spec ("Sculpt UI redesign: design spec").
Theme :: struct {
	// Surfaces, from the panels floating over the viewport up to what floats over them.
	surface:        Color, // toolbars, panels, the dock
	surface_raised: Color, // popovers, menus, tooltips, toasts
	fill:           Color, // wells behind segmented controls, slider tracks, inputs
	fill_hover:     Color, // the wash over a control under the pointer
	fill_pressed:   Color, // the wash over a held control
	cursor:         Color, // the sliding marker of the chosen tab or segment
	border:         Color, // the hairline round a panel
	border_strong:  Color, // the hairline round a popover
	shadow:         Color,

	text:           Color, // values and headings
	text_secondary: Color, // labels
	text_tertiary:  Color, // hints and shortcuts

	// The one accent: the active tool, the chosen option, the primary action.
	accent:         Color,
	accent_soft:    Color, // selected rows and tiles: the accent, faint
	on_accent:      Color,
	success:        Color,
	warning:        Color,
	danger:         Color,
	knob:           Color, // switch and slider knobs

	// Corners.
	radius_small:   f32, // chips, segments, inputs
	radius_medium:  f32, // buttons, tiles, rows
	radius_large:   f32, // panels, popovers

	// Type sizes, in points (Inter).
	caption_size:   f32,
	small_size:     f32,
	text_size:      f32,
	title_size:     f32,
	heading_size:   f32,
	icon_size:      f32, // toolbar icons
	icon_small:     f32, // icons in rows

	// Sizes. A hit area is never smaller than `target`, the stores' 44 pt and 48 dp both
	// met; what is drawn inside it can be smaller, so the look stays compact.
	target:         f32,
	control:        f32, // the drawn height of a button inside its target
	row:            f32, // the drawn height of a list row
	gap:            f32, // between groups in a panel
	edge:           f32, // from the window's edge to the floating panels
	// How far a finger or a pen moves before a press becomes a drag: a tap that wobbles
	// less is still a tap, and a scroll or an orbit starts only past it. Android's touch
	// slop is 8 dp, iOS's about 10 points and Flutter's 18 logical pixels.
	slop:           f32,

	// Motion, in seconds. Anything a stroke, the camera or a drag depends on is never
	// animated; these are for feedback and for things that appear and go.
	press_time:     f32,
	hover_time:     f32,
	tooltip_delay:  f32,
	tooltip_time:   f32,
	// A finger or a pen held still on a control this long is a long press (long_due),
	// and the ring that counts toward it shows from long_ring on, so a tap shows nothing.
	long_press:     f32,
	long_ring:      f32,
	popover_time:   f32,
	indicator_time: f32,
	panel_time:     f32,
	toast_time:     f32,
}

// "Graphite": cool, quiet chrome that recedes behind the warm clay of the viewport.
THEME_DARK :: Theme {
	surface        = {0x1b, 0x1c, 0x20, 0xf0},
	surface_raised = {0x24, 0x25, 0x2b, 0xff},
	fill           = {0x2d, 0x2e, 0x35, 0xff},
	fill_hover     = {0xff, 0xff, 0xff, 0x12},
	fill_pressed   = {0xff, 0xff, 0xff, 0x1c},
	cursor         = {0x41, 0x42, 0x4b, 0xff},
	border         = {0xff, 0xff, 0xff, 0x12},
	border_strong  = {0xff, 0xff, 0xff, 0x1f},
	shadow         = {0x00, 0x00, 0x00, 0x73},
	text           = {0xed, 0xed, 0xf0, 0xff},
	text_secondary = {0xa1, 0xa1, 0xaa, 0xff},
	text_tertiary  = {0x71, 0x71, 0x7a, 0xff},
	accent         = {0x5b, 0x8c, 0xff, 0xff},
	accent_soft    = {0x5b, 0x8c, 0xff, 0x29},
	on_accent      = {0xff, 0xff, 0xff, 0xff},
	success        = {0x2f, 0xc0, 0x7a, 0xff},
	warning        = {0xf2, 0xa9, 0x3b, 0xff},
	danger         = {0xf2, 0x54, 0x5b, 0xff},
	knob           = {0xff, 0xff, 0xff, 0xff},
	radius_small   = 6,
	radius_medium  = 8,
	radius_large   = 12,
	caption_size   = 11,
	small_size     = 12,
	text_size      = 13,
	title_size     = 15,
	heading_size   = 17,
	icon_size      = 18,
	icon_small     = 16,
	target         = 48,
	control        = 36,
	row            = 40,
	gap            = 12,
	edge           = 12,
	slop           = 10,
	press_time     = 0.10,
	hover_time     = 0.14,
	tooltip_delay  = 0.45,
	tooltip_time   = 0.15,
	long_press     = 0.45,
	long_ring      = 0.15,
	popover_time   = 0.18,
	indicator_time = 0.22,
	panel_time     = 0.24,
	toast_time     = 0.26,
}

// "Studio": neutral greys with a warm orange accent, the look of a sculpting studio's
// tablet app, so the clay reads true against chrome with no tint of its own. Sizes and
// timings are Graphite's; only the colours and the corners differ.
THEME_STUDIO :: Theme {
	surface        = {0x23, 0x23, 0x23, 0xf4},
	surface_raised = {0x2a, 0x2a, 0x2a, 0xff},
	fill           = {0x33, 0x33, 0x33, 0xff},
	fill_hover     = {0xff, 0xff, 0xff, 0x10},
	fill_pressed   = {0xff, 0xff, 0xff, 0x1a},
	cursor         = {0x40, 0x40, 0x40, 0xff},
	border         = {0xff, 0xff, 0xff, 0x0e},
	border_strong  = {0xff, 0xff, 0xff, 0x1a},
	shadow         = {0x00, 0x00, 0x00, 0x8c},
	text           = {0xed, 0xed, 0xed, 0xff},
	text_secondary = {0xb4, 0xb4, 0xb4, 0xff},
	text_tertiary  = {0x7c, 0x7c, 0x7c, 0xff},
	accent         = {0xf2, 0xa3, 0x3a, 0xff},
	accent_soft    = {0xf2, 0xa3, 0x3a, 0x2e},
	on_accent      = {0x1a, 0x1a, 0x1a, 0xff},
	success        = {0x3c, 0xc2, 0x7e, 0xff},
	warning        = {0xf5, 0xd0, 0x4c, 0xff},
	danger         = {0xf0, 0x6a, 0x5e, 0xff},
	knob           = {0xf4, 0xf4, 0xf4, 0xff},
	radius_small   = 6,
	radius_medium  = 10,
	radius_large   = 14,
	caption_size   = 11,
	small_size     = 12,
	text_size      = 13,
	title_size     = 15,
	heading_size   = 17,
	icon_size      = 18,
	icon_small     = 16,
	target         = 48,
	control        = 36,
	row            = 40,
	gap            = 12,
	edge           = 12,
	slop           = 10,
	press_time     = 0.10,
	hover_time     = 0.14,
	tooltip_delay  = 0.45,
	tooltip_time   = 0.15,
	long_press     = 0.45,
	long_ring      = 0.15,
	popover_time   = 0.18,
	indicator_time = 0.22,
	panel_time     = 0.24,
	toast_time     = 0.26,
}

// `c` with its alpha scaled by `f`.
color_fade :: proc(c: Color, f: f32) -> Color {
	return {c.r, c.g, c.b, u8(f32(c.a) * clamp(f, 0, 1) + 0.5)}
}

// The colour `t` of the way from `a` to `b`, for crossfades.
color_mix :: proc(a, b: Color, amount: f32) -> Color {
	t := clamp(amount, 0, 1)
	out: Color
	for i in 0 ..< 4 do out[i] = u8(f32(a[i]) + (f32(b[i]) - f32(a[i])) * t + 0.5)
	return out
}
