#version 450
// Live ambient occlusion (render/live_ao.odin): ground-truth ambient occlusion (GTAO,
// Jimenez et al. 2016, with XeGTAO's falloff and sample spacing) from the camera's
// depth, one value per texel of the occlusion target, which may be half the viewport's
// size. Each texel searches two slices through the depth buffer for the horizons either
// side and integrates the cosine-weighted visibility between them. The slices' turn and
// the steps' offset follow a 4 x 4 pattern of the texel's position, never time, which
// the 4 x 4 blur after (ao_blur.frag) averages away: thirty-two directions a pixel, the
// same every frame, so a partial redraw matches the full one.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D view_depth;

layout(set = 3, binding = 0) uniform Gtao_Uniforms {
	mat4 inv_proj; // the viewport's clip space back to view space
	vec4 size;     // xy: the viewport's size in pixels, z: viewport pixels per texel here, w: 1 for orthographic
	// x: the reach in view units, y: pixels a view unit spans one unit in front of the eye
	// (or anywhere, orthographic), z: the largest search radius in pixels.
	vec4 params;
};

layout(location = 0) out vec4 out_ao;

const float PI = 3.14159265;
const int SLICES = 2;
const int STEPS = 6;
// The nearest a step may land, in pixels, so the first does not read the pixel itself.
const float MIN_STEP_PX = 1.3;
// The share of the reach over which an occluder's weight falls to nothing at its end.
const float FALLOFF = 0.615;
const float BAYER[16] = float[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);

vec3 view_at(ivec2 px, float depth) {
	vec2 ndc = vec2(2.0 * (float(px.x) + 0.5) / size.x - 1.0, 1.0 - 2.0 * (float(px.y) + 0.5) / size.y);
	vec4 v = inv_proj * vec4(ndc, depth, 1.0);
	return v.xyz / v.w;
}

float depth_at(ivec2 px) {
	return texelFetch(view_depth, clamp(px, ivec2(0), ivec2(size.xy) - 1), 0).r;
}

void main() {
	ivec2 texel = ivec2(gl_FragCoord.xy);
	int scale = int(size.z);
	// The viewport pixel this texel stands for (ao_blur.frag reads the same one).
	ivec2 px = texel * scale + scale / 2;
	float d = depth_at(px);
	if (d >= 1.0) {
		out_ao = vec4(1.0);
		return;
	}
	vec3 p = view_at(px, d);
	vec3 v = size.w > 0.5 ? vec3(0.0, 0.0, 1.0) : normalize(-p);

	// The normal from the depth of the neighbouring pixels, taking the side with the
	// smaller step so silhouettes do not smear across the background (as studio_gather).
	float dl = depth_at(px - ivec2(1, 0)), dr = depth_at(px + ivec2(1, 0));
	float du = depth_at(px - ivec2(0, 1)), dd = depth_at(px + ivec2(0, 1));
	vec3 right = abs(dr - d) < abs(d - dl) ? view_at(px + ivec2(1, 0), dr) - p : p - view_at(px - ivec2(1, 0), dl);
	vec3 down = abs(dd - d) < abs(d - du) ? view_at(px + ivec2(0, 1), dd) - p : p - view_at(px - ivec2(0, 1), du);
	vec3 n = normalize(cross(right, down));
	if (dot(n, v) < 0.0) n = -n;

	float reach = params.x;
	float radius = reach * params.y / (size.w > 0.5 ? 1.0 : -p.z);
	radius = min(radius, params.z);
	if (radius < MIN_STEP_PX) {
		out_ao = vec4(1.0);
		return;
	}
	float falloff_mul = -1.0 / (FALLOFF * reach);
	float falloff_add = (1.0 - FALLOFF) / FALLOFF + 1.0;
	int k = (texel.y & 3) * 4 + (texel.x & 3);
	float turn = (BAYER[k] + 0.5) / 16.0;
	float offset = (float((texel.x - texel.y) & 3) + 0.5) / 4.0;
	float min_s = MIN_STEP_PX / radius;

	float visibility = 0.0;
	for (int slice = 0; slice < SLICES; slice++) {
		float phi = (float(slice) + turn) * PI / float(SLICES);
		// Down the screen is down the view's y: the pixel step and the view direction.
		vec2 omega = vec2(cos(phi), sin(phi));
		vec3 dir = vec3(omega.x, -omega.y, 0.0);
		vec3 ortho = dir - dot(dir, v) * v;
		vec3 axis = normalize(cross(ortho, v));
		vec3 projected = n - axis * dot(n, axis);
		float projected_len = length(projected);
		float cos_n = clamp(dot(projected, v) / max(projected_len, 1e-6), -1.0, 1.0);
		float gamma = sign(dot(ortho, projected)) * acos(cos_n);
		// Horizons start at the surface's own tangent plane, so open ground stays lit.
		float low_plus = cos(gamma + PI / 2.0), low_minus = cos(gamma - PI / 2.0);
		float horizon_plus = low_plus, horizon_minus = low_minus;
		for (int step = 0; step < STEPS; step++) {
			float s = (float(step) + offset) / float(STEPS);
			s = s * s + min_s;
			ivec2 o = ivec2(round(omega * s * radius));
			for (int side = 0; side < 2; side++) {
				ivec2 q = side == 0 ? px + o : px - o;
				vec3 delta = view_at(q, depth_at(q)) - p;
				float dist = length(delta);
				float c = dot(delta, v) / max(dist, 1e-6);
				float w = clamp(dist * falloff_mul + falloff_add, 0.0, 1.0);
				if (side == 0) horizon_plus = max(horizon_plus, mix(low_plus, c, w));
				else horizon_minus = max(horizon_minus, mix(low_minus, c, w));
			}
		}
		// Clamped first: a rounding error past 1 would make acos give NaN.
		float h0 = gamma + clamp(-acos(clamp(horizon_minus, -1.0, 1.0)) - gamma, -PI / 2.0, PI / 2.0);
		float h1 = gamma + clamp(acos(clamp(horizon_plus, -1.0, 1.0)) - gamma, -PI / 2.0, PI / 2.0);
		float arc0 = (cos_n + 2.0 * h0 * sin(gamma) - cos(2.0 * h0 - gamma)) / 4.0;
		float arc1 = (cos_n + 2.0 * h1 * sin(gamma) - cos(2.0 * h1 - gamma)) / 4.0;
		visibility += projected_len * (arc0 + arc1);
	}
	// Not clamped to 1: one pixel's two slices can see more than the whole sky where the
	// surface turns away (each is exact only averaged over every turn), and clamping would
	// darken such surfaces once the blur averages them. The blur clamps the average.
	out_ao = vec4(max(visibility / float(SLICES), 0.0));
}
