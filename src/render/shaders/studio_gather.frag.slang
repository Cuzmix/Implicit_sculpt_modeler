// One sample of the studio render: for every viewport pixel on a surface, whether a
// light from `light_dir` reaches it past everything in the shadow map, added to the
// accumulation target (blending adds). Ambient occlusion samples come from directions
// all round the scene and add (visibility * cos, cos) to red and green; light samples,
// jittered around the light the sample picked, add (visibility, 1) times the light's
// weight plus the ambient light's, which nothing shadows, to blue and alpha
// (studio_weight.slang).
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D view_depth;
[[vk::binding(1, 2)]] Sampler2D shadow_depth;

[[vk::binding(0, 3)]] cbuffer Gather_Uniforms {
	float4x4 inv_view_proj;   // viewport clip space back to the world
	float4x4 light_view_proj; // world to the shadow map's clip space
	float4 light_dir;       // xyz: toward the light (world, unit); w: 1 for a key light sample
	float4 params;          // x: depth bias, y: normal offset (world), z: shadow map texel (uv)
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
	float2 size = float2(texture_size(view_depth));
	int2 px = int2(frag_coord.xy);
	float d = view_depth.Load(int3(px, 0)).r;
	if (d >= 1.0) {
		return float4(0.0);
	}
	float3 p = world_at(frag_coord.xy, d, size);
	float3 n = depth_normal(view_depth, px, frag_coord.xy, d, p, size);

	float3 l = light_dir.xyz;
	float cosine = dot(n, l);
	bool key = light_dir.w > 0.5;
	// A sample counts by how much of the pixel's light its light gives; where no light
	// reaches, the pixel shows unshadowed.
	float2 weight = float2(0.0);
	if (key) {
		weight = shadow_weight(p, n);
		if (weight.x < 0.0) {
			return float4(0.0, 0.0, 1.0, 1.0);
		}
	}
	if (cosine <= 0.0) {
		// Facing away: no light from here, which the viewport's shading already shows
		// for the light this sample picked.
		return key ? float4(0.0, 0.0, 1.0, 1.0) * (weight.x + weight.y) : float4(0.0);
	}
	float4 c = mul(float4(p + n * params.y, 1.0), light_view_proj);
	float3 s = c.xyz / c.w;
	float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
	float lit = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float occluder = shadow_depth.Sample(uv + float2(x, y) * params.z).r;
			lit += s.z - params.x <= occluder ? 1.0 : 0.0;
		}
	}
	lit /= 9.0;
	return key ? float4(0.0, 0.0, lit * weight.x + weight.y, weight.x + weight.y) : float4(lit * cosine, cosine, 0.0, 0.0);
}
