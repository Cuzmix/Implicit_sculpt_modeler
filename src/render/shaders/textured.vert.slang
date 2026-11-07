// A textured mesh's vertex (render.Textured_Vertex): one interleaved buffer for the UV and
// the tangent the maps need. It writes everything mesh.vert.slang does, so the shared
// fragment body reads the same inputs.
//
// A pulled mesh (skin.x 1, render.Textured_Mesh.slot_vertex) takes each slot's position,
// normal, mask and paint from its level's own buffers through the slot's vertex, so a
// stroke shows on it as it is made with nothing gathered again; its tangent is squared to
// the live normal. Otherwise (a Peel moves the slots, or the device cannot read the
// level's buffers here) the interleaved position and normal stand, with no paint.
#define TEXTURED 1
#include "mesh_io.slang"

// Smooth blend's pages, read for a pulled mesh, whose slots name the level's vertices.
#define BLEND_TABLE_BINDING 5
#define BLEND_PAGES_BINDING 6
#define BLEND_NORMALS 1
#include "blend_pages.slang"

// Per slot, the level's vertex it stands for; then the level's positions (three floats a
// vertex, packed), packed normals, paint (render.Paint_Packed) and painted roughness and
// metal (paint_material.slang). One-word dummies while not pulled.
[[vk::binding(0, 0)]] StructuredBuffer<uint> slot_vertex;
[[vk::binding(1, 0)]] StructuredBuffer<float> positions;
[[vk::binding(2, 0)]] StructuredBuffer<uint> normals;
[[vk::binding(3, 0)]] StructuredBuffer<uint2> paint;
[[vk::binding(4, 0)]] StructuredBuffer<uint> paint_material_words;

// The sRGB curve back to linear light (IEC 61966-2-1), for the polypaint bytes.
float3 srgb_decode(float3 c) {
	return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c));
}

Mesh_Vertex_Out main(
	[[vk::location(0)]] float3 in_position : POSITION,
	// Octahedral with the mask in the low bits, see geom.oct_encode_masked.
	[[vk::location(1)]] float2 in_normal_oct : NORMAL,
	[[vk::location(2)]] float4 in_tangent : TANGENT, // xyz unit, w the bitangent's side
	[[vk::location(3)]] float2 in_uv : TEXCOORD0,
	uint slot : SV_VulkanVertexID) {
	Mesh_Vertex_Out o;
	float3 position = in_position;
	float2 normal_oct = in_normal_oct;
	float3 tangent = in_tangent.xyz;
	o.v.paint = float4(0.0);
	o.v.material = float4(0.0);
	uint v = 0u;
	if (skin.x != 0u) {
		v = slot_vertex[slot];
		position = float3(positions[3u * v], positions[3u * v + 1u], positions[3u * v + 2u]);
		uint packed = normals[v];
		// The two signed 16-bit halves as SHORT2_NORM reads them.
		normal_oct = max(float2(int2(int(packed << 16) >> 16, int(packed) >> 16)) / 32767.0, float2(-1.0));
		if (options.x > 0.5) {
			float4 p = unpackUnorm4x8ToFloat(paint[v].x);
			o.v.paint = float4(srgb_decode(p.rgb), p.a);
			if (options.w > 0.5) o.v.material = paint_material(paint_material_words[v]);
		}
	}
	float3 in_normal;
	decode_normal_mask(normal_oct, in_normal, o.v.mask);
	if (skin.x != 0u) blend_apply(v, position, in_normal);
	if (skin.x != 0u) {
		// Squared to the normal as it is now, which sculpting turns from the one the tangent
		// was made with.
		float3 t = tangent - in_normal * dot(in_normal, tangent);
		if (dot(t, t) > 1e-12) tangent = normalize(t);
	}
	o.v.group = float3(-1.0);
	o.v.slot = 0u;
	float4 world = mul(float4(position, 1.0), model);
	o.position = mul(world, view_proj);
	// The turn into view space without the object's scale, so the normal and tangent keep
	// the unit lengths the bake read them with, and their cross product the bitangent's.
	float3x3 turn = mul((float3x3)model, (float3x3)view);
	turn /= length(turn[0]);
	o.v.view_normal = mul(in_normal, turn);
	o.v.view_tangent = float4(mul(tangent, turn), in_tangent.w < 0.0 ? -1.0 : 1.0);
	o.v.view_pos = mul(world, view).xyz;
	o.v.mesh_pos = position;
	o.v.uv = in_uv;
	return o;
}
