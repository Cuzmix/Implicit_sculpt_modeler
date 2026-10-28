// The full-screen triangle clear.vert.slang draws, passing each pixel its place in
// normalized device coordinates, which the floor grid's fragment stage unprojects into a ray.
struct Vertex_Out {
	float4 position : SV_Position;
	[[vk::location(0)]] float2 ndc : TEXCOORD0;
};

Vertex_Out main(uint vertex : SV_VulkanVertexID) {
	int i = int(vertex);
	float2 p = float2((i << 1) & 2, i & 2) * 2.0 - 1.0;
	Vertex_Out o;
	o.ndc = p;
	o.position = float4(p, 1.0, 1.0);
	return o;
}
