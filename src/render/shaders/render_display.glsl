// The body of render_display.frag and render_display_linear.frag (which defines
// LINEAR_OUT first): an include, never compiled alone.
// Shows render mode's samples (render/path.odin) over the viewport: the mean radiance of
// the samples that met the scene, exposed, tone mapped and sRGB encoded as the viewport
// is, laid over the viewport's own image by how many of them did, so the background, the
// floor grid and anything not traced show as the viewport draws them. Denoised, the mean
// is the denoiser's light (render_atrous.frag) times the colour the guides hold. Traced
// at half size (tablets), each pixel blends the four traced pixels round it, weighed by
// how much of each met the scene, so edges stay smooth over the viewport's own image.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D view_color;
layout(set = 2, binding = 1) uniform sampler2D accum;
layout(set = 2, binding = 2) uniform sampler2D denoised;
layout(set = 2, binding = 3) uniform sampler2D guide_albedo;

layout(set = 3, binding = 0) uniform Display_Uniforms {
	// x: the exposure in stops, y: the samples summed in accum, z: 1 to show `denoised`,
	// w: 1 when the samples are half the viewport's size each way
	vec4 params;
};

layout(location = 0) out vec4 out_color;

#include "display.glsl"

// Traced pixel `q`'s mean radiance, and the share of its samples that met the scene.
vec4 traced(ivec2 q) {
	vec4 sum = texelFetch(accum, q, 0);
	float covered = sum.a / max(params.y, 1.0);
	vec3 mean = sum.rgb / max(sum.a, 1e-6);
	if (params.z > 0.5) {
		vec4 a = texelFetch(guide_albedo, q, 0);
		mean = texelFetch(denoised, q, 0).rgb * (a.a > 0.0 ? max(a.rgb, vec3(0.02)) : vec3(1.0));
	}
	return sum.a > 0.0 ? vec4(mean, covered) : vec4(0.0);
}

// traced(q) weighed by `w` and by its share, for blending.
vec4 blended(ivec2 q, float w) {
	vec4 t = traced(q);
	return vec4(t.rgb * t.a, t.a) * w;
}

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	vec3 under = texelFetch(view_color, px, 0).rgb;
	vec4 t;
	if (params.w < 0.5) {
		t = traced(px);
	} else {
		ivec2 hi = textureSize(accum, 0) - 1;
		vec2 at = gl_FragCoord.xy / vec2(textureSize(view_color, 0)) * vec2(hi + 1) - 0.5;
		ivec2 q = ivec2(floor(at));
		vec2 f = at - vec2(q);
		t = blended(clamp(q, ivec2(0), hi), (1.0 - f.x) * (1.0 - f.y)) + blended(clamp(q + ivec2(1, 0), ivec2(0), hi), f.x * (1.0 - f.y))
		  + blended(clamp(q + ivec2(0, 1), ivec2(0), hi), (1.0 - f.x) * f.y) + blended(clamp(q + ivec2(1, 1), ivec2(0), hi), f.x * f.y);
		if (t.a > 0.0) t.rgb /= t.a;
	}
#ifdef LINEAR_OUT
	// For the finishing stack (finish.frag): the exposed light itself, with the viewport's
	// own image under it brought back to the light it shows, so the curve and the glow
	// work on the traced light as it is.
	vec3 below = neutral_inverse(srgb_decode(under));
	vec3 shown = t.a > 0.0 ? t.rgb * exp2(params.x) : below;
	out_color = vec4(mix(below, shown, clamp(t.a, 0.0, 1.0)), 1.0);
#else
	vec3 shown = t.a > 0.0 ? display_color(t.rgb, params.x) : under;
	out_color = vec4(mix(under, shown, clamp(t.a, 0.0, 1.0)), 1.0);
#endif
}
