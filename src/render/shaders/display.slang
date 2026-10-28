// What a lit colour shows as, shared by mesh_shading.slang and clear.frag.slang (the
// image environment behind the scene goes through the same curve as what reflects it),
// and the way back from it the finishing stack takes (finish.frag.slang): an include,
// never compiled alone.

// Linear light to the sRGB curve the viewport texture is shown with (IEC 61966-2-1, the
// curve image files and the exporters use), not a 2.2 power: that one lifts the darkest
// values several steps, which greys crevices out.
float3 srgb_encode(float3 c) {
	c = clamp(c, 0.0, 1.0);
	return lerp(12.92 * c, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// Khronos PBR Neutral tone mapping: below about 0.8 colours pass through with only a
// small toe, so picked colours stay the colours shown; above it they roll off toward
// white, desaturating a little, instead of clipping. Both shading paths go through it,
// so a clay object and a metal one in the same view share one transfer curve.
float3 tone_map(float3 c) {
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
	return lerp(c, float3(new_peak), g);
}

// The sRGB curve undone: what srgb_encode was given.
float3 srgb_decode(float3 c) {
	return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c));
}

// The highest display value undone, the light of 8-bit code 254.5: white itself is light
// without end, and an 8-bit picture cannot tell anything past code 254 (seven times
// white) apart, so white comes back as about thirteen times it.
static const float NEUTRAL_TOP = 0.99555;

// tone_map undone, step by step from its end: the desaturation, the shoulder, then the
// toe. Each is one to one on what tone_map can give, so a Neutral display value comes
// back as the light that made it, up to its 8-bit step.
float3 neutral_inverse(float3 y) {
	const float START = 0.8 - 0.04;
	const float DESATURATION = 0.15;
	const float d = 1.0 - START;
	float3 c = y;
	float new_peak = min(max(y.r, max(y.g, y.b)), NEUTRAL_TOP);
	if (new_peak >= START) {
		// The mix toward new_peak keeps the largest channel at new_peak, so it names the
		// peak, and with it how far the mix went.
		float peak = START - d + d * d / (1.0 - new_peak);
		float g = 1.0 - 1.0 / (DESATURATION * (peak - new_peak) + 1.0);
		c = (min(y, float3(new_peak)) - g * new_peak) / (1.0 - g);
		c *= peak / new_peak;
	}
	// The toe took x - 6.25 x^2 off a smallest channel x under 0.08, leaving 6.25 x^2
	// (under 0.04), and 0.04 off anything above.
	float least = max(min(c.r, min(c.g, c.b)), 0.0);
	float offset = least < 0.04 ? 0.4 * sqrt(least) - least : 0.04;
	return max(c + offset, float3(0.0));
}

// A linear colour scaled by `stops` of exposure, tone mapped and sRGB encoded.
float3 display_color(float3 c, float stops) {
	return srgb_encode(tone_map(c * exp2(stops)));
}
