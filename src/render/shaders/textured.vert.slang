// A textured mesh's vertex (render.Textured_Vertex): one interleaved buffer, no paint.
// It writes everything mesh.vert.slang does, so the shared fragment body reads the same
// inputs, plus the UV and the tangent the maps need.
#define TEXTURED 1
#include "mesh_io.slang"

Mesh_Vertex_Out main(
	[[vk::location(0)]] float3 in_position : POSITION,
	// Octahedral with the mask in the low bits, see geom.oct_encode_masked.
	[[vk::location(1)]] float2 in_normal_oct : NORMAL,
	[[vk::location(2)]] float4 in_tangent : TANGENT, // xyz unit, w the bitangent's side
	[[vk::location(3)]] float2 in_uv : TEXCOORD0) {
	Mesh_Vertex_Out o;
	float3 in_normal;
	decode_normal_mask(in_normal_oct, in_normal, o.v.mask);
	o.v.paint = float4(0.0);
	o.v.group = float3(-1.0);
	o.v.slot = 0u;
	float4 world = mul(float4(in_position, 1.0), model);
	o.position = mul(world, view_proj);
	// The turn into view space without the object's scale, so the normal and tangent keep
	// the unit lengths the bake read them with, and their cross product the bitangent's.
	float3x3 turn = mul((float3x3)model, (float3x3)view);
	turn /= length(turn[0]);
	o.v.view_normal = mul(in_normal, turn);
	o.v.view_tangent = float4(mul(in_tangent.xyz, turn), in_tangent.w < 0.0 ? -1.0 : 1.0);
	o.v.view_pos = mul(world, view).xyz;
	o.v.mesh_pos = in_position;
	o.v.uv = in_uv;
	return o;
}
