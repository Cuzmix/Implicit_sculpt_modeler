// GPU culling of one object's chunks for one pass (render/gpu_cull.odin): the same tests
// as geom.cull_chunks_grouped, a group of geom.CHUNK_GROUP chunks first, then each chunk
// of a group that passes, written as indirect draw commands that keep the chunks' order.
// Two kernels share it: cull_count.comp.slang counts each group's visible chunks, and
// cull_write.comp.slang writes each group's commands after the groups before it, so the
// commands come out in the order the CPU's runs would, on every run.
//
// A chunk record is geom.Chunk as the CPU keeps it, twelve words: bounds lo and hi,
// cone axis and cutoff, first index and index count.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers.

[[vk::binding(0, 0)]] StructuredBuffer<uint> chunks;
[[vk::binding(1, 0)]] StructuredBuffer<uint> groups; // geom.chunk_group of each group, as a chunk record

[[vk::binding(0, 2)]] cbuffer Cull_Uniforms {
	float4 planes[6]; // geom.frustum_planes of the pass, in the object's space
	float4 eye;       // xyz: the eye in the object's space
	uint4 counts;     // x: chunks, y: groups
};

static const uint GROUP = 64; // geom.CHUNK_GROUP

struct Record {
	float3 lo, hi, axis;
	float cutoff;
	uint first_index, index_count;
};

Record chunk_record(uint c) {
	uint b = 12u * c;
	Record r;
	r.lo = asfloat(uint3(chunks[b], chunks[b + 1u], chunks[b + 2u]));
	r.hi = asfloat(uint3(chunks[b + 3u], chunks[b + 4u], chunks[b + 5u]));
	r.axis = asfloat(uint3(chunks[b + 6u], chunks[b + 7u], chunks[b + 8u]));
	r.cutoff = asfloat(chunks[b + 9u]);
	r.first_index = chunks[b + 10u];
	r.index_count = chunks[b + 11u];
	return r;
}

Record group_record(uint g) {
	uint b = 12u * g;
	Record r;
	r.lo = asfloat(uint3(groups[b], groups[b + 1u], groups[b + 2u]));
	r.hi = asfloat(uint3(groups[b + 3u], groups[b + 4u], groups[b + 5u]));
	r.axis = asfloat(uint3(groups[b + 6u], groups[b + 7u], groups[b + 8u]));
	r.cutoff = asfloat(groups[b + 9u]);
	r.first_index = 0u;
	r.index_count = 0u;
	return r;
}

// geom.aabb_outside.
bool outside(Record r) {
	for (int i = 0; i < 6; i++) {
		float4 p = planes[i];
		float3 far = float3(p.x >= 0.0 ? r.hi.x : r.lo.x, p.y >= 0.0 ? r.hi.y : r.lo.y, p.z >= 0.0 ? r.hi.z : r.lo.z);
		if (p.x * far.x + p.y * far.y + p.z * far.z + p.w < 0.0) return true;
	}
	return false;
}

// geom.chunk_backfacing.
bool backfacing(Record r) {
	if (r.cutoff >= 1.0) return false;
	float3 center = (r.lo + r.hi) * 0.5;
	float radius = length(r.hi - r.lo) * 0.5;
	float3 to = center - eye.xyz;
	float dist = length(to);
	return dot(to, r.axis) >= r.cutoff * (dist + radius) + radius;
}

// What the group's test says of all its chunks: 0 pass, 1 outside the view, 2 facing away.
uint group_verdict(uint g) {
	Record r = group_record(g);
	if (outside(r)) return 1u;
	if (backfacing(r)) return 2u;
	return 0u;
}

// What chunk c comes to once its group passed: 0 drawn, 1 outside the view, 2 facing
// away, 3 drawn but empty (no command).
uint chunk_verdict(uint c) {
	Record r = chunk_record(c);
	if (outside(r)) return 1u;
	if (backfacing(r)) return 2u;
	return r.index_count == 0u ? 3u : 0u;
}

groupshared uint verdict;
groupshared uint4 lanes[GROUP];
