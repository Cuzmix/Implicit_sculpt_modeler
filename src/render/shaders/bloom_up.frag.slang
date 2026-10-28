// One step up the bloom chain (render/finish.odin): the coarser glow read through a 3x3 tent
// (nine bilinear reads, Jimenez 2014), which smooths the step up in size, mixed with this
// size's own light by the scatter, as Unity HDRP's chain does: the more scatter, the more of
// each coarser, wider glow reaches the result, so it grows wider without growing brighter.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D coarse;
[[vk::binding(1, 2)]] Sampler2D fine;

[[vk::binding(0, 3)]] cbuffer Bloom_Up_Uniforms {
	// x: the scatter (0 only this size's light, 1 only the coarser glow)
	float4 params;
	// xy: one over the output's size in pixels
	float4 size;
};

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	float2 uv = frag_coord.xy * size.xy;
	float2 t = 1.0 / float2(texture_size(coarse));
	float3 sum = 4.0 * coarse.SampleLevel(uv, 0.0).rgb;
	sum += 2.0 * (coarse.SampleLevel(uv + t * float2(0.0, -1.0), 0.0).rgb + coarse.SampleLevel(uv + t * float2(-1.0, 0.0), 0.0).rgb +
		coarse.SampleLevel(uv + t * float2(1.0, 0.0), 0.0).rgb + coarse.SampleLevel(uv + t * float2(0.0, 1.0), 0.0).rgb);
	sum += coarse.SampleLevel(uv + t * float2(-1.0, -1.0), 0.0).rgb + coarse.SampleLevel(uv + t * float2(1.0, -1.0), 0.0).rgb +
		coarse.SampleLevel(uv + t * float2(-1.0, 1.0), 0.0).rgb + coarse.SampleLevel(uv + t * float2(1.0, 1.0), 0.0).rgb;
	float3 glow = sum / 16.0;
	return float4(lerp(fine.SampleLevel(uv, 0.0).rgb, glow, params.x), 1.0);
}
