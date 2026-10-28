#version 450
// Live ambient occlusion shown (render/live_ao.odin): the viewport image darkened by the
// occlusion gtao.frag found, averaged over the 4 x 4 texels around the pixel (which
// holds every turn of gtao.frag's pattern once) and weighted by how near each texel's
// depth is to the pixel's, so occlusion does not bleed across a silhouette. When the
// occlusion is at half size this is also its upsampling. The curve and strength are the
// studio render's (studio_composite.frag), so the view does not jump when the still
// render takes over. The background is left as it is.
layout(set = 2, binding = 0) uniform sampler2D view_color;
layout(set = 2, binding = 1) uniform sampler2D ao_map;
layout(set = 2, binding = 2) uniform sampler2D view_depth;

layout(set = 3, binding = 0) uniform Blur_Uniforms {
	mat4 inv_proj; // the viewport's clip space back to view space
	vec4 size;     // xy: the viewport's size in pixels, z: viewport pixels per occlusion texel
	vec4 params;   // x: the occlusion's strength (0 to 1), y: the depth difference that drops a texel, in view units,
	               // z: a wipe compare's line in pixels (negative for none), w: the strength from it on
};

layout(location = 0) out vec4 out_color;

// The view-space depth (distance along the view axis) at a depth-buffer value; it does
// not depend on where on the screen.
float view_z(float depth) {
	vec4 v = inv_proj * vec4(0.0, 0.0, depth, 1.0);
	return v.z / v.w;
}

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	vec4 color = texelFetch(view_color, px, 0);
	float d = texelFetch(view_depth, px, 0).r;
	if (d >= 1.0) {
		out_color = color;
		return;
	}
	float z = view_z(d);
	int scale = int(size.z);
	ivec2 texels = textureSize(ao_map, 0);
	ivec2 hi = ivec2(size.xy) - 1;
	ivec2 at = px / scale;
	float sum = 0.0, weight = 0.0;
	for (int y = -2; y <= 1; y++) {
		for (int x = -2; x <= 1; x++) {
			ivec2 t = clamp(at + ivec2(x, y), ivec2(0), texels - 1);
			float td = texelFetch(view_depth, clamp(t * scale + scale / 2, ivec2(0), hi), 0).r;
			if (td >= 1.0) continue;
			float w = max(1.0 - abs(view_z(td) - z) / params.y, 0.0);
			sum += w * texelFetch(ao_map, t, 0).r;
			weight += w;
		}
	}
	float ao = weight > 0.0 ? min(sum / weight, 1.0) : 1.0;
	// Each side of a wipe's line has its own pass, and only a side whose pass wants
	// occlusion is darkened.
	float strength = (params.z >= 0.0 && gl_FragCoord.x >= params.z) ? params.w : params.x;
	float shade = mix(1.0, ao * ao * (3.0 - 2.0 * ao), strength);
	out_color = vec4(color.rgb * shade, color.a);
}
