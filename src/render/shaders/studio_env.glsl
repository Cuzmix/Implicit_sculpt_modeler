// The built-in studio environment, shared by mesh_shading.glsl and render_trace.comp: an
// include, never compiled alone.

// The studio the physically based materials reflect, in its own space (turned into view
// space by light_x, y and z: by default not at all), as a photographer
// would light a product: a cool sky over a dark floor, a warm softbox above and to the
// side of the default key light (not on it, or the key's highlight would be counted twice), a
// cool strip light behind on the right that catches edges, and a bounce card behind the
// camera, so a face turned to the viewer reflects something rather than the black floor.
// `rough` (0 to 1) blurs it, standing in for a prefiltered environment map at no memory
// and a few instructions.
const vec3 SOFTBOX_DIR = normalize(vec3(-0.75, 0.85, 0.15));
const vec3 STRIP_DIR   = normalize(vec3(0.9, 0.35, -0.45));
const vec3 CARD_DIR    = normalize(vec3(0.1, -0.35, 1.0));

// A light of `color` seen as a lobe around `toward`, `sharp` at the sharpest; it widens
// with roughness while its energy stays about the same, as a blurred reflection of a
// bright light does.
vec3 lobe(vec3 dir, vec3 toward, vec3 color, float sharp, float rough) {
	float e = mix(sharp, 3.0, sqrt(rough));
	return color * pow(max(dot(dir, toward), 0.0), e) * (e + 2.0) / (sharp + 2.0);
}

vec3 studio(vec3 dir, float rough) {
	float w = 0.08 + 0.9 * rough;
	float up = smoothstep(-w, w, dir.y);
	vec3 c = mix(vec3(0.07, 0.065, 0.06), vec3(0.40, 0.43, 0.48), up);
	// A brighter band at the horizon reads as the far wall of the studio.
	c += vec3(0.13, 0.12, 0.11) * exp(-abs(dir.y) / (0.06 + 0.5 * rough));
	c += lobe(dir, SOFTBOX_DIR, vec3(4.0, 3.8, 3.5), 300.0, rough);
	c += lobe(dir, STRIP_DIR, vec3(1.6, 1.8, 2.1), 600.0, rough);
	c += lobe(dir, CARD_DIR, vec3(0.5, 0.5, 0.5), 4.0, rough);
	return c;
}
