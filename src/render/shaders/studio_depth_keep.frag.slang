// Keeps this frame's depth for the studio render's next reprojection (studio_reproject.frag.slang):
// the depth buffer's value as it is, in a colour target a later frame can read beside the
// next frame's depth.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2.
[[vk::binding(0, 2)]] Sampler2D view_depth;

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	return float4(view_depth.Load(int3(int2(frag_coord.xy), 0)).r, 0.0, 0.0, 0.0);
}
