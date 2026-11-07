// The sculpt mesh's vertex: position, the normal and mask packed together, and per vertex
// paint and polygroup from a storage buffer. skin.vert.slang compiles the same body with
// SKINNED, pulling the vertex from storage buffers instead (a triangle's number is then its
// first index position over three).
#include "mesh_io.slang"

#if !defined(SKINNED) && !defined(SKIN_TESS)
// Smooth blend's pages move the plain mesh's vertices; a mesh with a detail skin pauses
// the row (its skin draws some chunks as their own grid), so the skinned stages read none.
#define BLEND_TABLE_BINDING 2
#define BLEND_PAGES_BINDING 3
#define BLEND_NORMALS 1
#include "blend_pages.slang"
#endif

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

#ifdef SKINNED
// The mesh's index, position and packed normal buffers, read by place: the draw is not
// indexed, so the vertex number is the index's position (render.Mesh_Buffers).
[[vk::binding(1, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(2, 0)]] StructuredBuffer<float> positions; // three floats a vertex, packed
[[vk::binding(3, 0)]] StructuredBuffer<uint> normals;    // render.Normal_Packed, x in the low half
// Per vertex: its painted roughness and metal (paint_material.slang); a one-word dummy
// while the mesh has none, which options.w says.
[[vk::binding(4, 0)]] StructuredBuffer<uint> paint_material_words;

Mesh_Vertex_Out main(uint corner : SV_VulkanVertexID) {
	uint tri = corner / 3u;
	uint vertex = indices[corner];
	float3 in_position = float3(positions[3u * vertex], positions[3u * vertex + 1u], positions[3u * vertex + 2u]);
	uint packed = normals[vertex];
	// The two signed 16-bit halves as SHORT2_NORM reads them.
	float2 in_normal_oct = max(float2(int2(int(packed << 16) >> 16, int(packed) >> 16)) / 32767.0, float2(-1.0));
#elif defined(SKIN_TESS)
// The mesh's index, position and packed normal buffers as SKINNED reads them, and the
// detail skin's samples: their normals (octahedral, two signed 16-bit halves), each
// triangle's record (sculpt.sculptor_skin_tris) and their heights, two halves a word
// (sample 2k in the low half).
[[vk::binding(1, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(2, 0)]] StructuredBuffer<float> positions;
[[vk::binding(3, 0)]] StructuredBuffer<uint> normals;
[[vk::binding(4, 0)]] StructuredBuffer<uint> skin_normals;
[[vk::binding(5, 0)]] StructuredBuffer<uint4> skin_tris;
[[vk::binding(6, 0)]] StructuredBuffer<uint> skin_heights;
[[vk::binding(7, 0)]] StructuredBuffer<uint> paint_material_words;

float3 mesh_point(uint v) {
	return float3(positions[3u * v], positions[3u * v + 1u], positions[3u * v + 2u]);
}

void mesh_normal_mask(uint v, out float3 n, out float mask) {
	uint packed = normals[v];
	decode_normal_mask(max(float2(int2(int(packed << 16) >> 16, int(packed) >> 16)) / 32767.0, float2(-1.0)), n, mask);
}

// A half-precision float from its 16 bits, worked out by hand: the half type needs a
// capability not every device has.
float half_bits(uint h) {
	uint e = (h >> 10u) & 31u;
	float m = float(h & 1023u);
	float v = e == 0u ? m * exp2(-24.0) : (1.0 + m / 1024.0) * exp2(float(e) - 15.0);
	return (h & 0x8000u) != 0u ? -v : v;
}

float3 octahedral(uint p) {
	return oct_decode(max(float2(int2(int(p << 16) >> 16, int(p) >> 16)) / 32767.0, float2(-1.0)));
}

// A triangle drawn as the skin's grid of small ones (skin_tess.vert.slang), each vertex at
// the point the skin shows (sculpt.sculptor_skin_mesh): its flat point, worked out along an
// edge from the edge's owner as sculpt.skin_base does so neighbours meet exactly, plus the
// curved base (sculpt.skin_curve), plus its height along the interpolated normal. The draw
// is not indexed: 3 S^2 vertices a triangle, the small triangles row by row from the first
// edge, each row's upward one after each downward one but the last.
Mesh_Vertex_Out main(uint id : SV_VulkanVertexID) {
	uint S = skin.x, V = skin.y, E = skin.z;
	uint per = 3u * S * S;
	uint tri = id / per;
	uint small = (id - tri * per) / 3u;
	uint c = id - tri * per - 3u * small;
	uint j = 0u, first = 0u;
	while (first + 2u * (S - j) - 1u <= small) {
		first += 2u * (S - j) - 1u;
		j++;
	}
	uint q = small - first;
	uint i = q >> 1u;
	uint gi, gj;
	if ((q & 1u) == 0u) {
		gi = i + (c == 1u ? 1u : 0u);
		gj = j + (c == 2u ? 1u : 0u);
	} else {
		gi = c == 2u ? i : i + 1u;
		gj = c == 0u ? j : j + 1u;
	}
	uint3 v = uint3(indices[3u * tri], indices[3u * tri + 1u], indices[3u * tri + 2u]);
	uint4 rec = skin_tris[tri];
	float3 P[3] = { mesh_point(v.x), mesh_point(v.y), mesh_point(v.z) };
	float3 N[3];
	float M[3];
	mesh_normal_mask(v.x, N[0], M[0]);
	mesh_normal_mask(v.y, N[1], M[1]);
	mesh_normal_mask(v.z, N[2], M[2]);
	float fS = float(S);
	float3 w = float3(1.0 - float(gi) / fS - float(gj) / fS, float(gi) / fS, float(gj) / fS);
	float3 b = float3(0.0), nb = float3(0.0);
	uint a = 3u, e = 0u, k = 0u;
	if (gi == 0u && gj == 0u) { b = P[0]; nb = N[0]; }
	else if (gi == S) { b = P[1]; nb = N[1]; }
	else if (gj == S) { b = P[2]; nb = N[2]; }
	else if (gj == 0u) { a = 0u; e = rec.x; k = gi; }
	else if (gi + gj == S) { a = 1u; e = rec.y; k = gj; }
	else if (gi == 0u) { a = 2u; e = rec.z; k = S - gj; }
	else {
		b = P[0] * w.x + P[1] * w.y + P[2] * w.z;
		nb = N[0] * w.x + N[1] * w.y + N[2] * w.z;
	}
	if (a < 3u) {
		// The edge runs from corner a to the next; its owner may run it the other way.
		uint from = a, to = (a + 1u) % 3u, along = k;
		if ((e & 1u) == 1u) {
			from = to;
			to = a;
			along = S - k;
		}
		float f = float(along) / fS;
		b = P[from] + (P[to] - P[from]) * f;
		nb = N[from] + (N[to] - N[from]) * f;
	}
	float3 nu = normalize(nb);
	float3 curved = float3(0.0);
	for (uint m = 0u; m < 3u; m++) curved += (b - N[m] * dot(b - P[m], N[m])) * w[m];
	uint x = skin_index(gi, gj, S, V, E, tri, v, rec.xyz);
	float h = half_bits((skin_heights[x >> 1u] >> (16u * (x & 1u))) & 0xffffu);
	float3 in_position = b + nu * (dot(curved - b, nu) + h);
	Mesh_Vertex_Out o;
	float3 in_normal = octahedral(skin_normals[x]);
	o.v.mask = M[0] * w.x + M[1] * w.y + M[2] * w.z;
	// Paint mixes between the corners; the group and its slot are the lead corner's, as
	// the triangle drawn whole takes them.
	uint lead = v[rec.w & 3u];
	o.v.paint = float4(0.0);
	o.v.material = float4(0.0);
	o.v.group = float3(-1.0);
	o.v.slot = 0u;
	if (options.x > 0.5) {
		for (uint m = 0u; m < 3u; m++) {
			float4 p = unpackUnorm4x8ToFloat(paint[v[m]].x);
			o.v.paint += float4(srgb_decode(p.rgb), p.a) * w[m];
			if (options.w > 0.5) o.v.material += paint_material(paint_material_words[v[m]]) * w[m];
		}
	}
	if (options.y > 0.5 || options.z > 0.5) {
		uint group = paint[lead].y & 0xffffu;
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
#else
// Per vertex: its painted roughness and metal (paint_material.slang); a one-word dummy
// while the mesh has none, which options.w says.
[[vk::binding(1, 0)]] StructuredBuffer<uint> paint_material_words;

Mesh_Vertex_Out main(
	[[vk::location(0)]] float3 in_position : POSITION,
	// Octahedral with the mask in the low bits, see geom.oct_encode_masked.
	[[vk::location(1)]] float2 in_normal_oct : NORMAL,
#ifdef WIRE_BARY
	uint instance : SV_VulkanInstanceID,
#endif
	uint vertex : SV_VulkanVertexID) {
#endif
#ifndef SKIN_TESS
	Mesh_Vertex_Out o;
	float3 in_normal;
	decode_normal_mask(in_normal_oct, in_normal, o.v.mask);
#ifdef BLEND_TABLE_BINDING
	blend_apply(vertex, in_position, in_normal);
#endif
	o.v.paint = float4(0.0);
	o.v.material = float4(0.0);
	o.v.group = float3(-1.0);
	o.v.slot = 0u;
	if (options.x > 0.5 || options.y > 0.5 || options.z > 0.5) {
		uint2 p = paint[vertex];
		uint group = p.y & 0xffffu;
		if (options.x > 0.5) {
			o.v.paint = float4(srgb_decode(unpackUnorm4x8ToFloat(p.x).rgb), unpackUnorm4x8ToFloat(p.x).a);
			if (options.w > 0.5) o.v.material = paint_material(paint_material_words[vertex]);
		}
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
#ifdef SKINNED
	uint k = corner - 3u * tri;
	o.v.bary = float3(k == 0u ? 1.0 : 0.0, k == 1u ? 1.0 : 0.0, k == 2u ? 1.0 : 0.0);
	o.v.skin_tri = uint4(tri, indices[3u * tri], indices[3u * tri + 1u], indices[3u * tri + 2u]);
	float3x3 turn = mul((float3x3)model, (float3x3)view);
	o.v.turn_x = turn[0];
	o.v.turn_y = turn[1];
	o.v.turn_z = turn[2];
	o.v.skin_meta = skin;
#endif
#ifdef WIRE_BARY
	o.v.tri_base = instance;
#endif
	return o;
}
#endif
