#version 450
// Depth from a light's point of view, for the studio render's shadow maps.
// SDL_GPU SPIR-V conventions: vertex uniform buffers live in set 1.
layout(location = 0) in vec3 in_position;

layout(set = 1, binding = 0) uniform Shadow_Uniforms {
	mat4 light_view_proj;
	mat4 model;
};

void main() {
	gl_Position = light_view_proj * model * vec4(in_position, 1.0);
}
