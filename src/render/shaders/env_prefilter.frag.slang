// One level of the prefiltered environment (render/environment.odin): every texel the
// panorama as a GGX lobe of `params.x` roughness sees it around the texel's direction,
// with the eye along it (N = V = R, as the split sum assumes). 64 Hammersley samples, each
// read from the source's mip whose texels match the sample's solid angle (filtered
// importance sampling, Colbert and Krivanek 2007), so few samples show no fireflies. A
// fixed sequence, so the same file always gives the same texture.
#include "panorama.slang"

// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
[[vk::binding(0, 2)]] Sampler2D source;
[[vk::binding(0, 3)]] cbuffer Prefilter_Uniforms {
	float4 params; // x: roughness (0 to 1), y: the source's width, z: its height
	float4 target; // xy: this level's width and height, z: the source mip a mirror reads
};

static const uint SAMPLES = 64u;

float2 hammersley(uint i) {
	return float2(float(i) / float(SAMPLES), float(reversebits(i)) * 2.3283064e-10);
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	float2 uv = frag_coord.xy / target.xy;
	float rough = params.x;
	if (rough <= 0.0) {
		return float4(source.SampleLevel(uv, target.z).rgb, 1.0);
	}
	float3 n = panorama_dir(uv);
	float3 up = abs(n.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
	float3 t = normalize(cross(up, n));
	float3 b = cross(n, t);
	float a = rough * rough;
	float a2 = a * a;
	// A source texel's mean solid angle: the panorama's 4 pi over its texels (an equator
	// texel is a little larger, one near a pole much smaller, so the poles read a finer mip
	// than they need, at the cost of a little noise there).
	float texel = 12.5663706 / (params.y * params.z);
	float3 sum = float3(0.0);
	float weight = 0.0;
	for (uint i = 0u; i < SAMPLES; i++) {
		float2 xi = hammersley(i);
		float phi = 6.28318531 * xi.x;
		float cos_t = sqrt((1.0 - xi.y) / (1.0 + (a2 - 1.0) * xi.y));
		float sin_t = sqrt(max(1.0 - cos_t * cos_t, 0.0));
		float3 h = t * (sin_t * cos(phi)) + b * (sin_t * sin(phi)) + n * cos_t;
		float3 l = 2.0 * dot(n, h) * h - n;
		float n_dot_l = dot(n, l);
		if (n_dot_l <= 0.0) continue;
		// With N = V the sample's density is D / 4; its share of the sphere picks the mip.
		float d = cos_t * cos_t * (a2 - 1.0) + 1.0;
		float pdf = a2 / (3.14159265 * d * d) / 4.0;
		float lod = max(0.5 * log2(1.0 / (float(SAMPLES) * pdf * texel)) + 1.0, 0.0);
		sum += source.SampleLevel(panorama_uv(l), lod).rgb * n_dot_l;
		weight += n_dot_l;
	}
	return float4(sum / max(weight, 1e-6), 1.0);
}
