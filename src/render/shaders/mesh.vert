#version 450
// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(set = 1, binding = 0) uniform Frame_Uniforms {
	mat4 view_proj;
	mat4 view;
	mat4 model; // translation and uniform scale only, so it also transforms normals
};

layout(location = 0) out vec3 out_view_normal;
layout(location = 1) out vec3 out_view_pos;

void main() {
	vec4 world      = model * vec4(in_position, 1.0);
	gl_Position     = view_proj * world;
	out_view_normal = mat3(view) * mat3(model) * in_normal;
	out_view_pos    = (view * world).xyz;
}
