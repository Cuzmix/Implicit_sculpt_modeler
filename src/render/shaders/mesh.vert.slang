// The sculpt mesh's vertex: position, the normal and mask packed together, and per vertex
// paint and polygroup from a storage buffer.
#include "mesh_io.slang"

// Per vertex: its polypaint (sRGB red, green, blue and coverage, one byte each, red
// lowest) and the polygroup it carries (low 16 bits); see render.Mesh_Buffers.paint.
[[vk::binding(0, 0)]] StructuredBuffer<uint2> paint;

// A colour per group that neighbouring numbers keep far apart: hues a golden angle
// apart, in two lightnesses.
float3 group_color(uint g) {
	float h = frac(float(g) * 0.618034 + 0.12);
	float3 rgb = clamp(abs(frac(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	float light = (g & 1u) == 0u ? 0.75 : 0.55;
	return lerp(float3(1.0), rgb, 0.55) * light;
}

// The sRGB curve back to linear light (IEC 61966-2-1), for the polypaint bytes.
float3 srgb_decode(float3 c) {
	return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c));
}

Mesh_Vertex_Out main(
	[[vk::location(0)]] float3 in_position : POSITION,
	// Octahedral with the mask in the low bits, see geom.oct_encode_masked.
	[[vk::location(1)]] float2 in_normal_oct : NORMAL,
	uint vertex : SV_VulkanVertexID) {
	Mesh_Vertex_Out o;
	float3 in_normal;
	decode_normal_mask(in_normal_oct, in_normal, o.v.mask);
	o.v.paint = float4(0.0);
	o.v.group = float3(-1.0);
	o.v.slot = 0u;
	if (options.x > 0.5 || options.y > 0.5 || options.z > 0.5) {
		uint2 p = paint[vertex];
		uint group = p.y & 0xffffu;
		if (options.x > 0.5) o.v.paint = float4(srgb_decode(unpackUnorm4x8ToFloat(p.x).rgb), unpackUnorm4x8ToFloat(p.x).a);
		if (options.y > 0.5) o.v.group = group_color(group);
		if (options.z > 0.5) {
			for (uint k = 1u; k < 16u; k++) {
				if (slot_group[k >> 2][k & 3u] == group) o.v.slot = k;
			}
		}
	}
	float4 world = mul(float4(in_position, 1.0), model);
	o.position = mul(world, view_proj);
	o.v.view_normal = mul(in_normal, mul((float3x3)model, (float3x3)view));
	o.v.view_pos = mul(world, view).xyz;
	o.v.mesh_pos = in_position;
	return o;
}
