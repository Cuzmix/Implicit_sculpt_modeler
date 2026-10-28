// One step down the bloom chain (render/finish.odin): the input at half its size, as the
// Call of Duty: Advanced Warfare chain does it (Jimenez, SIGGRAPH 2014): thirteen bilinear
// reads, a box of four inner ones and four boxes of the outer ones, which follows a wide
// smooth falloff without the flicker a 2x2 box gives as a highlight crosses pixels. The
// first step reads the finishing stack's source, decoding it to linear light, takes off what
// is under the threshold, and weighs each box by one over its brightness (Karis's average),
// so a single blazing pixel cannot pulse the whole glow as it moves.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D input;

[[vk::binding(0, 3)]] cbuffer Bloom_Down_Uniforms {
	// x: 1 for the first step, y: 1 when the source holds linear light rather than Neutral's
	// display values, z: the threshold in linear light (0 none), w: its soft knee's width
	float4 params;
	// xy: one over the output's size in pixels
	float4 size;
};

#include "display.slang"

// The light at `uv`, in linear light on the first step.
float3 light(float2 uv) {
	float3 c = input.SampleLevel(uv, 0.0).rgb;
	if (params.x < 0.5) return c;
	if (params.y < 0.5) c = neutral_inverse(srgb_decode(c));
	// Finite, and within half floats', and the packed float targets', range.
	c = clamp(c, float3(0.0), float3(30000.0));
	// The threshold with a soft knee (Unity's): light fades in over the knee below the
	// threshold rather than popping on at it.
	if (params.z > 0.0) {
		float bright = max(c.r, max(c.g, c.b));
		float knee = max(params.w, 1e-4);
		float q = clamp(bright - params.z + knee, 0.0, 2.0 * knee);
		q = q * q / (4.0 * knee);
		c *= max(q, bright - params.z) / max(bright, 1e-4);
	}
	return c;
}

// The average of four reads, weighed on the first step by one over its brightness.
float3 box(float3 a, float3 b, float3 c, float3 d, out float weight) {
	float3 m = 0.25 * (a + b + c + d);
	weight = params.x > 0.5 ? 1.0 / (1.0 + dot(m, float3(0.2126, 0.7152, 0.0722))) : 1.0;
	return m;
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	float2 uv = frag_coord.xy * size.xy;
	float2 t = 1.0 / float2(texture_size(input));
	float3 a = light(uv + t * float2(-2.0, -2.0));
	float3 b = light(uv + t * float2(0.0, -2.0));
	float3 c = light(uv + t * float2(2.0, -2.0));
	float3 d = light(uv + t * float2(-2.0, 0.0));
	float3 e = light(uv);
	float3 f = light(uv + t * float2(2.0, 0.0));
	float3 g = light(uv + t * float2(-2.0, 2.0));
	float3 h = light(uv + t * float2(0.0, 2.0));
	float3 i = light(uv + t * float2(2.0, 2.0));
	float3 j = light(uv + t * float2(-1.0, -1.0));
	float3 k = light(uv + t * float2(1.0, -1.0));
	float3 l = light(uv + t * float2(-1.0, 1.0));
	float3 m = light(uv + t * float2(1.0, 1.0));
	// The inner box weighs half, each outer one an eighth.
	float w0, w1, w2, w3, w4;
	float3 inner = box(j, k, l, m, w0);
	float3 b1 = box(a, b, d, e, w1);
	float3 b2 = box(b, c, e, f, w2);
	float3 b3 = box(d, e, g, h, w3);
	float3 b4 = box(e, f, h, i, w4);
	w0 *= 0.5;
	w1 *= 0.125;
	w2 *= 0.125;
	w3 *= 0.125;
	w4 *= 0.125;
	float3 sum = inner * w0 + b1 * w1 + b2 * w2 + b3 * w3 + b4 * w4;
	return float4(sum / (w0 + w1 + w2 + w3 + w4), 1.0);
}
