// Shows render mode's samples (render/path.odin) over the viewport: the mean radiance of
// the samples that met the scene, exposed, tone mapped and sRGB encoded as the viewport
// is, laid over the viewport's own image by how many of them did, so the background, the
// floor grid and anything not traced show as the viewport draws them. Denoised, the mean
// is the denoiser's light (render_atrous.frag.slang) times the colour the guides hold. Traced
// at half size (tablets), each pixel blends the four traced pixels round it, weighed by
// how much of each met the scene, so edges stay smooth over the viewport's own image.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D view_color;
[[vk::binding(1, 2)]] Sampler2D accum;
[[vk::binding(2, 2)]] Sampler2D denoised;
[[vk::binding(3, 2)]] Sampler2D guide_albedo;

[[vk::binding(0, 3)]] cbuffer Display_Uniforms {
	// x: the exposure in stops, y: the samples summed in accum, z: 1 to show `denoised`,
	// w: 1 when the samples are half the viewport's size each way
	float4 params;
};

#include "display.slang"

// Traced pixel `q`'s mean radiance, and the share of its samples that met the scene.
float4 traced(int2 q) {
	float4 sum = accum.Load(int3(q, 0));
	float covered = sum.a / max(params.y, 1.0);
	float3 mean = sum.rgb / max(sum.a, 1e-6);
	if (params.z > 0.5) {
		float4 a = guide_albedo.Load(int3(q, 0));
		mean = denoised.Load(int3(q, 0)).rgb * (a.a > 0.0 ? max(a.rgb, float3(0.02)) : float3(1.0));
	}
	return sum.a > 0.0 ? float4(mean, covered) : float4(0.0);
}

// traced(q) weighed by `w` and by its share, for blending.
float4 blended(int2 q, float w) {
	float4 t = traced(q);
	return float4(t.rgb * t.a, t.a) * w;
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	float3 under = view_color.Load(int3(px, 0)).rgb;
	float4 t;
	if (params.w < 0.5) {
		t = traced(px);
	} else {
		int2 hi = texture_size(accum) - 1;
		float2 at = frag_coord.xy / float2(texture_size(view_color)) * float2(hi + 1) - 0.5;
		int2 q = int2(floor(at));
		float2 f = at - float2(q);
		t = blended(clamp(q, int2(0), hi), (1.0 - f.x) * (1.0 - f.y)) + blended(clamp(q + int2(1, 0), int2(0), hi), f.x * (1.0 - f.y))
		  + blended(clamp(q + int2(0, 1), int2(0), hi), (1.0 - f.x) * f.y) + blended(clamp(q + int2(1, 1), int2(0), hi), f.x * f.y);
		if (t.a > 0.0) t.rgb /= t.a;
	}
	float3 shown = t.a > 0.0 ? display_color(t.rgb, params.x) : under;
	return float4(lerp(under, shown, clamp(t.a, 0.0, 1.0)), 1.0);
}
