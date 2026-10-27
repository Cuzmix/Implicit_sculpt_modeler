// What a studio render shadow sample counts for at a pixel, shared by studio_gather.frag
// and studio_trace_add.frag; an include, never compiled alone. The including shader
// declares world_at and, in its uniforms, the lights in the world (render.Shadow_Lights):
// shadow_pos (toward a sun, or where a point or spot light is, kind in w), shadow_shape
// (distance, reach and a spot's inner cosine, the chance the light is picked in w),
// shadow_spot (a spot's axis and outer cosine) and shadow_pick (x: the light this sample
// took; z: the ambient light, in the units of the lights' reach over their chances).

#include "light_window.glsl"

// The surface normal from the depth of the neighbouring pixels, taking the side with the
// smaller depth step so silhouettes do not smear across the background, turned toward
// the eye.
vec3 depth_normal(sampler2D view_depth, ivec2 px, vec2 frag, float d, vec3 p, vec2 size) {
	ivec2 hi = ivec2(size) - 1;
	float dl = texelFetch(view_depth, clamp(px - ivec2(1, 0), ivec2(0), hi), 0).r;
	float dr = texelFetch(view_depth, clamp(px + ivec2(1, 0), ivec2(0), hi), 0).r;
	float du = texelFetch(view_depth, clamp(px - ivec2(0, 1), ivec2(0), hi), 0).r;
	float dd = texelFetch(view_depth, clamp(px + ivec2(0, 1), ivec2(0), hi), 0).r;
	vec3 px_r = abs(dr - d) < abs(d - dl) ? world_at(frag + vec2(1, 0), dr, size) - p : p - world_at(frag - vec2(1, 0), dl, size);
	vec3 px_d = abs(dd - d) < abs(d - du) ? world_at(frag + vec2(0, 1), dd, size) - p : p - world_at(frag - vec2(0, 1), du, size);
	vec3 n = normalize(cross(px_d, px_r));
	vec3 toward_eye = world_at(frag, 0.0, size) - p;
	if (dot(n, toward_eye) < 0.0) n = -n;
	return n;
}

// How much of light `i` reaches `p` facing `n`, before shadows, as the viewport's lights
// fall (light_at): the cosine, and for a point or spot light its fall with distance,
// reach and cone. Lights that are off have no chance and give nothing.
float shadow_light(int i, vec3 p, vec3 n) {
	vec4 pos = shadow_pos[i];
	if (shadow_shape[i].w <= 0.0) return 0.0;
	if (pos.w < 0.5) return max(dot(n, pos.xyz), 0.0);
	vec3 to = pos.xyz - p;
	float d2 = max(dot(to, to), 1e-8);
	vec3 l = to * inversesqrt(d2);
	float ref = shadow_shape[i].x;
	return max(dot(n, l), 0.0) * (ref * ref / d2) * light_window(pos, shadow_shape[i], shadow_spot[i], d2, l);
}

// This sample's weight at `p`, x for its light and y for the ambient light, which no
// shadow touches: each over all the light that reaches `p`, the lights' each by the
// chance it is picked. Their mean over the samples adds up to 1, and the samples' light
// summed over their weights tends to the share of all the light at `p` that arrives
// unshadowed, whichever lights give it, so a shadow from a dim light takes away only that
// light; no sample weighs more than one over its light's chance. (-1, 0) where no light
// reaches `p`, which shows unshadowed.
vec2 shadow_weight(vec3 p, vec3 n) {
	float total = shadow_pick.z;
	for (int i = 0; i < 8; i++) total += shadow_shape[i].w * shadow_light(i, p, n);
	if (total <= 0.0) return vec2(-1.0, 0.0);
	return vec2(shadow_light(int(shadow_pick.x), p, n), shadow_pick.z) / total;
}
