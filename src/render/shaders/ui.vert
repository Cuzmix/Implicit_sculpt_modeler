#version 450
// The interface kit's triangles: positions in physical pixels from the top-left of the
// target, texture coordinates in atlas pixels (or 0 to 1 across an image), and a colour.
layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(set = 1, binding = 0) uniform Ui_Vertex_Uniforms {
	vec4 target; // xy: the target's size in pixels
};

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

void main() {
	out_uv = in_uv;
	out_color = in_color;
	vec2 ndc = in_pos / target.xy * 2.0 - 1.0;
	gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
