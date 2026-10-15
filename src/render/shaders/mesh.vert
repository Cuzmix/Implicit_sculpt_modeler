#version 450
// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_normal_oct; // octahedral, see geom.oct_encode

layout(set = 1, binding = 0) uniform Frame_Uniforms {
	mat4 view_proj;
	mat4 view;
	mat4 model; // translation and uniform scale only, so it also transforms normals
};

layout(location = 0) out vec3 out_view_normal;
layout(location = 1) out vec3 out_view_pos;

vec3 oct_decode(vec2 e) {
	vec3 v = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) v.xy = (1.0 - abs(e.yx)) * vec2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
	return normalize(v);
}

void main() {
	vec3 in_normal  = oct_decode(in_normal_oct);
	vec4 world      = model * vec4(in_position, 1.0);
	gl_Position     = view_proj * world;
	out_view_normal = mat3(view) * mat3(model) * in_normal;
	out_view_pos    = (view * world).xyz;
}
