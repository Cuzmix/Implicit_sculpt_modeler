#version 450
// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
layout(set = 3, binding = 0) uniform Clear_Uniforms {
	vec4 color;
};

layout(location = 0) out vec4 out_color;

void main() {
	out_color = color;
}
