// The share of a point or spot light's light that reaches distance² `d2` from it along
// `l` (toward the light), besides its fall with distance: Karis's window at its reach
// (shape.y) and a spot's cone between its outer cosine (spot.w) and inner one (shape.z),
// as light_at in mesh_shading.glsl. Shared by render_trace.comp and studio_weight.glsl;
// an include, never compiled alone.
float light_window(vec4 pos, vec4 shape, vec4 spot, float d2, vec3 l) {
	float k = 1.0;
	if (shape.y > 0.0) {
		float x = d2 / (shape.y * shape.y);
		float w = clamp(1.0 - x * x, 0.0, 1.0);
		k *= w * w;
	}
	if (pos.w > 1.5) k *= smoothstep(spot.w, shape.z, dot(-l, spot.xyz));
	return k;
}
