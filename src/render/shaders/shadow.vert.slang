// Depth from a light's point of view, for the studio render's shadow maps, and the view's
// own depth (screen_pass.odin's view_depth_draw).
// SDL_GPU SPIR-V conventions: vertex storage buffers live in set 0, uniform buffers in set 1.
[[vk::binding(0, 1)]] cbuffer Shadow_Uniforms {
	float4x4 light_view_proj;
	float4x4 model;
	// x: 1 while the item's Smooth blend pages are bound (blend_pages.slang).
	uint4 blend;
};

#define BLEND_TABLE_BINDING 0
#define BLEND_PAGES_BINDING 1
#include "blend_pages.slang"

float4 main([[vk::location(0)]] float3 position : POSITION, uint vertex : SV_VulkanVertexID) : SV_Position {
	float3 p = position + asfloat(blend_entry(vertex).xyz);
	return mul(float4(p, 1.0), mul(model, light_view_proj));
}
