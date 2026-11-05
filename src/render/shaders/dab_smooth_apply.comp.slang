// slangc: -fp-mode precise
// A Smooth dab's step (sculpt.job_smooth_apply on the GPU, dab.slang): every vertex of the
// dab's slabs inside the reach moves toward the target dab_smooth_targets.comp.slang left
// in its scratch slot by this pass's rate times its falloff weight, what the mask leaves
// of it and the facing ramp;
// Relax keeps only the part across the surface, Valleys and Peaks take only the vertices
// whose step rises along their normal or sinks against it.
#include "dab.slang"

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	keep_bindings();
	Dab d = dabs[dab];
	uint g, v;
	if (!slab_vertex(d, group_id, local_id, g, v)) return;
	float3 p = at(v);
	float3 delta = p - d.center_r2.xyz;
	float d2 = dot(delta, delta);
	if (d2 >= d.center_r2.w) return;
	float3 n = normal_at(v);
	float w = shield(d, v) * facing_weight(d, n);
	if (w <= 0.0) return;
	float3 step = scratch[g * SLAB + local_id.x].xyz - p;
	uint flags = d.slabs.w;
	float along = dot(step, n);
	if ((flags & FLAG_VALLEYS) != 0 && !(along > 0.0)) return;
	if ((flags & FLAG_PEAKS) != 0 && !(along < 0.0)) return;
	float t = clamp(rate * dab_weight(d, delta, d2), 0.0, 1.0) * w;
	if ((flags & FLAG_RELAX) != 0) {
		// Only across the surface: the part along the normal would change the shape.
		step -= n * along;
	}
	put(v, p + step * t);
}
