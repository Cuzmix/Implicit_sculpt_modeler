// What mesh.vert.slang and textured.vert.slang hand the shared fragment body
// (mesh_shading.slang), and the decoding both vertex stages share: an include, never
// compiled alone.

// The per-frame uniforms of both mesh vertex stages. SDL_GPU SPIR-V conventions: vertex
// storage buffers live in set 0, uniform buffers in set 1.
[[vk::binding(0, 1)]] cbuffer Frame_Uniforms {
	float4x4 view_proj;
	float4x4 view;
	float4x4 model; // rotation, translation and uniform scale only, so it also transforms normals
	float4 options; // x: 1 to show the paint, y: 1 to show the polygroups, z: 1 to look up material slots (all read `paint`)
	// Slot k's polygroup in component k & 3 of element k >> 2 (render.Material_Slots), from
	// slot 1; 0xffffffff for an unused slot.
	uint4 slot_group[4];
};

struct Mesh_Varyings {
	[[vk::location(0)]] float3 view_normal : NORMAL;
	[[vk::location(1)]] float3 view_pos : POSITION1;
	[[vk::location(2)]] float mask : MASK; // 0 unmasked to 1 fully masked
	[[vk::location(3)]] float4 paint : COLOR; // linear colour, and how much it covers the clay
	// The triangle's polygroup colour, from the corner it is drawn from; negative for none.
	[[vk::location(4)]] nointerpolation float3 group : GROUP;
	// Where the vertex is in the mesh's own space, for the density preview's checker.
	[[vk::location(5)]] float3 mesh_pos : POSITION2;
	// The material slot of the triangle's polygroup, from the corner it is drawn from (the
	// one carrying its group); 0 for the item's own material.
	[[vk::location(6)]] nointerpolation uint slot : SLOT;
#ifdef TEXTURED
	[[vk::location(7)]] float2 uv : TEXCOORD0;
	[[vk::location(8)]] float4 view_tangent : TANGENT;
#endif
};

struct Mesh_Vertex_Out {
	float4 position : SV_Position;
	Mesh_Varyings v;
};

float3 oct_decode(float2 e) {
	float3 v = float3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) v.xy = (1.0 - abs(e.yx)) * float2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
	return normalize(v);
}

// The octahedral normal and the mask packed with it (geom.oct_encode_masked): back to the
// stored 16-bit integers, whose top 12 bits are the normal and the low 4 bits of each
// half the mask.
void decode_normal_mask(float2 normal_oct, out float3 normal, out float mask) {
	int2 raw = int2(round(max(normal_oct, float2(-1.0)) * 32767.0));
	normal = oct_decode(float2(raw & ~15) / 32767.0);
	mask = float(((raw.x & 15) << 4) | (raw.y & 15)) / 255.0;
}
