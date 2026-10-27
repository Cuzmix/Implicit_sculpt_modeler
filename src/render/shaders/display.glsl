// What a lit colour shows as, shared by mesh_shading.glsl and clear.frag (the image
// environment behind the scene goes through the same curve as what reflects it): an
// include, never compiled alone.

// Linear light to the sRGB curve the viewport texture is shown with (IEC 61966-2-1, the
// curve image files and the exporters use), not a 2.2 power: that one lifts the darkest
// values several steps, which greys crevices out.
vec3 srgb_encode(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(12.92 * c, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// Khronos PBR Neutral tone mapping: below about 0.8 colours pass through with only a
// small toe, so picked colours stay the colours shown; above it they roll off toward
// white, desaturating a little, instead of clipping. Both shading paths go through it,
// so a clay object and a metal one in the same view share one transfer curve.
vec3 tone_map(vec3 c) {
	const float START = 0.8 - 0.04;
	const float DESATURATION = 0.15;
	float x = min(c.r, min(c.g, c.b));
	float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
	c -= offset;
	float peak = max(c.r, max(c.g, c.b));
	if (peak < START) return c;
	const float d = 1.0 - START;
	float new_peak = 1.0 - d * d / (peak + d - START);
	c *= new_peak / peak;
	float g = 1.0 - 1.0 / (DESATURATION * (peak - new_peak) + 1.0);
	return mix(c, vec3(new_peak), g);
}

// A linear colour scaled by `stops` of exposure, tone mapped and sRGB encoded.
vec3 display_color(vec3 c, float stops) {
	return srgb_encode(tone_map(c * exp2(stops)));
}
