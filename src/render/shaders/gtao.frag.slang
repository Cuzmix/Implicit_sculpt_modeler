// Live ambient occlusion (render/live_ao.odin): ground-truth ambient occlusion (GTAO,
// Jimenez et al. 2016, with XeGTAO's falloff and sample spacing) from the camera's
// depth, one value per texel of the occlusion target, which may be half the viewport's
// size. Each texel searches two slices through the depth buffer for the horizons either
// side and integrates the cosine-weighted visibility between them. The slices' turn and
// the steps' offset follow a 4 x 4 pattern of the texel's position, never time, which
// the 4 x 4 blur after (ao_blur.frag.slang) averages away: thirty-two directions a pixel, the
// same every frame, so a partial redraw matches the full one.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
[[vk::binding(0, 2)]] Sampler2D view_depth;

[[vk::binding(0, 3)]] cbuffer Gtao_Uniforms {
	float4x4 inv_proj; // the viewport's clip space back to view space
	float4 size;     // xy: the viewport's size in pixels, z: viewport pixels per texel here, w: 1 for orthographic
	// x: the reach in view units, y: pixels a view unit spans one unit in front of the eye
	// (or anywhere, orthographic), z: the largest search radius in pixels.
	float4 params;
};

static const float PI = 3.14159265;
static const int SLICES = 2;
static const int STEPS = 6;
// The nearest a step may land, in pixels, so the first does not read the pixel itself.
static const float MIN_STEP_PX = 1.3;
// The share of the reach over which an occluder's weight falls to nothing at its end.
static const float FALLOFF = 0.615;
static const float BAYER[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

float3 view_at(int2 px, float depth) {
	float2 ndc = float2(2.0 * (float(px.x) + 0.5) / size.x - 1.0, 1.0 - 2.0 * (float(px.y) + 0.5) / size.y);
	float4 v = mul(float4(ndc, depth, 1.0), inv_proj);
	return v.xyz / v.w;
}

float depth_at(int2 px) {
	return view_depth.Load(int3(clamp(px, int2(0), int2(size.xy) - 1), 0)).r;
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 texel = int2(frag_coord.xy);
	int scale = int(size.z);
	// The viewport pixel this texel stands for (ao_blur.frag.slang reads the same one).
	int2 px = texel * scale + scale / 2;
	float d = depth_at(px);
	if (d >= 1.0) {
		return float4(1.0);
	}
	float3 p = view_at(px, d);
	float3 v = size.w > 0.5 ? float3(0.0, 0.0, 1.0) : normalize(-p);

	// The normal from the depth of the neighbouring pixels, taking the side with the
	// smaller step so silhouettes do not smear across the background (as studio_gather).
	float dl = depth_at(px - int2(1, 0)), dr = depth_at(px + int2(1, 0));
	float du = depth_at(px - int2(0, 1)), dd = depth_at(px + int2(0, 1));
	float3 right = abs(dr - d) < abs(d - dl) ? view_at(px + int2(1, 0), dr) - p : p - view_at(px - int2(1, 0), dl);
	float3 down = abs(dd - d) < abs(d - du) ? view_at(px + int2(0, 1), dd) - p : p - view_at(px - int2(0, 1), du);
	float3 n = normalize(cross(right, down));
	if (dot(n, v) < 0.0) n = -n;

	float reach = params.x;
	float radius = reach * params.y / (size.w > 0.5 ? 1.0 : -p.z);
	radius = min(radius, params.z);
	if (radius < MIN_STEP_PX) {
		return float4(1.0);
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
		float2 omega = float2(cos(phi), sin(phi));
		float3 dir = float3(omega.x, -omega.y, 0.0);
		float3 ortho = dir - dot(dir, v) * v;
		float3 axis = normalize(cross(ortho, v));
		float3 projected = n - axis * dot(n, axis);
		float projected_len = length(projected);
		float cos_n = clamp(dot(projected, v) / max(projected_len, 1e-6), -1.0, 1.0);
		float gamma = sign(dot(ortho, projected)) * acos(cos_n);
		// Horizons start at the surface's own tangent plane, so open ground stays lit.
		float low_plus = cos(gamma + PI / 2.0), low_minus = cos(gamma - PI / 2.0);
		float horizon_plus = low_plus, horizon_minus = low_minus;
		for (int step = 0; step < STEPS; step++) {
			float s = (float(step) + offset) / float(STEPS);
			s = s * s + min_s;
			int2 o = int2(round(omega * s * radius));
			for (int side = 0; side < 2; side++) {
				int2 q = side == 0 ? px + o : px - o;
				float3 delta = view_at(q, depth_at(q)) - p;
				float dist = length(delta);
				float c = dot(delta, v) / max(dist, 1e-6);
				float w = clamp(dist * falloff_mul + falloff_add, 0.0, 1.0);
				if (side == 0) horizon_plus = max(horizon_plus, lerp(low_plus, c, w));
				else horizon_minus = max(horizon_minus, lerp(low_minus, c, w));
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
	return float4(max(visibility / float(SLICES), 0.0));
}
