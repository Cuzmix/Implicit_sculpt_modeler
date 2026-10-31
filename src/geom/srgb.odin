package geom

import "core:math"

// The sRGB transfer curve, one home for the app, the importers, the writers and the
// panorama reader, matching the shaders' srgb_encode and srgb_decode.

// Linear light to the sRGB curve, both 0 to 1 (clamped).
srgb_encode :: proc(linear: f32) -> f32 {
	c := clamp(linear, 0, 1)
	return 12.92 * c if c <= 0.0031308 else 1.055 * math.pow(c, 1 / 2.4) - 0.055
}

// The sRGB curve back to linear light, both 0 to 1 (clamped).
srgb_decode :: proc(encoded: f32) -> f32 {
	c := clamp(encoded, 0, 1)
	return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
}
