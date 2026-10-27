#version 450
#extension GL_GOOGLE_include_directive : require
// One sample of the studio render: for every viewport pixel on a surface, whether a
// light from `light_dir` reaches it past everything in the shadow map, added to the
// accumulation target (blending adds). Ambient occlusion samples come from directions
// all round the scene and add (visibility * cos, cos) to red and green; light samples,
// jittered around the light the sample picked, add (visibility, 1) times the light's
// weight plus the ambient light's, which nothing shadows, to blue and alpha
// (studio_weight.glsl).
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D view_depth;
layout(set = 2, binding = 1) uniform sampler2D shadow_depth;

layout(set = 3, binding = 0) uniform Gather_Uniforms {
	mat4 inv_view_proj;   // viewport clip space back to the world
	mat4 light_view_proj; // world to the shadow map's clip space
	vec4 light_dir;       // xyz: toward the light (world, unit); w: 1 for a key light sample
	vec4 params;          // x: depth bias, y: normal offset (world), z: shadow map texel (uv)
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
	vec2 size = vec2(textureSize(view_depth, 0));
	ivec2 px = ivec2(gl_FragCoord.xy);
	float d = texelFetch(view_depth, px, 0).r;
	if (d >= 1.0) {
		out_sample = vec4(0.0);
		return;
	}
	vec3 p = world_at(gl_FragCoord.xy, d, size);
	vec3 n = depth_normal(view_depth, px, gl_FragCoord.xy, d, p, size);

	vec3 l = light_dir.xyz;
	float cosine = dot(n, l);
	bool key = light_dir.w > 0.5;
	// A sample counts by how much of the pixel's light its light gives; where no light
	// reaches, the pixel shows unshadowed.
	vec2 weight = vec2(0.0);
	if (key) {
		weight = shadow_weight(p, n);
		if (weight.x < 0.0) {
			out_sample = vec4(0.0, 0.0, 1.0, 1.0);
			return;
		}
	}
	if (cosine <= 0.0) {
		// Facing away: no light from here, which the viewport's shading already shows
		// for the light this sample picked.
		out_sample = key ? vec4(0.0, 0.0, 1.0, 1.0) * (weight.x + weight.y) : vec4(0.0);
		return;
	}
	vec4 c = light_view_proj * vec4(p + n * params.y, 1.0);
	vec3 s = c.xyz / c.w;
	vec2 uv = vec2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
	float lit = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float occluder = texture(shadow_depth, uv + vec2(x, y) * params.z).r;
			lit += s.z - params.x <= occluder ? 1.0 : 0.0;
		}
	}
	lit /= 9.0;
	out_sample = key ? vec4(0.0, 0.0, lit * weight.x + weight.y, weight.x + weight.y) : vec4(lit * cosine, cosine, 0.0, 0.0);
}
