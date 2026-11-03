// slangc: -fp-mode precise
// A dab's area (sculpt.job_area on the GPU, dab.slang): the falloff-weighted sums of the
// normals and the positions inside the sample radius, one partial a slab, which
// dab_reduce.comp.slang adds up. The threads' sums are added in thread order by one thread,
// so a slab's partial is the same on every run.
#include "dab.slang"

groupshared float4 lane_normal[SLAB]; // normal sum, weight
groupshared float4 lane_center[SLAB];

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	Dab d = dabs[dab];
	uint g, v;
	bool mine = slab_vertex(d, group_id, local_id, g, v);
	float4 normal = float4(0.0);
	float4 center = float4(0.0);
	if (mine) {
		float3 delta = at(v) - d.center_r2.xyz;
		float d2 = dot(delta, delta);
		float inv_sample2 = d.tilt1.w;
		if (d2 * inv_sample2 < 1.0) {
			float w = falloff(d2 * inv_sample2);
			normal = float4(normal_at(v) * w, w);
			center = float4(at(v) * w, 0.0);
		}
	}
	lane_normal[local_id.x] = normal;
	lane_center[local_id.x] = center;
	GroupMemoryBarrierWithGroupSync();
	if (local_id.x == 0 && g < d.slabs.y) {
		float4 n = float4(0.0);
		float4 c = float4(0.0);
		for (uint k = 0; k < SLAB; k++) {
			n += lane_normal[k];
			c += lane_center[k];
		}
		partials[2 * (d.slabs.x + g)] = n;
		partials[2 * (d.slabs.x + g) + 1] = c;
	}
}
