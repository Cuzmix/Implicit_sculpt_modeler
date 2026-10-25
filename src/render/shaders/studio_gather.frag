#version 450
// One sample of the studio render: for every viewport pixel on a surface, whether a
// light from `light_dir` reaches it past everything in the shadow map, added to the
// accumulation target (blending adds). Ambient occlusion samples come from directions
// all round the scene and add (visibility * cos, cos) to red and green; key light
// samples, jittered around the key light, add (visibility, 1) to blue and alpha.
// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
layout(set = 2, binding = 0) uniform sampler2D view_depth;
layout(set = 2, binding = 1) uniform sampler2D shadow_depth;

layout(set = 3, binding = 0) uniform Gather_Uniforms {
	mat4 inv_view_proj;   // viewport clip space back to the world
	mat4 light_view_proj; // world to the shadow map's clip space
	vec4 light_dir;       // xyz: toward the light (world, unit); w: 1 for a key light sample
	vec4 params;          // x: depth bias, y: normal offset (world), z: shadow map texel (uv)
};

layout(location = 0) out vec4 out_sample;

vec3 world_at(vec2 frag, float depth, vec2 size) {
	vec2 uv = frag / size;
	vec4 w = inv_view_proj * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
	return w.xyz / w.w;
}

void main() {
	vec2 size = vec2(textureSize(view_depth, 0));
	ivec2 px = ivec2(gl_FragCoord.xy);
	float d = texelFetch(view_depth, px, 0).r;
	if (d >= 1.0) {
		out_sample = vec4(0.0);
		return;
	}
	vec3 p = world_at(gl_FragCoord.xy, d, size);
	// The surface normal from the depth of the neighbouring pixels, taking the side
	// with the smaller depth step so silhouettes do not smear across the background.
	ivec2 hi = ivec2(size) - 1;
	float dl = texelFetch(view_depth, clamp(px - ivec2(1, 0), ivec2(0), hi), 0).r;
	float dr = texelFetch(view_depth, clamp(px + ivec2(1, 0), ivec2(0), hi), 0).r;
	float du = texelFetch(view_depth, clamp(px - ivec2(0, 1), ivec2(0), hi), 0).r;
	float dd = texelFetch(view_depth, clamp(px + ivec2(0, 1), ivec2(0), hi), 0).r;
	vec3 px_r = abs(dr - d) < abs(d - dl) ? world_at(gl_FragCoord.xy + vec2(1, 0), dr, size) - p : p - world_at(gl_FragCoord.xy - vec2(1, 0), dl, size);
	vec3 px_d = abs(dd - d) < abs(d - du) ? world_at(gl_FragCoord.xy + vec2(0, 1), dd, size) - p : p - world_at(gl_FragCoord.xy - vec2(0, 1), du, size);
	vec3 n = normalize(cross(px_d, px_r));
	vec3 toward_eye = world_at(gl_FragCoord.xy, 0.0, size) - p;
	if (dot(n, toward_eye) < 0.0) n = -n;

	vec3 l = light_dir.xyz;
	float cosine = dot(n, l);
	bool key = light_dir.w > 0.5;
	if (cosine <= 0.0) {
		// Facing away: no light from here, which the viewport's shading already shows
		// for the key light.
		out_sample = key ? vec4(0.0, 0.0, 1.0, 1.0) : vec4(0.0);
		return;
	}
	vec4 c = light_view_proj * vec4(p + n * params.y, 1.0);
	vec3 s = c.xyz / c.w;
	vec2 uv = vec2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
	float lit = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			float occluder = texture(shadow_depth, uv + vec2(x, y) * params.z).r;
			lit += s.z - params.x <= occluder ? 1.0 : 0.0;
		}
	}
	lit /= 9.0;
	out_sample = key ? vec4(0.0, 0.0, lit, 1.0) : vec4(lit * cosine, cosine, 0.0, 0.0);
}
