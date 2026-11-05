// A reference picture on a plane in the scene (the References card's In scene): one quad
// of two triangles built from the vertex's index alone, its middle, its half-width
// across and its half-height up taken from the uniforms, so a plane needs no buffer.
// The corners' texture coordinates come in as the board shows the place, cropped,
// flipped and turned (ref_corners), in the order top left, top right, bottom right,
// bottom left. Every corner is put at the far plane's depth: drawn behind the model, it
// then shows only where no mesh is in front of the far plane, wherever the plane stands,
// so it stands through the scene's middle and keeps the model's size in a perspective
// view; drawn through the model, its depth is not tested at all.
struct Vertex_Out {
	float4 position : SV_Position;
	[[vk::location(0)]] float2 uv : TEXCOORD0;
};

// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
[[vk::binding(0, 1)]] cbuffer Ref_Plane_Uniforms {
	float4x4 view_proj;
	float4 center; // xyz: the plane's middle in the world
	float4 right;  // xyz: half its width, along the screen's right in its view
	float4 up;     // xyz: half its height, along the screen's up in its view
	float4 uv_top;    // xy: the top left corner's texture coordinates, zw: the top right's
	float4 uv_bottom; // xy: the bottom right's, zw: the bottom left's
};

Vertex_Out main(uint vertex : SV_VulkanVertexID) {
	// Two triangles: top left, top right, bottom right, then top left, bottom right, bottom left.
	const uint CORNER[6] = { 0, 1, 2, 0, 2, 3 };
	const float2 SIDE[4] = { float2(-1.0, 1.0), float2(1.0, 1.0), float2(1.0, -1.0), float2(-1.0, -1.0) };
	uint c = CORNER[vertex % 6];
	float2 s = SIDE[c];
	float3 p = center.xyz + right.xyz * s.x + up.xyz * s.y;
	float2 uvs[4] = { uv_top.xy, uv_top.zw, uv_bottom.xy, uv_bottom.zw };
	Vertex_Out o;
	o.uv = uvs[c];
	float4 clip = mul(float4(p, 1.0), view_proj);
	o.position = float4(clip.xy, clip.w, clip.w);
	return o;
}
