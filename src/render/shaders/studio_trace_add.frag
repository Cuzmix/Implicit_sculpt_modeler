#version 450
#extension GL_GOOGLE_include_directive : require
// Adds one traced sample (studio_trace.comp's `visible`) to the studio render's
// accumulation target, in the gather's encoding (studio_gather.frag) so the composite
// reads both alike: an ambient sample, cosine-weighted already, adds (visible, 1) to red
// and green; a light sample adds (visible, 1) times its light's weight plus the ambient
// light's, which nothing shadows, to blue and alpha (studio_weight.glsl). The background
// adds nothing.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D visible;
layout(set = 2, binding = 1) uniform sampler2D view_depth;

layout(set = 3, binding = 0) uniform Add_Uniforms {
	mat4 inv_view_proj; // viewport clip space back to the world
	vec4 params;        // x: 1 for a light sample
	vec4 shadow_pos[8];
	vec4 shadow_shape[8];
	vec4 shadow_spot[8];
	vec4 shadow_pick;
};

layout(location = 0) out vec4 out_sample;

vec3 world_at(vec2 frag, float depth, vec2 size) {
	vec2 uv = frag / size;
	vec4 w = inv_view_proj * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
	return w.xyz / w.w;
}

#include "studio_weight.glsl"

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	float d = texelFetch(view_depth, px, 0).r;
	if (d >= 1.0) {
		out_sample = vec4(0.0);
		return;
	}
	float v = texelFetch(visible, px, 0).r;
	if (params.x < 0.5) {
		out_sample = vec4(v, 1.0, 0.0, 0.0);
		return;
	}
	// A pixel no light reaches shows unshadowed.
	vec2 size = vec2(textureSize(view_depth, 0));
	vec3 p = world_at(gl_FragCoord.xy, d, size);
	vec2 weight = shadow_weight(p, depth_normal(view_depth, px, gl_FragCoord.xy, d, p, size));
	if (weight.x < 0.0) {
		out_sample = vec4(0.0, 0.0, 1.0, 1.0);
		return;
	}
	out_sample = vec4(0.0, 0.0, v * weight.x + weight.y, weight.x + weight.y);
}
