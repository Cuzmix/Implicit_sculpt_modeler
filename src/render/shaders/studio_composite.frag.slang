// The studio render shown: the viewport image darkened by the ambient occlusion and the
// key light's shadow the gather samples have built up so far.
[[vk::binding(0, 2)]] Sampler2D view_color;
[[vk::binding(1, 2)]] Sampler2D accum;

[[vk::binding(0, 3)]] cbuffer Composite_Uniforms {
	float4 params; // x: ambient occlusion strength, y: shadow strength
};

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	float4 color = view_color.Load(int3(px, 0));
	float4 a = accum.Load(int3(px, 0));
	float ao = a.g > 0.0 ? a.r / a.g : 1.0;
	float lit = a.a > 0.0 ? a.b / a.a : 1.0;
	// Occlusion deepens toward crevices; a soft curve keeps open surfaces untouched.
	float shade = lerp(1.0, ao * ao * (3.0 - 2.0 * ao), params.x) * lerp(1.0, lit, params.y);
	return float4(color.rgb * shade, color.a);
}
