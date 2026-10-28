// What a studio render shadow sample counts for at a pixel, shared by studio_gather.frag.slang
// and studio_trace_add.frag.slang; an include, never compiled alone. The including shader
// declares world_at and, in its uniforms, the lights in the world (render.Shadow_Lights):
// shadow_pos (toward a sun, or where a point or spot light is, kind in w), shadow_shape
// (distance, reach and a spot's inner cosine, the chance the light is picked in w),
// shadow_spot (a spot's axis and outer cosine) and shadow_pick (x: the light this sample
// took; z: the ambient light, in the units of the lights' reach over their chances).

#include "light_window.slang"

// The surface normal from the depth of the neighbouring pixels, taking the side with the
// smaller depth step so silhouettes do not smear across the background, turned toward
// the eye.
float3 depth_normal(Sampler2D view_depth, int2 px, float2 frag, float d, float3 p, float2 size) {
	int2 hi = int2(size) - 1;
	float dl = view_depth.Load(int3(clamp(px - int2(1, 0), int2(0), hi), 0)).r;
	float dr = view_depth.Load(int3(clamp(px + int2(1, 0), int2(0), hi), 0)).r;
	float du = view_depth.Load(int3(clamp(px - int2(0, 1), int2(0), hi), 0)).r;
	float dd = view_depth.Load(int3(clamp(px + int2(0, 1), int2(0), hi), 0)).r;
	float3 px_r = abs(dr - d) < abs(d - dl) ? world_at(frag + float2(1, 0), dr, size) - p : p - world_at(frag - float2(1, 0), dl, size);
	float3 px_d = abs(dd - d) < abs(d - du) ? world_at(frag + float2(0, 1), dd, size) - p : p - world_at(frag - float2(0, 1), du, size);
	float3 n = normalize(cross(px_d, px_r));
	float3 toward_eye = world_at(frag, 0.0, size) - p;
	if (dot(n, toward_eye) < 0.0) n = -n;
	return n;
}

// How much of light `i` reaches `p` facing `n`, before shadows, as the viewport's lights
// fall (light_at): the cosine, and for a point or spot light its fall with distance,
// reach and cone. Lights that are off have no chance and give nothing.
float shadow_light(int i, float3 p, float3 n) {
	float4 pos = shadow_pos[i];
	if (shadow_shape[i].w <= 0.0) return 0.0;
	if (pos.w < 0.5) return max(dot(n, pos.xyz), 0.0);
	float3 to = pos.xyz - p;
	float d2 = max(dot(to, to), 1e-8);
	float3 l = to * rsqrt(d2);
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
float2 shadow_weight(float3 p, float3 n) {
	float total = shadow_pick.z;
	for (int i = 0; i < 8; i++) total += shadow_shape[i].w * shadow_light(i, p, n);
	if (total <= 0.0) return float2(-1.0, 0.0);
	return float2(shadow_light(int(shadow_pick.x), p, n), shadow_pick.z) / total;
}
