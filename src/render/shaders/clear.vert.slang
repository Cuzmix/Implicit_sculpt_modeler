// Full-screen triangle at the far plane, for clearing a scissored part of the
// viewport (render passes can only clear the whole target).
float4 main(uint vertex : SV_VulkanVertexID) : SV_Position {
	int i = int(vertex);
	float2 p = float2((i << 1) & 2, i & 2);
	return float4(p * 2.0 - 1.0, 1.0, 1.0);
}
