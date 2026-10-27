#version 450
#extension GL_GOOGLE_include_directive : require
// Shows render mode's samples (render/path.odin) over the viewport: the mean radiance of
// the samples that met the scene, exposed, tone mapped and sRGB encoded as the viewport
// is, laid over the viewport's own image by how many of them did, so the background, the
// floor grid and anything not traced show as the viewport draws them.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D view_color;
layout(set = 2, binding = 1) uniform sampler2D accum;

layout(set = 3, binding = 0) uniform Display_Uniforms {
	vec4 params; // x: the exposure in stops, y: the samples summed in accum
};

layout(location = 0) out vec4 out_color;

#include "display.glsl"

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	vec4 sum = texelFetch(accum, px, 0);
	vec3 under = texelFetch(view_color, px, 0).rgb;
	float covered = sum.a / max(params.y, 1.0);
	vec3 shown = sum.a > 0.0 ? display_color(sum.rgb / sum.a, params.x) : under;
	out_color = vec4(mix(under, shown, clamp(covered, 0.0, 1.0)), 1.0);
}
