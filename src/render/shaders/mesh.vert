#version 450
// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(set = 1, binding = 0) uniform Frame_Uniforms {
	mat4 view_proj;
	mat4 view;
};

layout(location = 0) out vec3 out_view_normal;
layout(location = 1) out vec3 out_view_pos;

void main() {
	gl_Position     = view_proj * vec4(in_position, 1.0);
	out_view_normal = mat3(view) * in_normal;
	out_view_pos    = (view * vec4(in_position, 1.0)).xyz;
}
