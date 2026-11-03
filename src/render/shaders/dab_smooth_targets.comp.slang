// slangc: -fp-mode precise
// A Smooth dab's targets (sculpt.job_smooth_targets on the GPU, dab.slang): for every
// vertex of the dab's slabs inside the reach, the mean of its triangles' corners, or along
// an open border the middle of its border neighbours, as sculpt.smooth_target finds them;
// into the scratch slot of the vertex (its slab's index among the dab's times SLAB, plus
// its lane), which dab_smooth_apply.comp.slang reads after every target of the pass is
// written: a Jacobi step, as the CPU's.
#include "dab.slang"

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	keep_bindings();
	Dab d = dabs[dab];
	uint g, v;
	if (!slab_vertex(d, group_id, local_id, g, v)) return;
	float3 delta = at(v) - d.center_r2.xyz;
	if (dot(delta, delta) >= d.center_r2.w) return;
	// Inside a closed fan every neighbour is a corner of two of its triangles, so the
	// exclusive or of the other corners is zero; on a border the two border neighbours
	// are corners once and leave it non-zero.
	float3 sum = float3(0.0);
	float n = 0.0;
	uint odd = 0;
	uint first = offsets[v], last = offsets[v + 1];
	for (uint k = first; k < last; k++) {
		uint f = tris[k];
		uint a = indices[3 * f], b = indices[3 * f + 1], c = indices[3 * f + 2];
		sum += at(a) + at(b) + at(c);
		odd ^= a ^ b ^ c ^ v;
		n += 3.0;
	}
	float3 q = n > 0.0 ? sum / n : at(v);
	if (odd != 0 && n <= 96.0) {
		// The neighbours that are corners of only one of its triangles lie along the border.
		uint seen[64];
		uint times[64];
		for (uint j = 0; j < 64; j++) {
			seen[j] = 0;
			times[j] = 0;
		}
		uint count = 0;
		for (uint k = first; k < last; k++) {
			uint f = tris[k];
			for (uint i = 0; i < 3; i++) {
				uint w = indices[3 * f + i];
				if (w == v) continue;
				uint j = 0;
				while (j < count && seen[j] != w) j++;
				if (j == count) {
					seen[j] = w;
					times[j] = 0;
					count++;
				}
				times[j]++;
			}
		}
		float3 border = float3(0.0);
		float b = 0.0;
		for (uint j = 0; j < count; j++) {
			if (times[j] == 1) {
				border += at(seen[j]);
				b += 1.0;
			}
		}
		if (b > 0.0) q = border / b;
	}
	scratch[g * SLAB + local_id.x] = float4(q, 1.0);
}
