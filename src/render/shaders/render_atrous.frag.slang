// One pass of render mode's denoiser (render/path.odin): the edge-avoiding À-Trous
// wavelet filter (Dammertz et al. 2010). Each pass blurs with a 5 x 5 B3-spline kernel
// whose taps are `step` pixels apart, the steps doubling pass by pass, and weighs each tap
// down where the guides (render_trace.comp.slang's first sample) say it is another surface: its
// normal, its distance or its colour differ, or where its light differs by more than the
// samples' noise could explain, so shadow edges and highlights stay. It filters the light
// with the surface's colour divided out, so texture and paint stay as sharp as the guides;
// render_display.frag.slang multiplies it back. A pixel whose centre met nothing passes through.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D src;
[[vk::binding(1, 2)]] Sampler2D guide_albedo;
[[vk::binding(2, 2)]] Sampler2D guide_normal;

[[vk::binding(0, 3)]] cbuffer Atrous_Uniforms {
	// x: the taps' step in pixels; y: how far light may differ, relative, before a tap
	// stops counting; z: 1 when `src` is render mode's sum (the first pass), whose mean
	// this pass takes and divides by the colour, 0 when it is the previous pass's output;
	// w: 1 when the guides are means over the samples (depth of field), whose normals are
	// shorter than one where they blur
	float4 params;
};

static const float KERNEL[3] = { 3.0 / 8.0, 1.0 / 4.0, 1.0 / 16.0 };

// The light at `px` with the colour divided out: from the sum on the first pass.
float3 light_at(int2 px) {
	float4 c = src.Load(int3(px, 0));
	if (params.z < 0.5) return c.rgb;
	float3 mean = c.rgb / max(c.a, 1.0);
	float4 a = guide_albedo.Load(int3(px, 0));
	return a.a > 0.0 ? mean / max(a.rgb, float3(0.02)) : mean;
}

float luminance(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	int2 hi = texture_size(src) - 1;
	float3 centre = light_at(px);
	float4 ga = guide_albedo.Load(int3(px, 0));
	if (ga.a <= 0.0) {
		return float4(centre, 1.0);
	}
	float4 gn = guide_normal.Load(int3(px, 0));
	if (params.w > 0.5) gn.xyz = normalize(gn.xyz + float3(0.0, 0.0, 1e-6));
	int step = int(params.x);
	float l0 = luminance(centre);
	float3 sum = float3(0.0);
	float total = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			int2 q = clamp(px + int2(x, y) * step, int2(0), hi);
			float4 qa = guide_albedo.Load(int3(q, 0));
			if (qa.a <= 0.0) continue;
			float4 qn = guide_normal.Load(int3(q, 0));
			if (params.w > 0.5) qn.xyz = normalize(qn.xyz + float3(0.0, 0.0, 1e-6));
			float3 c = light_at(q);
			float w = KERNEL[abs(x)] * KERNEL[abs(y)];
			w *= pow(max(dot(gn.xyz, qn.xyz), 0.0), 64.0);
			w *= exp(-abs(gn.w - qn.w) / (0.01 * gn.w * float(step) + 1e-6));
			float3 da = ga.rgb - qa.rgb;
			w *= exp(-dot(da, da) / 0.01);
			float dl = abs(luminance(c) - l0) / (0.5 * (luminance(c) + l0) + 1e-3);
			w *= exp(-dl / params.y);
			sum += c * w;
			total += w;
		}
	}
	return float4(total > 0.0 ? sum / total : centre, 1.0);
}
