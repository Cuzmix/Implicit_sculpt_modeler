#version 450
// A textured mesh's vertex (render.Textured_Vertex): one interleaved buffer, no paint.
// It writes everything mesh.vert does, so the shared fragment body reads the same inputs,
// plus the UV and the tangent the maps need.
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_normal_oct; // octahedral with the mask in the low bits, see geom.oct_encode_masked
layout(location = 2) in vec4 in_tangent;    // xyz unit, w the bitangent's side
layout(location = 3) in vec2 in_uv;

layout(set = 1, binding = 0) uniform Frame_Uniforms {
	mat4 view_proj;
	mat4 view;
	mat4 model; // rotation, translation and uniform scale only
	vec4 options;
	uvec4 slot_group[4];
};

layout(location = 0) out vec3 out_view_normal;
layout(location = 1) out vec3 out_view_pos;
layout(location = 2) out float out_mask;
layout(location = 3) out vec4 out_paint;
layout(location = 4) flat out vec3 out_group;
layout(location = 5) out vec3 out_mesh_pos;
layout(location = 6) flat out uint out_slot;
layout(location = 7) out vec2 out_uv;
layout(location = 8) out vec4 out_view_tangent;

vec3 oct_decode(vec2 e) {
	vec3 v = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) v.xy = (1.0 - abs(e.yx)) * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
	return normalize(v);
}

void main() {
	ivec2 raw      = ivec2(round(max(in_normal_oct, vec2(-1.0)) * 32767.0));
	vec3 in_normal = oct_decode(vec2(raw & ~15) / 32767.0);
	out_mask       = float(((raw.x & 15) << 4) | (raw.y & 15)) / 255.0;
	out_paint = vec4(0.0);
	out_group = vec3(-1.0);
	out_slot = 0u;
	vec4 world = model * vec4(in_position, 1.0);
	gl_Position = view_proj * world;
	// The turn into view space without the object's scale, so the normal and tangent keep
	// the unit lengths the bake read them with, and their cross product the bitangent's.
	mat3 turn = mat3(view) * mat3(model);
	turn /= length(turn[0]);
	out_view_normal  = turn * in_normal;
	out_view_tangent = vec4(turn * in_tangent.xyz, in_tangent.w < 0.0 ? -1.0 : 1.0);
	out_view_pos     = (view * world).xyz;
	out_mesh_pos     = in_position;
	out_uv           = in_uv;
}
