// slangc: -fp-mode precise
// One step of whole-mesh smoothing (sculpt.smooth_all_cpu on the GPU): each vertex goes
// to p * (1 - w) + target * w, the target being the mean of its triangles' corners.
// Reads src, writes dst; the host swaps them between steps. The first line has the build
// compile it with every multiply and add unfused (precise, which slangc does not take per
// variable), so the arithmetic is the CPU's.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers.

[[vk::binding(0, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(1, 0)]] StructuredBuffer<uint> offsets; // vertex -> first slot in tris
[[vk::binding(2, 0)]] StructuredBuffer<uint> tris;
[[vk::binding(3, 0)]] StructuredBuffer<float> weights;
[[vk::binding(4, 0)]] StructuredBuffer<float> src; // 3 floats a vertex
[[vk::binding(0, 1)]] RWStructuredBuffer<float> dst;

[[vk::binding(0, 2)]] cbuffer Params {
	uint vertex_count;
	uint groups_x; // the dispatch's width, since a large mesh needs a second dimension
};

float3 at(uint v) {
	return float3(src[3 * v], src[3 * v + 1], src[3 * v + 2]);
}

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID, uint3 global_id : SV_DispatchThreadID) {
	uint v = (group_id.y * groups_x + group_id.x) * 256 + local_id.x;
	if (v >= vertex_count) return;
	float3 p = at(v);
	float w = weights[v];
	uint first = offsets[v];
	uint last = offsets[v + 1];
	if (w > 0.0 && last > first) {
		float3 sum = float3(0.0);
		for (uint k = first; k < last; k++) {
			uint f = tris[k];
			sum += at(indices[3 * f]) + at(indices[3 * f + 1]) + at(indices[3 * f + 2]);
		}
		float3 target = sum / float(3 * (last - first));
		p = p * (1.0 - w) + target * w;
	}
	dst[3 * v] = p.x;
	dst[3 * v + 1] = p.y;
	dst[3 * v + 2] = p.z;
}
