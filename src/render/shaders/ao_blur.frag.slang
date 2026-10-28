// Live ambient occlusion shown (render/live_ao.odin): the viewport image darkened by the
// occlusion gtao.frag.slang found, averaged over the 4 x 4 texels around the pixel (which
// holds every turn of gtao.frag.slang's pattern once) and weighted by how near each texel's
// depth is to the pixel's, so occlusion does not bleed across a silhouette. When the
// occlusion is at half size this is also its upsampling. The curve and strength are the
// studio render's (studio_composite.frag.slang), so the view does not jump when the still
// render takes over. The background is left as it is.
#include "common.slang"
[[vk::binding(0, 2)]] Sampler2D view_color;
[[vk::binding(1, 2)]] Sampler2D ao_map;
[[vk::binding(2, 2)]] Sampler2D view_depth;

[[vk::binding(0, 3)]] cbuffer Blur_Uniforms {
	float4x4 inv_proj; // the viewport's clip space back to view space
	float4 size;     // xy: the viewport's size in pixels, z: viewport pixels per occlusion texel
	float4 params;   // x: the occlusion's strength (0 to 1), y: the depth difference that drops a texel, in view units,
	               // z: a wipe compare's line in pixels (negative for none), w: the strength from it on
};

// The view-space depth (distance along the view axis) at a depth-buffer value; it does
// not depend on where on the screen.
float view_z(float depth) {
	float4 v = mul(float4(0.0, 0.0, depth, 1.0), inv_proj);
	return v.z / v.w;
}

float4 main(float4 frag_coord : SV_Position) : SV_Target0 {
	int2 px = int2(frag_coord.xy);
	float4 color = view_color.Load(int3(px, 0));
	float d = view_depth.Load(int3(px, 0)).r;
	if (d >= 1.0) {
		return color;
	}
	float z = view_z(d);
	int scale = int(size.z);
	int2 texels = texture_size(ao_map);
	int2 hi = int2(size.xy) - 1;
	int2 at = px / scale;
	float sum = 0.0, weight = 0.0;
	for (int y = -2; y <= 1; y++) {
		for (int x = -2; x <= 1; x++) {
			int2 t = clamp(at + int2(x, y), int2(0), texels - 1);
			float td = view_depth.Load(int3(clamp(t * scale + scale / 2, int2(0), hi), 0)).r;
			if (td >= 1.0) continue;
			float w = max(1.0 - abs(view_z(td) - z) / params.y, 0.0);
			sum += w * ao_map.Load(int3(t, 0)).r;
			weight += w;
		}
	}
	float ao = weight > 0.0 ? min(sum / weight, 1.0) : 1.0;
	// Each side of a wipe's line has its own pass, and only a side whose pass wants
	// occlusion is darkened.
	float strength = (params.z >= 0.0 && frag_coord.x >= params.z) ? params.w : params.x;
	float shade = lerp(1.0, ao * ao * (3.0 - 2.0 * ao), strength);
	return float4(color.rgb * shade, color.a);
}
