// slangc: -fp-mode precise
// A dab's area from its slabs' partials (dab_area.comp.slang), as sculpt.dab_once sums
// them: the normal normalised, turned by the tilt when there is one, the plane through the
// weighted centre, moved along the normal for Clay. One workgroup: each thread adds every
// SLAB-th partial, and one thread adds the threads' sums in order, so the area is the same
// on every run.
#include "dab.slang"

groupshared float4 lane_normal[SLAB];
groupshared float4 lane_center[SLAB];

[numthreads(256, 1, 1)]
void main(uint3 local_id : SV_GroupThreadID) {
	Dab d = dabs[dab];
	float4 n = float4(0.0);
	float4 c = float4(0.0);
	for (uint k = local_id.x; k < d.slabs.y; k += SLAB) {
		n += partials[2 * (d.slabs.x + k)];
		c += partials[2 * (d.slabs.x + k) + 1];
	}
	lane_normal[local_id.x] = n;
	lane_center[local_id.x] = c;
	GroupMemoryBarrierWithGroupSync();
	if (local_id.x != 0) return;
	float4 sum_n = float4(0.0);
	float4 sum_c = float4(0.0);
	for (uint k = 0; k < SLAB; k++) {
		sum_n += lane_normal[k];
		sum_c += lane_center[k];
	}
	float3 normal = normalize0(sum_n.xyz);
	float3 plane = sum_n.w > 0.0 ? sum_c.xyz / sum_n.w : float3(0.0);
	if ((d.slabs.w & FLAG_TILT) != 0) {
		float3x3 tilt = float3x3(d.tilt0.xyz, d.tilt1.xyz, d.tilt2.xyz);
		normal = normalize0(mul(tilt, normal));
	}
	plane += normal * d.tilt2.w;
	areas[AREA_ROWS * dab] = float4(normal, 0.0);
	areas[AREA_ROWS * dab + 1] = float4(plane, 0.0);
	if ((d.slabs.w & FLAG_ALPHA) == 0) return;
	// sculpt.alpha_frame, in its order: the alpha's up laid on the plane (any way across
	// when it runs along the normal), right as up x normal, all over the radius.
	float3 an = normal;
	if (all(an == float3(0.0))) an = float3(0.0, 0.0, 1.0);
	float3 up = d.alpha_up.xyz - an * dot(d.alpha_up.xyz, an);
	if (dot(up, up) < 1e-12) {
		float3 helper = abs(an.x) < 0.9 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
		up = cross(an, helper);
	}
	float3 v = up / length(up);
	float3 u = cross(v, an);
	if ((d.slabs.w & FLAG_MIRROR) != 0) u = -u;
	float inv_r = 1.0 / d.misc.z;
	areas[AREA_ROWS * dab + 2] = float4(u * inv_r, 0.0);
	areas[AREA_ROWS * dab + 3] = float4(v * inv_r, 0.0);
	areas[AREA_ROWS * dab + 4] = float4(an * inv_r, 0.0);
}
