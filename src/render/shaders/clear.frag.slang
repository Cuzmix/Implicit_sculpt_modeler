// The viewport's background: one colour, a gradient, or the image environment.
#include "display.slang"
#include "panorama.slang"

// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
// The prefiltered environment (render/environment.odin), a 1 x 1 black one when none.
[[vk::binding(0, 2)]] Sampler2D environment_map;
[[vk::binding(0, 3)]] cbuffer Clear_Uniforms {
	float4 top;    // along the top edge
	float4 bottom; // along the bottom edge; equal to top for one flat colour
	float4 extent; // x: the target's height in pixels, y: its width
	// x: 1 to show the image environment, y: its strength as a factor, z: the prefiltered
	// level it shows (the Blur), w: the exposure in stops.
	float4 env;
	// From clip space into the panorama's own axes: the inverse projection, then the
	// view's turn into the panorama's.
	float4x4 clip_to_env;
};

// A 4x4 ordered dither: the same offset at the same pixel every frame, so a partial
// redraw matches the full one bit for bit.
static const float BAYER[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	// Under half an 8-bit step either way, so a gentle gradient shows no bands.
	int2 p = int2(frag_coord.xy) & 3;
	float dither = ((BAYER[p.y * 4 + p.x] + 0.5) / 16.0 - 0.5) / 255.0;
	if (env.x > 0.5) {
		// The pixel's ray from the near plane to the far one, which an orthographic view
		// points the same way everywhere (one colour), and its colour in the panorama.
		float2 ndc = float2(2.0 * frag_coord.x / extent.y - 1.0, 1.0 - 2.0 * frag_coord.y / extent.x);
		float4 a = mul(float4(ndc, 0.0, 1.0), clip_to_env);
		float4 b = mul(float4(ndc, 1.0, 1.0), clip_to_env);
		float3 d = normalize(b.xyz / b.w - a.xyz / a.w);
		float3 c = environment_map.SampleLevel(panorama_uv(d), env.z).rgb * env.y;
		return float4(display_color(c, env.w) + dither, 1.0);
	}
	if (all(top == bottom)) return top;
	// The pixel's row, from 0 at the top (SDL_GPU's framebuffer origin) to 1 at the bottom.
	float t = clamp(frag_coord.y / extent.x, 0.0, 1.0);
	return float4(lerp(top.rgb, bottom.rgb, t) + dither, lerp(top.a, bottom.a, t));
}
