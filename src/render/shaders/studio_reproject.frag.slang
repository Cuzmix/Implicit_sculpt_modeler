// Carries the studio render's samples (render/studio.odin) to where they are after the view
// turned, panned or zoomed, as TAA carries colour (Karis 2014) and EEVEE's and Toolbag's raster
// modes keep their shading while the camera moves. Each pixel's surface point, from this
// frame's depth, is found in last frame's picture; last frame's sums there are kept where
// last frame saw the same surface, read bilinearly over the four pixels around it, each tested
// on its own and the weights of those that pass made whole again (the sums are linear, so
// this is exact). Unlike TAA, nothing is clamped to the neighbourhood's colours, which would
// eat the occlusion: a sample is kept by whether it is of the same surface point, which is
// what occlusion and shadows belong to. Kept sums are then capped, so a turn's stale samples
// fade within a few frames as new ones come.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D view_depth; // this frame's, one sample
[[vk::binding(1, 2)]] Sampler2D prev_depth; // last frame's, R32F, as the depth buffer holds it
[[vk::binding(2, 2)]] Sampler2D prev_accum; // last frame's sums (studio_gather.frag.slang)

[[vk::binding(0, 3)]] cbuffer Reproject_Uniforms {
	float4x4 inv_view_proj;      // this frame's clip space back to the world
	float4x4 prev_view_proj;     // the world to last frame's clip space
	float4x4 prev_inv_view_proj; // last frame's clip space back to the world
	// x: the occlusion's cosine sum kept at most, y: the shadows' weight kept at most, z: 1 to
	// keep the shadows (every light fixed to the scene), 0 to drop them
	float4 params;
};

float3 world_at(float2 frag, float depth, float2 size) {
	float2 uv = frag / size;
	float4 w = mul(float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0), inv_view_proj);
	return w.xyz / w.w;
}

float3 prev_world_at(float2 frag, float depth, float2 size) {
	float2 uv = frag / size;
	float4 w = mul(float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0), prev_inv_view_proj);
	return w.xyz / w.w;
}

// studio_weight.slang's depth_normal reads shadow_ uniforms through light_window only for
// the weights, which this pass does not take; the normal is all it needs from there.
float3 normal_at(int2 px, float2 frag, float d, float3 p, float2 size) {
	int2 hi = int2(size) - 1;
	float dl = view_depth.Load(int3(clamp(px - int2(1, 0), int2(0), hi), 0)).r;
	float dr = view_depth.Load(int3(clamp(px + int2(1, 0), int2(0), hi), 0)).r;
	float du = view_depth.Load(int3(clamp(px - int2(0, 1), int2(0), hi), 0)).r;
	float dd = view_depth.Load(int3(clamp(px + int2(0, 1), int2(0), hi), 0)).r;
	float3 px_r = abs(dr - d) < abs(d - dl) ? world_at(frag + float2(1, 0), dr, size) - p : p - world_at(frag - float2(1, 0), dl, size);
	float3 px_d = abs(dd - d) < abs(d - du) ? world_at(frag + float2(0, 1), dd, size) - p : p - world_at(frag - float2(0, 1), du, size);
	return normalize(cross(px_d, px_r));
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	float2 size = float2(texture_size(view_depth));
	int2 px = int2(frag_coord.xy);
	float d = view_depth.Load(int3(px, 0)).r;
	if (d >= 1.0) return float4(0.0);
	float3 p = world_at(frag_coord.xy, d, size);
	float3 n = normal_at(px, frag_coord.xy, d, p, size);
	// The surface a pixel spans here, and how far it is from the eye (or, seen square on,
	// from the near plane): what two depths of one surface may differ by.
	float footprint = length(world_at(frag_coord.xy + float2(1.0, 0.0), d, size) - p);
	float distance = length(p - world_at(frag_coord.xy, 0.0, size));
	float plane_tolerance = 0.5 * footprint + 0.003 * distance;
	// A tap a pixel or so away lies on the surface a long way off where the surface is seen
	// edge on, so how far it may lie is loose: the plane test does the work, and this only
	// keeps a far surface that happens to share the plane from passing.
	float reach = 0.1 * distance + 4.0 * footprint;

	float4 c = mul(float4(p, 1.0), prev_view_proj);
	if (c.w <= 0.0) return float4(0.0);
	float2 at = float2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5) * size - 0.5;
	int2 base = int2(floor(at));
	float2 f = at - float2(base);
	int2 hi = int2(size) - 1;
	float4 sum = float4(0.0);
	float total = 0.0;
	for (int y = 0; y <= 1; y++) {
		for (int x = 0; x <= 1; x++) {
			int2 q = base + int2(x, y);
			if (any(q < int2(0)) || any(q > hi)) continue;
			float w = (x == 1 ? f.x : 1.0 - f.x) * (y == 1 ? f.y : 1.0 - f.y);
			if (w <= 0.0) continue;
			float qd = prev_depth.Load(int3(q, 0)).r;
			if (qd >= 1.0) continue;
			float3 qp = prev_world_at(float2(q) + 0.5, qd, size);
			float3 off = qp - p;
			if (abs(dot(n, off)) > plane_tolerance || length(off) > reach) continue;
			sum += w * prev_accum.Load(int3(q, 0));
			total += w;
		}
	}
	if (total <= 0.0) return float4(0.0);
	float4 kept = sum / total;
	// Caps in samples, so the history weighs no more than a few frames of new samples.
	kept.rg *= min(1.0, params.x / max(kept.g, 1e-6));
	kept.ba = params.z > 0.5 ? kept.ba * min(1.0, params.y / max(kept.a, 1e-6)) : float2(0.0);
	return kept;
}
