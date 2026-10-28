// The studio render shown: the viewport image darkened by the ambient occlusion and the
// key light's shadow the gather samples have built up so far. While the samples are carried
// across a moving view (render/studio.odin), a pixel with fewer than a few samples is mixed
// toward `under`, live occlusion's picture where it runs, so a surface the move uncovered
// shows smooth shading rather than one sample's speckle.
[[vk::binding(0, 2)]] Sampler2D view_color;
[[vk::binding(1, 2)]] Sampler2D accum;
[[vk::binding(2, 2)]] Sampler2D under;

[[vk::binding(0, 3)]] cbuffer Composite_Uniforms {
	// x: ambient occlusion strength, y: shadow strength, z: the occlusion's cosine sum at
	// which a pixel shows its own samples alone (0: always), w: the shadows' weight at which
	// they show at full strength
	float4 params;
};

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	float4 color = view_color.Load(int3(px, 0));
	float4 a = accum.Load(int3(px, 0));
	float ao = a.g > 0.0 ? a.r / a.g : 1.0;
	float lit = a.a > 0.0 ? a.b / a.a : 1.0;
	// Carried, a shadow of one or two samples (lights fixed to the camera build theirs again
	// after every turn) fades in rather than showing as speckle.
	if (params.z > 0.0) lit = lerp(1.0, lit, saturate(a.a / params.w));
	// Occlusion deepens toward crevices; a soft curve keeps open surfaces untouched.
	float shade = lerp(1.0, ao * ao * (3.0 - 2.0 * ao), params.x) * lerp(1.0, lit, params.y);
	if (params.z <= 0.0) return float4(color.rgb * shade, color.a);
	float settled = saturate(a.g / params.z);
	return float4(lerp(under.Load(int3(px, 0)).rgb, color.rgb * shade, settled), color.a);
}
