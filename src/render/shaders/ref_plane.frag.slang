// A reference picture on its plane, unlit: the photo keeps its own colours whatever the
// lights and the material, as Blender's and ZBrush's image planes do. The picture is
// already in display values, as the viewport's colour is, so it is written as it is,
// at the plane's opacity, blended over what is behind it.

// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
[[vk::binding(0, 2)]] Sampler2D picture;

[[vk::binding(0, 3)]] cbuffer Ref_Plane_Look {
	float4 look; // x: the opacity
};

float4 main([[vk::location(0)]] float2 uv : TEXCOORD0) : SV_Target0 {
	float4 s = picture.Sample(uv);
	return float4(s.rgb, s.a * look.x);
}
