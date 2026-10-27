#version 450
// One pass of render mode's denoiser (render/path.odin): the edge-avoiding À-Trous
// wavelet filter (Dammertz et al. 2010). Each pass blurs with a 5 x 5 B3-spline kernel
// whose taps are `step` pixels apart, the steps doubling pass by pass, and weighs each tap
// down where the guides (render_trace.comp's first sample) say it is another surface: its
// normal, its distance or its colour differ, or where its light differs by more than the
// samples' noise could explain, so shadow edges and highlights stay. It filters the light
// with the surface's colour divided out, so texture and paint stay as sharp as the guides;
// render_display.frag multiplies it back. A pixel whose centre met nothing passes through.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D src;
layout(set = 2, binding = 1) uniform sampler2D guide_albedo;
layout(set = 2, binding = 2) uniform sampler2D guide_normal;

layout(set = 3, binding = 0) uniform Atrous_Uniforms {
	// x: the taps' step in pixels; y: how far light may differ, relative, before a tap
	// stops counting; z: 1 when `src` is render mode's sum (the first pass), whose mean
	// this pass takes and divides by the colour, 0 when it is the previous pass's output
	vec4 params;
};

layout(location = 0) out vec4 out_color;

const float KERNEL[3] = float[3](3.0 / 8.0, 1.0 / 4.0, 1.0 / 16.0);

// The light at `px` with the colour divided out: from the sum on the first pass.
vec3 light_at(ivec2 px) {
	vec4 c = texelFetch(src, px, 0);
	if (params.z < 0.5) return c.rgb;
	vec3 mean = c.rgb / max(c.a, 1.0);
	vec4 a = texelFetch(guide_albedo, px, 0);
	return a.a > 0.0 ? mean / max(a.rgb, vec3(0.02)) : mean;
}

float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	ivec2 hi = textureSize(src, 0) - 1;
	vec3 centre = light_at(px);
	vec4 ga = texelFetch(guide_albedo, px, 0);
	if (ga.a <= 0.0) {
		out_color = vec4(centre, 1.0);
		return;
	}
	vec4 gn = texelFetch(guide_normal, px, 0);
	int step = int(params.x);
	float l0 = luminance(centre);
	vec3 sum = vec3(0.0);
	float total = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			ivec2 q = clamp(px + ivec2(x, y) * step, ivec2(0), hi);
			vec4 qa = texelFetch(guide_albedo, q, 0);
			if (qa.a <= 0.0) continue;
			vec4 qn = texelFetch(guide_normal, q, 0);
			vec3 c = light_at(q);
			float w = KERNEL[abs(x)] * KERNEL[abs(y)];
			w *= pow(max(dot(gn.xyz, qn.xyz), 0.0), 64.0);
			w *= exp(-abs(gn.w - qn.w) / (0.01 * gn.w * float(step) + 1e-6));
			vec3 da = ga.rgb - qa.rgb;
			w *= exp(-dot(da, da) / 0.01);
			float dl = abs(luminance(c) - l0) / (0.5 * (luminance(c) + l0) + 1e-3);
			w *= exp(-dl / params.y);
			sum += c * w;
			total += w;
		}
	}
	out_color = vec4(total > 0.0 ? sum / total : centre, 1.0);
}
