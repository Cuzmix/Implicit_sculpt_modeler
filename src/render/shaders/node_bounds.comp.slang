// slangc: -fp-mode precise
// The bounds of the nodes a stroke's flush handed over, after its dabs moved them on the
// GPU (render/sculpt_gpu.odin, README "Sculpt on the GPU"): one workgroup a node, over its
// own vertices and the vertices of its triangles that other nodes own, as
// sculpt.job_leaf_bounds grows them. Minimum and maximum are exact, so the bounds are the
// CPU's whatever the order, but for which zero a box keeps where +0 and -0 meet; the lanes
// still combine in one fixed order, so a run gives the same bits every time. The CPU reads
// them back with the positions instead of reading every vertex again (the landing's 2.9 ms
// a frame at 25M on the VM).
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers.

[[vk::binding(0, 0)]] StructuredBuffer<float> positions; // 3 floats a vertex
[[vk::binding(1, 0)]] StructuredBuffer<uint4> nodes;     // first vertex, count, first shared, count
[[vk::binding(2, 0)]] StructuredBuffer<uint> shared;     // sculpt.Sculptor.shared
[[vk::binding(0, 1)]] RWStructuredBuffer<float4> bounds; // two a node: lowest, highest

[[vk::binding(0, 2)]] cbuffer Params {
	uint node_count;
	uint groups_x; // the dispatch's width, since many nodes need a second dimension
};

static const uint LANES = 256;
static const float BIG = 3.40282346638528859812e+38; // max(f32): geom.AABB_EMPTY's corners

groupshared float3 lane_lo[LANES];
groupshared float3 lane_hi[LANES];

float3 at(uint v) {
	return float3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
}

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint g = group_id.y * groups_x + group_id.x;
	if (g >= node_count) return;
	uint4 n = nodes[g];
	float3 lo = float3(BIG, BIG, BIG);
	float3 hi = float3(-BIG, -BIG, -BIG);
	for (uint k = local_id.x; k < n.y; k += LANES) {
		float3 p = at(n.x + k);
		lo = min(lo, p);
		hi = max(hi, p);
	}
	for (uint k = local_id.x; k < n.w; k += LANES) {
		float3 p = at(shared[n.z + k]);
		lo = min(lo, p);
		hi = max(hi, p);
	}
	lane_lo[local_id.x] = lo;
	lane_hi[local_id.x] = hi;
	GroupMemoryBarrierWithGroupSync();
	// Halving, lane i with lane i + width: the same pairs on every run.
	for (uint width = LANES / 2; width > 0; width /= 2) {
		if (local_id.x < width) {
			lane_lo[local_id.x] = min(lane_lo[local_id.x], lane_lo[local_id.x + width]);
			lane_hi[local_id.x] = max(lane_hi[local_id.x], lane_hi[local_id.x + width]);
		}
		GroupMemoryBarrierWithGroupSync();
	}
	if (local_id.x != 0) return;
	bounds[2 * g] = float4(lane_lo[0], 0.0);
	bounds[2 * g + 1] = float4(lane_hi[0], 0.0);
}
