// Adds one traced sample (studio_trace.comp.slang's `visible`) to the studio render's
// accumulation target, in the gather's encoding (studio_gather.frag.slang) so the composite
// reads both alike: an ambient sample, cosine-weighted already, adds (visible, 1) to red
// and green; a light sample adds (visible, 1) times its light's weight plus the ambient
// light's, which nothing shadows, to blue and alpha (studio_weight.slang). The background
// adds nothing.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D visible;
[[vk::binding(1, 2)]] Sampler2D view_depth;

[[vk::binding(0, 3)]] cbuffer Add_Uniforms {
	float4x4 inv_view_proj; // viewport clip space back to the world
	float4 params;        // x: 1 for a light sample
	float4 shadow_pos[8];
	float4 shadow_shape[8];
	float4 shadow_spot[8];
	float4 shadow_pick;
};

float3 world_at(float2 frag, float depth, float2 size) {
	float2 uv = frag / size;
	float4 w = mul(float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0), inv_view_proj);
	return w.xyz / w.w;
}

#include "studio_weight.slang"

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	float d = view_depth.Load(int3(px, 0)).r;
	if (d >= 1.0) {
		return float4(0.0);
	}
	float v = visible.Load(int3(px, 0)).r;
	if (params.x < 0.5) {
		return float4(v, 1.0, 0.0, 0.0);
	}
	// A pixel no light reaches shows unshadowed.
	float2 size = float2(texture_size(view_depth));
	float3 p = world_at(frag_coord.xy, d, size);
	float2 weight = shadow_weight(p, depth_normal(view_depth, px, frag_coord.xy, d, p, size));
	if (weight.x < 0.0) {
		return float4(0.0, 0.0, 1.0, 1.0);
	}
	return float4(0.0, 0.0, v * weight.x + weight.y, weight.x + weight.y);
}
