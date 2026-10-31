// vulkan only: GPU culling's second kernel (cull.slang), a workgroup a group of chunks:
// its drawn chunks' commands, after those of every group before it, so they keep the
// chunks' order. The commands buffer starts with a header of one command's size: the
// number of commands (the draw count the indirect draw reads), then the pass's drawn
// triangles and the chunks left out of the view and facing away, for the stats.
#include "cull.slang"

[[vk::binding(2, 0)]] StructuredBuffer<uint4> totals; // cull_count.comp.slang's
[[vk::binding(0, 1)]] RWStructuredBuffer<uint> commands;

static const uint HEADER = 5u; // words: one VkDrawIndexedIndirectCommand

[numthreads(64, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint g = group_id.x, i = local_id.x, c = g * GROUP + i;
	// Where this group's commands start: the drawn chunks of the groups before it. The
	// last group also sums every group for the header.
	bool last = g + 1u == counts.y;
	uint4 before = uint4(0u), all = uint4(0u);
	for (uint k = i; k < counts.y; k += GROUP) {
		if (k < g) before += totals[k];
		if (last) all += totals[k];
	}
	lanes[i] = before;
	GroupMemoryBarrierWithGroupSync();
	uint start = 0u;
	for (uint k = 0u; k < GROUP; k++) start += lanes[k].x;
	GroupMemoryBarrierWithGroupSync();
	if (last) {
		lanes[i] = all;
		GroupMemoryBarrierWithGroupSync();
		if (i == 0u) {
			uint4 sum = uint4(0u);
			for (uint k = 0u; k < GROUP; k++) sum += lanes[k];
			commands[0] = sum.x;
			commands[1] = sum.y;
			commands[2] = sum.z;
			commands[3] = sum.w;
			commands[4] = 0u;
		}
		GroupMemoryBarrierWithGroupSync();
	}
	if (totals[g].x == 0u) return;
	if (i == 0u) verdict = group_verdict(g);
	GroupMemoryBarrierWithGroupSync();
	bool drawn = c < counts.x && verdict == 0u && chunk_verdict(c) == 0u;
	lanes[i] = uint4(drawn ? 1u : 0u, 0u, 0u, 0u);
	GroupMemoryBarrierWithGroupSync();
	if (!drawn) return;
	uint slot = start;
	for (uint k = 0u; k < i; k++) slot += lanes[k].x;
	Record r = chunk_record(c);
	uint at = HEADER + 5u * slot;
	commands[at] = r.index_count;
	commands[at + 1u] = 1u;
	commands[at + 2u] = r.first_index;
	commands[at + 3u] = 0u;
	commands[at + 4u] = 0u;
}
