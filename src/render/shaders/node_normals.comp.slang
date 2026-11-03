// slangc: -fp-mode precise
// The vertex normals of the nodes a stroke changed, worked out on the GPU
// (render/sculpt_gpu.odin, README "Sculpt on the GPU"): each vertex's normal is the sum of
// its triangles' face normals, taken in the order sculpt.job_node_normals takes them (the
// vertex's triangles ascending, cross(p1 - p0, p2 - p0) each), normalised and packed as
// geom.oct_encode_masked packs it, with the mask nibbles kept from the value already there.
// The first line has the build compile every multiply and add unfused (precise, which slangc
// does not take per variable), so the arithmetic is the CPU's up to the GPU's own rounding of
// the division and the square root.
//
// A workgroup takes one slab, up to SLAB vertices of one vertex range the flush reported (a
// slab is its first vertex and its count), and a thread takes one vertex.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers.

[[vk::binding(0, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(1, 0)]] StructuredBuffer<uint> offsets;   // vertex -> first slot in tris
[[vk::binding(2, 0)]] StructuredBuffer<uint> tris;
[[vk::binding(3, 0)]] StructuredBuffer<float> positions; // 3 floats a vertex
[[vk::binding(4, 0)]] StructuredBuffer<uint2> slabs;     // first vertex, count
[[vk::binding(0, 1)]] RWStructuredBuffer<uint> normals;  // a vertex's packed normal and mask: two shorts, x low

[[vk::binding(0, 2)]] cbuffer Params {
	uint slab_count;
	uint groups_x; // the dispatch's width, since many slabs need a second dimension
};

static const uint SLAB = 256;

float3 at(uint v) {
	return float3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
}

// geom.oct_encode of a unit normal, then oct_encode_masked's rounding: the top twelve bits
// of each component hold the normal and the low four are left for the mask.
int2 encode(float3 n) {
	float l1 = abs(n.x) + abs(n.y) + abs(n.z);
	if (l1 == 0.0) return int2(0, 0);
	float2 p = float2(n.x / l1, n.y / l1);
	if (n.z < 0.0) {
		float sx = p.x >= 0.0 ? 1.0 : -1.0;
		float sy = p.y >= 0.0 ? 1.0 : -1.0;
		p = float2((1.0 - abs(p.y)) * sx, (1.0 - abs(p.x)) * sy);
	}
	int2 e = int2(int(round(clamp(p.x, -1.0, 1.0) * 32767.0)), int(round(clamp(p.y, -1.0, 1.0) * 32767.0)));
	const int LIMIT = 32767 & ~15;
	return int2(clamp((e.x + 8) & ~15, -LIMIT, LIMIT), clamp((e.y + 8) & ~15, -LIMIT, LIMIT));
}

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint g = group_id.y * groups_x + group_id.x;
	if (g >= slab_count) return;
	uint2 slab = slabs[g];
	if (local_id.x >= slab.y) return;
	uint v = slab.x + local_id.x;
	float3 sum = float3(0.0);
	uint first = offsets[v], last = offsets[v + 1];
	for (uint k = first; k < last; k++) {
		uint f = tris[k];
		float3 p0 = at(indices[3 * f]);
		float3 p1 = at(indices[3 * f + 1]);
		float3 p2 = at(indices[3 * f + 2]);
		sum += cross(p1 - p0, p2 - p0);
	}
	// linalg.normalize0: the zero vector stays zero.
	float len = sqrt(dot(sum, sum));
	float3 n = len > 0.0 ? sum / len : float3(0.0);
	int2 e = encode(n);
	uint old = normals[v];
	uint x = (uint(e.x) & 0xffffu) | (old & 15u);
	uint y = (uint(e.y) & 0xffffu) | ((old >> 16) & 15u);
	normals[v] = x | (y << 16);
}
