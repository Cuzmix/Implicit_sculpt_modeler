// The interface kit's triangles: positions in physical pixels from the top-left of the
// target, texture coordinates in atlas pixels (or 0 to 1 across an image), and a colour.
struct Vertex_In {
	[[vk::location(0)]] float2 pos : POSITION;
	[[vk::location(1)]] float2 uv : TEXCOORD0;
	[[vk::location(2)]] float4 color : COLOR;
};

struct Vertex_Out {
	float4 position : SV_Position;
	[[vk::location(0)]] float2 uv : TEXCOORD0;
	[[vk::location(1)]] float4 color : COLOR;
};

// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
[[vk::binding(0, 1)]] cbuffer Ui_Vertex_Uniforms {
	// xy: the size in pixels the triangles are laid out in; zw: the cosine and sine of the
	// clockwise turn they are drawn at (1, 0 upright; a pre-rotated swapchain is turned).
	float4 target;
};

Vertex_Out main(Vertex_In v) {
	Vertex_Out o;
	o.uv = v.uv;
	o.color = v.color;
	float2 ndc = v.pos / target.xy * 2.0 - 1.0;
	float2 p = float2(ndc.x, -ndc.y);
	// Clockwise in clip space, whose y points up.
	o.position = float4(target.z * p.x + target.w * p.y, target.z * p.y - target.w * p.x, 0.0, 1.0);
	return o;
}
