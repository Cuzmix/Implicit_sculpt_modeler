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
	float4 target; // xy: the target's size in pixels
};

Vertex_Out main(Vertex_In v) {
	Vertex_Out o;
	o.uv = v.uv;
	o.color = v.color;
	float2 ndc = v.pos / target.xy * 2.0 - 1.0;
	o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
	return o;
}
