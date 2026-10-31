// ray query: the ray query check (render/ray_query.odin), which traces known rays
// against a top-level acceleration structure and writes what each hit, so the backend's
// builds are checked against answers worked out by hand. The own Vulkan and Metal backends
// run it; its Metal source comes from slangc's Metal target (scripts/shaders_msl.py).
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers; set 3 the acceleration structure.

[[vk::binding(0, 0)]] StructuredBuffer<float4> rays; // origin, then direction, each in xyz
[[vk::binding(0, 1)]] RWStructuredBuffer<float4> hits; // t, instance, primitive, geometry; then the barycentrics
[[vk::binding(0, 2)]] cbuffer Params {
	uint ray_count;
};
[[vk::binding(0, 3)]] RaytracingAccelerationStructure scene;

[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
	if (id.x >= ray_count) return;
	RayDesc ray;
	ray.Origin = rays[2 * id.x].xyz;
	ray.Direction = rays[2 * id.x + 1].xyz;
	ray.TMin = 0;
	ray.TMax = 1.0e30;
	RayQuery<RAY_FLAG_NONE> q;
	q.TraceRayInline(scene, RAY_FLAG_NONE, 0xFF, ray);
	// Every candidate of a geometry that is not opaque is taken, so both kinds are seen.
	while (q.Proceed()) {
		if (q.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE) q.CommitNonOpaqueTriangleHit();
	}
	float4 hit = float4(-1, 0, 0, 0);
	float4 bary = float4(0, 0, 0, 0);
	if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
		hit = float4(q.CommittedRayT(), float(q.CommittedInstanceID()), float(q.CommittedPrimitiveIndex()), float(q.CommittedGeometryIndex()));
		bary = float4(q.CommittedTriangleBarycentrics(), 0, 0);
	}
	hits[2 * id.x] = hit;
	hits[2 * id.x + 1] = bary;
}
