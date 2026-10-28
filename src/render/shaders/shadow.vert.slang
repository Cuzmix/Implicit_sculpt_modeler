// Depth from a light's point of view, for the studio render's shadow maps.
// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
[[vk::binding(0, 1)]] cbuffer Shadow_Uniforms {
	float4x4 light_view_proj;
	float4x4 model;
};

float4 main([[vk::location(0)]] float3 position : POSITION) : SV_Position {
	return mul(float4(position, 1.0), mul(model, light_view_proj));
}
