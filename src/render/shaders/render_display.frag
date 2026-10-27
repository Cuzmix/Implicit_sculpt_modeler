#version 450
#extension GL_GOOGLE_include_directive : require
// Shows render mode's samples (render/path.odin) over the viewport: the mean radiance of
// the samples that met the scene, exposed, tone mapped and sRGB encoded as the viewport
// is, laid over the viewport's own image by how many of them did, so the background, the
// floor grid and anything not traced show as the viewport draws them. Denoised, the mean
// is the denoiser's light (render_atrous.frag) times the colour the guides hold.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D view_color;
layout(set = 2, binding = 1) uniform sampler2D accum;
layout(set = 2, binding = 2) uniform sampler2D denoised;
layout(set = 2, binding = 3) uniform sampler2D guide_albedo;

layout(set = 3, binding = 0) uniform Display_Uniforms {
	vec4 params; // x: the exposure in stops, y: the samples summed in accum, z: 1 to show `denoised`
};

layout(location = 0) out vec4 out_color;

#include "display.glsl"

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	vec4 sum = texelFetch(accum, px, 0);
	vec3 under = texelFetch(view_color, px, 0).rgb;
	float covered = sum.a / max(params.y, 1.0);
	vec3 mean = sum.rgb / max(sum.a, 1e-6);
	if (params.z > 0.5) {
		vec4 a = texelFetch(guide_albedo, px, 0);
		mean = texelFetch(denoised, px, 0).rgb * (a.a > 0.0 ? max(a.rgb, vec3(0.02)) : vec3(1.0));
	}
	vec3 shown = sum.a > 0.0 ? display_color(mean, params.x) : under;
	out_color = vec4(mix(under, shown, clamp(covered, 0.0, 1.0)), 1.0);
}
