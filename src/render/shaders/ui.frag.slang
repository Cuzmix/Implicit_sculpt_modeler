// Glyphs and shapes take their coverage from the single-channel atlas (shapes sample its
// white corner); an image, such as the viewport, is drawn as it is, tinted by the colour.
// A filtered image drawn over a clear of nothing has its colour divided by its alpha:
// filtering averaged in the clear's black wherever it reached the edge.

// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
[[vk::binding(0, 2)]] Sampler2D tex;

[[vk::binding(0, 3)]] cbuffer Ui_Fragment_Uniforms {
	float4 params; // xy: what turns the coordinates into 0 to 1 (one over the atlas size, or 1); z: 1 for an image; w: 1 to take its colour out of its alpha
};

float4 main([[vk::location(0)]] float2 uv : TEXCOORD0, [[vk::location(1)]] float4 color : COLOR) : SV_Target0 {
	float4 s = tex.Sample(uv * params.xy);
	if (params.w > 0.5) s.rgb /= max(s.a, 1.0 / 255.0);
	return params.z > 0.5 ? color * s : float4(color.rgb, color.a * s.r);
}
