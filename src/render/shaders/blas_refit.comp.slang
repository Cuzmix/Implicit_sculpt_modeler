// Refits every chunk tree of one mesh to where its vertices are now (render/trace.odin):
// sculpting moves vertices but keeps the triangles, so the trees built for them stay
// valid and only their boxes go stale. One invocation a chunk walks its nodes from the
// last to the first, so it meets both children of a node (stored after it) first. A
// leaf's box is its triangles'; a triangle with a repeated corner (a hidden one, drawn
// as three copies of one vertex, or a voxel surface's unused slot) adds nothing, and a
// node with nothing in it gets an empty box that no ray enters.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers.

struct Node {
	float3 lo;
	uint first; // inner: the left child, the right one after it; leaf: into the order
	float3 hi;
	uint count; // 0 for an inner node
};

[[vk::binding(0, 0)]] StructuredBuffer<float> positions; // 3 floats a vertex
[[vk::binding(1, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(2, 0)]] StructuredBuffer<uint> order; // two 16-bit offsets a word
[[vk::binding(3, 0)]] StructuredBuffer<uint4> chunks; // node_off, order_off, first_tri, node_count
[[vk::binding(0, 1)]] RWStructuredBuffer<Node> nodes;

[[vk::binding(0, 2)]] cbuffer Params {
	uint chunk_count;
	uint groups_x; // the dispatch's width, since a large mesh needs a second dimension
};

static const float BIG = 3.0e38;

float3 at(uint v) {
	return float3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
}

[numthreads(64, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID, uint3 global_id : SV_DispatchThreadID) {
	uint c = (group_id.y * groups_x + group_id.x) * 64 + local_id.x;
	if (c >= chunk_count) return;
	uint4 ch = chunks[c];
	uint base = ch.x;
	for (uint k = ch.w; k > 0; k--) {
		uint i = base + k - 1;
		Node n = nodes[i];
		float3 lo = float3(BIG), hi = float3(-BIG);
		if (n.count == 0) {
			Node a = nodes[base + n.first], b = nodes[base + n.first + 1];
			lo = min(a.lo, b.lo);
			hi = max(a.hi, b.hi);
		} else {
			for (uint j = n.first; j < n.first + n.count; j++) {
				uint at_order = ch.y + j;
				uint word = order[at_order >> 1];
				uint tri = ch.z + ((at_order & 1u) == 0u ? (word & 0xFFFFu) : (word >> 16));
				uint a = indices[3 * tri], b = indices[3 * tri + 1], d = indices[3 * tri + 2];
				if (a == b || b == d || a == d) continue;
				float3 p0 = at(a), p1 = at(b), p2 = at(d);
				lo = min(lo, min(p0, min(p1, p2)));
				hi = max(hi, max(p0, max(p1, p2)));
			}
		}
		nodes[i].lo = lo;
		nodes[i].hi = hi;
	}
}
