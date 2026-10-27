#version 450
// SDL_GPU SPIR-V conventions: vertex storage buffers live in set 0, uniform buffers in set 1.
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_normal_oct; // octahedral with the mask in the low bits, see geom.oct_encode_masked

layout(set = 1, binding = 0) uniform Frame_Uniforms {
	mat4 view_proj;
	mat4 view;
	mat4 model; // rotation, translation and uniform scale only, so it also transforms normals
	vec4 options; // x: 1 to show the paint, y: 1 to show the polygroups (both read `paint`)
};

// Per vertex: its polypaint (sRGB red, green, blue and coverage, one byte each, red
// lowest) and the polygroup it carries (low 16 bits); see render.Mesh_Buffers.paint.
layout(std430, set = 0, binding = 0) readonly buffer Paint {
	uvec2 paint[];
};

layout(location = 0) out vec3 out_view_normal;
layout(location = 1) out vec3 out_view_pos;
layout(location = 2) out float out_mask; // 0 unmasked to 1 fully masked
layout(location = 3) out vec4 out_paint;  // linear colour, and how much it covers the clay
// The triangle's polygroup colour, from the corner it is drawn from; negative for none.
layout(location = 4) flat out vec3 out_group;
// Where the vertex is in the mesh's own space, for the density preview's checker.
layout(location = 5) out vec3 out_mesh_pos;

// A colour per group that neighbouring numbers keep far apart: hues a golden angle
// apart, in two lightnesses.
vec3 group_color(uint g) {
	float h = fract(float(g) * 0.618034 + 0.12);
	vec3 rgb = clamp(abs(fract(h + vec3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	float light = (g & 1u) == 0u ? 0.75 : 0.55;
	return mix(vec3(1.0), rgb, 0.55) * light;
}

// The sRGB curve back to linear light (IEC 61966-2-1), for the polypaint bytes.
vec3 srgb_decode(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 oct_decode(vec2 e) {
	vec3 v = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) v.xy = (1.0 - abs(e.yx)) * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
	return normalize(v);
}

void main() {
	// Back to the stored 16-bit integers: the top 12 bits are the normal, the low 4 bits
	// of each half the mask.
	ivec2 raw       = ivec2(round(max(in_normal_oct, vec2(-1.0)) * 32767.0));
	vec3 in_normal  = oct_decode(vec2(raw & ~15) / 32767.0);
	out_mask        = float(((raw.x & 15) << 4) | (raw.y & 15)) / 255.0;
	out_paint = vec4(0.0);
	out_group = vec3(-1.0);
	if (options.x > 0.5 || options.y > 0.5) {
		uvec2 p = paint[gl_VertexIndex];
		if (options.x > 0.5) out_paint = vec4(srgb_decode(unpackUnorm4x8(p.x).rgb), unpackUnorm4x8(p.x).a);
		if (options.y > 0.5) out_group = group_color(p.y & 0xffffu);
	}
	vec4 world      = model * vec4(in_position, 1.0);
	gl_Position     = view_proj * world;
	out_view_normal = mat3(view) * mat3(model) * in_normal;
	out_view_pos    = (view * world).xyz;
	out_mesh_pos    = in_position;
}
