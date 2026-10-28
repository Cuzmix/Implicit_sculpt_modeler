// Sharpening, the finishing stack's last pass (render/finish.odin), after the tone curve as it
// expects: contrast-adaptive sharpening, AMD FidelityFX CAS's method (Lottes 2019), written
// here from its published description. Each pixel moves away from its four neighbours by a
// weight that shrinks as the 3x3 around it nears black or white, so detail in the midtones
// gains and edges already at the ends of the range gain no halo, as an unsharp mask's do.
// Then the grain and the dither, which sharpening would only coarsen.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
#include "finish_grain.slang"
[[vk::binding(0, 2)]] Sampler2D graded;

[[vk::binding(0, 3)]] cbuffer Sharpen_Uniforms {
	// x: the sharpening (0 least to 1 most), y: the grain's strength (0 none), z: its size
	// in pixels, w: its pattern
	float4 params;
};

float3 at(int2 p) {
	int2 last = texture_size(graded) - 1;
	return saturate(graded.Load(int3(clamp(p, int2(0), last), 0)).rgb);
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 p = int2(frag_coord.xy);
	// a b c
	// d e f
	// g h i
	float3 a = at(p + int2(-1, -1)), b = at(p + int2(0, -1)), c = at(p + int2(1, -1));
	float3 d = at(p + int2(-1, 0)), e = at(p), f = at(p + int2(1, 0));
	float3 g = at(p + int2(-1, 1)), h = at(p + int2(0, 1)), i = at(p + int2(1, 1));
	// The soft minimum and maximum: the cross's and the whole 3x3's, added, which follows
	// the range near the pixel more smoothly than either alone.
	float3 lo = min(min(min(d, e), min(f, b)), h);
	lo += min(lo, min(min(a, c), min(g, i)));
	float3 hi = max(max(max(d, e), max(f, b)), h);
	hi += max(hi, max(max(a, c), max(g, i)));
	// How far from black and white the neighbourhood sits (0 at either, 1 in the middle).
	float3 room = sqrt(saturate(min(lo, 2.0 - hi) / max(hi, float3(1e-5))));
	// Unlike CAS, nothing where the 3x3 spans under two 8-bit steps: that is the dither in a
	// smooth gradient (clear.frag.slang's), which sharpened would show as a screen pattern.
	float3 range = 0.5 * (hi - lo);
	float3 floor = smoothstep(1.5 / 255.0, 4.0 / 255.0, range);
	float3 w = room * floor * (-1.0 / lerp(8.0, 5.0, saturate(params.x)));
	float3 sharp = saturate((w * (b + d + f + h) + e) / (1.0 + 4.0 * w));
	float alpha = graded.Load(int3(p, 0)).a;
	return float4(grain_and_dither(sharp, frag_coord.xy, params.y, params.z, asuint(params.w)), alpha);
}
