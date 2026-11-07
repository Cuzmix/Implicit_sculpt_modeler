// slangc: -fp-mode precise
// A dab's move (sculpt.displace on the GPU, dab.slang): every vertex of the dab's slabs
// inside the reach moves as the kind says, by its falloff weight times what the mask
// leaves of it and the facing ramp, along the area dab_reduce.comp.slang worked out (Draw,
// Clay, Flatten, Pinch, Crease) or its own normal (Inflate). With Accumulate off (FLAG_ONCE) Draw and Inflate raise a
// vertex to this dab's height only where that is above what the stroke has given it so
// far (sculpt.displace's ONCE), both signs for Ctrl's dig, and keep the height.
#include "dab.slang"

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	keep_bindings();
	Dab d = dabs[dab];
	uint g, v;
	if (!slab_vertex(d, group_id, local_id, g, v)) return;
	float3 p = at(v);
	float3 center = d.center_r2.xyz;
	float3 delta = p - center;
	float d2 = dot(delta, delta);
	if (d2 >= d.center_r2.w) return;
	if ((d.slabs.w & FLAG_SWEEP) != 0) {
		// The offset from the nearest point of the sweep (sculpt.displace's ONCE).
		float3 sw = d.alpha_up.xyz;
		delta -= sw * clamp(dot(delta, sw) / dot(sw, sw), 0.0, 1.0);
		d2 = dot(delta, delta);
	}
	float3 n = normal_at(v);
	float w = dab_weight(d, delta, d2) * shield(d, v) * facing_weight(d, n);
	if (w <= 0.0) return;
	float amount = d.facing_amount.w;
	float strength = d.tilt0.w;
	float3 normal = areas[AREA_ROWS * dab].xyz;
	float3 plane = areas[AREA_ROWS * dab + 1].xyz;
	uint kind = d.slabs.z;
	if ((d.slabs.w & FLAG_ONCE) != 0) {
		uint2 l = heights[v];
		float h = l.x == stroke ? asfloat(l.y) : 0.0;
		float want = amount * w;
		float next = amount > 0.0 ? max(h, want) : min(h, want);
		float3 way = kind == DAB_DRAW ? normal : n;
		p += way * (next - h);
		heights[v] = uint2(stroke, asuint(next));
	} else if (kind == DAB_DRAW) {
		p += normal * (amount * w);
	} else if (kind == DAB_INFLATE) {
		p += n * (amount * w);
	} else if (kind == DAB_CLAY) {
		// Only what lies on the near side of the plane moves, up to the plane.
		float h = dot(p - plane, normal);
		if (h * amount < 0.0) p -= normal * (h * min(strength * w * PLANE_RATE, 1.0));
	} else if (kind == DAB_FLATTEN) {
		// Plane height and depth: past them on either side it leaves the surface.
		float h = dot(p - plane, normal);
		float reach = d.misc.z * (1.0 - clamp(h > 0.0 ? d.misc.x : d.misc.y, 0.0, 1.0));
		if (abs(h) <= reach) p -= normal * (h * amount * min(strength * w * PLANE_RATE, 1.0));
	} else if (kind == DAB_PINCH) {
		float3 to = center - p;
		to -= normal * dot(to, normal);
		p += to * (amount * min(strength * w * PINCH_RATE, 1.0));
	} else if (kind == DAB_CREASE) {
		float3 to = center - p;
		to -= normal * dot(to, normal);
		p += normal * (amount * w * w) + to * min(strength * w * CREASE_PINCH, 1.0);
	} else {
		return;
	}
	put(v, p);
}
