#version 450
#extension GL_GOOGLE_include_directive : require
// One level of the prefiltered environment (render/environment.odin): every texel the
// panorama as a GGX lobe of `params.x` roughness sees it around the texel's direction,
// with the eye along it (N = V = R, as the split sum assumes). 64 Hammersley samples, each
// read from the source's mip whose texels match the sample's solid angle (filtered
// importance sampling, Colbert and Krivanek 2007), so few samples show no fireflies. A
// fixed sequence, so the same file always gives the same texture.
#include "panorama.glsl"

// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D source;
layout(set = 3, binding = 0) uniform Prefilter_Uniforms {
	vec4 params; // x: roughness (0 to 1), y: the source's width, z: its height
	vec4 target; // xy: this level's width and height, z: the source mip a mirror reads
};

layout(location = 0) out vec4 out_color;

const uint SAMPLES = 64u;

vec2 hammersley(uint i) {
	return vec2(float(i) / float(SAMPLES), float(bitfieldReverse(i)) * 2.3283064e-10);
}

void main() {
	vec2 uv = gl_FragCoord.xy / target.xy;
	float rough = params.x;
	if (rough <= 0.0) {
		out_color = vec4(textureLod(source, uv, target.z).rgb, 1.0);
		return;
	}
	vec3 n = panorama_dir(uv);
	vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t = normalize(cross(up, n));
	vec3 b = cross(n, t);
	float a = rough * rough;
	float a2 = a * a;
	// A source texel's solid angle at the equator: the panorama's 4 pi over its texels.
	float texel = 12.5663706 / (params.y * params.z);
	vec3 sum = vec3(0.0);
	float weight = 0.0;
	for (uint i = 0u; i < SAMPLES; i++) {
		vec2 xi = hammersley(i);
		float phi = 6.28318531 * xi.x;
		float cos_t = sqrt((1.0 - xi.y) / (1.0 + (a2 - 1.0) * xi.y));
		float sin_t = sqrt(max(1.0 - cos_t * cos_t, 0.0));
		vec3 h = t * (sin_t * cos(phi)) + b * (sin_t * sin(phi)) + n * cos_t;
		vec3 l = 2.0 * dot(n, h) * h - n;
		float n_dot_l = dot(n, l);
		if (n_dot_l <= 0.0) continue;
		// With N = V the sample's density is D / 4; its share of the sphere picks the mip.
		float d = cos_t * cos_t * (a2 - 1.0) + 1.0;
		float pdf = a2 / (3.14159265 * d * d) / 4.0;
		float lod = max(0.5 * log2(1.0 / (float(SAMPLES) * pdf * texel)) + 1.0, 0.0);
		sum += textureLod(source, panorama_uv(l), lod).rgb * n_dot_l;
		weight += n_dot_l;
	}
	out_color = vec4(sum / max(weight, 1e-6), 1.0);
}
