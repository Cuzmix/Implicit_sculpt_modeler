#version 450
// Adds one traced sample (studio_trace.comp's `visible`) to the studio render's
// accumulation target, in the gather's encoding (studio_gather.frag) so the composite
// reads both alike: an ambient sample, cosine-weighted already, adds (visible, 1) to red
// and green; a key light sample adds (visible, 1) to blue and alpha. The background adds
// nothing.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D visible;
layout(set = 2, binding = 1) uniform sampler2D view_depth;

layout(set = 3, binding = 0) uniform Add_Uniforms {
	vec4 params; // x: 1 for a key light sample
};

layout(location = 0) out vec4 out_sample;

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	if (texelFetch(view_depth, px, 0).r >= 1.0) {
		out_sample = vec4(0.0);
		return;
	}
	float v = texelFetch(visible, px, 0).r;
	out_sample = params.x > 0.5 ? vec4(0.0, 0.0, v, 1.0) : vec4(v, 1.0, 0.0, 0.0);
}
