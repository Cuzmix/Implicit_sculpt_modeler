package main

import "core:fmt"

import "../ui"
import "../geom"

// Lens's look cards (round 2 of the mockups, screen studio2): Lights, Material and
// Environment as cards of the stack, which a fresh layout leaves out and Studio shows.
// Lights is the Lights section (kit_lights.odin), Material its card (lens_materials.odin),
// Environment the Environment section: each the one interface for its part.

// A light row's height, and the colour dot's radius, in points.
LIGHT_ROW_H :: 36
LIGHT_DOT :: 6

// A light's line on its row: its colour temperature, when it has one, and its intensity.
light_line :: proc(l: Light) -> string {
	if l.kelvin > 0 do return fmt.tprintf("%.0f K · %.1f", l.kelvin, l.strength)
	return fmt.tprintf("%.1f", l.strength)
}

// A preset's colour as its sphere shows it: the colour of a selected object, in sRGB.
material_swatch :: proc(m: Material) -> ui.Color {
	c := m.selected
	return {u8(geom.srgb_encode(clamp(c.r, 0, 1)) * 255 + 0.5), u8(geom.srgb_encode(clamp(c.g, 0, 1)) * 255 + 0.5), u8(geom.srgb_encode(clamp(c.b, 0, 1)) * 255 + 0.5), 255}
}
