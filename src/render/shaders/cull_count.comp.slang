// vulkan only: GPU culling's first kernel (cull.slang), a workgroup a group of chunks:
// each group's drawn chunks, their triangles, and the chunks left out of the view and
// facing away, into `totals`, which cull_write.comp.slang reads.
#include "cull.slang"

[[vk::binding(0, 1)]] RWStructuredBuffer<uint4> totals;

[numthreads(64, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint g = group_id.x, i = local_id.x, c = g * GROUP + i;
	if (i == 0u) verdict = group_verdict(g);
	GroupMemoryBarrierWithGroupSync();
	uint4 mine = uint4(0u);
	if (c < counts.x) {
		uint v = verdict != 0u ? verdict : chunk_verdict(c);
		if (v == 0u) mine = uint4(1u, chunk_record(c).index_count / 3u, 0u, 0u);
		else if (v == 1u) mine.z = 1u;
		else if (v == 2u) mine.w = 1u;
	}
	lanes[i] = mine;
	GroupMemoryBarrierWithGroupSync();
	if (i == 0u) {
		uint4 sum = uint4(0u);
		for (uint k = 0u; k < GROUP; k++) sum += lanes[k];
		totals[g] = sum;
	}
}
