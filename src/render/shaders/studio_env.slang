// The built-in studio environment, shared by mesh_shading.slang and render_trace.comp.slang: an
// include, never compiled alone.

// The studio the physically based materials reflect, in its own space (turned into view
// space by light_x, y and z: by default not at all), as a photographer
// would light a product: a cool sky over a dark floor, a warm softbox above and to the
// side of the default key light (not on it, or the key's highlight would be counted twice), a
// cool strip light behind on the right that catches edges, and a bounce card behind the
// camera, so a face turned to the viewer reflects something rather than the black floor.
// `rough` (0 to 1) blurs it, standing in for a prefiltered environment map at no memory
// and a few instructions.
// The lights' directions, written out as normalize(float3(-0.75, 0.85, 0.15)),
// normalize(float3(0.9, 0.35, -0.45)) and normalize(float3(0.1, -0.35, 1.0)) round to: a
// static const is computed in the shader, every pixel, and a few ulps away from these.
static const float3 SOFTBOX_DIR = float3(-0.655904233, 0.743358076, 0.131180838);
static const float3 STRIP_DIR   = float3(0.844781876, 0.328526288, -0.422390938);
static const float3 CARD_DIR    = float3(0.0939681977, -0.328888685, 0.939681947);

// A light of `color` seen as a lobe around `toward`, `sharp` at the sharpest; it widens
// with roughness while its energy stays about the same, as a blurred reflection of a
// bright light does.
float3 lobe(float3 dir, float3 toward, float3 color, float sharp, float rough) {
	float e = lerp(sharp, 3.0, sqrt(rough));
	return color * pow(max(dot(dir, toward), 0.0), e) * (e + 2.0) / (sharp + 2.0);
}

float3 studio(float3 dir, float rough) {
	float w = 0.08 + 0.9 * rough;
	float up = smoothstep(-w, w, dir.y);
	float3 c = lerp(float3(0.07, 0.065, 0.06), float3(0.40, 0.43, 0.48), up);
	// A brighter band at the horizon reads as the far wall of the studio.
	c += float3(0.13, 0.12, 0.11) * exp(-abs(dir.y) / (0.06 + 0.5 * rough));
	c += lobe(dir, SOFTBOX_DIR, float3(4.0, 3.8, 3.5), 300.0, rough);
	c += lobe(dir, STRIP_DIR, float3(1.6, 1.8, 2.1), 600.0, rough);
	c += lobe(dir, CARD_DIR, float3(0.5, 0.5, 0.5), 4.0, rough);
	return c;
}
