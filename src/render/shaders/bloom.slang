// What the bloom (render/finish.odin) shares between its chain and the finishing pass.
// Include after display.slang.

// The light above `threshold` with a soft knee half the threshold wide (Unity's): light fades
// in over the knee rather than popping on at the threshold. With no threshold, all the light.
float3 above_threshold(float3 c, float threshold) {
	if (threshold <= 0.0) return c;
	float bright = max(c.r, max(c.g, c.b));
	float knee = 0.5 * threshold;
	float q = clamp(bright - threshold + knee, 0.0, 2.0 * knee);
	q = q * q / (4.0 * knee);
	return c * max(q, bright - threshold) / max(bright, 1e-4);
}

// The light a Neutral display value came from, for the glow: neutral_inverse, but where its
// guess cannot be trusted (finish.frag.slang's main says where: a colour Neutral never shows,
// and anything near white) the colour shown at the guessed light's brightness, so a MatCap's
// pink highlight glows pink rather than the pure red its 8-bit guess may give.
float3 bloom_decode(float3 v) {
	float3 shown = srgb_decode(v);
	float3 c = neutral_inverse(shown);
	float3 residual = shown - tone_map(c);
	float off = smoothstep(0.01, 0.05, max(abs(residual.r), max(abs(residual.g), abs(residual.b))));
	float bright = smoothstep(0.85, 0.97, max(shown.r, max(shown.g, shown.b)));
	float3 weights = float3(0.2126, 0.7152, 0.0722);
	float3 kept = shown * dot(c, weights) / max(dot(shown, weights), 1e-4);
	return lerp(c, kept, max(off, bright));
}
